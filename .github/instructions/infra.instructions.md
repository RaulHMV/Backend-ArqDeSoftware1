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
