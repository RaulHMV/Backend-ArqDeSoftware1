#!/usr/bin/env python3
"""Rescate de una replica MySQL MAL HECHA (el esclavo acepto escrituras directas).

Corre en el ESCLAVO como root. No borra ni reclona nada:
  1. (rescatar) congela el esclavo (super_read_only) para que no entren mas errores.
  2. Lee el BINLOG del esclavo y separa lo que se escribio directo ahi (server_id del
     esclavo). El binlog (formato ROW, imagen FULL: default de MySQL 8) guarda cada fila
     ANTES y DESPUES del cambio: es la "libreta" que la replica mal hecha nunca tuvo.
  3. Deja cada cambio en ops.rescate del MAESTRO y llama ops.reconciliar(): aplica lo
     seguro y marca conflicto lo que tambien cambio en el maestro (gana el maestro).
  4. Corrige en el esclavo SOLO las filas en conflicto (les pone la version del maestro).
  5. Revive la replica (modo IDEMPOTENT mientras se pone al dia) y verifica con
     CHECKSUM TABLE que maestro y esclavo quedaron iguales.

Modos: diagnostico (solo informa, no cambia nada) | rescatar (arregla).
"""
import argparse
import datetime
import decimal
import json
import logging
import os
import re
import sys
import time

import pymysql
from pymysql.cursors import DictCursor
from pymysqlreplication import BinLogStreamReader
from pymysqlreplication.event import QueryEvent
from pymysqlreplication.row_event import DeleteRowsEvent, UpdateRowsEvent, WriteRowsEvent

# El binlog guarda TIMESTAMP en UTC; todo el rescate trabaja en UTC.
os.environ["TZ"] = "UTC"
time.tzset()
# La libreria avisa que binlog_row_metadata=MINIMAL no trae nombres de columna: los
# resolvemos nosotros por posicion con information_schema.
logging.getLogger("pymysqlreplication").setLevel(logging.ERROR)

ID_LECTOR = 4242          # server_id con el que leemos el binlog (distinto a maestro/esclavo)
INT_BITS = {"tinyint": 8, "smallint": 16, "mediumint": 24, "int": 32, "bigint": 64}


class NoSoportado(Exception):
    pass


# --------------------------------------------------------------------- conexiones
def conectar_esclavo(socket):
    return pymysql.connect(unix_socket=socket, user="root", password="", charset="utf8mb4",
                           autocommit=True, cursorclass=DictCursor,
                           init_command="SET time_zone = '+00:00'")


def conectar_maestro(host, port, user, password):
    # caching_sha2_password exige conexion cifrada: TLS sin verificar cert (red privada).
    return pymysql.connect(host=host, port=port, user=user, password=password, charset="utf8mb4",
                           autocommit=True, cursorclass=DictCursor, ssl={"check_hostname": False},
                           init_command="SET time_zone = '+00:00'")


def q(conn, sql, args=None):
    with conn.cursor() as c:
        c.execute(sql, args)
        return c.fetchall()


def q1(conn, sql, args=None):
    filas = q(conn, sql, args)
    return filas[0] if filas else None


def posicion_binlog(conn):
    for sql in ("SHOW BINARY LOG STATUS", "SHOW MASTER STATUS"):   # 8.4+ / 8.0
        try:
            fila = q1(conn, sql)
            return (fila["File"], int(fila["Position"])) if fila else None
        except pymysql.err.ProgrammingError:
            continue
    return None


def estado_replica(esc):
    fila = q1(esc, "SHOW REPLICA STATUS")
    if not fila:
        return {"configurada": False, "texto": "replica NO configurada"}
    io, sql = fila.get("Replica_IO_Running"), fila.get("Replica_SQL_Running")
    err = fila.get("Last_SQL_Error") or fila.get("Last_IO_Error") or ""
    texto = f"IO={io} SQL={sql}" + (f" | error: {err[:150]}" if err else "")
    return {"configurada": True, "io": io, "sql": sql, "error": err, "texto": texto}


