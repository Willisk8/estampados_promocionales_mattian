import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from check_env import check_env  # noqa: E402


def entorno_valido(**overrides):
    base = {
        "SUPABASE_URL": "https://psereyjwjpyakkmnabgm.supabase.co",
        "SUPABASE_ANON_KEY": "sb_publishable_" + "x" * 30,
        "SUPABASE_SERVICE_ROLE_KEY": "sb_secret_" + "y" * 30,
        "DATABASE_URL": "postgresql://postgres.proyecto:clave@db.example.com:5432/postgres",
        "HMAC_SUPPRESSION_SECRET": "a" * 64,
        "ENVIRONMENT": "staging",
    }
    base.update(overrides)
    return base


class CheckEnvTests(unittest.TestCase):
    def test_entorno_completo_no_reporta_nada(self):
        errors, warnings = check_env(entorno_valido())
        self.assertEqual(errors, [])
        self.assertEqual(warnings, [])

    def test_anon_key_es_obligatoria(self):
        env = entorno_valido()
        del env["SUPABASE_ANON_KEY"]
        errors, _ = check_env(env)
        self.assertTrue(
            any("SUPABASE_ANON_KEY" in e for e in errors),
            "la consola necesita la clave publicable y debe exigirse",
        )

    def test_clave_publicable_en_slot_de_service_role_es_error(self):
        """Es el error que tiene .env.staging hoy: sb_pub... en SERVICE_ROLE."""
        env = entorno_valido(SUPABASE_SERVICE_ROLE_KEY="sb_publishable_" + "z" * 30)
        errors, _ = check_env(env)
        self.assertTrue(
            any("SUPABASE_SERVICE_ROLE_KEY" in e and "publicable" in e for e in errors),
            "una clave publicable en el slot de service_role no puede escribir con RLS deny-all",
        )

    def test_prefijo_sb_pub_corto_tambien_se_detecta(self):
        env = entorno_valido(SUPABASE_SERVICE_ROLE_KEY="sb_pub" + "z" * 30)
        errors, _ = check_env(env)
        self.assertTrue(any("SUPABASE_SERVICE_ROLE_KEY" in e for e in errors))

    def test_clave_secreta_en_slot_anon_es_error(self):
        env = entorno_valido(SUPABASE_ANON_KEY="sb_secret_" + "z" * 30)
        errors, _ = check_env(env)
        self.assertTrue(
            any("SUPABASE_ANON_KEY" in e for e in errors),
            "una clave secreta nunca debe quedar en la variable que llega al navegador",
        )

    def test_variable_faltante_se_reporta(self):
        env = entorno_valido()
        del env["HMAC_SUPPRESSION_SECRET"]
        errors, _ = check_env(env)
        self.assertTrue(any("HMAC_SUPPRESSION_SECRET" in e for e in errors))

    def test_valor_demasiado_corto_es_invalido(self):
        env = entorno_valido(DATABASE_URL="corto")
        errors, _ = check_env(env)
        self.assertTrue(any("DATABASE_URL" in e for e in errors))

    def test_environment_desconocido_advierte(self):
        env = entorno_valido(ENVIRONMENT="dev")
        errors, warnings = check_env(env)
        self.assertEqual(errors, [])
        self.assertTrue(any("ENVIRONMENT" in w for w in warnings))

    def test_credencial_de_produccion_en_staging_advierte(self):
        env = entorno_valido(SUPABASE_URL="https://mi-proyecto-production.supabase.co")
        _, warnings = check_env(env)
        self.assertTrue(any("PRODUCCION" in w for w in warnings))

    def test_mensajes_de_error_son_imprimibles_en_cp1252(self):
        env = entorno_valido()
        del env["DATABASE_URL"]
        errors, warnings = check_env(env)
        salida = "\n".join([*errors, *warnings])
        salida.encode("cp1252")


if __name__ == "__main__":
    unittest.main()
