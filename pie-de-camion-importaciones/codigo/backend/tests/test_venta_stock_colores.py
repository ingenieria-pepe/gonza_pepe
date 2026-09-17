"""Stock vivo por COLOR de banana (25/08): cámaras × Charlie − ventas.

disponible(color) = cajas de las cámaras en ese color (última foto o carga
posterior del pie) − vendido hoy (facturas -N) − comprometido (pedidos '30').
Estimativo, jamás bloquea. Fechas RELATIVAS (regla 24/08).
"""
import itertools
from datetime import date, datetime, time, timedelta, timezone

from app.modules.venta import stock_colores as sc
from tests import factories

_REF = itertools.count(1)
_LID = itertools.count(920_000)
HOY = date.today()


def _camara_contada(pg_tx, numero, cajas, dia=None):
    dia = dia or HOY
    # Las cámaras ZAC vienen sembradas por migración: usar la existente.
    with pg_tx.cursor() as c:
        c.execute("SELECT id FROM ext.inventario_unidad "
                  "WHERE BTRIM(sede)='ZAC' AND codigo=%s", (f"camara-{numero}",))
        fila = c.fetchone()
    if fila:
        unidad = {"id": fila[0]}
    else:
        unidad = factories.insertar(
            pg_tx, "ext.inventario_unidad",
            sede="ZAC", codigo=f"camara-{numero}", tipo="camara",
            etiqueta=f"Camara {numero}", numero=numero,
        )
    ciclo = factories.insertar(
        pg_tx, "ext.inventario_ciclo",
        sede="ZAC", deposito_codigo="B", nombre=f"col {next(_REF)}",
        estado="cerrado", alcance_completo=True,
        fecha_corte=datetime.combine(dia, time(12, 0), tzinfo=timezone.utc),
        client_ref=f"col-{next(_REF)}",
    )
    cu = factories.insertar(
        pg_tx, "ext.inventario_ciclo_unidad",
        ciclo_id=ciclo["id"], unidad_id=unidad["id"],
        codigo_snapshot=f"camara-{numero}", tipo_snapshot="camara",
        etiqueta_snapshot=f"Camara {numero}", estado="contada", ultima_revision=1,
    )
    rev = factories.insertar(
        pg_tx, "ext.inventario_conteo_revision",
        ciclo_unidad_id=cu["id"], numero_revision=1,
        client_ref=f"col-rev-{next(_REF)}", fuente="aloha",
        contado_en=datetime.combine(dia, time(11, 0), tzinfo=timezone.utc),
    )
    factories.insertar(pg_tx, "ext.inventario_conteo_linea",
                       revision_id=rev["id"], cod_art="010101", cantidad=cajas,
                       descripcion_snapshot="Banana Brasil")
    return unidad


def _venta(pg_tx, codart, cajas, dia=None):
    factories.insertar(pg_tx, "legacy.documentos",
                       documento="08  ", detalle="E-Ticket", tipdoc="V", afecta=1,
                       nostock=0, nrocaja=1, formulario="F", afectactacte=0,
                       referenciado=0, llevanro=0, rubro=0, llevavencimiento=0,
                       aceptadto=0, aceptadtolinea=0, afectacontabilidad=0)
    factories.insertar(pg_tx, "legacy.lineas",
                       id=next(_LID), documento="08  ", nrofact=next(_LID),
                       fecha=datetime.combine(dia or HOY, time(0, 0)),
                       codart=codart, cantidadhaber=cajas, cantidaddebe=0,
                       deposito="A", nostock=0)


def test_pool_por_color_con_venta_y_comprometido(pg_tx, monkeypatch):
    """El label rango asigna SIEMPRE al color más chico (regla del dueño)."""
    monkeypatch.setattr(
        "app.modules.inventarios_ciclicos.charlie_ingestor.datos_charlie_para_mapa",
        lambda sede: ({3: "4-5", 7: "4-5", 9: "2"}, {}),
    )
    _camara_contada(pg_tx, 3, 500)
    _camara_contada(pg_tx, 7, 300)
    _camara_contada(pg_tx, 9, 200)
    _venta(pg_tx, "010101-4", 120)                       # color 4: resta del pool 4-5
    ped = factories.pedido(pg_tx, fecha=str(HOY), facturado=0)   # comprometido -5
    factories.insertar(pg_tx, "legacy.lineas2",
                       id=next(_LID), documento="30  ", nrofact=ped["nro_fact"],
                       codart="010101-5", cantidadhaber=30, fecha=str(HOY))

    out = sc.stock_por_color()
    pools = {p["color"]: p for p in out["pools"]}
    # REGLA (26/08): "4-5" asigna al color MÁS CHICO → pool "4", sin solape.
    assert set(pools) == {"4", "2"}
    p4 = pools["4"]
    assert p4["cajas_contadas"] == 800                   # cámaras 3 + 7
    assert p4["vendido_hoy"] == 120                      # ventas de -4
    assert p4["comprometido"] == 0                       # el -5 NO toca al pool 4
    assert p4["disponible_estimado"] == 800 - 120
    assert pools["2"]["disponible_estimado"] == 200
    assert out["colores_con_camara"] == ["2", "4"]


