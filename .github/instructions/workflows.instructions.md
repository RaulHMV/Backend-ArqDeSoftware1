---
applyTo: ".github/workflows/**"
description: "Contexto de los workflows de GitHub Actions (auth con llaves estáticas, deploy manual)."
---

# Workflows — Ticket System (GitHub Actions)

Auth con **llaves estáticas** del usuario IAM `github-actions-deploy`
(AdministratorAccess). **NO OIDC, NO GitHub Environments.**
Secrets: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. Variable: `AWS_REGION`.

## Workflows
- `bootstrap.yml`: manual (workflow_dispatch, input action plan/apply). Crea el remote
  state en `infra/bootstrap`. YA ejecutado (no re-correr salvo recrear state).
- `pr-check.yml`: en pull_request a main. Job backend (npm install + typecheck + build)
  y job terraform (`fmt -check`, `init -backend=false` + `validate` de bootstrap y prod).
  NO toca AWS.
- `deploy.yml`: MANUAL (workflow_dispatch, nunca auto). Inputs:
  - `action`: plan | apply.
  - `confirm`: para apply hay que escribir `deploy` (seguro anti-clics).
  - La rama se elige en "Use workflow from".
  Compila Lambdas (`npm install` + `npm run build`) y corre Terraform en
  `infra/environments/prod` (init + plan, y apply solo si action=apply).

- `pg-deploy.yml` / `pg-destroy.yml`: MANUALES, stack `pg-multimaster` (2 EC2 + Ansible).
  Mismas llaves estáticas + secret extra `POSTGRES_PASSWORD`. deploy: `plan` o `apply`
  (confirm `deploy`; aplica el plan guardado). destroy: confirm `destroy`.
  Comparten `concurrency: pg-multimaster`. `pr-check` también valida este stack.
  Ansible va FIJO en un venv propio (Python 3.12, ansible-core 2.21.4,
  community.postgresql 5.0.0): NO usar el Ansible/colecciones preinstalados del runner.
  Si subes versiones, prueba antes: en c.postgresql 5 `db` ya es `login_db`.

## Reglas
- Mantener deploy MANUAL; no agregar trigger `push`/auto salvo petición.
- No reintroducir OIDC ni `role-to-assume`; usar `aws-access-key-id`/`aws-secret-access-key`.
- Terraform 1.9.5, Node 20.
