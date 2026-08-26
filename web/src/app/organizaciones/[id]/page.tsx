import Link from "next/link";
import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";
import {
  actualizarEstadoComercial,
  clasificarTipoOrganizacion,
  registrarInteraccion,
  programarSeguimiento,
  completarSeguimiento,
  actualizarPreferenciaCliente,
  aprobarAccionIA,
} from "./acciones";

export const dynamic = "force-dynamic";

// ----------------------------------------------------------
// Tipos — reflejan las funciones/tablas de la Etapa C (docs/plan_ia.md)
// ----------------------------------------------------------

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

type Cliente360 = {
  temperatura: string;
  cotizaciones_abiertas: number;
  total_interacciones: number;
  total_cotizaciones: number;
  total_cotizaciones_aceptadas: number;
  total_pedidos: number;
  valor_total_cotizado: number;
  valor_total_vendido: number;
  fecha_ultima_interaccion: string | null;
  fecha_ultima_cotizacion: string | null;
  fecha_ultimo_pedido: string | null;
  producto_mas_cotizado: string | null;
  producto_mas_comprado: string | null;
  dias_desde_ultima_gestion: number | null;
  score_engagement: number;
  score_compra: number | null;
};

type EventoTimeline = {
  id_evento: string;
  categoria: string;
  tipo_evento: string;
  canal: string | null;
  resumen: string;
  persona_nombre: string | null;
  occurred_at: string;
  hay_mas: boolean;
};

type Cotizacion = {
  id_cotizacion: string;
  numero: number;
  estado: string;
  total: number;
  moneda: string;
  fecha_emision: string | null;
  fecha_vencimiento: string | null;
  created_at: string;
};

type Pedido = {
  id_pedido: string;
  numero: number;
  estado: string;
  estado_pago: string;
  total: number;
  saldo: number;
  fecha_pedido: string;
  fecha_prometida_entrega: string | null;
  fecha_entrega_real: string | null;
};

type SeguimientoPendiente = {
  id_cotizacion_followup: string;
  id_cotizacion: string;
  numero_cotizacion: number;
  fecha_programada: string;
  notas: string | null;
  esta_atrasado: boolean;
};

type Preferencia = {
  canal_preferido: string | null;
  horario_preferido: string | null;
  frecuencia_contacto_preferida: string | null;
  sensibilidad_precio: string | null;
  notas_comerciales: string | null;
};

type Recomendacion = {
  id_ia_recomendacion: string;
  texto: string;
  created_at: string;
};

type PropuestaIA = {
  id_ia_accion_propuesta: string;
  tipo_accion: string;
  justificacion: string;
  estado: string;
  expira_at: string;
  created_at: string;
};

const PESTANAS = [
  { clave: "resumen", texto: "Resumen" },
  { clave: "timeline", texto: "Timeline" },
  { clave: "contactos", texto: "Contactos" },
  { clave: "cotizaciones", texto: "Cotizaciones" },
  { clave: "pedidos", texto: "Pedidos" },
  { clave: "preferencias", texto: "Preferencias" },
  { clave: "ia", texto: "Recomendaciones IA" },
] as const;

type Pestana = (typeof PESTANAS)[number]["clave"];

function fechaHora(v: string | null) {
  if (!v) return "—";
  return new Date(v).toLocaleString("es-CO", { dateStyle: "short", timeStyle: "short" });
}

function fecha(v: string | null) {
  if (!v) return "—";
  return new Date(v).toLocaleDateString("es-CO");
}

function moneda(v: number | null) {
  if (v === null || v === undefined) return "—";
  return v.toLocaleString("es-CO", { style: "currency", currency: "COP", maximumFractionDigits: 0 });
}

function insigniaTemperatura(t: string) {
  if (t === "ACTIVO") return "insignia";
  if (t === "EN_NEGOCIACION") return "insignia aviso";
  if (t === "PERDIDO") return "insignia alerta";
  return "insignia neutra"; // FRIO
}

