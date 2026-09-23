"use client";

import { useRef, useState } from "react";

export type Ubicacion = { departamento: string; municipio: string | null };

/** El formulario GET conserva los otros filtros y reinicia la paginación. */
export function FiltrosUbicacion({ ubicaciones, departamento = "", ciudad = "" }: {
  ubicaciones: Ubicacion[]; departamento?: string; ciudad?: string;
}) {
  const [depto, setDepto] = useState(departamento);
  const ciudadRef = useRef<HTMLSelectElement>(null);
  const departamentos = [...new Set(ubicaciones.map(u => u.departamento))].sort((a, b) => a.localeCompare(b, "es"));
  const ciudades = [...new Set(ubicaciones.filter(u => !depto || u.departamento === depto).map(u => u.municipio).filter((m): m is string => !!m))].sort((a, b) => a.localeCompare(b, "es"));
  return <>
    <select name="depto" aria-label="Departamento" value={depto} onChange={e => {
      setDepto(e.target.value);
      // El municipio anterior nunca se envía junto al nuevo departamento.
      if (ciudadRef.current) ciudadRef.current.value = "";
      e.currentTarget.form?.requestSubmit();
    }}>
      <option value="">Todo departamento</option>
      {departamentos.map(d => <option key={d} value={d}>{d}</option>)}
    </select>
    <select ref={ciudadRef} name="ciudad" aria-label="Ciudad o municipio" defaultValue={ciudades.includes(ciudad) ? ciudad : ""} onChange={e => e.currentTarget.form?.requestSubmit()}>
      <option value="">Toda ciudad</option>
      {ciudades.map(c => <option key={c} value={c}>{c}</option>)}
    </select>
  </>;
}
