import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const POR_PAGINA = 50;

type Revision = {
  id_import_review_item: string;
  severity: string;
  review_reason: string;
  entity_kind: string;
  match_status: string;
  target_table: string | null;
  target_id: string | null;
  error_message: string | null;
  row_number: number;
  source_name: string;
  review_created_at: string;
  total_filas: number;
};

type Lote = {
  id_import_batch: string;
  source_name: string;
  source_row_count: number | null;
  import_status: string;
  created_at: string;
  finished_at: string | null;
};

const insigniaSeveridad = (s: string) =>
  s === "HIGH" ? "insignia alerta" : s === "MEDIUM" ? "insignia aviso" : "insignia neutra";

export default async function PaginaImportaciones({
  searchParams,
}: {
  searchParams: Promise<{ sev?: string; p?: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const sp = await searchParams;
  const pagina = Math.max(1, Number(sp.p ?? 1) || 1);
  const supabase = await crearClienteServidor();

  const [revisiones, lotes] = await Promise.all([
    supabase.rpc("fn_consola_revisiones", {
      p_severidad: sp.sev || null,
      p_limite: POR_PAGINA,
      p_desplazamiento: (pagina - 1) * POR_PAGINA,
    }),
    supabase
      .from("import_batch")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(15),
  ]);

  const filas = (revisiones.data ?? []) as Revision[];
  const total = filas[0]?.total_filas ?? 0;
  const ultimaPagina = Math.max(1, Math.ceil(total / POR_PAGINA));
  const listaLotes = (lotes.data ?? []) as Lote[];

  const url = (p: number, sev?: string) => {
    const q = new URLSearchParams();
    if (sev ?? sp.sev) q.set("sev", (sev ?? sp.sev)!);
    q.set("p", String(p));
    return `/importaciones?${q}`;
  };

  return (
    <>
      <h1>Importaciones</h1>
      <p className="subtitulo">
        Lotes cargados y cola de revision humana abierta.
      </p>

      <h2>Ultimos lotes</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Fuente</th>
              <th className="num">Filas</th>
              <th>Estado</th>
              <th>Creado</th>
              <th>Finalizado</th>
            </tr>
          </thead>
          <tbody>
            {listaLotes.map((l) => (
              <tr key={l.id_import_batch}>
                <td>{l.source_name}</td>
                <td className="num">{l.source_row_count ?? "—"}</td>
                <td>
                  <span
                    className={
                      l.import_status === "COMPLETED" ? "insignia" : "insignia aviso"
                    }
                  >
                    {l.import_status}
                  </span>
                </td>
                <td>{new Date(l.created_at).toLocaleString("es-CO")}</td>
                <td>
                  {l.finished_at
                    ? new Date(l.finished_at).toLocaleString("es-CO")
                    : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h2>Cola de revision abierta ({total.toLocaleString("es-CO")})</h2>

      <div className="filtros">
        <Link href={url(1, undefined)} className="nav-enlace">
          Todas
        </Link>
        <Link href={url(1, "HIGH")} className="nav-enlace">
          Solo HIGH
        </Link>
        <Link href={url(1, "MEDIUM")} className="nav-enlace">
          Solo MEDIUM
        </Link>
      </div>

      <div className="aviso-caja neutro">
        Esta cola es de solo lectura en la Etapa B. Resolver un item es la unica
        escritura prevista, y llega con su registro de auditoria en una migracion
        aparte.
      </div>

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Severidad</th>
              <th>Motivo</th>
              <th>Entidad</th>
              <th>Estado de cruce</th>
              <th className="num">Fila</th>
              <th>Fuente</th>
              <th>Detectado</th>
            </tr>
          </thead>
          <tbody>
            {filas.map((r) => (
              <tr key={r.id_import_review_item}>
                <td>
                  <span className={insigniaSeveridad(r.severity)}>{r.severity}</span>
                </td>
                <td>{r.review_reason}</td>
                <td>{r.entity_kind}</td>
                <td>{r.match_status}</td>
                <td className="num">{r.row_number}</td>
                <td>{r.source_name}</td>
                <td>{new Date(r.review_created_at).toLocaleDateString("es-CO")}</td>
              </tr>
            ))}
            {filas.length === 0 && (
              <tr>
                <td colSpan={7} style={{ color: "var(--texto-suave)" }}>
                  Sin items abiertos con este filtro.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="paginacion">
        {pagina > 1 && <Link href={url(pagina - 1)}>← Anterior</Link>}
        <span>
          Pagina {pagina} de {ultimaPagina}
        </span>
        {pagina < ultimaPagina && <Link href={url(pagina + 1)}>Siguiente →</Link>}
      </div>
    </>
  );
}