export default async function PaginaOrganizacion({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ ok?: string; error?: string; tab?: string }>;
}) {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const { id } = await params;
  const sp = await searchParams;
  const pestana: Pestana = (PESTANAS.find((p) => p.clave === sp.tab)?.clave ?? "resumen");
  const supabase = await crearClienteServidor();

  const [
    org,
    canales,
    personas,
    tipos,
    comercial,
    cliente360,
    timeline,
    cotizaciones,
    pedidos,
    seguimientos,
    preferencia,
    recomendaciones,
    propuestas,
  ] = await Promise.all([
    supabase.from("organizacion").select("*").eq("id_organizacion", id).maybeSingle(),
    supabase.rpc("fn_consola_canales_organizacion", { p_id_organizacion: id }),
    supabase.rpc("fn_consola_personas_organizacion", { p_id_organizacion: id }),
    supabase.from("cat_tipo_organizacion").select("id, codigo, descripcion").order("codigo"),
    supabase
      .from("relacion_comercial_organizacion")
      .select("estado_comercial, prioridad, notas")
      .eq("id_organizacion", id)
      .maybeSingle(),
    supabase.rpc("fn_consola_cliente_360", { p_id_organizacion: id }).maybeSingle(),
    supabase.rpc("fn_consola_timeline_cliente", { p_id_organizacion: id, p_limite: 50 }),
    supabase
      .from("cotizacion")
      .select("id_cotizacion, numero, estado, total, moneda, fecha_emision, fecha_vencimiento, created_at")
      .eq("id_organizacion", id)
      .order("created_at", { ascending: false }),
    supabase
      .from("pedido")
      .select("id_pedido, numero, estado, estado_pago, total, saldo, fecha_pedido, fecha_prometida_entrega, fecha_entrega_real")
      .eq("id_organizacion", id)
      .order("fecha_pedido", { ascending: false }),
    supabase
      .from("vw_clientes_para_followup")
      .select("id_cotizacion_followup, id_cotizacion, numero_cotizacion, fecha_programada, notas, esta_atrasado")
      .eq("id_organizacion", id)
      .order("fecha_programada", { ascending: true }),
    supabase
      .from("cliente_preferencia")
      .select("canal_preferido, horario_preferido, frecuencia_contacto_preferida, sensibilidad_precio, notas_comerciales")
      .eq("id_organizacion", id)
      .maybeSingle(),
    supabase
      .from("ia_recomendacion")
      .select("id_ia_recomendacion, texto, created_at")
      .eq("id_organizacion", id)
      .order("created_at", { ascending: false })
      .limit(20),
    supabase
      .from("ia_accion_propuesta")
      .select("id_ia_accion_propuesta, tipo_accion, justificacion, estado, expira_at, created_at")
      .eq("id_organizacion", id)
      .order("created_at", { ascending: false })
      .limit(20),
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
  const c360 = cliente360.data as Cliente360 | null;
  const listaTimeline = (timeline.data ?? []) as EventoTimeline[];
  const listaCotizaciones = (cotizaciones.data ?? []) as Cotizacion[];
  const listaPedidos = (pedidos.data ?? []) as Pedido[];
  const listaSeguimientos = (seguimientos.data ?? []) as SeguimientoPendiente[];
  const pref = preferencia.data as Preferencia | null;
  const listaRecomendaciones = (recomendaciones.data ?? []) as Recomendacion[];
  const listaPropuestas = (propuestas.data ?? []) as PropuestaIA[];

  const tipoActual = listaTipos.find((t) => t.id === o.id_tipo_organizacion);
  const hayEnmascarado = listaCanales.some((c) => c.enmascarado);
  const puedeEditar = sesion.rol === "ADMIN" || sesion.rol === "COMERCIAL";

  const conTab = (tab: Pestana) => {
    const q = new URLSearchParams({ tab });
    return `?${q}`;
  };

  return (
    <>
      <p className="subtitulo" style={{ marginBottom: 6 }}>
        <Link href="/organizaciones">← Organizaciones</Link>
      </p>
      <h1>{o.nombre_legal}</h1>
      <p className="subtitulo">
        {o.nombre_comercial ?? "Sin nombre comercial"}
        {c360 && (
          <>
            {" · "}
            <span className={insigniaTemperatura(c360.temperatura)}>{c360.temperatura}</span>
          </>
        )}
      </p>

      {sp.ok && <div className="aviso-caja neutro">Cambio guardado.</div>}
      {sp.error && <div className="aviso-caja">{sp.error}</div>}

      <nav className="filtros" aria-label="Pestañas de la organización">
        {PESTANAS.map((p) => (
          <Link
            key={p.clave}
            href={conTab(p.clave)}
            className="nav-enlace"
            aria-current={pestana === p.clave ? "page" : undefined}
          >
            {p.texto}
          </Link>
        ))}
      </nav>

      {pestana === "resumen" && (
        <>
          <h2>Cliente 360</h2>
          <div className="rejilla">
            <div className="tarjeta">
              <div className="cifra">{c360?.dias_desde_ultima_gestion ?? "—"}</div>
              <div className="etiqueta">Días desde la última gestión</div>
            </div>
            <div className="tarjeta">
              <div className="cifra">{c360?.cotizaciones_abiertas ?? 0}</div>
              <div className="etiqueta">Cotizaciones abiertas</div>
            </div>
            <div className="tarjeta">
              <div className="cifra">{c360?.total_pedidos ?? 0}</div>
              <div className="etiqueta">Pedidos históricos</div>
            </div>
            <div className="tarjeta">
              <div className="cifra">{moneda(c360?.valor_total_vendido ?? 0)}</div>
              <div className="etiqueta">Valor total vendido</div>
            </div>
          </div>
          <div className="tarjeta" style={{ marginBottom: 18 }}>
            <dl className="datos">
              <dt>Última interacción</dt>
              <dd>{fechaHora(c360?.fecha_ultima_interaccion ?? null)}</dd>
              <dt>Última cotización</dt>
              <dd>{fecha(c360?.fecha_ultima_cotizacion ?? null)}</dd>
              <dt>Último pedido</dt>
              <dd>{fecha(c360?.fecha_ultimo_pedido ?? null)}</dd>
              <dt>Cotizaciones cotizadas / aceptadas</dt>
              <dd>
                {c360?.total_cotizaciones ?? 0} / {c360?.total_cotizaciones_aceptadas ?? 0}
              </dd>
              <dt>Valor total cotizado</dt>
              <dd>{moneda(c360?.valor_total_cotizado ?? 0)}</dd>
              <dt>Producto más cotizado</dt>
              <dd>{c360?.producto_mas_cotizado ?? "—"}</dd>
              <dt>Producto más comprado</dt>
              <dd>{c360?.producto_mas_comprado ?? "—"}</dd>
            </dl>
          </div>

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
                </span>{" "}
                <span className="insignia neutra">{relacion?.prioridad ?? "MEDIA"}</span>
              </dd>
              <dt>Ubicacion</dt>
              <dd>{[o.municipio, o.departamento].filter(Boolean).join(", ") || "—"}</dd>
              <dt>Dirección</dt>
              <dd>{o.direccion ?? "—"}</dd>
              <dt>Estado</dt>
              <dd>
                <span className="insignia neutra">{o.estado}</span>
              </dd>
              <dt>Fuente</dt>
              <dd>{o.fuente_registro ?? "—"}</dd>
            </dl>
          </div>

          <h2>Gestión comercial</h2>
          <div className="tarjeta">
            <form action={actualizarEstadoComercial} className="filtros">
              <input type="hidden" name="id" value={id} />
              <select name="estado_comercial" defaultValue={relacion?.estado_comercial ?? "PROSPECTO"} disabled={!puedeEditar}>
                <option value="PROSPECTO">Prospecto</option>
                <option value="CLIENTE">Cliente</option>
                <option value="DESCARTADO">Descartado</option>
                <option value="INACTIVO">Inactivo</option>
              </select>
              <select name="prioridad" defaultValue={relacion?.prioridad ?? "MEDIA"} disabled={!puedeEditar}>
                <option value="ALTA">Prioridad alta</option>
                <option value="MEDIA">Prioridad media</option>
                <option value="BAJA">Prioridad baja</option>
              </select>
              <input name="notas" placeholder="Notas comerciales" defaultValue={relacion?.notas ?? ""} disabled={!puedeEditar} />
              <button type="submit" disabled={!puedeEditar}>
                Guardar estado
              </button>
            </form>

            <form action={clasificarTipoOrganizacion} className="filtros">
              <input type="hidden" name="id" value={id} />
              <select name="tipo_codigo" defaultValue={tipoActual?.codigo ?? ""} disabled={!puedeEditar} required>
                <option value="">Tipo normalizado</option>
                {listaTipos.map((t) => (
                  <option key={t.id} value={t.codigo}>
                    {t.codigo} - {t.descripcion}
                  </option>
                ))}
              </select>
              <input name="criterio" placeholder="Criterio de clasificacion" defaultValue="MANUAL" disabled={!puedeEditar} />
              <button type="submit" disabled={!puedeEditar}>
                Guardar tipo
              </button>
            </form>
            {!puedeEditar && (
              <p className="subtitulo" style={{ marginBottom: 0 }}>
                Tu rol puede consultar, pero solo ADMIN y COMERCIAL pueden actualizar clasificaciones.
              </p>
            )}
          </div>
        </>
      )}

      {pestana === "timeline" && (
        <>
          <h2>Registrar interacción</h2>
          <div className="tarjeta" style={{ marginBottom: 18 }}>
            <form action={registrarInteraccion} className="filtros">
              <input type="hidden" name="id" value={id} />
              <select name="tipo_interaccion" defaultValue="LLAMADA" disabled={!puedeEditar}>
                <option value="LLAMADA">Llamada</option>
                <option value="WHATSAPP">WhatsApp</option>
                <option value="VISITA">Visita</option>
                <option value="REUNION">Reunión</option>
                <option value="EMAIL_INDIVIDUAL">Email</option>
                <option value="NOTA_INTERNA">Nota interna</option>
              </select>
              <select name="direccion" defaultValue="OUTBOUND" disabled={!puedeEditar}>
                <option value="OUTBOUND">Salida</option>
                <option value="INBOUND">Entrada</option>
              </select>
              <select name="motivo" defaultValue="SEGUIMIENTO" disabled={!puedeEditar}>
                <option value="SEGUIMIENTO">Seguimiento</option>
                <option value="COTIZACION">Cotización</option>
                <option value="PEDIDO">Pedido</option>
                <option value="MARKETING">Marketing</option>
                <option value="SOPORTE">Soporte</option>
                <option value="OTRO">Otro</option>
              </select>
              <input name="asunto" placeholder="Asunto" disabled={!puedeEditar} />
              <button type="submit" disabled={!puedeEditar}>
                Registrar
              </button>
            </form>
            {!puedeEditar && (
              <p className="subtitulo" style={{ marginBottom: 0 }}>
                Tu rol puede consultar el timeline, pero solo ADMIN y COMERCIAL pueden registrar interacciones.
              </p>
            )}
          </div>

          <h2>Timeline ({listaTimeline.length})</h2>
          <div className="tabla-contenedor">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Categoría</th>
                  <th>Tipo</th>
                  <th>Canal</th>
                  <th>Resumen</th>
                  <th>Persona</th>
                </tr>
              </thead>
              <tbody>
                {listaTimeline.map((e) => (
                  <tr key={e.id_evento}>
                    <td>{fechaHora(e.occurred_at)}</td>
                    <td>
                      <span className="insignia neutra">{e.categoria}</span>
                    </td>
                    <td>{e.tipo_evento}</td>
                    <td>{e.canal ?? "—"}</td>
                    <td style={{ maxWidth: 320, whiteSpace: "normal" }}>{e.resumen}</td>
                    <td>{e.persona_nombre ?? "—"}</td>
                  </tr>
                ))}
                {listaTimeline.length === 0 && (
                  <tr>
                    <td colSpan={6} style={{ color: "var(--texto-suave)" }}>
                      Sin eventos registrados todavía.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
          {listaTimeline.some((e) => e.hay_mas) && (
            <p className="subtitulo">Hay más eventos de los que se muestran aquí (tope de 50 por consulta).</p>
          )}
        </>
      )}

      {pestana === "contactos" && (
        <>
          <h2>Canales de contacto ({listaCanales.length})</h2>
          {hayEnmascarado && (
            <div className="aviso-caja neutro">
              Los correos aparecen enmascarados para el rol <strong>{sesion.rol}</strong>. Solo el rol ADMIN ve la
              dirección completa.
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
                      <span className={c.estado === "ACTIVE" ? "insignia" : "insignia alerta"}>{c.estado}</span>
                    </td>
                    <td>
                      {c.base_contacto_codigo === "DESCONOCIDA" || !c.base_contacto_codigo ? (
                        <span className="insignia aviso">{c.base_contacto_codigo ?? "sin registro"}</span>
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
                  <th>Área</th>
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
      )}

      {pestana === "cotizaciones" && (
        <>
          {listaSeguimientos.length > 0 && (
            <>
              <h2>Seguimientos pendientes ({listaSeguimientos.length})</h2>
              <div className="tabla-contenedor" style={{ marginBottom: 18 }}>
                <table>
                  <thead>
                    <tr>
                      <th>Cotización</th>
                      <th>Fecha programada</th>
                      <th>Notas</th>
                      <th>Estado</th>
                      {puedeEditar && <th>Acción</th>}
                    </tr>
                  </thead>
                  <tbody>
                    {listaSeguimientos.map((s) => (
                      <tr key={s.id_cotizacion_followup}>
                        <td>#{s.numero_cotizacion}</td>
                        <td>{fechaHora(s.fecha_programada)}</td>
                        <td style={{ maxWidth: 240, whiteSpace: "normal" }}>{s.notas ?? "—"}</td>
                        <td>
                          <span className={s.esta_atrasado ? "insignia alerta" : "insignia aviso"}>
                            {s.esta_atrasado ? "atrasado" : "pendiente"}
                          </span>
                        </td>
                        {puedeEditar && (
                          <td>
                            <form action={completarSeguimiento} style={{ display: "inline" }}>
                              <input type="hidden" name="id" value={id} />
                              <input type="hidden" name="id_cotizacion_followup" value={s.id_cotizacion_followup} />
                              <button type="submit">Completar</button>
                            </form>
                          </td>
                        )}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}

          <h2>Cotizaciones ({listaCotizaciones.length})</h2>
          <div className="tabla-contenedor">
            <table>
              <thead>
                <tr>
                  <th>Número</th>
                  <th>Estado</th>
                  <th>Total</th>
                  <th>Emisión</th>
                  <th>Vencimiento</th>
                  {puedeEditar && <th>Programar seguimiento</th>}
                </tr>
              </thead>
              <tbody>
                {listaCotizaciones.map((c) => (
                  <tr key={c.id_cotizacion}>
                    <td>#{c.numero}</td>
                    <td>
                      <span className="insignia neutra">{c.estado}</span>
                    </td>
                    <td className="num">{moneda(c.total)}</td>
                    <td>{fecha(c.fecha_emision)}</td>
                    <td>{fecha(c.fecha_vencimiento)}</td>
                    {puedeEditar && (
                      <td>
                        <form action={programarSeguimiento} className="form-inline">
                          <input type="hidden" name="id" value={id} />
                          <input type="hidden" name="id_cotizacion" value={c.id_cotizacion} />
                          <input type="datetime-local" name="fecha_programada" required />
                          <button type="submit">Programar</button>
                        </form>
                      </td>
                    )}
                  </tr>
                ))}
                {listaCotizaciones.length === 0 && (
                  <tr>
                    <td colSpan={puedeEditar ? 6 : 5} style={{ color: "var(--texto-suave)" }}>
                      Sin cotizaciones registradas.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}

      {pestana === "pedidos" && (
        <>
          <h2>Pedidos ({listaPedidos.length})</h2>
          <div className="tabla-contenedor">
            <table>
              <thead>
                <tr>
                  <th>Número</th>
                  <th>Estado</th>
                  <th>Pago</th>
                  <th>Total</th>
                  <th>Saldo</th>
                  <th>Fecha pedido</th>
                  <th>Entrega prometida</th>
                  <th>Entrega real</th>
                </tr>
              </thead>
              <tbody>
                {listaPedidos.map((p) => (
                  <tr key={p.id_pedido}>
                    <td>#{p.numero}</td>
                    <td>
                      <span className="insignia neutra">{p.estado}</span>
                    </td>
                    <td>
                      <span className={p.estado_pago === "PAGADO" ? "insignia" : "insignia aviso"}>{p.estado_pago}</span>
                    </td>
                    <td className="num">{moneda(p.total)}</td>
                    <td className="num">{moneda(p.saldo)}</td>
                    <td>{fecha(p.fecha_pedido)}</td>
                    <td>{fecha(p.fecha_prometida_entrega)}</td>
                    <td>{fecha(p.fecha_entrega_real)}</td>
                  </tr>
                ))}
                {listaPedidos.length === 0 && (
                  <tr>
                    <td colSpan={8} style={{ color: "var(--texto-suave)" }}>
                      Sin pedidos registrados.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}

      {pestana === "preferencias" && (
        <>
          <h2>Preferencias del cliente</h2>
          <div className="tarjeta">
            <form action={actualizarPreferenciaCliente} className="filtros">
              <input type="hidden" name="id" value={id} />
              <select name="canal_preferido" defaultValue={pref?.canal_preferido ?? ""} disabled={!puedeEditar}>
                <option value="">Canal preferido</option>
                <option value="EMAIL">Email</option>
                <option value="TELEFONO">Teléfono</option>
                <option value="WHATSAPP">WhatsApp</option>
              </select>
              <input
                name="horario_preferido"
                placeholder="Horario preferido"
                defaultValue={pref?.horario_preferido ?? ""}
                disabled={!puedeEditar}
              />
              <input
                name="frecuencia_contacto_preferida"
                placeholder="Frecuencia de contacto"
                defaultValue={pref?.frecuencia_contacto_preferida ?? ""}
                disabled={!puedeEditar}
              />
              <select
                name="sensibilidad_precio"
                defaultValue={pref?.sensibilidad_precio ?? "MEDIA"}
                disabled={!puedeEditar}
              >
                <option value="ALTA">Sensibilidad de precio alta</option>
                <option value="MEDIA">Sensibilidad de precio media</option>
                <option value="BAJA">Sensibilidad de precio baja</option>
              </select>
              <input
                name="notas_comerciales"
                placeholder="Notas comerciales"
                defaultValue={pref?.notas_comerciales ?? ""}
                disabled={!puedeEditar}
              />
              <button type="submit" disabled={!puedeEditar}>
                Guardar preferencias
              </button>
            </form>
            <p className="subtitulo" style={{ marginBottom: 0 }}>
              Esto es informativo (lo que el cliente declaró). No limita cuántas campañas se le envían — ese control
              vive aparte, en la política de frecuencia de la Fase 8.
            </p>
          </div>
        </>
      )}

      {pestana === "ia" && (
        <>
          <h2>Propuestas pendientes de aprobación ({listaPropuestas.filter((p) => p.estado === "PENDIENTE").length})</h2>
          <div className="tabla-contenedor" style={{ marginBottom: 18 }}>
            <table>
              <thead>
                <tr>
                  <th>Tipo</th>
                  <th>Justificación</th>
                  <th>Expira</th>
                  <th>Estado</th>
                  {puedeEditar && <th>Acción</th>}
                </tr>
              </thead>
              <tbody>
                {listaPropuestas.map((p) => (
                  <tr key={p.id_ia_accion_propuesta}>
                    <td>{p.tipo_accion}</td>
                    <td style={{ maxWidth: 320, whiteSpace: "normal" }}>{p.justificacion}</td>
                    <td>{fechaHora(p.expira_at)}</td>
                    <td>
                      <span
                        className={
                          p.estado === "APROBADA"
                            ? "insignia"
                            : p.estado === "RECHAZADA" || p.estado === "EXPIRADA"
                              ? "insignia neutra"
                              : "insignia aviso"
                        }
                      >
                        {p.estado}
                      </span>
                    </td>
                    {puedeEditar && (
                      <td>
                        {p.estado === "PENDIENTE" ? (
                          <div className="form-inline">
                            <form action={aprobarAccionIA} style={{ display: "inline" }}>
                              <input type="hidden" name="id" value={id} />
                              <input type="hidden" name="id_ia_accion_propuesta" value={p.id_ia_accion_propuesta} />
                              <input type="hidden" name="aprobar" value="true" />
                              <button type="submit">Aprobar</button>
                            </form>
                            <form action={aprobarAccionIA} style={{ display: "inline" }}>
                              <input type="hidden" name="id" value={id} />
                              <input type="hidden" name="id_ia_accion_propuesta" value={p.id_ia_accion_propuesta} />
                              <input type="hidden" name="aprobar" value="false" />
                              <button type="submit">Rechazar</button>
                            </form>
                          </div>
                        ) : (
                          "—"
                        )}
                      </td>
                    )}
                  </tr>
                ))}
                {listaPropuestas.length === 0 && (
                  <tr>
                    <td colSpan={puedeEditar ? 5 : 4} style={{ color: "var(--texto-suave)" }}>
                      Sin propuestas de IA todavía.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          <h2>Recomendaciones ({listaRecomendaciones.length})</h2>
          <div className="tabla-contenedor">
            <table>
              <thead>
                <tr>
                  <th>Fecha</th>
                  <th>Texto</th>
                </tr>
              </thead>
              <tbody>
                {listaRecomendaciones.map((r) => (
                  <tr key={r.id_ia_recomendacion}>
                    <td>{fechaHora(r.created_at)}</td>
                    <td style={{ maxWidth: 480, whiteSpace: "normal" }}>{r.texto}</td>
                  </tr>
                ))}
                {listaRecomendaciones.length === 0 && (
                  <tr>
                    <td colSpan={2} style={{ color: "var(--texto-suave)" }}>
                      El agente todavía no ha registrado ninguna recomendación para este cliente.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
