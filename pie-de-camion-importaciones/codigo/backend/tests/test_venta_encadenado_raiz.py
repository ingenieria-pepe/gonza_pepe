"""POST /venta/pedidos con `agregado_de` (caso B: pedido ENCADENADO).

Regla cubierta (docs/tests/inventario-reglas.md):
  R154 — el pedido encadenado siempre se re-apunta a la RAÍZ del grupo (si el
         elegido ya es un agregado, se sube a SU original — grupo de raíz
         única, mig 0062); y solo se encadena a originales de HOY, no
         anulados y del MISMO cliente — validado ANTES de escribir nada.

Patrón mixto de la suite: PG real vía pg_tx (espejo + ext.pedido_agregado +
reserva de idempotencia) y el lado Macrosoft con cursor falso patcheado en
app.modules.venta.router (regla dura: cero SQL Server en tests).
"""
import itertools
import uuid
from contextlib import contextmanager

import pytest
from fastapi import HTTPException

from tests import factories
from tests.integration.helpers_expedicion import usuario_db

_NEXT_FACT = itertools.count(940_001)

CLIENTE = 88200
OTRO_CLIENTE = 88300


class CursorVentaFalso:
    """Cursor MSSQL falso (patrón test_venta_crear_pedido): numera y registra."""

    def __init__(self, next_fact: int):
        self.ejecutado: list[tuple[str, tuple | None]] = []
        self._next_fact = next_fact
        self._resp: dict | None = None

    def execute(self, sql, params=None):
        self.ejecutado.append((sql, params))
        if "next_fact" in sql:
            self._resp = {"next_fact": self._next_fact}
        elif "NroDocumento FROM Documentos" in sql:
            self._resp = {"NroDocumento": 4000}
        else:
            self._resp = None

    def fetchone(self):
        return self._resp


class _SettingsFalso:
    venta_escribe_macrosoft_real = True


@contextmanager
def _ctx(cursor):
    yield cursor


@pytest.fixture
def vendedor(pg_tx):
    """Usuario real (FKs de meta/envío) con código de vendedor y el cliente
    del espejo que el pedido copia."""
    u = usuario_db(pg_tx, "venta")
    factories.insertar(pg_tx, "ext.venta_vendedor", usuario_id=u["id"], vendedor=7)
    factories.insertar(pg_tx, "legacy.clientes",
                       codcliente=CLIENTE, nombre="CLIENTE ENCADENA",
                       tiposprecios=2, moneda=1)
    factories.insertar(pg_tx, "legacy.articulos",
                       codarticulo="010101", descripcion="BANANA ECUADOR")
    return factories.usuario_operario("venta", id=u["id"])


def _body(agregado_de: int):
    from app.modules.venta.schemas import LineaPedidoInput, PedidoVentaCreate
    return PedidoVentaCreate(
        cliente_cod=CLIENTE,
        lineas=[LineaPedidoInput(cod_art="010101", cantidad=5, precio=100)],
        ref=str(uuid.uuid4()),
        agregado_de=agregado_de,
    )


def _crear(monkeypatch, body, user):
    from app.modules.venta import router as vr

    ms = CursorVentaFalso(next_fact=next(_NEXT_FACT))
    monkeypatch.setattr(vr, "settings", _SettingsFalso())
    monkeypatch.setattr(vr, "get_venta_cursor", lambda: _ctx(ms))
    monkeypatch.setattr(vr, "venta_fetch_all", lambda *a, **kw: [])  # dual-write no-op
    return vr.crear_pedido(body, user), ms


def _raiz_de(conn, nro_fact: int) -> int | None:
    with conn.cursor() as cur:
        cur.execute("SELECT nro_fact_original FROM ext.pedido_agregado "
                    "WHERE documento = '30  ' AND nro_fact = %s", (nro_fact,))
        row = cur.fetchone()
        return row[0] if row else None


def _original_de_hoy(pg_tx, **extra) -> dict:
    from datetime import date
    base = dict(cliente=CLIENTE, fecha=date.today(), facturado=1, anulada=0, lineas=())
    base.update(extra)
    return factories.pedido(pg_tx, **base)


# ── R154: siempre a la raíz ─────────────────────────────────────────────────

def test_encadenar_a_un_agregado_reapunta_a_la_raiz(pg_tx, monkeypatch, vendedor):
    """Regla R154: el vendedor eligió el pedido B — que YA es agregado de A.
    El nuevo pedido NO se encadena a B: se sube a la raíz A (grupo de raíz
    única; si no, mover/entregar la cadena dejaría colas colgadas)."""
    raiz = _original_de_hoy(pg_tx)
    agregado_previo = _original_de_hoy(pg_tx)
    factories.insertar(pg_tx, "ext.pedido_agregado",
                       documento="30  ", nro_fact=agregado_previo["nro_fact"],
                       nro_fact_original=raiz["nro_fact"], creado_por=vendedor.id)

    out, _ = _crear(monkeypatch, _body(agregado_de=agregado_previo["nro_fact"]), vendedor)

    assert _raiz_de(pg_tx, out.nro_fact) == raiz["nro_fact"]   # A, no B


