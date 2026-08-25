import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,

  // Un `next build` normal sobrescribe el .next que `next dev` esta usando, y
  // el servidor de desarrollo se queda sirviendo rutas de CSS que ya no
  // existen: la pagina carga los datos pero sin ningun estilo. Con esto,
  // `npm run verificar` compila en .next-verificacion y no toca el de dev.
  distDir: process.env.NEXT_DIST_DIR || ".next",

  // La consola solo corre en localhost contra Supabase STAGING (Etapa B).
  // No se define ninguna variable de servidor con credenciales privilegiadas.
  env: {},
};

export default nextConfig;
