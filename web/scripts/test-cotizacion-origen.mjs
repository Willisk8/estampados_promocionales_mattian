import assert from 'node:assert/strict';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';

const result = await build({
  entryPoints: ['src/lib/cotizacion-origen.ts'],
  bundle: true,
  platform: 'node',
  format: 'esm',
  write: false,
  plugins: [{
    name: 'isolate-database',
    setup(api) {
      api.onResolve({ filter: /^@\/lib\/supabase\/servidor$/ }, () => ({ path: 'server', namespace: 'test' }));
      api.onLoad({ filter: /.*/, namespace: 'test' }, () => ({ contents: 'export const crearClienteServidor=()=>{throw Error("No DB in unit test")};' }));
      api.onResolve({ filter: /^@\// }, args => ({ path: fileURLToPath(new URL(`../src/${args.path.slice(2)}.ts`, import.meta.url)) }));
    },
  }],
});
const code = result.outputFiles[0].text;
const { lineaDesdeItem } = await import(`data:text/javascript;base64,${Buffer.from(code).toString('base64')}`);

const base = {
  cantidad: 12,
  id_producto_proveedor: 'producto',
  id_precio_proveedor_snapshot: 'precio',
  proveedor_snapshot: { id_proveedor: 'proveedor', nombre: 'Proveedor' },
  nombre_item_snapshot: 'Caja',
  costo_compra_unitario_snapshot: 1800,
  unidad_compra_snapshot: 'PACK',
  cantidad_pack_snapshot: 10,
  created_at: '2026-09-23T00:00:00Z',
};
const tecnica = {
  tipo: 'dtf', disenos: [{ name: 'Pecho', w: 10, h: 12, qty: 2 }],
  ancho_rollo: 58, precio_metro: 12000, reserva_pct: 10,
  costo_aplicacion_unitario: 0,
};
const generado = { descripcion: 'Marcacion dtf', costo_total: 4000, configuracion_tecnica: tecnica, calculo: { status: 'OK' } };
const item = {
  ...base,
  metadata_costeo: { motor_version: 'CLIENT_V2', cantidad_presentaciones: 2, configuracion_tecnica: tecnica,
    costos_adicionales: [{ descripcion: 'Preparacion', costo_total: 6000 }, generado] },
};
const linea = lineaDesdeItem(item);
assert.equal(linea.cantidad, '12', 'PACK conserva unidades entregadas, no presentaciones');
assert.equal(linea.tecnica, 'dtf');
assert.deepEqual(linea.disenos, [{ name: 'Pecho', w: 10, h: 12, qty: 2 }]);
assert.equal(linea.dtfWaste, '10');
assert.deepEqual(linea.otros, [{ name: 'Preparacion', val: '6000', modo: 'TOTAL' }],
  'el consumo DTF calculado no se duplica como costo fijo');

const invalida = lineaDesdeItem({ ...item, metadata_costeo: { ...item.metadata_costeo,
  configuracion_tecnica: { ...tecnica, disenos: [{ w: 0, h: 12, qty: 2 }] } } });
assert.equal(invalida.requiereRevisarTecnica, true, 'una geometria invalida requiere revision explicita');
assert.equal(invalida.otros.length, 1, 'el DTF calculado tampoco se hereda cuando la geometria es invalida');

const legacy = lineaDesdeItem({ ...base, metadata_costeo: { cantidad_presentaciones: 2,
  costos_adicionales: [{ descripcion: 'Marcacion manual', costo_total: 4000 }] } });
assert.equal(legacy.cantidad, '12');
assert.equal(legacy.otros.length, 1, 'el costo manual antiguo sigue visible');
console.log('OK: historico V2 restaura geometria sin duplicar costo DTF; historico legacy conserva costo manual');
