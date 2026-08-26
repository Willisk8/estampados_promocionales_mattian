-- ============================================================
-- 046_close_anon_execute_and_null_role_bypass.sql
--
-- Correccion de seguridad, fuera del alcance de la Etapa C (Cliente 360)
-- pero descubierta al construir sus evals (Fase 6, docs/plan_ia.md).
-- Toma el numero 046 antes que las campanas (que pasan a 047): es un
-- bypass de escritura, no una mejora de producto.
--
-- HALLAZGO
--
-- 1. Supabase otorga EXECUTE a anon automaticamente en toda funcion nueva
--    del esquema public (ALTER DEFAULT PRIVILEGES a nivel de esquema,
--    confirmado en pg_default_acl). El patron "REVOKE ALL ... FROM PUBLIC"
--    que usa el proyecto desde la migracion 007 no lo revoca: es un grant
--    directo a anon, no mediado por PUBLIC. Unica excepcion existente:
--    fn_email_eligible_for_campaign (030), que ademas revoca de
--    anon/authenticated explicitamente.
--
-- 2. "IF v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN RAISE EXCEPTION" no
--    dispara cuando v_rol es NULL. NULL NOT IN (...) es NULL (logica de
--    tres valores de SQL), y PL/pgSQL trata una condicion NULL en IF como
--    falsa: la excepcion nunca se lanza, la funcion sigue ejecutandose.
--    Verificado con una prueba directa contra Postgres antes de escribir
--    esta migracion.
--
-- Combinadas: cualquier llamador sin sesion (con la anon key publica, sin
-- login) tiene fn_consola_rol() = NULL, y pasa de largo por esta guardia
-- en las 14 funciones de escritura listadas mas abajo -4 anteriores a la
-- Etapa C (migracion 029 y sus parches 031/032/033), 10 escritas en esta
-- misma etapa (040-045).
--
-- CORRECCION, dos partes independientes (defensa en profundidad):
--
-- A. Cierra la explotacion practica: revoca EXECUTE de anon en todas las
--    funciones de public, y fija el default privilege para que ninguna
--    funcion futura vuelva a heredarlo. Esto solo por si mismo ya cierra
--    el acceso de un llamador no autenticado.
--
-- B. Corrige la logica en si: reescribe las 14 funciones con
--    "IF v_rol IS NULL OR v_rol NOT IN (...)". Necesaria incluso con (A)
--    aplicado, porque un usuario AUTENTICADO sin fila en perfil_usuario
--    (p.ej. una cuenta de Supabase Auth recien creada, aun sin acceso de
--    consola) tambien tiene v_rol = NULL y seguiria pasando la guardia.
--
-- Cada CREATE OR REPLACE FUNCTION de abajo se genero a partir de
-- pg_get_functiondef() sobre la version YA APLICADA en STAGING, no
-- reconstruida de memoria: garantiza que el unico cambio real es la
-- guardia, sin perder ninguno de los ajustes acumulados por 031/032/033.
--
-- scripts/audit_change.py se actualizo en la misma sesion para detectar
-- este patron ("guardia-rol-null") en migraciones futuras.
-- ============================================================

