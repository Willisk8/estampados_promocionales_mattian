-- ============================================================
-- 053_allow_admin_storage_image_upsert.sql
--
-- Corrige la incompatibilidad entre el importador de imagenes, que usa
-- x-upsert=true para hacer reintentos idempotentes, y las policies de
-- Storage creadas en 028, que solo permitian INSERT.
--
-- No se edita 028 porque ya fue aplicada. La escritura sigue limitada al
-- bucket privado catalogo-proveedor y al rol interno ADMIN.
-- ============================================================

DROP POLICY IF EXISTS consola_admin_actualiza_catalogo ON storage.objects;
CREATE POLICY consola_admin_actualiza_catalogo ON storage.objects
    FOR UPDATE TO authenticated
    USING (bucket_id = 'catalogo-proveedor' AND public.fn_consola_rol() = 'ADMIN')
    WITH CHECK (bucket_id = 'catalogo-proveedor' AND public.fn_consola_rol() = 'ADMIN');
