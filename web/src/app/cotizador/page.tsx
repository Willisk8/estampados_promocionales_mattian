import { randomUUID } from "node:crypto";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import {
  crearProductoProveedorManual,
  crearCotizacionProveedor,
  crearSnapshotTecnicaManual,
  prepararCotizacionProveedor,
  previsualizarCotizacionProveedor,
} from "./acciones";

export const dynamic = "force-dynamic";

type Organizacion = {
  id_organizacion: string;
  nombre_legal: string;
  nit: string | null;
};

type Proveedor = {
  id_proveedor: string;
  nombre: string;
  ciudad: string | null;
  productos: number | string;
};

type ProductoProveedor = {
  id_producto_proveedor: string;
  sku_proveedor: string | null;
  nombre_original: string;
  categoria: string | null;
  estado_calidad: string;
  ultimo_precio: number | string | null;
  moneda: string | null;
  unidad_compra: string | null;
  cantidad_pack: number | string | null;
  observado_en: string | null;
};

type OfertaProveedor = {
  id_snapshot: string;
  precio_publicado: number | string;
  moneda: string;
  unidad_compra: string;
  cantidad_pack: number | string | null;
  costo_unitario_estimado: number | string;
  cantidad_comprada: number | string;
  cantidad_sobrante: number | string;
  precio_texto_original: string | null;
  url_fuente: string | null;
  observado_en: string | null;
  vigente: boolean;
};

type TecnicaSnapshot = {
  id_snapshot: string;
  tecnica_codigo: string;
  proveedor_tecnica: string;
  billing_unit: string | null;
  price_value: number | string;
  width_cm: number | string | null;
  height_cm: number | string | null;
  quantity_min: number | string | null;
  quantity_max: number | string | null;
  verification_status: string;
  size_label: string | null;
};

type ComponentePreview = {
  tipo_componente: string;
  descripcion: string;
  cantidad: number | string;
  costo_unitario: number | string | null;
  costo_total: number | string | null;
  margen_aplicado_pct: number | string | null;
  minimum_pct: number | string | null;
  precio_resultante: number | string | null;
  source_type: string;
  status: string;
};

const cop = (v: string | number | null | undefined) =>
  v === null || v === undefined
    ? "-"
    : "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

const fechaCorta = (v: string | null | undefined) =>
  v ? new Date(v).toLocaleDateString("es-CO") : "-";

const numero = (v: string | number | null | undefined) =>
  v === null || v === undefined ? "-" : Number(v).toLocaleString("es-CO");

const buildMarkingLines = (sp: Record<string, string | undefined>) => {
  if (!sp.id_snapshot_tecnica) return [];
  const line: Record<string, string | number> = {
    id_snapshot: sp.id_snapshot_tecnica,
  };
  if (sp.marcacion_descripcion) line.descripcion = sp.marcacion_descripcion;
  if (sp.marcacion_ancho_cm) line.ancho_cm = Number(sp.marcacion_ancho_cm);
  if (sp.marcacion_alto_cm) line.alto_cm = Number(sp.marcacion_alto_cm);
  if (sp.marcacion_merma_pct) line.merma_pct = Number(sp.marcacion_merma_pct);
  if (sp.numero_preparaciones) line.numero_preparaciones = Number(sp.numero_preparaciones);
  if (sp.costo_preparacion) line.costo_preparacion = Number(sp.costo_preparacion);
  return [line];
};

const CAMPOS_ESTADO_PROVEEDOR = [
  "id_organizacion",
  "id_proveedor",
  "q_proveedor",
  "q_producto",
  "id_producto_proveedor",
  "id_precio_proveedor_snapshot",
  "cantidad",
  "q_tecnica",
  "id_snapshot_tecnica",
  "marcacion_descripcion",
  "marcacion_ancho_cm",
  "marcacion_alto_cm",
  "marcacion_merma_pct",
  "numero_preparaciones",
  "costo_preparacion",
  "transporte_total",
  "transport_mode",
  "margen_override_pct",
  "notas",
] as const;

