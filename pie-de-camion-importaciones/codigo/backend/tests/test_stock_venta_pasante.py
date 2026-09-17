"""Códigos que SÓLO registran salidas (1/09/2026).

La fruta entra con un código y sale con otro, y Macrosoft no tiene el asiento
que convierta uno en el otro: el saldo del código de salida se hunde para
siempre. La palta llegó a mostrar −8.338 en pantalla cuando en la cámara había
3.456 cajas, y el 98% de ese agujero era un solo código.
"""
from app.modules.stock.curation import VENTA_PASANTE, es_venta_pasante


def test_los_cinco_codigos_super_estan_marcados():
    # Medidos sobre el histórico completo: entró/salió por debajo del 40%.
    for cod in ("600248", "981002", "010701", "120401", "890202"):
        assert es_venta_pasante(cod), f"{cod} debería estar marcado"


def test_un_codigo_normal_NO_esta_marcado():
    # 600260 (Palta Chile Cal. 60) recibe por viajes e importación: su saldo sí
    # significa algo.
    assert not es_venta_pasante("600260")
    assert not es_venta_pasante("010101")


def test_los_colores_de_banana_NO_van_en_la_lista():
    """Tienen el mismo problema pero compensan solos: el Color 4 vive en el
    MISMO producto del dashboard que su Color 1, y el grupo cierra (Banana
    Brasil fibra: −26.756 en el Color 4 y el producto queda en −109). Marcarlos
    haría ruido sin arreglar nada."""
    for cod in ("010101-4", "010701-4", "010102-5"):
        assert not es_venta_pasante(cod)


def test_tolera_el_cero_adelante_y_los_espacios():
    # Macrosoft guarda los códigos con padding y a veces sin el cero inicial.
    assert es_venta_pasante(" 600248 ")
    assert es_venta_pasante("0600248")


def test_nulo_no_explota():
    assert not es_venta_pasante(None)
    assert not es_venta_pasante("")


def test_no_se_descuenta_del_total():
    """La marca AVISA, no resta: la fruta salió de verdad y descontarla
    inflaría el stock. Por eso `es_venta_pasante` es independiente de
    `es_articulo_fantasma`, que sí excluye."""
    from app.modules.stock.curation import SUPER_FANTASMA
    assert VENTA_PASANTE >= SUPER_FANTASMA, "lo que se excluye también se avisa"
    assert len(VENTA_PASANTE) > len(SUPER_FANTASMA)
