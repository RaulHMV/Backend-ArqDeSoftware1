---
applyTo: "infra/**"
description: "Contexto de la infraestructura Terraform (módulos, stack, env prod, gotchas de ciclos)."
---

# Infra — Ticket System (Terraform)

## Estructura
- `bootstrap/`: SOLO remote state (bucket S3 versionado/cifrado + tabla lock DynamoDB).
  YA ejecutado. NO crea OIDC ni roles (decisión: llaves estáticas).
- `modules/`: dynamodb, lambda (genérico, archive_file + source_code_hash),
  cognito, apigw-http (JWT authorizer), apigw-websocket (Lambda Authorizer REQUEST),
  s3-attachments, `stack` (composición que cablea todo).
- `environments/prod/`: ÚNICO env (no hay dev). `backend.tf` (state S3) + `main.tf`
  (llama al módulo stack con env="prod", backend_dist_path a backend/dist).

## State backend
- bucket `ticketsys-tfstate-020379956700`, key `prod/terraform.tfstate`,
  region us-east-1, lock table `ticketsys-tf-locks`, encrypt=true.

- `environments/pg-multimaster/`: stack APARTE (no toca el serverless). 2 EC2 t3.micro en
  2 AZs, SG con reglas como recursos separados (nada inline), llave ED25519 vía
  `tls_private_key`. State: mismo bucket/lock, key `pg-multimaster/terraform.tfstate`.
  `ami` va en `ignore_changes` a propósito (evita reemplazar los nodos y perder datos).
- `ansible/`: playbook Postgres 16 maestro-maestro (replicación lógica, `origin = none`).
  El inventario se genera en el workflow con `make_inventory.py` desde `terraform output`.

- `environments/mysql-multimaster/` + `ansible/mysql/`: mismo patrón para MySQL 8.0
  (puerto 3306, key `mysql-multimaster/terraform.tfstate`). Replicación binlog + GTID
  con `SOURCE_AUTO_POSITION`. En MySQL el DDL SÍ se replica: usuario y esquema se crean
  en cada nodo con `sql_log_bin = 0`. La 1a vez hace `RESET MASTER` (binlog de la
  instalación sin GTID). Usa la colección `ansible.mysql` (community.mysql 5 solo redirige).

- `environments/mysql-replica/` + `ansible/mysql-replica/`: maestro-esclavo configurado MAL a
  propósito (esclavo escribible, sin GTID, por posición) en `playbook.yml`, y kit de rescate
  en `rescate.yml`: `files/rescate_binlog.py` (lee el binlog del esclavo con mysql-replication,
  filtra por server_id, mapea columnas por posición porque binlog_row_metadata=MINIMAL) +
  `templates/ops_rescate.sql.j2` (`ops.reconciliar()` compara la imagen "antes" con el maestro,
  aplica con sql_log_bin=0, conflictos -> gana el maestro). Réplica se pone al día en modo
  IDEMPOTENT y vuelve a STRICT; verificación con CHECKSUM TABLE. Probado con y sin GTID.
  Gotchas probados: comparar JSON vía variable local tipada (no `@var`), TIMESTAMP en UTC,
  JSON_VALUE corta a 512 chars (se usa JSON_EXTRACT).

- `environments/mysql-gr/` + `ansible/mysql-gr/`: Group Replication multi-primary, 4 EC2
  (una por AZ si alcanzan; `element()` da la vuelta), SG con 3306 y 33061 solo entre nodos.
  `templates/gr.cnf.j2` (message_cache 128 MB por la t3.micro, auto_increment 4/offset N).
  Playbook: usuario `rpl` local con sql_log_bin=0, bootstrap SOLO en node_a si no hay grupo
  ONLINE, los demás se unen `serial: 1`, `SET PERSIST start_on_boot=ON` al quedar ONLINE.
  Gotchas probados: tras un apagón total los nodos quedan en super_read_only (se abre solo
  para crear el usuario y se cierra en `always`); XCom abre el puerto en TODAS las IPs (por
  eso las semillas usan el `gr_port` de cada host); nunca dejar bootstrap_group=ON.

