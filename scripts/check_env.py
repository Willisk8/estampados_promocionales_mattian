"""
Verifica que todas las variables de entorno requeridas están configuradas.
Uso: python scripts/check_env.py
"""
import os
import sys

REQUIRED_VARS = [
    ("SUPABASE_URL", "Supabase Dashboard → Settings → API → Project URL"),
    ("SUPABASE_SERVICE_ROLE_KEY", "Supabase Dashboard → Settings → API → service_role"),
    ("DATABASE_URL", "Supabase Dashboard → Settings → Database → Connection string"),
    ("HMAC_SUPPRESSION_SECRET", "Generar: python -c \"import secrets; print(secrets.token_hex(32))\""),
    ("ENVIRONMENT", "Debe ser 'staging' o 'production'"),
]

WARN_IF_PROD_VALUE = [
    "SUPABASE_URL",
    "SUPABASE_SERVICE_ROLE_KEY",
    "DATABASE_URL",
]

def check_env():
    errors = []
    warnings = []

    for var, hint in REQUIRED_VARS:
        value = os.environ.get(var)
        if not value:
            errors.append(f"FALTA: {var}\n  -> {hint}")
        elif len(value) < 10:
            errors.append(f"INVALIDO (muy corto): {var}")

    env = os.environ.get("ENVIRONMENT", "")
    if env not in ("staging", "production"):
        warnings.append(f"ENVIRONMENT='{env}' no es 'staging' ni 'production'")

    if env == "staging":
        for var in WARN_IF_PROD_VALUE:
            val = os.environ.get(var, "")
            if "prod" in val.lower():
                warnings.append(f"POSIBLE CREDENCIAL DE PRODUCCION en STAGING: {var}")

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
        print(f"   Entorno: {env}")
        return 0

    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(check_env())