-- ----------------------------------------------------------
-- Parte A: cerrar el grant de EXECUTE a anon, hoy y en adelante
-- ----------------------------------------------------------
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- ----------------------------------------------------------
-- Parte B: guardia NULL-segura en las 14 funciones afectadas
--
-- Generadas desde pg_get_functiondef() de la version vigente en STAGING;
-- unico cambio respecto al original: la linea del IF de rol.
-- ----------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_consola_resolver_revision(p_id_import_review_item uuid, p_resolution_status text, p_resolution_notes text DEFAULT NULL::text)
 RETURNS TABLE(id_import_review_item uuid, resolution_status text, resolved_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_user UUID := auth.uid();
    v_estado_anterior TEXT;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden resolver revisiones.';
    END IF;

    IF p_resolution_status NOT IN ('APPROVED', 'REJECTED', 'MERGED', 'IGNORED') THEN
        RAISE EXCEPTION 'Estado de resolucion invalido: %', p_resolution_status;
    END IF;

    SELECT iri.resolution_status
      INTO v_estado_anterior
      FROM import_review_item iri
     WHERE iri.id_import_review_item = p_id_import_review_item
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item de revision no encontrado.';
    END IF;

    IF v_estado_anterior <> 'OPEN' THEN
        RAISE EXCEPTION 'Solo se pueden resolver items OPEN. Estado actual: %', v_estado_anterior;
    END IF;

    UPDATE import_review_item iri
       SET resolution_status = p_resolution_status,
           resolution_notes = nullif(btrim(p_resolution_notes), ''),
           resolved_at = now()
     WHERE iri.id_import_review_item = p_id_import_review_item;

    INSERT INTO auditoria_revision_importacion (
        id_import_review_item, estado_anterior, estado_nuevo, notas,
        resuelto_por, rol_consola
    )
    VALUES (
        p_id_import_review_item, v_estado_anterior, p_resolution_status,
        nullif(btrim(p_resolution_notes), ''), v_user, v_rol
    );

    RETURN QUERY
    SELECT iri.id_import_review_item, iri.resolution_status, iri.resolved_at
      FROM import_review_item iri
     WHERE iri.id_import_review_item = p_id_import_review_item;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_actualizar_estado_comercial(p_id_organizacion uuid, p_estado_comercial text, p_prioridad text DEFAULT 'MEDIA'::text, p_notas text DEFAULT NULL::text)
 RETURNS TABLE(id_organizacion uuid, estado_comercial text, prioridad text, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden actualizar estado comercial.';
    END IF;

    IF p_estado_comercial NOT IN ('PROSPECTO', 'CLIENTE', 'DESCARTADO', 'INACTIVO') THEN
        RAISE EXCEPTION 'Estado comercial invalido: %', p_estado_comercial;
    END IF;

    IF coalesce(p_prioridad, 'MEDIA') NOT IN ('ALTA', 'MEDIA', 'BAJA') THEN
        RAISE EXCEPTION 'Prioridad invalida: %', p_prioridad;
    END IF;

    IF NOT EXISTS (
        SELECT 1
          FROM organizacion o
         WHERE o.id_organizacion = p_id_organizacion
    ) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    INSERT INTO relacion_comercial_organizacion (
        id_organizacion, estado_comercial, prioridad, notas, actualizado_por
    )
    VALUES (
        p_id_organizacion, p_estado_comercial, coalesce(p_prioridad, 'MEDIA'),
        nullif(btrim(p_notas), ''), auth.uid()
    )
    ON CONFLICT ON CONSTRAINT relacion_comercial_organizacion_pkey DO UPDATE
       SET estado_comercial = EXCLUDED.estado_comercial,
           prioridad = EXCLUDED.prioridad,
           notas = EXCLUDED.notas,
           actualizado_por = EXCLUDED.actualizado_por,
           updated_at = now();

    RETURN QUERY
    SELECT r.id_organizacion, r.estado_comercial, r.prioridad, r.updated_at
      FROM relacion_comercial_organizacion r
     WHERE r.id_organizacion = p_id_organizacion;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_clasificar_tipo_organizacion(p_id_organizacion uuid, p_tipo_codigo text, p_criterio text DEFAULT 'MANUAL'::text)
 RETURNS TABLE(id_organizacion uuid, tipo_codigo text, tipo_descripcion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_tipo_nuevo UUID;
    v_tipo_anterior UUID;
    v_origen TEXT;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden clasificar organizaciones.';
    END IF;

    SELECT c.id INTO v_tipo_nuevo
      FROM cat_tipo_organizacion c
     WHERE c.codigo = p_tipo_codigo;

    IF v_tipo_nuevo IS NULL THEN
        RAISE EXCEPTION 'Tipo de organizacion invalido: %', p_tipo_codigo;
    END IF;

    SELECT o.id_tipo_organizacion, o.tipo_entidad_origen
      INTO v_tipo_anterior, v_origen
      FROM organizacion o
     WHERE o.id_organizacion = p_id_organizacion
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    UPDATE organizacion o
       SET id_tipo_organizacion = v_tipo_nuevo
     WHERE o.id_organizacion = p_id_organizacion;

    INSERT INTO auditoria_tipo_organizacion (
        id_organizacion, id_tipo_anterior, id_tipo_nuevo, tipo_entidad_origen,
        criterio, clasificado_por, rol_consola
    )
    VALUES (
        p_id_organizacion, v_tipo_anterior, v_tipo_nuevo, v_origen,
        coalesce(nullif(btrim(p_criterio), ''), 'MANUAL'), auth.uid(), v_rol
    );

    RETURN QUERY
    SELECT o.id_organizacion, c.codigo, c.descripcion
      FROM organizacion o
      JOIN cat_tipo_organizacion c ON c.id = o.id_tipo_organizacion
     WHERE o.id_organizacion = p_id_organizacion;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_simple(p_id_organizacion uuid, p_id_producto uuid, p_id_variante uuid, p_cantidad integer, p_moneda text DEFAULT 'COP'::text, p_notas text DEFAULT NULL::text)
 RETURNS TABLE(id_cotizacion uuid, numero bigint, total numeric, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_precio NUMERIC(12,2);
    v_moneda TEXT;
    v_id_precio UUID;
    v_status TEXT;
    v_id_cotizacion UUID;
    v_numero BIGINT;
    v_snapshot JSONB;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden crear cotizaciones.';
    END IF;

    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor que cero.';
    END IF;

    IF p_id_organizacion IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    SELECT precio_unitario, moneda, id_precio, status
      INTO v_precio, v_moneda, v_id_precio, v_status
      FROM resolve_price(p_id_producto, p_id_variante, p_cantidad, now(), coalesce(p_moneda, 'COP'));

    IF v_status <> 'OK' THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_status;
        RETURN;
    END IF;

    SELECT jsonb_build_object(
        'id_producto', p.id_producto,
        'sku', p.sku,
        'producto', p.nombre,
        'estado_producto', p.estado,
        'id_variante', v.id_variante,
        'sku_variante', v.sku_variante,
        'variante', v.nombre,
        'estado_variante', v.estado,
        'id_precio', v_id_precio,
        'cantidad', p_cantidad,
        'moneda', v_moneda,
        'precio_unitario', v_precio,
        'capturado_en', now()
    )
      INTO v_snapshot
      FROM producto p
      LEFT JOIN variante_producto v ON v.id_variante = p_id_variante
     WHERE p.id_producto = p_id_producto;

    INSERT INTO cotizacion (
        id_organizacion, estado, moneda, total, creada_por, rol_consola, notas,
        metodo_precio, fecha_emision, origen, canal_origen
    )
    VALUES (
        p_id_organizacion, 'EMITIDA', v_moneda, v_precio * p_cantidad,
        auth.uid(), v_rol, nullif(btrim(p_notas), ''),
        'TARIFA_PUBLICADA', now(), 'CONSOLA', 'INTERNO'
    )
    RETURNING cotizacion.id_cotizacion, cotizacion.numero
      INTO v_id_cotizacion, v_numero;

    INSERT INTO cotizacion_item (
        id_cotizacion, id_producto, id_variante, id_precio, producto_snapshot,
        cantidad, precio_unitario, subtotal, moneda
    )
    VALUES (
        v_id_cotizacion, p_id_producto, p_id_variante, v_id_precio, v_snapshot,
        p_cantidad, v_precio, v_precio * p_cantidad, v_moneda
    );

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        v_id_cotizacion, 'CREADA', NULL, 'EMITIDA',
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('metodo_precio', 'TARIFA_PUBLICADA', 'id_precio', v_id_precio)
    );

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_precio * p_cantidad, 'OK'::TEXT;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_transicionar_cotizacion(p_id_cotizacion uuid, p_estado_nuevo text, p_notas text DEFAULT NULL::text)
 RETURNS TABLE(id_cotizacion uuid, estado_anterior text, estado_nuevo text, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol             TEXT := fn_consola_rol();
    v_user            UUID := auth.uid();
    v_estado_anterior TEXT;
    v_validas         TEXT[];
    v_notas           TEXT := nullif(btrim(p_notas), '');
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden transicionar cotizaciones.';
    END IF;

    SELECT c.estado
      INTO v_estado_anterior
      FROM cotizacion c
     WHERE c.id_cotizacion = p_id_cotizacion
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    v_validas := fn_cotizacion_transiciones_validas(v_estado_anterior);

    IF v_validas IS NULL THEN
        RAISE EXCEPTION 'Estado actual desconocido: %', v_estado_anterior;
    END IF;

    IF NOT (p_estado_nuevo = ANY (v_validas)) THEN
        RAISE EXCEPTION 'Transicion invalida: % -> %. Validas desde %: %',
            v_estado_anterior, p_estado_nuevo, v_estado_anterior,
            coalesce(array_to_string(v_validas, ', '), '(estado terminal)');
    END IF;

    UPDATE cotizacion c
       SET estado           = p_estado_nuevo,
           fecha_emision    = CASE WHEN p_estado_nuevo = 'EMITIDA'    THEN coalesce(c.fecha_emision, now())    ELSE c.fecha_emision    END,
           fecha_envio      = CASE WHEN p_estado_nuevo = 'ENVIADA'    THEN coalesce(c.fecha_envio, now())      ELSE c.fecha_envio      END,
           fecha_vista      = CASE WHEN p_estado_nuevo = 'VISTA'      THEN coalesce(c.fecha_vista, now())      ELSE c.fecha_vista      END,
           fecha_aceptacion = CASE WHEN p_estado_nuevo = 'ACEPTADA'   THEN coalesce(c.fecha_aceptacion, now()) ELSE c.fecha_aceptacion END,
           fecha_rechazo    = CASE WHEN p_estado_nuevo = 'RECHAZADA'  THEN coalesce(c.fecha_rechazo, now())    ELSE c.fecha_rechazo    END,
           fecha_anulacion  = CASE WHEN p_estado_nuevo = 'ANULADA'    THEN coalesce(c.fecha_anulacion, now())  ELSE c.fecha_anulacion  END,
           motivo_rechazo   = CASE WHEN p_estado_nuevo = 'RECHAZADA'  THEN coalesce(v_notas, c.motivo_rechazo) ELSE c.motivo_rechazo   END
     WHERE c.id_cotizacion = p_id_cotizacion;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        notas, actor_tipo, actor_id, rol_consola
    )
    VALUES (
        p_id_cotizacion, 'TRANSICION_ESTADO', v_estado_anterior, p_estado_nuevo,
        v_notas, 'HUMANO', v_user, v_rol
    );

    RETURN QUERY
    SELECT c.id_cotizacion, v_estado_anterior, c.estado, c.updated_at
      FROM cotizacion c
     WHERE c.id_cotizacion = p_id_cotizacion;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_registrar_interaccion(p_id_organizacion uuid, p_tipo_interaccion text, p_direccion text, p_motivo text, p_asunto text DEFAULT NULL::text, p_resumen text DEFAULT NULL::text, p_resultado text DEFAULT NULL::text, p_estado text DEFAULT 'REALIZADA'::text, p_id_persona uuid DEFAULT NULL::uuid, p_id_canal_contacto uuid DEFAULT NULL::uuid, p_relacionado_con_tipo text DEFAULT NULL::text, p_relacionado_con_id uuid DEFAULT NULL::uuid, p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS TABLE(id_interaccion uuid, estado text, occurred_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id  UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden registrar interacciones.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    IF p_id_persona IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM persona WHERE id_persona = p_id_persona) THEN
        RAISE EXCEPTION 'Persona no encontrada.';
    END IF;

    INSERT INTO interaccion_cliente (
        id_organizacion, id_persona, id_canal_contacto, tipo_interaccion,
        direccion, motivo, estado, asunto, resumen, resultado,
        actor_tipo, actor_id, relacionado_con_tipo, relacionado_con_id, occurred_at
    )
    VALUES (
        p_id_organizacion, p_id_persona, p_id_canal_contacto, p_tipo_interaccion,
        p_direccion, p_motivo, coalesce(p_estado, 'REALIZADA'),
        nullif(btrim(p_asunto), ''), nullif(btrim(p_resumen), ''), p_resultado,
        'HUMANO', auth.uid(), p_relacionado_con_tipo, p_relacionado_con_id,
        coalesce(p_occurred_at, now())
    )
    RETURNING interaccion_cliente.id_interaccion INTO v_id;

    RETURN QUERY
    SELECT ic.id_interaccion, ic.estado, ic.occurred_at
      FROM interaccion_cliente ic
     WHERE ic.id_interaccion = v_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_registrar_documento_cotizacion(p_id_cotizacion uuid, p_tipo_documento text, p_storage_path text, p_id_canal_contacto uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id_cotizacion_documento uuid, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id  UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden registrar documentos de cotizacion.';
    END IF;

    IF p_tipo_documento NOT IN ('PDF_GENERADO', 'PDF_ENVIADO') THEN
        RAISE EXCEPTION 'Tipo de documento invalido: %', p_tipo_documento;
    END IF;

    IF p_tipo_documento = 'PDF_ENVIADO' AND p_id_canal_contacto IS NULL THEN
        RAISE EXCEPTION 'PDF_ENVIADO requiere id_canal_contacto.';
    END IF;

    IF nullif(btrim(p_storage_path), '') IS NULL THEN
        RAISE EXCEPTION 'storage_path no puede estar vacio.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = p_id_cotizacion) THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    INSERT INTO cotizacion_documento (
        id_cotizacion, tipo_documento, storage_path, id_canal_contacto,
        generado_por, rol_consola
    )
    VALUES (
        p_id_cotizacion, p_tipo_documento, btrim(p_storage_path), p_id_canal_contacto,
        auth.uid(), v_rol
    )
    RETURNING cotizacion_documento.id_cotizacion_documento INTO v_id;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, p_tipo_documento, 'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('id_cotizacion_documento', v_id)
    );

    RETURN QUERY
    SELECT cd.id_cotizacion_documento, cd.created_at
      FROM cotizacion_documento cd
     WHERE cd.id_cotizacion_documento = v_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_programar_seguimiento(p_id_cotizacion uuid, p_fecha_programada timestamp with time zone, p_notas text DEFAULT NULL::text)
 RETURNS TABLE(id_cotizacion_followup uuid, fecha_programada timestamp with time zone, estado text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_id  UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden programar seguimientos.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = p_id_cotizacion) THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    IF p_fecha_programada IS NULL THEN
        RAISE EXCEPTION 'fecha_programada es obligatoria.';
    END IF;

    INSERT INTO cotizacion_followup (
        id_cotizacion, fecha_programada, notas, programado_por
    )
    VALUES (
        p_id_cotizacion, p_fecha_programada, nullif(btrim(p_notas), ''), auth.uid()
    )
    RETURNING cotizacion_followup.id_cotizacion_followup INTO v_id;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, notas, actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, 'SEGUIMIENTO_PROGRAMADO', nullif(btrim(p_notas), ''),
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('id_cotizacion_followup', v_id, 'fecha_programada', p_fecha_programada)
    );

    RETURN QUERY
    SELECT cf.id_cotizacion_followup, cf.fecha_programada, cf.estado
      FROM cotizacion_followup cf
     WHERE cf.id_cotizacion_followup = v_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_completar_seguimiento(p_id_cotizacion_followup uuid, p_notas text DEFAULT NULL::text, p_cancelado boolean DEFAULT false)
 RETURNS TABLE(id_cotizacion_followup uuid, estado text, realizado_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol           TEXT := fn_consola_rol();
    v_id_cotizacion UUID;
    v_estado_actual TEXT;
    v_estado_nuevo  TEXT := CASE WHEN p_cancelado THEN 'CANCELADO' ELSE 'REALIZADO' END;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden completar seguimientos.';
    END IF;

    SELECT cf.id_cotizacion, cf.estado
      INTO v_id_cotizacion, v_estado_actual
      FROM cotizacion_followup cf
     WHERE cf.id_cotizacion_followup = p_id_cotizacion_followup
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Seguimiento no encontrado.';
    END IF;

    IF v_estado_actual <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Solo se puede completar un seguimiento PENDIENTE. Estado actual: %', v_estado_actual;
    END IF;

    UPDATE cotizacion_followup cf
       SET estado       = v_estado_nuevo,
           realizado_at = now(),
           notas        = coalesce(nullif(btrim(p_notas), ''), cf.notas)
     WHERE cf.id_cotizacion_followup = p_id_cotizacion_followup;

    IF NOT p_cancelado THEN
        INSERT INTO cotizacion_evento (
            id_cotizacion, tipo_evento, notas, actor_tipo, actor_id, rol_consola, metadata
        )
        VALUES (
            v_id_cotizacion, 'SEGUIMIENTO_REALIZADO', nullif(btrim(p_notas), ''),
            'HUMANO', auth.uid(), v_rol,
            jsonb_build_object('id_cotizacion_followup', p_id_cotizacion_followup)
        );
    END IF;

    RETURN QUERY
    SELECT cf.id_cotizacion_followup, cf.estado, cf.realizado_at
      FROM cotizacion_followup cf
     WHERE cf.id_cotizacion_followup = p_id_cotizacion_followup;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_versionar_cotizacion(p_id_cotizacion uuid, p_motivo text DEFAULT NULL::text)
 RETURNS TABLE(id_cotizacion_version uuid, version_num integer, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol          TEXT := fn_consola_rol();
    v_snapshot     JSONB;
    v_version_num  INTEGER;
    v_id           UUID;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden versionar cotizaciones.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = p_id_cotizacion) THEN
        RAISE EXCEPTION 'Cotizacion no encontrada.';
    END IF;

    SELECT coalesce(max(cv.version_num), 0) + 1
      INTO v_version_num
      FROM cotizacion_version cv
     WHERE cv.id_cotizacion = p_id_cotizacion;

    SELECT jsonb_build_object(
        'cotizacion', to_jsonb(c.*),
        'items', coalesce(jsonb_agg(to_jsonb(ci.*)) FILTER (WHERE ci.id_cotizacion_item IS NOT NULL), '[]'::jsonb)
    )
      INTO v_snapshot
      FROM cotizacion c
      LEFT JOIN cotizacion_item ci ON ci.id_cotizacion = c.id_cotizacion
     WHERE c.id_cotizacion = p_id_cotizacion
     GROUP BY c.id_cotizacion;

    INSERT INTO cotizacion_version (
        id_cotizacion, version_num, snapshot, motivo, creado_por, rol_consola
    )
    VALUES (
        p_id_cotizacion, v_version_num, v_snapshot, nullif(btrim(p_motivo), ''), auth.uid(), v_rol
    )
    RETURNING cotizacion_version.id_cotizacion_version INTO v_id;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, notas, actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        p_id_cotizacion, 'VERSION_ARCHIVADA', nullif(btrim(p_motivo), ''),
        'HUMANO', auth.uid(), v_rol,
        jsonb_build_object('id_cotizacion_version', v_id, 'version_num', v_version_num)
    );

    RETURN QUERY
    SELECT cv.id_cotizacion_version, cv.version_num, cv.created_at
      FROM cotizacion_version cv
     WHERE cv.id_cotizacion_version = v_id;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_transicionar_pedido(p_id_pedido uuid, p_estado_nuevo text, p_notas text DEFAULT NULL::text)
 RETURNS TABLE(id_pedido uuid, estado_anterior text, estado_nuevo text, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol             TEXT := fn_consola_rol();
    v_user            UUID := auth.uid();
    v_estado_anterior TEXT;
    v_validas         TEXT[];
    v_notas           TEXT := nullif(btrim(p_notas), '');
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden transicionar pedidos.';
    END IF;

    SELECT p.estado
      INTO v_estado_anterior
      FROM pedido p
     WHERE p.id_pedido = p_id_pedido
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido no encontrado.';
    END IF;

    v_validas := fn_pedido_transiciones_validas(v_estado_anterior);

    IF v_validas IS NULL THEN
        RAISE EXCEPTION 'Estado actual desconocido: %', v_estado_anterior;
    END IF;

    IF NOT (p_estado_nuevo = ANY (v_validas)) THEN
        RAISE EXCEPTION 'Transicion invalida: % -> %. Validas desde %: %',
            v_estado_anterior, p_estado_nuevo, v_estado_anterior,
            coalesce(array_to_string(v_validas, ', '), '(estado terminal)');
    END IF;

    UPDATE pedido p
       SET estado             = p_estado_nuevo,
           fecha_entrega_real = CASE WHEN p_estado_nuevo = 'ENTREGADO' THEN coalesce(p.fecha_entrega_real, now()) ELSE p.fecha_entrega_real END
     WHERE p.id_pedido = p_id_pedido;

    INSERT INTO pedido_evento (
        id_pedido, tipo_evento, estado_anterior, estado_nuevo,
        notas, actor_tipo, actor_id, rol_consola
    )
    VALUES (
        p_id_pedido, 'TRANSICION_ESTADO', v_estado_anterior, p_estado_nuevo,
        v_notas, 'HUMANO', v_user, v_rol
    );

    RETURN QUERY
    SELECT p.id_pedido, v_estado_anterior, p.estado, p.updated_at
      FROM pedido p
     WHERE p.id_pedido = p_id_pedido;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_convertir_cotizacion_en_pedido(p_id_cotizacion uuid)
 RETURNS TABLE(id_pedido uuid, numero bigint, total numeric, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol            TEXT := fn_consola_rol();
    v_id_organizacion UUID;
    v_estado         TEXT;
    v_moneda         TEXT;
    v_subtotal       NUMERIC(14,2);
    v_id_pedido      UUID;
    v_numero         BIGINT;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden convertir cotizaciones en pedidos.';
    END IF;

    SELECT c.id_organizacion, c.estado, c.moneda
      INTO v_id_organizacion, v_estado, v_moneda
      FROM cotizacion c
     WHERE c.id_cotizacion = p_id_cotizacion
     FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    IF v_estado <> 'ACEPTADA' THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_NOT_ACCEPTED'::TEXT;
        RETURN;
    END IF;

    IF v_id_organizacion IS NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_WITHOUT_ORGANIZATION'::TEXT;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM pedido WHERE id_cotizacion = p_id_cotizacion) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'ALREADY_CONVERTED'::TEXT;
        RETURN;
    END IF;

    SELECT coalesce(sum(ci.subtotal), 0)
      INTO v_subtotal
      FROM cotizacion_item ci
     WHERE ci.id_cotizacion = p_id_cotizacion;

    IF v_subtotal <= 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 'QUOTE_WITHOUT_ITEMS'::TEXT;
        RETURN;
    END IF;

    -- impuestos_total en 0: el IVA quedo fuera del MVP (038). No se inventa
    -- un calculo que nadie pidio.
    INSERT INTO pedido (
        id_organizacion, id_cotizacion, origen, moneda,
        subtotal, impuestos_total, total, creado_por, rol_consola
    )
    VALUES (
        v_id_organizacion, p_id_cotizacion, 'COTIZACION', v_moneda,
        v_subtotal, 0, v_subtotal, auth.uid(), v_rol
    )
    RETURNING pedido.id_pedido, pedido.numero INTO v_id_pedido, v_numero;

    -- Precios congelados: se copian tal como quedaron en cotizacion_item,
    -- nunca se vuelve a resolver el precio actual.
    INSERT INTO pedido_item (
        id_pedido, id_producto, id_variante, producto_snapshot,
        cantidad, precio_unitario, subtotal
    )
    SELECT
        v_id_pedido, ci.id_producto, ci.id_variante, ci.producto_snapshot,
        ci.cantidad, ci.precio_unitario, ci.subtotal
      FROM cotizacion_item ci
     WHERE ci.id_cotizacion = p_id_cotizacion;

    INSERT INTO pedido_evento (id_pedido, tipo_evento, estado_nuevo, actor_tipo, actor_id, rol_consola)
    VALUES (v_id_pedido, 'CREADO', 'RECIBIDO', 'HUMANO', auth.uid(), v_rol);

    -- Reusa la maquina de estados de la cotizacion (040) en vez de un
    -- UPDATE directo: deja su propio evento en cotizacion_evento.
    PERFORM fn_consola_transicionar_cotizacion(
        p_id_cotizacion, 'CONVERTIDA_A_PEDIDO', 'Convertida a pedido #' || v_numero);

    RETURN QUERY SELECT v_id_pedido, v_numero, v_subtotal, 'OK'::TEXT;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_actualizar_preferencia_cliente(p_id_organizacion uuid, p_canal_preferido text DEFAULT NULL::text, p_horario_preferido text DEFAULT NULL::text, p_frecuencia_contacto_preferida text DEFAULT NULL::text, p_productos_interes uuid[] DEFAULT NULL::uuid[], p_productos_no_interes uuid[] DEFAULT NULL::uuid[], p_sensibilidad_precio text DEFAULT NULL::text, p_notas_comerciales text DEFAULT NULL::text)
 RETURNS TABLE(id_organizacion uuid, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden actualizar preferencias de cliente.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RAISE EXCEPTION 'Organizacion no encontrada.';
    END IF;

    INSERT INTO cliente_preferencia (
        id_organizacion, canal_preferido, horario_preferido, frecuencia_contacto_preferida,
        productos_interes, productos_no_interes, sensibilidad_precio, notas_comerciales,
        actualizado_por
    )
    VALUES (
        p_id_organizacion, p_canal_preferido, p_horario_preferido, p_frecuencia_contacto_preferida,
        coalesce(p_productos_interes, '{}'), coalesce(p_productos_no_interes, '{}'),
        coalesce(p_sensibilidad_precio, 'MEDIA'), nullif(btrim(p_notas_comerciales), ''),
        auth.uid()
    )
    ON CONFLICT (id_organizacion) DO UPDATE
       SET canal_preferido               = EXCLUDED.canal_preferido,
           horario_preferido             = EXCLUDED.horario_preferido,
           frecuencia_contacto_preferida = EXCLUDED.frecuencia_contacto_preferida,
           productos_interes             = EXCLUDED.productos_interes,
           productos_no_interes          = EXCLUDED.productos_no_interes,
           sensibilidad_precio           = EXCLUDED.sensibilidad_precio,
           notas_comerciales             = EXCLUDED.notas_comerciales,
           actualizado_por               = EXCLUDED.actualizado_por,
           updated_at                    = now();

    RETURN QUERY
    SELECT cp.id_organizacion, cp.updated_at
      FROM cliente_preferencia cp
     WHERE cp.id_organizacion = p_id_organizacion;
END;
$function$;


CREATE OR REPLACE FUNCTION public.fn_consola_aprobar_accion_ia(p_id_ia_accion_propuesta uuid, p_aprobar boolean, p_notas text DEFAULT NULL::text)
 RETURNS TABLE(id_ia_accion_propuesta uuid, estado text, aprobada_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol           TEXT := fn_consola_rol();
    v_estado_actual TEXT;
    v_expira_at     TIMESTAMPTZ;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RAISE EXCEPTION 'Solo ADMIN o COMERCIAL pueden aprobar o rechazar propuestas de IA.';
    END IF;

    SELECT iap.estado, iap.expira_at
      INTO v_estado_actual, v_expira_at
      FROM ia_accion_propuesta iap
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Propuesta no encontrada.';
    END IF;

    IF v_estado_actual <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Solo se puede resolver una propuesta PENDIENTE. Estado actual: %', v_estado_actual;
    END IF;

    IF now() > v_expira_at THEN
        UPDATE ia_accion_propuesta SET estado = 'EXPIRADA'
         WHERE id_ia_accion_propuesta = p_id_ia_accion_propuesta;
        RAISE EXCEPTION 'La propuesta expiro el % y no puede aprobarse ni rechazarse.', v_expira_at;
    END IF;

    UPDATE ia_accion_propuesta iap
       SET estado       = CASE WHEN p_aprobar THEN 'APROBADA' ELSE 'RECHAZADA' END,
           aprobada_por = auth.uid(),
           aprobada_at  = now(),
           resultado    = CASE WHEN nullif(btrim(p_notas), '') IS NOT NULL
                                THEN jsonb_build_object('notas', btrim(p_notas))
                                ELSE iap.resultado END
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta;

    RETURN QUERY
    SELECT iap.id_ia_accion_propuesta, iap.estado, iap.aprobada_at
      FROM ia_accion_propuesta iap
     WHERE iap.id_ia_accion_propuesta = p_id_ia_accion_propuesta;
END;
$function$;


-- ----------------------------------------------------------
-- Documentacion
-- ----------------------------------------------------------
COMMENT ON FUNCTION fn_consola_resolver_revision(UUID, TEXT, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_actualizar_estado_comercial(UUID, TEXT, TEXT, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_clasificar_tipo_organizacion(UUID, TEXT, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INT, TEXT, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_transicionar_cotizacion(UUID, TEXT, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_registrar_interaccion(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, UUID, UUID, TEXT, UUID, TIMESTAMPTZ) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_registrar_documento_cotizacion(UUID, TEXT, TEXT, UUID) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_programar_seguimiento(UUID, TIMESTAMPTZ, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_completar_seguimiento(UUID, TEXT, BOOLEAN) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_versionar_cotizacion(UUID, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_transicionar_pedido(UUID, TEXT, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_convertir_cotizacion_en_pedido(UUID) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_actualizar_preferencia_cliente(UUID, TEXT, TEXT, TEXT, UUID[], UUID[], TEXT, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
COMMENT ON FUNCTION fn_consola_aprobar_accion_ia(UUID, BOOLEAN, TEXT) IS
    'Guardia NULL-segura desde 046: v_rol NULL (sin perfil) ya no bypassea el chequeo de rol.';
