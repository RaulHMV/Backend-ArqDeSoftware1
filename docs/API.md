# API Reference — Ticket System

API serverless en AWS (API Gateway HTTP + WebSocket). Esta guía es para el equipo
de frontend: cómo autenticarse, qué endpoints existen y qué body/response usan.

## URLs base (deploy actual — prod)

- **REST (HTTP API):** `https://8ic60mz311.execute-api.us-east-1.amazonaws.com`
- **WebSocket:** `wss://frr4uakqw2.execute-api.us-east-1.amazonaws.com/prod`
- `cognito_pool_id`, `cognito_client_id` → para el login (ver outputs de Terraform).

> Si se vuelve a desplegar en otra cuenta/region, estas URLs cambian. Los valores
> siempre salen en los outputs de Terraform (`http_api_url`, `ws_api_url`).

## Autenticación

1. El usuario hace login contra **Cognito** (User Pool `cognito_pool_id`, app client
   `cognito_client_id`, sin secret). Flujo recomendado: `USER_SRP_AUTH` (Amplify/SDK)
   o `USER_PASSWORD_AUTH` para pruebas.
2. Cognito devuelve un **ID token** (JWT). Ese token es el que se manda a la API.
3. En cada request REST agrega el header:

   ```
   Authorization: Bearer <ID_TOKEN>
   ```

   El authorizer JWT valida `audience = cognito_client_id`, por eso se usa el **ID token**
   (no el access token).
4. El rol sale de los grupos de Cognito (`Requester`, `Agent`, `Manager`, `Admin`) y el
   área del atributo `custom:areaId`. Al registrarse, un trigger crea el usuario y lo
   mete al grupo `Requester` automáticamente.

### Formato de respuestas

- Éxito: el objeto directo (ej. el ticket) o `{ "items": [...], "nextCursor": ... }` en listados.
- Error: `{ "error": "mensaje" }` con status 400/401/403/404/500.

---

## Endpoints REST

Todos requieren el header `Authorization`. La columna **Rol** indica quién puede usarlo.

| Método | Ruta | Rol | Descripción |
|--------|------|-----|-------------|
| POST | `/tickets` | cualquiera | Crear ticket |
| GET | `/tickets` | cualquiera | Listar (según rol) |
| GET | `/tickets/{id}` | cualquiera* | Ver un ticket |
| PUT | `/tickets/{id}` | Agent/Manager/Admin | Actualizar estado/asignación |
| GET | `/tickets/{id}/comments` | cualquiera | Listar comentarios |
| POST | `/tickets/{id}/comments` | cualquiera | Agregar comentario |
| POST | `/attachments/presign` | cualquiera | URL prefirmada para subir archivo |
| GET | `/attachments/download` | cualquiera | URL prefirmada para descargar |
| GET | `/users/me` | cualquiera | Mi perfil |
| GET | `/users` | Manager/Admin | Usuarios de un área |
| POST | `/users` | Admin | Alta/edición de usuario |
| GET | `/areas` | cualquiera | Listar áreas |
| POST | `/areas` | Admin | Crear área |

\* El Requester solo puede ver tickets que él creó.

### POST /tickets
Body:
```json
{
  "title": "No imprime la impresora",
  "description": "La impresora del piso 3 no responde",
  "areaId": "IT",
  "category": "HARDWARE",
  "priority": "HIGH"
}
```
- Obligatorios: `title`, `description`, `areaId`.
- Opcionales: `category` (default `GENERAL`), `priority` (`LOW|MEDIUM|HIGH|CRITICAL`, default `MEDIUM`).
- Respuesta `201`: el ticket completo (incluye `ticketId`, `number`, `state: "NEW"`, etc.).

### GET /tickets
Query params según rol:
- **Requester**: sin params → sus propios tickets.
- **Agent**: `?state=IN_PROGRESS` (default) → tickets asignados a él en ese estado.
- **Manager/Admin**: `?areaId=IT` (o usa su `custom:areaId`), opcional `?state=NEW`.
- Común: `?limit=25` (máx 100).
- Respuesta: `{ "items": [...], "nextCursor": null|objeto }`.

### GET /tickets/{id}
- Respuesta `200`: el ticket. `404` si no existe, `403` si un Requester pide ajeno.

### PUT /tickets/{id}
Body (todos opcionales, manda lo que cambies):
```json
{
  "state": "IN_PROGRESS",
  "assignedToId": "<userId>",
  "assignedToName": "Juan Pérez",
  "resolutionNotes": "Se reinició el spooler",
  "reason": "Tomado por soporte"
}
```
- `state`: `NEW|ASSIGNED|IN_PROGRESS|RESOLVED|CLOSED`.
- Si cambia el estado se guarda un registro de auditoría (STATUSCHANGE).
- Respuesta `200`: el ticket actualizado.

### GET /tickets/{id}/comments
- Respuesta: `{ "items": [...] }` (orden cronológico).

### POST /tickets/{id}/comments
Body:
```json
{ "content": "Ya lo estoy revisando", "type": "PUBLIC", "mentions": [] }
```
- Obligatorio: `content`. `type`: `PUBLIC` (default) o `INTERNAL`.
- Respuesta `201`: el comentario. Incrementa `commentCount` del ticket.

