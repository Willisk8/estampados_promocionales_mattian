"""Inventario remoto de solo lectura; no imprime credenciales ni datos de negocio."""
import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

import psycopg
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', default=str(ROOT / '.env.staging'))
    parser.add_argument('--expected-project', required=True)
    args = parser.parse_args()
    env = dotenv_values(args.env_file)
    dsn = env.get('DATABASE_URL', '')
    api = urlsplit(env.get('SUPABASE_URL', ''))
    db = urlsplit(dsn)
    ref = args.expected_project
    if api.hostname != f'{ref}.supabase.co':
        raise SystemExit('La URL API no corresponde al proyecto esperado.')
    direct = db.hostname == f'db.{ref}.supabase.co'
    pooler = (db.hostname or '').endswith('.pooler.supabase.com') and db.username == f'postgres.{ref}'
    if not (direct or pooler):
        raise SystemExit('La conexion PostgreSQL no corresponde al proyecto esperado.')

    with psycopg.connect(dsn, connect_timeout=12, sslmode='require',
                         options='-c default_transaction_read_only=on -c statement_timeout=30000') as conn:
        record = conn.execute("SELECT to_regclass('public.schema_migrations')::text").fetchone()[0]
        migrations = [] if record is None else [r[0] for r in conn.execute(
            'SELECT to_jsonb(m) FROM public.schema_migrations m ORDER BY filename').fetchall()]
        conn.rollback()
        sql = (ROOT / 'database/diagnostics/supabase_security_inventory.sql').read_text(encoding='utf-8-sig')
        cursor = conn.execute(sql)
        inventory = None
        while True:
            if cursor.description and cursor.description[0].name == 'security_inventory':
                inventory = cursor.fetchone()[0]
            if not cursor.nextset():
                break
        if inventory is None:
            raise RuntimeError('El diagnostico no produjo inventario.')

    local = {p.name: hashlib.sha256(p.read_text(encoding='utf-8-sig').replace('\r\n', '\n').encode()).hexdigest()
             for p in (ROOT / 'database/migrations').glob('*.sql')}
    remote = {m['filename']: m for m in migrations}
    comparison = {
        'pending': sorted(set(local) - set(remote)),
        'remote_only': sorted(set(remote) - set(local)),
        'missing_checksum': [n for n, m in remote.items() if not m.get('checksum_sha256')],
        'checksum_mismatch': [n for n, m in remote.items() if n in local and m.get('checksum_sha256')
                              and m['checksum_sha256'] != local[n]],
        'backfilled': [n for n, m in remote.items() if m.get('checksum_backfilled')],
    }
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output = ROOT / 'outputs' / f'supabase-audit-{stamp}'
    output.mkdir(parents=True, exist_ok=False)
    for filename, value in [('inventory.json', inventory), ('migrations.json', migrations), ('comparison.json', comparison)]:
        (output / filename).write_text(json.dumps(value, ensure_ascii=False, indent=2, default=str), encoding='utf-8')
    print(json.dumps({'project': ref, 'output': str(output), 'migration_count': len(migrations),
                      'inventory_counts': {k: len(v) for k, v in inventory.items() if isinstance(v, list)},
                      'comparison': comparison}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except psycopg.Error as exc:
        # No volcar DSN, credenciales ni mensajes que puedan incluir sus valores.
        raise SystemExit(f'No se pudo completar la lectura PostgreSQL: {type(exc).__name__}, SQLSTATE={exc.sqlstate or "conexion"}.')
