"""Recupera caracteres perdidos solo por identidad estable y coincidencia restante.

Usa el XLSX oficial conservado y la descarga pública por NIT. No atribuye
vigencia a cargos del histórico, ni modifica vínculos o nombres distintos.
"""
import collections
import json
import re
from pathlib import Path
import pandas as pd
from scripts.data_quality.audit_live_snapshot import damaged, repair


def candidate_name(original, candidates):
    pattern = re.sub(r'(?:\\\?)+', '.', re.escape(repair(original).upper()))
    matches = {n for n in candidates if n and not damaged(n) and re.fullmatch(pattern, n)}
    return next(iter(matches)) if len(matches) == 1 else None


def main():
    base = Path('outputs/calidad-viva-20260917')
    read = lambda path: json.loads(path.read_text(encoding='utf-8-sig'))
    source = collections.defaultdict(set)
    for _, row in pd.read_excel(base/'supersolidaria-2023-verificado.xlsx',header=4).fillna('').iterrows():
        nit = re.sub(r'\D', '', str(row['NIT']))
        nit = nit[:-1] if len(nit)==10 else nit
        source[nit].add(repair(row['REPRESENTANTE LEGAL']).upper())
    for row in read(base/'representantes-fuente-oficial.json'):
        nit = re.sub(r'\D','',str(row['nit']).split('-')[0])
        source[nit].add(repair(row.get('representantelegal','')).upper())
    org = {r['id_organizacion']:r['nit'] for r in read(base/'organizacion.json')}
    links = collections.defaultdict(set)
    for row in read(Path('outputs/calidad-viva-20260917-nombres/persona-organizacion.json')):
        if row['rol']=='REPRESENTANTE_LEGAL':
            links[row['id_persona']].update(source.get(org.get(row['id_organizacion']),set()))
    changes = []
    for row in read(base/'persona.json'):
        original = row.get('nombre_completo') or ''
        if not damaged(original):
            continue
        candidate = candidate_name(original, links[row['id_persona']])
        if candidate:
            changes.append(dict(table='persona',pk='id_persona',id=row['id_persona'],field='nombre_completo',
                                original=original,normalized=candidate,evidence='Supersolidaria por NIT y vinculo existente; nombre completo coincide salvo caracteres perdidos; no cambia rol ni vigencia'))
    out=Path('outputs/calidad-viva-20260917-personas')
    out.mkdir(exist_ok=True)
    (out/'correcciones-preview.json').write_text(json.dumps(changes,ensure_ascii=False,indent=2),encoding='utf-8')
    print('Nombres de personas verificables:',len(changes))


if __name__ == '__main__':
    main()
