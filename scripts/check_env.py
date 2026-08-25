"""
Verifica que todas las variables de entorno requeridas están configuradas.
Uso: python scripts/check_env.py

Carga .env.staging igual que scripts/import/_shared.py. Sin esa carga la
verificación fallaba siempre en Windows, donde el archivo no se exporta al
entorno del proceso.
"""
import os
import sys
from pathlib import Path

# (variable, pista, longitud mínima). La longitud mínima es por variable:
# ENVIRONMENT vale 'staging' (7 caracteres) y se valida por pertenencia, no
# por tamaño. Un mínimo global de 10 la marcaba como inválida siempre.
REQUIRED_VARS = [
    ("SUPABASE_URL", "Supabase Dashboard → Settings → API → Project URL", 10),
    ("SUPABASE_ANON_KEY", "Supabase Dashboard → Settings → API → anon / publishable", 10),
    ("SUPABASE_SERVICE_ROLE_KEY", "Supabase Dashboard → Settings → API → service_role", 10),
    ("DATABASE_URL", "Supabase Dashboard → Settings → Database → Connection string", 10),
    ("HMAC_SUPPRESSION_SECRET", "Generar: python -c \"import secrets; print(secrets.token_hex(32))\"", 32),
    ("ENVIRONMENT", "Debe ser 'staging' o 'production'", 0),
]

WARN_IF_PROD_VALUE = [
    "SUPABASE_URL",
    "SUPABASE_SERVICE_ROLE_KEY",
    "DATABASE_URL",
]

PRODUCTION_MARKERS = ("prod", "production", "produccion", "producción")

# Prefijos de las claves nuevas de Supabase. Confundirlas es un error de
# seguridad en las dos direcciones: una clave publicable no puede escribir
# con RLS deny-all, y una clave secreta jamás debe llegar al navegador.
PREFIJO_PUBLICABLE = ("sb_publishable_", "sb_pub")
PREFIJO_SECRETA = ("sb_secret_",)


def load_env_file():
    """Carga .env.staging si existe, igual que scripts/import/_shared.py."""
    env_file = Path(__file__).resolve().parent.parent / ".env.staging"
    if env_file.exists():
        from dotenv import load_dotenv
        load_dotenv(env_file)


def check_key_shapes(env, errors):
    """La clave de service_role y la publicable no son intercambiables."""
    service = env.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if service and service.startswith(PREFIJO_PUBLICABLE):
        errors.append(
            "INVALIDO: SUPABASE_SERVICE_ROLE_KEY contiene una clave publicable "
            f"('{service[:9]}...').\n"
            "  -> Es la clave equivocada: no puede escribir con RLS deny-all.\n"
            "  -> Copia la clave service_role (sb_secret_... o JWT) y mueve esta a SUPABASE_ANON_KEY."
        )

    anon = env.get("SUPABASE_ANON_KEY", "")
    if anon and anon.startswith(PREFIJO_SECRETA):
        errors.append(
            "INVALIDO: SUPABASE_ANON_KEY contiene una clave secreta.\n"
            "  -> La clave secreta nunca debe exponerse al navegador."
        )


def check_env(env=None):
    """Devuelve (errores, advertencias). Recibe el entorno para poder testearlo."""
    if env is None:
        env = os.environ

    errors = []
    warnings = []

    for var, hint, min_len in REQUIRED_VARS:
        value = env.get(var)
        if not value:
            errors.append(f"FALTA: {var}\n  -> {hint}")
        elif len(value) < min_len:
            errors.append(f"INVALIDO (muy corto): {var}")

    check_key_shapes(env, errors)

    environment = env.get("ENVIRONMENT", "")
    if environment not in ("staging", "production"):
        warnings.append(f"ENVIRONMENT='{environment}' no es 'staging' ni 'production'")

    if environment == "staging":
        for var in WARN_IF_PROD_VALUE:
            val = env.get(var, "")
            if any(marker in val.lower() for marker in PRODUCTION_MARKERS):
                warnings.append(f"POSIBLE CREDENCIAL DE PRODUCCION en STAGING: {var}")

    return errors, warnings


def main():
    load_env_file()
    errors, warnings = check_env()

    if errors:
        print("Variables faltantes o invalidas:")
        for e in errors:
            print(f"  {e}")

    if warnings:
        print("Advertencias:")
        for w in warnings:
            print(f"  {w}")

    if not errors and not warnings:
        print("Todas las variables de entorno estan configuradas correctamente.")
        print(f"   Entorno: {os.environ.get('ENVIRONMENT', '')}")
        return 0

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
