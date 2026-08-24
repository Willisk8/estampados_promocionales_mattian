-- ============================================================
-- 000_extensions.sql
-- Habilitar extensiones requeridas por el MVP Estampados
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
-- uuid-ossp como fallback por compatibilidad
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
