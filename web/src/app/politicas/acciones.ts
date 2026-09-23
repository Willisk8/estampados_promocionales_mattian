"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";

export async function guardarPlantilla(form: FormData) {
  const supabase = await crearClienteServidor();
  let tramos: { desde: number; margen: number }[] = [];
  let fallo = "";
  try {
    tramos = String(form.get("tramos") ?? "").split(/\r?\n/).filter(l => l.trim()).map(linea => {
      const partes = linea.split(";").map(s => s.trim());
      if (partes.length !== 2 || partes.some(p => !/^\d+(?:[.,]\d+)?$/.test(p))) throw new Error("Cada fila debe contener cantidad; margen.");
      return { desde: Number(partes[0].replace(",", ".")), margen: Number(partes[1].replace(",", ".")) };
    });
  } catch { fallo = "Revisa los tramos: escribe cantidad; margen en cada fila."; }
  const margenTexto = String(form.get("margen_base") ?? "").trim();
  if (!/^\d+(?:[.,]\d+)?$/.test(margenTexto)) fallo = "Indica un margen base numerico.";
  if (fallo) redirect(`/politicas?error=${encodeURIComponent(fallo)}`);
  const { error } = await supabase.rpc("fn_consola_guardar_plantilla_margen", {
    p_codigo: String(form.get("codigo") ?? ""),
    p_margen_base: Number(margenTexto.replace(",", ".")), p_tramos: tramos,
    p_id: String(form.get("id") ?? "") || null,
  });
  if (error) redirect(`/politicas?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/politicas");
  redirect("/politicas?ok=Borrador%20guardado");
}

export async function publicarPlantilla(form: FormData) {
  const supabase = await crearClienteServidor();
  const { error } = await supabase.rpc("fn_consola_publicar_plantilla_margen", { p_id: String(form.get("id") ?? "") });
  if (error) redirect(`/politicas?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/politicas");
  redirect("/politicas?ok=Version%20publicada");
}
