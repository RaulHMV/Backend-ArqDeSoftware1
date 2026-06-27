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

## Desarrollo local del backend

```bash
cd backend
npm install
npm run typecheck   # revisa tipos
npm run build       # genera dist/<lambda>/index.js (lo que Terraform empaqueta)
```

No necesitas correr Terraform localmente; todo el infra va por GitHub Actions.
