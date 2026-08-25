# Reporte de calidad de datos - Supabase STAGING

Fecha de corte: 2026-08-24  
Base evaluada: Supabase STAGING, migraciones `000` a `012`, cargas piloto y full de entidades/catalogo.

## Veredicto ejecutivo

Score operativo estimado: **87/100**.

La base ya esta lista para trabajo interno de CRM, curacion comercial y analisis de catalogo proveedor. No esta lista aun para campanas automatizadas: todos los contactos entraron con contactabilidad `DESCONOCIDA` y hay 824 items abiertos de revision.

## KPIs principales

| Indicador | Valor | Lectura |
|---|---:|---|
| Organizaciones | 5,639 | Carga completa del sector solidario |
| Personas | 4,642 | Representantes legales disponibles |
| Relaciones persona-organizacion | 4,642 | Relacion representante legal cargada |
| Canales de contacto | 16,211 | Email, telefono, WhatsApp y website |
| Contactabilidad | 16,211 | Paridad 1:1 con canales |
| Batches de importacion | 4 | Piloto y full separados |
| Filas raw trazables | 33,399 | Trazabilidad completa por batch |
| Items abiertos de revision | 824 | Deben revisarse antes de activar uso comercial |

## Cobertura

| Dimension | Valor |
|---|---:|
| NIT presente | 100.0% |
| Nombre legal | 100.0% |
| Fecha reporte oficial | 100.0% |
| Sigla | 95.8% |
| Departamento | 99.9% |
| Municipio | 99.9% |
| Direccion | 99.9% |
| Nombre comercial | 0.0% |

## Distribucion de organizaciones

| Tipo de entidad | Organizaciones | % |
|---|---:|---:|
| Fondos de empleados | 1,911 | 33.89% |
| Multiactiva sin seccion de ahorro | 1,771 | 31.41% |
| Cooperativas de trabajo asociado | 585 | 10.37% |
| Especializada sin seccion de ahorro | 431 | 7.64% |
| Asociaciones mutuales | 225 | 3.99% |
| Otras categorias | 716 | 12.70% |

## Canales de contacto

| Tipo | Canales | % |
|---|---:|---:|
| TELEFONO | 7,857 | 48.47% |
| EMAIL | 7,371 | 45.47% |
| WEBSITE | 575 | 3.55% |
| WHATSAPP | 408 | 2.52% |

Cobertura por organizacion:

| Cobertura | Organizaciones |
|---|---:|
| Con email | 5,628 |
| Con telefono | 5,374 |
| Con WhatsApp | 188 |
| Sin contacto | 3 |

## Emails

| Clasificacion | Emails | % |
|---|---:|---:|
| Personal | 3,491 | 47.36% |
| Corporativo | 2,879 | 39.06% |
| Rol | 1,001 | 13.58% |

Formato y seguridad:

| Control | Resultado |
|---|---:|
| Emails con formato valido | 7,371 / 7,371 |
| Emails con hash HMAC | 7,371 / 7,371 |
| Emails sin arroba | 0 |

Top dominios:

| Dominio | Emails | Nota |
|---|---:|---|
| gmail.com | 1,925 | Personal |
| hotmail.com | 1,207 | Personal |
| yahoo.es | 169 | Personal |
| yahoo.com | 115 | Personal |
| usbmed.edu.co | 72 | Institucional |
| cooprudea.com | 71 | Corporativo |
| outlook.com | 58 | Personal |
| coomservi.combogot | 28 | Revisar malformacion |
| colegiocoomeva.edu.codocente | 19 | Revisar malformacion |
| fbcsena.comauxiliar | 11 | Revisar malformacion |

## Catalogo proveedor

| Indicador | Valor |
|---|---:|
| Proveedores | 7 |
| Productos proveedor | 935 |
| Snapshots de precio | 934 |
| Productos validos | 934 |
| Productos en revision | 1 |

Distribucion por proveedor:

| Proveedor | Productos | Snapshots | Precio min | Precio max | Alerta |
|---|---:|---:|---:|---:|---|
| Esferos.com / Boton Promo SAS | 608 | 608 | 60 | 50,000 | Precios muy bajos a revisar |
| Sublifly / Sublimatic SAS | 133 | 133 | 4,500 | 75,000 | OK |
| Tienda FLA / Grupo FLA SAS | 120 | 119 | 1,983 | 649,740 | 1 producto sin snapshot |
| INGenios Maquinando Ideas | 50 | 50 | 3,500 | 127,000 | OK |
| Colorisa Studio | 12 | 12 | 2,800 | 92,000 | OK |
| NaturalGraphic | 8 | 8 | 5 | 20,000 | Precios artefactuales |
| Verona Studio | 4 | 4 | 22,000 | 1,200,000 | Posibles planes/no productos |

Distribucion de precios:

| Rango | Snapshots |
|---|---:|
| < $5,000 | 380 |
| $5,000 - $19,999 | 305 |
| $20,000 - $49,999 | 202 |
| $50,000 - $99,999 | 33 |
| $100,000 - $499,999 | 12 |
| >= $500,000 | 2 |

## Hallazgos

| Severidad | Hallazgo | Estado |
|---|---|---|
| OK | Migraciones `000` a `012` aplicadas en STAGING | Cerrado |
| OK | Cargas piloto y completas separadas por batch | Cerrado |
| OK | `contactabilidad` tiene paridad 1:1 con `canal_contacto` | Cerrado |
| OK | `email_hash` calculado para todos los emails | Cerrado |
| OK | Catalogo proveedor cargado completo | Cerrado |
| Advertencia | 824 items abiertos de revision | Requiere curacion |
| Advertencia | 47.36% de emails son personales | Segmentar antes de contactar |
| Advertencia | 575 websites son candidatos, no necesariamente validacion manual | Mantener confianza separada |
| Advertencia | `nombre_comercial` tiene 0% de completitud | Definir fuente o dejar fuera del MVP |
| Advertencia | Dominios malformados detectados por concatenacion | Crear limpieza especifica |
| Error de datos | Precios extremos en NaturalGraphic, Verona y algunos productos de Esferos.com | Revisar antes de usar para margenes |

## Recomendaciones priorizadas

| Prioridad | Recomendacion |
|---|---|
| Alta | Resolver o clasificar los 824 `import_review_item` abiertos antes de campanas. |
| Alta | No habilitar campanas hasta cambiar contactabilidad de `DESCONOCIDA` a una base valida y auditable. |
| Alta | Crear regla de cuarentena para emails/dominos malformados por concatenacion. |
| Alta | Marcar NaturalGraphic y Verona como proveedores con revision de precio antes de costeo. |
| Media | Crear vista `vw_organizacion_contacto_resumen` para CRM y validacion diaria. |
| Media | Crear reporte de organizaciones sin contacto o con solo email personal. |
| Media | Normalizar categorias de catalogo proveedor a taxonomia propia. |
| Baja | Definir si `nombre_comercial` se elimina del MVP o se pobla desde una fuente futura. |

## Siguiente etapa

La siguiente etapa recomendada es crear una capa de consultas operativas:

1. `vw_organizacion_contacto_resumen`
2. `vw_import_review_open`
3. `vw_catalogo_proveedor_quality`
4. `vw_campaign_eligibility_queue`

Estas vistas no activan campanas; solo dejan el CRM listo para revision humana y priorizacion comercial.