# --------------------------------------------------------------------- metadatos
def metadatos(esc, db):
    """Columnas (en orden) y PK de cada tabla de la base."""
    tablas = {}
    for f in q(esc, """SELECT TABLE_NAME t, COLUMN_NAME c, DATA_TYPE d, COLUMN_TYPE ct
                         FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = %s
                        ORDER BY TABLE_NAME, ORDINAL_POSITION""", (db,)):
        tablas.setdefault(f["t"], {"cols": [], "pk": None})["cols"].append(
            {"nombre": f["c"], "tipo": f["d"], "tipo_col": f["ct"]})
    for f in q(esc, """SELECT TABLE_NAME t, GROUP_CONCAT(COLUMN_NAME) pk, COUNT(*) n
                         FROM information_schema.KEY_COLUMN_USAGE
                        WHERE TABLE_SCHEMA = %s AND CONSTRAINT_NAME = 'PRIMARY'
                        GROUP BY TABLE_NAME""", (db,)):
        if f["t"] in tablas and f["n"] == 1:
            tablas[f["t"]]["pk"] = f["pk"]
    return tablas


def opciones_enum(tipo_col):
    return re.findall(r"'((?:[^']|'')*)'", tipo_col)


def a_json(valor, col):
    """Valor del binlog -> valor JSON con el MISMO formato que JSON_OBJECT() de MySQL."""
    if valor is None:
        return None
    tipo = col["tipo"]
    if tipo in INT_BITS and isinstance(valor, int) and valor < 0 and "unsigned" in col["tipo_col"]:
        return valor + (1 << INT_BITS[tipo])
    if tipo == "enum" and isinstance(valor, int):
        return opciones_enum(col["tipo_col"])[valor - 1] if valor > 0 else ""
    if tipo == "set" and isinstance(valor, int):
        ops = opciones_enum(col["tipo_col"])
        return ",".join(o for i, o in enumerate(ops) if valor & (1 << i))
    if isinstance(valor, set):
        return ",".join(o for o in opciones_enum(col["tipo_col"]) if o in valor)
    if isinstance(valor, bool):
        return int(valor)
    if isinstance(valor, decimal.Decimal):
        return float(valor)        # MySQL tambien lee los numeros JSON con punto como DOUBLE
    if isinstance(valor, datetime.datetime):
        return valor.strftime("%Y-%m-%d %H:%M:%S.%f")   # JSON de MySQL: siempre 6 decimales
    if isinstance(valor, datetime.date):
        return valor.isoformat()
    if isinstance(valor, datetime.timedelta):
        seg = valor.total_seconds()
        signo, seg = ("-" if seg < 0 else ""), abs(seg)
        h, resto = divmod(int(seg), 3600)
        return f"{signo}{h:02d}:{resto // 60:02d}:{resto % 60:02d}.{round((seg % 1) * 1e6):06d}"
    if isinstance(valor, (bytes, bytearray)):
        raise NoSoportado(f"columna binaria '{col['nombre']}' ({tipo})")
    return valor                    # int, float, str, dict/list (columna JSON)


def fila_json(valores, meta_tabla):
    cols = meta_tabla["cols"]
    salida = {}
    for clave, valor in valores.items():
        if clave.startswith("UNKNOWN_COL"):            # metadata MINIMAL: viene por posicion
            col = cols[int(clave[len("UNKNOWN_COL"):])]
        else:
            col = next(c for c in cols if c["nombre"] == clave)
        salida[col["nombre"]] = a_json(valor, col)
    return salida


