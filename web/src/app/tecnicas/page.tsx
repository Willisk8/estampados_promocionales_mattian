import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

type Precio = {
  id_snapshot: string;
  service_component: string | null;
  price_scope: string;
  size_label: string | null;
  quantity_min: number | null;
  quantity_max: number | null;
  billing_unit: string | null;
  price_value: number | null;
  price_min: number | null;
  price_max: number | null;
  currency: string;
  verification_status: string;
  fetched_at: string | null;
  source_url: string | null;
  proveedor_tecnica_marcacion: { nombre: string } | null;
};

type Tecnica = {
  id_tecnica: string;
  codigo: string;
  mejor_para: string | null;
  limitaciones: string | null;
  drivers_costo: string | null;
  verification_status: string;
};

const cop = (v: number | null) =>
  v === null ? null : "$" + v.toLocaleString("es-CO", { maximumFractionDigits: 0 });

function precioTexto(p: Precio) {
  const valor = cop(p.price_value);
  if (valor) return valor;
  const min = cop(p.price_min);
  const max = cop(p.price_max);
  if (min && max) return `${min} – ${max}`;
  return min ?? max ?? "sin precio";
}

export default async function PaginaTecnicas() {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const supabase = await crearClienteServidor();
  const [tecnicas, precios] = await Promise.all([
    supabase.from("tecnica_marcacion").select("*").order("codigo"),
    supabase
      .from("precio_tecnica_marcacion_snapshot")
      .select("*, proveedor_tecnica_marcacion(nombre)")
      .order("fetched_at", { ascending: false }),
  ]);

  const listaTecnicas = (tecnicas.data ?? []) as Tecnica[];
  const listaPrecios = (precios.data ?? []) as unknown as Precio[];

  const porTecnica = new Map<string, Precio[]>();
  for (const p of listaPrecios) {
    const key = (p as unknown as { id_tecnica: string }).id_tecnica;
    porTecnica.set(key, [...(porTecnica.get(key) ?? []), p]);
  }

  const sinVerificar = listaPrecios.filter(
    (p) => p.verification_status !== "VERIFIED",
  ).length;

  return (
    <>
      <h1>Tecnicas de marcacion</h1>
      <p className="subtitulo">
        {listaTecnicas.length} tecnicas y {listaPrecios.length} precios observados.
      </p>

      {sinVerificar > 0 && (
        <div className="aviso-caja">
          {sinVerificar} de {listaPrecios.length} precios no estan verificados. La
          calculadora no debe usarlos para calculo automatico hasta que se curen:
          es el Hito 2 del plan de cierre del MVP.
        </div>
      )}

      {listaTecnicas.map((t) => {
        const precios = porTecnica.get(t.id_tecnica) ?? [];
        return (
          <section key={t.id_tecnica}>
            <h2>
              {t.codigo}{" "}
              <span
                className={
                  t.verification_status === "VERIFIED"
                    ? "insignia"
                    : "insignia aviso"
                }
              >
                {t.verification_status}
              </span>
            </h2>
            {t.mejor_para && (
              <p className="subtitulo" style={{ marginBottom: 8 }}>
                {t.mejor_para}
                {t.limitaciones ? ` · Limitaciones: ${t.limitaciones}` : ""}
              </p>
            )}
            <div className="tabla-contenedor">
              <table>
                <thead>
                  <tr>
                    <th>Proveedor</th>
                    <th>Componente</th>
                    <th>Alcance</th>
                    <th>Tamano</th>
                    <th className="num">Cantidad</th>
                    <th>Unidad de cobro</th>
                    <th className="num">Precio</th>
                    <th>Verificacion</th>
                    <th>Fuente</th>
                  </tr>
                </thead>
                <tbody>
                  {precios.map((p) => (
                    <tr key={p.id_snapshot}>
                      <td>{p.proveedor_tecnica_marcacion?.nombre ?? "—"}</td>
                      <td>{p.service_component ?? "—"}</td>
                      <td>{p.price_scope}</td>
                      <td>{p.size_label ?? "—"}</td>
                      <td className="num">
                        {p.quantity_min ?? "—"}
                        {p.quantity_max ? `–${p.quantity_max}` : ""}
                      </td>
                      <td>{p.billing_unit ?? "—"}</td>
                      <td className="num">{precioTexto(p)}</td>
                      <td>
                        <span
                          className={
                            p.verification_status === "VERIFIED"
                              ? "insignia"
                              : "insignia aviso"
                          }
                        >
                          {p.verification_status}
                        </span>
                      </td>
                      <td>
                        {p.source_url ? (
                          <a href={p.source_url} target="_blank" rel="noreferrer">
                            ver
                          </a>
                        ) : (
                          "—"
                        )}
                      </td>
                    </tr>
                  ))}
                  {precios.length === 0 && (
                    <tr>
                      <td colSpan={9} style={{ color: "var(--texto-suave)" }}>
                        Sin precios observados para esta tecnica.
                      </td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>
          </section>
        );
      })}
    </>
  );
}
