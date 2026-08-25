import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

const POR_PAGINA = 50;

/** Un reporte oficial viejo puede describir una entidad que ya no existe. */
const ANIOS_PARA_ALERTA = 4;

type Fila = {
  id_organizacion: string;
  nit: string | null;
  nombre_legal: string;
  nombre_comercial: string | null;
  tipo_entidad_origen: string | null;
  tipo_codigo: string | null;
  tipo_descripcion: string | null;
  estado_comercial: string;
  prioridad_comercial: string;
  departamento: string | null;
  municipio: string | null;
  estado: string;
  fecha_reporte_oficial: string | null;
  anios_desde_reporte: number | null;
  emails: number;
  telefonos: number;
  whatsapps: number;
  websites: number;
  total_filas: number;
};

function Antiguedad({ anios, fecha }: { anios: number | null; fecha: string | null }) {
  if (fecha === null) return <span style={{ color: "var(--texto-suave)" }}>—</span>;
  const texto = new Date(fecha).toLocaleDateString("es-CO", {
    year: "numeric",
    month: "short",
  });
  if (anios === null) return <>{texto}</>;
  if (anios >= ANIOS_PARA_ALERTA) {
    return (
      <span className="insignia alerta" title={`${anios} anios sin reportar`}>
        {texto}
      </span>
    );
  }
  if (anios >= 2) {
    return (
      <span className="insignia aviso" title={`${anios} anios sin reportar`}>
        {texto}
      </span>
    );
  }
  return <>{texto}</>;
}

export default async function PaginaOrganizaciones({
  searchParams,
}: {
  searchParams: Promise<{
    q?: string;
    depto?: string;
    ciudad?: string;
    email?: string;
    p?: string;
  }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const sp = await searchParams;
  const pagina = Math.max(1, Number(sp.p ?? 1) || 1);
  const supabase = await crearClienteServidor();

  const [orgs, ubic] = await Promise.all([
    supabase.rpc("fn_consola_organizaciones", {
      p_busqueda: sp.q?.trim() || null,
      p_departamento: sp.depto?.trim() || null,
      p_municipio: sp.ciudad?.trim() || null,
      p_solo_con_email: sp.email === "1" ? true : null,
      p_limite: POR_PAGINA,
      p_desplazamiento: (pagina - 1) * POR_PAGINA,
    }),
    supabase.rpc("fn_consola_ubicaciones", { p_departamento: null }),
  ]);

  const filas = (orgs.data ?? []) as Fila[];
  const total = filas[0]?.total_filas ?? 0;
  const ultimaPagina = Math.max(1, Math.ceil(total / POR_PAGINA));

  const ubicaciones = (ubic.data ?? []) as Array<{
    departamento: string;
    municipio: string | null;
  }>;
  const departamentos = [...new Set(ubicaciones.map((u) => u.departamento))].sort();
  const ciudades = [
    ...new Set(
      ubicaciones
        .filter((u) =>
          sp.depto
            ? u.departamento.toLowerCase().includes(sp.depto.toLowerCase())
            : true,
        )
        .map((u) => u.municipio)
        .filter((m): m is string => Boolean(m)),
    ),
  ].sort();

  const desactualizadas = filas.filter(
    (f) => (f.anios_desde_reporte ?? 0) >= ANIOS_PARA_ALERTA,
  ).length;

  const url = (p: number) => {
    const q = new URLSearchParams();
    if (sp.q) q.set("q", sp.q);
    if (sp.depto) q.set("depto", sp.depto);
    if (sp.ciudad) q.set("ciudad", sp.ciudad);
    if (sp.email === "1") q.set("email", "1");
    q.set("p", String(p));
    return `/organizaciones?${q}`;
  };

  return (
    <>
      <h1>Organizaciones</h1>
      <p className="subtitulo">
        Base comercial de prospectos y clientes. El tipo normalizado y el estado
        comercial se manejan separados del dato oficial de origen.
      </p>

      <form className="filtros" method="get">
        <input name="q" placeholder="Nombre o NIT" defaultValue={sp.q ?? ""} />
        <select name="depto" defaultValue={sp.depto ?? ""}>
          <option value="">Todo departamento</option>
          {departamentos.map((d) => (
            <option key={d} value={d}>
              {d}
            </option>
          ))}
        </select>
        <select name="ciudad" defaultValue={sp.ciudad ?? ""}>
          <option value="">Toda ciudad</option>
          {ciudades.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </select>
        <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 14 }}>
          <input type="checkbox" name="email" value="1" defaultChecked={sp.email === "1"} />
          Solo con correo activo
        </label>
        <button type="submit">Filtrar</button>
        {(sp.q || sp.depto || sp.ciudad || sp.email) && (
          <Link href="/organizaciones" className="nav-enlace">
            Limpiar
          </Link>
        )}
      </form>

      {orgs.error && (
        <div className="aviso-caja">No se pudo consultar: {orgs.error.message}</div>
      )}

      <p className="subtitulo">
        {total.toLocaleString("es-CO")} organizaciones coinciden.
        {sp.ciudad ? ` Ciudad: ${sp.ciudad}.` : ""}
      </p>

      {desactualizadas > 0 && (
        <div className="aviso-caja">
          {desactualizadas} de las {filas.length} de esta pagina no reportan hace{" "}
          {ANIOS_PARA_ALERTA} anios o mas. Una entidad reportada en 2017 puede
          haberse liquidado: conviene verificarla antes de contactarla.
        </div>
      )}

      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Nombre legal</th>
              <th>NIT</th>
              <th>Tipo</th>
              <th>Estado comercial</th>
              <th>Ciudad</th>
              <th>Ultimo reporte</th>
              <th className="num">Correos</th>
              <th className="num">Telefonos</th>
              <th className="num">WhatsApp</th>
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
                <td>
                  {f.tipo_codigo ? (
                    <span title={f.tipo_entidad_origen ?? undefined}>
                      {f.tipo_codigo}
                    </span>
                  ) : (
                    <span className="insignia aviso">pendiente</span>
                  )}
                </td>
                <td>
                  <span
                    className={
                      f.estado_comercial === "CLIENTE" ? "insignia" : "insignia neutra"
                    }
                  >
                    {f.estado_comercial}
                  </span>
                  {f.prioridad_comercial === "ALTA" && (
                    <>
                      {" "}
                      <span className="insignia aviso">ALTA</span>
                    </>
                  )}
                </td>
                <td>
                  {f.municipio ?? "—"}
                  {f.departamento && (
                    <span style={{ color: "var(--texto-suave)" }}>
                      {" "}
                      · {f.departamento}
                    </span>
                  )}
                </td>
                <td>
                  <Antiguedad
                    anios={f.anios_desde_reporte}
                    fecha={f.fecha_reporte_oficial}
                  />
                </td>
                <td className="num">{f.emails}</td>
                <td className="num">{f.telefonos}</td>
                <td className="num">{f.whatsapps}</td>
                <td className="num">{f.websites}</td>
              </tr>
            ))}
            {filas.length === 0 && (
              <tr>
                <td colSpan={10} style={{ color: "var(--texto-suave)" }}>
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
