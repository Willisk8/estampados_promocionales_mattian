"""
Evals de la capa de IA de Cliente 360 (Etapa C, Fase 6).

No evalua un LLM en vivo -todavia no hay un agente conectado a las
funciones fn_ai_*. Evalua si la CAPA DE DATOS puede responder cada
pregunta del golden dataset (evals/golden_cliente360.yaml) de forma
correcta y segura: es la red de seguridad de la Fase 5, no un juez de
calidad conversacional.

Cada caso corre dentro de una transaccion que se revierte siempre: igual
que database/tests/*.sql, nunca escribe en STAGING.

Uso:
    python -m unittest scripts.evals.run_evals -v
    python scripts/evals/run_evals.py

Requiere DATABASE_URL (o .env.staging, igual que
scripts/backfill_migration_checksums.py).
"""

from __future__ import annotations

import os
import re
import sys
import unittest
import uuid
from pathlib import Path

import psycopg
import yaml

ROOT = Path(__file__).resolve().parents[2]
GOLDEN_PATH = ROOT / "evals" / "golden_cliente360.yaml"

# Namespace de UUIDs de este archivo: evita colisionar con los fixtures de
# database/tests/*.sql, que usan sus propios prefijos por fase.
NS = "00000000-0000-4000-e600-"

ORG_CON_HISTORIA = f"{NS}000000000010"
ORG_SIN_HISTORIA = f"{NS}000000000011"
USER_COMERCIAL = f"{NS}000000000002"
USER_LECTURA = f"{NS}000000000001"

PATRON_CORREO = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")

# Catalogo cerrado de herramientas que el agente conoce hoy. El caso
# "pregunta_fuera_de_alcance" verifica contra esta lista, no contra la base
# de datos: "fuera de alcance" es una propiedad del catalogo de
# herramientas, no de los datos.
HERRAMIENTAS_CONOCIDAS = {
    "fn_ai_cliente_resumen",
    "fn_ai_cliente_timeline",
    "fn_ai_cliente_metricas",
    "fn_ai_cotizaciones_activas",
    "fn_ai_pedidos_cliente",
    "fn_ai_senales_cliente",
    "fn_ai_vocabulario",
    "fn_ai_registrar_recomendacion",
    "fn_ai_proponer_accion",
}


def cargar_entorno() -> str:
    env_file = ROOT / ".env.staging"
    if env_file.exists():
        from dotenv import load_dotenv

        load_dotenv(env_file)
    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        raise SystemExit("DATABASE_URL no esta configurado (revisa .env.staging).")
    return db_url


def cargar_casos() -> list[dict]:
    data = yaml.safe_load(GOLDEN_PATH.read_text(encoding="utf-8"))
    casos = list(data.get("casos_negocio", [])) + list(data.get("casos_adversariales", []))
    if not casos:
        raise SystemExit(f"No se encontraron casos en {GOLDEN_PATH}")
    return casos


class ContextoEval:
    """Envuelve una conexion + cursor con helpers para simular un rol.

    Mismo idioma que database/tests/*.sql: set_config('request.jwt.claims')
    + SET LOCAL ROLE authenticated para actuar como un usuario de consola
    dentro de la transaccion, que nunca se confirma.
    """

    def __init__(self, conn: psycopg.Connection):
        self.conn = conn
        self.cur = conn.cursor()

    def como(self, id_usuario: str) -> None:
        self.cur.execute(
            "SELECT set_config('request.jwt.claims', %s, true);",
            (f'{{"sub":"{id_usuario}"}}',),
        )
        self.cur.execute("SET LOCAL ROLE authenticated;")

    def como_owner(self) -> None:
        self.cur.execute("RESET ROLE;")

    def llamar(self, funcion: str, *args) -> list[dict]:
        placeholders = ", ".join(["%s"] * len(args))
        self.cur.execute(f"SELECT * FROM {funcion}({placeholders});", args)
        columnas = [d.name for d in self.cur.description]
        return [dict(zip(columnas, fila)) for fila in self.cur.fetchall()]

    def uno(self, funcion: str, *args) -> dict:
        filas = self.llamar(funcion, *args)
        if not filas:
            raise AssertionError(f"{funcion} no devolvio ninguna fila")
        return filas[0]


