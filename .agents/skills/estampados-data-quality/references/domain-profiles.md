# Perfiles de dominio

## Fondos de empleados y otras entidades solidarias

- Identidad primaria: NIT base; DV separado.
- Razón social canónica con tildes; sigla separada; clave de búsqueda sin tildes.
- Territorio por DIVIPOLA. Mantener fuente y fecha del registro oficial.
- Separar email, teléfono, WhatsApp y website en canales individuales. Listas concatenadas se dividen sin perder el valor original.
- Un contacto público o institucional no equivale a consentimiento para campañas.

## Proveedores

- Dedupe preliminar por NIT. Sin NIT, usar nombre + dominio + evidencia y dejar `REVIEW_REQUIRED`.
- Separar nombre legal, comercial y variantes observadas.
- No derivar datos fiscales de una página comercial sin RUT/RUES u otra fuente competente.

## Productos promocionales

- Identidad: proveedor + SKU/product ID; URL/nombre solo como respaldo.
- Mantener nombre visible, clave de búsqueda, categoría interna y opcionalmente UNSPSC/GTIN.
- Precio requiere moneda, unidad, cantidad mínima/máxima, impuestos, vigencia, disponibilidad y URL/fecha de consulta.
- Dimensiones y capacidad deben separar valor y unidad; no convertir texto ambiguo automáticamente.
- Las variantes de color/tamaño son registros o entidades separadas cuando cambian disponibilidad/SKU/precio.

## Técnicas de marcación

- Código controlado ASCII (`dtf_textil`, `sublimacion`, etc.) y etiqueta visible con tildes por separado.
- No confundir técnica, costo de marcación y producto terminado.
- Precio utilizable requiere `service_component`, `price_scope`, unidad, moneda, cantidad y evidencia.
- `NEEDS_REVIEW_UNIT` no entra al cálculo automático.

## Propiedad horizontal / conjuntos residenciales

- Identidad territorial: `record_id` + fuente; NIT solo cuando la fuente lo publica.
- Ubicación por DIVIPOLA y dirección canónica; no deduplicar únicamente por nombre.
- Mantener separados `legal_representative` y `contact_person`.
- La fuente pública territorial no certifica por sí sola vigencia actual de representación.
- Email/teléfono/WhatsApp públicos se conservan con URL, fecha, alcance y confianza.
- La base no cargada debe pasar por `INVALID=0` y revisión documentada de coincidencias difusas antes de migración.
