-- Contrato cliente V2. No modifica contratos legacy ni cotizaciones emitidas.
CREATE OR REPLACE FUNCTION public.fn_quote_client_dtf(p jsonb, unidades integer)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE d jsonb; w numeric; h numeric; ancho numeric; sep numeric; tarifa numeric; reserva numeric; minimo numeric;
 n numeric; cols numeric; metros numeric; alterno numeric; aplica numeric; rotar boolean;
BEGIN
 IF jsonb_typeof(p)<>'object' OR p->>'tipo' NOT IN ('dtf','dtfv') OR jsonb_typeof(p->'disenos')<>'array' OR jsonb_array_length(p->'disenos')<>1 THEN
  RETURN jsonb_build_object('status','TECHNICAL_CONFIGURATION_REQUIRED'); END IF;
 d:=p->'disenos'->0; w:=(d->>'w')::numeric;h:=(d->>'h')::numeric;ancho:=(p->>'ancho_rollo')::numeric;
 sep:=(p->>'separacion')::numeric;tarifa:=(p->>'precio_metro')::numeric;reserva:=(p->>'reserva_pct')::numeric;
 minimo:=(p->>'minimo_metros')::numeric;aplica:=(p->>'costo_aplicacion_unitario')::numeric;rotar:=(p->>'rotacion')::boolean;
 n:=(d->>'qty')::numeric;
 IF w IS NULL OR h IS NULL OR ancho IS NULL OR sep IS NULL OR tarifa IS NULL OR reserva IS NULL OR minimo IS NULL OR aplica IS NULL OR rotar IS NULL OR n IS NULL
 OR w<=0 OR h<=0 OR ancho<=0 OR sep<0 OR tarifa<=0 OR reserva<0 OR reserva>100 OR minimo<0 OR aplica<0 OR n<1 OR n<>trunc(n)
 OR (ARRAY[w,h,ancho,sep,tarifa,reserva,minimo,aplica,n])::text ~ 'NaN|Infinity' THEN RETURN jsonb_build_object('status','INVALID_TECHNICAL_INPUT'); END IF;
 n:=ceil(n*unidades*(1+reserva/100)); cols:=floor((ancho+sep)/(w+sep));
 IF cols>0 THEN metros:=(ceil(n/cols)*(h+sep)-sep)/100; END IF;
 IF rotar THEN cols:=floor((ancho+sep)/(h+sep)); IF cols>0 THEN alterno:=(ceil(n/cols)*(w+sep)-sep)/100; END IF; END IF;
 metros:=least(metros,alterno);
 IF metros IS NULL THEN RETURN jsonb_build_object('status','DESIGN_DOES_NOT_FIT'); END IF;
 metros:=greatest(metros,minimo);
 RETURN jsonb_build_object('status','OK','metros',metros,'repeticiones',n,'costo_total',round(metros*tarifa+aplica*unidades,2));
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN RETURN jsonb_build_object('status','INVALID_TECHNICAL_INPUT');
END; $$;
REVOKE ALL ON FUNCTION public.fn_quote_client_dtf(jsonb,integer) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.fn_quote_client_payload_matches(
    p_id_cotizacion uuid,
    p_id_organizacion uuid,
    p_lineas jsonb,
    p_transporte_total numeric,
    p_transport_mode text,
    p_policy_code text,
    p_margen_override_pct numeric
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
    SELECT COALESCE(bool_and(
        c.id_organizacion IS NOT DISTINCT FROM p_id_organizacion
        AND COALESCE(ev.metadata->>'source_mode', '') = 'CLIENT_QUOTE_V2'
        AND COALESCE(ev.metadata->'lineas', '[]'::jsonb)
            IS NOT DISTINCT FROM p_lineas
        AND COALESCE((ev.metadata->>'transporte_total')::numeric, 0)
            IS NOT DISTINCT FROM COALESCE(p_transporte_total, 0)
        AND COALESCE(ev.metadata->>'transport_mode', 'SEPARATE_LINE')
            IS NOT DISTINCT FROM COALESCE(p_transport_mode, 'SEPARATE_LINE')
        AND COALESCE(ev.metadata->>'policy_code', 'MVP_DEFAULT')
            IS NOT DISTINCT FROM COALESCE(p_policy_code, 'MVP_DEFAULT')
        AND (ev.metadata->>'margen_override_pct')::numeric
            IS NOT DISTINCT FROM p_margen_override_pct
    ), false)
      FROM cotizacion c
      LEFT JOIN LATERAL (
          SELECT ce.metadata
            FROM cotizacion_evento ce
           WHERE ce.id_cotizacion = c.id_cotizacion
             AND ce.tipo_evento = 'CREADA'
           ORDER BY ce.occurred_at ASC
           LIMIT 1
      ) ev ON true
     WHERE c.id_cotizacion = p_id_cotizacion;
$function$;

REVOKE ALL ON FUNCTION public.fn_quote_client_payload_matches(
    UUID, UUID, JSONB, NUMERIC, TEXT, TEXT, NUMERIC
) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_quote_client_core(
    p_id_organizacion uuid,
    p_lineas jsonb,
    p_transporte_total numeric DEFAULT 0,
    p_transport_mode text DEFAULT 'SEPARATE_LINE',
    p_policy_code text DEFAULT 'MVP_DEFAULT',
    p_margen_override_pct numeric DEFAULT NULL,
    p_notas text DEFAULT NULL,
    p_idempotency_key text DEFAULT NULL,
    p_previsualizar boolean DEFAULT false,
    p_total_esperado numeric DEFAULT NULL
)
RETURNS TABLE(
    id_cotizacion uuid,
    numero bigint,
    total numeric,
    lineas integer,
    status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
    v_rol TEXT := fn_consola_rol();
    v_uid UUID := auth.uid();
    v_key TEXT := NULLIF(btrim(p_idempotency_key), '');
    v_lineas JSONB := COALESCE(p_lineas, '[]'::jsonb);
    v_modo TEXT := COALESCE(p_transport_mode, 'SEPARATE_LINE');
    v_policy_code TEXT := COALESCE(p_policy_code, 'MVP_DEFAULT');
    v_transporte NUMERIC := COALESCE(p_transporte_total, 0);
    v_existing UUID;
    v_numero BIGINT;
    v_total NUMERIC;
    v_status TEXT;
    v_id_cotizacion UUID;
    v_id_item UUID;
    v_id_policy UUID;
    v_rounding TEXT;
    v_n_lineas INTEGER;
    v_idx INTEGER;
    v_linea JSONB;
    v_snapshot RECORD;
    v_component RECORD;
    v_fila RECORD;
    v_unidad TEXT;
    v_pack NUMERIC;
    v_presentaciones NUMERIC;
    v_unidades NUMERIC;
    v_unidades_totales NUMERIC := 0;
    v_transporte_linea NUMERIC;
    v_transporte_asignado NUMERIC := 0;
    v_marking JSONB;
    v_extras JSONB;
    v_extra JSONB;
    v_extra_costo NUMERIC;
    v_extra_cantidad NUMERIC;
    v_extra_desc TEXT;
    v_policy_otro RECORD;
    v_snapshot_text TEXT;
    v_qty_comprada NUMERIC;
    v_qty_sobrante NUMERIC;
    v_linea_total NUMERIC;
    v_precio_unitario NUMERIC;
    v_costo_override NUMERIC;
    v_margen_linea NUMERIC;
    v_retencion NUMERIC;
    v_credito NUMERIC;
    v_motivo TEXT;
    v_tecnica JSONB;
    v_tecnica_resultado JSONB;
    v_plantilla_id UUID;
    v_plantilla RECORD;
    v_plantilla_snapshot JSONB;
    v_margen_plantilla NUMERIC;
    v_raw_total NUMERIC;
    v_adjust NUMERIC;
BEGIN
    IF v_rol IS NULL OR v_rol NOT IN ('ADMIN', 'COMERCIAL') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, NULL::INTEGER, 'FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF v_rol <> 'ADMIN' AND p_margen_override_pct IS NOT NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, NULL::INTEGER, 'MARGIN_OVERRIDE_FORBIDDEN'::TEXT;
        RETURN;
    END IF;

    IF p_margen_override_pct IS NOT NULL AND
       (p_margen_override_pct::text IN ('NaN','Infinity','-Infinity') OR p_margen_override_pct < 0 OR p_margen_override_pct >= 100) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, NULL::INTEGER, 'INVALID_MARGIN'::TEXT;
        RETURN;
    END IF;

    IF jsonb_typeof(v_lineas) <> 'array' THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, NULL::INTEGER, 'INVALID_LINES'::TEXT;
        RETURN;
    END IF;

    v_n_lineas := jsonb_array_length(v_lineas);
    IF v_n_lineas = 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, 0::INTEGER, 'NO_LINES'::TEXT;
        RETURN;
    END IF;

    IF v_n_lineas > 50 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'TOO_MANY_LINES'::TEXT;
        RETURN;
    END IF;

    IF v_modo NOT IN ('SEPARATE_LINE', 'DISTRIBUTED') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'INVALID_TRANSPORT_MODE'::TEXT;
        RETURN;
    END IF;

    IF v_transporte < 0 THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'INVALID_TRANSPORT_TOTAL'::TEXT;
        RETURN;
    END IF;

    IF p_id_organizacion IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM organizacion WHERE id_organizacion = p_id_organizacion) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'ORGANIZATION_NOT_FOUND'::TEXT;
        RETURN;
    END IF;

    IF v_key IS NOT NULL THEN
        SELECT c.id_cotizacion
          INTO v_existing
          FROM cotizacion c
         WHERE c.creada_por = v_uid
           AND c.idempotency_key = v_key
         LIMIT 1;

        IF v_existing IS NOT NULL THEN
            IF public.fn_quote_client_payload_matches(
                v_existing, p_id_organizacion, v_lineas, v_transporte,
                v_modo, v_policy_code, p_margen_override_pct
            ) AND EXISTS (SELECT 1 FROM cotizacion c WHERE c.id_cotizacion = v_existing AND c.notas IS NOT DISTINCT FROM p_notas) THEN
                SELECT c.numero, c.total INTO v_numero, v_total
                  FROM cotizacion c
                 WHERE c.id_cotizacion = v_existing;
                RETURN QUERY SELECT v_existing, v_numero, v_total, v_n_lineas, 'OK'::TEXT;
            ELSE
                RETURN QUERY SELECT v_existing, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'CONFLICT'::TEXT;
            END IF;
            RETURN;
        END IF;
    END IF;

    -- ── PASO 1: resolver y validar TODAS las lineas antes de escribir nada ──
    -- No se inserta ninguna fila hasta que las N lineas hayan pasado. Una
    -- validacion a mitad del INSERT dejaria una cotizacion incompleta emitida.
    DROP TABLE IF EXISTS pg_temp.tmp_ml_lineas;
    CREATE TEMP TABLE tmp_ml_lineas (
        idx INTEGER,
        id_snapshot UUID,
        id_producto_proveedor UUID,
        unidad TEXT,
        pack NUMERIC,
        presentaciones NUMERIC,
        unidades INTEGER,
        marking JSONB,
        extras JSONB,
        transporte_linea NUMERIC,
        costo_override NUMERIC,
        margen_linea NUMERIC,
        retencion NUMERIC, credito NUMERIC, motivo TEXT, configuracion JSONB, plantilla JSONB
    ) ON COMMIT DROP;

    FOR v_idx, v_linea IN
        SELECT t.ordinality::INTEGER, t.value
          FROM jsonb_array_elements(v_lineas) WITH ORDINALITY AS t(value, ordinality)
    LOOP
        IF jsonb_typeof(v_linea) <> 'object' THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_LINE'::TEXT;
            RETURN;
        END IF;

        v_snapshot_text := NULLIF(btrim(COALESCE(v_linea->>'id_precio_proveedor_snapshot', '')), '');
        IF v_snapshot_text IS NULL
           OR v_snapshot_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_LINE_SNAPSHOT'::TEXT;
            RETURN;
        END IF;

        v_marking := NULL;
        v_marking := COALESCE(v_linea->'marking_lines', '[]'::jsonb);
        IF jsonb_typeof(v_marking) <> 'array' THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_MARKING_LINES'::TEXT;
            RETURN;
        END IF;

        IF NOT public.fn_quote_supplier_marking_lines_usable(v_marking) THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'MARKING_COST_NOT_FOUND'::TEXT;
            RETURN;
        END IF;

        v_extras := COALESCE(v_linea->'costos_adicionales', '[]'::jsonb);
        IF jsonb_typeof(v_extras) <> 'array' THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_EXTRA_COSTS'::TEXT;
            RETURN;
        END IF;

        BEGIN
            v_presentaciones := NULLIF(btrim(COALESCE(v_linea->>'unidades_entregar', '')), '')::NUMERIC;
        EXCEPTION WHEN others THEN
            v_presentaciones := NULL;
        END;

        IF v_presentaciones IS NULL
           OR v_presentaciones::text IN ('NaN','Infinity','-Infinity')
           OR v_presentaciones > 1000000
           OR v_presentaciones <= 0
           OR v_presentaciones <> trunc(v_presentaciones) THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_QUANTITY'::TEXT;
            RETURN;
        END IF;

        -- Mismos filtros de vigencia/calidad que usa el nucleo de calculo, para
        -- que una linea que el nucleo va a rechazar se detecte aca y no a mitad
        -- de la escritura.
        SELECT
            pps.id_snapshot,
            pps.id_producto_proveedor,
            pps.unidad_compra,
            pps.cantidad_pack
          INTO v_snapshot
          FROM precio_proveedor_snapshot pps
          JOIN producto_proveedor pp ON pp.id_producto_proveedor = pps.id_producto_proveedor
          JOIN proveedor pr ON pr.id_proveedor = pp.id_proveedor
         WHERE pps.id_snapshot = v_snapshot_text::UUID
           AND pps.moneda = 'COP'
           AND pp.estado_calidad <> 'REJECTED'
           AND pr.activo
           AND (pps.precio_vigencia IS NULL OR pps.precio_vigencia @> now())
         LIMIT 1;

        IF v_snapshot.id_snapshot IS NULL THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'SUPPLIER_PRICE_NOT_FOUND'::TEXT;
            RETURN;
        END IF;

        -- id_producto_proveedor viaja en la linea solo como comprobacion: la
        -- fuente de verdad es el snapshot. Si el frontend manda un par
        -- inconsistente se rechaza en vez de congelar datos cruzados.
        IF NULLIF(btrim(COALESCE(v_linea->>'id_producto_proveedor', '')), '') IS NOT NULL
           AND (v_linea->>'id_producto_proveedor') IS DISTINCT FROM v_snapshot.id_producto_proveedor::TEXT THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'LINE_PRODUCT_MISMATCH'::TEXT;
            RETURN;
        END IF;

        IF v_snapshot.unidad_compra IS NULL THEN
            RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_idx,'PURCHASE_UNIT_UNVERIFIED'::text; RETURN;
        END IF;
        v_unidad := v_snapshot.unidad_compra;
        v_pack := CASE WHEN v_unidad = 'PACK' THEN COALESCE(v_snapshot.cantidad_pack, 0) ELSE 1 END;

        IF v_unidad = 'PACK' AND v_pack <= 0 THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_PACK_QUANTITY'::TEXT;
            RETURN;
        END IF;

        -- V2 recibe unidades a entregar; la presentacion es una condicion de compra.
        v_unidades := v_presentaciones;
        v_presentaciones := ceil(v_unidades / v_pack);

        IF v_unidades <= 0
           OR v_unidades <> trunc(v_unidades)
           OR v_unidades > 2147483647 THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_QUANTITY'::TEXT;
            RETURN;
        END IF;

        BEGIN
            v_costo_override := NULLIF(v_linea->>'costo_unitario_override', '')::numeric;
            v_margen_linea := NULLIF(v_linea->>'margen_linea_pct', '')::numeric;
            v_retencion := COALESCE(NULLIF(v_linea->>'retencion_pct', '')::numeric, 0);
            v_credito := COALESCE((v_linea->>'reasignacion_sobrante')::numeric,0);
            v_motivo := NULLIF(btrim(v_linea->>'motivo_ajuste'),'');
            v_tecnica := COALESCE(v_linea->'configuracion_tecnica','{}'::jsonb);
        EXCEPTION WHEN others THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_PRICING_INPUT'::TEXT;
            RETURN;
        END;
        IF v_rol <> 'ADMIN' AND (v_costo_override IS NOT NULL OR v_margen_linea IS NOT NULL OR v_retencion <> 0) THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'PRICING_OVERRIDE_FORBIDDEN'::TEXT;
            RETURN;
        END IF;
        v_plantilla_snapshot := '{}'::jsonb;
        v_margen_plantilla := NULL;
        IF NULLIF(btrim(COALESCE(v_linea->>'id_plantilla_margen','')),'') IS NOT NULL THEN
            IF (v_linea->>'id_plantilla_margen') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
                RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_idx,'MARGIN_TEMPLATE_NOT_FOUND'::text; RETURN;
            END IF;
            v_plantilla_id := (v_linea->>'id_plantilla_margen')::uuid;
            SELECT p.id,p.codigo,p.version,p.margen_base,p.tramos,p.estado INTO v_plantilla
            FROM public.plantilla_margen_version p WHERE p.id=v_plantilla_id AND p.estado='ACTIVE';
            IF NOT FOUND THEN
                RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_idx,'MARGIN_TEMPLATE_NOT_FOUND'::text; RETURN;
            END IF;
            v_margen_plantilla := v_plantilla.margen_base;
            SELECT (t.value->>'margen')::numeric INTO v_margen_plantilla
            FROM jsonb_array_elements(v_plantilla.tramos) WITH ORDINALITY AS t(value,ordinality)
            WHERE (t.value->>'desde')::numeric <= v_unidades ORDER BY t.ordinality DESC LIMIT 1;
            v_margen_plantilla := COALESCE(v_margen_plantilla,v_plantilla.margen_base);
            v_plantilla_snapshot := jsonb_build_object('id',v_plantilla.id,'codigo',v_plantilla.codigo,
                'version',v_plantilla.version,'margen_base',v_plantilla.margen_base,
                'tramos',v_plantilla.tramos,'margen_sugerido',v_margen_plantilla);
        END IF;
        IF (v_costo_override IS NOT NULL AND (v_costo_override <= 0 OR v_costo_override > 1000000000 OR v_costo_override::text IN ('NaN','Infinity','-Infinity')))
           OR (v_margen_linea IS NOT NULL AND (v_margen_linea < 0 OR v_margen_linea >= 100 OR v_margen_linea::text IN ('NaN','Infinity','-Infinity')))
           OR v_retencion < 0 OR v_retencion >= 100 OR v_retencion::text IN ('NaN','Infinity','-Infinity') THEN
            RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_idx, 'INVALID_PRICING_INPUT'::TEXT;
            RETURN;
        END IF;

        IF v_credito < 0 OR v_credito::text IN ('NaN','Infinity','-Infinity') OR (v_credito > 0 AND (v_rol <> 'ADMIN' OR v_motivo IS NULL)) THEN
            RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_idx,'INVALID_SURPLUS_ALLOCATION'::text; RETURN;
        END IF;
        IF (jsonb_array_length(v_extras)>0 OR v_tecnica <> '{}'::jsonb) AND v_rol <> 'ADMIN' THEN
            RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_idx,'PRICING_OVERRIDE_FORBIDDEN'::text; RETURN;
        END IF;
        IF v_tecnica <> '{}'::jsonb THEN
            v_tecnica_resultado := public.fn_quote_client_dtf(v_tecnica,v_unidades::integer);
            IF v_tecnica_resultado->>'status' <> 'OK' THEN
                RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_idx,(v_tecnica_resultado->>'status')::text; RETURN;
            END IF;
            v_extras := v_extras || jsonb_build_array(jsonb_build_object('descripcion','Marcacion ' || (v_tecnica->>'tipo'),
                'costo_total',(v_tecnica_resultado->>'costo_total')::numeric,'configuracion_tecnica',v_tecnica,'calculo',v_tecnica_resultado));
        END IF;
        INSERT INTO tmp_ml_lineas (
            idx, id_snapshot, id_producto_proveedor, unidad, pack,
            presentaciones, unidades, marking, extras, transporte_linea, costo_override, margen_linea, retencion, credito, motivo, configuracion, plantilla
        )
        VALUES (
            v_idx, v_snapshot.id_snapshot, v_snapshot.id_producto_proveedor,
            v_unidad, v_pack, v_presentaciones, v_unidades::INTEGER,
            v_marking, v_extras, 0, v_costo_override, COALESCE(v_margen_linea, v_margen_plantilla, p_margen_override_pct), v_retencion, v_credito, v_motivo, v_tecnica, v_plantilla_snapshot
        );

        v_unidades_totales := v_unidades_totales + v_unidades;
    END LOOP;

    -- Una misma oferta/configuracion no puede dividirse para cambiar el tramo
    -- de margen o repetir preparaciones. En V2 el usuario consolida unidades
    -- en una sola linea; configuraciones tecnicas diferentes siguen separadas.
    IF EXISTS (
        SELECT 1 FROM tmp_ml_lineas
        GROUP BY id_snapshot, configuracion
        HAVING count(*) > 1
    ) THEN
        RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_n_lineas,
            'DUPLICATE_CONFIGURATION'::text;
        RETURN;
    END IF;

    -- Reparto del transporte del PEDIDO entre las lineas.
    IF v_transporte > 0 THEN
        IF v_modo = 'SEPARATE_LINE' THEN
            UPDATE tmp_ml_lineas SET transporte_linea = v_transporte WHERE idx = 1;
        ELSE
            FOR v_fila IN SELECT * FROM tmp_ml_lineas ORDER BY idx LOOP
                IF v_fila.idx = v_n_lineas THEN
                    v_transporte_linea := v_transporte - v_transporte_asignado;
                ELSE
                    v_transporte_linea := round(
                        v_transporte * v_fila.unidades / NULLIF(v_unidades_totales, 0), 2
                    );
                    v_transporte_asignado := v_transporte_asignado + v_transporte_linea;
                END IF;
                UPDATE tmp_ml_lineas SET transporte_linea = v_transporte_linea WHERE idx = v_fila.idx;
            END LOOP;
        END IF;
    END IF;

    -- ── PASO 2: calcular los componentes de cada linea con el nucleo de 069 ──
    DROP TABLE IF EXISTS pg_temp.tmp_ml_componentes;
    CREATE TEMP TABLE tmp_ml_componentes (
        idx INTEGER,
        tipo_componente TEXT,
        descripcion TEXT,
        cantidad NUMERIC,
        costo_unitario NUMERIC,
        costo_total NUMERIC,
        pricing_method TEXT,
        margen_aplicado_pct NUMERIC,
        minimum_pct NUMERIC,
        precio_resultante NUMERIC,
        source_type TEXT,
        source_snapshot_id UUID,
        metadata JSONB,
        status TEXT
    ) ON COMMIT DROP;

    FOR v_fila IN SELECT * FROM tmp_ml_lineas ORDER BY idx LOOP
        INSERT INTO tmp_ml_componentes
        SELECT
            v_fila.idx, c.tipo_componente, c.descripcion, c.cantidad,
            c.costo_unitario, c.costo_total, c.pricing_method,
            c.margen_aplicado_pct, c.minimum_pct, c.precio_resultante,
            c.source_type, c.source_snapshot_id, c.metadata, c.status
          FROM fn_quote_calculate_supplier_components_core(
            v_fila.id_snapshot,
            v_fila.unidades,
            v_fila.marking,
            v_fila.transporte_linea,
            v_modo,
            v_policy_code,
            now(),
            'COP',
            v_fila.margen_linea
          ) c;
    END LOOP;

    SELECT t.status INTO v_status
      FROM tmp_ml_componentes t
     WHERE t.status <> 'OK'
     ORDER BY t.idx
     LIMIT 1;

    IF v_status IS NOT NULL THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, v_status;
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tmp_ml_componentes) THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'NO_COMPONENTS'::TEXT;
        RETURN;
    END IF;

    SELECT (t.metadata->>'policy_id')::UUID, t.metadata->>'rounding_rule'
      INTO v_id_policy, v_rounding
      FROM tmp_ml_componentes t
     LIMIT 1;

    -- Costos adicionales de linea -> componentes 'OTRO' con la MISMA politica
    -- y el MISMO redondeo que aplica el nucleo a los demas componentes.
    SELECT mpc.pricing_method, mpc.target_pct, mpc.minimum_pct
      INTO v_policy_otro
      FROM margin_policy_component mpc
     WHERE mpc.id_margin_policy_version = v_id_policy
       AND mpc.tipo_componente = 'OTRO';

    FOR v_fila IN SELECT * FROM tmp_ml_lineas ORDER BY idx LOOP
        FOR v_extra IN SELECT value FROM jsonb_array_elements(v_fila.extras) LOOP
            IF jsonb_typeof(v_extra) <> 'object' THEN
                RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_fila.idx, 'INVALID_EXTRA_COSTS'::TEXT;
                RETURN;
            END IF;

            BEGIN
                IF NULLIF(btrim(COALESCE(v_extra->>'costo_total', '')), '') IS NOT NULL THEN
                    v_extra_costo := (v_extra->>'costo_total')::NUMERIC;
                    v_extra_cantidad := 1;
                ELSE
                    v_extra_costo := COALESCE(
                        NULLIF(btrim(COALESCE(v_extra->>'costo_unitario', '')), '')::NUMERIC, 0
                    ) * v_fila.unidades;
                    v_extra_cantidad := v_fila.unidades;
                END IF;
            EXCEPTION WHEN others THEN
                v_extra_costo := NULL;
            END;

            IF v_extra_costo IS NULL OR v_extra_costo < 0 OR v_extra_costo::text IN ('NaN','Infinity','-Infinity') THEN
                RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_fila.idx, 'INVALID_EXTRA_COSTS'::TEXT;
                RETURN;
            END IF;

            CONTINUE WHEN v_extra_costo = 0;

            v_extra_desc := COALESCE(NULLIF(btrim(COALESCE(v_extra->>'descripcion', '')), ''), 'Costo adicional');

            INSERT INTO tmp_ml_componentes (
                idx, tipo_componente, descripcion, cantidad, costo_unitario,
                costo_total, pricing_method, margen_aplicado_pct, minimum_pct,
                precio_resultante, source_type, source_snapshot_id, metadata, status
            )
            VALUES (
                v_fila.idx,
                'OTRO',
                v_extra_desc,
                round(v_extra_cantidad, 4),
                round(v_extra_costo / NULLIF(v_extra_cantidad, 0), 4),
                round(v_extra_costo, 2),
                COALESCE(v_policy_otro.pricing_method, 'MARGIN'),
                COALESCE(v_fila.margen_linea, v_policy_otro.target_pct, 0),
                COALESCE(v_policy_otro.minimum_pct, 0),
                CASE
                    WHEN COALESCE(v_policy_otro.pricing_method, 'MARGIN') = 'PASS_THROUGH'
                        THEN round(fn_quote_apply_margin(
                                round(v_extra_costo, 2),
                                COALESCE(v_policy_otro.pricing_method, 'MARGIN'),
                                COALESCE(v_fila.margen_linea, v_policy_otro.target_pct, 0)
                             ), 2)
                    ELSE fn_quote_round(
                            fn_quote_apply_margin(
                                round(v_extra_costo, 2),
                                COALESCE(v_policy_otro.pricing_method, 'MARGIN'),
                                COALESCE(v_fila.margen_linea, v_policy_otro.target_pct, 0)
                            ),
                            v_rounding
                         )
                END,
                'MANUAL',
                NULL::UUID,
                v_extra || jsonb_build_object(
                    'policy_id', v_id_policy,
                    'rounding_rule', v_rounding,
                    'minimum_pct', COALESCE(v_policy_otro.minimum_pct, 0),
                    'origen', 'COSTO_ADICIONAL_LINEA'
                ),
                'OK'
            );
        END LOOP;
    END LOOP;

    -- Compra completa, con reasignacion auditable limitada al sobrante real.
    FOR v_fila IN SELECT * FROM tmp_ml_lineas ORDER BY idx LOOP
        SELECT * INTO v_component FROM tmp_ml_componentes WHERE idx=v_fila.idx AND tipo_componente='PRODUCTO';
        v_qty_comprada := v_fila.presentaciones*v_fila.pack;
        v_qty_sobrante := v_qty_comprada-v_fila.unidades;
        IF v_fila.credito > round(v_qty_sobrante*COALESCE(v_fila.costo_override,v_component.costo_unitario),2) THEN
            RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,v_fila.idx,'INVALID_SURPLUS_ALLOCATION'::text; RETURN;
        END IF;
        UPDATE tmp_ml_componentes SET cantidad=v_qty_comprada,
            costo_unitario=COALESCE(v_fila.costo_override,v_component.costo_unitario),
            costo_total=round(v_qty_comprada*COALESCE(v_fila.costo_override,v_component.costo_unitario),2)-v_fila.credito,
            metadata=metadata||jsonb_build_object('cantidad_comprada',v_qty_comprada,'cantidad_usada',v_fila.unidades,
                'cantidad_sobrante',v_qty_sobrante,'reasignacion_sobrante',v_fila.credito,'motivo_ajuste',v_fila.motivo,
                'desembolso_compra',round(v_qty_comprada*COALESCE(v_fila.costo_override,v_component.costo_unitario),2))
        WHERE idx=v_fila.idx AND tipo_componente='PRODUCTO';
    END LOOP;

    -- Se elimina el gross-up y el redondeo de componentes. El ajuste se calcula
    -- al unitario y se registra en un componente, para conciliar el desglose.
    UPDATE tmp_ml_componentes t SET precio_resultante=fn_quote_apply_margin(t.costo_total,t.pricing_method,t.margen_aplicado_pct),
        minimum_pct=0,metadata=t.metadata||jsonb_build_object('motor_version','CLIENT_V2','retencion_informativa_pct',l.retencion,
        'rounding_rule','UP_1_UNIT','policy_snapshot',jsonb_build_object('metodo',t.pricing_method,'margen',t.margen_aplicado_pct))
    FROM tmp_ml_lineas l WHERE t.idx=l.idx;
    FOR v_fila IN SELECT * FROM tmp_ml_lineas ORDER BY idx LOOP
        SELECT sum(precio_resultante) INTO v_raw_total FROM tmp_ml_componentes WHERE idx=v_fila.idx;
        v_linea_total := ceil(v_raw_total/v_fila.unidades)*v_fila.unidades;
        UPDATE tmp_ml_componentes SET precio_resultante=round(precio_resultante,2) WHERE idx=v_fila.idx;
        SELECT v_linea_total-sum(precio_resultante) INTO v_adjust FROM tmp_ml_componentes WHERE idx=v_fila.idx;
        UPDATE tmp_ml_componentes SET precio_resultante=precio_resultante+v_adjust,
            metadata=metadata||jsonb_build_object('ajuste_redondeo',v_adjust)
        WHERE ctid=(SELECT ctid FROM tmp_ml_componentes WHERE idx=v_fila.idx ORDER BY precio_resultante DESC, tipo_componente LIMIT 1);
    END LOOP;
    SELECT sum(precio_resultante) INTO v_total FROM tmp_ml_componentes;

    IF v_total IS NULL OR v_total <= 0 OR v_total::text IN ('NaN','Infinity','-Infinity') THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'INVALID_TOTAL'::TEXT;
        RETURN;
    END IF;
    IF p_previsualizar THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, v_total, v_n_lineas, 'OK'::TEXT;
        RETURN;
    END IF;
    IF p_total_esperado IS NOT NULL AND p_total_esperado IS DISTINCT FROM v_total THEN
        RETURN QUERY SELECT NULL::UUID, NULL::BIGINT, v_total, v_n_lineas, 'PREVIEW_CHANGED'::TEXT;
        RETURN;
    END IF;

    -- ── PASO 3: escribir cotizacion + N items + sus componentes ──
    INSERT INTO cotizacion (
        id_organizacion, estado, moneda, total, creada_por, rol_consola, notas,
        metodo_precio, id_margin_policy_version, fecha_emision, origen, canal_origen,
        idempotency_key
    )
    VALUES (
        p_id_organizacion, 'EMITIDA', 'COP', v_total, v_uid, v_rol, p_notas,
        'CALCULO_COMPONENTES', v_id_policy, now(), 'CONSOLA', 'COTIZADOR_PROVEEDOR',
        v_key
    )
    RETURNING cotizacion.id_cotizacion, cotizacion.numero INTO v_id_cotizacion, v_numero;

    FOR v_fila IN SELECT * FROM tmp_ml_lineas ORDER BY idx LOOP
        SELECT
            pps.id_snapshot,
            pps.id_producto_proveedor,
            pps.precio_publicado,
            pps.unidad_compra,
            pps.cantidad_pack,
            pps.url_fuente,
            pps.observado_en,
            pp.nombre_original,
            pp.sku_proveedor,
            pp.categoria,
            pp.atributos,
            pr.id_proveedor,
            pr.nombre AS proveedor_nombre
          INTO v_snapshot
          FROM precio_proveedor_snapshot pps
          JOIN producto_proveedor pp ON pp.id_producto_proveedor = pps.id_producto_proveedor
          JOIN proveedor pr ON pr.id_proveedor = pp.id_proveedor
         WHERE pps.id_snapshot = v_fila.id_snapshot;

        SELECT COALESCE(SUM(t.precio_resultante), 0)
          INTO v_linea_total
          FROM tmp_ml_componentes t
         WHERE t.idx = v_fila.idx;

        v_precio_unitario := GREATEST(round(v_linea_total / v_fila.unidades, 2), 0.01);
        v_qty_comprada := CASE
            WHEN v_fila.unidad = 'PACK' THEN CEIL(v_fila.unidades::NUMERIC / v_fila.pack) * v_fila.pack
            ELSE v_fila.unidades
        END;
        v_qty_sobrante := GREATEST(v_qty_comprada - v_fila.unidades, 0);

        INSERT INTO cotizacion_item (
            id_cotizacion, id_producto, id_variante, id_precio, producto_snapshot,
            cantidad, precio_unitario, subtotal, moneda, id_tecnica, personalizacion,
            source_mode, id_producto_proveedor, id_precio_proveedor_snapshot,
            proveedor_snapshot, nombre_item_snapshot, sku_proveedor_snapshot,
            costo_compra_unitario_snapshot, unidad_compra_snapshot, cantidad_pack_snapshot,
            cantidad_comprada, cantidad_usada, cantidad_sobrante, metadata_costeo
        )
        VALUES (
            v_id_cotizacion, NULL, NULL, NULL,
            jsonb_build_object(
                'source_mode', 'SUPPLIER_PRODUCT',
                'id_producto_proveedor', v_snapshot.id_producto_proveedor,
                'id_precio_proveedor_snapshot', v_snapshot.id_snapshot,
                'proveedor', v_snapshot.proveedor_nombre,
                'nombre_original', v_snapshot.nombre_original,
                'sku_proveedor', v_snapshot.sku_proveedor,
                'categoria', v_snapshot.categoria,
                'atributos', v_snapshot.atributos,
                'url_fuente', v_snapshot.url_fuente,
                'observado_en', v_snapshot.observado_en
            ),
            v_fila.unidades,
            v_precio_unitario,
            v_linea_total,
            'COP',
            NULL,
            jsonb_build_object('marking_lines', v_fila.marking),
            'SUPPLIER_PRODUCT', v_snapshot.id_producto_proveedor, v_snapshot.id_snapshot,
            jsonb_build_object('id_proveedor', v_snapshot.id_proveedor, 'nombre', v_snapshot.proveedor_nombre),
            v_snapshot.nombre_original, v_snapshot.sku_proveedor,
            COALESCE(v_fila.costo_override, CASE
                WHEN v_fila.unidad = 'PACK' THEN v_snapshot.precio_publicado / v_fila.pack
                ELSE v_snapshot.precio_publicado
            END),
            v_fila.unidad,
            v_snapshot.cantidad_pack,
            v_qty_comprada, v_fila.unidades, v_qty_sobrante,
            jsonb_build_object(
                'linea', v_fila.idx,
                'cantidad_presentaciones', v_fila.presentaciones,
                'motor_version','CLIENT_V2',
                'configuracion_tecnica',v_fila.configuracion,
                'plantilla_margen',v_fila.plantilla,
                'reasignacion_sobrante',v_fila.credito,
                'motivo_ajuste',v_fila.motivo,
                'unidades_por_presentacion', v_fila.pack,
                'unidades_totales', v_fila.unidades,
                'cantidad_comprada', v_qty_comprada,
                'cantidad_usada', v_fila.unidades,
                'cantidad_sobrante', v_qty_sobrante,
                'precio_publicado', v_snapshot.precio_publicado,
                'transporte_linea', v_fila.transporte_linea,
                'transport_mode', v_modo,
                'costos_adicionales', v_fila.extras,
                'costo_unitario_override', v_fila.costo_override,
                'margen_linea_pct', v_fila.margen_linea,
                'retencion_pct', v_fila.retencion
            )
        )
        RETURNING cotizacion_item.id_cotizacion_item INTO v_id_item;

        FOR v_component IN
            SELECT * FROM tmp_ml_componentes t WHERE t.idx = v_fila.idx
             ORDER BY CASE t.tipo_componente
                WHEN 'PRODUCTO' THEN 1 WHEN 'MARCACION' THEN 2 WHEN 'PREPARACION' THEN 3
                WHEN 'EMPAQUE' THEN 4 WHEN 'TRANSPORTE' THEN 5 ELSE 9 END
        LOOP
            INSERT INTO cotizacion_componente (
                id_cotizacion_item, tipo_componente, descripcion, cantidad,
                costo_unitario, costo_total, pricing_method, margen_aplicado_pct,
                precio_resultante, source_type, source_snapshot_id, metadata
            )
            VALUES (
                v_id_item, v_component.tipo_componente, v_component.descripcion,
                v_component.cantidad, v_component.costo_unitario, v_component.costo_total,
                v_component.pricing_method, v_component.margen_aplicado_pct,
                v_component.precio_resultante, v_component.source_type,
                v_component.source_snapshot_id, v_component.metadata
            );
        END LOOP;
    END LOOP;

    INSERT INTO cotizacion_evento (
        id_cotizacion, tipo_evento, estado_anterior, estado_nuevo,
        actor_tipo, actor_id, rol_consola, metadata
    )
    VALUES (
        v_id_cotizacion, 'CREADA', NULL, 'EMITIDA',
        'HUMANO', v_uid, v_rol,
        jsonb_build_object(
            'metodo_precio', 'CALCULO_COMPONENTES',
            'source_mode', 'CLIENT_QUOTE_V2',
            'lineas', v_lineas,
            'total_lineas', v_n_lineas,
            'unidades_totales', v_unidades_totales,
            'transporte_total', v_transporte,
            'transport_mode', v_modo,
            'policy_code', v_policy_code,
            'margen_override_pct', p_margen_override_pct,
            'idempotency_key', v_key
        )
    );

    RETURN QUERY SELECT v_id_cotizacion, v_numero, v_total, v_n_lineas, 'OK'::TEXT;
