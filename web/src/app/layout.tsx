import type { Metadata } from "next";
import "./globals.css";
import { obtenerSesionConsola } from "@/lib/supabase/servidor";
import { NavLateral } from "@/componentes/nav-lateral";

export const metadata: Metadata = {
  title: "Consola Estampados",
  description: "Consola interna de operacion controlada, STAGING",
};

// La consola siempre refleja el estado actual de la base; nada se cachea.
export const dynamic = "force-dynamic";

export default async function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const sesion = await obtenerSesionConsola();

  return (
    <html lang="es">
      <body>
        {sesion ? (
          <div className="disposicion">
            <NavLateral rol={sesion.rol} email={sesion.email} />
            <main className="contenido">{children}</main>
          </div>
        ) : (
          <main>{children}</main>
        )}
      </body>
    </html>
  );
}
