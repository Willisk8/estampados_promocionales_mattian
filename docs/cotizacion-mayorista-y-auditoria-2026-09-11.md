# Correcciones y cotización por volumen — 11 de septiembre de 2026

> Actualización: la recuperación de Supabase, las migraciones remotas y las pruebas
> reales de PDF terminaron después de este informe. Consulta el
> [cierre del 16 de septiembre](cierre-supabase-2026-09-16.md) para el estado vigente.

## Estado

Cambios locales, sin commit, push ni despliegue remoto. Se conservaron los cambios que ya existían en el checkout. La aplicación está levantada en http://127.0.0.1:3000. Su configuración todavía apunta a Supabase remoto: ese dominio no resuelve, por lo que el login y el CRM autenticado no están operativos. No se sustituyeron sus datos por los fixtures de auditoría.

Para validar SQL se instaló PostgreSQL portable en `tmp/postgres-portable`, escuchando exclusivamente en `127.0.0.1:55432`. La base aislada `estampados_audit_final` tiene las migraciones 000–078 y los fixtures. Las migraciones nuevas 077/078 solo se aplicaron allí; el estado remoto sigue sin verificarse.

## Hallazgos corregidos

| Hallazgo | Corrección y evidencia |
|---|---|
| H1: los decimales cambiaban al perder foco | Conversión monetaria común, formato editable con decimales y manejo del foco. Chromium conserva `18.000,50` como 18000,5. |
| H2: costos y eventos accesibles directamente | RLS de ítems y eventos restringida a ADMIN; las RPC mantienen sus salidas por rol. Pruebas con roles ADMIN, COMERCIAL y LECTURA. |
| H3: PDF de ADMIN visible por otros roles | Lectura de documentos y objetos filtrada por rol, validación del archivo registrado y protección frente a registrar un PDF ajeno como propio. |
| H4: respuesta tardía cambiaba el producto seleccionado | Identificador de solicitud e invalidación al cambiar selección. Prueba con respuesta A lenta y B rápida. |
| H5: contraseñas QA incrustadas | Se retiraron los literales de seis scripts; requieren variables de entorno. No se ha podido rotar la credencial remota ni verificar si sigue vigente. |
| H6: PDF archivado sobrescribible | Nombres únicos, `upsert: false` y política restrictiva de actualización. Solo se permite limpiar objetos propios todavía no registrados; se prueba también la degradación de rol de un ADMIN. |
| H7: costo total perdido cuando el unitario era nulo | Reconstrucción que distingue ausencia, cero, costo por unidad y costo fijo. Conserva los decimales. |
| Costo editado y retenciones no llegaban a emisión | Nuevos campos validados en servidor, snapshot de costo aplicado y previsualización calculada por el mismo motor que emite. Los ajustes internos requieren ADMIN. |
| Cliente fuera de las primeras 120 organizaciones | Búsqueda en servidor por nombre o NIT, conservando el cliente seleccionado. |
| Archivado PDF fallaba sin aviso | Error explícito si falla Storage o registro; limpieza del objeto no registrado. |
| Selector de producto fallaba al reabrir o usar teclado | Apertura explícita, selección por click/teclado y eliminación de la carrera del cierre por blur. |
| Dependencias y auditor automático | Actualizaciones de PostCSS y sharp; detección de encabezados SQL corregida para no señalar comentarios como funciones sin search_path. |

Al modificar una cotización se recuperan cantidades y costos, incluyendo costos fijos. La interfaz avisa que los controles de margen y retenciones empiezan con los valores de la calculadora: se revisan y validan antes de emitir una nueva cotización. No se modifica la original.

## Precio por mayor

