"""_resolver_lineas: el cálculo de importes del pedido '30' (contrato del tomador).

El contrato relevado de Macrosoft: precio CON IVA incluido, TotalSinIva/IvaLinea
separados POR LÍNEA (nunca sobre el total), todo en Decimal a 2 decimales. Si
esto se rompe, caja factura otra cosa que lo que el vendedor cargó.
"""
from decimal import Decimal

import pytest
from fastapi import HTTPException
from unittest.mock import patch

from app.modules.venta.router import _resolver_lineas
from app.modules.venta.schemas import LineaPedidoInput

# Catálogo falso: lo que devolvería GET_ARTICULO_SQL (join Articulos+Ivas del
# espejo). iva_tasa llega como FRACCIÓN (0.22), igual que en la query real.
CATALOGO = {
    "010101": {"cod": "010101", "descripcion": "Banana Brasil", "iva_tasa": 0.22},
    "600101": {"cod": "600101", "descripcion": "Palta Cal.60", "iva_tasa": 0.10},
    "800001": {"cod": "800001", "descripcion": "Articulo Exento", "iva_tasa": 0.0},
    "900001": {"cod": "900001", "descripcion": "X" * 150, "iva_tasa": 0.22},
}


def _catalogo_falso(_sql, params=None):
    return CATALOGO.get(params[0])


def _resolver(lineas):
    with patch("app.modules.venta.router.fetch_one", side_effect=_catalogo_falso):
        return _resolver_lineas(lineas)


def _linea(cod="010101", cantidad=10, precio=100) -> LineaPedidoInput:
    return LineaPedidoInput(cod_art=cod, cantidad=cantidad, precio=precio)


def test_iva_por_linea_contrato_del_tomador():
    """Regla R143: TotalSinIva = TotalLinea/(1+Iva) e IvaLinea = la diferencia,
    con el precio IVA INCLUIDO (10 bultos × $100 = $1000 CON IVA adentro)."""
    lineas_calc, total, subtotal, iva_total, unidades = _resolver([_linea()])

    lc = lineas_calc[0]
    assert lc["total_linea"] == Decimal("1000.00")
    assert lc["sin_iva"] == Decimal("819.67")     # 1000/1.22 redondeado a 2
    assert lc["iva_linea"] == Decimal("180.33")   # la DIFERENCIA, no total*tasa
    assert total == Decimal("1000.00")
    assert subtotal == Decimal("819.67")
    assert iva_total == Decimal("180.33")
    assert unidades == Decimal("10")


def test_tasas_10_y_exento():
    """Regla R143: la tasa sale del catálogo Ivas por artículo (fracción)."""
    lineas_calc, total, _sub, iva_total, _uni = _resolver([
        _linea("600101", cantidad=10, precio=110),   # 10% → 1100/1.1 = 1000
        _linea("800001", cantidad=1, precio=50),     # exento → sin_iva == total
    ])

    palta, exento = lineas_calc
    assert palta["sin_iva"] == Decimal("1000.00")
    assert palta["iva_linea"] == Decimal("100.00")
    assert exento["sin_iva"] == Decimal("50.00")
    assert exento["iva_linea"] == Decimal("0.00")
    assert total == Decimal("1150.00")
    assert iva_total == Decimal("100.00")


def test_el_iva_se_separa_linea_por_linea_no_sobre_el_total():
    """Reglas R143 y R101: separar el IVA sobre el total acumulado da OTRO
    número que separarlo línea a línea y sumar (el clásico centavo de
    diferencia). El contrato del tomador es POR LÍNEA."""
    lineas = [_linea(cantidad=1, precio=10.01), _linea(cantidad=1, precio=10.01)]
    _calc, total, subtotal, iva_total, _uni = _resolver(lineas)

    assert total == Decimal("20.02")
    # Por línea: 10.01/1.22 → 8.20 dos veces → IVA 1.81 + 1.81 = 3.62.
    assert iva_total == Decimal("3.62")
    assert subtotal == Decimal("16.40")
    # Sobre el total hubiera dado 20.02/1.22 → 16.41 → IVA 3.61: DISTINTO.
    mal_calculado = Decimal("20.02") - Decimal("16.41")
    assert iva_total != mal_calculado


def test_subtotal_mas_iva_da_exacto_el_total():
    """Regla R143: la identidad sin_iva + iva_linea == total_linea se cumple
    EXACTA por línea y en los acumulados (nada de drift de float)."""
    lineas_calc, total, subtotal, iva_total, _uni = _resolver([
        _linea(cantidad=3, precio=33.33),
        _linea("600101", cantidad=7, precio=14.99),
        _linea("800001", cantidad=1.5, precio=0.99),
    ])

    for lc in lineas_calc:
        assert lc["sin_iva"] + lc["iva_linea"] == lc["total_linea"]
    assert subtotal + iva_total == total


def test_todo_es_decimal_nunca_float():
    """El motor de importes trabaja en Decimal (misma disciplina que el motor
    CFE, regla R104): un float acá filtra centavos fantasma a Macrosoft."""
    lineas_calc, total, subtotal, iva_total, unidades = _resolver(
        [_linea(cantidad=2.5, precio=10.1)]
    )

    lc = lineas_calc[0]
    for valor in (lc["cantidad"], lc["precio"], lc["total_linea"], lc["sin_iva"],
                  lc["iva_linea"], total, subtotal, iva_total, unidades):
        assert isinstance(valor, Decimal), f"{valor!r} tiene que ser Decimal"
    # float 2.5 * 10.1 = 25.249999... — en Decimal da justo.
    assert lc["total_linea"] == Decimal("25.25")


def test_precio_redondea_half_up():
    """Regla R143: los montos van cuantizados a 2 decimales con ROUND_HALF_UP
    (mitad para arriba, como redondea la caja — no banker's rounding)."""
    lineas_calc, _t, _s, _i, _u = _resolver([_linea(cantidad=1, precio=10.005)])
    assert lineas_calc[0]["precio"] == Decimal("10.01")


def test_tope_de_total_linea_da_400_legible():
    """Regla R163: TotalLinea es numeric(10,2) en Macrosoft — pasarse tiene que
    dar 400 con mensaje claro, no un 500 de arithmetic overflow."""
    with pytest.raises(HTTPException) as ctx:
        _resolver([_linea(cantidad=1_000_000, precio=100)])
    assert ctx.value.status_code == 400
    assert "demasiado grande" in ctx.value.detail


def test_articulo_inexistente_da_400_con_el_codigo():
    with pytest.raises(HTTPException) as ctx:
        _resolver([_linea("999999")])
    assert ctx.value.status_code == 400
    assert "999999" in ctx.value.detail


def test_cod_art_va_stripeado_al_catalogo():
    """La tablet puede mandar espacios; el lookup va con el código limpio."""
    with patch("app.modules.venta.router.fetch_one", side_effect=_catalogo_falso) as m:
        _resolver_lineas([_linea(" 010101 ")])
    (_sql, params), _ = m.call_args
    assert params == ("010101",)


def test_descripcion_capeada_a_100_chars():
    """Lineas2.Descripcion es char(100): más largo revienta el INSERT."""
    lineas_calc, *_ = _resolver([_linea("900001")])
    assert len(lineas_calc[0]["descripcion"]) == 100


def test_unidades_suma_las_cantidades():
    _calc, _t, _s, _i, unidades = _resolver([
        _linea(cantidad=10),
        _linea("600101", cantidad=2.5),
    ])
    assert unidades == Decimal("12.5")
