"""POST /venta/pedidos/{nro}/agregar-lineas (caso A) contra cursores falsos.

Dos contratos acá son incidentes reales de prod: el prefijo YA_FACTURADO del
409 (el ÚNICO que autoriza al front a auto-convertir en encadenado — regla
R152) y el SYNC de totales del cabezal (bug del pedido 93049 — regla R149:
caja factura por el cabezal, lo agregado sin sincronizar no se cobraba).
"""
from contextlib import contextmanager
from datetime import datetime
from unittest.mock import patch

import pytest
from fastapi import HTTPException

from app.modules.venta.router import agregar_lineas
from app.modules.venta.schemas import AgregarLineasInput, LineaPedidoInput
from tests.factories import usuario_operario

REF = "22222222-2222-2222-2222-222222222222"

ARTICULOS = {
    "010101": {"cod": "010101", "descripcion": "Banana Brasil", "iva_tasa": 0.22},
    "D01": {"cod": "D01", "descripcion": "Dto. Bananas madera", "iva_tasa": 0.22},
}

ESPEJO_OK = {"codcliente": 123, "anulada": 0, "facturado": 0, "es_de_hoy": True}


def _fetch_falso(espejo):
    def fetch(sql, params=None):
        if "legacy.articulos" in sql:
            return ARTICULOS.get(params[0])
        if "FROM legacy.cabezal2" in sql:
            return espejo
        if "SUM(l.totallinea)" in sql:
            return {"total": 4321.0}
        raise AssertionError(f"fetch_one inesperado en el test: {sql[:80]}")
    return fetch


class CursorAgregarFalso:
    """Cursor MSSQL falso para el flujo de agregar-líneas."""

    def __init__(self, en_caja=True):
        self.ejecutado: list[tuple[str, tuple | None]] = []
        # None = caja ya lo facturó (el SELECT con FACTURADO=0 no trae fila).
        self._cab = (
            {"NROFACT": 93001, "NRODOC": "93006", "FECHA": datetime(2026, 8, 12),
             "MONEDA": 1, "CODCLIENTE": 123, "NOMBRE": "ALMACEN MARTINEZ"}
            if en_caja else None
        )
        self._resp: dict | None = None

    def execute(self, sql, params=None):
        self.ejecutado.append((sql, params))
        if "FROM Cabezal2 WITH (UPDLOCK" in sql:
            self._resp = self._cab
        elif "AS n_dto" in sql:
            self._resp = {"n": 2, "n_dto": 0, "max_id": 500}
        elif "TOP 1 RTRIM(Deposito)" in sql:
            self._resp = {"deposito": "B"}
        else:
            self._resp = None

    def fetchone(self):
        return self._resp

    def sqls(self) -> list[str]:
        return [s for s, _ in self.ejecutado]

    def params_de(self, fragmento: str) -> tuple | None:
        for s, p in self.ejecutado:
            if fragmento in s:
                return p
        return None


class CursorPgFalso:
    def __init__(self, reserva_ok=True, envio: dict | None = None):
        self.ejecutado: list[tuple[str, tuple | None]] = []
        self.rowcount = 1 if reserva_ok else 0
        self._envio = envio
        self._resp: dict | None = None

    def execute(self, sql, params=None):
        self.ejecutado.append((sql, params))
        self._resp = self._envio if "FROM ext.venta_envio" in sql else None

    def fetchone(self):
        return self._resp

    def sqls(self) -> list[str]:
        return [s for s, _ in self.ejecutado]


class _SettingsFalso:
    venta_escribe_macrosoft_real = True


@contextmanager
def _ctx(cursor):
    yield cursor


def _body(cods=("010101",)) -> AgregarLineasInput:
    return AgregarLineasInput(
        lineas=[LineaPedidoInput(cod_art=c, cantidad=5, precio=100) for c in cods],
        ref=REF,
        cliente_cod=123,
    )


def _correr(body=None, pg=None, ms=None, espejo=ESPEJO_OK, nro_fact=93001):
    pg = pg if pg is not None else CursorPgFalso()
    ms = ms if ms is not None else CursorAgregarFalso()
    with (
        patch("app.modules.venta.router.settings", _SettingsFalso()),
        patch("app.modules.venta.router.fetch_one", side_effect=_fetch_falso(espejo)),
        patch("app.modules.venta.router.get_cursor", lambda: _ctx(pg)),
        patch("app.modules.venta.router.get_venta_cursor", lambda: _ctx(ms)),
        patch("app.modules.venta.router.venta_fetch_all", return_value=[]),
    ):
        return agregar_lineas(nro_fact, body or _body(), usuario_operario("venta"))


# ── El contrato del 409 (regla R152) ────────────────────────────────────────

def test_pedido_ya_facturado_409_con_prefijo_ya_facturado():
    """Regla R152: el 409 de 'caja ya lo facturó' lleva el prefijo ESTABLE
    'YA_FACTURADO:' — es el marcador que autoriza al front a ofrecer el
    pedido ENCADENADO (caso B)."""
    pg, ms = CursorPgFalso(), CursorAgregarFalso(en_caja=False)
    with pytest.raises(HTTPException) as ctx:
        _correr(pg=pg, ms=ms)
    assert ctx.value.status_code == 409
    assert ctx.value.detail.startswith("YA_FACTURADO:")
    # El guard propio (HTTPException) libera la reserva: el ref queda reusable.
    assert any("DELETE FROM ext.venta_envio" in s for s in pg.sqls())


