import { Document, Page, Text, View, StyleSheet } from "@react-pdf/renderer";

const styles = StyleSheet.create({
  page: { padding: 32, fontSize: 11, fontFamily: "Helvetica" },
  titulo: { fontSize: 18, marginBottom: 4 },
  subtitulo: { fontSize: 10, color: "#555", marginBottom: 16 },
  filaEncabezado: { flexDirection: "row", borderBottom: 1, paddingBottom: 4, marginBottom: 4, fontWeight: 700 },
  fila: { flexDirection: "row", paddingVertical: 3, borderBottom: 0.5, borderColor: "#ddd" },
  colDescripcion: { flex: 3 },
  colPrecio: { flex: 1, textAlign: "right" },
  total: { marginTop: 12, fontSize: 13, textAlign: "right" },
});

const cop = (v: number) => "$" + Number(v).toLocaleString("es-CO", { maximumFractionDigits: 0 });

export type ComponentePdf = { descripcion: string; precio_resultante: number };

export function DocumentoCotizacion({
  numero,
  fecha,
  total,
  componentes,
}: {
  numero: number;
  fecha: string;
  total: number;
  componentes: ComponentePdf[];
}) {
  return (
    <Document>
      <Page size="A4" style={styles.page}>
        <Text style={styles.titulo}>Cotización #{numero}</Text>
        <Text style={styles.subtitulo}>Estampados Promocionales · {fecha}</Text>

        <View style={styles.filaEncabezado}>
          <Text style={styles.colDescripcion}>Concepto</Text>
          <Text style={styles.colPrecio}>Precio</Text>
        </View>
        {componentes.map((c, i) => (
          <View style={styles.fila} key={i}>
            <Text style={styles.colDescripcion}>{c.descripcion}</Text>
            <Text style={styles.colPrecio}>{cop(c.precio_resultante)}</Text>
          </View>
        ))}

        <Text style={styles.total}>Total: {cop(total)}</Text>
      </Page>
    </Document>
  );
}