def test_carga_del_pie_posterior_al_conteo_suma(pg_tx, monkeypatch):
    from tests.integration.helpers_expedicion import usuario_db

    monkeypatch.setattr(
        "app.modules.inventarios_ciclicos.charlie_ingestor.datos_charlie_para_mapa",
        lambda sede: ({3: "1"}, {}),
    )
    _camara_contada(pg_tx, 3, 500, dia=HOY - timedelta(days=1))
    pie = factories.insertar(pg_tx, "ext.pie_de_camion",
                             fecha=HOY, placa_camion="AAA1111",
                             chofer_nombre="Chofer", producto="Banana",
                             pdf_filename="x.pdf", pdf_size_bytes=1,
                             creado_por_usuario_id=usuario_db(pg_tx, "stock")["id"],
                             estado="pendiente")
    factories.insertar(pg_tx, "ext.pie_de_camion_camara",
                       pie_camion_id=pie["id"], ubicacion="ZAC", numero=3,
                       cantidad=250)

    out = sc.stock_por_color()
    pool = out["pools"][0]
    assert pool["cajas_contadas"] == 500
    assert pool["cargas_pie"] == 250                     # camión de HOY, conteo de AYER
    assert pool["disponible_estimado"] == 750


def test_camara_sin_color_no_aporta_y_charlie_caido_no_rompe(pg_tx, monkeypatch):
    monkeypatch.setattr(
        "app.modules.inventarios_ciclicos.charlie_ingestor.datos_charlie_para_mapa",
        lambda sede: ({}, {}),                           # Charlie sin datos/caído
    )
    _camara_contada(pg_tx, 3, 500)
    out = sc.stock_por_color()
    assert out["pools"] == []
    assert out["colores_actualizados"] is False


def test_cache_sirve_viejo_y_refresca_en_fondo(pg_tx, monkeypatch):
    """El endpoint nunca hace esperar: sirve lo último calculado y refresca
    en un hilo cuando venció el TTL (la ida a Charlie la paga el fondo)."""
    import threading

    from app.modules.venta import stock_colores as sc2

    llamadas = []

    def _calculo_lento():
        llamadas.append(1)
        return {"pools": [{"n": len(llamadas)}], "colores_actualizados": True,
                "colores_con_camara": []}

    monkeypatch.setattr(sc2, "stock_por_color", _calculo_lento)
    monkeypatch.setattr(sc2, "_cache", {"data": None, "ts": 0.0, "refrescando": False})

    out1 = sc2.stock_por_color_cacheado()          # primer boot: calcula inline
    assert out1["pools"] == [{"n": 1}]
    out2 = sc2.stock_por_color_cacheado()          # dentro del TTL: mismo dato, sin recálculo
    assert out2["pools"] == [{"n": 1}] and len(llamadas) == 1

    with sc2._lock:
        sc2._cache["ts"] = 0.0                     # vencer el TTL
    out3 = sc2.stock_por_color_cacheado()          # sirve lo VIEJO ya mismo…
    assert out3["pools"] == [{"n": 1}]
    for t in threading.enumerate():                # …y refresca atrás
        if t.name == "stock-colores-refresh":
            t.join(timeout=5)
    assert len(llamadas) == 2
    assert sc2.stock_por_color_cacheado()["pools"] == [{"n": 2}]


# ── El ancla es el CONTEO, no el día (dueño 3/09) ───────────────────────────
#
# Antes se restaba `vendido_hoy` entero y eso descuenta dos veces: el 80% de la
# banana se vende antes de las 7 y la mayoría de las cámaras se cuentan entre
# las 9 y las 12, así que el conteo YA tiene descontada la venta de la noche.
# El 3/09 el Color 4 daba −2.469 con 685 cajas en la cámara.

