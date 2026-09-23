import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { documentosDeCotizacion } from "@/lib/documentos-cotizacion";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const cop = (v: string | number | null | undefined) =>
  v === null || v === undefined
    ? "—"
    : "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

const miles = (v: string | number | null | undefined) =>
  v === null || v === undefined ? "—" : Number(v).toLocaleString("es-CO");

type Cotizacion = {
  id_cotizacion: string;
  numero: number;
  total: number | string;
  estado: string;
  fecha_emision: string | null;
  metodo_precio: string | null;
  notas: string | null;
  id_organizacion: string | null;
};

type Componente = {
  tipo_componente: string;
  descripcion: string;
  cantidad: number | string;
  costo_unitario: number | string | null;
  costo_total: number | string | null;
  margen_aplicado_pct: number | string | null;
  precio_resultante: number | string;
  status: string;
};

/** Fila por LINEA de la cotizacion (migracion 075). */
type ItemCotizacion = {
  id_cotizacion_item: string;
  linea: number;
  nombre_item: string;
  descripcion_marcacion: string | null;
  unidad_compra: string;
  cantidad_pack: number | string | null;
  cantidad_presentaciones: number | string;
  unidades_totales: number;
  precio_unitario_venta: number | string | null;
  total_linea: number | string;
  costo_compra_unitario: number | string | null;
  sku_proveedor: string | null;
  proveedor: string | null;
  status: string;
};

type Canal = { tipo: string; valor: string; estado: string };
type Persona = { nombre_completo: string; cargo: string | null; rol: string };

/**
 * Presentacion de una linea de cara al cliente: es lo mismo que muestra el PDF.
 * "paquete x 10 unidades" para multipack; "unidad" para producto individual.
 */
const presentacionDe = (unidad: string, pack: number | string | null) => {
  const n = Number(pack ?? NaN);
  if (unidad === "PACK" && Number.isFinite(n) && n > 0) {
    return `Paquete x ${miles(n)} unidad${n === 1 ? "" : "es"}`;
  }
  if (unidad === "METER") return "Metro";
  if (unidad === "SHEET") return "Hoja";
  return "Unidad";
};

