import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

/**
 * Cliente de Supabase para componentes y acciones de servidor.
 *
 * Usa la sesion del usuario, no una clave privilegiada. Todo lo que devuelva
 * pasa por RLS: si una consulta no trae filas, es porque la politica lo decidio,
 * no porque falte una clave. Esa es la garantia de la Etapa B.
 */
export async function crearClienteServidor() {
  const almacenCookies = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return almacenCookies.getAll();
        },
        setAll(cookiesAEscribir) {
          try {
            cookiesAEscribir.forEach(({ name, value, options }) =>
              almacenCookies.set(name, value, options),
            );
          } catch {
            // Los Server Components no pueden escribir cookies. El middleware
            // ya refresco la sesion, asi que se puede ignorar sin perderla.
          }
        },
      },
    },
  );
}

export type RolConsola = "ADMIN" | "COMERCIAL" | "LECTURA";

export type SesionConsola = {
  email: string;
  rol: RolConsola;
};

/**
 * Devuelve la sesion de consola, o null si el usuario no tiene perfil activo.
 *
 * Un usuario autenticado sin fila en perfil_usuario no ve nada: es el diseno,
 * no un fallo. La UI debe distinguir ese caso de una tabla vacia.
 */
export async function obtenerSesionConsola(): Promise<SesionConsola | null> {
  const supabase = await crearClienteServidor();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data } = await supabase
    .from("perfil_usuario")
    .select("email, rol, activo")
    .eq("user_id", user.id)
    .maybeSingle();

  if (!data || !data.activo) return null;
  return { email: data.email, rol: data.rol as RolConsola };
}
