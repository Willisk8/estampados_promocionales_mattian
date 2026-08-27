const RUTAS_INTERNAS_PERMITIDAS = [
  "/",
  "/clientes",
  "/cotizador",
  "/importaciones",
  "/organizaciones",
  "/productos-propios",
  "/productos-proveedor",
  "/proveedores",
  "/tecnicas",
] as const;

function tienePrefijoPermitido(pathname: string): boolean {
  return RUTAS_INTERNAS_PERMITIDAS.some((ruta) => {
    if (ruta === "/") return pathname === "/";
    return pathname === ruta || pathname.startsWith(`${ruta}/`);
  });
}

export function rutaInternaSegura(valor: unknown, fallback = "/"): string {
  if (typeof valor !== "string") return fallback;

  const ruta = valor.trim();
  if (!ruta || !ruta.startsWith("/") || ruta.startsWith("//") || ruta.includes("\\")) {
    return fallback;
  }

  let url: URL;
  try {
    url = new URL(ruta, "https://consola.estampados.local");
  } catch {
    return fallback;
  }

  if (url.origin !== "https://consola.estampados.local") return fallback;
  if (!tienePrefijoPermitido(url.pathname)) return fallback;

  return `${url.pathname}${url.search}${url.hash}`;
}

export function agregarParametroARutaInterna(
  ruta: string,
  nombre: string,
  valor: string,
  fallback = "/",
): string {
  const segura = rutaInternaSegura(ruta, fallback);
  const url = new URL(segura, "https://consola.estampados.local");
  url.searchParams.set(nombre, valor);
  return `${url.pathname}${url.search}${url.hash}`;
}
