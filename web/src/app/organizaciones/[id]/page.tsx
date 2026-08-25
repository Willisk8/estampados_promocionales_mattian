import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import {
  actualizarEstadoComercial,
  clasificarTipoOrganizacion,
} from "./acciones";

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

type TipoOrganizacion = {
  id: string;
  codigo: string;
  descripcion: string;
};

type RelacionComercial = {
  estado_comercial: string;
  prioridad: string;
  notas: string | null;
};

export default async function PaginaOrganizacion({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ ok?: string; error?: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const sp = await searchParams;
  const supabase = await crearClienteServidor();

  const [org, canales, personas, tipos, comercial] = await Promise.all([
    supabase.from("organizacion").select("*").eq("id_organizacion", id).maybeSingle(),
    supabase.rpc("fn_consola_canales_organizacion", { p_id_organizacion: id }),
    supabase.rpc("fn_consola_personas_organizacion", { p_id_organizacion: id }),
    supabase.from("cat_tipo_organizacion").select("id, codigo, descripcion").order("codigo"),
    supabase
      .from("relacion_comercial_organizacion")
      .select("estado_comercial, prioridad, notas")
      .eq("id_organizacion", id)
      .maybeSingle(),
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
  const listaTipos = (tipos.data ?? []) as TipoOrganizacion[];
  const relacion = comercial.data as RelacionComercial | null;
  const tipoActual = listaTipos.find((t) => t.id === o.id_tipo_organizacion);
  const hayEnmascarado = listaCanales.some((c) => c.enmascarado);
  const puedeEditar = sesion.rol === "ADMIN" || sesion.rol === "COMERCIAL";

  return (
    <>
      <p className="subtitulo" style={{ marginBottom: 6 }}>
        <Link href="/organizaciones">← Organizaciones</Link>
      </p>
      <h1>{o.nombre_legal}</h1>
      <p className="subtitulo">{o.nombre_comercial ?? "Sin nombre comercial"}</p>

      {sp.ok && <div className="aviso-caja neutro">Cambio guardado.</div>}
      {sp.error && <div className="aviso-caja">{sp.error}</div>}

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
            {tipoActual ? (
              `${tipoActual.codigo} - ${tipoActual.descripcion}`
            ) : (
              <span className="insignia aviso">pendiente</span>
            )}
          </dd>
          <dt>Estado comercial</dt>
          <dd>
            <span className={relacion?.estado_comercial === "CLIENTE" ? "insignia" : "insignia neutra"}>
              {relacion?.estado_comercial ?? "PROSPECTO"}
            </span>
            {" "}
            <span className="insignia neutra">{relacion?.prioridad ?? "MEDIA"}</span>
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

      <h2>Gestion comercial</h2>
      <div className="tarjeta">
        <form action={actualizarEstadoComercial} className="filtros">
          <input type="hidden" name="id" value={id} />
          <select
            name="estado_comercial"
            defaultValue={relacion?.estado_comercial ?? "PROSPECTO"}
            disabled={!puedeEditar}
          >
            <option value="PROSPECTO">Prospecto</option>
            <option value="CLIENTE">Cliente</option>
            <option value="DESCARTADO">Descartado</option>
            <option value="INACTIVO">Inactivo</option>
          </select>
          <select
            name="prioridad"
            defaultValue={relacion?.prioridad ?? "MEDIA"}
            disabled={!puedeEditar}
          >
            <option value="ALTA">Prioridad alta</option>
            <option value="MEDIA">Prioridad media</option>
            <option value="BAJA">Prioridad baja</option>
          </select>
          <input
            name="notas"
            placeholder="Notas comerciales"
            defaultValue={relacion?.notas ?? ""}
            disabled={!puedeEditar}
          />
          <button type="submit" disabled={!puedeEditar}>
            Guardar estado
          </button>
        </form>

        <form action={clasificarTipoOrganizacion} className="filtros">
          <input type="hidden" name="id" value={id} />
          <select
            name="tipo_codigo"
            defaultValue={tipoActual?.codigo ?? ""}
            disabled={!puedeEditar}
            required
          >
            <option value="">Tipo normalizado</option>
            {listaTipos.map((t) => (
              <option key={t.id} value={t.codigo}>
                {t.codigo} - {t.descripcion}
              </option>
            ))}
          </select>
          <input
            name="criterio"
            placeholder="Criterio de clasificacion"
            defaultValue="MANUAL"
            disabled={!puedeEditar}
          />
          <button type="submit" disabled={!puedeEditar}>
            Guardar tipo
          </button>
        </form>
        {!puedeEditar && (
          <p className="subtitulo" style={{ marginBottom: 0 }}>
            Tu rol puede consultar, pero solo ADMIN y COMERCIAL pueden actualizar
            clasificaciones.
          </p>
        )}
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
