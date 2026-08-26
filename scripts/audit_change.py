"""
Auditoria de regresion para el MVP Estampados.

Se ejecuta despues de cada cambio de archivo (hook PostToolUse) y tambien a
mano. Verifica invariantes mecanicas del plan de Etapas A y B: que el cambio
no rompa el resto de la aplicacion ni relaje la seguridad de la base.

Uso:
    python scripts/audit_change.py --file <ruta>   # audita un archivo
    python scripts/audit_change.py --all           # audita todo el repositorio

Salida: texto legible por defecto; --json para el hook.
Codigo de salida: 0 sin errores, 1 con al menos un ERROR.

Las reglas de juicio (cumplimiento del plan) NO viven aqui: viven en las
skills estampados-change-audit y estampados-db-audit. Aqui solo van reglas
que se pueden decidir con certeza leyendo el archivo.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Tablas cuyo deny_all protege PII y no debe relajarse (plan B1-d).
TABLAS_PII = (
    "canal_contacto",
    "persona",
    "persona_organizacion",
    "contactabilidad",
    "supresion",
    # Etapa C, Fase 1 (docs/plan_ia.md): guardan id_persona y resumenes de
    # conversaciones. Se leen solo por fn_consola_timeline_cliente.
    "interaccion_cliente",
    "cliente_evento",
)

# Vistas que exponen correos en crudo y nunca se otorgan a authenticated.
VISTAS_PROHIBIDAS = (
    "vw_campaign_eligibility_queue",
    "vw_email_quality_classification",
)

# Snapshots append-only: nuevas observaciones son INSERT, jamas UPDATE.
TABLAS_APPEND_ONLY = (
    "precio_proveedor_snapshot",
    "precio_tecnica_marcacion_snapshot",
)

# Directorios que no son codigo del proyecto y no deben auditarse.
IGNORADOS = {"node_modules", ".next", "__pycache__", ".git", "dist", "build"}

SEVERIDAD_ERROR = "ERROR"
SEVERIDAD_WARN = "WARN"


@dataclass
class Hallazgo:
    severidad: str
    regla: str
    detalle: str
    archivo: str = ""


@dataclass
class Reporte:
    hallazgos: list[Hallazgo] = field(default_factory=list)

    def error(self, regla: str, detalle: str, archivo: str = "") -> None:
        self.hallazgos.append(Hallazgo(SEVERIDAD_ERROR, regla, detalle, archivo))

    def warn(self, regla: str, detalle: str, archivo: str = "") -> None:
        self.hallazgos.append(Hallazgo(SEVERIDAD_WARN, regla, detalle, archivo))

    @property
    def errores(self) -> list[Hallazgo]:
        return [h for h in self.hallazgos if h.severidad == SEVERIDAD_ERROR]

    @property
    def advertencias(self) -> list[Hallazgo]:
        return [h for h in self.hallazgos if h.severidad == SEVERIDAD_WARN]


def checksum_normalizado(path: Path) -> str:
    """SHA-256 estable entre plataformas.

    Git entrega CRLF en Windows y LF en el runner de CI. Hashear los bytes
    crudos hace que el mismo archivo tenga dos checksums distintos, asi que se
    normalizan los finales de linea y se descarta el BOM antes de hashear.
    """
    texto = path.read_bytes().decode("utf-8-sig", errors="replace")
    return hashlib.sha256(texto.replace("\r\n", "\n").encode("utf-8")).hexdigest()


def sin_comentarios(sql: str) -> str:
    """Quita comentarios de linea y de bloque para no disparar falsos positivos."""
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    sql = re.sub(r"--[^\n]*", " ", sql)
    return sql


def remediada_en_otra_migracion(funcion: str) -> bool:
    """¿Alguna migracion fija el search_path de esta funcion con ALTER FUNCTION?

    La 011 endurece asi las funciones creadas en la 007 y la 009. Sin esta
    comprobacion la auditoria dejaria dos advertencias fijas y ya resueltas.
    """
    patron = re.compile(
        r"ALTER\s+FUNCTION\s+" + re.escape(funcion) + r"\b[^;]*SET\s+search_path",
        re.I | re.DOTALL,
    )
    for otra in (ROOT / "database" / "migrations").glob("*.sql"):
        if patron.search(sin_comentarios(otra.read_text(encoding="utf-8", errors="replace"))):
            return True
    return False


def guardia_rol_null_corregida(funcion: str) -> bool:
    """¿La definicion VIGENTE (la de mayor numero de migracion) de esta
    funcion ya trae la guardia NULL-segura?

    046_close_anon_execute_and_null_role_bypass.sql reescribio 14 funciones
    con CREATE OR REPLACE FUNCTION para que "v_rol NULL" ya no atraviese el
    chequeo de rol. El archivo que las creo originalmente es inmutable (no
    se edita, ver migracion-inmutable arriba) y conserva el patron viejo en
    su texto para siempre. Sin esta comprobacion, --all quedaria en rojo de
    forma permanente por 14 hallazgos ya resueltos hacia adelante -exactamente
    el mismo caso que remediada_en_otra_migracion ya resuelve para
    search-path-fijo, aplicado aqui a una guardia distinta.

    Importante: se compara contra la ULTIMA definicion (por numero de
    archivo), no contra "existe en algun punto del historial". Una
    migracion futura podria volver a tocar una de estas 14 funciones y
    reintroducir el patron vulnerable por accidente -ya paso varias veces
    en este repo, p.ej. fn_consola_actualizar_estado_comercial redefinida
    en 029, 031 y 032-; una version vieja y ya superada no debe poder
    enmascarar esa regresion. Hallado por auditoria externa (sesion
    willi-eb) con una prueba reproducible antes de aplicar este ajuste.
    """
    patron_funcion = re.compile(
        r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?" + re.escape(funcion) + r"\s*\(",
        re.I,
    )
    ultima_es_segura = False
    for otra in sorted((ROOT / "database" / "migrations").glob("*.sql"), key=lambda p: p.name):
        texto = sin_comentarios(otra.read_text(encoding="utf-8", errors="replace"))
        m = patron_funcion.search(texto)
        if not m:
            continue
        ventana = texto[m.end(): m.end() + 6000]
        ultima_es_segura = bool(re.search(r"v_rol\s+IS\s+NULL\s+OR\s+v_rol\s+NOT\s+IN", ventana, re.I))
    return ultima_es_segura


def auditar_migracion(path: Path, rep: Reporte) -> None:
    nombre = path.name
    rel = str(path.relative_to(ROOT)).replace("\\", "/")
    crudo = path.read_text(encoding="utf-8", errors="replace")
    sql = sin_comentarios(crudo)

    if not re.match(r"^\d{3}_[a-z0-9_]+\.sql$", nombre):
        rep.error(
            "migracion-numerada",
            "'" + nombre + "' no cumple el formato NNN_descripcion_en_minusculas.sql",
            rel,
        )

    # Una migracion ya aplicada no se edita: se escribe una nueva.
    manifiesto = ROOT / "database" / "migrations" / "CHECKSUMS.txt"
    ya_aplicada = False
    if manifiesto.exists():
        registrados = {}
        for linea in manifiesto.read_text(encoding="utf-8").splitlines():
            if "  " in linea:
                digest, archivo = linea.split("  ", 1)
                registrados[archivo.strip()] = digest.strip()
        actual = checksum_normalizado(path)
        esperado = registrados.get(nombre)
        ya_aplicada = esperado is not None
        if esperado and esperado != actual:
            rep.error(
                "migracion-inmutable",
                "'" + nombre + "' ya fue aplicada y su contenido cambio. "
                "Crea una migracion nueva en vez de editar esta.",
                rel,
            )

    # Toda tabla nueva nace con RLS y con negacion por defecto.
    for tabla in re.findall(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)", sql, re.I):
        if not re.search(r"ALTER\s+TABLE\s+" + tabla + r"\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY", sql, re.I):
            rep.error(
                "rls-obligatorio",
                "la tabla '" + tabla + "' se crea sin ENABLE ROW LEVEL SECURITY",
                rel,
            )
        elif not re.search(r"CREATE\s+POLICY\s+\w+\s+ON\s+" + tabla + r"\b", sql, re.I):
            rep.error(
                "negacion-por-defecto",
                "la tabla '" + tabla + "' habilita RLS pero no define ninguna politica",
                rel,
            )

    # Supabase concede ALL a anon y authenticated sobre las tablas nuevas de
    # public. Una tabla que solo se apoya en deny_all queda a una politica mal
    # escrita de estar abierta al rol anonimo. Paso exactamente eso con
    # perfil_usuario en la migracion 024.
    # Solo se exige a migraciones que aun no se han aplicado: una ya aplicada es
    # inmutable por la regla de arriba, y su brecha se cierra con una migracion
    # nueva (eso hace la 025), no editandola.
    tablas_creadas = [] if ya_aplicada else re.findall(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)", sql, re.I)
    if tablas_creadas:
        for tabla in tablas_creadas:
            revocada = re.search(
                r"REVOKE\s+[^;]*\bON\b[^;]*\b" + tabla + r"\b[^;]*\bFROM\b[^;]*\banon\b",
                sql, re.I | re.DOTALL,
            )
            if not revocada:
                rep.error(
                    "grant-por-defecto",
                    "crea la tabla '" + tabla + "' sin revocar los privilegios que "
                    "Supabase otorga por defecto a anon. Agrega "
                    "'REVOKE ALL ON " + tabla + " FROM anon, authenticated;'",
                    rel,
                )

    # El deny_all de las tablas con PII no se toca (plan B1-d).
    for tabla in TABLAS_PII:
        if re.search(r"DROP\s+POLICY\s+(?:IF\s+EXISTS\s+)?deny_all\s+ON\s+" + tabla + r"\b", sql, re.I):
            rep.error(
                "pii-deny-all",
                "elimina deny_all de '" + tabla + "', que contiene PII. "
                "Expon esos datos con una funcion SECURITY DEFINER enmascarada.",
                rel,
            )

    # anon nunca recibe privilegios; las vistas de campana tampoco se otorgan.
    for grant in re.findall(r"GRANT\s+(.{0,400}?);", sql, re.I | re.DOTALL):
        if re.search(r"\bTO\b[^;]*\banon\b", grant, re.I):
            rep.error(
                "grant-anon",
                "otorga privilegios al rol 'anon'; la consola solo usa 'authenticated'",
                rel,
            )
        for vista in VISTAS_PROHIBIDAS:
            if re.search(r"\b" + vista + r"\b", grant, re.I):
                rep.error(
                    "grant-vista-campana",
                    "otorga acceso a '" + vista + "', que expone correos en crudo. "
                    "Debe quedar solo para service_role/psql.",
                    rel,
                )

    # NULL NOT IN (...) es NULL, y PL/pgSQL trata un IF con condicion NULL
    # como falso: la guardia "IF v_rol NOT IN (...) THEN RAISE EXCEPTION"
    # no dispara para un usuario sin perfil activo (v_rol NULL), dejandolo
    # pasar. Se descubrio en 14 funciones vivas al construir los evals de
    # la Fase 6 (046_close_anon_execute_and_null_role_bypass.sql). La forma
    # segura es "IF v_rol IS NULL OR v_rol NOT IN (...)".
    for m in re.finditer(r"IF\s+v_rol\s+NOT\s+IN", sql, re.I):
        contexto_previo = sql[max(0, m.start() - 40):m.start()]
        if re.search(r"v_rol\s+IS\s+NULL\s+OR\s*$", contexto_previo, re.I):
            continue
        anterior = sql[: m.start()]
        creadas = re.findall(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(\w+)", anterior, re.I)
        funcion = creadas[-1] if creadas else None
        if funcion and guardia_rol_null_corregida(funcion):
            continue
        rep.error(
            "guardia-rol-null",
            "'IF v_rol NOT IN (...)' no bloquea v_rol NULL (sin perfil activo): "
            "NULL NOT IN (...) es NULL, y PL/pgSQL trata un IF nulo como falso. "
            "Usa 'IF v_rol IS NULL OR v_rol NOT IN (...)'.",
            rel,
        )

    # Los snapshots son append-only.
    for tabla in TABLAS_APPEND_ONLY:
        if re.search(r"UPDATE\s+" + tabla + r"\b", sql, re.I):
            rep.error(
                "snapshot-append-only",
                "hace UPDATE sobre '" + tabla + "'. Un precio nuevo es un INSERT nuevo.",
                rel,
            )

    # SECURITY DEFINER sin search_path fijo es inyectable. Una migracion
    # posterior puede corregirlo con ALTER FUNCTION, asi que se comprueba el
    # conjunto de migraciones antes de avisar.
    for definer in re.finditer(r"SECURITY\s+DEFINER", sql, re.I):
        ventana = sql[definer.start(): definer.start() + 400]
        if re.search(r"SET\s+search_path", ventana, re.I):
            continue
        anterior = sql[: definer.start()]
        creadas = re.findall(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(\w+)", anterior, re.I)
        if not creadas:
            continue
        funcion = creadas[-1]
        if remediada_en_otra_migracion(funcion):
            continue
        rep.warn(
            "search-path-fijo",
            "la funcion '" + funcion + "' es SECURITY DEFINER sin "
            "'SET search_path = public, pg_temp' y ninguna migracion lo corrige",
            rel,
        )
        break

    # Referencias a objetos de Supabase que CI no tiene sin el bootstrap.
    usa_auth = re.search(r"\bauth\.(users|uid)\b", sql, re.I)
    usa_roles = re.search(r"\b(anon|authenticated|service_role)\b", sql)
    bootstrap = ROOT / "database" / "ci" / "bootstrap_supabase_roles.sql"
    if (usa_auth or usa_roles) and not bootstrap.exists():
        rep.warn(
            "ci-bootstrap",
            "referencia objetos de Supabase (auth.* o roles) y no existe "
            "database/ci/bootstrap_supabase_roles.sql; CI corre sobre postgres limpio",
            rel,
        )


def auditar_web(path: Path, rep: Reporte) -> None:
    rel = str(path.relative_to(ROOT)).replace("\\", "/")
    texto = path.read_text(encoding="utf-8", errors="replace")
    if re.search(r"service_role|SUPABASE_SERVICE_ROLE_KEY", texto):
        rep.error(
            "service-role-en-web",
            "menciona service_role. La consola es de lectura y usa la sesion "
            "del usuario; la clave privilegiada no entra en web/.",
            rel,
        )


def auditar_secretos(path: Path, rep: Reporte) -> None:
    """Evita que una clave real termine versionada."""
    rel = str(path.relative_to(ROOT)).replace("\\", "/")
    if path.name == ".env.example" or path.suffix == ".md":
        return
    if rel == "scripts/audit_change.py":
        return  # un detector contiene por fuerza los patrones que detecta
    texto = path.read_text(encoding="utf-8", errors="replace")
    patrones = [
        (r"\bsb_secret_[A-Za-z0-9_\-]{10,}", "clave secreta de Supabase"),
        (r"\beyJ[A-Za-z0-9_\-]{30,}\.[A-Za-z0-9_\-]{20,}", "JWT literal"),
    ]
    for patron, que in patrones:
        if re.search(patron, texto):
            rep.error("secreto-en-codigo", "contiene lo que parece ser " + que, rel)

    # Las cadenas de conexion necesitan mas contexto que un regex plano: el
    # contenedor de tests de CI usa postgres:postgres@localhost a proposito, y
    # los ejemplos usan marcadores en mayusculas. Nada de eso es un secreto.
    hosts_desechables = ("localhost", "127.0.0.1", "postgres", "db")
    claves_marcador = ("postgres", "password", "changeme", "secret", "clave")
    for m in re.finditer(r"postgresql://([^:\s]+):([^@\s]{4,})@([^/\s:]+)", texto):
        clave, host = m.group(2), m.group(3)
        if host in hosts_desechables or host.endswith(".example.com"):
            continue
        if clave.lower() in claves_marcador or clave.isupper() or clave.startswith("your-"):
            continue
        rep.error(
            "secreto-en-codigo",
            "contiene una cadena de conexion con contrasena real hacia " + host,
            rel,
        )


def correr_tests_python(rep: Reporte) -> None:
    try:
        proc = subprocess.run(
            [sys.executable, "-m", "unittest", "discover", "-s", "tests"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=180,
        )
    except subprocess.TimeoutExpired:
        rep.warn("tests-python", "los tests de Python excedieron 180 s y no se pudo concluir")
        return
    if proc.returncode != 0:
        cola = (proc.stderr or proc.stdout).strip().splitlines()
        resumen = " | ".join(cola[-6:]) if cola else "sin salida"
        rep.error("tests-python", "la suite de tests falla: " + resumen)


def ruta_desde_stdin() -> str | None:
    """Modo hook: extrae la ruta del archivo del JSON que envia el harness.

    No depende de jq, que no siempre existe en Windows. Cualquier entrada
    malformada devuelve None para que el hook no rompa la sesion.
    """
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(payload, dict):
        return None
    respuesta = payload.get("tool_response")
    if isinstance(respuesta, dict) and respuesta.get("filePath"):
        return str(respuesta["filePath"])
    entrada = payload.get("tool_input")
    if isinstance(entrada, dict) and entrada.get("file_path"):
        return str(entrada["file_path"])
    return None


def archivos_a_auditar(args: argparse.Namespace) -> list[Path]:
    if args.all:
        objetivos: list[Path] = []
        for patron in (
            "database/migrations/*.sql",
            "web/**/*.ts",
            "web/**/*.tsx",
            "scripts/**/*.py",
        ):
            objetivos.extend(ROOT.glob(patron))
        return sorted(set(objetivos))
    if not args.file:
        return []
    p = Path(args.file)
    if not p.is_absolute():
        p = (ROOT / p).resolve()
    return [p] if p.exists() else []


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", help="archivo cambiado a auditar")
    parser.add_argument("--all", action="store_true", help="auditar todo el repositorio")
    parser.add_argument("--json", action="store_true", help="salida JSON para el hook")
    parser.add_argument(
        "--hook",
        action="store_true",
        help="leer la ruta del archivo desde el JSON de stdin (implica --json)",
    )
    args = parser.parse_args()

    if args.hook:
        args.json = True
        if not args.file:
            args.file = ruta_desde_stdin()
            if not args.file:
                return 0  # nada que auditar: el hook no debe entorpecer la sesion

    rep = Reporte()
    objetivos = archivos_a_auditar(args)
    corrio_tests = False

    for path in objetivos:
        try:
            rel_parts = path.relative_to(ROOT).parts
        except ValueError:
            continue  # fuera del repositorio: no es asunto de esta auditoria

        # Dependencias y artefactos de build no son codigo del proyecto. El SDK
        # de Supabase menciona la clave privilegiada en sus propios tipos, que
        # es legitimo y no dice nada sobre lo que hace esta consola.
        if any(p in IGNORADOS for p in rel_parts):
            continue

        if rel_parts[:2] == ("database", "migrations") and path.suffix == ".sql":
            auditar_migracion(path, rep)
        if rel_parts[0] == "web" and path.suffix in (".ts", ".tsx", ".js", ".jsx", ".mjs"):
            auditar_web(path, rep)
        if path.suffix in (".py", ".sql", ".ts", ".tsx", ".ps1", ".json", ".yml", ".yaml"):
            auditar_secretos(path, rep)
        if path.suffix == ".py" and not corrio_tests:
            correr_tests_python(rep)
            corrio_tests = True

    if args.json:
        if rep.hallazgos:
            lineas = [
                h.severidad + ": " + h.regla + " - " + (h.archivo or "repo") + ": " + h.detalle
                for h in rep.hallazgos
            ]
            cuerpo = "Auditoria Estampados:\n" + "\n".join(lineas)
            salida = {"systemMessage": cuerpo}
            if rep.errores:
                salida["decision"] = "block"
                salida["reason"] = cuerpo + "\n\nCorrige estos ERROR antes de continuar."
            # ensure_ascii evita que la consola de Windows corrompa la salida.
            print(json.dumps(salida, ensure_ascii=True))
        return 1 if rep.errores else 0

    if not objetivos:
        print("Nada que auditar.")
        return 0
    if not rep.hallazgos:
        print("OK - " + str(len(objetivos)) + " archivo(s) auditado(s), sin hallazgos.")
        return 0
    for h in rep.hallazgos:
        print(h.severidad + ": " + h.regla + " - " + (h.archivo or "repo") + ": " + h.detalle)
    print("\nErrores: " + str(len(rep.errores)) + "  Advertencias: " + str(len(rep.advertencias)))
    return 1 if rep.errores else 0


if __name__ == "__main__":
    sys.exit(main())