EXCEPTION WHEN unique_violation THEN
    IF v_key IS NULL THEN
        RAISE;
    END IF;

    SELECT c.id_cotizacion
      INTO v_existing
      FROM cotizacion c
     WHERE c.creada_por = v_uid
       AND c.idempotency_key = v_key
     LIMIT 1;

    IF v_existing IS NOT NULL
       AND public.fn_quote_client_payload_matches(
            v_existing, p_id_organizacion, v_lineas, v_transporte,
            v_modo, v_policy_code, p_margen_override_pct
       ) AND EXISTS (SELECT 1 FROM cotizacion c WHERE c.id_cotizacion = v_existing AND c.notas IS NOT DISTINCT FROM p_notas) THEN
        SELECT c.numero, c.total INTO v_numero, v_total
          FROM cotizacion c
         WHERE c.id_cotizacion = v_existing;
        RETURN QUERY SELECT v_existing, v_numero, v_total, v_n_lineas, 'OK'::TEXT;
        RETURN;
    END IF;

    RETURN QUERY SELECT v_existing, NULL::BIGINT, NULL::NUMERIC, v_n_lineas, 'CONFLICT'::TEXT;
END;
$function$;


REVOKE ALL ON FUNCTION public.fn_quote_client_core(UUID,JSONB,NUMERIC,TEXT,TEXT,NUMERIC,TEXT,TEXT,BOOLEAN,NUMERIC) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_previsualizar_cotizacion_cliente(
    p_id_organizacion uuid, p_lineas jsonb, p_margen_override_pct numeric DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE r record; v_detalle jsonb;
BEGIN
    SELECT * INTO r FROM public.fn_quote_client_core(p_id_organizacion,p_lineas,
      0,'SEPARATE_LINE','MVP_DEFAULT',p_margen_override_pct,NULL,NULL,true,NULL);
    IF r.status <> 'OK' THEN RETURN jsonb_build_object('status',r.status); END IF;
    SELECT jsonb_agg(jsonb_build_object('linea',q.idx,'total',q.total,'unidades',q.unidades,
      'precio_unitario',q.total/q.unidades,'unidades_comprar',q.compradas,
      'cantidad_presentaciones',q.presentaciones,'cantidad_sobrante',q.compradas-q.unidades,
      'costo_total',CASE WHEN fn_consola_rol()='ADMIN' THEN q.costo ELSE NULL END) ORDER BY q.idx)
    INTO v_detalle FROM (
      SELECT l.idx,l.unidades,max(l.presentaciones*l.pack) compradas,max(l.presentaciones) presentaciones,SUM(t.precio_resultante) total,SUM(t.costo_total) costo
      FROM tmp_ml_lineas l JOIN tmp_ml_componentes t ON t.idx=l.idx GROUP BY l.idx,l.unidades
    ) q;
    RETURN jsonb_build_object('status','OK','total',r.total,'lineas',v_detalle);
END;
$$;
REVOKE ALL ON FUNCTION public.fn_consola_previsualizar_cotizacion_cliente(UUID,JSONB,NUMERIC) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fn_consola_previsualizar_cotizacion_cliente(UUID,JSONB,NUMERIC) TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_consola_emitir_cotizacion_cliente(
    p_id_organizacion uuid, p_lineas jsonb, p_total_esperado numeric,
    p_margen_override_pct numeric DEFAULT NULL, p_notas text DEFAULT NULL, p_idempotency_key text DEFAULT NULL
) RETURNS TABLE(id_cotizacion uuid, numero bigint, total numeric, lineas integer, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
    IF p_total_esperado IS NULL OR p_total_esperado <= 0 OR p_total_esperado::text IN ('NaN','Infinity','-Infinity') THEN
      RETURN QUERY SELECT NULL::uuid,NULL::bigint,NULL::numeric,NULL::integer,'INVALID_EXPECTED_TOTAL'::text;
      RETURN;
    END IF;
    RETURN QUERY SELECT * FROM public.fn_quote_client_core(p_id_organizacion,p_lineas,0,
      'SEPARATE_LINE','MVP_DEFAULT',p_margen_override_pct,p_notas,p_idempotency_key,false,p_total_esperado);
END;
$$;
REVOKE ALL ON FUNCTION public.fn_consola_emitir_cotizacion_cliente(UUID,JSONB,NUMERIC,NUMERIC,TEXT,TEXT) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fn_consola_emitir_cotizacion_cliente(UUID,JSONB,NUMERIC,NUMERIC,TEXT,TEXT) TO authenticated;
