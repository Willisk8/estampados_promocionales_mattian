import { redirect } from "next/navigation";
import { crearClienteServidor } from "@/lib/supabase/servidor";
import { rutaInternaSegura } from "@/lib/rutas-internas";

export const dynamic = "force-dynamic";

export default async function PaginaLogin({
  searchParams,
}: {
  searchParams: Promise<{ error?: string; siguiente?: string }>;
}) {
  const params = await searchParams;

  async function iniciarSesion(formData: FormData) {
    "use server";

    const email = String(formData.get("email") ?? "").trim();
    const password = String(formData.get("password") ?? "");
    const siguiente = rutaInternaSegura(formData.get("siguiente"), "/");

    const supabase = await crearClienteServidor();
    const { error } = await supabase.auth.signInWithPassword({ email, password });

    if (error) {
      // No se distingue "usuario inexistente" de "clave incorrecta": decirlo
      // permitiria enumerar cuentas validas.
      redirect("/login?error=credenciales");
    }

    redirect(siguiente);
  }

  return (
    <div className="centro">
      <h1>Consola Estampados</h1>
      <p className="subtitulo">Acceso interno · STAGING</p>

      {params.error === "credenciales" && (
        <p className="error-texto">
          Correo o contrasena incorrectos.
        </p>
      )}

      <form action={iniciarSesion}>
        <input type="hidden" name="siguiente" value={rutaInternaSegura(params.siguiente, "/")} />
        <input
          type="email"
          name="email"
          placeholder="Correo"
          autoComplete="username"
          required
        />
        <input
          type="password"
          name="password"
          placeholder="Contrasena"
          autoComplete="current-password"
          required
        />
        <button type="submit">Entrar</button>
      </form>
    </div>
  );
}
