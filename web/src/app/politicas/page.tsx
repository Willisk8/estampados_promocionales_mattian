import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import { guardarPlantilla, publicarPlantilla } from "./acciones";

export const dynamic = "force-dynamic";
type Plantilla = { id: string; codigo: string; version: number; estado: string; margen_base: number; tramos: { desde: number; margen: number }[] };

function Editor({ plantilla, copia = false }: { plantilla?: Plantilla; copia?: boolean }) {
  return <form action={guardarPlantilla} style={{ display: "grid", gap: "0.75rem", maxWidth: "42rem" }}>
    {plantilla && !copia && <input type="hidden" name="id" value={plantilla.id} />}
    <label>Codigo de politica <input name="codigo" required maxLength={64} defaultValue={plantilla?.codigo} readOnly={!!plantilla} pattern="[A-Za-z0-9][A-Za-z0-9_-]*" /></label>
    <label>Margen base (%) <input name="margen_base" required inputMode="decimal" defaultValue={plantilla?.margen_base} /></label>
    <label>Tramos: cantidad minima; margen (%)<textarea name="tramos" rows={5} style={{ display: "block", width: "100%" }} defaultValue={plantilla?.tramos.map(t => `${t.desde}; ${t.margen}`).join("\n")} /></label>
    <p>Una fila por tramo, cantidades enteras ascendentes y margenes que no aumenten. Sin tramos se aplica el margen base. El ultimo tramo no tiene limite superior.</p>
    <button type="submit">{plantilla && !copia ? "Guardar borrador" : "Crear borrador"}</button>
  </form>;
}

export default async function Politicas({ searchParams }: { searchParams: Promise<{ error?: string; ok?: string }> }) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;
  const params = await searchParams;
  const supabase = await crearClienteServidor();
  const { data, error } = await supabase.rpc("fn_consola_plantillas_margen");
  const plantillas = (data ?? []) as Plantilla[];
  const admin = sesion.rol === "ADMIN";
  return <>
    <h1>Politicas de margen</h1>
    <p>Plantillas versionadas. Publicar reemplaza la version activa del mismo codigo; conserva el historico. Solo ADMIN puede editar y publicar.</p>
    {(params.error || error) && <p role="alert" className="aviso-caja">{params.error || error?.message}</p>}
    {params.ok && <p role="status">{params.ok}</p>}
    {admin && <details><summary>Nueva politica</summary><Editor /></details>}
    {!plantillas.length && !error && <p>No hay plantillas publicadas o borradores disponibles.</p>}
    <div className="tabla-contenedor"><table><thead><tr><th>Codigo</th><th>Version</th><th>Estado</th><th>Margen base</th><th>Tramos</th><th>Gestion</th></tr></thead><tbody>
      {plantillas.map(p => <tr key={p.id}><td>{p.codigo}</td><td>{p.version}</td><td>{p.estado}</td><td>{p.margen_base}%</td><td>{p.tramos.map(t => `Desde ${t.desde}: ${t.margen}%`).join(" · ") || "Sin tramos"}</td><td>
        {admin && <details><summary>{p.estado === "DRAFT" ? "Editar borrador" : "Crear siguiente version"}</summary><Editor plantilla={p} copia={p.estado !== "DRAFT"} /></details>}
        {admin && p.estado === "DRAFT" && <form action={publicarPlantilla}><input type="hidden" name="id" value={p.id} /><p>Publicar congelara esta version y retirara la anterior.</p><button type="submit">Publicar version {p.version}</button></form>}
      </td></tr>)}
    </tbody></table></div>
  </>;
}
