import { createBrowserClient } from "@supabase/ssr";

/**
 * Cliente de Supabase para componentes de navegador ("use client").
 *
 * Usa exactamente las mismas credenciales publicas que el cliente de servidor:
 * URL publicable y clave anonima. La sesion viaja en las cookies que ya escribio
 * el middleware, asi que las RPC llamadas desde aqui llegan a Postgres con el
 * mismo rol del usuario y pasan por RLS igual que las de servidor. Nunca debe
 * existir una variante privilegiada de este archivo.
 */
export function crearClienteNavegador() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  );
}