def instalar_fixtures(ctx: ContextoEval) -> None:
    """Crea el estado conocido contra el que se miden las respuestas.

    Corre como owner (bypassa RLS), igual que los INSERT de fixture al
    inicio de cada database/tests/*.sql.
    """
    cur = ctx.cur

    cur.execute(
        """
        INSERT INTO auth.users (id, email) VALUES
            (%s, 'lectura-evals@prueba.local'),
            (%s, 'comercial-evals@prueba.local')
        ON CONFLICT (id) DO NOTHING;
        """,
        (USER_LECTURA, USER_COMERCIAL),
    )
    cur.execute(
        """
        INSERT INTO perfil_usuario (user_id, email, rol, activo) VALUES
            (%s, 'lectura-evals@prueba.local', 'LECTURA', true),
            (%s, 'comercial-evals@prueba.local', 'COMERCIAL', true)
        ON CONFLICT (user_id) DO NOTHING;
        """,
        (USER_LECTURA, USER_COMERCIAL),
    )

    cur.execute(
        """
        INSERT INTO organizacion (id_organizacion, nit, nombre_legal, tipo_entidad_origen, departamento, municipio)
        VALUES
            (%s, '900700100', 'ORG EVAL CLIENTE 360', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.'),
            (%s, '900700200', 'ORG EVAL SIN HISTORIA', 'Fondos de empleados', 'Bogota, D.C.', 'Bogota, D.C.');
        """,
        (ORG_CON_HISTORIA, ORG_SIN_HISTORIA),
    )

    # Interacciones: la mas reciente hace 2 dias. psycopg3 no acepta
    # multiples sentencias en un solo execute() con parametros, asi que
    # van por separado.
    ctx.como(USER_COMERCIAL)
    cur.execute(
        """
        SELECT * FROM fn_consola_registrar_interaccion(
            %s, 'LLAMADA', 'OUTBOUND', 'SEGUIMIENTO', p_occurred_at => now() - interval '10 days');
        """,
        (ORG_CON_HISTORIA,),
    )
    cur.execute(
        """
        SELECT * FROM fn_consola_registrar_interaccion(
            %s, 'WHATSAPP', 'INBOUND', 'COTIZACION', p_occurred_at => now() - interval '2 days');
        """,
        (ORG_CON_HISTORIA,),
    )
    ctx.como_owner()

    cur.execute("SELECT id_producto FROM producto LIMIT 1;")
    fila = cur.fetchone()
    if fila is None:
        raise SystemExit("No hay ningun producto en la base: los evals necesitan al menos uno para fijar el fixture.")
    id_producto = fila[0]

    # Tres cotizaciones: rechazada, vencida, y aceptada -> convertida.
    id_cot_rechazada = str(uuid.uuid4())
    id_cot_vencida = str(uuid.uuid4())
    id_cot_aceptada = str(uuid.uuid4())

    cur.execute(
        """
        INSERT INTO cotizacion (id_cotizacion, id_organizacion, estado, moneda, total, creada_por, rol_consola, metodo_precio, fecha_emision)
        VALUES
            (%(rechazada)s, %(org)s, 'RECHAZADA', 'COP', 50000, %(user)s, 'COMERCIAL', 'TARIFA_PUBLICADA', now() - interval '30 days'),
            (%(vencida)s, %(org)s, 'VENCIDA', 'COP', 60000, %(user)s, 'COMERCIAL', 'TARIFA_PUBLICADA', now() - interval '20 days'),
            (%(aceptada)s, %(org)s, 'ACEPTADA', 'COP', 150000, %(user)s, 'COMERCIAL', 'TARIFA_PUBLICADA', now() - interval '5 days');
        """,
        {
            "rechazada": id_cot_rechazada,
            "vencida": id_cot_vencida,
            "aceptada": id_cot_aceptada,
            "org": ORG_CON_HISTORIA,
            "user": USER_COMERCIAL,
        },
    )
    for id_cot, cantidad, precio, subtotal in (
        (id_cot_rechazada, 5, 10000, 50000),
        (id_cot_vencida, 6, 10000, 60000),
        (id_cot_aceptada, 15, 10000, 150000),
    ):
        cur.execute(
            """
            INSERT INTO cotizacion_item (id_cotizacion, id_producto, cantidad, precio_unitario, subtotal, producto_snapshot)
            VALUES (%s, %s, %s, %s, %s, '{}'::jsonb);
            """,
            (id_cot, id_producto, cantidad, precio, subtotal),
        )

    ctx.como(USER_COMERCIAL)
    cur.execute("SELECT * FROM fn_consola_convertir_cotizacion_en_pedido(%s);", (id_cot_aceptada,))
    ctx.como_owner()


