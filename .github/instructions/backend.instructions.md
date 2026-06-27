---
applyTo: "backend/**"
description: "Contexto del backend Node/TS (handlers, lib, convenciones ESM, DynamoDB single-table)."
---

# Backend — Ticket System

Node 20 + TypeScript (ESM). Bundle con esbuild (`esbuild.config.mjs`) →
`dist/<handler>/index.js` (cjs, node20). Terraform empaqueta esos dist.

## Convenciones
- ESM: imports con extensión `.js` (ej. `from "../lib/ddb.js"`).
- Respuestas SIEMPRE vía helpers de `src/lib/response.ts` (incluyen CORS):
  `ok/created/badRequest/unauthorized/forbidden/notFound/serverError`.
- Auth vía `getAuth(event)` y `hasRole(...)` de `src/lib/auth.ts`
  (lee claims JWT, `cognito:groups`, deriva role).
- IDs/tiempo vía `src/lib/ids.ts`: `newId()`, `now()` (epoch s),
  `nextTicketNumber()` (folio atómico con `COUNTER#TICKET#<year>` + UpdateItem ADD).
- WebSocket vía `src/lib/ws.ts`: `postToConnection` (maneja 410 Gone borrando
  conexión muerta) y `broadcast` (allSettled).
- S3 vía `src/lib/s3.ts`: `presignPut`/`presignGet`, valida ALLOWED_MIME y MAX_UPLOAD_BYTES.
- SSM vía `src/lib/ssm.ts`: `getParam` (cacheado).
- Tipos en `src/types/index.ts`: Role, TicketState, Priority, AuthContext, TicketInput.

## Env vars (común)
MAIN_TABLE, WS_TABLE, ATTACHMENTS_BUCKET, APP_REGION, COGNITO_POOL_ID, COGNITO_CLIENT_ID,
SSM_PREFIX, WS_ENDPOINT_PARAM, MAX_UPLOAD_BYTES.

## Modelo de datos (DynamoDB single-table `TicketsSystem`)
- PK/SK. GSIs: GSI1 (area+state), GSI2 (requester), GSI3 (assigned, sparse KEYS_ONLY),
  GSI4 (area dual: tickets + users).
- Tabla aparte `WSConnections` (TTL en expirationTime): GSIByArea, GSIByUser.
- Listado por rol en tickets: requester→GSI2, agent→GSI3, manager/admin→GSI4.

## Handlers (src/handlers)
- REST: `tickets` (CRUD + audit STATUSCHANGE), `comments` (commentCount atómico),
  `attachments` (presign up/down, validación MIME/size), `users`, `areas`.
- WebSocket: `ws-authorizer` (CognitoJwtVerifier tokenUse id, token en query string),
  `ws-connect` (TTL 2h), `ws-disconnect`, `ws-message` (heartbeat en ruta `sendMessage`:
  renueva TTL y responde `{type:"pong"}`; endpoint del contexto del evento).
- Eventos: `notifications-dispatch` (DynamoDB Streams → query GSIByArea/GSIByUser → broadcast;
  endpoint WS desde SSM), `cognito-postconfirmation` (crea item USER + grupo Requester).

## Comandos
`npm install` · `npm run typecheck` · `npm run build` (genera dist).
