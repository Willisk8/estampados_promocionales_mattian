import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

type Canal = {
  id_canal_contacto: string;
  tipo: string;
  valor: string;
  enmascarado: boolean;
  confianza: string;
  estado: string;
  fuente: string | null;
  base_contacto_codigo: string | null;
};

type Persona = {
  id_persona: string;
  nombre_completo: string;
  rol: string;
  cargo: string | null;
  area: string | null;
  estado: string;
};

export default async function PaginaOrganizacion({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const supabase = await crearClienteServidor();

  const [org, canales, personas] = await Promise.all([
    supabase.from("organizacion").select("*").eq("id_organizacion", id).maybeSingle(),
    supabase.rpc("fn_consola_canales_organizacion", { p_id_organizacion: id }),
    supabase.rpc("fn_consola_personas_organizacion", { p_id_organizacion: id }),
  ]);

  if (!org.data) {
    return (
      <>
        <h1>Organizacion no encontrada</h1>
        <p className="subtitulo">
          <Link href="/organizaciones">← Volver al listado</Link>
        </p>
      </>
    );
  }

  const o = org.data;
  const listaCanales = (canales.data ?? []) as Canal[];
  const listaPersonas = (personas.data ?? []) as Persona[];
  const hayEnmascarado = listaCanales.some((c) => c.enmascarado);

  return (
    <>
      <p className="subtitulo" style={{ marginBottom: 6 }}>
        <Link href="/organizaciones">← Organizaciones</Link>
      </p>
      <h1>{o.nombre_legal}</h1>
      <p className="subtitulo">{o.nombre_comercial ?? "Sin nombre comercial"}</p>

      <h2>Datos generales</h2>
      <div className="tarjeta">
        <dl className="datos">
          <dt>NIT</dt>
          <dd>{o.nit ?? "—"}</dd>
          <dt>Sigla</dt>
          <dd>{o.sigla ?? "—"}</dd>
          <dt>Tipo de origen</dt>
          <dd>{o.tipo_entidad_origen ?? "—"}</dd>
          <dt>Tipo normalizado</dt>
          <dd>
            {o.id_tipo_organizacion ? (
              o.id_tipo_organizacion
            ) : (
              <span className="insignia aviso">pendiente — Etapa C</span>
            )}
          </dd>
          <dt>Ubicacion</dt>
          <dd>{[o.municipio, o.departamento].filter(Boolean).join(", ") || "—"}</dd>
          <dt>Direccion</dt>
          <dd>{o.direccion ?? "—"}</dd>
          <dt>Estado</dt>
          <dd>
            <span className="insignia neutra">{o.estado}</span>
          </dd>
          <dt>Fuente</dt>
          <dd>{o.fuente_registro ?? "—"}</dd>
          <dt>Reporte oficial</dt>
          <dd>
            {o.fecha_reporte_oficial
              ? new Date(o.fecha_reporte_oficial).toLocaleDateString("es-CO")
              : "—"}
          </dd>
        </dl>
      </div>

      <h2>Canales de contacto ({listaCanales.length})</h2>
      {hayEnmascarado && (
        <div className="aviso-caja neutro">
          Los correos aparecen enmascarados para el rol{" "}
          <strong>{sesion.rol}</strong>. Solo el rol ADMIN ve la direccion
          completa.
        </div>
      )}
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Tipo</th>
              <th>Valor</th>
              <th>Confianza</th>
              <th>Estado</th>
              <th>Base de contacto</th>
              <th>Fuente</th>
            </tr>
          </thead>
          <tbody>
            {listaCanales.map((c) => (
              <tr key={c.id_canal_contacto}>
                <td>{c.tipo}</td>
                <td>{c.valor}</td>
                <td>{c.confianza}</td>
                <td>
                  <span
                    className={
                      c.estado === "ACTIVE" ? "insignia" : "insignia alerta"
                    }
                  >
                    {c.estado}
                  </span>
                </td>
                <td>
                  {c.base_contacto_codigo === "DESCONOCIDA" ||
                  !c.base_contacto_codigo ? (
                    <span className="insignia aviso">
                      {c.base_contacto_codigo ?? "sin registro"}
                    </span>
                  ) : (
                    c.base_contacto_codigo
                  )}
                </td>
                <td>{c.fuente ?? "—"}</td>
              </tr>
            ))}
            {listaCanales.length === 0 && (
              <tr>
                <td colSpan={6} style={{ color: "var(--texto-suave)" }}>
                  Sin canales registrados.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <h2>Personas relacionadas ({listaPersonas.length})</h2>
      <div className="tabla-contenedor">
        <table>
          <thead>
            <tr>
              <th>Nombre</th>
              <th>Rol</th>
              <th>Cargo</th>
              <th>Area</th>
              <th>Estado</th>
            </tr>
          </thead>
          <tbody>
            {listaPersonas.map((p) => (
              <tr key={p.id_persona + p.rol}>
                <td>{p.nombre_completo}</td>
                <td>{p.rol}</td>
                <td>{p.cargo ?? "—"}</td>
                <td>{p.area ?? "—"}</td>
                <td>
                  <span className="insignia neutra">{p.estado}</span>
                </td>
              </tr>
            ))}
            {listaPersonas.length === 0 && (
              <tr>
                <td colSpan={5} style={{ color: "var(--texto-suave)" }}>
                  Sin personas relacionadas.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
