-- ============================================================
-- 050_capture_quote_item_personalization.sql
--
-- Corrige un hallazgo real (P1) de revision de codigo externa, presentado
-- al usuario como decision antes de aplicar (a diferencia de 048/049, que
-- se corrigieron directo): la conversion de cotizacion a pedido pierde la
-- tecnica de marcacion y la personalizacion.
--
-- HALLAZGO
-- pedido_item (043) define id_tecnica y personalizacion, pero nunca se
-- llenan: cotizacion_item (029, anterior a la Etapa C) jamas tuvo esas
-- columnas, asi que fn_consola_convertir_cotizacion_en_pedido no tiene de
-- donde copiarlas. Un pedido convertido queda sin instrucciones de
-- marcacion aunque el producto cotizado las requiera.
--
-- Confirmado antes de corregir: unica funcion que escribe en
-- cotizacion_item es fn_consola_crear_cotizacion_simple (grep sobre todas
-- las migraciones). No existe un segundo camino de escritura que tambien
-- necesite este cambio.
--
-- CORRECCION
-- 1. cotizacion_item gana id_tecnica y personalizacion (nullable/opcional:
--    el flujo "simple" no exige tecnica, igual que antes).
-- 2. fn_consola_crear_cotizacion_simple acepta dos parametros nuevos al
--    final, con default -compatible con todo llamador existente,
--    incluido web/src/app/cotizador/acciones.ts, que llama por nombre-.
--    Solo valida que la tecnica exista (no valida producto_tecnica: eso
--    es responsabilidad del motor de componentes de 038, no de este flujo
--    simple).
-- 3. fn_consola_convertir_cotizacion_en_pedido copia ambas columnas de
--    cotizacion_item a pedido_item, junto a lo que ya copiaba (precios
--    congelados, snapshot).
--
-- HALLAZGO INCIDENTAL (no relacionado con personalizacion, encontrado al
-- probar esta migracion): fn_consola_crear_cotizacion_simple no podia
-- ejecutarse en absoluto. "SELECT precio_unitario, moneda, id_precio,
-- status FROM resolve_price(...)" es ambiguo en Postgres 17 (STAGING
-- corre 17.6): status es tambien columna de salida de esta funcion via
-- RETURNS TABLE, y PL/pgSQL la trae al alcance como variable. Confirmado
-- que es preexistente, no introducido aqui: se probo la version YA
-- APLICADA en STAGING (antes de tocar nada de esta migracion) y fallaba
-- igual. Se corrige calificando con un alias, unica forma de poder probar
-- la parte de personalizacion. Barrido confirmado: ninguna otra funcion
-- del esquema tiene el mismo patron (columna 'status' de salida + llamada
-- a resolve_price o fn_calculate_quote_components).
-- ============================================================

ALTER TABLE cotizacion_item
    ADD COLUMN id_tecnica     UUID  REFERENCES tecnica_marcacion(id_tecnica),
    ADD COLUMN personalizacion JSONB NOT NULL DEFAULT '{}';

COMMENT ON COLUMN cotizacion_item.id_tecnica IS
    'Tecnica de marcacion solicitada, si aplica. Opcional: el flujo simple de cotizacion no la exige.';
COMMENT ON COLUMN cotizacion_item.personalizacion IS
    'Detalle de personalizacion pedido por el cliente al cotizar (colores, texto, ubicacion). Se copia a pedido_item al convertir.';

-- CREATE OR REPLACE con parametros nuevos al final NO reemplaza la
-- funcion existente: Postgres identifica una funcion por nombre + lista
-- de tipos de parametros declarados, sin contar los defaults. Sin este
-- DROP quedarian DOS sobrecargas coexistiendo (verificado: una llamada
-- posicional con 4 argumentos se volvia ambigua entre ambas).
DROP FUNCTION IF EXISTS fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INTEGER, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.fn_consola_crear_cotizacion_simple(p_id_organizacion uuid, p_id_producto uuid, p_id_variante uuid, p_cantidad integer, p_moneda text DEFAULT 'COP'::text, p_notas text DEFAULT NULL::text, p_id_tecnica uuid DEFAULT NULL::uuid, p_personalizacion jsonb DEFAULT '{}'::jsonb)
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

    -- No se valida contra producto_tecnica (esta funcion es el flujo
    -- "simple", no el motor de componentes de 038): solo confirma que la
    -- tecnica exista, para no guardar un id inventado.
    IF p_id_tecnica IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM tecnica_marcacion WHERE id_tecnica = p_id_tecnica) THEN
        RAISE EXCEPTION 'Tecnica de marcacion no encontrada.';
    END IF;

    -- Calificado con el alias rp: status tambien es una columna de salida
    -- de esta funcion (RETURNS TABLE), y PL/pgSQL la trae al alcance como
    -- variable, lo que vuelve ambiguo el nombre sin calificar. Bug
    -- preexistente (no introducido por esta migracion, verificado contra
    -- la version ya aplicada antes de tocar nada): en Postgres 17 este
    -- SELECT sin calificar falla siempre con "column reference status is
    -- ambiguous", asi que fn_consola_crear_cotizacion_simple nunca podia
    -- completar una cotizacion exitosa. Se corrige aqui porque no hay
    -- forma de probar la Fase de personalizacion (el motivo real de esta
    -- migracion) sin que la funcion pueda ejecutarse primero.
    SELECT rp.precio_unitario, rp.moneda, rp.id_precio, rp.status
      INTO v_precio, v_moneda, v_id_precio, v_status
      FROM resolve_price(p_id_producto, p_id_variante, p_cantidad, now(), coalesce(p_moneda, 'COP')) AS rp;

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
        cantidad, precio_unitario, subtotal, moneda, id_tecnica, personalizacion
    )
    VALUES (
        v_id_cotizacion, p_id_producto, p_id_variante, v_id_precio, v_snapshot,
        p_cantidad, v_precio, v_precio * p_cantidad, v_moneda, p_id_tecnica,
        coalesce(p_personalizacion, '{}'::jsonb)
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
        id_pedido, id_producto, id_variante, id_tecnica, producto_snapshot,
        cantidad, precio_unitario, subtotal, personalizacion
    )
    SELECT
        v_id_pedido, ci.id_producto, ci.id_variante, ci.id_tecnica, ci.producto_snapshot,
        ci.cantidad, ci.precio_unitario, ci.subtotal, ci.personalizacion
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

-- El DROP de arriba crea un objeto nuevo (OID distinto): a diferencia de
-- un CREATE OR REPLACE que si coincide en firma, NO conserva los grants
-- anteriores. Sin este GRANT explicito, la funcion quedaria inalcanzable
-- para authenticated (047 revoco el default de authenticated a nivel de
-- esquema para toda funcion nueva). fn_consola_convertir_cotizacion_en_pedido
-- no cambio de firma -su CREATE OR REPLACE de mas arriba si conserva sus
-- grants existentes, no necesita este paso.
REVOKE ALL ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INTEGER, TEXT, TEXT, UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_consola_crear_cotizacion_simple(UUID, UUID, UUID, INTEGER, TEXT, TEXT, UUID, JSONB) TO authenticated;