def test_encadenar_directo_al_original(pg_tx, monkeypatch, vendedor):
    """Regla R154 (caso simple): el elegido no es agregado de nadie → él mismo
    es la raíz del vínculo nuevo."""
    original = _original_de_hoy(pg_tx)

    out, _ = _crear(monkeypatch, _body(agregado_de=original["nro_fact"]), vendedor)

    assert _raiz_de(pg_tx, out.nro_fact) == original["nro_fact"]


# ── R154: candados del original, ANTES de escribir nada ─────────────────────

def _sin_efectos(pg_tx, ms, ref: str):
    """Ni Macrosoft tocado ni ref reservado: el candado corre antes de todo."""
    assert ms.ejecutado == []
    with pg_tx.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM ext.venta_envio WHERE ref = %s", (ref,))
        assert cur.fetchone()[0] == 0


def test_original_de_ayer_409_sin_escribir(pg_tx, monkeypatch, vendedor):
    """Regla R154: un agregado se encadena solo a pedidos de HOY — el de ayer
    ya se facturó/entregó y encadenarle carga nueva mentiría en toda la
    operativa. 409 con el porqué, sin reservar ref ni tocar Macrosoft."""
    from datetime import date, timedelta
    viejo = _original_de_hoy(pg_tx, fecha=date.today() - timedelta(days=1))
    body = _body(agregado_de=viejo["nro_fact"])

    from app.modules.venta import router as vr
    ms = CursorVentaFalso(next_fact=next(_NEXT_FACT))
    monkeypatch.setattr(vr, "settings", _SettingsFalso())
    monkeypatch.setattr(vr, "get_venta_cursor", lambda: _ctx(ms))
    with pytest.raises(HTTPException) as ctx:
        vr.crear_pedido(body, vendedor)

    assert ctx.value.status_code == 409
    assert "HOY" in ctx.value.detail
    _sin_efectos(pg_tx, ms, body.ref)


def test_original_anulado_409(pg_tx, monkeypatch, vendedor):
    """Regla R154: a un original ANULADO no se le encadena nada — el mensaje
    manda a crear un pedido normal."""
    anulado = _original_de_hoy(pg_tx, anulada=1)
    body = _body(agregado_de=anulado["nro_fact"])

    from app.modules.venta import router as vr
    ms = CursorVentaFalso(next_fact=next(_NEXT_FACT))
    monkeypatch.setattr(vr, "settings", _SettingsFalso())
    monkeypatch.setattr(vr, "get_venta_cursor", lambda: _ctx(ms))
    with pytest.raises(HTTPException) as ctx:
        vr.crear_pedido(body, vendedor)

    assert ctx.value.status_code == 409
    assert "anulado" in ctx.value.detail.lower()
    _sin_efectos(pg_tx, ms, body.ref)


def test_original_de_otro_cliente_400(pg_tx, monkeypatch, vendedor):
    """Regla R154: encadenar cruza SOLO dentro del mismo cliente — un número
    tipeado mal no cuelga la carga de un tercero."""
    ajeno = _original_de_hoy(pg_tx, cliente=OTRO_CLIENTE)
    body = _body(agregado_de=ajeno["nro_fact"])

    from app.modules.venta import router as vr
    ms = CursorVentaFalso(next_fact=next(_NEXT_FACT))
    monkeypatch.setattr(vr, "settings", _SettingsFalso())
    monkeypatch.setattr(vr, "get_venta_cursor", lambda: _ctx(ms))
    with pytest.raises(HTTPException) as ctx:
        vr.crear_pedido(body, vendedor)

    assert ctx.value.status_code == 400
    assert "OTRO cliente" in ctx.value.detail
    _sin_efectos(pg_tx, ms, body.ref)


def test_pedido_normal_no_deja_vinculo(pg_tx, monkeypatch, vendedor):
    """Contra-caso: sin agregado_de no aparece NINGUNA fila en
    ext.pedido_agregado (un pedido común no arma cadenas fantasma)."""
    from app.modules.venta.schemas import LineaPedidoInput, PedidoVentaCreate
    body = PedidoVentaCreate(
        cliente_cod=CLIENTE,
        lineas=[LineaPedidoInput(cod_art="010101", cantidad=5, precio=100)],
        ref=str(uuid.uuid4()),
    )

    out, _ = _crear(monkeypatch, body, vendedor)

    assert _raiz_de(pg_tx, out.nro_fact) is None
