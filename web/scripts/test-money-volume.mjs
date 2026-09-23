import assert from 'node:assert/strict';
import { leerImporte, importeEditable, numeroOpcional } from '../src/lib/dinero.ts';
import { margenPorCantidad, precioConMargen, precioComercial, validarEscalas, cantidadesComparacion } from '../src/lib/cotizacion-volumen.ts';

for (const [entrada, valor] of [['18.000,50', 18000.5], ['0,125', .125], ['100,01',100.01], ['',0]]) {
  assert.equal(leerImporte(entrada),valor);
  assert.equal(leerImporte(importeEditable(valor)),valor, 'editar y salir debe conservar centavos');
}
assert.equal(numeroOpcional(null),null);
assert.equal(numeroOpcional(''),null);
assert.equal(numeroOpcional(0),0);
const escalas = [{desde:12,margen:35},{desde:30,margen:30},{desde:50,margen:25}];
for (const [cantidad,margen] of [[1,40],[11,40],[12,35],[29,35],[30,30],[49,30],[50,25]]) {
  assert.equal(margenPorCantidad(cantidad,40,escalas),margen);
}
assert.equal(validarEscalas(escalas,40),null);
const flexibles = [{desde:1200,margen:15},{desde:100,margen:28},{desde:1100,margen:18},{desde:1000,margen:20}];
for (const [n,m] of [[1,40],[100,28],[110,28],[1000,20],[1100,18],[1150,18],[1200,15],[10000,15]]) {
  assert.equal(margenPorCantidad(n,40,flexibles),m);
}
assert.equal(validarEscalas(flexibles,40),null);
assert.deepEqual(cantidadesComparacion(1150,flexibles),[1,100,1000,1100,1150,1200]);
for (const desde of [0,-1,1.5,NaN,Infinity]) assert.ok(validarEscalas([{desde,margen:20}],40));
assert.ok(validarEscalas([{desde:100,margen:20},{desde:100,margen:10}],40));
assert.equal(margenPorCantidad(1150,40,[]),40);
assert.ok(validarEscalas([{desde:12,margen:50}],40));
assert.ok(Number.isNaN(precioConMargen(1000,100)));
assert.equal(precioConMargen(1000,40,100), precioConMargen(1000,40,0));
assert.equal(precioComercial(18000,35,12), 27696);
assert.equal(precioComercial(70000,30,1), 100000);
assert.equal(precioComercial(12,0,12), 12);
for (const n of [1,3,12,37,100,1150,1200]) assert.equal(precioComercial(1000*n+6000,35,n) % n, 0);
let anterior = Infinity;
for (const n of [1,12,30,50]) {
  const costo = 1000 * n + 6000;
  const margen = margenPorCantidad(n,40,escalas);
  const precio = precioConMargen(costo,margen);
  assert.ok(precio/n < anterior);
  assert.ok(Math.abs((precio-costo)/precio*100-margen) < 1e-9);
  anterior = precio/n;
}
assert.ok(Math.abs(precioConMargen(6000,40)-10000) < 1e-9, '40% margen no es sumar 40% al costo');
console.log('OK: importes, limites de escalas, reparto fijo y margen sobre venta');
