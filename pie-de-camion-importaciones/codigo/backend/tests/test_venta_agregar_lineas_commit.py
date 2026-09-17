"""agregar-lineas: qué pasa cuando el COMMIT contra Macrosoft queda en duda,
y el contrato textual del candado anti-carrera.

Reglas cubiertas (docs/tests/inventario-reglas.md):
  R153 — ante fallo indeterminado de commit, agregar-lineas hace READBACK con
         conexión fresca: líneas aparecieron → COMPLETAR la reserva (el retry
         cae en la rama idempotente); nada apareció → liberar la reserva;
         readback falló → reserva "a medias" (revisión humana, nunca duplicar)
  R151 (mitad automatizable) — SET LOCK_TIMEOUT 5000 va ANTES del SELECT del
         cabezal, que lleva UPDLOCK+HOLDLOCK y FACTURADO=0 AND ANULADA=0.
         La espera real del lock y su corte a los 5s son semántica de SQL
         Server vivo — acá se fija el contrato para que nadie lo desarme.
  R150 (mitad automatizable) — el SYNC del cabezal recalcula DESDE las líneas
         y solo pisa cabezales todavía EN CAJA (FACTURADO=0 AND ANULADA=0).
         La aritmética ejecutada es T-SQL (CROSS APPLY) contra SQL Server.

Patrón de la suite: cursores falsos patcheados en app.modules.venta.router;
el commit en duda se simula con un context manager que revienta al SALIR del
with (exactamente donde commitea el cursor real).
"""
from contextlib import contextmanager
from datetime import datetime
from unittest.mock import patch

import pytest
from fastapi import HTTPException

from app.modules.venta import queries as q
from app.modules.venta.router import agregar_lineas
from app.modules.venta.schemas import AgregarLineasInput, LineaPedidoInput
from tests.factories import usuario_operario

REF = "33333333-3333-3333-3333-333333333333"

ARTICULOS = {"010101": {"cod": "010101", "descripcion": "Banana Brasil", "iva_tasa": 0.22}}
ESPEJO_OK = {"codcliente": 123, "anulada": 0, "facturado": 0, "es_de_hoy": True}
LINEA_NUEVA = {"ID": 501, "Fecha": datetime(2026, 8, 13), "Documento": "30  ",
               "NroFact": 93001, "NroDoc": "93006", "Deposito": "B",
               "CodArt": "010101", "Descripcion": "Banana Brasil",
               "CantidadHaber": 5, "Precio": 100, "TotalLinea": 500}


def _fetch_falso(sql, params=None):
    if "legacy.articulos" in sql:
        return ARTICULOS.get(params[0])
    if "FROM legacy.cabezal2" in sql:
        return ESPEJO_OK
    if "SUM(l.totallinea)" in sql:
        return {"total": 4321.0}
    raise AssertionError(f"fetch_one inesperado en el test: {sql[:80]}")


class CursorMsFalso:
    """Cursor MSSQL falso del flujo de agregar-líneas (contesta lo justo)."""

    def __init__(self):
        self.ejecutado: list[tuple[str, tuple | None]] = []
        self._resp: dict | None = None

    def execute(self, sql, params=None):
        self.ejecutado.append((sql, params))
        if "FROM Cabezal2 WITH (UPDLOCK" in sql:
            self._resp = {"NROFACT": 93001, "NRODOC": "93006",
                          "FECHA": datetime(2026, 8, 13), "MONEDA": 1,
                          "CODCLIENTE": 123, "NOMBRE": "ALMACEN MARTINEZ"}
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


class CursorPgFalso:
    def __init__(self):
        self.ejecutado: list[tuple[str, tuple | None]] = []
        self.rowcount = 1
        self._resp = None

    def execute(self, sql, params=None):
        self.ejecutado.append((sql, params))

    def fetchone(self):
        return self._resp

    def sqls(self) -> list[str]:
        return [s for s, _ in self.ejecutado]


class _SettingsFalso:
    venta_escribe_macrosoft_real = True


