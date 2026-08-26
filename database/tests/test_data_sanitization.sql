-- Validacion del saneamiento visible y de telefonos colombianos.
BEGIN;

DO $$
BEGIN
    ASSERT fn_sanitize_visible_text(E'  "Árbol\n  de   Bogotá"  ') = 'Árbol de Bogotá';
    ASSERT fn_text_search_key('Árbol de Bogotá') = 'arbol_de_bogota';
    ASSERT fn_normalize_colombian_phone('+57 (601) 234-5678') = '6012345678';
    ASSERT fn_normalize_colombian_phone('0057 320 123 4567') = '3201234567';
    ASSERT fn_classify_colombian_phone('6027654321') = 'FIJO';
    ASSERT fn_classify_colombian_phone('3117654321') = 'CELULAR';
    ASSERT fn_classify_colombian_phone('6037654321') = 'INVALIDO';
    ASSERT fn_classify_colombian_phone('3507654321') = 'MOVIL_TRUNKING';
    ASSERT fn_classify_colombian_phone('3407654321') = 'RANGO_NO_ATRIBUIDO';
    ASSERT fn_classify_colombian_phone('2117654321') = 'INVALIDO';
    RAISE NOTICE 'PASSED - funciones puras de saneamiento';
END;
$$;

INSERT INTO organizacion (
    id_organizacion, nit, nombre_legal, nombre_comercial, direccion
) VALUES (
    '00000000-0000-4000-b000-000000000048',
    '999000048',
    E'  "Organización\n de   Prueba"  ',
    'Compañía “Única”',
    E'  Calle  1\t Bogotá '
);

INSERT INTO canal_contacto (
    id_canal_contacto, id_organizacion, tipo, valor_original,
    valor_normalizado, fuente
) VALUES
(
    '00000000-0000-4000-b000-000000000049',
    '00000000-0000-4000-b000-000000000048',
    'TELEFONO',
    '+57 (601) 234-5678',
    '+57 (601) 234-5678',
    E'  "Directorio\n público" '
),
(
    '00000000-0000-4000-b000-000000000050',
    '00000000-0000-4000-b000-000000000048',
    'WHATSAPP',
    '+57 320 123 4567',
    '+57 320 123 4567',
    'Web pública'
),
(
    '00000000-0000-4000-b000-000000000051',
    '00000000-0000-4000-b000-000000000048',
    'TELEFONO',
    '123 45',
    '123 45',
    'fixture'
);

DO $$
DECLARE
    v_org organizacion%ROWTYPE;
    v_fijo canal_contacto%ROWTYPE;
    v_celular canal_contacto%ROWTYPE;
    v_invalido canal_contacto%ROWTYPE;
BEGIN
    SELECT * INTO v_org FROM organizacion
     WHERE id_organizacion = '00000000-0000-4000-b000-000000000048';
    ASSERT v_org.nombre_legal = 'Organización de Prueba';
    ASSERT v_org.nombre_comercial = 'Compañía “Única”';
    ASSERT v_org.nombre_legal_busqueda = 'organizacion_de_prueba';
    ASSERT v_org.direccion = 'Calle 1 Bogotá';

    SELECT * INTO v_fijo FROM canal_contacto
     WHERE id_canal_contacto = '00000000-0000-4000-b000-000000000049';
    ASSERT v_fijo.valor_original = '+57 (601) 234-5678', 'valor_original debe conservar evidencia';
    ASSERT v_fijo.valor_normalizado = '6012345678';
    ASSERT v_fijo.telefono_clasificacion = 'FIJO';
    ASSERT v_fijo.telefono_codigo_area = '601';
    ASSERT v_fijo.telefono_numero_local = '2345678';
    ASSERT v_fijo.fuente = 'Directorio público';

    SELECT * INTO v_celular FROM canal_contacto
     WHERE id_canal_contacto = '00000000-0000-4000-b000-000000000050';
    ASSERT v_celular.valor_normalizado = '3201234567';
    ASSERT v_celular.telefono_clasificacion = 'CELULAR';
    ASSERT v_celular.telefono_codigo_area IS NULL;

    SELECT * INTO v_invalido FROM canal_contacto
     WHERE id_canal_contacto = '00000000-0000-4000-b000-000000000051';
    ASSERT v_invalido.telefono_clasificacion = 'INVALIDO';
    ASSERT v_invalido.estado = 'INVALID';
    RAISE NOTICE 'PASSED - triggers saneamiento y clasificacion';
END;
$$;

ROLLBACK;