# --------------------------------------------------------------------- leer binlog
def leer_cambios_esclavo(socket, sid_esclavo, db, desde, meta):
    """Recorre el binlog del esclavo y devuelve SOLO lo escrito directo en el esclavo."""
    kw = dict(connection_settings={"unix_socket": socket, "user": "root", "passwd": "", "charset": "utf8mb4"},
              server_id=ID_LECTOR, blocking=False,
              only_events=[QueryEvent, WriteRowsEvent, UpdateRowsEvent, DeleteRowsEvent])
    if desde:
        kw.update(log_file=desde[0], log_pos=desde[1], resume_stream=True)
    stream = BinLogStreamReader(**kw)
    notas, otros, primero = [], [], None
    try:
        for ev in stream:
            if primero is None:
                primero = ev.timestamp
            if ev.packet.server_id != sid_esclavo:
                continue                                   # vino del maestro por replicacion
            if isinstance(ev, QueryEvent):
                sql = ev.query.strip()
                if sql.upper() not in ("BEGIN", "COMMIT") and not sql.upper().startswith("XA "):
                    otros.append(f"sentencia directa en el esclavo (no rescatable): {sql[:120]}")
                continue
            if ev.schema == "ops":
                continue
            if ev.schema != db or ev.table not in meta or not meta[ev.table]["pk"]:
                otros.append(f"cambio en {ev.schema}.{ev.table} (fuera de '{db}' o sin PK simple)")
                continue
            m = meta[ev.table]
            op = {WriteRowsEvent: "INSERT", UpdateRowsEvent: "UPDATE", DeleteRowsEvent: "DELETE"}[type(ev)]
            cuando = datetime.datetime.fromtimestamp(ev.timestamp, datetime.timezone.utc)
            for i, fila in enumerate(ev.rows):
                uid = f"{stream.log_file}:{stream.log_pos:012d}:{i:04d}"
                try:
                    if op == "INSERT":
                        antes, despues = None, fila_json(fila["values"], m)
                    elif op == "UPDATE":
                        antes, despues = fila_json(fila["before_values"], m), fila_json(fila["after_values"], m)
                    else:
                        antes, despues = fila_json(fila["values"], m), None
                except NoSoportado as e:
                    otros.append(f"{op} en {ev.table}: {e}")
                    continue
                pk = (despues or antes)[m["pk"]]
                notas.append({"uid": uid, "tabla": ev.table, "op": op, "pk": pk, "antes": antes,
                              "despues": despues, "cuando": cuando.strftime("%Y-%m-%d %H:%M:%S.%f")})
    finally:
        stream.close()
    return notas, otros, primero


# --------------------------------------------------------------------- pasos
def clasificar_previo(mae, db, notas):
    """Solo para el diagnostico: misma regla que ops.reconciliar(), sin aplicar nada."""
    exprs = {f["tabla"]: f for f in q(mae, "SELECT tabla, pk, json_expr FROM ops.tablas")}
    unicos = {}   # tabla -> {indice: [columnas]} (UNIQUE que no son la PK)
    for f in q(mae, """SELECT TABLE_NAME t, INDEX_NAME i, COLUMN_NAME c FROM information_schema.STATISTICS
                        WHERE TABLE_SCHEMA = %s AND NON_UNIQUE = 0 AND INDEX_NAME <> 'PRIMARY'
                        ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX""", (db,)):
        unicos.setdefault(f["t"], {}).setdefault(f["i"], []).append(f["c"])
    for n in notas:
        e = exprs[n["tabla"]]
        fila = q1(mae, f"SELECT CAST({e['json_expr']} AS CHAR) j FROM `{db}`.`{n['tabla']}` WHERE `{e['pk']}` = %s",
                  (n["pk"],))
        actual = json.loads(fila["j"]) if fila else None
        a, d = n["antes"], n["despues"]
        if (n["op"] == "INSERT" and actual is None) or (n["op"] != "INSERT" and actual == a):
            n["resultado"] = "aplicaria"
            # Igual que en el rescate real: un UNIQUE ocupado por otra fila es conflicto
            for idx, cols in unicos.get(n["tabla"], {}).items() if d else []:
                where = " AND ".join(f"`{c}` = %s" for c in cols)
                if q1(mae, f"SELECT 1 x FROM `{db}`.`{n['tabla']}` WHERE {where} AND `{e['pk']}` <> %s LIMIT 1",
                      tuple(d[c] for c in cols) + (n["pk"],)):
                    n["resultado"] = f"conflicto (UNIQUE {idx})"
                    break
        elif actual == d:
            n["resultado"] = "ya_estaba"
        else:
            n["resultado"] = "conflicto"