### POST /attachments/presign
Body:
```json
{
  "ticketId": "<ticketId>",
  "fileName": "captura.png",
  "mimeType": "image/png",
  "size": 12345,
  "commentId": "<opcional>"
}
```
- Obligatorios: `ticketId`, `fileName`, `mimeType`. `mimeType` debe estar en la lista permitida.
- Respuesta `201`: `{ "attachmentId", "key", "uploadUrl", "expiresIn": 300 }`.
- **Luego** el frontend hace `PUT uploadUrl` con el binario y header `Content-Type: <mimeType>`.

### GET /attachments/download
Query: `?ticketId=<id>&attachmentId=<id>`.
- Respuesta: `{ "downloadUrl", "fileName", "expiresIn": 300 }`.

### GET /users/me
- Respuesta: el perfil del usuario autenticado.

### GET /users
Query: `?areaId=IT` (o usa el área del manager). Solo Manager/Admin.
- Respuesta: `{ "items": [...] }`.

### POST /users
Body:
```json
{
  "userId": "<sub de Cognito>",
  "email": "agente@empresa.com",
  "role": "AGENT",
  "fullName": "Agente Uno",
  "areaId": "IT"
}
```
- Obligatorios: `userId`, `email`, `role`. Sincroniza el grupo y `custom:areaId` en Cognito.
- Solo Admin. Respuesta `201`: el usuario.

### GET /areas
- Respuesta: `{ "items": [...] }`.

### POST /areas
Body:
```json
{ "name": "Tecnología", "areaId": "IT", "description": "Soporte técnico", "managerId": null }
```
- Obligatorio: `name`. `areaId` opcional (si no, se genera UUID). Solo Admin.

---

## WebSocket (tiempo real)

URL del deploy actual:
```
wss://frr4uakqw2.execute-api.us-east-1.amazonaws.com/prod?token=<ID_TOKEN>
```

### Conexión (handshake)
- El **ID token** de Cognito va SIEMPRE en el **query string** (`?token=`), porque el
  handshake del WebSocket no admite headers. Lo valida un Lambda Authorizer
  (`tokenUse=id`). Sin token o inválido → la conexión se rechaza (Deny).
- Al conectar, la conexión se guarda en `WSConnections` asociada a tu `userId`,
  `email` y `areaId` (sacado de `custom:areaId`), con TTL de **2 horas**.

### Heartbeat (mantener viva la conexión)
Envía por la ruta `sendMessage`:
```json
{ "action": "sendMessage" }
```
El servidor renueva el TTL (otras 2h) y responde:
```json
{ "type": "pong", "ts": 1750000000 }
```
Recomendado mandarlo cada ~5-10 min. Si no, la conexión expira sola por TTL.

### Eventos push (te llegan solos, no los pides)
Disparados por DynamoDB Streams cuando algo cambia en la base.

**Ticket creado/actualizado** → a **todas las conexiones del área** del ticket:
```json
{
  "type": "TICKET",
  "event": "INSERT",            // o "MODIFY"
  "ticketId": "uuid",
  "number": "TKT-2026-0001",
  "title": "No imprime la impresora",
  "state": "NEW",              // NEW|ASSIGNED|IN_PROGRESS|RESOLVED|CLOSED
  "priority": "HIGH",          // LOW|MEDIUM|HIGH|CRITICAL
  "areaId": "IT"
}
```

**Comentario nuevo** → al **requester + asignado + área** del ticket (deduplicado):
```json
{
  "type": "COMMENT",
  "event": "INSERT",           // o "MODIFY"
  "ticketId": "uuid",
  "commentId": "uuid",
  "authorName": "agente@empresa.com",
  "preview": "primeros 140 caracteres del comentario..."
}
```

### Reglas de entrega
- Solo recibes eventos de **tu área** (por el `custom:areaId` del token). En
  comentarios, además te llegan si eres el **requester** o el **asignado** del ticket.
- Conexiones muertas (`410 Gone`) se borran solas de la tabla al intentar enviarles.

### Cómo probar
- **Bruno**: abre `WebSocket / Conectar WebSocket` (ya arma `{{wsUrl}}?token={{idToken}}`),
  dale **Connect**, manda `{"action":"sendMessage"}` para ver el `pong`. Deja la conexión
  abierta y crea un ticket REST en esa misma área para ver llegar el evento `TICKET`.
- **Terminal** (websocat):
  ```bash
  websocat "wss://frr4uakqw2.execute-api.us-east-1.amazonaws.com/prod?token=<ID_TOKEN>"
  # luego escribe:  {"action":"sendMessage"}
  ```

---

## Cómo probar en Bruno

En la carpeta `bruno/` hay una colección lista. Pasos:
1. Abre Bruno → **Open Collection** → elige la carpeta `ticket-system/bruno`.
2. Selecciona el environment **prod** y llena las variables:
   - `baseUrl` = el `http_api_url` del deploy.
   - `wsUrl` = el `ws_api_url`.
   - `idToken` = el ID token que te dé Cognito al hacer login.
3. Empieza por `Areas / Crear área` (como Admin) y `Tickets / Crear ticket`.
