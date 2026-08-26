-- ============================================================
-- 047_close_authenticated_default_grant_on_ai_helpers.sql
--
-- Continuacion de 046, descubierta al reconfirmar los evals de la Fase 6
-- sobre el esquema ya parcheado.
--
-- HALLAZGO
--
-- El default privilege de Supabase en el esquema public no solo otorga
-- EXECUTE a anon automaticamente (eso lo cerro 046): otorga tambien un
-- grant DIRECTO y SEPARADO a authenticated en toda funcion nueva, sin
-- pasar por PUBLIC. "REVOKE ALL ... FROM PUBLIC" -que 045 escribio para
-- fn_ai_resolver_sesion y fn_ai_registrar_llamada, con la intencion
-- explicita de que nunca fueran invocables directo por authenticated- no
-- lo toca, exactamente por el mismo motivo que "anon" se colaba en 046.
--
-- Efecto real: cualquier usuario AUTENTICADO (no necesita ser ADMIN ni
-- COMERCIAL) puede hoy llamar fn_ai_resolver_sesion o
-- fn_ai_registrar_llamada directamente, creando filas de ia_sesion con un
-- rol_consola arbitrario o insertando entradas fabricadas en
-- ia_llamada_herramienta bajo cualquier id_ia_sesion -exactamente el
-- riesgo de auditoria falsificable que el comentario de 045 advertia.
--
-- Se verifico que estas son las UNICAS dos funciones de las migraciones
-- 040-046 con este patron (REVOKE FROM PUBLIC sin GRANT a authenticated
-- despues): grep sobre los 7 archivos, cero candidatos adicionales.
--
-- CORRECCION: revocar el grant directo a authenticated en las dos, y
-- fijar tambien el default privilege para authenticated de aqui en
-- adelante, igual que 046 hizo para anon.
-- ============================================================

REVOKE ALL ON FUNCTION fn_ai_resolver_sesion(UUID, TEXT) FROM authenticated;
REVOKE ALL ON FUNCTION fn_ai_registrar_llamada(UUID, TEXT, JSONB, TEXT, INTEGER) FROM authenticated;

-- No se revoca EXECUTE a authenticated a nivel de esquema completo: a
-- diferencia de anon (que nunca debe tener nada), casi todo lo que se crea
-- en public SI esta pensado para authenticated, y cada fn_consola_*/fn_ai_*
-- publica ya trae su propio GRANT explicito. Revocar el default de
-- authenticated aqui obligaria a escribir GRANT EXECUTE para cada funcion
-- nueva de ahora en adelante -lo cual, de hecho, ya es la disciplina que
-- sigue todo el proyecto desde la migracion 007-. Se fija el default
-- igual para que quede escrito como regla, no solo como habito:
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM authenticated;

COMMENT ON FUNCTION fn_ai_resolver_sesion(UUID, TEXT) IS
    'Ayudante interno de la Fase 5. Nunca se otorga a authenticated (corregido en 047: el default privilege de Supabase lo otorgaba solo, sin GRANT explicito). Solo se alcanza por llamada anidada desde otra funcion SECURITY DEFINER.';

COMMENT ON FUNCTION fn_ai_registrar_llamada(UUID, TEXT, JSONB, TEXT, INTEGER) IS
    'Ayudante interno de la Fase 5. Nunca se otorga a authenticated (corregido en 047). Si un cliente pudiera llamarla directo, la auditoria de IA seria falsificable.';