def test_el_409_de_idempotencia_no_lleva_el_prefijo():
    """Regla R152: el 409 de 'envío en curso/a medias' NO puede llevar el
    prefijo — si el front lo convirtiera en encadenado duplicaría mercadería
    (el envío original puede estar todavía en vuelo)."""
    pg = CursorPgFalso(reserva_ok=False, envio={"ref": REF, "nro_fact": None,
                                                "nro_doc": None, "total": None})
    ms = CursorAgregarFalso()
    with pytest.raises(HTTPException) as ctx:
        _correr(pg=pg, ms=ms)
    assert ctx.value.status_code == 409
    assert not ctx.value.detail.startswith("YA_FACTURADO")
    assert ms.ejecutado == [], "un envío en vuelo no puede volver a tocar Macrosoft"


def test_reintento_ya_completado_responde_con_el_total_real_del_espejo():
    """Regla R147: el reintento de un agregado que YA entró devuelve lo
    guardado, con el total del pedido leído del espejo (0 acá pintaba
    'totaliza $0' en la tablet)."""
    pg = CursorPgFalso(reserva_ok=False, envio={"ref": REF, "nro_fact": 93001,
                                                "nro_doc": "93006", "total": 500.0})
    ms = CursorAgregarFalso()
    out = _correr(pg=pg, ms=ms)
    assert out.nro_fact == 93001
    assert out.total_agregado == 500.0
    assert out.total_pedido == 4321.0    # TOTAL_LINEAS_ESPEJO_SQL, no 0
    assert ms.ejecutado == []


# ── Candados de destino (regla R155, parte espejo) ──────────────────────────

def test_pedido_de_otro_cliente_400_sin_reservar():
    """Regla R155: el destino se valida contra el espejo (cliente) ANTES de
    reservar el ref o tocar Macrosoft — candado anti borrador viejo."""
    pg, ms = CursorPgFalso(), CursorAgregarFalso()
    with pytest.raises(HTTPException) as ctx:
        _correr(pg=pg, ms=ms, espejo={**ESPEJO_OK, "codcliente": 999})
    assert ctx.value.status_code == 400
    assert "OTRO cliente" in ctx.value.detail
    assert pg.ejecutado == [] and ms.ejecutado == []


def test_pedido_que_no_es_de_hoy_409_ya_facturado():
    """Regla R155: a un pedido viejo no se le agregan líneas; el front lo
    resuelve ofreciendo encadenar (por eso el prefijo YA_FACTURADO)."""
    with pytest.raises(HTTPException) as ctx:
        _correr(espejo={**ESPEJO_OK, "es_de_hoy": False})
    assert ctx.value.status_code == 409
    assert ctx.value.detail.startswith("YA_FACTURADO:")


def test_pedido_inexistente_404():
    with pytest.raises(HTTPException) as ctx:
        _correr(espejo=None)
    assert ctx.value.status_code == 404


def test_no_se_agregan_descuentos_400():
    """Regla R159: los D% van en pedido aparte, tampoco se AGREGAN a uno de
    mercadería."""
    pg, ms = CursorPgFalso(), CursorAgregarFalso()
    with pytest.raises(HTTPException) as ctx:
        _correr(body=_body(cods=("D01",)), pg=pg, ms=ms)
    assert ctx.value.status_code == 400
    assert pg.ejecutado == [] and ms.ejecutado == []


# ── Éxito: el SYNC del cabezal (regla R149) ─────────────────────────────────

def test_exito_sincroniza_los_totales_del_cabezal_tras_los_inserts():
    """Regla R149 (bug 93049): tras insertar, el cabezal se recalcula desde las
    líneas DENTRO de la misma transacción — caja factura por el cabezal."""
    ms = CursorAgregarFalso()
    out = _correr(ms=ms)

    assert out.nro_fact == 93001
    assert out.lineas_agregadas == 1
    sqls = ms.sqls()
    pos_insert = max(i for i, s in enumerate(sqls) if "INSERT INTO Lineas2" in s)
    pos_sync = next(i for i, s in enumerate(sqls) if "SET UNIDADES" in s)
    assert pos_sync > pos_insert, "el SYNC va después de los INSERT, misma tx"
    assert ms.params_de("SET UNIDADES") == (93001,)


def test_las_lineas_nuevas_copian_deposito_y_nrodoc_del_pedido():
    """Contrato nativo (reglas R142/R149): la línea agregada copia el NRODOC
    del cabezal (no el NROFACT) y el depósito de la última línea existente —
    exactamente como edita el tomador viejo."""
    ms = CursorAgregarFalso()
    _correr(ms=ms)

    linea = ms.params_de("INSERT INTO Lineas2")
    assert linea[1] == 93001      # NroFact
    assert linea[2] == "93006"    # NroDoc del cabezal
    assert linea[3] == "B"        # depósito heredado de las líneas, no 'A' fijo
