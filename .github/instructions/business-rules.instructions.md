---
applyTo: "**"
description: "Reglas de negocio del sistema de tickets (dominio, roles, estados, validaciones, side-effects, modelo de datos). Lectura obligada para entender QUÉ hace el sistema."
---

# Reglas de negocio — Ticket System (estilo ServiceNow)

Sistema de tickets serverless multi-área con roles. Este archivo describe el
DOMINIO y las REGLAS exactas (validaciones, defaults, permisos, transiciones,
efectos colaterales). Los valores aquí son los que el código realmente aplica;
si cambias una regla, actualiza este archivo.

## Glosario de entidades
- **Ticket**: solicitud/incidencia. Pertenece a un **área** y tiene un **requester** (quien lo crea).
- **Comment**: comentario en un ticket (público o interno).
- **Attachment**: archivo adjunto a un ticket o a un comentario.
- **User**: perfil de usuario espejo de Cognito (rol + área).
- **Area**: departamento/cola de atención (ej. IT, RH).
- **STATUSCHANGE**: registro de auditoría de cada cambio de estado de un ticket.

## Enums oficiales (única fuente de verdad)
- **Role**: `REQUESTER` < `AGENT` < `MANAGER` < `ADMIN` (jerarquía por privilegio).
- **TicketState**: `NEW` · `ASSIGNED` · `IN_PROGRESS` · `RESOLVED` · `CLOSED`.
- **Priority**: `LOW` · `MEDIUM` · `HIGH` · `CRITICAL`.
- **CommentType**: `PUBLIC` · `INTERNAL`.
- **Category**: texto libre; default `GENERAL` (no es enum cerrado).

## Roles y cómo se asignan
- Los roles son **grupos de Cognito**: `Requester`, `Agent`, `Manager`, `Admin` (4 grupos).
- El backend deriva el rol efectivo del **grupo de mayor privilegio** del usuario
  (`auth.role`). Si no tiene grupo válido → `REQUESTER`.
- El **área** del usuario va en el atributo custom `custom:areaId` (NO es un grupo).
- Al confirmar el registro (PostConfirmation), todo usuario nuevo entra automáticamente
  al grupo `Requester` y se le crea su item `USER` con `role=REQUESTER`, `areaId=null`.
- Solo un **ADMIN** puede cambiar el rol/área de otros (`POST /users`), lo cual
  sincroniza el grupo de Cognito y `custom:areaId`.

## Matriz de permisos por endpoint
| Acción | REQUESTER | AGENT | MANAGER | ADMIN |
|---|:--:|:--:|:--:|:--:|
| Crear ticket (`POST /tickets`) | ✅ | ✅ | ✅ | ✅ |
| Listar tickets (`GET /tickets`) | solo propios | asignados a él | de su área | de su área |
| Ver ticket (`GET /tickets/{id}`) | solo propios | ✅ | ✅ | ✅ |
| Actualizar ticket (`PUT /tickets/{id}`) | ❌ 403 | ✅ | ✅ | ✅ |
| Comentar PUBLIC | ✅ | ✅ | ✅ | ✅ |
| Comentar INTERNAL | ✅* | ✅ | ✅ | ✅ |
| Adjuntar/descargar archivos | ✅ | ✅ | ✅ | ✅ |
| `GET /users/me` | ✅ | ✅ | ✅ | ✅ |
| Listar usuarios (`GET /users`) | ❌ 403 | ❌ 403 | ✅ | ✅ |
| Crear/editar usuario (`POST /users`) | ❌ | ❌ | ❌ | ✅ |
| Listar áreas (`GET /areas`) | ✅ | ✅ | ✅ | ✅ |
| Crear área (`POST /areas`) | ❌ | ❌ | ❌ | ✅ |

\* El backend hoy NO bloquea que un REQUESTER mande `type=INTERNAL`; el filtrado de
visibilidad de comentarios internos es responsabilidad del frontend. Si esto debe
ser una regla dura, hay que implementarla en `comments.ts`.

## Reglas de TICKETS
**Crear (`POST /tickets`)**
- Obligatorios: `title`, `description`, `areaId`.
- Opcionales: `category` (default `GENERAL`), `priority` (default `MEDIUM`).
- `priority` se valida contra el enum; valor inválido → 400.
- Estado inicial SIEMPRE `NEW` (no es configurable por el cliente).
- Se autogenera el folio `number` = `TKT-<año>-<NNNN>` (4 dígitos, contador atómico
  por año → único aun con concurrencia).
- `requesterId/Name/Email` se toman del token; `assignedTo*` arranca en `null`;
  contadores `commentCount/worklogCount/attachmentCount` arrancan en `0`.

**Listar (`GET /tickets`)** — la query cambia según el rol:
- REQUESTER → GSI2: solo sus tickets.
- AGENT → GSI3: tickets asignados a él filtrados por `?state` (default `IN_PROGRESS`).
- MANAGER/ADMIN → GSI4: por `?areaId` (default su `custom:areaId`); `?state` opcional.
  Si no hay área resoluble → 400 `areaId requerido`.
- `limit` default 25, máximo 100.

**Ver (`GET /tickets/{id}`)**
- REQUESTER solo puede ver tickets donde `requesterId == su sub`; si no → prohibido.
- AGENT/MANAGER/ADMIN ven cualquiera.

**Actualizar (`PUT /tickets/{id}`)**
- Solo AGENT/MANAGER/ADMIN (REQUESTER → 403).
- Campos editables: `state`, `assignedToId`, `assignedToName`, `resolutionNotes`.
- `state` se valida contra el enum.
- Cada cambio de estado escribe un item de auditoría `STATUSCHANGE` con
  `fromState`, `toState`, `changedBy`, `reason` (opcional del body).
