import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const POR_PAGINA = 50;

type Fila = {
  id_organizacion: string;
  nit: string | null;
  nombre_legal: string;
  nombre_comercial: string | null;
  tipo_entidad_origen: string | null;
  departamento: string | null;
  municipio: string | null;
  estado: string;
  emails: number;
  telefonos: number;
  whatsapps: number;
  websites: number;
  total_filas: number;
};

export default async function PaginaOrganizaciones({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; depto?: string; email?: string; p?: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const sp = await searchParams;
  const pagina = Math.max(1, Number(sp.p ?? 1) || 1);
  const supabase = await crearClienteServidor();

  const { data, error } = await supabase.rpc("fn_consola_organizaciones", {
    p_busqueda: sp.q?.trim() || null,
    p_departamento: sp.depto?.trim() || null,
    p_municipio: null,
    p_solo_con_email: sp.email === "1" ? true : null,
    p_limite: POR_PAGINA,
    p_desplazamiento: (pagina - 1) * POR_PAGINA,
  });

  const filas = (data ?? []) as Fila[];
  const total = filas[0]?.total_filas ?? 0;
  const ultimaPagina = Math.max(1, Math.ceil(total / POR_PAGINA));

  const url = (p: number) => {
    const q = new URLSearchParams();
    if (sp.q) q.set("q", sp.q);
    if (sp.depto) q.set("depto", sp.depto);
    if (sp.email === "1") q.set("email", "1");
    q.set("p", String(p));
    return `/organizaciones?${q}`;
  };

  return (
    <>
      <h1>Organizaciones</h1>
      <p className="subtitulo">
        Base comercial de prospectos del sector solidario. Todavia no hay estado
        prospecto/cliente: eso llega en la Etapa C.
      </p>

      <form className="filtros" method="get">
        <input name="q" placeholder="Nombre o NIT" defaultValue={sp.q ?? ""} />
        <input name="depto" placeholder="Departamento" defaultValue={sp.depto ?? ""} />
        <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 14 }}>
          <input type="checkbox" name="email" value="1" defaultChecked={sp.email === "1"} />
          Solo con correo activo
        </label>
        <button type="submit">Filtrar</button>
      </form>

      {error && <div className="aviso-caja">No se pudo consultar: {error.message}</div>}

      <p className="subtitulo">
        {total.toLocaleString("es-CO")} organizaciones coinciden.
      </p>

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Nombre legal</th>
              <th>NIT</th>
              <th>Tipo de origen</th>
              <th>Ubicacion</th>
              <th className="num">Correos</th>
              <th className="num">Telefonos</th>
              <th className="num">Web</th>
            </tr>
          </thead>
          <tbody>
            {filas.map((f) => (
              <tr key={f.id_organizacion}>
                <td>
                  <Link href={`/organizaciones/${f.id_organizacion}`}>
                    {f.nombre_legal}
                  </Link>
                </td>
                <td>{f.nit ?? "—"}</td>
                <td>{f.tipo_entidad_origen ?? "—"}</td>
                <td>
                  {[f.municipio, f.departamento].filter(Boolean).join(", ") || "—"}
                </td>
                <td className="num">{f.emails}</td>
                <td className="num">{f.telefonos}</td>
                <td className="num">{f.websites}</td>
              </tr>
            ))}
            {filas.length === 0 && (
              <tr>
                <td colSpan={7} style={{ color: "var(--texto-suave)" }}>
                  Ninguna organizacion coincide con el filtro.
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
