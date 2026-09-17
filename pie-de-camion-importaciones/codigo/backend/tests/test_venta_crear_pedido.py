"""POST /venta/pedidos contra cursores falsos: idempotencia, numeración doble,
contrato del cabezal y regla de descuentos.

No hay Macrosoft en tests (regla dura), así que se verifica la SECUENCIA de SQL
y los parámetros que viajarían — que es exactamente el contrato relevado del
tomador (memoria reference_tomador_pedidos_macrosoft).
"""
import re
from contextlib import contextmanager
from unittest.mock import patch

import pytest
from fastapi import HTTPException
from pydantic import ValidationError

from app.modules.venta import queries as q
from app.modules.venta.router import _es_descuento, crear_pedido
from app.modules.venta.schemas import LineaPedidoInput, PedidoVentaCreate
from tests.factories import usuario_operario

REF = "11111111-1111-1111-1111-111111111111"

CLIENTES = {
    123: {"codcliente": 123, "nombre": "ALMACEN MARTINEZ", "direccion": "RUTA 8 KM 17",
          "ruc": "212345670017", "lista_precio": 2, "moneda": 1},
    456: {"codcliente": 456, "nombre": "PUESTO SIN RUT", "direccion": "",
          "ruc": "", "lista_precio": 2, "moneda": 1},
    999901: {"codcliente": 999901, "nombre": "CONSUMIDOR FINAL", "direccion": "",
             "ruc": "", "lista_precio": 2, "moneda": 1},
}

ARTICULOS = {
    "010101": {"cod": "010101", "descripcion": "Banana Brasil", "iva_tasa": 0.22},
    "D01": {"cod": "D01", "descripcion": "Dto. Bananas madera", "iva_tasa": 0.22},
}


def _fetch_one_falso(sql, params=None):
    if "ext.venta_vendedor" in sql:
        return {"vendedor": 5}
    if "FROM legacy.clientes" in sql:
        return CLIENTES.get(params[0])
    if "legacy.articulos" in sql:
        return ARTICULOS.get(params[0])
    raise AssertionError(f"fetch_one inesperado en el test: {sql[:80]}")


def _fetch_sin_vendedor(sql, params=None):
    if "ext.venta_vendedor" in sql:
        return None
    return _fetch_one_falso(sql, params)


class CursorVentaFalso:
    """Cursor de SQL Server falso: registra (sql, params) y numera lo justo."""

    def __init__(self, next_fact=93001, nrodoc_contador=1751):
        self.ejecutado: list[tuple[str, tuple | None]] = []
        self._next_fact = next_fact
        self._contador = nrodoc_contador
        self._resp: dict | None = None

    def execute(self, sql, params=None):
        self.ejecutado.append((sql, params))
        if "next_fact" in sql:
            self._resp = {"next_fact": self._next_fact}
        elif "NroDocumento FROM Documentos" in sql:
            self._resp = {"NroDocumento": self._contador}
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


class CursorVentaExplota(CursorVentaFalso):
    """Simula el corte de conexión a Macrosoft en pleno INSERT."""

    def execute(self, sql, params=None):
        if "INSERT INTO Cabezal2" in sql:
            raise RuntimeError("se cayó la conexión con Macrosoft")
        super().execute(sql, params)


class CursorPgFalso:
    """Cursor PG falso para la reserva de idempotencia + post-commit."""

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
    def __init__(self, conectado=True):
        self.venta_escribe_macrosoft_real = conectado


@contextmanager
def _ctx(cursor):
    yield cursor


def _body(**ov) -> PedidoVentaCreate:
    base = dict(
        cliente_cod=123,
        lineas=[LineaPedidoInput(cod_art="010101", cantidad=10, precio=100)],
        ref=REF,
    )
    base.update(ov)
    return PedidoVentaCreate(**base)


def _correr(body, pg=None, ms=None, fetch=None, settings=None, user=None):
    pg = pg if pg is not None else CursorPgFalso()
    ms = ms if ms is not None else CursorVentaFalso()
    with (
        patch("app.modules.venta.router.settings", settings or _SettingsFalso()),
        patch("app.modules.venta.router.fetch_one", side_effect=fetch or _fetch_one_falso),
        patch("app.modules.venta.router.get_cursor", lambda: _ctx(pg)),
        patch("app.modules.venta.router.get_venta_cursor", lambda: _ctx(ms)),
        patch("app.modules.venta.router._dual_write_pedido_to_legacy"),
    ):
        return crear_pedido(body, user or usuario_operario("venta"))


# ── Gate de ambiente ────────────────────────────────────────────────────────

def test_sin_macrosoft_conectado_403_sin_tocar_nada():
    """Regla R091: dev/testing sin VENTA_MSSQL_* no escribe NUNCA (ni al espejo)."""
    pg, ms = CursorPgFalso(), CursorVentaFalso()
    with pytest.raises(HTTPException) as ctx:
        _correr(_body(), pg=pg, ms=ms, settings=_SettingsFalso(conectado=False))
    assert ctx.value.status_code == 403
    assert pg.ejecutado == [] and ms.ejecutado == []


