import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import { firmarImagenes } from "@/lib/imagenes";

export const dynamic = "force-dynamic";

const cop = (v: number) => "$" + v.toLocaleString("es-CO", { maximumFractionDigits: 0 });

const miles = (v: number) => v.toLocaleString("es-CO");

/**
 * Presentacion y costo unitario interno de una observacion de precio.
 *
 * "Precio mas reciente: $18.000 / Unidad: —" no alcanza: no distingue si esos
 * $18.000 son por unidad o por un paquete de 10, que es exactamente la
 * diferencia entre cotizar bien y cotizar 10 veces mal. Se calcula con la
 * MISMA formula que usa el motor de cotizacion
 * (fn_quote_calculate_supplier_components_core) y que el selector de ofertas
 * (fn_consola_ofertas_producto_proveedor):
 *   costo_unitario = PACK con cantidad_pack > 0 ? precio / cantidad_pack : precio
 */
const desglosePrecio = (s: {
  precio_publicado: number | string;
  unidad_compra: string | null;
  cantidad_pack: number | string | null;
}) => {
  const precio = Number(s.precio_publicado);
  const pack = Number(s.cantidad_pack ?? NaN);
  const esPack = s.unidad_compra === "PACK" && Number.isFinite(pack) && pack > 0;
  const contenido = esPack ? pack : 1;
  const unidadTexto =
    s.unidad_compra === "METER"
      ? "metro"
      : s.unidad_compra === "SHEET"
        ? "hoja"
        : esPack
          ? "paquete"
          : "unidad";
  return {
    esPack,
    contenido,
    unidadTexto,
    costoUnitario: esPack ? precio / pack : precio,
  };
};

