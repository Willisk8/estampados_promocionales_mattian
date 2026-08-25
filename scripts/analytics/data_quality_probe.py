"""
Extrae métricas de calidad de datos desde Supabase STAGING.
Genera JSON con todos los indicadores para el reporte ETAPA 6.

Uso:
  python scripts/analytics/data_quality_probe.py > docs/data_quality_raw.json
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "import"))
from _shared import load_env

import psycopg
from psycopg.rows import dict_row


QUERIES = {
    "resumen_general": """
        SELECT
            (SELECT COUNT(*) FROM organizacion)             AS total_organizaciones,
            (SELECT COUNT(*) FROM persona)                  AS total_personas,
            (SELECT COUNT(*) FROM persona_organizacion)     AS total_relaciones,
            (SELECT COUNT(*) FROM canal_contacto)           AS total_canales,
            (SELECT COUNT(*) FROM contactabilidad)          AS total_contactabilidad,
            (SELECT COUNT(*) FROM import_batch)             AS total_batches,
            (SELECT COUNT(*) FROM import_raw_row)           AS total_raw_rows,
            (SELECT COUNT(*) FROM import_review_item WHERE resolution_status = 'OPEN') AS items_revision_abiertos
    """,

    "distribucion_tipo_entidad": """
        SELECT
            tipo_entidad_origen,
            COUNT(*)                                              AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS pct
        FROM organizacion
        GROUP BY tipo_entidad_origen
        ORDER BY n DESC
    """,

    "cobertura_nit": """
        SELECT
            COUNT(*) FILTER (WHERE nit IS NOT NULL AND nit <> '')  AS con_nit,
            COUNT(*) FILTER (WHERE nit IS NULL OR nit = '')        AS sin_nit,
            COUNT(*)                                               AS total,
            ROUND(
                COUNT(*) FILTER (WHERE nit IS NOT NULL AND nit <> '') * 100.0 / COUNT(*),
                2
            ) AS pct_con_nit
        FROM organizacion
    """,

    "cobertura_estado": """
        SELECT
            estado,
            COUNT(*)                                              AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS pct
        FROM organizacion
        GROUP BY estado
        ORDER BY n DESC
    """,

    "top_departamentos": """
        SELECT
            COALESCE(departamento, '(sin departamento)')         AS departamento,
            COUNT(*)                                             AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
        FROM organizacion
        GROUP BY departamento
        ORDER BY n DESC
        LIMIT 20
    """,

    "top_municipios": """
        SELECT
            COALESCE(municipio, '(sin municipio)')               AS municipio,
            COALESCE(departamento, '')                           AS departamento,
            COUNT(*)                                             AS n
        FROM organizacion
        GROUP BY municipio, departamento
        ORDER BY n DESC
        LIMIT 20
    """,

    "canales_por_tipo": """
        SELECT
            tipo,
            COUNT(*)                                              AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS pct
        FROM canal_contacto
        GROUP BY tipo
        ORDER BY n DESC
    """,

    "cobertura_email_por_org": """
        SELECT
            COUNT(DISTINCT o.id_organizacion) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM canal_contacto cc
                    WHERE cc.id_organizacion = o.id_organizacion AND cc.tipo = 'EMAIL'
                )
            )  AS orgs_con_email,
            COUNT(DISTINCT o.id_organizacion) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM canal_contacto cc
                    WHERE cc.id_organizacion = o.id_organizacion AND cc.tipo = 'TELEFONO'
                )
            )  AS orgs_con_telefono,
            COUNT(DISTINCT o.id_organizacion) FILTER (
                WHERE EXISTS (
                    SELECT 1 FROM canal_contacto cc
                    WHERE cc.id_organizacion = o.id_organizacion AND cc.tipo = 'WHATSAPP'
                )
            )  AS orgs_con_whatsapp,
            COUNT(DISTINCT o.id_organizacion) AS total_orgs
        FROM organizacion o
    """,

    "contactos_por_org": """
        SELECT
            COUNT(*) FILTER (WHERE contactos = 0) AS sin_contacto,
            COUNT(*) FILTER (WHERE contactos = 1) AS un_contacto,
            COUNT(*) FILTER (WHERE contactos BETWEEN 2 AND 5) AS dos_a_cinco,
            COUNT(*) FILTER (WHERE contactos > 5) AS mas_de_cinco,
            ROUND(AVG(contactos), 2) AS promedio_contactos,
            MAX(contactos) AS max_contactos
        FROM (
            SELECT o.id_organizacion, COUNT(cc.id_canal_contacto) AS contactos
            FROM organizacion o
            LEFT JOIN canal_contacto cc ON cc.id_organizacion = o.id_organizacion
            GROUP BY o.id_organizacion
        ) sub
    """,

    "top_dominios_email": """
        SELECT
            LOWER(SPLIT_PART(valor_normalizado, '@', 2))         AS dominio,
            COUNT(*)                                             AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 3) AS pct
        FROM canal_contacto
        WHERE tipo = 'EMAIL'
          AND valor_normalizado IS NOT NULL
          AND valor_normalizado LIKE '%@%'
        GROUP BY LOWER(SPLIT_PART(valor_normalizado, '@', 2))
        ORDER BY n DESC
        LIMIT 40
    """,

    "clasificacion_email": """
        SELECT
            CASE
                WHEN LOWER(SPLIT_PART(valor_normalizado, '@', 2)) IN (
                    'gmail.com','hotmail.com','yahoo.com','outlook.com',
                    'live.com','icloud.com','hotmail.es','yahoo.es',
                    'gmail.es','aol.com','msn.com','me.com'
                ) THEN 'personal'
                WHEN LOWER(SPLIT_PART(valor_normalizado, '@', 1)) ~
                    '^(info|contacto|contact|admin|administracion|gerencia|secretaria|'
                    'contabilidad|compras|ventas|comercial|director|presidencia|'
                    'tesoreria|cartera|servicio|servicios|atencion|soporte|'
                    'correspondencia|comunicaciones|recursos)$'
                THEN 'rol'
                ELSE 'corporativo'
            END AS tipo_email,
            COUNT(*)                                              AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS pct
        FROM canal_contacto
        WHERE tipo = 'EMAIL'
          AND valor_normalizado IS NOT NULL
          AND valor_normalizado LIKE '%@%'
        GROUP BY tipo_email
        ORDER BY n DESC
    """,

    "emails_rol_top": """
        SELECT
            LOWER(SPLIT_PART(valor_normalizado, '@', 1)) AS local_part,
            COUNT(*)                                     AS n
        FROM canal_contacto
        WHERE tipo = 'EMAIL'
          AND valor_normalizado IS NOT NULL
          AND LOWER(SPLIT_PART(valor_normalizado, '@', 1)) ~
              '^(info|contacto|contact|admin|administracion|gerencia|secretaria|'
              'contabilidad|compras|ventas|comercial|director|presidencia|'
              'tesoreria|cartera|servicio|servicios|atencion|soporte|'
              'correspondencia|comunicaciones|recursos)$'
        GROUP BY local_part
        ORDER BY n DESC
    """,

    "validez_email_formato": """
        SELECT
            COUNT(*) FILTER (
                WHERE valor_normalizado ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
            ) AS formato_valido,
            COUNT(*) FILTER (
                WHERE valor_normalizado IS NOT NULL
                  AND valor_normalizado NOT LIKE '%@%'
            ) AS sin_arroba,
            COUNT(*) FILTER (WHERE valor_normalizado IS NULL) AS nulo,
            COUNT(*) AS total
        FROM canal_contacto
        WHERE tipo = 'EMAIL'
    """,

    "cobertura_email_hash": """
        SELECT
            COUNT(*) FILTER (WHERE email_hash IS NOT NULL) AS con_hash,
            COUNT(*) FILTER (WHERE email_hash IS NULL)     AS sin_hash,
            COUNT(*)                                       AS total
        FROM canal_contacto
        WHERE tipo = 'EMAIL'
    """,

    "confianza_canal": """
        SELECT
            tipo,
            confianza,
            COUNT(*) AS n
        FROM canal_contacto
        GROUP BY tipo, confianza
        ORDER BY tipo, n DESC
    """,

    "estado_canal": """
        SELECT
            tipo,
            estado,
            COUNT(*) AS n
        FROM canal_contacto
        GROUP BY tipo, estado
        ORDER BY tipo, n DESC
    """,

    "revision_items_severidad": """
        SELECT
            severity,
            resolution_status,
            COUNT(*) AS n
        FROM import_review_item
        GROUP BY severity, resolution_status
        ORDER BY n DESC
    """,

    "fuentes_registro": """
        SELECT
            fuente_registro,
            COUNT(*)                                              AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)  AS pct
        FROM organizacion
        GROUP BY fuente_registro
        ORDER BY n DESC
    """,

    "completitud_campos_org": """
        SELECT
            ROUND(COUNT(*) FILTER (WHERE nombre_legal      IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_nombre_legal,
            ROUND(COUNT(*) FILTER (WHERE nit               IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_nit,
            ROUND(COUNT(*) FILTER (WHERE nombre_comercial  IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_nombre_comercial,
            ROUND(COUNT(*) FILTER (WHERE sigla             IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_sigla,
            ROUND(COUNT(*) FILTER (WHERE departamento      IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_departamento,
            ROUND(COUNT(*) FILTER (WHERE municipio         IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_municipio,
            ROUND(COUNT(*) FILTER (WHERE direccion         IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_direccion,
            ROUND(COUNT(*) FILTER (WHERE fecha_reporte_oficial IS NOT NULL) * 100.0 / COUNT(*), 1) AS pct_fecha_reporte
        FROM organizacion
    """,

    "catalogo_resumen": """
        SELECT
            (SELECT COUNT(*) FROM proveedor)                                       AS total_proveedores,
            (SELECT COUNT(*) FROM producto_proveedor)                              AS total_productos,
            (SELECT COUNT(*) FROM precio_proveedor_snapshot)                       AS total_snapshots,
            (SELECT COUNT(*) FROM producto_proveedor WHERE estado_calidad = 'VALID')  AS productos_valid,
            (SELECT COUNT(*) FROM producto_proveedor WHERE estado_calidad = 'PENDING_REVIEW') AS productos_pending,
            (SELECT COUNT(*) FROM producto_proveedor WHERE estado_calidad = 'NEEDS_REVIEW')   AS productos_review
    """,

    "catalogo_por_proveedor": """
        SELECT
            p.nombre                                                              AS proveedor,
            COUNT(pp.id_producto_proveedor)                                       AS productos,
            COUNT(pps.id_snapshot)                                                AS snapshots,
            ROUND(AVG(pps.precio_publicado)::numeric, 0)                         AS precio_promedio,
            MIN(pps.precio_publicado)                                             AS precio_min,
            MAX(pps.precio_publicado)                                             AS precio_max
        FROM proveedor p
        LEFT JOIN producto_proveedor pp ON pp.id_proveedor = p.id_proveedor
        LEFT JOIN precio_proveedor_snapshot pps ON pps.id_producto_proveedor = pp.id_producto_proveedor
        GROUP BY p.nombre
        ORDER BY productos DESC
    """,

    "catalogo_distribucion_precio": """
        SELECT
            CASE
                WHEN precio_publicado IS NULL          THEN 'sin_precio'
                WHEN precio_publicado = 0              THEN 'precio_cero'
                WHEN precio_publicado < 5000           THEN '< $5.000'
                WHEN precio_publicado < 20000          THEN '$5.000 - $19.999'
                WHEN precio_publicado < 50000          THEN '$20.000 - $49.999'
                WHEN precio_publicado < 100000         THEN '$50.000 - $99.999'
                WHEN precio_publicado < 500000         THEN '$100.000 - $499.999'
                ELSE '>= $500.000'
            END AS rango_precio,
            COUNT(*) AS n
        FROM precio_proveedor_snapshot
        GROUP BY rango_precio
        ORDER BY MIN(COALESCE(precio_publicado, -1))
    """,

    "catalogo_categorias": """
        SELECT
            COALESCE(categoria, '(sin categoría)')                               AS categoria,
            COUNT(*)                                                             AS n,
            ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2)                 AS pct
        FROM producto_proveedor
        GROUP BY categoria
        ORDER BY n DESC
        LIMIT 25
    """,
}


def run():
    db_url = load_env()
    results = {}

    with psycopg.connect(db_url, row_factory=dict_row, prepare_threshold=None) as conn:
        with conn.cursor() as cur:
            for name, sql in QUERIES.items():
                try:
                    cur.execute(sql)
                    rows = cur.fetchall()
                    # Convertir a tipos serializables
                    results[name] = [
                        {k: float(v) if hasattr(v, '__float__') and not isinstance(v, (int, bool)) else v
                         for k, v in row.items()}
                        for row in rows
                    ]
                except Exception as e:
                    results[name] = {"error": str(e)}

    print(json.dumps(results, indent=2, default=str, ensure_ascii=False))


if __name__ == "__main__":
    run()
