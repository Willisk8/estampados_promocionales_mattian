import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const POR_PAGINA = 50;

const ESTADOS_COMERCIALES = ["PROSPECTO", "CLIENTE", "DESCARTADO", "INACTIVO"] as const;
const PRIORIDADES = ["ALTA", "MEDIA", "BAJA"] as const;

type Fila = {
  id_organizacion: string;
  nit: string | null;
  nombre_legal: string;
  tipo_codigo: string | null;
  departamento: string | null;
  municipio: string | null;
  estado_comercial: string;
  prioridad: string;
  notas: string | null;
  actualizado_en: string | null;
  total_filas: number;
};

function insigniaEstado(estado: string) {
  if (estado === "CLIENTE") return "insignia";
  if (estado === "DESCARTADO" || estado === "INACTIVO") return "insignia neutra";
  return "insignia aviso";
}

function insigniaPrioridad(p: string) {
  return p === "ALTA" ? "insignia alerta" : p === "BAJA" ? "insignia neutra" : "insignia";
}

export default async function PaginaClientes({
  searchParams,
}: {
  searchParams: Promise<{ estado?: string; prioridad?: string; p?: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const sp = await searchParams;
  const pagina = Math.max(1, Number(sp.p ?? 1) || 1);
  const supabase = await crearClienteServidor();

  const { data, error } = await supabase.rpc("fn_consola_clientes_prospectos", {
    p_estado_comercial: sp.estado?.trim() || null,
    p_prioridad: sp.prioridad?.trim() || null,
    p_limite: POR_PAGINA,
    p_desplazamiento: (pagina - 1) * POR_PAGINA,
  });

  const filas = (data ?? []) as Fila[];
  const total = filas[0]?.total_filas ?? 0;
  const ultimaPagina = Math.max(1, Math.ceil(total / POR_PAGINA));

  const url = (p: number) => {
    const q = new URLSearchParams();
    if (sp.estado) q.set("estado", sp.estado);
    if (sp.prioridad) q.set("prioridad", sp.prioridad);
    q.set("p", String(p));
    return `/clientes?${q}`;
  };

  return (
    <>
      <h1>Clientes y prospectos</h1>
      <p className="subtitulo">
        Solo organizaciones con una relación comercial registrada — no la base
        completa de 5.639. Esa vive en{" "}
        <Link href="/organizaciones">Organizaciones</Link>. El estado se marca
        desde la ficha de cada organización.
      </p>

      <form className="filtros" method="get">
        <select name="estado" defaultValue={sp.estado ?? ""}>
          <option value="">Todo estado</option>
          {ESTADOS_COMERCIALES.map((e) => (
            <option key={e} value={e}>
              {e}
            </option>
          ))}
        </select>
        <select name="prioridad" defaultValue={sp.prioridad ?? ""}>
          <option value="">Toda prioridad</option>
          {PRIORIDADES.map((p) => (
            <option key={p} value={p}>
              {p}
            </option>
          ))}
        </select>
        <button type="submit">Filtrar</button>
        {(sp.estado || sp.prioridad) && (
          <Link href="/clientes" className="nav-enlace">
            Limpiar
          </Link>
        )}
      </form>

      {error && <div className="aviso-caja">No se pudo consultar: {error.message}</div>}

      <p className="subtitulo">{total.toLocaleString("es-CO")} organizaciones con relación comercial.</p>

      {total === 0 && !error && (
        <div className="aviso-caja neutro">
          Todavía no hay ninguna organización clasificada comercialmente. Ve a la
          ficha de una organización en <Link href="/organizaciones">Organizaciones</Link>{" "}
          y márcala como prospecto o cliente.
        </div>
      )}

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Nombre legal</th>
              <th>NIT</th>
              <th>Tipo</th>
              <th>Ciudad</th>
              <th>Estado</th>
              <th>Prioridad</th>
              <th>Notas</th>
              <th>Actualizado</th>
            </tr>
          </thead>
          <tbody>
            {filas.map((f) => (
              <tr key={f.id_organizacion}>
                <td>
                  <Link href={`/organizaciones/${f.id_organizacion}`}>{f.nombre_legal}</Link>
                </td>
                <td>{f.nit ?? "—"}</td>
                <td>{f.tipo_codigo ?? "—"}</td>
                <td>
                  {f.municipio ?? "—"}
                  {f.departamento && (
                    <span style={{ color: "var(--texto-suave)" }}> · {f.departamento}</span>
                  )}
                </td>
                <td>
                  <span className={insigniaEstado(f.estado_comercial)}>
                    {f.estado_comercial}
                  </span>
                </td>
                <td>
                  <span className={insigniaPrioridad(f.prioridad)}>{f.prioridad}</span>
                </td>
                <td style={{ maxWidth: 240, whiteSpace: "normal" }}>{f.notas ?? "—"}</td>
                <td>
                  {f.actualizado_en
                    ? new Date(f.actualizado_en).toLocaleDateString("es-CO")
                    : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="paginacion">
        {pagina > 1 && <Link href={url(pagina - 1)}>← Anterior</Link>}
        <span>
          Página {pagina} de {ultimaPagina}
        </span>
        {pagina < ultimaPagina && <Link href={url(pagina + 1)}>Siguiente →</Link>}
      </div>
    </>
  );
}
