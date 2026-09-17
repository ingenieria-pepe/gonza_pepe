"""Chip de estado y armado del item de listado de Venta (_estado_chip/_list_item).

Lo que decide el chip es lo mismo que decide la cola de caja de Macrosoft
(FACTURADO/ANULADA smallint, ESTADO texto), y `anulable` es el candado visual
de "anular": si miente, un vendedor intenta anular lo que no puede (o no ve el
botón para lo que sí).
"""
from datetime import datetime
from decimal import Decimal

from app.modules.venta.router import _estado_chip, _list_item
from tests.factories import usuario_operario


def _row(**ov) -> dict:
    """Fila como la devuelve LIST_PEDIDOS_SQL_TPL (flags smallint del espejo)."""
    base = dict(
        nrofact=93001, nrodoc="93006",
        fecha=datetime(2026, 8, 12), hora=datetime(2026, 8, 12, 3, 47, 12),
        cliente_nombre="ALMACEN MARTINEZ", codcliente=123,
        codvendedor=5, vendedor_nombre="Gonzalo",
        total=Decimal("1500.50"), encuotas=0, estado="",
        facturado=0, anulada=0, observaciones=None,
        creado_por_usuario_id=7, creado_por_nombre="Tester",
        creado_por_username="tester",
    )
    base.update(ov)
    return base


# ── _estado_chip ────────────────────────────────────────────────────────────

def test_chip_anulado_gana_aunque_este_facturado():
    """Regla R145: anular deja ANULADA=1 + FACTURADO=1 (así sale de la cola).
    El chip tiene que decir 'anulado', jamás 'facturado'."""
    assert _estado_chip(_row(anulada=1, facturado=1)) == "anulado"


def test_chip_en_caja_ignora_el_estado():
    """Regla R078: la cola de caja es FACTURADO=0 AND ANULADA=0 — ESTADO es
    irrelevante mientras el pedido no salió de caja."""
    assert _estado_chip(_row(facturado=0, estado="")) == "en_caja"
    assert _estado_chip(_row(facturado=0, estado="ASIGNADO")) == "en_caja"


def test_chip_facturado_con_estado_en_blanco():
    """Facturado con ESTADO vacío es un estado NORMAL (paralelo de la regla
    R011: en Expedición eso cuenta como PENDIENTE, acá como 'facturado')."""
    assert _estado_chip(_row(facturado=1, estado="")) == "facturado"
    assert _estado_chip(_row(facturado=1, estado=None)) == "facturado"


def test_chip_estado_operativo_en_minusculas_y_sin_espacios():
    """El espejo trae char() con relleno: 'ASIGNADO  ' → chip 'asignado'."""
    assert _estado_chip(_row(facturado=1, estado="ASIGNADO  ")) == "asignado"
    assert _estado_chip(_row(facturado=1, estado="ENTREGADO")) == "entregado"


# ── _list_item: anulable ────────────────────────────────────────────────────

def test_anulable_solo_pedidos_creados_desde_aloha():
    """Regla R146: un pedido del tomador viejo (sin meta → creado_por NULL) no
    se anula desde Aloha aunque siga en caja."""
    user = usuario_operario("venta")
    item = _list_item(_row(creado_por_usuario_id=None), user, ver_todos=False)
    assert item.anulable is False
    assert item.es_mio is False


def test_anulable_el_propio_en_caja_si():
    """Regla R146: el dueño anula lo suyo mientras siga en caja."""
    user = usuario_operario("venta")  # id=7, igual que creado_por_usuario_id
    item = _list_item(_row(), user, ver_todos=False)
    assert item.es_mio is True
    assert item.anulable is True


def test_anulable_ajeno_requiere_ver_todos():
    """Regla R146: anular ajenos es de admin/venta_todos — el candado visual
    sigue la misma línea que el candado del endpoint."""
    user = usuario_operario("venta", id=99)
    fila = _row()  # creado por el usuario 7
    assert _list_item(fila, user, ver_todos=False).anulable is False
    assert _list_item(fila, user, ver_todos=True).anulable is True


def test_no_anulable_si_ya_paso_por_caja_o_esta_anulado():
    """Regla R145: anular es SOLO antes de que caja facture (guard optimista
    FACTURADO=0); un anulado tampoco se re-anula."""
    user = usuario_operario("venta")
    assert _list_item(_row(facturado=1), user, ver_todos=True).anulable is False
    assert _list_item(_row(anulada=1, facturado=1), user, ver_todos=True).anulable is False


# ── _list_item: formato ─────────────────────────────────────────────────────

def test_formatos_de_fecha_hora_y_credito():
    item = _list_item(_row(encuotas=1), usuario_operario("venta"), ver_todos=False)
    assert item.fecha == "2026-08-12"
    assert item.hora == "03:47"          # HH:MM, sin segundos
    assert item.credito is True          # ENCUOTAS smallint → bool
    assert item.total == 1500.50
    assert item.nro_doc == "93006"


def test_fila_vieja_del_espejo_sin_total_ni_horas():
    """Filas pre-columna del espejo: total NULL viaja como None (no como 0 —
    el front distingue 'sin dato' de 'gratis')."""
    fila = _row(total=None, fecha=None, hora=None, nrodoc=None)
    item = _list_item(fila, usuario_operario("venta"), ver_todos=False)
    assert item.total is None
    assert item.fecha is None
    assert item.hora is None
    assert item.nro_doc == ""
