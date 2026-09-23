import { Document, Page, Text, View, StyleSheet } from "@react-pdf/renderer";

/**
 * PDF de cotizacion PARA EL CLIENTE.
 *
 * Regla dura de este documento: NO muestra costo de proveedor, margen,
 * ganancia, retenciones internas, SKU del proveedor ni nombre del proveedor.
 * El backend ya enmascara esos campos para roles no ADMIN
 * (fn_consola_items_cotizacion), pero un ADMIN si los recibe: por eso este
 * componente no acepta ninguna de esas propiedades, y la ruta que lo arma
 * tampoco se las pasa. Si mañana alguien quiere un PDF interno, se agrega un
 * documento aparte o un flag explicito; no se filtra por descuido.
 *
 * El emisor es texto fijo: el proyecto todavia no tiene tabla de datos
 * propios de la empresa (NIT, direccion, telefono). Queda como pendiente
 * declarado, no se inventan campos.
 */
const styles = StyleSheet.create({
  page: { padding: 34, fontSize: 10, fontFamily: "Helvetica", color: "#111" },

  encabezado: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "flex-start",
    borderBottom: 1.5,
    borderColor: "#111",
    paddingBottom: 10,
    marginBottom: 14,
  },
  emisorNombre: { fontSize: 15, fontFamily: "Helvetica-Bold" },
  emisorNota: { fontSize: 9, color: "#555", marginTop: 3 },
  tituloBloque: { alignItems: "flex-end" },
  titulo: { fontSize: 20, fontFamily: "Helvetica-Bold", letterSpacing: 1 },
  numero: { fontSize: 12, marginTop: 2 },
  fecha: { fontSize: 9, color: "#555", marginTop: 2 },

  seccion: { fontSize: 10, fontFamily: "Helvetica-Bold", marginBottom: 5 },
  bloqueCliente: {
    backgroundColor: "#f4f4f5",
    padding: 10,
    borderRadius: 3,
    marginBottom: 16,
  },
  filaDato: { flexDirection: "row", marginBottom: 2 },
  etiqueta: { width: 78, color: "#555", fontSize: 9 },
  valor: { flex: 1, fontSize: 9 },

  filaEncabezado: {
    flexDirection: "row",
    backgroundColor: "#111",
    color: "#fff",
    paddingVertical: 5,
    paddingHorizontal: 4,
  },
  fila: {
    flexDirection: "row",
    paddingVertical: 5,
    paddingHorizontal: 4,
    borderBottom: 0.5,
    borderColor: "#ddd",
  },
  filaAlterna: { backgroundColor: "#fafafa" },
  colItem: { width: 22 },
  colDescripcion: { flex: 3.1 },
  colPresentacion: { flex: 1.5 },
  colCantidad: { flex: 0.9, textAlign: "right" },
  colUnidades: { flex: 0.9, textAlign: "right" },
  colUnitario: { flex: 1.3, textAlign: "right" },
  colTotal: { flex: 1.4, textAlign: "right" },
  cabeceraTexto: { fontSize: 8.5, fontFamily: "Helvetica-Bold" },
  celda: { fontSize: 9 },
  celdaNota: { fontSize: 8, color: "#666", marginTop: 1 },

  resumen: { marginTop: 14, alignItems: "flex-end" },
  filaResumen: { flexDirection: "row", width: 240, paddingVertical: 3 },
  resumenEtiqueta: { flex: 1, textAlign: "right", paddingRight: 12, fontSize: 10 },
  resumenValor: { width: 100, textAlign: "right", fontSize: 10 },
  filaTotal: {
    flexDirection: "row",
    width: 240,
    paddingVertical: 6,
    borderTop: 1.2,
    borderColor: "#111",
    marginTop: 3,
  },
  totalEtiqueta: {
    flex: 1,
    textAlign: "right",
    paddingRight: 12,
    fontSize: 12,
    fontFamily: "Helvetica-Bold",
  },
  totalValor: { width: 100, textAlign: "right", fontSize: 12, fontFamily: "Helvetica-Bold" },

  notas: { marginTop: 18, fontSize: 9, color: "#333" },
  pie: {
    position: "absolute",
    bottom: 26,
    left: 34,
    right: 34,
    borderTop: 0.5,
    borderColor: "#ccc",
    paddingTop: 6,
    fontSize: 8,
    color: "#666",
    textAlign: "center",
  },
});

const cop = (v: number) =>
  "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

const miles = (v: number) => Number(v).toLocaleString("es-CO");

/** Una linea del PDF. Sin costo, sin margen, sin proveedor: a proposito. */
export type LineaPdf = {
  linea: number;
  nombre: string;
  detalle: string | null;
  presentacion: string;
  cantidad: number;
  unidades: number;
  esPack: boolean;
  precioUnitario: number;
  totalLinea: number;
};

export type ClientePdf = {
  nombre: string;
  nit: string | null;
  ciudad: string | null;
  contacto: string | null;
  correo: string | null;
  telefono: string | null;
} | null;