class EvalsClienteContext360(unittest.TestCase):
    """Un metodo de test por caso del golden dataset, generado dinamicamente
    en tiempo de importacion (ver el bucle al final del archivo)."""

    conn: psycopg.Connection
    ctx: ContextoEval

    @classmethod
    def setUpClass(cls) -> None:
        db_url = cargar_entorno()
        cls.conn = psycopg.connect(db_url, connect_timeout=20, autocommit=False)
        cls.ctx = ContextoEval(cls.conn)
        instalar_fixtures(cls.ctx)

    @classmethod
    def tearDownClass(cls) -> None:
        # Nunca se confirma: ningun eval escribe en STAGING.
        cls.conn.rollback()
        cls.conn.close()


# ----------------------------------------------------------------
# Verificaciones. Cada una recibe el ContextoEval y el caso del YAML.
# ----------------------------------------------------------------

def _verificar_fecha_ultima_interaccion_reciente(ctx: ContextoEval, caso: dict) -> None:
    ctx.como(USER_LECTURA)
    fila = ctx.uno("fn_ai_cliente_resumen", ORG_CON_HISTORIA)
    ctx.como_owner()
    assert fila["status"] == "OK", fila
    fecha = fila["fecha_ultima_interaccion"]
    assert fecha is not None, "fecha_ultima_interaccion no debe ser NULL con historia registrada"
    dias = (ctx_now() - fecha).days if hasattr(fecha, "tzinfo") else None
    # Verificacion tolerante: debe estar dentro de los ultimos 3 dias
    # (la fixture la registra hace 2).
    import datetime

    ahora = datetime.datetime.now(datetime.timezone.utc)
    assert (ahora - fecha).days <= 3, f"fecha_ultima_interaccion demasiado antigua: {fecha}"


def ctx_now():
    import datetime

    return datetime.datetime.now(datetime.timezone.utc)


def _verificar_capacidad_no_disponible_aun(ctx: ContextoEval, caso: dict) -> None:
    ctx.cur.execute(
        "SELECT proname FROM pg_proc WHERE proname ILIKE 'fn_ai%campan%';"
    )
    filas = ctx.cur.fetchall()
    assert not filas, (
        "Existe una fn_ai_* de campanas pero el caso adversarial asume que "
        f"todavia no hay ninguna (Fase 8): {filas}"
    )


def _verificar_conteo_cotizaciones_coherente(ctx: ContextoEval, caso: dict) -> None:
    ctx.como(USER_LECTURA)
    fila = ctx.uno("fn_ai_cliente_metricas", ORG_CON_HISTORIA)
    ctx.como_owner()
    assert fila["status"] == "OK", fila
    assert fila["total_cotizaciones"] == 3, fila["total_cotizaciones"]
    assert fila["total_cotizaciones_aceptadas"] == 1, fila["total_cotizaciones_aceptadas"]
    assert fila["total_pedidos"] == 1, fila["total_pedidos"]


def _verificar_productos_top_no_nulos(ctx: ContextoEval, caso: dict) -> None:
    ctx.como(USER_LECTURA)
    fila = ctx.uno("fn_ai_cliente_metricas", ORG_CON_HISTORIA)
    ctx.como_owner()
    assert fila["producto_mas_cotizado"] is not None
    assert fila["producto_mas_comprado"] is not None


def _verificar_senales_suficientes_para_recomendar(ctx: ContextoEval, caso: dict) -> None:
    ctx.como(USER_LECTURA)
    fila = ctx.uno("fn_ai_senales_cliente", ORG_CON_HISTORIA)
    ctx.como_owner()
    assert fila["status"] == "OK", fila
    assert fila["temperatura"] is not None
    assert fila["seguimientos_pendientes"] is not None
    # La funcion NUNCA debe traer un campo de texto con la recomendacion
    # ya redactada: esa es responsabilidad del modelo, no de SQL.
    assert "recomendacion" not in fila, "fn_ai_senales_cliente no debe redactar la recomendacion"


def _verificar_temperatura_es_activo(ctx: ContextoEval, caso: dict) -> None:
    ctx.como(USER_LECTURA)
    fila = ctx.uno("fn_ai_cliente_resumen", ORG_CON_HISTORIA)
    ctx.como_owner()
    assert fila["temperatura"] == "ACTIVO", fila["temperatura"]


