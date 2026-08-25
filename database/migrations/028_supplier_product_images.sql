-- ============================================================
-- 028_supplier_product_images.sql
--
-- Guarda las imagenes de los productos de proveedor en Supabase Storage, con
-- registro de procedencia.
--
-- DE DONDE SALEN
-- El scraping ya trajo la URL de la imagen y quedo enterrada en
-- producto_proveedor.atributos->>'image_url': 911 de los 935 productos la
-- tienen. No hace falta volver a rastrear nada, solo descargar y guardar.
--
-- POR QUE COPIARLAS
-- Son URLs de CDN ajeno. Si el proveedor cambia o borra la imagen, la ficha
-- queda rota y se pierde la evidencia de como se veia el producto cuando se
-- observo su precio. Copiarlas fija esa evidencia junto al snapshot.
--
-- La tabla registra url_origen y capturada_en, asi que siempre se puede decir
-- de donde salio cada archivo y cuando.
-- ============================================================

-- ----------------------------------------------------------
-- 1. Bucket privado
-- ----------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'catalogo-proveedor',
    'catalogo-proveedor',
    false,                                  -- privado: se sirve con la sesion
    5242880,                                -- 5 MB por archivo
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- Lectura para cualquier perfil de consola; escritura solo para ADMIN y para
-- los roles de backend, que son los que corren el script de descarga.
DROP POLICY IF EXISTS consola_lee_catalogo ON storage.objects;
CREATE POLICY consola_lee_catalogo ON storage.objects
    FOR SELECT TO authenticated
    USING (bucket_id = 'catalogo-proveedor' AND public.fn_consola_puede_leer());

DROP POLICY IF EXISTS consola_admin_escribe_catalogo ON storage.objects;
CREATE POLICY consola_admin_escribe_catalogo ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'catalogo-proveedor' AND public.fn_consola_rol() = 'ADMIN');

-- ----------------------------------------------------------
-- 2. Procedencia de cada imagen
-- ----------------------------------------------------------
CREATE TABLE imagen_producto_proveedor (
    id_imagen              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    id_producto_proveedor  UUID        NOT NULL
                           REFERENCES producto_proveedor(id_producto_proveedor)
                           ON DELETE CASCADE,
    url_origen             TEXT        NOT NULL,
    ruta_storage           TEXT,
    content_type           TEXT,
    bytes                  INTEGER,
    capturada_en           TIMESTAMPTZ,
    estado                 TEXT        NOT NULL DEFAULT 'PENDIENTE'
                           CHECK (estado IN ('PENDIENTE', 'DESCARGADA', 'FALLIDA', 'OMITIDA')),
    error                  TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_imagen_producto UNIQUE (id_producto_proveedor, url_origen)
);

ALTER TABLE imagen_producto_proveedor ENABLE ROW LEVEL SECURITY;

CREATE POLICY deny_insert ON imagen_producto_proveedor AS RESTRICTIVE FOR INSERT WITH CHECK (false);
CREATE POLICY deny_update ON imagen_producto_proveedor AS RESTRICTIVE FOR UPDATE USING (false);
CREATE POLICY deny_delete ON imagen_producto_proveedor AS RESTRICTIVE FOR DELETE USING (false);

CREATE POLICY consola_read ON imagen_producto_proveedor
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (fn_consola_puede_leer());

CREATE POLICY consola_read_guard ON imagen_producto_proveedor
    AS RESTRICTIVE FOR SELECT
    USING (fn_consola_puede_leer());

REVOKE ALL   ON imagen_producto_proveedor FROM anon, authenticated;
GRANT SELECT ON imagen_producto_proveedor TO authenticated;

CREATE INDEX idx_imagen_producto ON imagen_producto_proveedor (id_producto_proveedor);
CREATE INDEX idx_imagen_estado   ON imagen_producto_proveedor (estado);

CREATE TRIGGER trg_imagen_updated_at
    BEFORE UPDATE ON imagen_producto_proveedor
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

COMMENT ON TABLE imagen_producto_proveedor IS
    'Imagenes de catalogo de proveedor copiadas a Storage. url_origen y '
    'capturada_en conservan la procedencia de cada archivo.';

-- ----------------------------------------------------------
-- 3. Sembrar las pendientes desde lo que ya trajo el scraping
-- ----------------------------------------------------------
INSERT INTO imagen_producto_proveedor (id_producto_proveedor, url_origen)
SELECT pp.id_producto_proveedor, pp.atributos->>'image_url'
  FROM producto_proveedor pp
 WHERE pp.atributos->>'image_url' ~* '^https?://.+\.(jpg|jpeg|png|webp|gif)(\?.*)?$'
ON CONFLICT (id_producto_proveedor, url_origen) DO NOTHING;
