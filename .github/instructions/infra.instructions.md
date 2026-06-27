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
