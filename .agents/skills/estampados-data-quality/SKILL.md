---
name: estampados-data-quality
description: Audita, normaliza y prepara para carga los datos colombianos de Estampados, incluyendo organizaciones solidarias, contactos, productos, proveedores, técnicas de marcación y propiedad horizontal. Úsala al revisar CSV/XLSX, importadores o migraciones; no la uses para modificar datos vivos sin autorización explícita.
---

# Estampados Data Quality

Produce datos utilizables sin destruir evidencia ni convertir incertidumbre en hechos.

## Invariantes

- Conserva el archivo/fila/campo crudo y escribe la versión normalizada aparte.
- Usa Unicode NFC para texto canónico. Conserva tildes y puntuación significativa; genera una clave ASCII separada solo para búsqueda o deduplicación.
- No recuperes caracteres `�` por intuición. Reconsulta la fuente o marca revisión. Repara mojibake únicamente cuando la conversión sea reversible.
- Separa `VALID`, `REVIEW_REQUIRED` e `INVALID`. Una forma válida no demuestra que el teléfono, email, NIT o entidad exista o esté activo.
- No fusiones registros por nombre solamente. Exige identificador estable o evidencia suficiente y conserva el linaje.
- No transformes `contact_person` en `legal_representative` ni infieras consentimiento comercial.
- No sobrescribas snapshots históricos de precios; agrega observaciones nuevas.
- Toda escritura en Supabase requiere vista previa, respaldo lógico o transacción de ensayo y autorización explícita para el entorno indicado.

## Flujo

1. Inventaría las fuentes actuales y sus esquemas; distingue crudo, procesado y cargado.
2. Lee [references/standards.md](references/standards.md) para reglas transversales.
3. Lee únicamente los perfiles aplicables en [references/domain-profiles.md](references/domain-profiles.md).
4. Ejecuta `python scripts/data_quality/audit_datasets.py --output-dir outputs/data_quality_<fecha>` desde la raíz del proyecto cuando las rutas estándar estén disponibles.
5. Revisa `resumen_calidad.json` e `incidencias_calidad.csv`; no cargues filas `INVALID` y exige resolución o aceptación documentada para `REVIEW_REQUIRED`.
6. Valida conteos, unicidad, FKs, formatos y una muestra visual del workbook/CSV antes de entregar o migrar.

## Salidas mínimas

- Copias normalizadas por dominio, sin sobrescribir fuentes.
- Incidencias con dataset, fila, campo, código, severidad, valor crudo y normalizado.
- Resumen con conteos por estado y estándar aplicado.
- Límites explícitos: qué se validó sintácticamente, qué se contrastó con catálogo oficial y qué necesita verificación externa.
