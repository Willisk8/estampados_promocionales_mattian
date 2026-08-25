"""
Copia a Supabase Storage las imagenes de catalogo que el scraping ya habia
encontrado, y registra la procedencia de cada archivo.

Lee las filas PENDIENTE de imagen_producto_proveedor, descarga cada imagen de
su url_origen y la sube al bucket 'catalogo-proveedor'. Es idempotente: una
imagen ya DESCARGADA no se vuelve a bajar.

Credenciales: la subida usa la API de Storage, que necesita una sesion. Se
inicia sesion con un usuario de consola con rol ADMIN, que es quien tiene
permiso de escritura sobre el bucket segun la migracion 028.

Uso:
    set CONSOLA_EMAIL=...
    set CONSOLA_PASSWORD=...
    python scripts/import/descargar_imagenes_catalogo.py --limite 5   # prueba
    python scripts/import/descargar_imagenes_catalogo.py             # todo
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent.parent
BUCKET = "catalogo-proveedor"

EXTENSION_POR_TIPO = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
    "image/gif": ".gif",
}
TAMANO_MAXIMO = 5 * 1024 * 1024  # el bucket rechaza mas de 5 MB


def cargar_entorno() -> tuple[str, str, str]:
    env_file = ROOT / ".env.staging"
    if env_file.exists():
        from dotenv import load_dotenv
        load_dotenv(env_file)

    db = os.environ.get("DATABASE_URL")
    url = os.environ.get("SUPABASE_URL")
    if not db or not url:
        raise SystemExit("Faltan DATABASE_URL o SUPABASE_URL (revisa .env.staging).")

    # La clave publicable esta hoy guardada bajo el nombre de service_role; se
    # usa por lo que es, no por como se llama. check_env.py reporta ese desorden.
    clave = os.environ.get("SUPABASE_ANON_KEY") or os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not clave:
        raise SystemExit("Falta la clave publicable de Supabase.")
    return db, url.rstrip("/"), clave


def iniciar_sesion(url: str, clave: str) -> str:
    email = os.environ.get("CONSOLA_EMAIL")
    password = os.environ.get("CONSOLA_PASSWORD")
    if not email or not password:
        raise SystemExit(
            "Define CONSOLA_EMAIL y CONSOLA_PASSWORD con un usuario de consola rol ADMIN.\n"
            "Solo ese rol puede escribir en el bucket (migracion 028)."
        )

    req = urllib.request.Request(
        f"{url}/auth/v1/token?grant_type=password",
        data=json.dumps({"email": email, "password": password}).encode(),
        method="POST",
    )
    req.add_header("apikey", clave)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())["access_token"]
    except urllib.error.HTTPError as e:
        raise SystemExit(f"No se pudo iniciar sesion ({e.code}): {(e.read() or b'').decode()[:160]}")


def descargar(url_origen: str) -> tuple[bytes, str]:
    req = urllib.request.Request(url_origen, method="GET")
    req.add_header("User-Agent", "estampados-catalogo/1.0")
    with urllib.request.urlopen(req, timeout=45) as r:
        tipo = (r.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        datos = r.read(TAMANO_MAXIMO + 1)
    if len(datos) > TAMANO_MAXIMO:
        raise ValueError(f"imagen mayor a {TAMANO_MAXIMO // 1024 // 1024} MB")
    if tipo not in EXTENSION_POR_TIPO:
        raise ValueError(f"tipo no permitido por el bucket: {tipo or 'desconocido'}")
    return datos, tipo


def subir(url: str, clave: str, token: str, ruta: str, datos: bytes, tipo: str) -> None:
    req = urllib.request.Request(
        f"{url}/storage/v1/object/{BUCKET}/{ruta}", data=datos, method="POST"
    )
    req.add_header("apikey", clave)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", tipo)
    req.add_header("x-upsert", "true")
    with urllib.request.urlopen(req, timeout=60):
        return


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limite", type=int, help="procesar solo N imagenes (para probar)")
    parser.add_argument("--pausa", type=float, default=0.2,
                        help="segundos entre descargas, para no golpear el CDN")
    parser.add_argument("--reintentar-fallidas", action="store_true",
                        help="incluir tambien las que quedaron en FALLIDA")
    args = parser.parse_args()

    db, url, clave = cargar_entorno()
    token = iniciar_sesion(url, clave)
    print("Sesion iniciada. Subiendo al bucket:", BUCKET)

    import psycopg

    estados = ("PENDIENTE", "FALLIDA") if args.reintentar_fallidas else ("PENDIENTE",)
    consulta = """
        SELECT i.id_imagen, i.url_origen, pp.id_proveedor
          FROM imagen_producto_proveedor i
          JOIN producto_proveedor pp ON pp.id_producto_proveedor = i.id_producto_proveedor
         WHERE i.estado = ANY(%s)
         ORDER BY i.created_at
    """
    if args.limite:
        consulta += f" LIMIT {int(args.limite)}"

    ok = fallidas = 0
    with psycopg.connect(db, connect_timeout=30) as conn:
        with conn.cursor() as cur:
            cur.execute(consulta, (list(estados),))
            pendientes = cur.fetchall()

        print(f"Pendientes a procesar: {len(pendientes)}")

        for i, (id_imagen, url_origen, id_proveedor) in enumerate(pendientes, 1):
            try:
                datos, tipo = descargar(url_origen)
                nombre = Path(urlparse(url_origen).path).stem[:60] or "imagen"
                ruta = f"{id_proveedor}/{id_imagen}-{nombre}{EXTENSION_POR_TIPO[tipo]}"
                subir(url, clave, token, ruta, datos, tipo)

                with conn.cursor() as cur:
                    cur.execute(
                        """
                        UPDATE imagen_producto_proveedor
                           SET estado='DESCARGADA', ruta_storage=%s, content_type=%s,
                               bytes=%s, capturada_en=now(), error=NULL
                         WHERE id_imagen=%s
                        """,
                        (ruta, tipo, len(datos), id_imagen),
                    )
                conn.commit()
                ok += 1
            except Exception as exc:  # noqa: BLE001
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE imagen_producto_proveedor SET estado='FALLIDA', error=%s WHERE id_imagen=%s",
                        (str(exc)[:300], id_imagen),
                    )
                conn.commit()
                fallidas += 1

            if i % 25 == 0 or i == len(pendientes):
                print(f"  {i}/{len(pendientes)}  ok={ok} fallidas={fallidas}")
            time.sleep(args.pausa)

    print(f"\nTerminado. Descargadas {ok}, fallidas {fallidas}.")
    return 0 if fallidas == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
