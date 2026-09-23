"""Prepara correcciones verificables de un respaldo JSON; nunca escribe en DB."""
import argparse
import collections
import csv
import json
import re
from pathlib import Path

from scripts.data_quality.normalization import normalize_text, search_key


def repair(text):
    text = normalize_text(text)
    for encoding in ('cp1252', 'latin1'):
        if any(c in text for c in ('Ã', 'Â', 'â€')) and '\ufffd' not in text:
            try:
                candidate = text.encode(encoding).decode('utf-8')
                if candidate.encode('utf-8').decode(encoding) == text:
                    return normalize_text(candidate)
            except (UnicodeError, LookupError):
                pass
    return text


def damaged(text):
    return any(c in text for c in ('?', '\ufffd', 'Ã', 'Â', 'â€'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True)
    args = parser.parse_args()
    base = Path(args.directory)
    read = lambda name: json.loads((base / name).read_text(encoding='utf-8-sig'))
    territories = [r['attributes'] for r in read('divipola-dane-2025.json')['features']]
    pairs = {(search_key(r['DPTO_CNMBRE']), search_key(r['MPIO_CNMBRE'])): r for r in territories}
    by_code = {r['MPIO_CDPMP']: r for r in territories}
    # Reproduce el defecto de codificación contra el catálogo conocido, incluyendo
    # el saneamiento previo de controles C1. Solo admite pares con un código único.
    encoded_pairs = collections.defaultdict(set)
    def observed_variants(name):
        variants = {name}
        for encoding in ('cp1252', 'latin1'):
            try:
                variants.add(normalize_text(re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', name.encode('utf-8').decode(encoding))))
            except UnicodeError:
                pass
        return variants
    for record in territories:
        for dep in observed_variants(record['DPTO_CNMBRE']):
            for city in observed_variants(record['MPIO_CNMBRE']):
                encoded_pairs[(dep, city)].add(record['MPIO_CDPMP'])
    # DANE CNPV 2018: 76001 = Cali; MGN2025: 76001 = Santiago de Cali.
    # https://www.dane.gov.co/files/investigaciones/planes-departamentos-ciudades/220510-InfoDane-Cali-Buenaventura-Valle-del-Cauca.pdf
    pairs[('valle_del_cauca', 'cali')] = by_code['76001']
    # Alias entre versiones del catálogo enlazados por código, nunca por parecido.
    historical = Path('scraping/residential_properties/outputs/cobertura_municipios_colombia.csv')
    if historical.exists():
        for row in csv.DictReader(historical.open(encoding='utf-8-sig')):
            if row['divipola'] in by_code:
                pairs.setdefault((search_key(row['department']), search_key(row['municipality'])), by_code[row['divipola']])
    source = collections.defaultdict(list)
    for row in read('entidades-fuente-oficial.json'):
        nit = re.sub(r'\D', '', row.get('nit', '').split('-')[0])
        source[nit].append(row)
    changes, issues = [], []

    def change(table, pk, row, field, value, evidence):
        if value != row.get(field):
            changes.append(dict(table=table, pk=pk, id=row[pk], field=field,
                                original=row.get(field), normalized=value, evidence=evidence))

    for row in read('organizacion.json'):
        pk = 'id_organizacion'
        official = source.get(row['nit'], [])
        name = repair(row['nombre_legal'])
        if damaged(name):
            candidates = {repair(x.get('nombreentidad', '')).upper() for x in official
                          if x.get('nombreentidad') and not damaged(repair(x['nombreentidad']))}
            # Solo una variante oficial compatible con las letras que sobrevivieron.
            pattern = re.escape(search_key(name)).replace(r'_', r'[_a-z0-9]*')
            candidates = {n for n in candidates if re.fullmatch(pattern, search_key(n))}
            if len(candidates) == 1:
                name = next(iter(candidates))
            else:
                issues.append(dict(table='organizacion', id=row[pk], nit=row['nit'], field='nombre_legal',
                                   original=row['nombre_legal'], code='NAME_SOURCE_UNRESOLVED', candidates=sorted(candidates)))
        if not damaged(name):
            change('organizacion', pk, row, 'nombre_legal', name.upper(), 'NFC/espacios/mayusculas; fuente kg2d-yfyg por NIT para caracteres perdidos')
        dep, city = repair(row['departamento']), repair(row['municipio'])
        match = pairs.get((search_key(dep), search_key(city)))
        if not match:
            codes = encoded_pairs.get((dep, city), set())
            if len(codes) == 1:
                match = by_code[next(iter(codes))]
        if not match:
            matches = {r['MPIO_CDPMP']: r for x in official
                       if (r := pairs.get((search_key(repair(x.get('departamento'))), search_key(repair(x.get('municipio'))))))}
            # Fuente por NIT: no mover entidades si existen ubicaciones oficiales diferentes.
            if len(matches) == 1 and (damaged(dep) or damaged(city)):
                match = next(iter(matches.values()))
        if match:
            for field, value in [('departamento', match['DPTO_CNMBRE']), ('municipio', match['MPIO_CNMBRE'])]:
                change('organizacion', pk, row, field, value, 'DANE MGN2025 exacto normalizado; fuente kg2d-yfyg por NIT si dano')
        else:
            issues.append(dict(table='organizacion', id=row[pk], nit=row['nit'], field='ubicacion',
                               original=[row['departamento'], row['municipio']], code='TERRITORY_REVIEW'))

    for table, pk, fields in [('persona', 'id_persona', ['nombres','apellidos','nombre_completo']),
                             ('proveedor', 'id_proveedor', ['nombre','ciudad']),
                             ('producto_proveedor', 'id_producto_proveedor', ['nombre_original','categoria'])]:
        for row in read(table + '.json'):
            for field in fields:
                if row.get(field) is None:
                    continue
                value = repair(row[field])
                if damaged(value):
                    issues.append(dict(table=table,id=row[pk],field=field,original=row[field],code='TEXT_SOURCE_REVIEW'))
                else:
                    change(table,pk,row,field,value,'NFC, espacios y reparacion reversible; conserva caso y signos significativos')

    products = {r['id_producto_proveedor']: r for r in read('producto_proveedor.json')}
    latest = {}
    for row in sorted(read('precio_proveedor_snapshot.json'), key=lambda r: (r['observado_en'],r['created_at'])):
        latest[row['id_producto_proveedor']] = row
    for pid, row in products.items():
        snap = latest.get(pid)
        if not snap:
            continue
        # No adivinar pack a partir del embalaje de transporte; registrar conflicto
        # solo si el titulo menciona explicitamente una cantidad/presentacion.
        title = search_key(row['nombre_original'])
        multiplicity = re.search(r'(?:^|_)x_?(\d+)(?:_|$)|(?:^|_)(\d+)_(?:unidades|unds|und|metros|mts)(?:_|$)', title)
        if multiplicity and snap['unidad_compra'] in (None, 'UNIT'):
            issues.append(dict(table='precio_proveedor_snapshot',id=snap['id_snapshot'],product_id=pid,
                               field='unidad_compra',original=snap['unidad_compra'],title=row['nombre_original'],
                               source=row['url_producto'],code='PURCHASE_UNIT_AMBIGUOUS'))
        elif snap['unidad_compra'] is None:
            issues.append(dict(table='precio_proveedor_snapshot',id=snap['id_snapshot'],product_id=pid,
                               field='unidad_compra',original=None,title=row['nombre_original'],
                               source=row['url_producto'],code='PURCHASE_UNIT_UNDECLARED'))
    for filename, data in [('correcciones-preview.json',changes),('incidencias.json',issues)]:
        (base/filename).write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
    summary = dict(changes=len(changes), changes_by_field=dict(collections.Counter(c['table']+'.'+c['field'] for c in changes)),
                   issues_by_code=dict(collections.Counter(i['code'] for i in issues)))
    (base/'resumen.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
    print(json.dumps(summary,indent=2))


if __name__ == '__main__':
    main()
