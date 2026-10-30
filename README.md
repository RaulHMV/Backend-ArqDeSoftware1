# Ticket System (clon básico de ServiceNow)

Backend serverless en AWS: API REST + WebSocket en tiempo real, autenticación con
Cognito, datos en DynamoDB single-table, adjuntos en S3. Todo se despliega desde
GitHub Actions con Terraform. Sin servidores que administrar.

## Arquitectura (resumen)

- **API Gateway HTTP** → Lambdas (Node 20) → DynamoDB / S3
- **API Gateway WebSocket** → notificaciones en vivo (tickets y comentarios)
- **Cognito** User Pool (roles: Requester, Agent, Manager, Admin)
- **DynamoDB** tabla única `TicketsSystem` (+ `WSConnections` con TTL), Streams
  disparan la Lambda de notificaciones
- **S3** adjuntos con subida/descarga por URL prefirmada
- **Terraform** state en S3 + lock en DynamoDB

```
infra/        Terraform (bootstrap, modules, environments/prod)
backend/      Node + TypeScript (esbuild) → dist/<lambda>/index.js
.github/      Workflows: bootstrap, pr-check, deploy
```

---


### 1. Correr el bootstrap (una sola vez)

Crea el remote state (bucket S3 + tabla de lock) que el deploy necesita.

GitHub → Actions → **bootstrap** → Run workflow:
1. Primero con input `plan` para revisar.
2. Luego otra vez con `apply`.

### 2. Desplegar (manual, eliges la rama)

El deploy **nunca corre solo**. GitHub → Actions → **deploy** → Run workflow:

1. En **"Use workflow from"** elige la rama desde la que quieres correr el pipeline.
2. En **action** elige `plan` (solo previsualiza los cambios) o `apply` (despliega).
3. Si elegiste `apply`, escribe `deploy` en el campo **confirm** (seguro anti-clics).

El job compila las Lambdas y corre Terraform en `infra/environments/prod`.
Al final, en los outputs verás `api_endpoint`, `ws_endpoint`, `cognito_pool_id` y
`cognito_client_id` para conectar tu frontend.

---

## PostgreSQL maestro-maestro en 2 EC2 (stack aparte)

Stack independiente del backend serverless: 2 EC2 (Ubuntu 24.04, `t3.micro`) con
PostgreSQL 16 y replicación lógica bidireccional. Terraform crea las máquinas
(`infra/environments/pg-multimaster`, state propio) y Ansible configura Postgres
(`infra/ansible`).

