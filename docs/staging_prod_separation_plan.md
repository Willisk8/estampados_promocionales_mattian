# Plan de separación STAGING / PROD

Fecha de corte: 2026-08-25

## Estado actual

El repositorio tiene dos ramas (`staging` y `master`), pero actualmente ambas
apuntan al mismo commit y solo existe despliegue automático a Supabase STAGING.

Esto es intencional mientras el piloto no esté listo para producción, pero no
debe confundirse con una separación PROD completa.

## Antes de crear PROD

1. Crear proyecto Supabase PROD separado.
2. Crear secretos GitHub separados:
   - `SUPABASE_PROD_DATABASE_URL`
   - `SUPABASE_PROD_PROJECT_ID` si se usa CLI en el futuro
3. Mantener secretos criptográficos separados:
   - `HMAC_SUPPRESSION_SECRET` de PROD diferente al de STAGING.
   - `N8N_ENCRYPTION_KEY` de PROD diferente al de STAGING.
4. Crear workflow `deploy-prod.yml` con ejecución manual o por release/tag.
5. Activar branch protection:
   - `master`: PR obligatorio, CI verde, revisión humana.
   - `staging`: CI verde antes de merge.
6. Prohibir deploy PROD desde commits no probados en STAGING.
7. Definir backup/restore de base PROD antes de la primera carga real.
8. Definir política de retención/anonimización de `import_raw_row`.

## Criterio de promoción

Un cambio puede pasar de STAGING a PROD solo si:

- migraciones aplicadas en STAGING;
- tests SQL y Python verdes;
- linter de Supabase sin errores críticos;
- gates pre-piloto revisados;
- precios propios en `DRAFT` revisados antes de pasar a `ACTIVE`;
- no hay datos PII crudos en Git;
- existe rollback o backup antes de cambios destructivos.

## No implementado todavía

- No existe workflow PROD.
- No existe secret PROD en GitHub Actions.
- No existe proyecto Supabase PROD documentado en este repo.
- No existe branch protection documentada como aplicada.
