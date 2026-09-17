"""Helpers compartidos de los tests de integración de PIE DE CAMIÓN / STOCK.

Patrón de la suite: PG REAL vía pg_tx (ext.* + legacy.* sembrados con
tests/factories) y TODO lo que sale del proceso (S3, webhook de maduración,
SQL Server) patcheado en el namespace que lo usa. Los PDFs se generan con el
reportlab REAL y se asertan con pypdf (cantidad de páginas / texto).
"""
import base64
import itertools
from contextlib import contextmanager
from datetime import date
from io import BytesIO

from tests import factories
from tests.integration.helpers_expedicion import usuario_db

_N = itertools.count(1)


# ── Imágenes / PDFs de verdad ───────────────────────────────────────────────

def jpeg(w: int = 80, h: int = 60, color=(200, 30, 30)) -> bytes:
    """JPEG real (PIL) — reportlab lo embebe tal cual en los PDFs."""
    from PIL import Image

    buf = BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format="JPEG")
    return buf.getvalue()


def data_uri(blob: bytes, mime: str = "image/jpeg") -> str:
    return f"data:{mime};base64,{base64.b64encode(blob).decode()}"


def paginas(pdf_bytes) -> int:
    """Páginas de un PDF (o -1 si no se puede leer). memoryview/bytes."""
    from pypdf import PdfReader

    try:
        return len(PdfReader(BytesIO(bytes(pdf_bytes))).pages)
    except Exception:
        return -1


def texto_pdf(pdf_bytes) -> str:
    from pypdf import PdfReader

    return "\n".join(p.extract_text() or "" for p in PdfReader(BytesIO(bytes(pdf_bytes))).pages)


def pdf_simple(texto: str = "PDF de prueba") -> bytes:
    """Un PDF de 1 página hecho con reportlab (p. ej. para el termógrafo)."""
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen import canvas

    buf = BytesIO()
    c = canvas.Canvas(buf, pagesize=A4)
    c.drawString(72, 720, texto)
    c.showPage()
    c.save()
    return buf.getvalue()


# ── Seeds ───────────────────────────────────────────────────────────────────

COD_BANANA = "010101"
COD_PERA = "020202"


def sembrar_entorno(conn) -> dict:
    """Catálogo mínimo que asume el módulo: artículos del mirror, depósito B
    (el default de ingreso) y un motivo de defecto. Devuelve {'motivo_id': …}."""
    factories.insertar(conn, "legacy.articulos",
                       codarticulo=COD_BANANA, descripcion="BANANA BRASIL")
    factories.insertar(conn, "legacy.articulos",
                       codarticulo=COD_PERA, descripcion="PERA RIO NEGRO")
    factories.insertar(conn, "legacy.deposito",
                       marcado=0, deposito="B", descripcion="ZAC")
    factories.insertar(conn, "legacy.deposito",
                       marcado=0, deposito="C", descripcion="CORONEL RAIZ")
    factories.insertar(conn, "legacy.deposito",
                       marcado=0, deposito="A", descripcion="PUESTO")
    m = factories.insertar(conn, "ext.defecto_motivo",
                           nombre=f"Podrida test {next(_N)}", activo=True)
    return {"motivo_id": m["id"]}


def actor(conn, *permisos: str):
    """CurrentUser respaldado por una fila REAL de ext.usuarios (las FKs
    creado_por/confirmado_por/generado_por lo exigen)."""
    fila = usuario_db(conn, *permisos)
    return factories.usuario(
        id=fila["id"], username=fila["username"],
        permisos=frozenset(permisos),
    )


def body_pie(motivo_id: int | None = None, **overrides) -> dict:
    """Body JSON mínimo válido de POST/PUT /pie-camion. Por default: una línea
    de banana SIN reclamos. Con `motivo_id`, la línea trae un defecto con foto
    (y hay_reclamos=True) → el create genera el reclamo al proveedor."""
    n = next(_N)
    if motivo_id is not None:
        lineas = [{
            "cod_art": COD_BANANA, "cantidad": 100, "hay_reclamos": True,
            "defectos": [{
                "motivo_id": motivo_id, "cantidad": 5, "notas": "cajas golpeadas",
                "fotos": [data_uri(jpeg(color=(30, 120, 30)))],
            }],
        }]
    else:
        lineas = [{"cod_art": COD_BANANA, "cantidad": 100, "hay_reclamos": False}]
    base = {
        "fecha": date.today().isoformat(),
        "chofer_nombre": f"Chofer Test {n}",
        "placa_camion": f"TEST{n:03d}",
        "lineas": lineas,
    }
    base.update(overrides)
    return base


