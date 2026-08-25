import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // La consola solo corre en localhost contra Supabase STAGING (Etapa B).
  // No se define ninguna variable de servidor con credenciales privilegiadas.
  env: {},
};

export default nextConfig;
