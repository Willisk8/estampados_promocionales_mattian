import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

type Resumen = {
  organizaciones: number;
  personas: number;
  canales_contacto: number;
  proveedores: number;
  productos_proveedor: number;
  precios_proveedor: number;
  tecnicas_marcacion: number;
  precios_marcacion: number;
  revisiones_abiertas: number;
  productos_propios_activos: number;
  productos_propios_borrador: number;
  precios_comerciales_vigentes: number;
  organizaciones_sin_tipo: number;
  ultimo_snapshot_proveedor: string | null;
};

function Tarjeta({ cifra, etiqueta }: { cifra: number | string; etiqueta: string }) {
  return (
    <div className="tarjeta">
      <div className="cifra">
        {typeof cifra === "number" ? cifra.toLocaleString("es-CO") : cifra}
      </div>
      <div className="etiqueta">{etiqueta}</div>
    </div>
  );
}

async function leerResumenConTimeout(
  supabase: Awaited<ReturnType<typeof crearClienteServidor>>,
  timeoutMs = 5000,
): Promise<{ data: Resumen | null; error: string | null }> {
  const controlador = new AbortController();
  const timeout = setTimeout(() => controlador.abort(), timeoutMs);

  try {
    const { data, error } = await supabase
      .rpc("fn_consola_resumen")
      .abortSignal(controlador.signal);
    return {
      data: (data?.[0] ?? null) as Resumen | null,
      error: error?.message ?? null,
    };
  } catch (error) {
    return {
      data: null,
      error:
        error instanceof Error && error.name === "AbortError"
          ? "La consulta de resumen tardó demasiado. La consola sigue disponible desde el menú."
          : error instanceof Error
            ? error.message
            : "Error desconocido leyendo el resumen.",
    };
  } finally {
    clearTimeout(timeout);
  }
}

export default async function PaginaResumen() {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const supabase = await crearClienteServidor();
  const { data: r, error } = await leerResumenConTimeout(supabase);

  if (error || !r) {
    return (
      <>
        <h1>Resumen</h1>
        <p className="subtitulo">
          La sesión está activa. Puedes entrar al Cotizador desde el menú lateral
          aunque el resumen tarde.
        </p>
        <div className="aviso-caja">
          No se pudo leer el resumen: {error ?? "sin datos"}
        </div>
      </>
    );
  }

  const fecha = r.ultimo_snapshot_proveedor
    ? new Date(r.ultimo_snapshot_proveedor).toLocaleDateString("es-CO", {
        year: "numeric",
        month: "short",
        day: "numeric",
      })
    : "sin dato";

  return (
    <>
      <h1>Resumen</h1>
      <p className="subtitulo">
        Conteos en vivo de Supabase STAGING. Todo lo que ves pasa por RLS con tu
        sesion; nada usa una clave privilegiada.
      </p>

      <h2>CRM</h2>
      <div className="rejilla">
        <Tarjeta cifra={r.organizaciones} etiqueta="Organizaciones" />
        <Tarjeta cifra={r.personas} etiqueta="Personas" />
        <Tarjeta cifra={r.canales_contacto} etiqueta="Canales de contacto" />
        <Tarjeta cifra={r.revisiones_abiertas} etiqueta="Revisiones abiertas" />
      </div>

      <h2>Catalogo de proveedores</h2>
      <div className="rejilla">
        <Tarjeta cifra={r.proveedores} etiqueta="Proveedores" />
        <Tarjeta cifra={r.productos_proveedor} etiqueta="Productos de proveedor" />
        <Tarjeta cifra={r.precios_proveedor} etiqueta="Precios observados" />
        <Tarjeta cifra={fecha} etiqueta="Ultimo precio observado" />
      </div>

      <h2>Marcacion y catalogo propio</h2>
      <div className="rejilla">
        <Tarjeta cifra={r.tecnicas_marcacion} etiqueta="Tecnicas de marcacion" />
        <Tarjeta cifra={r.precios_marcacion} etiqueta="Precios de marcacion" />
        <Tarjeta cifra={r.productos_propios_activos} etiqueta="Productos propios activos" />
        <Tarjeta cifra={r.productos_propios_borrador} etiqueta="Productos propios en borrador" />
        <Tarjeta cifra={r.precios_comerciales_vigentes} etiqueta="Precios comerciales vigentes" />
      </div>

      {r.organizaciones_sin_tipo > 0 && (
        <div className="aviso-caja">
          <strong>{r.organizaciones_sin_tipo.toLocaleString("es-CO")}</strong>{" "}
          organizaciones no tienen tipo normalizado. La ficha de cada
          organizacion ya permite clasificar el tipo con auditoria, conservando
          el texto de origen para trazabilidad.
        </div>
      )}

      {r.productos_propios_borrador > 0 && (
        <div className="aviso-caja">
          <strong>{r.productos_propios_borrador}</strong> productos propios estan
          en borrador porque sus costos siguen sin confirmar (migracion 023). No
          son cotizables hasta que se revisen.
        </div>
      )}
    </>
  );
}