1. Crea el secret **`POSTGRES_PASSWORD`** (mín. 12 caracteres, solo `A-Za-z0-9_.-`) y la
   variable **`SSH_PUBLIC_KEY`** (contenido de tu `~/.ssh/id_ed25519.pub`, para entrar por
   SSH como `ubuntu`). Usa los mismos `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y
   `AWS_REGION` de siempre.
2. Actions → **pg-deploy** → `plan` para revisar, luego `apply` con `deploy` en **confirm**.
3. Al terminar, el resumen del run trae las IPs de los nodos. Cada nodo escribe local y
   replica al otro (`node_a` genera IDs impares, `node_b` pares).
4. Actions → **pg-destroy** (`destroy` en confirm) cuando termines: las EC2 facturan
   mientras existan y se pierden los datos.

---

## MySQL maestro-maestro en 2 EC2 (stack aparte)

Igual que el de Postgres pero con MySQL 8.0 (replicación por binlog con GTID, cada
nodo es réplica del otro). Terraform en `infra/environments/mysql-multimaster` (state
propio) y Ansible en `infra/ansible/mysql`.

1. No necesitas nada nuevo: usa el **mismo** `POSTGRES_PASSWORD` y la **misma**
   `SSH_PUBLIC_KEY` del stack de Postgres (más las llaves de AWS de siempre).
2. Actions → **mysql-deploy** → `plan`, luego `apply` con `deploy` en **confirm**.
3. Entra con `ssh ubuntu@<IP>` (IPs en el resumen del run) y luego `sudo mysql demo`.
   `node_a` genera IDs impares y `node_b` pares.
4. Actions → **mysql-destroy** (`destroy` en confirm) al terminar.

> Con los dos stacks arriba son **4 EC2**: el free tier (750 h/mes) no alcanza para
> tenerlas todas prendidas todo el mes. Levanta solo el que vayas a usar.

---

## MySQL maestro-esclavo MAL HECHO + rescate (stack aparte)

Simula la réplica de producción que **ya estaba mal configurada** y cómo arreglarla
**sin borrar ni reclonar nada**.

1. Actions → **mysql-replica-deploy** (`apply` + `deploy`): maestro con 1000 clientes y un
   esclavo configurado "de tutorial": **acepta escrituras**, sin GTID, sin protección.
2. Simula el problema: en el **esclavo** haz INSERT/UPDATE/DELETE en `demo.clientes`
   (si cambias las mismas filas en el maestro, la réplica truena).
3. Actions → **mysql-replica-rescate**:
   - `diagnostico`: lista lo que se escribió en el esclavo y qué pasaría con cada cambio.
   - `rescatar` (confirm `rescatar`): lee el **binlog del esclavo** (guarda cada fila antes y
     después), aplica en el maestro lo que nadie más tocó, registra los conflictos (gana el
     maestro), corrige solo esas filas en el esclavo, revive la réplica y verifica con
     checksum que ambos quedan iguales. Con `bloquear=si` deja el esclavo en solo lectura.
4. Resultados en el maestro: `SELECT * FROM ops.rescate;` y `SELECT * FROM ops.incidentes;`.
5. **mysql-replica-destroy** al terminar.

Usa el mismo `POSTGRES_PASSWORD` y `SSH_PUBLIC_KEY` que los otros stacks.

---

## MySQL Group Replication: 4 maestros (stack aparte)

4 EC2 con MySQL 8.0 en **Group Replication multi-primary**: los 4 aceptan escrituras y,
antes de confirmar cada transacción, el grupo revisa si otro nodo tocó las mismas filas.
Si sí, el segundo `COMMIT` falla (la app reintenta) y **los datos nunca divergen**.

1. Actions → **mysql-gr-deploy** (`plan`, luego `apply` + `deploy`). Mismo `POSTGRES_PASSWORD`
   y `SSH_PUBLIC_KEY` de siempre.
2. Entra a cualquier nodo: `ssh ubuntu@<IP>` y `sudo mysql demo`. IDs: el maestro N genera
   números con `id mod 4 = N` (incremento 4).
3. Para ver el grupo: `SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;`
4. **mysql-gr-destroy** al terminar (son 4 EC2 facturando).

Límites a saber:
- Funciona con **mayoría** (3 de 4): aguanta 1 nodo caído; si la red se parte 2 y 2 se
  bloquean las escrituras (por eso MySQL recomienda 3 o 5 nodos).
- Todas las tablas necesitan PK, solo InnoDB, sin FKs con `CASCADE`.
- Si se apagan los 4, volver a correr `mysql-gr-deploy` (`apply`) reconstruye el grupo
  desde `node_a`.

---

## PostgreSQL en malla: 4 maestros (stack aparte)

4 EC2 con PostgreSQL 16, todos maestros. Es la misma replicación lógica nativa del stack de
2 nodos, pero en **malla completa**: cada nodo publica su tabla y se suscribe directo a los
otros 3 (12 suscripciones). Con `origin = none` cada cambio llega una sola vez a los demás y
no rebota.

1. Actions → **pg-mesh-deploy** (`plan`, luego `apply` + `deploy`). Mismo `POSTGRES_PASSWORD`
   y `SSH_PUBLIC_KEY` de siempre.
2. Entra a cualquier nodo: `ssh ubuntu@<IP>` y `sudo -u postgres psql demo`. Ya hay un
   `hola desde node_x` de cada nodo en `mensajes` (el deploy lo usa como prueba). IDs:
   `node_a` 1, 5, 9…, `node_b` 2, 6, 10…, `node_c` 3, 7, 11…, `node_d` 4, 8, 12…
3. Para ver la malla: `\dRs` (3 suscripciones) y `SELECT slot_name, active FROM pg_replication_slots;`
   (3 slots: los otros nodos leyendo de este).
4. **pg-mesh-destroy** al terminar (son 4 EC2 facturando).

Límites a saber:
- **No hay detección de conflictos**: si dos nodos editan la MISMA fila al mismo tiempo, cada
  uno se queda con la versión del otro y divergen. Los INSERT no chocan gracias a las secuencias.
- Si un nodo se cae los otros 3 siguen, y al volver se pone al día solo (los demás le guardan
  el WAL mientras tanto).
- El DDL (`CREATE`/`ALTER TABLE`) no se replica: hay que aplicarlo en los 4 nodos.

---

## Droplet SSHD-Conexion: SSH endurecido en DigitalOcean (stack aparte)

Un droplet **Rocky Linux 9** en DigitalOcean con SSH + PAM endurecidos. Terraform crea el droplet
y el firewall (`infra/environments/do-sshd`) y Ansible hace el hardening (`infra/ansible/do-sshd`):

- Solo entra **tu usuario**, con **tu llave RSA 4096 y el código de Google Authenticator**.
  root no entra y el password de Unix no sirve por SSH (es solo para `sudo`).
- SSH en el puerto **3947** (configurable, sin ningún `2`: nunca el 22) y el firewall de DigitalOcean solo
  deja llegar **desde tu IP pública**.
- El secreto de Google Authenticator **no** está en la ruta por defecto (`~/.google_authenticator`):
  vive en `/var/lib/sshd_otp/<usuario>.totp`, de root. El usuario entra normal pero no puede
  leer su propio secreto (solo con `sudo`).
- Banner de acceso restringido, SELinux en enforcing, criptografía moderna, y sshd/PAM sin
  las opciones que no se usan (forwarding, X11, GSSAPI, motd, etc.).

> DigitalOcean no acepta `_` en nombres de droplet: se llama `SSHD-Conexion` y lleva el
> tag `SSHD_Conexion`.

1. Crea los secrets del repo: `DIGITALOCEAN_TOKEN`, `SSH_PRIVATE_KEY` (tu llave privada RSA 4096
   completa), `SSH_KEY_PASSPHRASE` (si tu llave tiene frase), `SUDO_PASSWORD` (12+ caracteres) y
   `TOTP_SECRET` (secreto base32 que también registras en Google Authenticator).
2. Actions → **sshd-deploy** → `plan`, luego `apply` + `deploy` en confirm, con tu IP en
   `mi_ip` (la ves en https://ifconfig.me). El job prueba al final que root no entra, que la
   llave sola no basta, que el 22 está cerrado y que llave + código + sudo sí funcionan.
3. Conéctate con lo que diga el resumen del run, p. ej.
   `ssh -i ~/.ssh/sshd_conexion -p 3947 operador@<IP>` (te pide el código de 6 dígitos).
4. **sshd-destroy** al terminar (el droplet se cobra por hora).

Sin state remoto (gratis): el workflow encuentra el droplet por su tag. Si ya existe, solo
vuelve a aplicar el hardening (entra con tu usuario y el código). Si tu IP de casa cambió,
corre `apply` de nuevo con la nueva y se actualiza el firewall.

---

## Desarrollo local del backend

```bash
cd backend
npm install
npm run typecheck   # revisa tipos
npm run build       # genera dist/<lambda>/index.js (lo que Terraform empaqueta)
```

No necesitas correr Terraform localmente; todo el infra va por GitHub Actions.
