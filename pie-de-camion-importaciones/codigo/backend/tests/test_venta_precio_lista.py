"""POST /venta/ultimos-precios: el precio BASE del tomador contra PG real.

Reglas cubiertas (docs/tests/inventario-reglas.md):
  R156 — precio base = lista de Macrosoft (CambiosDePrecios último ≤ hoy,
         fallback Precios, según Clientes.TiposPrecios) → últ. venta del
         cliente → global (el back publica los tres; el −10%/+20% del front
         se ancla en precio_lista)
  R169 — Ivas.Porcentaje tolera fracción (0.22) y porcentaje (22) en
         PRECIOS_LISTA_SQL (listas de costo que suman el IVA)

Todo por el espejo legacy.* en PG (pg_tx + factories) — es la réplica del
DOYPRECIOAFECHASI de Macrosoft, así que se verifica cada salto de la cascada
con datos sembrados, no contra SQL Server.
"""
import itertools
from datetime import date, datetime, timedelta

import pytest

from app.modules.venta.router import ultimos_precios
from app.modules.venta.schemas import UltimosPreciosInput
from tests import factories

_LID = itertools.count(8_800_001)
_CDP_ID = itertools.count(41_001)

HOY = date.today()


def _cambio(pg_tx, cod: str, lista: int, precio, fecha, id=None) -> dict:
    return factories.insertar(
        pg_tx, "legacy.cambiosdeprecios",
        id=id if id is not None else next(_CDP_ID),
        codarticulo=cod, tiposprecios=lista, fecha=fecha,
        precioactual=precio, moneda=1,
    )


def _precio_base(pg_tx, cod: str, lista: int, precio, moneda=1) -> dict:
    return factories.insertar(
        pg_tx, "legacy.precios",
        codarticulo=cod, tiposprecios=lista, moneda=moneda, precio=precio,
    )


def _venta(pg_tx, cliente: int, cod: str, precio, fecha: datetime, anulada=0):
    """Pedido '30' del espejo con UNA línea vendida (para últ. venta/global)."""
    p = factories.pedido(pg_tx, cliente=cliente, lineas=(), anulada=anulada)
    factories.insertar(
        pg_tx, "legacy.lineas2",
        id=next(_LID), documento="30  ", nrofact=p["nro_fact"],
        codart=cod, precio=precio, fecha=fecha,
        descripcion="VENTA DE PRUEBA",
    )


def _pedir(cods, cliente=None):
    out = ultimos_precios(UltimosPreciosInput(cliente_cod=cliente, cod_arts=list(cods)))
    return {r.cod_art: r for r in out}


# ── R156: la resolución de la LISTA ─────────────────────────────────────────

def test_el_ultimo_cambio_hasta_hoy_manda_sobre_precios(pg_tx):
    """Regla R156: con CambiosDePrecios el último cambio con fecha <= hoy
    manda (uno FUTURO no rige todavía) y la tabla Precios queda de fallback."""
    _cambio(pg_tx, "LCAM", 2, 90, HOY - timedelta(days=12))
    _cambio(pg_tx, "LCAM", 2, 95, HOY)
    _cambio(pg_tx, "LCAM", 2, 999, HOY + timedelta(days=1))   # rige mañana
    _precio_base(pg_tx, "LCAM", 2, 70)                        # no debe ganar

    assert _pedir(["LCAM"])["LCAM"].precio_lista == pytest.approx(95)


def test_empate_de_fecha_lo_resuelve_el_id(pg_tx):
    """Regla R156: dos cambios el MISMO día (pasa: Valeria corrige) — gana el
    de id más alto (el último grabado), no uno al azar."""
    _cambio(pg_tx, "LEMP", 2, 50, HOY, id=61_010)
    _cambio(pg_tx, "LEMP", 2, 60, HOY, id=61_011)

    assert _pedir(["LEMP"])["LEMP"].precio_lista == pytest.approx(60)


def test_sin_cambios_cae_a_precios_en_pesos(pg_tx):
    """Regla R156: sin historia en CambiosDePrecios rige el precio base de la
    tabla Precios, SOLO moneda pesos (un precio en USD pre-llenado en un
    pedido en pesos sería un desastre silencioso)."""
    _precio_base(pg_tx, "LBAS", 2, 70, moneda=1)
    _precio_base(pg_tx, "LBAS", 2, 999, moneda=2)   # USD: no juega

    filas = _pedir(["LBAS", "LNADA"])
    assert filas["LBAS"].precio_lista == pytest.approx(70)
    assert filas["LNADA"].precio_lista is None      # sin lista: el front bloquea


