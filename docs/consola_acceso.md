# Consola interna — acceso y puesta en marcha

Consola privada contra Supabase STAGING. Lee con la sesion del usuario y solo
escribe mediante RPC auditadas.

## Como funciona el acceso

Tres condiciones deben cumplirse. Si falta cualquiera, no se ve nada:

1. **Usuario en Supabase Auth.** Correo y contrasena.
2. **Fila activa en `perfil_usuario`.** Es lo que enciende el acceso. Sin ella,
   RLS no devuelve ni una fila y la consola muestra «Sin acceso a la consola»,
   no una tabla vacia.
3. **Rol.** `ADMIN`, `COMERCIAL` o `LECTURA`.

La consola nunca usa la clave privilegiada de Supabase. Lee con la sesion del
usuario; RLS y las funciones auditadas deciden que se ve y que se puede cambiar.
`npm run check:privilegios` falla si esa clave aparece en el codigo.

### Que ve cada rol hoy

| | LECTURA | COMERCIAL | ADMIN |
|---|:--:|:--:|:--:|
| Resumen, organizaciones, proveedores, tecnicas, importaciones | si | si | si |
| Correos completos en la ficha de organizacion | enmascarados | enmascarados | completos |
| Costos del catalogo propio | no | no | si |
| Resolver items de revision | no | si | si |
| Marcar prospecto/cliente y prioridad | no | si | si |
| Clasificar tipo normalizado de organizacion | no | si | si |
| Emitir cotizaciones con snapshot | no | si | si |
| Escritura directa en tablas desde la app | no | no | no |

Las escrituras permitidas no abren permisos directos sobre tablas. Pasan por
funciones `SECURITY DEFINER` que validan `perfil_usuario` y dejan auditoria o
snapshot, segun corresponda.

## Crear el primer usuario

**Paso 1 — crear la cuenta.** En el dashboard de Supabase: Authentication →
Users → Add user. Marca «Auto Confirm User» para no depender de correo saliente.
Copia el UUID que queda en la columna `id`.

**Paso 2 — habilitar el perfil.** Con `psql` o el SQL Editor:

```sql
INSERT INTO perfil_usuario (user_id, email, rol)
VALUES ('<uuid-de-auth.users>', '<tu-correo>', 'ADMIN');
```

Los perfiles se administran solo por SQL: la tabla tiene politicas restrictivas
que impiden escribirla desde la aplicacion, a proposito.

**Para revocar el acceso** sin borrar el historial:

```sql
UPDATE perfil_usuario SET activo = false WHERE email = '<correo>';
```

## Levantar la consola

```bash
cd web
cp .env.local.example .env.local   # completar con los valores de STAGING
npm install
npm run dev                        # http://localhost:3000
```

`.env.local` solo lleva dos variables, ambas publicas por diseno:
`NEXT_PUBLIC_SUPABASE_URL` y `NEXT_PUBLIC_SUPABASE_ANON_KEY`. La seguridad la
impone RLS en PostgreSQL, no el secreto de la clave.

## Comprobaciones

```bash
cd web && npm run verificar          # tipos y compilacion, sin tocar el dev
cd web && npm run check:privilegios  # la clave privilegiada no esta en el codigo
./scripts/run_db_tests.ps1           # incluye test_console_access.sql y test_console_actions.sql
python scripts/audit_change.py --all # invariantes del repositorio
```

`test_console_access.sql` verifica once condiciones, entre ellas que un usuario
sin perfil no ve nada, que ninguna escritura pasa, que las seis tablas con datos
personales son inaccesibles, y que `LECTURA` recibe el correo enmascarado
mientras `ADMIN` lo ve completo.

`test_console_actions.sql` verifica que `LECTURA` no ejecute acciones, que
`COMERCIAL` pueda resolver revisiones y actualizar estado comercial, que `ADMIN`
pueda clasificar tipos, y que `resolve_price()` siga cerrado para ejecucion
directa desde `authenticated`.

## Si la consola pierde los estilos

Sintoma: los datos cargan pero la pagina sale sin ningun formato, con tipografia
de navegador. Causa: se corrio `npm run build` mientras `npm run dev` estaba
vivo, y el build de produccion sobrescribio el `.next` que el servidor de
desarrollo estaba usando; las rutas de CSS que la pagina pide dejan de existir y
devuelven 404.

Por eso existe `npm run verificar`, que compila en `.next-verificacion` y no toca
el directorio del servidor de desarrollo. Si ya ocurrio:

```bash
cd web
rm -rf .next
npm run dev
```

## Si la consola aparece vacia

Casi siempre es una de estas tres, en este orden:

1. No hay fila en `perfil_usuario`, o tiene `activo = false`.
2. Las migraciones de consola, desde `024_console_access.sql`, no estan aplicadas
   en el entorno.
3. `.env.local` apunta a otro proyecto de Supabase.

Una consola vacia rara vez significa que falten permisos de clave. Si una
consulta parece necesitar mas privilegios, el error esta en la politica RLS, no
en la configuracion del cliente.