No hay una regla universal que obligue a descontar exactamente desde 12, 30 o 50 unidades. Printful, por ejemplo, aplica sus propias cantidades y condiciones por producto: [condiciones de descuentos](https://help.printful.com/hc/en-us/articles/360014009700-Are-there-any-discounts-for-bulk-orders) y [pedidos al por mayor](https://www.printful.com/bulk-orders). Los umbrales implementados responden a la necesidad del negocio, no a una tarifa oficial del mercado.

Para cada línea:

1. Costo = costo variable unitario × unidades + costos fijos de esa línea + parte de gastos generales.
2. Los gastos generales se distribuyen en proporción al costo de las líneas.
3. Sin retenciones, venta = costo / (1 − margen / 100). Un margen de 40% significa dividir entre 0,60; sumar 40% al costo produce un margen de 28,57%.
4. Si se declara una retención efectiva, el modelo busca conservar el margen sobre lo recibido: venta = costo / ((1 − margen / 100) × (1 − retención / 100)). No calcula obligaciones tributarias ni decide tasas aplicables; estas empiezan en cero y son configurables.
5. El servidor aplica el redondeo comercial. La previsualización muestra el total emitible, y emitir vuelve a calcularlo y rechaza cambios de total.

El criterio de cubrir materiales, trabajo y otros costos al fijar precios coincide con la [guía de precios de Shopify](https://help.shopify.com/en/manual/products/details/product-pricing/determine-pricing). La fórmula anterior es la derivación matemática del margen definido por la aplicación.

La opción «Aplicar márgenes por volumen» está inicialmente desactivada. Presenta valores editables de 35% desde 12 unidades, 30% desde 30 y 25% desde 50, con base 40%. Son propuestas de configuración; no se presentan como porcentajes investigados del mercado. No permite una escala mayor con margen superior a la anterior.

Las escalas operan por línea de producto y por unidades efectivas, también cuando la presentación es un paquete. No se suman referencias diferentes para obtener un descuento. Si un mismo producto se divide en varias líneas, cada línea se evalúa por separado. Los descuentos del proveedor no se inventan: el costo debe corresponder a su oferta o al ajuste explícito del ADMIN.

Ejemplo de prueba, con costo ficticio de $1.000 por unidad y $6.000 de preparación fija, sin retenciones:

| Unidades | Margen | Costo total | Total del servidor |
|---:|---:|---:|---:|
| 1 | 40% | $7.000 | $11.700 |
| 12 | 35% | $18.000 | $27.800 |
| 30 | 30% | $36.000 | $51.500 |
| 50 | 25% | $56.000 | $74.700 |

Los totales incluyen la política de redondeo por componente. La tabla de escenarios de la interfaz es estimativa; el bloque «Total validado» es el valor final que se guarda y usa el PDF.

## Validación

- Migraciones 000–078 aplicadas en una base local nueva; 28 archivos de pruebas SQL completados. Incluyen permisos, inmutabilidad, idempotencia, costos editados, retenciones, costos fijos y límites de márgenes.
- 33 pruebas Python en `tests/` y 9 del scraper de propiedad horizontal.
- Cuatro scripts de `npm test`, chequeo de claves privilegiadas y TypeScript correctos.
- `npm run verificar`: compilación de producción correcta, usando `.next-verificacion` para no interferir con el servicio local.
- Auditor automático del repositorio sin hallazgos y `git diff --check` sin errores.
- Instalación con overrides de seguridad: auditoría npm sin vulnerabilidades reportadas en ese momento.
- Diez comprobaciones Chromium del componente real, incluyendo emisión contra SQL real y ausencia de desbordamiento horizontal a 390 px. El transporte, la navegación y los catálogos son fixtures; no equivalen a E2E contra Supabase.

Evidencias: `outputs/qa-correcciones-2026-09-11/resultado.json`, capturas desktop/móvil en el mismo directorio y logs `tmp/audit-final-*.log`. El test abre una transacción y revierte sus cotizaciones de prueba.

Reejecución de la regresión de navegador, con la instancia local ya iniciada:

```powershell
cd web
$env:QA_DATABASE_URL='postgresql://postgres@127.0.0.1:55432/estampados_audit_final'
npm run test:ui
```

## Pendientes que dependen del entorno

Recuperar o corregir la configuración de Supabase y verificar su esquema antes de aplicar migraciones allí. Después faltará repetir navegación autenticada y generación, subida y descarga reales del PDF con cada rol. La prueba SQL de `storage.objects` verifica políticas, pero no reemplaza la prueba de la API de Storage. El login local muestra indisponibilidad del servicio en lugar de atribuirla a una contraseña incorrecta; los reintentos de autenticación con sesiones previas pueden tardar mientras la dependencia no responde.

No se verificaron CI remoto, PROD, inventario real, cifras actuales del CRM ni rotación remota de credenciales. Los resultados de esta revisión no certifican ausencia de todo bug en el proyecto.