- `environments/pg-mesh/` + `ansible/pg-mesh/`: Postgres 16, 4 maestros en malla completa de
  replicación lógica (cada nodo publica `mensajes` y se suscribe a los otros 3: 12
  suscripciones, `origin = none`, `copy_data = false`). 4 EC2 como mysql-gr (`element()`),
  SG solo con 5432 entre nodos, swap 2 GB. Secuencia por nodo START index+1 INCREMENT 4.
  `CREATE SUBSCRIPTION` con `throttle: 1` (en paralelo hay deadlock distribuido al crear slots).
  Play final: cada nodo inserta su saludo y se espera que los 4 vean los 4.
  Probado en local con 4 Postgres 16.15 (`pg_port` y `pg_socket_dir` por host para correr
  varios en una máquina). Límite probado: dos nodos editando la MISMA fila a la vez divergen
  (PG16 no detecta conflictos; a diferencia de Group Replication).

- `environments/do-sshd/` + `ansible/do-sshd/`: DigitalOcean (provider digitalocean, token por env
  `DIGITALOCEAN_TOKEN`), SIN backend remoto: el workflow busca el droplet por tag `SSHD_Conexion`
  (nombre `SSHD-Conexion`: DO no acepta `_` en nombres). Rocky Linux 9 (`rockylinux-9-x64`),
  firewall de DO solo `my_ip` en `ssh_port` (default 3947; NINGUN digito 2, regla del profe). Playbook: usuario de MINIMO
  PRIVILEGIO (solo su grupo, sin sudo, password "!"); root solo con `su -` + `ROOT_PASSWORD`, y
  `pam_wheel.so use_uid group=<usuario>` en /etc/pam.d/su (cuenta el grupo primario, probado);
  Ansible re-entra como el usuario con `become_method: su`. Llave RSA 4096 exclusiva en
  `AuthorizedKeysFile /etc/ssh/authorized_keys/%u` (root, 0644: sshd la lee como el usuario;
  etc_t) + Google Authenticator (EPEL), `LoginGraceTime 60` (con 30 + PerSourcePenalties de
  OpenSSH 9.9 el humano quedaba bloqueado), `AuthenticationMethods
  publickey,keyboard-interactive`, PAM sin common-auth (solo pam_google_authenticator) +
  pam_access, sin Include de sshd_config.d, `RequiredRSASize 4096` (regenera la host key RSA a
  4096 ANTES del template), `semanage port` para ssh_port_t, sshd se reinicia al final.
  Swap de 2 GB (dd) ANTES de cualquier dnf: con 1 GB, dnf + EPEL muere por OOM (rc -9).
  Secreto OTP en ruta propia de root: `/var/lib/sshd_otp/<usuario>.totp` (0700/0400), PAM con
  `secret=/var/lib/sshd_otp/${USER}.totp user=root` (con `user=` el dueno debe ser ese usuario).
  Gotchas probados: con SELinux sshd no puede reescribir el secreto en `~` (crea un temporal y
  renombra); la carpeta se etiqueta `var_auth_t` con `semanage fcontext` (sshd_t/login_pgm puede
  crear/renombrar ahi, verificado con sesearch en la politica de Rocky 9); `mlkem768x25519-sha256`
  no lo acepta el sshd de Rocky; re-runs entran como el usuario con el codigo de
  `files/totp.py` via el askpass de Ansible (`ansible_sshpass_prompt: "Verification code:"`).

## Stack (modules/stack) — puntos clave
- DynamoDB main (PK/SK, 4 GSIs, Streams NEW_AND_OLD_IMAGES, PITR en prod) + WSConnections.
- Cognito (email username, `custom:areaId`, grupos Requester/Agent/Manager/Admin,
  trigger PostConfirmation).
- 11 Lambdas vía for_each (handlers map). API HTTP (13 rutas) + API WebSocket (3 rutas).
- SSM param `/ticketsys/<env>/ws_management_endpoint`. Event source mapping del Stream
  (filtro INSERT/MODIFY) → notifications-dispatch.

## Gotchas (rompimiento de ciclos)
- `lambda_postconf` se crea ANTES que cognito (toma el pool del evento del trigger).
- `ws-message` arma el endpoint desde el contexto del evento (sin env var).
- `notifications-dispatch` lee el endpoint WS de SSM en runtime.
- Permisos ManageConnections y cognito-admin se adjuntan como `aws_iam_role_policy`
  SEPARADOS, después de crear apigw/cognito.
- apigw-http NO usa integration_method (AWS_PROXY no lo necesita).

## Reglas
- Terraform corre SOLO en GitHub Actions, nunca local.
- NO reintroducir OIDC, roles de deploy, GitHub Environments ni un env dev
  salvo petición explícita del usuario.