export default async function DetalleCotizacion({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const supabase = await crearClienteServidor();
  const [{ data: cotizacion }, { data: componentes }, { data: items }] = await Promise.all([
    supabase
      .from("cotizacion")
      .select(
        "id_cotizacion, numero, total, estado, fecha_emision, metodo_precio, notas, id_organizacion",
      )
      .eq("id_cotizacion", id)
      .maybeSingle(),
    supabase.rpc("fn_consola_componentes_cotizacion", { p_id_cotizacion: id }),
    supabase.rpc("fn_consola_items_cotizacion", { p_id_cotizacion: id }),
  ]);

  if (!cotizacion) {
    return (
      <>
        <h1>Cotización no encontrada</h1>
        <p className="subtitulo">No existe una cotización con ese identificador.</p>
      </>
    );
  }

  const c = cotizacion as Cotizacion;
  const filas = (componentes ?? []) as Componente[];
  const filasValidas = filas.filter((f) => f.status === "OK");
  const lineas = ((items ?? []) as ItemCotizacion[]).filter((f) => f.status === "OK");
  const puedeVerCostos = sesion.rol === "ADMIN";
  const puedeGenerarPdf = filasValidas.length > 0;

  // Datos del cliente: salen del CRM que ya existe (organizacion + canales +
  // personas). No hay -ni hacen falta- campos de contacto propios de la
  // cotizacion; el correo sigue enmascarado para roles no ADMIN porque lo
  // enmascara la propia RPC.
  type OrganizacionCliente = {
    nombre_legal: string;
    nombre_comercial: string | null;
    nit: string | null;
    municipio: string | null;
    departamento: string | null;
  };

  let organizacion: OrganizacionCliente | null = null;
  let listaCanales: Canal[] = [];
  let contacto: Persona | null = null;

  if (c.id_organizacion) {
    const [orgResp, canalesResp, personasResp] = await Promise.all([
      supabase
        .from("organizacion")
        .select("nombre_legal, nombre_comercial, nit, municipio, departamento")
        .eq("id_organizacion", c.id_organizacion)
        .maybeSingle(),
      supabase.rpc("fn_consola_canales_organizacion", {
        p_id_organizacion: c.id_organizacion,
      }),
      supabase.rpc("fn_consola_personas_organizacion", {
        p_id_organizacion: c.id_organizacion,
      }),
    ]);

    organizacion = (orgResp.data as OrganizacionCliente | null) ?? null;
    listaCanales = ((canalesResp.data ?? []) as Canal[]).filter(
      (x) => x.estado === "ACTIVE",
    );
    contacto = ((personasResp.data ?? []) as Persona[])[0] ?? null;
  }

  const email = listaCanales.find((x) => x.tipo === "EMAIL")?.valor ?? null;
  const telefono =
    listaCanales.find((x) => x.tipo === "TELEFONO")?.valor ??
    listaCanales.find((x) => x.tipo === "WHATSAPP")?.valor ??
    null;

  const subtotalLineas = lineas.reduce((acc, l) => acc + Number(l.total_linea ?? 0), 0);

  // PDFs ya generados de esta cotizacion, con su URL de descarga firmada. El
  // SELECT lo permite la RLS de 042 a cualquier perfil de consola activo.
  const documentos = await documentosDeCotizacion(id);

  const pesoLegible = (bytes: unknown) => {
    const n = Number(bytes);
    if (!Number.isFinite(n) || n <= 0) return null;
    return n < 1024 * 1024
      ? `${Math.round(n / 1024)} KB`
      : `${(n / (1024 * 1024)).toFixed(1)} MB`;
  };

  return (
    <>
      <h1>Cotización #{c.numero}</h1>
      <p className="subtitulo">
        Método: {c.metodo_precio ?? "—"} · Estado: {c.estado} · Emitida:{" "}
        {c.fecha_emision ? new Date(c.fecha_emision).toLocaleString("es-CO") : "—"} ·{" "}
        {lineas.length} línea(s)
      </p>

      {filas[0]?.status && filas[0].status !== "OK" && (
        <div className="aviso-caja">
          No se pudo leer el desglose: <code>{filas[0].status}</code>.
        </div>
      )}

      <h2>Cliente</h2>
      <div className="tarjeta">
        {organizacion ? (
          <dl className="datos">
            <dt>Organización</dt>
            <dd>
              {organizacion.nombre_legal}
              {organizacion.nombre_comercial &&
              organizacion.nombre_comercial !== organizacion.nombre_legal
                ? ` (${organizacion.nombre_comercial})`
                : ""}
            </dd>
            <dt>NIT</dt>
            <dd>{organizacion.nit ?? "—"}</dd>
            <dt>Ciudad</dt>
            <dd>
              {[organizacion.municipio, organizacion.departamento]
                .filter(Boolean)
                .join(", ") || "—"}
            </dd>
            <dt>Contacto</dt>
            <dd>
              {contacto
                ? `${contacto.nombre_completo}${contacto.cargo ? ` — ${contacto.cargo}` : ""}`
                : "—"}
            </dd>
            <dt>Correo</dt>
            <dd>{email ?? "—"}</dd>
            <dt>Teléfono</dt>
            <dd>{telefono ?? "—"}</dd>
          </dl>
        ) : (
          <p style={{ margin: 0, color: "var(--texto-suave)" }}>
            Esta cotización no tiene organización asociada. El PDF saldrá sin datos de
            cliente.
          </p>
        )}
      </div>

      <h2>Productos cotizados</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th className="num">#</th>
              <th>Producto</th>
              <th>Presentación</th>
              <th className="num">Cantidad</th>
              <th className="num">Unidades</th>
              <th className="num">Precio und</th>
              <th className="num">Total</th>
              {/* Columna interna al final: lo que ve el cliente va primero. */}
              {puedeVerCostos && <th className="num">Costo/und</th>}
            </tr>
          </thead>
          <tbody>
            {lineas.map((l) => (
              <tr key={l.id_cotizacion_item} data-testid="detalle-linea">
                <td className="num">{l.linea}</td>
                <td>
                  {l.nombre_item}
                  {l.descripcion_marcacion ? (
                    <>
                      <br />
                      <span style={{ color: "var(--texto-suave)", fontSize: 12 }}>
                        {l.descripcion_marcacion}
                      </span>
                    </>
                  ) : null}
                </td>
                <td>{presentacionDe(l.unidad_compra, l.cantidad_pack)}</td>
                <td className="num">{miles(l.cantidad_presentaciones)}</td>
                <td className="num">{miles(l.unidades_totales)}</td>
                <td className="num">{cop(l.precio_unitario_venta)}</td>
                <td className="num">{cop(l.total_linea)}</td>
                {puedeVerCostos && (
                  <td className="num">{cop(l.costo_compra_unitario)}</td>
                )}
              </tr>
            ))}
            {lineas.length === 0 && (
              <tr>
                <td colSpan={puedeVerCostos ? 8 : 7} style={{ color: "var(--texto-suave)" }}>
                  Esta cotización no tiene líneas persistidas.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {lineas.length > 0 && (
        <p className="subtitulo" data-testid="detalle-subtotal">
          Subtotal de líneas: <strong>{cop(subtotalLineas)}</strong>
        </p>
      )}

      <details>
        <summary>
          <h2 style={{ display: "inline-block", margin: "18px 0 10px" }}>
            Desglose interno por componente
          </h2>
        </summary>
        <div className="aviso-caja neutro">
          Este desglose es interno: no aparece en el PDF del cliente.
        </div>
        <div className="tabla-contenedor">
          <table>
            <thead>
              <tr>
                <th>Componente</th>
                <th>Descripción</th>
                <th className="num">Cantidad</th>
                {puedeVerCostos && <th className="num">Costo unitario</th>}
                {puedeVerCostos && <th className="num">Costo total</th>}
                {puedeVerCostos && <th className="num">Margen %</th>}
                <th className="num">Precio</th>
              </tr>
            </thead>
            <tbody>
              {filasValidas.map((f, index) => (
                <tr key={`${f.tipo_componente}-${index}`}>
                  <td>
                    <span className="insignia">{f.tipo_componente}</span>
                  </td>
                  <td>{f.descripcion}</td>
                  <td className="num">{Number(f.cantidad).toLocaleString("es-CO")}</td>
                  {puedeVerCostos && <td className="num">{cop(f.costo_unitario)}</td>}
                  {puedeVerCostos && <td className="num">{cop(f.costo_total)}</td>}
                  {puedeVerCostos && (
                    <td className="num">
                      {f.margen_aplicado_pct === null
                        ? "—"
                        : Number(f.margen_aplicado_pct).toLocaleString("es-CO")}
                    </td>
                  )}
                  <td className="num">{cop(f.precio_resultante)}</td>
                </tr>
              ))}
              {filasValidas.length === 0 && (
                <tr>
                  <td colSpan={puedeVerCostos ? 7 : 4} style={{ color: "var(--texto-suave)" }}>
                    Esta cotización no tiene componentes persistidos.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </details>

      <h2>Documentos generados</h2>
      <div className="tarjeta">
        {documentos.length === 0 ? (
          <p style={{ margin: 0, color: "var(--texto-suave)" }} data-testid="detalle-sin-documentos">
            Todavía no se ha generado ningún PDF de esta cotización. Al generarlo queda
            guardado acá y se puede volver a descargar sin regenerarlo.
          </p>
        ) : (
          <div className="tabla-contenedor">
            <table>
              <thead>
                <tr>
                  <th>Documento</th>
                  <th>Generado</th>
                  <th>Por</th>
                  <th className="num">Tamaño</th>
                  <th>Descarga</th>
                </tr>
              </thead>
              <tbody>
                {documentos.map((d) => {
                  const numeroMeta = d.metadata?.numero;
                  const peso = pesoLegible(d.metadata?.bytes);
                  return (
                    <tr key={d.id_cotizacion_documento} data-testid="detalle-documento">
                      <td>
                        <span className="insignia">{d.tipo_documento}</span>
                        {numeroMeta ? ` cotizacion-${String(numeroMeta)}.pdf` : ""}
                      </td>
                      <td>{new Date(d.created_at).toLocaleString("es-CO")}</td>
                      <td>{d.rol_consola}</td>
                      <td className="num">{peso ?? "—"}</td>
                      <td>
                        {d.url ? (
                          <a href={d.url} data-testid="detalle-documento-descargar">
                            Descargar
                          </a>
                        ) : (
                          <span
                            style={{ color: "var(--texto-suave)" }}
                            title="El archivo ya no está en Storage o no se pudo firmar la URL"
                          >
                            No disponible
                          </span>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
        {documentos.length > 0 && (
          <p
            className="subtitulo"
            style={{ marginBottom: 0 }}
            data-testid="detalle-documentos-nota"
          >
            Los enlaces de descarga se firman al abrir esta página y vencen a los 30
            minutos. Recargá la página para obtener uno nuevo.
          </p>
        )}
      </div>

      <div className="tarjeta">
        <p style={{ marginTop: 0 }}>
          <strong>Total:</strong>{" "}
          <span data-testid="detalle-total">{cop(c.total)}</span>
        </p>
        {c.notas && <p>{c.notas}</p>}
        <div className="filtros">
          <a href="/cotizador">
            <button type="button">Volver al cotizador</button>
          </a>
          {/*
            MODIFICAR: la cotizacion es INMUTABLE (RLS deny_update, migracion
            029). Este boton no edita nada; recarga estos mismos valores en la
            calculadora para emitir una cotizacion NUEVA con numero propio.
            Solo ADMIN, que es el unico rol que ve la calculadora visual.
          */}
          {puedeVerCostos && lineas.length > 0 && (
            <a href={`/cotizador?desde_cotizacion=${id}`} data-testid="detalle-modificar">
              <button
                type="button"
                title="Carga estos valores en la calculadora para emitir una cotización nueva. Esta cotización no se modifica."
              >
                Modificar
              </button>
            </a>
          )}
          <button type="button" disabled title="Pendiente: generación/envío de PDF">
            Enviar PDF por correo
          </button>
          {puedeGenerarPdf ? (
            <a href={`/cotizador/${id}/pdf`} data-testid="detalle-pdf">
              <button type="button">Generar PDF</button>
            </a>
          ) : (
            <button
              type="button"
              disabled
              title="PDF no disponible: esta cotización no tiene desglose de componentes persistido"
            >
              Generar PDF
            </button>
          )}
        </div>
      </div>
    </>
  );
}