# ── Idempotencia (ext.venta_envio) ──────────────────────────────────────────

def test_reintento_devuelve_el_pedido_ya_creado_sin_reescribir():
    """Regla R147: el ref se reserva ANTES de escribir; el reintento tras
    timeout con el mismo ref devuelve el pedido original — cero duplicados."""
    pg = CursorPgFalso(reserva_ok=False, envio={
        "ref": REF, "usuario_id": 7, "nro_fact": 93001, "nro_doc": "93006",
        "total": 1000.0,
    })
    ms = CursorVentaFalso()
    creado = _correr(_body(), pg=pg, ms=ms)

    assert creado.nro_fact == 93001
    assert creado.nro_doc == "93006"
    assert creado.total == 1000.0
    assert ms.ejecutado == [], "el reintento no puede volver a tocar Macrosoft"


def test_envio_en_vuelo_da_409_sin_reescribir():
    """Regla R147: ref reservado pero sin nro_fact = otro envío en curso (o
    quedó a medias) → 409 de revisión humana, nunca insertar de nuevo."""
    pg = CursorPgFalso(reserva_ok=False, envio={
        "ref": REF, "usuario_id": 7, "nro_fact": None, "nro_doc": None, "total": None,
    })
    ms = CursorVentaFalso()
    with pytest.raises(HTTPException) as ctx:
        _correr(_body(), pg=pg, ms=ms)
    assert ctx.value.status_code == 409
    assert ms.ejecutado == []


def test_fallo_de_macrosoft_libera_la_reserva():
    """Regla R147: si Macrosoft NO commiteó, la reserva se libera para que el
    reintento del mismo ref pueda entrar (LIBERAR borra solo si nro_fact IS NULL)."""
    pg, ms = CursorPgFalso(), CursorVentaExplota()
    with pytest.raises(RuntimeError):
        _correr(_body(), pg=pg, ms=ms)
    assert any("DELETE FROM ext.venta_envio" in s for s in pg.sqls()), \
        "tiene que liberar la reserva tras el rollback de Macrosoft"


# ── Descuentos (artículos D%) ───────────────────────────────────────────────

def test_es_descuento_detecta_los_articulos_d():
    """Regla R159: los D% son ajustes de precio, no mercadería."""
    assert _es_descuento("D01") is True
    assert _es_descuento("d01") is True        # case-insensible
    assert _es_descuento(" D01 ") is True      # espacios de la tablet
    assert _es_descuento("010101") is False
    assert _es_descuento("1D0") is False       # la D tiene que ser el prefijo


def test_mezclar_descuento_con_mercaderia_da_400_antes_de_escribir():
    """Regla R159: pedido mixto no existe en el legacy (cero en mayo) — se corta
    con 400 ANTES de reservar ref o tocar Macrosoft."""
    pg, ms = CursorPgFalso(), CursorVentaFalso()
    body = _body(lineas=[
        LineaPedidoInput(cod_art="010101", cantidad=10, precio=100),
        LineaPedidoInput(cod_art="D01", cantidad=1, precio=50),
    ])
    with pytest.raises(HTTPException) as ctx:
        _correr(body, pg=pg, ms=ms)
    assert ctx.value.status_code == 400
    assert "aparte" in ctx.value.detail
    assert pg.ejecutado == [] and ms.ejecutado == []


def test_pedido_solo_descuentos_es_valido():
    """Regla R159: el pedido 100% D% sí existe (368 en mayo) y pasa entero."""
    ms = CursorVentaFalso()
    body = _body(lineas=[LineaPedidoInput(cod_art="D01", cantidad=1, precio=50)])
    creado = _correr(body, ms=ms)
    assert creado.nro_fact == 93001
    assert ms.params_de("INSERT INTO Lineas2")[4] == "D01"


# ── Numeración doble (NROFACT + NRODOC) ─────────────────────────────────────

def test_numeracion_nrofact_max_mas_uno_y_nrodoc_contador_mas_uno():
    """Regla R140 (parte mockeable): NROFACT sale del MAX+1 con UPDLOCK+HOLDLOCK
    y NRODOC del contador de Documentos+1, con el UPDATE del contador en la
    MISMA transacción."""
    ms = CursorVentaFalso(next_fact=93001, nrodoc_contador=1751)
    creado = _correr(_body(), ms=ms)

    assert creado.nro_fact == 93001
    assert creado.nro_doc == "1752"
    cab = ms.params_de("INSERT INTO Cabezal2")
    assert cab[5] == 93001 and cab[6] == "1752"
    assert ms.params_de("UPDATE Documentos") == (1752,)
    # Los locks viven en el texto de las queries (no ejecutables en unit).
    assert "UPDLOCK" in q.NEXT_NROFACT_MSSQL and "HOLDLOCK" in q.NEXT_NROFACT_MSSQL
    assert "UPDLOCK" in q.GET_NRODOC_MSSQL