@contextmanager
def _ctx(cursor):
    yield cursor


@contextmanager
def _ctx_commit_en_duda(cursor):
    """Todo el trabajo del with sale bien; la explosión es AL COMMITEAR (corte
    de red en el peor momento): el router no sabe si Macrosoft persistió."""
    yield cursor
    raise RuntimeError("se cortó la red durante el commit")


def _body() -> AgregarLineasInput:
    return AgregarLineasInput(
        lineas=[LineaPedidoInput(cod_art="010101", cantidad=5, precio=100)],
        ref=REF, cliente_cod=123,
    )


def _correr_con_commit_en_duda(readback):
    """Ejecuta agregar_lineas con el commit MSSQL en duda y devuelve el cursor
    PG (para assertar qué pasó con la reserva). `readback` es lo que contesta
    la conexión fresca de verificación (lista, o excepción)."""
    pg, ms = CursorPgFalso(), CursorMsFalso()
    llamadas = []

    def _venta_fetch_all(sql, params=None):
        llamadas.append((sql, params))
        if isinstance(readback, Exception):
            raise readback
        return readback

    with (
        patch("app.modules.venta.router.settings", _SettingsFalso()),
        patch("app.modules.venta.router.fetch_one", side_effect=_fetch_falso),
        patch("app.modules.venta.router.get_cursor", lambda: _ctx(pg)),
        patch("app.modules.venta.router.get_venta_cursor", lambda: _ctx_commit_en_duda(ms)),
        patch("app.modules.venta.router.venta_fetch_all", side_effect=_venta_fetch_all),
    ):
        with pytest.raises(RuntimeError, match="commit"):
            agregar_lineas(93001, _body(), usuario_operario("venta"))
    return pg, llamadas


# ── R153: las tres salidas del commit en duda ───────────────────────────────

def test_readback_con_lineas_completa_la_reserva():
    """Regla R153: el readback (conexión FRESCA, desde el max_id previo) trae
    líneas → el commit ENTRÓ: se completa la reserva para que el reintento del
    mismo ref caiga en la rama idempotente y NO inserte de nuevo."""
    pg, llamadas = _correr_con_commit_en_duda(readback=[LINEA_NUEVA])

    assert any("SET nro_fact" in s for s in pg.sqls()), "no completó la reserva"
    assert not any("DELETE FROM ext.venta_envio" in s for s in pg.sqls())
    # El readback arranca en el max_id ANTERIOR a los INSERT (500, del fake).
    assert llamadas[0][1] == (93001, 500)


def test_readback_vacio_libera_la_reserva():
    """Regla R153: el readback no trae nada → rollback real en Macrosoft: se
    libera la reserva y el vendedor puede reintentar con el mismo ref."""
    pg, _ = _correr_con_commit_en_duda(readback=[])

    assert any("DELETE FROM ext.venta_envio" in s for s in pg.sqls())
    assert not any("SET nro_fact" in s for s in pg.sqls())


def test_readback_fallido_deja_la_reserva_a_medias():
    """Regla R153: ni el readback pudimos hacer (Macrosoft caído del todo) →
    la reserva queda "a medias" A PROPÓSITO: el retry da 409 de revisión
    humana. Liberar acá habilitaría duplicar bultos; completar mentiría."""
    pg, _ = _correr_con_commit_en_duda(readback=RuntimeError("macrosoft caído"))

    assert not any("DELETE FROM ext.venta_envio" in s for s in pg.sqls())
    assert not any("SET nro_fact" in s for s in pg.sqls())