def corregir_conflictos(esc, mae, db, meta):
    """Pone en el esclavo la version del maestro de cada fila en conflicto (sin binlog)."""
    pendientes = q(mae, """SELECT DISTINCT tabla, pk FROM ops.rescate
                            WHERE resultado = 'conflicto' AND esclavo_corregido = 0""")
    if not pendientes:
        return 0
    q(esc, "SET GLOBAL read_only = ON")          # la app (sin SUPER) sigue sin poder escribir
    q(esc, "SET GLOBAL super_read_only = OFF")   # root si, para corregir
    try:
        q(esc, "SET SESSION sql_log_bin = 0")    # la correccion no debe generar mas binlog
        q(esc, "SET SESSION foreign_key_checks = 0")
        for p in pendientes:
            t, pkcol = p["tabla"], meta[p["tabla"]]["pk"]
            fila = q1(mae, f"SELECT * FROM `{db}`.`{t}` WHERE `{pkcol}` = %s", (p["pk"],))
            q(esc, f"DELETE FROM `{db}`.`{t}` WHERE `{pkcol}` = %s", (p["pk"],))
            if fila:
                cols = ", ".join(f"`{c}`" for c in fila)
                q(esc, f"INSERT INTO `{db}`.`{t}` ({cols}) VALUES ({', '.join(['%s'] * len(fila))})",
                  tuple(fila.values()))
            q(mae, """UPDATE ops.rescate SET esclavo_corregido = 1
                       WHERE tabla = %s AND pk = %s AND resultado = 'conflicto'""", (t, p["pk"]))
    finally:
        q(esc, "SET SESSION sql_log_bin = 1")
        q(esc, "SET SESSION foreign_key_checks = 1")
        q(esc, "SET GLOBAL super_read_only = ON")
    return len(pendientes)


def poner_al_dia(esc, mae, espera=120):
    """Revive la replica y la pone al dia con el maestro. Mientras alcanza usa modo
    IDEMPOTENT (ignora 'ya existe'/'no existe': p.ej. una fila que el esclavo borro por
    error y luego el maestro tambien borro). Despues vuelve a STRICT."""
    if not estado_replica(esc)["configurada"]:
        return "replica no configurada: no se puede poner al dia"
    objetivo = posicion_binlog(mae)
    q(esc, "STOP REPLICA")
    q(esc, "SET GLOBAL replica_exec_mode = 'IDEMPOTENT'")
    q(esc, "START REPLICA")
    r = q1(esc, "SELECT SOURCE_POS_WAIT(%s, %s, %s) r", (objetivo[0], objetivo[1], espera))["r"]
    q(esc, "STOP REPLICA")
    q(esc, "SET GLOBAL replica_exec_mode = 'STRICT'")
    q(esc, "START REPLICA")
    time.sleep(2)
    if r is None or r == -1:
        return f"no alcanzo al maestro en {espera}s (SOURCE_POS_WAIT={r})"
    return "al dia"


def checksums(conn, db, tablas):
    return {t: q1(conn, f"CHECKSUM TABLE `{db}`.`{t}`")["Checksum"] for t in tablas}


def verificar(esc, mae, db, tablas, intentos=3):
    for _ in range(intentos):
        objetivo = posicion_binlog(mae)
        q1(esc, "SELECT SOURCE_POS_WAIT(%s, %s, 60) r", objetivo)
        cm, ce = checksums(mae, db, tablas), checksums(esc, db, tablas)
        distintas = [t for t in tablas if cm[t] != ce[t]]
        if not distintas:
            return True, "maestro y esclavo IGUALES (CHECKSUM TABLE de todas las tablas)"
        time.sleep(3)      # el maestro sigue recibiendo escrituras: reintentar
    return False, "DISTINTAS: " + ", ".join(distintas) + " (cambios sin rastro en binlog: revisar a mano)"


