"""
Registra el SHA-256 de las migraciones ya aplicadas en public.schema_migrations.

Las migraciones 000-022 se aplicaron antes de que el runner guardara checksums.
Este script reconstruye ese dato a partir de los archivos actuales y lo marca
con checksum_backfilled = true.

Limite honesto de la reconstruccion: el checksum se calcula sobre el archivo tal
como esta HOY. Si una migracion fue editada despues de aplicarse, el checksum
reconstruido registra la version editada y esa diferencia ya no es detectable.
Por eso queda marcado como backfilled: a partir de aqui el runner detecta
cambios, pero no puede afirmar nada sobre lo ocurrido antes.

Tambien escribe database/migrations/CHECKSUMS.txt, que usa la auditoria local
(scripts/audit_change.py) para avisar si se edita una migracion ya aplicada.

Uso:
    python scripts/backfill_migration_checksums.py            # dry-run
    python scripts/backfill_migration_checksums.py --apply    # escribe
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS = ROOT / "database" / "migrations"
MANIFIESTO = MIGRATIONS / "CHECKSUMS.txt"


def cargar_entorno() -> str:
    env_file = ROOT / ".env.staging"
    if env_file.exists():
        from dotenv import load_dotenv
        load_dotenv(env_file)
    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        raise SystemExit("DATABASE_URL no esta configurado (revisa .env.staging).")
    return db_url


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="escribir en la base de datos; sin esta bandera solo muestra el plan",
    )
    args = parser.parse_args()

    locales = {p.name: sha256(p) for p in sorted(MIGRATIONS.glob("*.sql"))}
    if not locales:
        raise SystemExit(f"No se encontraron migraciones en {MIGRATIONS}")

    import psycopg

    db_url = cargar_entorno()
    with psycopg.connect(db_url, connect_timeout=20) as conn:
        with conn.cursor() as cur:
            # Las columnas las agrega apply_pending_migrations.ps1, pero este
            # script debe poder correr solo. El DDL es idempotente y solo se
            # ejecuta con --apply, para que el dry-run no escriba nada.
            cur.execute(
                """
                SELECT count(*) FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = 'schema_migrations'
                  AND column_name IN ('checksum_sha256', 'checksum_backfilled')
                """
            )
            columnas_presentes = cur.fetchone()[0]
            if columnas_presentes < 2:
                if not args.apply:
                    print(
                        "Las columnas de checksum no existen todavia en "
                        "public.schema_migrations.\n"
                        "Ejecuta con --apply para crearlas y registrar los checksums."
                    )
                    return 0
                cur.execute(
                    """
                    ALTER TABLE public.schema_migrations
                        ADD COLUMN IF NOT EXISTS checksum_sha256 TEXT;
                    ALTER TABLE public.schema_migrations
                        ADD COLUMN IF NOT EXISTS checksum_backfilled BOOLEAN NOT NULL DEFAULT false;
                    """
                )
                print("Columnas de checksum creadas en public.schema_migrations.")

            cur.execute(
                """
                SELECT filename, checksum_sha256, checksum_backfilled
                FROM public.schema_migrations
                ORDER BY filename
                """
            )
            registradas = {f: (c, b) for f, c, b in cur.fetchall()}

            pendientes = [f for f in registradas if registradas[f][0] is None and f in locales]
            sin_archivo = [f for f in registradas if f not in locales]
            sin_aplicar = [f for f in locales if f not in registradas]

            print(f"Migraciones aplicadas en la base : {len(registradas)}")
            print(f"Archivos locales                 : {len(locales)}")
            print(f"Sin checksum registrado          : {len(pendientes)}")
            if sin_archivo:
                print(f"AVISO aplicadas sin archivo local: {', '.join(sin_archivo)}")
            if sin_aplicar:
                print(f"AVISO locales sin aplicar        : {', '.join(sin_aplicar)}")

            for f in pendientes:
                print(f"  backfill {f} -> {locales[f][:16]}...")

            if not args.apply:
                print("\nDry-run: no se escribio nada. Repite con --apply para registrar.")
                return 0

            for f in pendientes:
                cur.execute(
                    """
                    UPDATE public.schema_migrations
                    SET checksum_sha256 = %s, checksum_backfilled = true
                    WHERE filename = %s AND checksum_sha256 IS NULL
                    """,
                    (locales[f], f),
                )
            conn.commit()
            print(f"\nRegistrados {len(pendientes)} checksums reconstruidos.")

            cur.execute(
                """
                SELECT filename, checksum_sha256
                FROM public.schema_migrations
                WHERE checksum_sha256 IS NOT NULL
                ORDER BY filename
                """
            )
            filas = cur.fetchall()

    lineas = [f"{checksum}  {filename}" for filename, checksum in filas]
    cabecera = [
        "# Checksums SHA-256 de las migraciones aplicadas en STAGING.",
        "# Generado por scripts/backfill_migration_checksums.py --apply.",
        "# Lo usa scripts/audit_change.py para avisar si se edita una migracion ya aplicada.",
    ]
    MANIFIESTO.write_text("\n".join(cabecera + lineas) + "\n", encoding="utf-8")
    print(f"Manifiesto escrito: {MANIFIESTO.relative_to(ROOT)} ({len(filas)} entradas)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