def test_el_guard_propio_libera_sin_readback():
    """Regla R153 (borde): una HTTPException NUESTRA (acá: el pedido es de
    descuentos) no es un commit en duda — libera directo, sin readback."""
    class CursorMsSoloDto(CursorMsFalso):
        def execute(self, sql, params=None):
            super().execute(sql, params)
            if "AS n_dto" in sql:
                self._resp = {"n": 2, "n_dto": 2, "max_id": 500}   # solo descuentos

    pg, ms_dto = CursorPgFalso(), CursorMsSoloDto()
    llamadas = []
    with (
        patch("app.modules.venta.router.settings", _SettingsFalso()),
        patch("app.modules.venta.router.fetch_one", side_effect=_fetch_falso),
        patch("app.modules.venta.router.get_cursor", lambda: _ctx(pg)),
        patch("app.modules.venta.router.get_venta_cursor", lambda: _ctx(ms_dto)),
        patch("app.modules.venta.router.venta_fetch_all",
              side_effect=lambda *a: llamadas.append(a)),
    ):
        with pytest.raises(HTTPException) as ctx:
            agregar_lineas(93001, _body(), usuario_operario("venta"))

    assert ctx.value.status_code == 400
    assert llamadas == [], "un guard propio no necesita readback"
    assert any("DELETE FROM ext.venta_envio" in s for s in pg.sqls())


# ── R151 + R150: el contrato textual del candado y del SYNC ─────────────────

def test_lock_timeout_va_antes_del_select_con_updlock():
    """Regla R151 (mitad automatizable): en el flujo real el SET LOCK_TIMEOUT
    se ejecuta ANTES del SELECT del cabezal, y ese SELECT lleva UPDLOCK+
    HOLDLOCK con FACTURADO=0 AND ANULADA=0 — si caja ya facturó no hay fila
    (→ 409, cubierto en test_venta_agregar_lineas) y si está facturando, el
    lock corta a los 5s en vez de colgar la tablet."""
    pg, ms = CursorPgFalso(), CursorMsFalso()
    with (
        patch("app.modules.venta.router.settings", _SettingsFalso()),
        patch("app.modules.venta.router.fetch_one", side_effect=_fetch_falso),
        patch("app.modules.venta.router.get_cursor", lambda: _ctx(pg)),
        patch("app.modules.venta.router.get_venta_cursor", lambda: _ctx(ms)),
        patch("app.modules.venta.router.venta_fetch_all", return_value=[]),
    ):
        agregar_lineas(93001, _body(), usuario_operario("venta"))

    sqls = ms.sqls()
    pos_timeout = next(i for i, s in enumerate(sqls) if "SET LOCK_TIMEOUT" in s)
    pos_lock = next(i for i, s in enumerate(sqls) if "FROM Cabezal2 WITH (UPDLOCK" in s)
    pos_insert = next(i for i, s in enumerate(sqls) if "INSERT INTO Lineas2" in s)
    assert pos_timeout < pos_lock < pos_insert

    assert q.SET_LOCK_TIMEOUT_MSSQL.strip() == "SET LOCK_TIMEOUT 5000"
    for fragmento in ("UPDLOCK", "HOLDLOCK", "FACTURADO = 0", "ANULADA = 0"):
        assert fragmento in q.LOCK_PEDIDO_EN_CAJA_MSSQL, f"el candado perdió {fragmento}"


def test_sync_recalcula_desde_lineas_y_solo_pisa_en_caja():
    """Regla R150 (mitad automatizable): el SYNC del cabezal es un RECÁLCULO
    desde Lineas2 (SUM de CantidadHaber/TotalSinIva/IvaLinea/TotalLinea →
    UNIDADES/SUBTOTALDEBE/IVADEBE/TOTALDEBE, con SALDO=TOTALDEBE) y NUNCA
    toca un cabezal que ya salió de caja (FACTURADO=0 AND ANULADA=0). La
    igualdad TOTALDEBE == SUM(TotalLinea) ejecutada es T-SQL contra SQL
    Server real (no automatizable acá)."""
    sync = q.SYNC_TOTALES_CABEZAL_MSSQL
    for fragmento in ("SUM(l.CantidadHaber)", "SUM(l.TotalSinIva)",
                      "SUM(l.IvaLinea)", "SUM(l.TotalLinea)",
                      "TOTALDEBE    = x.t", "SALDO        = x.t",
                      "FACTURADO = 0", "ANULADA = 0"):
        assert fragmento in sync, f"el SYNC perdió {fragmento}"