def _venta_a_las(pg_tx, codart, cajas, hora_uy, dia=None):
    """Venta CON cabezal, para que tenga hora comparable contra el conteo."""
    dia = dia or HOY
    factories.insertar(pg_tx, "legacy.documentos",
                       documento="08  ", detalle="E-Ticket", tipdoc="V", afecta=1,
                       nostock=0, nrocaja=1, formulario="F", afectactacte=0,
                       referenciado=0, llevanro=0, rubro=0, llevavencimiento=0,
                       aceptadto=0, aceptadtolinea=0, afectacontabilidad=0)
    nf = next(_LID)
    factories.insertar(pg_tx, "legacy.cabezal",
                       documento="08  ", nrofact=nf,
                       fecha=datetime.combine(dia, time(0, 0)),
                       hora=time(hora_uy, 0), anulada=0)
    factories.insertar(pg_tx, "legacy.lineas",
                       id=next(_LID), documento="08  ", nrofact=nf,
                       fecha=datetime.combine(dia, time(0, 0)),
                       codart=codart, cantidadhaber=cajas, cantidaddebe=0,
                       deposito="A", nostock=0)


def test_lo_vendido_ANTES_del_conteo_no_se_descuenta(pg_tx, monkeypatch):
    """El caso real del 3/09: cámara contada a las 11 con 685 cajas y 3.154
    vendidas de madrugada. Esas 3.154 YA no estaban cuando se contó."""
    monkeypatch.setattr(
        "app.modules.inventarios_ciclicos.charlie_ingestor.datos_charlie_para_mapa",
        lambda sede: ({3: "4"}, {}),
    )
    _camara_contada(pg_tx, 3, 685)          # el helper cuenta a las 11:00 UTC
    _venta_a_las(pg_tx, "010101-4", 3154, hora_uy=3)   # 03:00 UY = 06:00 UTC

    p = {x["color"]: x for x in sc.stock_por_color()["pools"]}["4"]

    assert p["vendido_hoy"] == 3154, "el total del día se sigue informando"
    assert p["vendido_post_conteo"] == 0, "esa venta es ANTERIOR al conteo"
    assert p["disponible_estimado"] == 685
    assert p["disponible_estimado"] > 0, "no puede dar negativo por doble resta"


def test_lo_vendido_DESPUES_del_conteo_si_se_descuenta(pg_tx, monkeypatch):
    monkeypatch.setattr(
        "app.modules.inventarios_ciclicos.charlie_ingestor.datos_charlie_para_mapa",
        lambda sede: ({3: "4"}, {}),
    )
    _camara_contada(pg_tx, 3, 500)                     # 11:00 UTC = 08:00 UY
    _venta_a_las(pg_tx, "010101-4", 120, hora_uy=14)   # 14:00 UY, después

    p = {x["color"]: x for x in sc.stock_por_color()["pools"]}["4"]
    assert p["vendido_post_conteo"] == 120
    assert p["disponible_estimado"] == 380


def test_cada_camara_se_ancla_en_SU_conteo(pg_tx, monkeypatch):
    """Dos cámaras del mismo color contadas a horas distintas: la venta del
    medio sólo puede haber salido de la que ya estaba contada."""
    monkeypatch.setattr(
        "app.modules.inventarios_ciclicos.charlie_ingestor.datos_charlie_para_mapa",
        lambda sede: ({3: "4", 7: "4"}, {}),
    )
    # El helper fija contado_en a las 11:00 UTC; para tener dos horas distintas
    # se retrasa una a mano.
    _camara_contada(pg_tx, 3, 400)
    _camara_contada(pg_tx, 7, 600)
    with pg_tx.cursor() as c:
        c.execute("""UPDATE ext.inventario_conteo_revision SET contado_en = %s
                     WHERE id = (SELECT MAX(id) FROM ext.inventario_conteo_revision)""",
                  (datetime.combine(HOY, time(20, 0), tzinfo=timezone.utc),))
    _venta_a_las(pg_tx, "010101-4", 100, hora_uy=14)   # 17:00 UTC

    p = {x["color"]: x for x in sc.stock_por_color()["pools"]}["4"]
    # La venta es posterior al conteo de la 3 (11:00) pero anterior al de la 7
    # (20:00): sólo descuenta la parte proporcional de la 3 → 100 × 400/1000.
    assert p["vendido_post_conteo"] == 40
    assert p["disponible_estimado"] == 960


def test_una_venta_SIN_hora_se_descuenta_igual(pg_tx, monkeypatch):
    """Si el cabezal no está en la ventana del espejo no se sabe cuándo fue.
    Ante la duda se resta: es peor decirle al vendedor que hay de más."""
    monkeypatch.setattr(
        "app.modules.inventarios_ciclicos.charlie_ingestor.datos_charlie_para_mapa",
        lambda sede: ({3: "4"}, {}),
    )
    _camara_contada(pg_tx, 3, 500)
    _venta(pg_tx, "010101-4", 80)          # este helper NO crea cabezal

    p = {x["color"]: x for x in sc.stock_por_color()["pools"]}["4"]
    assert p["vendido_post_conteo"] == 80
    assert p["disponible_estimado"] == 420
