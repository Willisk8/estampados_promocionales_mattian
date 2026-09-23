# Contactos, propiedad horizontal y pruebas visuales

Fecha: 2026-09-18. Cambios de datos aplicados a Supabase remoto `psereyjwjpyakkmnabgm`. Ensayos transaccionales con rollback antes de confirmar; originales conservados en respaldos locales ignorados por Git y en la trazabilidad de importación.

## Telefonía colombiana

La marcación fija nacional usa 60 + indicativo regional de un dígito + siete dígitos locales: Bogotá/Cundinamarca es 601, no 0601. Los indicativos contemplados son 601, 602, 604, 605, 606, 607 y 608. Un número de siete dígitos sin ubicación suficiente permanece pendiente; no se convierte en celular por longitud parcial.

La migración 083 agrega columnas generadas separadas `telefono_celular` y `telefono_fijo`, conserva indicativo/número local y corrige la variante inequívoca 0601… y extensiones al normalizar. La inferencia territorial se almacena separada y no borra el original. Se completaron 4.203 indicativos en la revisión masiva; el total remoto con contexto es 4.289, incluyendo los incorporados por el importador residencial. Siguen sujetos a revisión, no se afirma que estén activos.

Fuentes: [CRC: marcación](https://www.crcom.gov.co/es/noticias/comunicado-prensa/desde-1-septiembre-cambia-forma-hacer-llamadas-en-colombia), [Circular CRC 127](https://normograma.crcom.gov.co/crc/compilacion/docs/circular_crc_0127_2020.htm), [repositorio Google libphonenumber](https://github.com/google/libphonenumber). Los metadatos de librerías son contraste técnico; no prueban titularidad, operador actual ni actividad del número.

## Correos

Se verificó sintaxis y DNS de 8.433 correos, con 2.350 dominios distintos. Gmail, Hotmail, Outlook y otros proveedores gratuitos están permitidos. No se exige un dominio empresarial a las copropiedades.

| Resultado | Correos |
|---|---:|
| MX | 7.848 |
| Resolución alternativa A/AAAA | 56 |
| Dominio inexistente NXDOMAIN | 483 |
| Null MX: dominio declara no aceptar correo | 17 |
| Sin ruta de correo | 21 |
| Formato inválido | 3 |
| No concluyente | 5 |

465 canales cambiaron de estado por evidencia negativa. No se reactivaron suprimidos ni rebotados. **Los 8.433 buzones continúan NO_VERIFICADO**: ningún resultado DNS demuestra que una dirección concreta exista. No se enviaron mensajes ni se realizaron comprobaciones SMTP de buzones. El proveedor DNS recibió dominios, no las direcciones completas.

La migración 084 invalida la verificación anterior cuando cambia la dirección, evitando mostrar resultados del correo previo. La nueva RPC de detalle conserva enmascaramiento y autorización de la consola.

Fuentes: [python-email-validator](https://github.com/JoshData/python-email-validator), [RFC 7505 Null MX](https://www.rfc-editor.org/info/rfc7505/), [RFC 5321](https://www.rfc-editor.org/info/rfc5321/).

## Conjuntos residenciales

De 8.342 registros fuente se incorporaron 7.950 organizaciones, 4.528 personas/relaciones y 1.292 canales. 392 registros quedaron exclusivamente en staging de importación por ambigüedad de identidad; no se fusionaron automáticamente. Se generaron 2.767 ítems de revisión.

Se conservan todos los registros originales. Solo se asigna representante legal cuando la fuente lo identifica; un contacto genérico no se convierte en representante. Los roles procedentes de fuentes históricas requieren revisión de vigencia. El catálogo territorial normaliza El Espinal a ESPINAL/TOLIMA, DIVIPOLA 73268, sin perder el alias original.

La aplicación mostró el listado de 7.950 conjuntos y una ficha con el correo en dominio gratuito y las nuevas columnas. Esa observación puntual no certifica visualmente todas las fichas.

## Pruebas y CI

Se añadieron Chromium y `npm run test:ui` al workflow CI, contra PostgreSQL aislado, con artefactos de capturas/resultados durante 14 días. La prueba local obtuvo 10 comprobaciones satisfactorias de cálculo, invalidación de resultados, emisión, respuesta tardía, decimales, ausencia de errores JS y diseño móvil/escritorio.

Se ejecutaron 47 pruebas Python principales y 9 del módulo residencial en esta tarea; 31 archivos SQL después de 083 y la prueba específica de contactos después de 084, incluyendo controles de rol. Build de Next.js satisfactorio. Las pruebas principales Python se repitieron después de la verificación DNS: 47 OK. El JSON `ok:false` que imprime un fixture vacío de scraper es una comprobación negativa esperada, no un fallo del runner.

Estas pruebas visuales son recorridos funcionales con capturas, no comparación automática píxel a píxel ni cobertura total del CRM. La ejecución GitHub de estos cambios queda pendiente de publicar el código; el CI remoto de agosto no certifica esta implementación.

## Evidencia local

- `outputs/contactos-residenciales-20260918/importacion/aplicacion.json`
- `outputs/contactos-residenciales-20260918/verificacion-contactos/aplicacion.json`
- `outputs/contactos-residenciales-20260918/verificacion-contactos/canales-antes.json`
- `outputs/qa-ci-local/resultado.json`, `cotizador-desktop.png`, `cotizador-movil.png`
- Migraciones 083–084 y `database/tests/test_contact_phone_columns.sql`.

Los archivos de datos contienen información de contactos y deben mantenerse fuera del repositorio público. El informe solo presenta agregados.