# ── Lecturas de verificación ────────────────────────────────────────────────

def pie_row(conn, pdc_id: int) -> dict:
    import psycopg2.extras

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM ext.pie_de_camion WHERE id = %s", (pdc_id,))
        return dict(cur.fetchone())


def lineas_de(conn, pdc_id: int) -> list[dict]:
    import psycopg2.extras

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT id, BTRIM(cod_art) AS cod_art, cantidad, hay_reclamos "
            "FROM ext.pie_de_camion_linea WHERE pie_camion_id = %s "
            "ORDER BY orden, id", (pdc_id,))
        return [dict(r) for r in cur.fetchall()]


def defectos_de(conn, pdc_id: int) -> list[dict]:
    import psycopg2.extras

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT d.id, d.pie_camion_linea_id, d.motivo_id, d.cantidad, "
            "       d.cantidad_fotos, BTRIM(l.cod_art) AS cod_art "
            "FROM ext.pie_de_camion_defecto d "
            "JOIN ext.pie_de_camion_linea l ON l.id = d.pie_camion_linea_id "
            "WHERE l.pie_camion_id = %s ORDER BY d.id", (pdc_id,))
        return [dict(r) for r in cur.fetchall()]


def reclamo_row(conn, reclamo_id: int) -> dict:
    import psycopg2.extras

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM ext.reclamo WHERE id = %s", (reclamo_id,))
        return dict(cur.fetchone())


# ── Aislamiento de infra externa ────────────────────────────────────────────

def patch_infra(monkeypatch) -> dict:
    """S3 y webhook de maduración patcheados — CERO red real. Devuelve un
    recorder: {'offloads': [(tabla, id, prefix)], 'webhooks': [(evento, id)]}."""
    from app.core import s3
    from app.modules.piedecamion import webhook

    rec = {"offloads": [], "webhooks": []}

    def _offload(tabla, id_, data, prefix, **kw):
        rec["offloads"].append((tabla, id_, prefix))

    def _boom(*_a, **_kw):
        raise AssertionError("el test intentó hablar con S3 de verdad")

    monkeypatch.setattr(s3, "offload_pdf", _offload)
    monkeypatch.setattr(s3, "put", _boom)
    monkeypatch.setattr(s3, "get", _boom)
    monkeypatch.setattr(s3, "delete", _boom)
    monkeypatch.setattr(s3, "_client", _boom)
    monkeypatch.setattr(
        webhook, "enviar_registrado",
        lambda pid: rec["webhooks"].append(("registrado", pid)))
    monkeypatch.setattr(
        webhook, "enviar_ingresado",
        lambda pid: rec["webhooks"].append(("ingresado", pid)))
    return rec


# ── SQL Server falso para el confirmar→ingreso ─────────────────────────────

class CursorMacrosoft:
    """Cursor falso de la conexión CFE (patrón test_ingreso_numeracion):
    registra cada (sql, params) y responde lo justo para la numeración."""

    def __init__(self, ultimo_usado: int | None = 1751, next_nro_fact: int = 90_001,
                 precios: dict[str, float] | None = None):
        self.ejecutado: list[tuple[str, tuple | None]] = []
        self._ultimo_usado = ultimo_usado
        self._next_nro_fact = next_nro_fact
        # Lista de Costo falsa: {cod_art: precio}. Sin entrada → None (=> 0).
        self._precios = precios or {}
        self._resp: dict | None = None

    def execute(self, sql, params=None):
        self.ejecutado.append((sql, params))
        if "MAX(NroFact)" in sql:
            # Incremental: tras cada INSERT de Cabezal el MAX real sube — el
            # par de un viaje necesita DOS NroFact distintos.
            self._resp = {"next_nro": self._next_nro_fact}
            self._next_nro_fact += 1
        elif "ultimo_usado" in sql:
            self._resp = (None if self._ultimo_usado is None
                          else {"ultimo_usado": self._ultimo_usado})
        elif "FROM Precios" in sql:
            precio = self._precios.get((params or ("",))[0])
            self._resp = None if precio is None else {"Precio": precio}
        else:
            self._resp = None

    def fetchone(self):
        return self._resp

    def sqls(self) -> list[str]:
        return [sql for sql, _ in self.ejecutado]

    def params_de(self, fragmento: str) -> tuple | None:
        for sql, params in self.ejecutado:
            if fragmento in sql:
                return params
        return None


@contextmanager
def ctx(cursor):
    yield cursor