# --------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--modo", choices=["diagnostico", "rescatar"], required=True)
    ap.add_argument("--db", default="demo")
    ap.add_argument("--esclavo-socket", default="/var/run/mysqld/mysqld.sock")
    ap.add_argument("--maestro-host", required=True)
    ap.add_argument("--maestro-port", type=int, default=3306)
    ap.add_argument("--maestro-user", default="rescate")
    ap.add_argument("--bloquear", choices=["si", "no"], default="si",
                    help="dejar el esclavo en solo lectura al final (arreglar la causa)")
    ap.add_argument("--informe", help="archivo markdown con el informe")
    a = ap.parse_args()

    inf = []
    def p(linea=""):
        print(linea)
        inf.append(linea)

    esc = conectar_esclavo(a.esclavo_socket)
    mae = conectar_maestro(a.maestro_host, a.maestro_port, a.maestro_user, os.environ["RESCATE_PASSWORD"])
    v = q1(esc, """SELECT @@server_id sid, @@log_bin log_bin, @@binlog_format fmt, @@binlog_row_image img,
                          @@gtid_mode gtid, @@read_only ro, @@super_read_only sro""")
    p(f"## Rescate de replica — modo **{a.modo}**")
    p()
    p(f"- Esclavo: server_id={v['sid']}, binlog={'ON' if v['log_bin'] else 'OFF'}, formato={v['fmt']}, "
      f"imagen={v['img']}, GTID={v['gtid']}, read_only={v['ro']}")
    rep_antes = estado_replica(esc)
    p(f"- Replica al empezar: {rep_antes['texto']}")
    if not v["log_bin"] or v["fmt"] != "ROW" or v["img"] != "FULL":
        p("- **No se puede rescatar automaticamente**: sin binlog ROW con imagen FULL no existe el")
        p("  'antes' de cada cambio. Solo se puede comparar (pt-table-checksum) y decidir a mano.")
        return finalizar(inf, a.informe, 2)

    meta = metadatos(esc, a.db)
    tablas = sorted(t for t in meta if meta[t]["pk"])
    q(mae, "CALL ops.registrar_tablas()")

    if a.modo == "rescatar":
        q(esc, "SET GLOBAL super_read_only = ON")         # 1. frenar: no mas escrituras
        p("- Esclavo congelado (super_read_only=ON) mientras se rescata")

    hasta = posicion_binlog(esc)
    cp = q1(mae, "SELECT archivo, posicion FROM ops.checkpoint WHERE id = 1")
    disponibles = [f["Log_name"] for f in q(esc, "SHOW BINARY LOGS")]
    desde = (cp["archivo"], cp["posicion"]) if cp and cp["archivo"] in disponibles else None
    if cp and not desde:
        p(f"- AVISO: el binlog del checkpoint ({cp['archivo']}) ya no existe; se lee desde el mas antiguo")
    notas, otros, primero = leer_cambios_esclavo(a.esclavo_socket, v["sid"], a.db, desde, meta)
    if primero and not desde:
        p(f"- Binlog disponible desde: {datetime.datetime.fromtimestamp(primero, datetime.timezone.utc):%Y-%m-%d %H:%M} UTC "
          "(cambios mas viejos que eso ya no tienen 'antes')")
    p(f"- Cambios escritos DIRECTO en el esclavo: **{len(notas)}**"
      + (f" (INSERT={sum(n['op'] == 'INSERT' for n in notas)}, UPDATE={sum(n['op'] == 'UPDATE' for n in notas)}, "
         f"DELETE={sum(n['op'] == 'DELETE' for n in notas)})" if notas else ""))
    for o in otros:
        p(f"  - ⚠️ {o}")

    if a.modo == "diagnostico":
        clasificar_previo(mae, a.db, notas)
        p()
        p("| cambio | tabla | id | que pasaria |")
        p("|---|---|---|---|")
        for n in notas[:100]:
            p(f"| {n['op']} | {n['tabla']} | {n['pk']} | {n['resultado']} |")
        ok, texto = True, "(diagnostico: no se cambio nada)"
        cm, ce = checksums(mae, a.db, tablas), checksums(esc, a.db, tablas)
        dist = [t for t in tablas if cm[t] != ce[t]]
        p()
        p(f"- Tablas distintas hoy entre maestro y esclavo: {', '.join(dist) if dist else 'ninguna'}")
        q(mae, "INSERT INTO ops.incidentes (modo, cambios_esclavo, replica_antes, verificacion) VALUES (%s,%s,%s,%s)",
          ("diagnostico", len(notas), rep_antes["texto"][:255], texto))
        return finalizar(inf, a.informe, 0)

    # 2-3. dejar los cambios en el maestro y reconciliar
    if notas:
        with mae.cursor() as c:
            c.executemany("""INSERT IGNORE INTO ops.rescate (uid, tabla, op, pk, antes, despues, cuando)
                             VALUES (%s, %s, %s, %s, %s, %s, %s)""",
                          [(n["uid"], n["tabla"], n["op"], n["pk"],
                            json.dumps(n["antes"], ensure_ascii=False) if n["antes"] is not None else None,
                            json.dumps(n["despues"], ensure_ascii=False) if n["despues"] is not None else None,
                            n["cuando"]) for n in notas])
    q(mae, "CALL ops.reconciliar(@a, @y, @c)")
    r = q1(mae, "SELECT @a a, @y y, @c c")
    aplicados, ya, conflictos = int(r["a"] or 0), int(r["y"] or 0), int(r["c"] or 0)
    p(f"- Reconciliado en el maestro: aplicados={aplicados}, ya_estaban={ya}, conflictos={conflictos} (gana el maestro)")

    # 4. corregir en el esclavo SOLO las filas en conflicto
    corregidas = corregir_conflictos(esc, mae, a.db, meta)
    p(f"- Filas del esclavo corregidas con la version del maestro: {corregidas}")

    # 5. checkpoint, replica y GTIDs
    q(mae, """INSERT INTO ops.checkpoint (id, archivo, posicion) VALUES (1, %s, %s)
              ON DUPLICATE KEY UPDATE archivo = VALUES(archivo), posicion = VALUES(posicion)""", hasta)
    p(f"- Replica: {poner_al_dia(esc, mae)}")
    gtids = 0
    if v["gtid"] == "ON":
        g_esc = q1(esc, "SELECT REPLACE(@@GLOBAL.gtid_executed, '\\n', '') g")["g"]
        errantes = q1(mae, "SELECT GTID_SUBTRACT(%s, REPLACE(@@GLOBAL.gtid_executed, '\\n', '')) e", (g_esc,))["e"]
        if errantes:
            q(mae, "CALL ops.inyectar_gtids(%s, 100000, @n)", (errantes,))
            gtids = int(q1(mae, "SELECT @n n")["n"])
        p(f"- GTIDs errantes registrados en el maestro: {gtids}")

    # 6. verificar y cerrar la causa
    ok, texto = verificar(esc, mae, a.db, tablas)
    rep_despues = estado_replica(esc)
    p(f"- Replica al terminar: {rep_despues['texto']}")
    p(f"- Verificacion: {'✅' if ok else '❌'} {texto}")
    if a.bloquear == "si":
        q(esc, "SET PERSIST read_only = ON")
        q(esc, "SET PERSIST super_read_only = ON")
        p("- Causa cerrada: esclavo en SOLO LECTURA permanente (SET PERSIST super_read_only=ON)")
    else:
        q(esc, "SET GLOBAL super_read_only = OFF")
        q(esc, "SET GLOBAL read_only = OFF")
        p("- Esclavo se deja ESCRIBIBLE otra vez (bloquear=no; util para repetir la demo)")
    q(mae, """INSERT INTO ops.incidentes (modo, cambios_esclavo, aplicados, ya_estaban, conflictos,
                filas_corregidas, gtids_limpiados, replica_antes, replica_despues, verificacion)
              VALUES ('rescatar', %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
      (len(notas), aplicados, ya, conflictos, corregidas, gtids,
       rep_antes["texto"][:255], rep_despues["texto"][:255], texto[:255]))
    if notas:
        p()
        p("| cambio | tabla | id | resultado | detalle |")
        p("|---|---|---|---|---|")
        for f in q(mae, "SELECT op, tabla, pk, resultado, IFNULL(detalle,'') d FROM ops.rescate "
                        "WHERE uid IN (" + ",".join(["%s"] * len(notas)) + ") ORDER BY uid",
                   tuple(n["uid"] for n in notas))[:100]:
            p(f"| {f['op']} | {f['tabla']} | {f['pk']} | {f['resultado']} | {f['d']} |")
    return finalizar(inf, a.informe, 0 if ok else 1)


def finalizar(inf, ruta, codigo):
    if ruta:
        with open(ruta, "w", encoding="utf-8") as fh:
            fh.write("\n".join(inf) + "\n")
    return codigo


if __name__ == "__main__":
    sys.exit(main())