export default async function PaginaProductoProveedor({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [prod, snaps] = await Promise.all([
    supabase
      .from("producto_proveedor")
      .select("*, proveedor(id_proveedor, nombre)")
      .eq("id_producto_proveedor", id)
      .maybeSingle(),
    supabase
      .from("precio_proveedor_snapshot")
      .select("*")
      .eq("id_producto_proveedor", id)
      .order("observado_en", { ascending: false }),
  ]);

  if (!prod.data) {
    return (
      <>
        <h1>Producto no encontrado</h1>
        <p className="subtitulo">
          <Link href="/proveedores">← Proveedores</Link>
        </p>
      </>
    );
  }

  const p = prod.data;
  const proveedor = p.proveedor as { id_proveedor: string; nombre: string } | null;
  const historico = snaps.data ?? [];
  const imagen = (await firmarImagenes([id])).get(id) ?? null;

  return (
    <>
      <p className="subtitulo" style={{ marginBottom: 6 }}>
        {proveedor ? (
          <Link href={`/proveedores/${proveedor.id_proveedor}`}>
            ← {proveedor.nombre}
          </Link>
        ) : (
          <Link href="/proveedores">← Proveedores</Link>
        )}
      </p>
      <h1>{p.nombre_original}</h1>
      <p className="subtitulo">
        {p.categoria ?? "sin categoria"} ·{" "}
        <span
          className={
            p.estado_calidad === "VALID" ? "insignia" : "insignia aviso"
          }
        >
          {p.estado_calidad}
        </span>
      </p>

      {p.motivo_revision && (
        <div className="aviso-caja">Motivo de revision: {p.motivo_revision}</div>
      )}

      <h2>Ficha</h2>
      <div className="tarjeta" style={{ display: "flex", gap: 20, alignItems: "flex-start" }}>
        {imagen ? (
          <figure style={{ margin: 0, flexShrink: 0 }}>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={imagen.url}
              alt={p.nombre_original}
              style={{
                width: 190,
                height: 190,
                objectFit: "contain",
                borderRadius: 8,
                background: "var(--fondo)",
                display: "block",
              }}
            />
            <figcaption style={{ fontSize: 11.5, color: "var(--texto-suave)", marginTop: 6 }}>
              Copia guardada
              {imagen.capturada_en
                ? ` el ${new Date(imagen.capturada_en).toLocaleDateString("es-CO")}`
                : ""}
            </figcaption>
          </figure>
        ) : null}
        <dl className="datos" style={{ flex: 1 }}>
          <dt>SKU proveedor</dt>
          <dd>{p.sku_proveedor ?? "—"}</dd>
          <dt>Descripcion</dt>
          <dd>{p.descripcion ?? "—"}</dd>
          <dt>Etiquetas</dt>
          <dd>{(p.tags ?? []).join(", ") || "—"}</dd>
          <dt>URL del producto</dt>
          <dd>
            {p.url_producto ? (
              <a href={p.url_producto} target="_blank" rel="noreferrer">
                {p.url_producto}
              </a>
            ) : (
              "—"
            )}
          </dd>
        </dl>
      </div>

      <h2>Precio y presentacion</h2>
      {historico.length === 0 ? (
        <div className="aviso-caja neutro">Sin precios observados para este producto.</div>
      ) : (
        (() => {
          const ultimo = historico[0];
          const d = desglosePrecio(ultimo);
          return (
            <div
              className="tarjeta"
              data-testid="producto-precio-resumen"
              data-unidad-compra={ultimo.unidad_compra ?? "UNIT"}
              data-contenido={d.contenido}
              data-precio-proveedor={Math.round(Number(ultimo.precio_publicado))}
              data-costo-unitario={Math.round(d.costoUnitario)}
            >
              <dl className="datos">
                <dt>Precio proveedor</dt>
                <dd>
                  <strong>{cop(Number(ultimo.precio_publicado))}</strong> / {d.unidadTexto}
                </dd>
                <dt>Contenido</dt>
                <dd>
                  {miles(d.contenido)} unidad{d.contenido === 1 ? "" : "es"}
                </dd>
                <dt>Costo unitario interno</dt>
                <dd>
                  <strong>{cop(d.costoUnitario)}</strong> / unidad
                  {d.esPack && (
                    <span style={{ color: "var(--texto-suave)" }}>
                      {" "}
                      ({cop(Number(ultimo.precio_publicado))} ÷ {miles(d.contenido)})
                    </span>
                  )}
                </dd>
                <dt>Observado</dt>
                <dd>{new Date(ultimo.observado_en).toLocaleDateString("es-CO")}</dd>
              </dl>
              {!ultimo.unidad_compra && (
                <div className="aviso-caja">
                  Esta observacion no tiene registrada la unidad de compra, asi que se
                  asume <strong>1 unidad</strong>. Si el proveedor la vende por paquete,
                  el costo unitario que se use para cotizar va a estar inflado: hay que
                  registrar una observacion nueva con <code>unidad_compra = PACK</code> y{" "}
                  <code>cantidad_pack</code>.
                </div>
              )}
            </div>
          );
        })()
      )}

      <h2>Historico de precios observados ({historico.length})</h2>
      <div className="aviso-caja neutro">
        Esta tabla es de solo lectura por diseno. Un cambio de precio no edita un
        snapshot: crea una observacion nueva, para que cualquier calculo pasado
        siga siendo reproducible.
      </div>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Observado</th>
              <th className="num">Precio proveedor</th>
              <th>Moneda</th>
              <th>Unidad</th>
              <th className="num">Contenido</th>
              <th className="num">Costo unitario interno</th>
              <th className="num">Minimo</th>
              <th>Formato</th>
              <th>Disponibilidad</th>
              <th>Fuente</th>
            </tr>
          </thead>
          <tbody>
            {historico.map((s) => (
              <tr key={s.id_snapshot}>
                <td>{new Date(s.observado_en).toLocaleDateString("es-CO")}</td>
                <td className="num">
                  {cop(s.precio_publicado)} / {desglosePrecio(s).unidadTexto}
                </td>
                <td>{s.moneda}</td>
                <td>{s.unidad_compra ?? "—"}</td>
                <td className="num">{miles(desglosePrecio(s).contenido)} und</td>
                <td className="num">{cop(desglosePrecio(s).costoUnitario)}</td>
                <td className="num">{s.minimo_compra ?? "—"}</td>
                <td>
                  {s.ancho_cm && s.alto_cm ? `${s.ancho_cm} × ${s.alto_cm} cm` : "—"}
                </td>
                <td>{s.disponibilidad ?? "—"}</td>
                <td>
                  {s.url_fuente ? (
                    <a href={s.url_fuente} target="_blank" rel="noreferrer">
                      ver
                    </a>
                  ) : (
                    "—"
                  )}
                </td>
              </tr>
            ))}
            {historico.length === 0 && (
              <tr>
                <td colSpan={10} style={{ color: "var(--texto-suave)" }}>
                  Sin precios observados para este producto.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
