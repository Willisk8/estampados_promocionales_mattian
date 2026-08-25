import { crearClienteServidor, obtenerSesionConsola } from "@/lib/supabase/servidor";
import { SinAcceso } from "@/componentes/sin-acceso";

export const dynamic = "force-dynamic";

type Resumen = {
  productos_propios_activos: number;
  productos_propios_borrador: number;
  precios_comerciales_vigentes: number;
};

export default async function PaginaCotizador() {
  const sesion = await obtenerSesionConsola();
  if (!sesion) return <SinAcceso />;

  const supabase = await crearClienteServidor();
  const { data } = await supabase.rpc("fn_consola_resumen");
  const r = (data?.[0] ?? null) as Resumen | null;

  return (
    <>
      <h1>Cotizador</h1>
      <p className="subtitulo">
        Presente desde el primer dia para que la separacion entre cotizar y
        simular quede clara, pero no operativo todavia.
      </p>

      <div className="aviso-caja">
        <strong>No operativo.</strong> El catalogo propio si existe:{" "}
        {r?.productos_propios_activos ?? "?"} productos activos y{" "}
        {r?.precios_comerciales_vigentes ?? "?"} precios comerciales vigentes
        {r?.productos_propios_borrador
          ? `, mas ${r.productos_propios_borrador} en borrador por costos sin confirmar`
          : ""}
        . Lo que falta no son datos, sino <strong>persistencia auditable</strong>:
        no existen las tablas de cotizacion, asi que una cotizacion emitida hoy no
        podria reproducirse despues con los snapshots y margenes que la generaron.
        Emitirla sin eso es justo lo que la Etapa E debe impedir.
      </div>

      <h2>Cotizacion comercial</h2>
      <div className="tarjeta">
        <p style={{ marginTop: 0 }}>
          Consulta precios ya aprobados mediante <code>resolve_price()</code>. No
          recalcula nada: devuelve la escala vigente para el producto, la variante
          y la cantidad.
        </p>
        <div className="filtros">
          <select disabled>
            <option>Producto aprobado…</option>
          </select>
          <input type="number" placeholder="Cantidad" disabled />
          <button type="button" disabled>
            Cotizar
          </button>
        </div>
        <p style={{ fontSize: 13, color: "var(--texto-suave)", marginBottom: 0 }}>
          <code>resolve_price()</code> no tiene permiso de ejecucion para la
          consola: es una funcion de servidor y seguira siendolo hasta la Etapa E.
        </p>
      </div>

      <h2>Simulador administrativo</h2>
      <div className="tarjeta">
        <p style={{ marginTop: 0 }}>
          Calcula desde insumos: costo de proveedor, marcacion, empaque, mano de
          obra, gastos, retenciones y margen. Sirve para construir escalas nuevas,
          no para cotizarle a un cliente.
        </p>
        <div className="filtros">
          <input placeholder="Costo proveedor" disabled />
          <input placeholder="Tecnica" disabled />
          <input placeholder="Margen %" disabled />
          <button type="button" disabled>
            Simular
          </button>
        </div>
        <p style={{ fontSize: 13, color: "var(--texto-suave)", marginBottom: 0 }}>
          La logica vive hoy en <code>scripts/catalog/pricing_model.py</code> y se
          ejecuta desde consola, con entradas versionadas en JSON.
        </p>
      </div>

      <div className="aviso-caja neutro">
        Estas dos funciones estan separadas a proposito. Un precio aprobado no
        debe recalcularse libremente durante una cotizacion: si el calculo cambia,
        cambia la escala, y eso pasa por revision.
      </div>
    </>
  );
}