def test_lineas_cuelgan_del_nrodoc_no_del_nrofact():
    """Regla R142: Lineas2.NroDoc = NRODOC del cabezal (¡no el NROFACT!) y el
    ID es IDENTITY (no se inserta)."""
    ms = CursorVentaFalso(next_fact=93001, nrodoc_contador=1751)
    _correr(_body(), ms=ms)

    linea = ms.params_de("INSERT INTO Lineas2")
    assert linea[1] == 93001            # NroFact
    assert linea[2] == "1752"           # NroDoc = el del cabezal, como string
    columnas = q.INSERT_LINEA2_MSSQL.split("VALUES")[0]
    assert re.search(r"\bID\b", columnas) is None, "ID es IDENTITY: no se inserta"


# ── Contrato del cabezal ────────────────────────────────────────────────────

def test_saldo_igual_totaldebe_hora_al_minuto_y_usuario_restapi():
    """Regla R144: SALDO=TOTALDEBE siempre, HORA truncada al minuto,
    USUARIO='Restapi' y FORMULARIO='P' (así escribe la app original)."""
    ms = CursorVentaFalso()
    _correr(_body(), ms=ms)

    cab = ms.params_de("INSERT INTO Cabezal2")
    assert cab[16] == cab[14], "SALDO tiene que nacer igual a TOTALDEBE"
    assert cab[17].second == 0 and cab[17].microsecond == 0  # HORA al minuto
    assert cab[0].hour == 0 and cab[0].minute == 0           # FECHA a medianoche
    assert "'Restapi'" in q.INSERT_CABEZAL2_MSSQL
    assert "'P'" in q.INSERT_CABEZAL2_MSSQL


def test_plan_va_bracketeado_en_el_insert():
    """Regla R168: PLAN es palabra reservada de T-SQL — sin corchetes el INSERT
    revienta en Macrosoft real (en dev no, por eso se lintea acá)."""
    assert "[PLAN]" in q.INSERT_CABEZAL2_MSSQL
    assert ", PLAN," not in q.INSERT_CABEZAL2_MSSQL


def test_consumofinal_por_ruc_del_cliente():
    """Regla R162: cliente sin CioRuc → CONSUMOFINAL=1; con RUC → 0 (elegible
    para eFactura)."""
    ms = CursorVentaFalso()
    _correr(_body(cliente_cod=123), ms=ms)          # con RUT
    assert ms.params_de("INSERT INTO Cabezal2")[1] == 0

    ms2 = CursorVentaFalso()
    _correr(_body(cliente_cod=456), ms=ms2)         # sin RUT
    assert ms2.params_de("INSERT INTO Cabezal2")[1] == 1


def test_consumidor_final_pisa_el_nombre_con_el_comprador_real():
    """Regla R162: SOLO el cliente 999901 permite pisar NOMBRE con el nombre
    del comprador; cualquier otro cliente lo ignora."""
    ms = CursorVentaFalso()
    _correr(_body(cliente_cod=999901, consumidor_nombre="Juan Perez"), ms=ms)
    assert ms.params_de("INSERT INTO Cabezal2")[2] == "Juan Perez"

    ms2 = CursorVentaFalso()
    _correr(_body(cliente_cod=123, consumidor_nombre="Juan Perez"), ms=ms2)
    assert ms2.params_de("INSERT INTO Cabezal2")[2] == "ALMACEN MARTINEZ"


def test_observaciones_stripeadas_y_capeadas_en_la_capa_schema():
    """Regla R161: Cabezal2.OBSERVACIONES es char(100) — el schema rechaza >100
    y el router además stripea (la capa back de las 3 capas)."""
    ms = CursorVentaFalso()
    _correr(_body(observaciones="  urgente para las 4  "), ms=ms)
    assert ms.params_de("INSERT INTO Cabezal2")[18] == "urgente para las 4"

    with pytest.raises(ValidationError):
        _body(observaciones="x" * 101)


def test_deposito_nace_en_A_por_default():
    """Regla R165: el pedido nace en A (el depósito lo asigna Expedición,
    VENDEDOR_ELIGE_DEPOSITO=false preservado)."""
    assert PedidoVentaCreate(
        cliente_cod=1, lineas=[LineaPedidoInput(cod_art="010101", cantidad=1, precio=1)],
        ref=REF,
    ).deposito == "A"
    ms = CursorVentaFalso()
    _correr(_body(), ms=ms)
    assert ms.params_de("INSERT INTO Lineas2")[3] == "A"


def test_sin_numero_de_vendedor_asignado_400():
    """Regla R164: usuario sin código de Macrosoft asignado → 400 con mensaje
    claro (no un pedido con CODVENDEDOR basura)."""
    pg, ms = CursorPgFalso(), CursorVentaFalso()
    with pytest.raises(HTTPException) as ctx:
        _correr(_body(), pg=pg, ms=ms, fetch=_fetch_sin_vendedor)
    assert ctx.value.status_code == 400
    assert "vendedor" in ctx.value.detail.lower()
    assert ms.ejecutado == []