- `RESOLVED` agrega `resolvedAt`; `CLOSED` agrega `closedAt`.
- Nota: hoy NO se valida una máquina de estados estricta (cualquier estado→estado
  válido del enum es aceptado). Las transiciones "lógicas" las cuida el frontend.

## Reglas de COMMENTS
- Listar: `GET /tickets/{id}/comments`, orden ascendente (más viejos primero).
- Crear: obligatorio `content`; opcionales `type` (default `PUBLIC`) y `mentions` (default `[]`).
- Efecto colateral atómico: incrementa `commentCount` del ticket y actualiza su `updatedAt`.
- Se guarda `authorRole` (rol del autor al momento de comentar).

## Reglas de ATTACHMENTS
- Subir es en 2 pasos: (1) `POST /attachments/presign` devuelve `uploadUrl`;
  (2) el cliente hace `PUT` del binario a esa URL con `Content-Type = mimeType`.
- Presign obligatorios: `ticketId`, `fileName`, `mimeType`. Opcionales: `commentId`, `size`.
- El ticket debe existir; si no → error.
- `mimeType` debe estar en la whitelist (imágenes png/jpeg/gif/webp, pdf, txt,
  doc/docx, xls/xlsx). Otro tipo → 400.
- Tamaño máximo `MAX_UPLOAD_BYTES` = 10 MB (configurable por env).
- URLs presignadas (subir y descargar) expiran en **300 s (5 min)**.
- `fileName` se sanitiza (`[^\w.\-]` → `_`). El adjunto nace con `status=PENDING`.
- Efecto colateral: incrementa `attachmentCount` del ticket.
- Descargar: `GET /attachments/download?ticketId&attachmentId` → `downloadUrl`.

## Reglas de USERS
- `GET /users/me`: cualquiera; si no hay item, responde un perfil mínimo derivado del JWT.
- `GET /users`: solo MANAGER/ADMIN; lista por `?areaId` (default su área) vía GSI4.
- `POST /users` (solo ADMIN): obligatorios `userId`, `email`, `role`; opcionales
  `fullName`, `areaId`. Sincroniza el grupo de Cognito (`Requester|Agent|Manager|Admin`)
  y, si hay `areaId`, el atributo `custom:areaId`.

## Reglas de AREAS
- `GET /areas`: cualquiera; lee la partición espejo `AREAS`.
- `POST /areas` (solo ADMIN): obligatorio `name`; opcionales `description`, `managerId`,
  `areaId` (si no se da, se genera). Escribe DOS items: el directo (`AREA#<id>`) y el
  espejo (`PK=AREAS`) para poder listar todas las áreas con un solo query.

## Reglas de TIEMPO REAL (WebSocket + Streams)
- **Conexión**: `wss://.../prod?token=<ID_TOKEN>`. El authorizer valida el ID token de
  Cognito (`tokenUse=id`) tomado del **query string**. Sin token o inválido → Deny.
- **Heartbeat**: el cliente manda `{"action":"sendMessage"}`; el server renueva el TTL
  (2 h) y responde `{"type":"pong","ts":...}`. Si no hay heartbeat, la conexión expira
  por TTL en `WSConnections`.
- **Push automático** (vía DynamoDB Streams → `notifications-dispatch`):
  - Evento de **TICKET** (INSERT/MODIFY) → se notifica a todas las conexiones del **área**
    del ticket. Payload: `{type:"TICKET", event, ticketId, number, title, state, priority, areaId}`.
  - Evento de **COMMENT** → se notifica a la **unión** de: requester + assignedTo + área
    del ticket (deduplicado). Payload: `{type:"COMMENT", event, ticketId, commentId, authorName, preview}`
    (preview = primeros 140 chars).
- Conexiones muertas (`410 Gone`) se borran solas al intentar enviarles.

## Convenciones de API (para el frontend)
- Autenticación REST: header `Authorization: Bearer <ID_TOKEN de Cognito>` (la HTTP API
  usa audience = client_id, por eso es el **ID token**, no el access token).
- Respuesta OK: el objeto/array tal cual (200/201). Respuesta de error: `{ "error": "<mensaje>" }`
  con el status correspondiente (400/401/403/404/500). CORS abierto (`*`).
- Folio visible al usuario: `number` (`TKT-AAAA-NNNN`). Identificador interno: `ticketId` (UUID).

## Modelo de datos (single-table `TicketsSystem`)
| Entidad | PK | SK | Notas |
|---|---|---|---|
| Ticket (metadata) | `TICKET#<id>` | `METADATA#<id>` | indexado en GSI1–GSI4 |
| Auditoría estado | `TICKET#<id>` | `STATUSCHANGE#<ts>#<rid>` | historial |
| Comentario | `TICKET#<ticketId>` | `COMMENT#<commentId>#<ts>` | orden temporal |
| Adjunto | `TICKET#<ticketId>` | `ATTACHMENT#<attId>` | status PENDING al crear |
| Usuario | `USER#<userId>` | `PROFILE#<userId>` | en GSI4 (`USER#<role>#<id>`) |
| Área (directa) | `AREA#<areaId>` | `PROFILE#<areaId>` | |
| Área (espejo) | `AREAS` | `AREA#<areaId>` | para listar todas |
| Contador folios | `COUNTER#TICKET#<año>` | `COUNTER` | `ADD lastNumber 1` atómico |

GSIs: **GSI1** area+state → prioridad/fecha · **GSI2** requester → fecha ·
**GSI3** assigned+state (sparse) · **GSI4** area → tickets (`TICKET#...`) y usuarios (`USER#...`).
Tabla aparte `WSConnections` (TTL en `expirationTime`) con `GSIByArea` y `GSIByUser`.