def _verificar_ninguna_herramienta_expone_correo(ctx: ContextoEval, caso: dict) -> None:
    ctx.como(USER_LECTURA)
    resumen = ctx.uno("fn_ai_cliente_resumen", ORG_CON_HISTORIA)
    timeline = ctx.llamar("fn_ai_cliente_timeline", ORG_CON_HISTORIA, None, 50, None)
    metricas = ctx.uno("fn_ai_cliente_metricas", ORG_CON_HISTORIA)
    ctx.como_owner()

    texto = " ".join(
        str(v)
        for fila in ([resumen] + timeline + [metricas])
        for v in fila.values()
    )
    assert not PATRON_CORREO.search(texto), "una fn_ai_* expuso un correo en su salida"


def _verificar_sin_herramienta_sql_libre(ctx: ContextoEval, caso: dict) -> None:
    ctx.cur.execute(
        """
        SELECT p.proname, array_agg(a.parametro) AS parametros
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
          CROSS JOIN LATERAL unnest(
              string_to_array(pg_get_function_arguments(p.oid), ', ')
          ) AS a(parametro)
         WHERE n.nspname = 'public'
           AND p.proname LIKE 'fn_ai_%'
         GROUP BY p.proname;
        """
    )
    sospechosos = []
    for proname, parametros in ctx.cur.fetchall():
        for parametro in parametros:
            nombre = parametro.lower()
            if any(palabra in nombre for palabra in ("sql", "query", "comando", "statement")):
                sospechosos.append((proname, parametro))
    assert not sospechosos, f"una fn_ai_* acepta un parametro tipo SQL libre: {sospechosos}"


def _verificar_responde_sin_inventar(ctx: ContextoEval, caso: dict) -> None:
    ctx.como(USER_LECTURA)
    fila = ctx.uno("fn_ai_cliente_resumen", ORG_SIN_HISTORIA)
    ctx.como_owner()
    assert fila["status"] == "OK", "la organizacion existe, debe responder OK"
    for campo in ("fecha_ultima_interaccion", "producto_mas_cotizado", "producto_mas_comprado"):
        assert fila[campo] is None, f"{campo} deberia ser NULL sin historia, no un valor inventado: {fila[campo]}"


def _verificar_ninguna_herramienta_aplica(ctx: ContextoEval, caso: dict) -> None:
    # has_function_privilege excluye los ayudantes internos
    # (fn_ai_resolver_sesion, fn_ai_registrar_llamada): no se otorgan a
    # authenticated a proposito (ver 045), y no son herramientas del
    # agente, son implementacion.
    ctx.cur.execute(
        """
        SELECT p.proname
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname LIKE 'fn_ai_%'
           AND has_function_privilege('authenticated', p.oid, 'EXECUTE');
        """
    )
    existentes = {fila[0] for fila in ctx.cur.fetchall()}
    assert existentes == HERRAMIENTAS_CONOCIDAS, (
        "el catalogo de herramientas cambio; actualiza HERRAMIENTAS_CONOCIDAS "
        f"en este archivo. Diferencia: {existentes.symmetric_difference(HERRAMIENTAS_CONOCIDAS)}"
    )
    # Ninguna herramienta conocida tiene nada que ver con clima/tiempo.
    assert not any("clima" in h or "tiempo" in h for h in existentes)


VERIFICACIONES = {
    "fecha_ultima_interaccion_reciente": _verificar_fecha_ultima_interaccion_reciente,
    "capacidad_no_disponible_aun": _verificar_capacidad_no_disponible_aun,
    "conteo_cotizaciones_coherente": _verificar_conteo_cotizaciones_coherente,
    "productos_top_no_nulos": _verificar_productos_top_no_nulos,
    "senales_suficientes_para_recomendar": _verificar_senales_suficientes_para_recomendar,
    "temperatura_es_activo": _verificar_temperatura_es_activo,
    "ninguna_herramienta_expone_correo": _verificar_ninguna_herramienta_expone_correo,
    "sin_herramienta_sql_libre": _verificar_sin_herramienta_sql_libre,
    "responde_sin_inventar": _verificar_responde_sin_inventar,
    "ninguna_herramienta_aplica": _verificar_ninguna_herramienta_aplica,
}


def _generar_metodo_test(caso: dict):
    nombre_verificacion = caso["verificacion"]
    verificar = VERIFICACIONES[nombre_verificacion]

    def metodo(self: EvalsClienteContext360) -> None:
        with self.subTest(pregunta=caso["pregunta"]):
            verificar(self.ctx, caso)

    metodo.__name__ = f"test_{caso['id']}"
    metodo.__doc__ = caso["pregunta"]
    return metodo


for _caso in cargar_casos():
    _nombre = f"test_{_caso['id']}"
    setattr(EvalsClienteContext360, _nombre, _generar_metodo_test(_caso))


if __name__ == "__main__":
    unittest.main()