export function DocumentoCotizacion({
  numero,
  fecha,
  total,
  lineas,
  cliente,
  notas,
}: {
  numero: number;
  fecha: string;
  total: number;
  lineas: LineaPdf[];
  cliente: ClientePdf;
  notas?: string | null;
}) {
  const subtotal = lineas.reduce((acc, l) => acc + l.totalLinea, 0);

  return (
    <Document>
      <Page size="A4" style={styles.page}>
        <View style={styles.encabezado}>
          <View>
            <Text style={styles.emisorNombre}>Estampados Promocionales</Text>
            <Text style={styles.emisorNota}>Productos promocionales y personalizacion</Text>
          </View>
          <View style={styles.tituloBloque}>
            <Text style={styles.titulo}>COTIZACION</Text>
            <Text style={styles.numero}>No. {numero}</Text>
            <Text style={styles.fecha}>{fecha}</Text>
          </View>
        </View>

        <Text style={styles.seccion}>Cliente</Text>
        <View style={styles.bloqueCliente}>
          {cliente ? (
            <>
              <View style={styles.filaDato}>
                <Text style={styles.etiqueta}>Razon social</Text>
                <Text style={styles.valor}>{cliente.nombre}</Text>
              </View>
              {cliente.nit ? (
                <View style={styles.filaDato}>
                  <Text style={styles.etiqueta}>NIT</Text>
                  <Text style={styles.valor}>{cliente.nit}</Text>
                </View>
              ) : null}
              {cliente.ciudad ? (
                <View style={styles.filaDato}>
                  <Text style={styles.etiqueta}>Ciudad</Text>
                  <Text style={styles.valor}>{cliente.ciudad}</Text>
                </View>
              ) : null}
              {cliente.contacto ? (
                <View style={styles.filaDato}>
                  <Text style={styles.etiqueta}>Contacto</Text>
                  <Text style={styles.valor}>{cliente.contacto}</Text>
                </View>
              ) : null}
              {cliente.correo ? (
                <View style={styles.filaDato}>
                  <Text style={styles.etiqueta}>Correo</Text>
                  <Text style={styles.valor}>{cliente.correo}</Text>
                </View>
              ) : null}
              {cliente.telefono ? (
                <View style={styles.filaDato}>
                  <Text style={styles.etiqueta}>Telefono</Text>
                  <Text style={styles.valor}>{cliente.telefono}</Text>
                </View>
              ) : null}
            </>
          ) : (
            <Text style={styles.valor}>Cliente no especificado</Text>
          )}
        </View>

        <Text style={styles.seccion}>Productos cotizados</Text>
        <View style={styles.filaEncabezado}>
          <Text style={[styles.colItem, styles.cabeceraTexto]}>#</Text>
          <Text style={[styles.colDescripcion, styles.cabeceraTexto]}>Producto</Text>
          <Text style={[styles.colPresentacion, styles.cabeceraTexto]}>Presentacion</Text>
          <Text style={[styles.colCantidad, styles.cabeceraTexto]}>Cant.</Text>
          <Text style={[styles.colUnidades, styles.cabeceraTexto]}>Unidades</Text>
          <Text style={[styles.colUnitario, styles.cabeceraTexto]}>Precio und</Text>
          <Text style={[styles.colTotal, styles.cabeceraTexto]}>Total</Text>
        </View>

        {lineas.map((l, i) => (
          <View
            style={i % 2 === 1 ? [styles.fila, styles.filaAlterna] : styles.fila}
            key={`ln-${l.linea}`}
            wrap={false}
          >
            <Text style={[styles.colItem, styles.celda]}>{l.linea}</Text>
            <View style={styles.colDescripcion}>
              <Text style={styles.celda}>{l.nombre}</Text>
              {l.detalle ? <Text style={styles.celdaNota}>{l.detalle}</Text> : null}
            </View>
            <Text style={[styles.colPresentacion, styles.celda]}>{l.presentacion}</Text>
            <Text style={[styles.colCantidad, styles.celda]}>{miles(l.cantidad)}</Text>
            <Text style={[styles.colUnidades, styles.celda]}>{miles(l.unidades)}</Text>
            <Text style={[styles.colUnitario, styles.celda]}>{cop(l.precioUnitario)}</Text>
            <Text style={[styles.colTotal, styles.celda]}>{cop(l.totalLinea)}</Text>
          </View>
        ))}

        <View style={styles.resumen}>
          <View style={styles.filaResumen}>
            <Text style={styles.resumenEtiqueta}>Subtotal</Text>
            <Text style={styles.resumenValor}>{cop(subtotal)}</Text>
          </View>
          <View style={styles.filaTotal}>
            <Text style={styles.totalEtiqueta}>Total</Text>
            <Text style={styles.totalValor}>{cop(total)}</Text>
          </View>
        </View>

        {notas ? <Text style={styles.notas}>{notas}</Text> : null}

        <Text style={styles.notas}>
          Los valores estan expresados en pesos colombianos (COP) e incluyen la
          personalizacion descrita en cada linea. Cualquier cambio de cantidades o de
          arte puede modificar el valor cotizado.
        </Text>

        <Text style={styles.pie} fixed>
          Cotizacion No. {numero} · {fecha} · Gracias por su interes.
        </Text>
      </Page>
    </Document>
  );
}