def test_la_lista_es_la_del_cliente(pg_tx):
    """Regla R156: el precio sale de la lista del CLIENTE
    (Clientes.TiposPrecios); sin cliente elegido rige la 2 "Venta Público"."""
    factories.insertar(pg_tx, "legacy.clientes",
                       codcliente=88123, nombre="SUPER PLAZA", tiposprecios=3, moneda=1)
    _cambio(pg_tx, "LCLI", 2, 100, HOY - timedelta(days=1))
    _cambio(pg_tx, "LCLI", 3, 120, HOY - timedelta(days=1))

    assert _pedir(["LCLI"], cliente=88123)["LCLI"].precio_lista == pytest.approx(120)
    assert _pedir(["LCLI"])["LCLI"].precio_lista == pytest.approx(100)


def test_lista_de_costo_suma_iva_y_tolera_fraccion_o_porcentaje(pg_tx):
    """Reglas R156 + R169: una lista con NoIncluyeImpuestos=1 (lista de costo)
    suma el IVA del artículo igual que Macrosoft — y da LO MISMO si el espejo
    trae Ivas.Porcentaje como fracción (0.22) o como porcentaje (22)."""
    factories.insertar(pg_tx, "legacy.tiposprecios",
                       tipo=7, descripcion="COSTO", noincluyeimpuestos=1)
    factories.insertar(pg_tx, "legacy.clientes",
                       codcliente=88456, nombre="CLIENTE COSTO", tiposprecios=7, moneda=1)
    factories.insertar(pg_tx, "legacy.ivas", iva=1, descripcion="Basico", porcentaje=0.22)
    factories.insertar(pg_tx, "legacy.ivas", iva=9, descripcion="BasicoPct", porcentaje=22)
    factories.insertar(pg_tx, "legacy.articulos", codarticulo="CFRA", iva=1)
    factories.insertar(pg_tx, "legacy.articulos", codarticulo="CPCT", iva=9)
    _precio_base(pg_tx, "CFRA", 7, 100)
    _precio_base(pg_tx, "CPCT", 7, 100)

    filas = _pedir(["CFRA", "CPCT"], cliente=88456)
    assert filas["CFRA"].precio_lista == pytest.approx(122)
    assert filas["CPCT"].precio_lista == pytest.approx(122)   # 22 ≡ 0.22


# ── R156: los fallbacks última-venta cuando no hay lista ────────────────────

def test_sin_lista_quedan_ultima_venta_del_cliente_y_global(pg_tx):
    """Regla R156 (cola de la cascada): artículo sin precio de lista →
    precio_lista=None y viajan los fallbacks: último precio A ESTE cliente
    (el más reciente NO anulado) y el global — que ignora ventas a clientes
    en moneda extranjera y por eso puede diferir del más reciente absoluto."""
    factories.insertar(pg_tx, "legacy.clientes",
                       codcliente=88123, nombre="ALMACEN UNO", tiposprecios=2, moneda=1)
    factories.insertar(pg_tx, "legacy.clientes",
                       codcliente=88124, nombre="ALMACEN DOS", tiposprecios=2, moneda=1)
    factories.insertar(pg_tx, "legacy.clientes",
                       codcliente=88999, nombre="EXPORTADOR USD", tiposprecios=2, moneda=2)

    d = datetime.combine(HOY, datetime.min.time())
    _venta(pg_tx, 88123, "SINL", 40, d - timedelta(days=3))
    _venta(pg_tx, 88123, "SINL", 45, d - timedelta(days=1))    # la última del cliente
    _venta(pg_tx, 88123, "SINL", 999, d, anulada=1)            # anulada: no cuenta
    _venta(pg_tx, 88124, "SINL", 80, d)                        # la última global en pesos
    _venta(pg_tx, 88999, "SINL", 999, d + timedelta(hours=5))  # USD: fuera del global

    fila = _pedir(["SINL"], cliente=88123)["SINL"]
    assert fila.precio_lista is None
    assert fila.precio == pytest.approx(45)
    assert fila.fecha == (d - timedelta(days=1)).date().isoformat()
    assert fila.precio_global == pytest.approx(80)
    assert fila.fecha_global == d.date().isoformat()
