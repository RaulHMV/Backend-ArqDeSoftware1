# Copilot instructions — Ticket System

Clon básico de ServiceNow (tickets por áreas). Backend serverless en AWS,
desplegado con Terraform desde GitHub Actions. **Responde en español casual.**

> El detalle profundo vive en instrucciones por carpeta (`.github/instructions/`):
> `backend.instructions.md`, `infra.instructions.md`, `workflows.instructions.md`.
> Solo se cargan cuando trabajas en esa carpeta → ahorra tokens.
>
> **Reglas de negocio del dominio** (roles, estados, permisos, validaciones, modelo
> de datos): ver `.github/instructions/business-rules.instructions.md` (aplica a todo
> el repo). Léelo para entender QUÉ hace el sistema antes de cambiar lógica.

## Estructura
```
ticket-system/
  backend/    Node 20 + TS (ESM), bundle esbuild → dist/<handler>/index.js
  infra/      Terraform: bootstrap, modules, environments/prod (ÚNICO env)
  .github/    workflows (bootstrap, pr-check, deploy) + instructions
```

## Datos AWS
- Account: 020379956700 · región us-east-1
- State bucket: `ticketsys-tfstate-020379956700` · lock table: `ticketsys-tf-locks`
- Repo GitHub: `RaulHMV/Backend-ArqDeSoftware1`

## CI/CD (decisión del usuario: simple)
- **NO OIDC, NO GitHub Environments, NO env dev.** No reintroducir salvo que lo pida.
- Auth con llaves estáticas del IAM `github-actions-deploy` (AdministratorAccess).
- Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` · Variable: `AWS_REGION`.
- Deploy 100% manual (workflow_dispatch). Bootstrap ya ejecutado.

## Comandos
- Backend: `cd backend && npm install && npm run typecheck && npm run build`
- Terraform solo corre en GHA (no local).

## Estado
Backend completo (typecheck + build OK). Infra completa. Bootstrap ejecutado.
Pendiente: que el usuario corra `deploy` (plan → apply).
