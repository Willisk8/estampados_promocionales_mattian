"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

const ENLACES = [
  { href: "/", texto: "Resumen" },
  { href: "/organizaciones", texto: "Organizaciones" },
  { href: "/proveedores", texto: "Proveedores" },
  { href: "/productos-propios", texto: "Productos propios" },
  { href: "/tecnicas", texto: "Tecnicas de marcacion" },
  { href: "/importaciones", texto: "Importaciones" },
  { href: "/cotizador", texto: "Cotizador" },
];

export function NavLateral({ rol, email }: { rol: string; email: string }) {
  const ruta = usePathname();

  return (
    <nav className="barra-lateral">
      <div className="marca">
        Consola Estampados
        <span>STAGING · solo lectura</span>
      </div>

      {ENLACES.map(({ href, texto }) => {
        const activo = href === "/" ? ruta === "/" : ruta.startsWith(href);
        return (
          <Link
            key={href}
            href={href}
            className="nav-enlace"
            aria-current={activo ? "page" : undefined}
          >
            {texto}
          </Link>
        );
      })}

      <div className="pie-lateral">
        {email}
        <br />
        rol {rol}
        <br />
        <form action="/auth/salir" method="post">
          <button
            type="submit"
            style={{
              background: "none",
              border: "none",
              padding: "6px 0 0",
              color: "var(--acento)",
              cursor: "pointer",
              fontSize: 12,
            }}
          >
            Cerrar sesion
          </button>
        </form>
      </div>
    </nav>
  );
}
