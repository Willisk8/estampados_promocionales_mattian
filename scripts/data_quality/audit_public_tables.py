"""Auditoria agregada, de solo lectura, de tablas public del proyecto indicado.

No exporta valores personales. Los indicadores textuales requieren revision:
un historico o valor_original no debe reescribirse para eliminar su incidencia.
"""
import argparse
import collections
import json
import re
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit

import psycopg
from psycopg import sql
from dotenv import dotenv_values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expected-project', required=True)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    env = dotenv_values('.env.staging')
    ref = args.expected_project
    db = urlsplit(env['DATABASE_URL'])
    if urlsplit(env['SUPABASE_URL']).hostname != f'{ref}.supabase.co':
        raise SystemExit('Proyecto API incorrecto')
    if not (db.hostname == f'db.{ref}.supabase.co' or
            ((db.hostname or '').endswith('.pooler.supabase.com') and db.username == f'postgres.{ref}')):
        raise SystemExit('Proyecto PostgreSQL incorrecto')
    report = {'project': ref, 'read_only': True, 'tables': {},
              'limitations': 'Indicadores estructurales, no certifican identidad, vigencia ni exactitud comercial. No inspecciona valores dentro de JSON ni archivos Storage.'}
    with psycopg.connect(env['DATABASE_URL'], connect_timeout=12, sslmode='require',
                         options='-c default_transaction_read_only=on -c statement_timeout=30000') as conn:
        conn.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
        report['captured_at'] = str(conn.execute('SELECT now()').fetchone()[0])
        tables = conn.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").fetchall()
        for (table,) in tables:
            print(f'Inspeccionando {table}', flush=True)
            count = conn.execute(sql.SQL('SELECT count(*) FROM public.{}').format(sql.Identifier(table))).fetchone()[0]
            columns = [r[0] for r in conn.execute("SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name=%s AND data_type IN ('text','character varying','character') ORDER BY ordinal_position", (table,))]
            issues = collections.Counter()
            if columns:
                query = sql.SQL('SELECT {} FROM public.{}').format(sql.SQL(',').join(map(sql.Identifier, columns)), sql.Identifier(table))
                with conn.cursor() as cursor:
                    cursor.execute(query)
                    for row in cursor:
                        for col, value in zip(columns, row):
                            if value is None:
                                continue
                            if value != unicodedata.normalize('NFC', value):
                                issues[col + ':NON_NFC'] += 1
                            if value != value.strip():
                                issues[col + ':OUTER_WHITESPACE'] += 1
                            if '\ufffd' in value or re.search(r'\?{2,}', value):
                                issues[col + ':LOST_CHARACTERS_REVIEW'] += 1
                            if any(marker in value for marker in ('Ã', 'Â', 'â€')):
                                issues[col + ':ENCODING_REVIEW'] += 1
                            if re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', value):
                                issues[col + ':CONTROL_CHARACTERS'] += 1
            report['tables'][table] = {'rows': count, 'text_columns': len(columns), 'indicators': dict(issues)}
        report['unvalidated_constraints'] = [dict(zip(('table', 'constraint', 'type'), row)) for row in conn.execute("SELECT conrelid::regclass::text, conname, contype FROM pg_constraint WHERE connamespace='public'::regnamespace AND NOT convalidated")]
        report['rls_disabled'] = [row[0] for row in conn.execute("SELECT relname FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r' AND NOT relrowsecurity")]
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    (output / 'public-tables.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except psycopg.Error as exc:
        raise SystemExit(f'Lectura incompleta: {type(exc).__name__}; SQLSTATE={exc.sqlstate or "conexion"}')