const CamposEstadoProveedor = ({ sp }: { sp: Record<string, string | undefined> }) => (
  <>
    {CAMPOS_ESTADO_PROVEEDOR.map((campo) => (
      <input key={campo} type="hidden" name={campo} value={sp[campo] ?? ""} />
    ))}
  </>
);

export default async function PaginaCotizador({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | undefined>>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const sp = await searchParams;
  const supabase = await crearClienteServidor();
  const puedeCotizar = sesion.rol === "ADMIN" || sesion.rol === "COMERCIAL";
  const esAdmin = sesion.rol === "ADMIN";
  const cantidad = Number(sp.cantidad ?? 0);
  const idempotencyKey = randomUUID();

  const [organizacionesResp, proveedoresResp, cotizacionesResp] = await Promise.all([
    supabase
      .from("organizacion")
      .select("id_organizacion, nombre_legal, nit")
      .order("nombre_legal")
      .limit(120),
    supabase.rpc("fn_consola_buscar_proveedores_producto", {
      p_q: sp.q_proveedor ?? null,
      p_limit: 80,
    }),
    supabase
      .from("cotizacion")
      .select("id_cotizacion, numero, total, estado, created_at, metodo_precio, canal_origen")
      .order("created_at", { ascending: false })
      .limit(8),
  ]);

  const organizaciones = (organizacionesResp.data ?? []) as Organizacion[];
  const proveedores = (proveedoresResp.data ?? []) as Proveedor[];
  const cotizaciones = (cotizacionesResp.data ?? []) as Array<{
    id_cotizacion: string;
    numero: number;
    total: number | string;
    estado: string;
    created_at: string;
    metodo_precio: string | null;
    canal_origen: string | null;
  }>;

  let productosProveedor: ProductoProveedor[] = [];
  if (sp.id_proveedor) {
    const { data } = await supabase.rpc("fn_consola_buscar_productos_proveedor", {
      p_id_proveedor: sp.id_proveedor,
      p_q: sp.q_producto ?? null,
      p_limit: 120,
    });
    productosProveedor = (data ?? []) as ProductoProveedor[];
  }

  let ofertas: OfertaProveedor[] = [];
  if (sp.id_producto_proveedor) {
    const { data } = await supabase.rpc("fn_consola_ofertas_producto_proveedor", {
      p_id_producto_proveedor: sp.id_producto_proveedor,
      p_cantidad: Number.isFinite(cantidad) && cantidad > 0 ? cantidad : 1,
    });
    ofertas = (data ?? []) as OfertaProveedor[];
  }

  let tecnicas: TecnicaSnapshot[] = [];
  if (Number.isFinite(cantidad) && cantidad > 0) {
    const { data } = await supabase.rpc("fn_consola_buscar_snapshots_tecnica_marcacion", {
      p_q: sp.q_tecnica ?? null,
      p_cantidad: cantidad,
      p_moneda: "COP",
      p_limit: 80,
    });
    tecnicas = (data ?? []) as TecnicaSnapshot[];
  }

  const mostrarPreview =
    sp.previsualizar_proveedor === "1" &&
    !!sp.id_precio_proveedor_snapshot &&
    Number.isFinite(cantidad) &&
    cantidad > 0;

  let previewFilas: ComponentePreview[] = [];
  if (mostrarPreview) {
    const { data } = await supabase.rpc("fn_consola_previsualizar_cotizacion_proveedor", {
      p_id_precio_proveedor_snapshot: sp.id_precio_proveedor_snapshot,
      p_cantidad: cantidad,
      p_marking_lines: buildMarkingLines(sp),
      p_transporte_total: Number(sp.transporte_total ?? 0),
      p_transport_mode: sp.transport_mode ?? "SEPARATE_LINE",
      p_policy_code: "MVP_DEFAULT",
      p_margen_override_pct: sp.margen_override_pct ? Number(sp.margen_override_pct) : null,
    });
    previewFilas = (data ?? []) as ComponentePreview[];
  }

  const previewOk = previewFilas.length > 0 && previewFilas.every((f) => f.status === "OK");
  const previewTotal = previewOk
    ? previewFilas.reduce((acc, f) => acc + Number(f.precio_resultante ?? 0), 0)
    : null;

  const productoSeleccionado = productosProveedor.find(
    (p) => p.id_producto_proveedor === sp.id_producto_proveedor
  );
  const ofertaSeleccionada = ofertas.find((o) => o.id_snapshot === sp.id_precio_proveedor_snapshot);
  const tecnicaSeleccionada = tecnicas.find((t) => t.id_snapshot === sp.id_snapshot_tecnica);

  return (
    <>
      <h1>Cotizador</h1>
      <p className="subtitulo">
        Flujo proveedor-first: cliente, proveedor, producto, costo real, tecnica,
        preview y cotizacion auditable.
      </p>

      {sp.status && (
        <div className="aviso-caja">
          No se pudo cotizar: <code>{sp.status}</code>.
        </div>
      )}
      {sp.error && <div className="aviso-caja">{sp.error}</div>}
      {sp.ok === "producto_manual" && (
        <div className="aviso-caja neutro">
          Producto/precio manual creado en revision. Ya puedes usarlo en esta cotizacion.
        </div>
      )}
      {sp.ok === "tecnica_manual" && (
        <div className="aviso-caja neutro">
          Tecnica/costo manual creado en revision. Ya puedes usarlo en esta cotizacion.
        </div>
      )}

      <form action={previsualizarCotizacionProveedor}>
        <h2>1. Cliente y proveedor</h2>
        <div className="tarjeta">
          <div className="filtros">
            <select name="id_organizacion" defaultValue={sp.id_organizacion ?? ""} disabled={!puedeCotizar}>
              <option value="">Sin cliente asociado</option>
              {organizaciones.map((o) => (
                <option key={o.id_organizacion} value={o.id_organizacion}>
                  {o.nombre_legal}
                  {o.nit ? ` - ${o.nit}` : ""}
                </option>
              ))}
            </select>
            <input
              name="q_proveedor"
              placeholder="Buscar proveedor"
              defaultValue={sp.q_proveedor ?? ""}
              disabled={!puedeCotizar}
            />
            <select name="id_proveedor" defaultValue={sp.id_proveedor ?? ""} disabled={!puedeCotizar}>
              <option value="">Proveedor</option>
              {proveedores.map((p) => (
                <option key={p.id_proveedor} value={p.id_proveedor}>
                  {p.nombre}
                  {p.ciudad ? ` - ${p.ciudad}` : ""}
                  {` (${p.productos})`}
                </option>
              ))}
            </select>
            <button formAction={prepararCotizacionProveedor} type="submit" disabled={!puedeCotizar}>
              Buscar proveedor
            </button>
          </div>
        </div>

        <h2>2. Producto del proveedor</h2>
        <div className="tarjeta">
          <div className="filtros">
            <input
              name="q_producto"
              placeholder="Buscar: mug, termo, agenda, esfero..."
              defaultValue={sp.q_producto ?? ""}
              disabled={!puedeCotizar || !sp.id_proveedor}
            />
            <select
              name="id_producto_proveedor"
              defaultValue={sp.id_producto_proveedor ?? ""}
              disabled={!puedeCotizar || productosProveedor.length === 0}
            >
              <option value="">Producto del proveedor</option>
              {productosProveedor.map((p) => (
                <option key={p.id_producto_proveedor} value={p.id_producto_proveedor}>
                  {p.sku_proveedor ? `${p.sku_proveedor} - ` : ""}
                  {p.nombre_original}
                  {p.ultimo_precio ? ` (${cop(p.ultimo_precio)})` : ""}
                </option>
              ))}
            </select>
            <input
              name="cantidad"
              type="number"
              min="1"
              placeholder="Cantidad"
              defaultValue={sp.cantidad ?? ""}
              required
              disabled={!puedeCotizar}
            />
            <button formAction={prepararCotizacionProveedor} type="submit" disabled={!puedeCotizar || !sp.id_proveedor}>
              Buscar producto/ofertas
            </button>
          </div>

          {productoSeleccionado && (
            <p style={{ marginBottom: 0, color: "var(--texto-suave)" }}>
              Seleccionado: <strong>{productoSeleccionado.nombre_original}</strong>{" "}
              <span className="insignia">{productoSeleccionado.estado_calidad}</span>
            </p>
          )}

          <details style={{ marginTop: "1rem" }}>
            <summary>+ Producto/precio manual de proveedor</summary>
            <p style={{ color: "var(--texto-suave)" }}>
              Usa esto cuando el proveedor o el producto no este en la base. Queda como
              dato manual pendiente de revision, pero sirve para esta cotizacion.
            </p>
            <div className="filtros">
              <CamposEstadoProveedor sp={sp} />
              <input
                name="manual_nombre_proveedor"
                placeholder="Nombre proveedor nuevo (si no seleccionaste uno)"
                disabled={!puedeCotizar}
              />
              <input
                name="manual_nombre_producto"
                placeholder="Producto: mug 11 oz, tula, agenda..."
                required
                disabled={!puedeCotizar}
              />
              <input name="manual_sku_proveedor" placeholder="SKU proveedor opcional" disabled={!puedeCotizar} />
              <input name="manual_categoria" placeholder="Categoria opcional" disabled={!puedeCotizar} />
              <input
                name="manual_precio"
                type="number"
                min="1"
                step="0.01"
                placeholder="Costo proveedor"
                required
                disabled={!puedeCotizar}
              />
              <select name="manual_moneda" defaultValue="COP" disabled={!puedeCotizar}>
                <option value="COP">COP</option>
                <option value="USD">USD</option>
              </select>
              <select name="manual_unidad_compra" defaultValue="UNIT" disabled={!puedeCotizar}>
                <option value="UNIT">Unidad</option>
                <option value="PACK">Paquete / caja</option>
                <option value="METER">Metro</option>
                <option value="SHEET">Hoja</option>
                <option value="CUSTOM">Otro</option>
              </select>
              <input
                name="manual_cantidad_pack"
                type="number"
                min="1"
                step="0.01"
                placeholder="Unidades por caja/paquete"
                disabled={!puedeCotizar}
              />
              <input
                name="manual_minimo_compra"
                type="number"
                min="0"
                step="0.01"
                placeholder="Minimo compra"
                disabled={!puedeCotizar}
              />
              <input
                name="manual_incremento_compra"
                type="number"
                min="0"
                step="0.01"
                placeholder="Incremento compra"
                disabled={!puedeCotizar}
              />
              <input name="manual_url_fuente" placeholder="URL/evidencia opcional" disabled={!puedeCotizar} />
              <input name="manual_notas" placeholder="Notas del costo" disabled={!puedeCotizar} />
              <button
                formAction={crearProductoProveedorManual}
                formNoValidate
                type="submit"
                disabled={!puedeCotizar}
              >
                Guardar producto/precio
              </button>
            </div>
          </details>
        </div>

        <h2>3. Costo proveedor y tecnica</h2>
        <div className="tarjeta">
          <div className="filtros">
            <select
              name="id_precio_proveedor_snapshot"
              defaultValue={sp.id_precio_proveedor_snapshot ?? ""}
              disabled={!puedeCotizar || ofertas.length === 0}
              required
            >
              <option value="">Oferta / costo proveedor</option>
              {ofertas.map((o) => (
                <option key={o.id_snapshot} value={o.id_snapshot}>
                  {cop(o.precio_publicado)} {o.unidad_compra}
                  {o.cantidad_pack ? ` x${numero(o.cantidad_pack)}` : ""}
                  {` -> ${cop(o.costo_unitario_estimado)}/und`}
                  {o.vigente ? "" : " (no vigente)"}
                </option>
              ))}
            </select>
            <input
              name="q_tecnica"
              placeholder="Buscar tecnica: DTF, sublimacion, laser..."
              defaultValue={sp.q_tecnica ?? ""}
              disabled={!puedeCotizar || !sp.cantidad}
            />
            <select
              name="id_snapshot_tecnica"
              defaultValue={sp.id_snapshot_tecnica ?? ""}
              disabled={!puedeCotizar || tecnicas.length === 0}
            >
              <option value="">Sin tecnica de marcacion</option>
              {tecnicas.map((t) => (
                <option key={t.id_snapshot} value={t.id_snapshot}>
                  {t.tecnica_codigo} - {t.proveedor_tecnica} - {cop(t.price_value)} / {t.billing_unit ?? "unidad"}
                  {t.size_label ? ` - ${t.size_label}` : ""}
                </option>
              ))}
            </select>
            <button formAction={prepararCotizacionProveedor} type="submit" disabled={!puedeCotizar || !sp.cantidad}>
              Buscar tecnicas
            </button>
          </div>

          {ofertaSeleccionada && (
            <div className="aviso-caja neutro">
              Costo estimado: <strong>{cop(ofertaSeleccionada.costo_unitario_estimado)}/und</strong>.
              Compra sugerida: {numero(ofertaSeleccionada.cantidad_comprada)} unidades;
              sobrantes: {numero(ofertaSeleccionada.cantidad_sobrante)}.
              Observado: {fechaCorta(ofertaSeleccionada.observado_en)}.
            </div>
          )}

          {tecnicaSeleccionada && (
            <div className="filtros">
              <input
                name="marcacion_descripcion"
                placeholder="Descripcion marcacion: pecho, espalda, logo..."
                defaultValue={sp.marcacion_descripcion ?? tecnicaSeleccionada.tecnica_codigo}
                disabled={!puedeCotizar}
              />
              <input
                name="marcacion_ancho_cm"
                type="number"
                step="0.01"
                placeholder="Ancho cm"
                defaultValue={sp.marcacion_ancho_cm ?? ""}
                disabled={!puedeCotizar}
              />
              <input
                name="marcacion_alto_cm"
                type="number"
                step="0.01"
                placeholder="Alto cm"
                defaultValue={sp.marcacion_alto_cm ?? ""}
                disabled={!puedeCotizar}
              />
              <input
                name="marcacion_merma_pct"
                type="number"
                step="0.01"
                placeholder="Merma %"
                defaultValue={sp.marcacion_merma_pct ?? "0"}
                disabled={!puedeCotizar}
              />
              <input
                name="numero_preparaciones"
                type="number"
                min="0"
                placeholder="Preparaciones"
                defaultValue={sp.numero_preparaciones ?? "1"}
                disabled={!puedeCotizar}
              />
              <input
                name="costo_preparacion"
                type="number"
                min="0"
                placeholder="Costo preparacion"
                defaultValue={sp.costo_preparacion ?? "0"}
                disabled={!puedeCotizar}
              />
            </div>
          )}

          <details style={{ marginTop: "1rem" }}>
            <summary>+ Tecnica/costo manual</summary>
            <p style={{ color: "var(--texto-suave)" }}>
              Para una tecnica o tarifa que aun no este curada: DTF por metro, sublimacion por hoja,
              laser, tampografia, etc. Queda en revision y conserva evidencia.
            </p>
            <div className="filtros">
              <CamposEstadoProveedor sp={sp} />
              <input
                name="manual_nombre_proveedor_tecnica"
                placeholder="Proveedor tecnica: Surtivinilos, taller..."
                required
                disabled={!puedeCotizar}
              />
              <input
                name="manual_codigo_tecnica"
                placeholder="Tecnica: DTF, SUBLIMACION, LASER..."
                required
                disabled={!puedeCotizar}
              />
              <input
                name="manual_precio_tecnica"
                type="number"
                min="1"
                step="0.01"
                placeholder="Costo tecnica"
                required
                disabled={!puedeCotizar}
              />
              <select name="manual_moneda_tecnica" defaultValue="COP" disabled={!puedeCotizar}>
                <option value="COP">COP</option>
                <option value="USD">USD</option>
              </select>
              <select name="manual_billing_unit" defaultValue="unidad" disabled={!puedeCotizar}>
                <option value="unidad">Por unidad</option>
                <option value="metro">Por metro / m2</option>
                <option value="metro_lineal">Por metro lineal</option>
                <option value="hoja">Por hoja</option>
                <option value="servicio">Por servicio</option>
              </select>
              <input
                name="manual_width_cm"
                type="number"
                min="0"
                step="0.01"
                placeholder="Ancho base cm"
                disabled={!puedeCotizar}
              />
              <input
                name="manual_height_cm"
                type="number"
                min="0"
                step="0.01"
                placeholder="Alto base cm"
                disabled={!puedeCotizar}
              />
              <input
                name="manual_quantity_min"
                type="number"
                min="1"
                placeholder="Cantidad minima"
                disabled={!puedeCotizar}
              />
              <input
                name="manual_quantity_max"
                type="number"
                min="1"
                placeholder="Cantidad maxima"
                disabled={!puedeCotizar}
              />
              <input name="manual_size_label" placeholder="Tamano: 58x100, carta, pecho..." disabled={!puedeCotizar} />
              <input name="manual_source_url" placeholder="URL/evidencia opcional" disabled={!puedeCotizar} />
              <input name="manual_notas_tecnica" placeholder="Notas tecnica" disabled={!puedeCotizar} />
              <button
                formAction={crearSnapshotTecnicaManual}
                formNoValidate
                type="submit"
                disabled={!puedeCotizar}
              >
                Guardar tecnica/costo
              </button>
            </div>
          </details>
        </div>

        <h2>4. Transporte y margen</h2>
        <div className="tarjeta">
          <div className="filtros">
            <input
              name="transporte_total"
              type="number"
              min="0"
              placeholder="Transporte total"
              defaultValue={sp.transporte_total ?? "0"}
              disabled={!puedeCotizar}
            />
            <select name="transport_mode" defaultValue={sp.transport_mode ?? "SEPARATE_LINE"} disabled={!puedeCotizar}>
              <option value="SEPARATE_LINE">Transporte separado</option>
              <option value="DISTRIBUTED">Distribuir por unidad</option>
            </select>
            {esAdmin && (
              <input
                name="margen_override_pct"
                type="number"
                step="0.01"
                placeholder="Margen opcional %"
                defaultValue={sp.margen_override_pct ?? ""}
                disabled={!puedeCotizar}
              />
            )}
            <input name="notas" placeholder="Notas internas" defaultValue={sp.notas ?? ""} disabled={!puedeCotizar} />
            <button
              type="submit"
              disabled={!puedeCotizar || !sp.id_precio_proveedor_snapshot || !sp.cantidad}
            >
              Calcular precio
            </button>
          </div>
        </div>
      </form>

      <h2>5. Previsualizacion</h2>
      <div className="tarjeta">
        {!mostrarPreview ? (
          <p style={{ margin: 0, color: "var(--texto-suave)" }}>
            Selecciona proveedor, producto, oferta y cantidad para ver el calculo.
          </p>
        ) : !previewOk ? (
          <div className="aviso-caja">
            No se pudo calcular: <code>{previewFilas[0]?.status ?? "SIN_DATOS"}</code>.
          </div>
        ) : (
          <>
            <div className="tabla-contenedor">
              <table>
                <thead>
                  <tr>
                    <th>Componente</th>
                    <th>Descripcion</th>
                    <th className="num">Cantidad</th>
                    {esAdmin && <th className="num">Costo unitario</th>}
                    {esAdmin && <th className="num">Costo total</th>}
                    {esAdmin && <th className="num">Margen</th>}
                    <th className="num">Precio</th>
                  </tr>
                </thead>
                <tbody>
                  {previewFilas.map((f, index) => (
                    <tr key={`${f.tipo_componente}-${index}`}>
                      <td><span className="insignia">{f.tipo_componente}</span></td>
                      <td>{f.descripcion}</td>
                      <td className="num">{numero(f.cantidad)}</td>
                      {esAdmin && <td className="num">{cop(f.costo_unitario)}</td>}
                      {esAdmin && <td className="num">{cop(f.costo_total)}</td>}
                      {esAdmin && <td className="num">{f.margen_aplicado_pct ?? "-"}</td>}
                      <td className="num">{cop(f.precio_resultante)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="aviso-caja neutro">
              Total calculado: <strong>{cop(previewTotal)}</strong>. El PDF no mostrara costos ni margen.
            </div>

            <form action={crearCotizacionProveedor} className="filtros">
              <input type="hidden" name="idempotency_key" value={idempotencyKey} />
              <input type="hidden" name="id_organizacion" value={sp.id_organizacion ?? ""} />
              <input type="hidden" name="id_proveedor" value={sp.id_proveedor ?? ""} />
              <input type="hidden" name="q_producto" value={sp.q_producto ?? ""} />
              <input type="hidden" name="id_producto_proveedor" value={sp.id_producto_proveedor ?? ""} />
              <input type="hidden" name="id_precio_proveedor_snapshot" value={sp.id_precio_proveedor_snapshot ?? ""} />
              <input type="hidden" name="cantidad" value={sp.cantidad ?? ""} />
              <input type="hidden" name="id_snapshot_tecnica" value={sp.id_snapshot_tecnica ?? ""} />
              <input type="hidden" name="marcacion_descripcion" value={sp.marcacion_descripcion ?? ""} />
              <input type="hidden" name="marcacion_ancho_cm" value={sp.marcacion_ancho_cm ?? ""} />
              <input type="hidden" name="marcacion_alto_cm" value={sp.marcacion_alto_cm ?? ""} />
              <input type="hidden" name="marcacion_merma_pct" value={sp.marcacion_merma_pct ?? ""} />
              <input type="hidden" name="numero_preparaciones" value={sp.numero_preparaciones ?? ""} />
              <input type="hidden" name="costo_preparacion" value={sp.costo_preparacion ?? ""} />
              <input type="hidden" name="transporte_total" value={sp.transporte_total ?? "0"} />
              <input type="hidden" name="transport_mode" value={sp.transport_mode ?? "SEPARATE_LINE"} />
              <input type="hidden" name="margen_override_pct" value={sp.margen_override_pct ?? ""} />
              <input type="hidden" name="notas" value={sp.notas ?? ""} />
              <button type="submit" disabled={!puedeCotizar}>
                Emitir cotizacion
              </button>
            </form>
          </>
        )}
      </div>

      <h2>Ultimas cotizaciones</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Numero</th>
              <th>Estado</th>
              <th>Origen</th>
              <th>Metodo</th>
              <th className="num">Total</th>
              <th>Creada</th>
            </tr>
          </thead>
          <tbody>
            {cotizaciones.map((c) => (
              <tr key={c.id_cotizacion}>
                <td><a href={`/cotizador/${c.id_cotizacion}`}>#{c.numero}</a></td>
                <td><span className="insignia">{c.estado}</span></td>
                <td>{c.canal_origen ?? "-"}</td>
                <td>{c.metodo_precio ?? "-"}</td>
                <td className="num">{cop(c.total)}</td>
                <td>{new Date(c.created_at).toLocaleString("es-CO")}</td>
              </tr>
            ))}
            {cotizaciones.length === 0 && (
              <tr>
                <td colSpan={6} style={{ color: "var(--texto-suave)" }}>
                  Sin cotizaciones emitidas.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
