"""Pedidos PRIORITARIOS (24/08): el vendedor marca que un pedido tiene que
salir YA y la marca viaja por TODA la cadena:

- Venta: POST /venta/pedidos/{nf}/prioridad (marcar/desmarcar, con auditoría)
  y el flag en el listado de Pedidos.
- Asignación (expedición): el prioritario aparece ARRIBA DE TODO.
- Armador: su lista lo trae primero y con el flag.
- Tele de entregas: el pedido viaja con prioritario=true y entra a la lista
  top-level `prioritarios` (la alarma) hasta que se entrega.
"""
import itertools
from datetime import date, timedelta

import pytest
from fastapi import HTTPException

from app.modules.venta.router import marcar_prioridad
from app.modules.venta.schemas import PrioridadBody
from tests import factories
from tests.integration.helpers_expedicion import seed_entorno, usuario_db

_REF = itertools.count(1)


def _vendedor(pg_tx):
    fila = usuario_db(pg_tx, "venta")
    return factories.usuario_operario("venta", id=fila["id"])


def test_marcar_desmarcar_con_auditoria(pg_tx):
    user = _vendedor(pg_tx)
    ped = factories.pedido(pg_tx, estado="ASIGNADO")
    nf = ped["nro_fact"]

    out = marcar_prioridad(nf, PrioridadBody(prioritario=True), user)
    assert out == {"nro_fact": nf, "prioritario": True}
    with pg_tx.cursor() as cur:
        cur.execute(
            "SELECT activo, marcado_por, desmarcado_en FROM ext.pedido_prioridad "
            "WHERE documento = '30  ' AND nro_fact = %s", (nf,))
        activo, marcado_por, desmarcado_en = cur.fetchone()
    assert (activo, marcado_por, desmarcado_en) == (True, user.id, None)

    # Desmarcar apaga y audita; re-marcar vuelve a encender limpio.
    marcar_prioridad(nf, PrioridadBody(prioritario=False), user)
    with pg_tx.cursor() as cur:
        cur.execute(
            "SELECT activo, desmarcado_por FROM ext.pedido_prioridad "
            "WHERE documento = '30  ' AND nro_fact = %s", (nf,))
        assert cur.fetchone() == (False, user.id)
    marcar_prioridad(nf, PrioridadBody(prioritario=True), user)
    with pg_tx.cursor() as cur:
        cur.execute(
            "SELECT activo, desmarcado_por FROM ext.pedido_prioridad "
            "WHERE documento = '30  ' AND nro_fact = %s", (nf,))
        assert cur.fetchone() == (True, None)


def test_pedido_inexistente_404(pg_tx):
    with pytest.raises(HTTPException) as e:
        marcar_prioridad(99_999_999, PrioridadBody(prioritario=True), _vendedor(pg_tx))
    assert e.value.status_code == 404


def test_asignacion_lo_pone_arriba_de_todo(pg_tx):
    """El listado de expedición/asignación ordena PRIORITARIOS primero aunque
    sean más viejos que el resto."""
    from app.modules.expedicion.router import list_pedidos

    seed_entorno(pg_tx)
    user = _vendedor(pg_tx)
    viejo = factories.pedido(pg_tx, estado="ASIGNADO", fecha="2026-08-23",
                             nrodoc="91001", nombre="CLIENTE VIEJO")
    nuevo = factories.pedido(pg_tx, estado="ASIGNADO", fecha="2026-08-24",
                             nrodoc="91002", nombre="CLIENTE NUEVO")
    nf_viejo = viejo["nro_fact"]
    marcar_prioridad(nf_viejo, PrioridadBody(prioritario=True), user)

    resp = list_pedidos(estado="ASIGNADO", search="", pallets="todos",
                        descuentos="todos", deposito="", excluir_deposito="",
                        fecha_desde=date(2026, 8, 20), limit=50, offset=0)
    ids = [p.id for p in resp.items]
    nf_nuevo = nuevo["nro_fact"]
    assert ids.index(nf_viejo) < ids.index(nf_nuevo)   # el prioritario gana
    assert next(p for p in resp.items if p.id == nf_viejo).prioritario is True
    assert next(p for p in resp.items if p.id == nf_nuevo).prioritario is False


def test_armador_lo_ve_primero_y_con_flag(pg_tx):
    from app.modules.armado.router import list_pedidos_para_armar

    vendedor = _vendedor(pg_tx)
    armador_fila = usuario_db(pg_tx, "armado")
    armador = factories.usuario_operario("armado", id=armador_fila["id"])

    comun = factories.pedido(pg_tx, estado="ASIGNADO", fecha="2026-08-23", deposito="B",
                             nrodoc="91003", nombre="CLIENTE COMUN")
    urgente = factories.pedido(pg_tx, estado="ASIGNADO", fecha="2026-08-24", deposito="B",
                               nrodoc="91004", nombre="CLIENTE URGENTE")
    for ped in (comun, urgente):
        factories.insertar(pg_tx, "ext.pedido_asignacion",
                           documento="30  ", nro_fact=ped["nro_fact"], usuario_id=armador.id)
    nf_urgente = urgente["nro_fact"]
    marcar_prioridad(nf_urgente, PrioridadBody(prioritario=True), vendedor)

    items = list_pedidos_para_armar(fecha_desde=date(2026, 8, 20), user=armador)
    assert items[0].id == nf_urgente        # el prioritario primero (era el más nuevo)
    assert items[0].prioritario is True
    assert all(not p.prioritario for p in items[1:])


def test_la_tele_lo_marca_y_lo_suma_a_la_alarma(pg_tx, monkeypatch):
    from app.config import settings
    from app.modules.monitor_entregas import queries as mq
    from app.modules.monitor_entregas.router import monitor
    from app.pg import fetch_all

    class _ReqTV:
        query_params = {"k": "tok-tele"}
        headers = {}

    monkeypatch.setattr(settings, "monitor_kiosk_token", "tok-tele")

    user = _vendedor(pg_tx)
    hoy = date(2026, 8, 24)
    normal = factories.pedido(pg_tx, estado="ASIGNADO", fecha=str(hoy))
    urgente = factories.pedido(pg_tx, estado="ASIGNADO", fecha=str(hoy))
    nf = urgente["nro_fact"]
    marcar_prioridad(nf, PrioridadBody(prioritario=True), user)

    # La query del día trae el flag por pedido…
    por_nf = {r["nrofact"]: r for r in fetch_all(mq.PEDIDOS_DEL_DIA_SQL, (hoy,))}
    assert por_nf[nf]["prioritario"] is True
    assert por_nf[normal["nro_fact"]]["prioritario"] is False

    # …y el payload completo de la tele expone la lista de la ALARMA.
    data = monitor(_ReqTV(), fecha=str(hoy), dia=None)
    assert [a["nro_fact"] for a in data["prioritarios"]] == [nf]


def test_la_lista_de_pedidos_dice_cual_esta_marcado(pg_tx):
    """El agujero por el que se coló el bug del 28/08.

    La query del listado traía el flag, pero el router armaba el item campo por
    campo y `prioritario` se quedaba en su default False. En la calle eso era:
    el botón nunca se veía marcado (nadie sabía CUÁL era el prioritario) y, al
    tocarlo, mandaba !False = marcar otra vez → la prioridad no se podía sacar
    y la tele sonaba cada 20 s hasta que el pedido se entregaba.
    """
    from app.modules.venta.router import list_pedidos

    user = _vendedor(pg_tx)
    marcado = factories.pedido(pg_tx, estado="ASIGNADO", fecha=str(date.today()))
    suelto = factories.pedido(pg_tx, estado="ASIGNADO", fecha=str(date.today()))
    marcar_prioridad(marcado["nro_fact"], PrioridadBody(prioritario=True), user)

    def flags():
        items = list_pedidos(scope="todos", cliente=None, vendedor=None,
                             fecha=str(date.today()), con_resumen=False, limit=200,
                             user=factories.usuario_admin())
        return {i.nro_fact: i.prioritario for i in items}

    f = flags()
    assert f[marcado["nro_fact"]] is True
    assert f[suelto["nro_fact"]] is False

    # Y el viaje de vuelta: desmarcar se ve en la lista, que es lo que hace que
    # el mismo botón sirva para apagar la alarma.
    marcar_prioridad(marcado["nro_fact"], PrioridadBody(prioritario=False), user)
    assert flags()[marcado["nro_fact"]] is False
def test_asignacion_no_muestra_los_ya_controlados(pg_tx):
    """Dueño 28/08: un pedido controlado seguía apareciendo en Asignación —
    Macrosoft lo deja en ESTADO=ASIGNADO aunque en Aloha ya se armó y controló,
    y el asignador lo veía como si le faltara algo."""
    from app.modules.expedicion.router import list_pedidos

    seed_entorno(pg_tx)
    # Fechas RELATIVAS: con fechas fijas el test se pudre solo (regla 24/08).
    hoy = date.today()
    sin_controlar = factories.pedido(pg_tx, estado="ASIGNADO", fecha=str(hoy),
                                     nrodoc="92001", nombre="SIN CONTROLAR")
    controlado = factories.pedido(pg_tx, estado="ASIGNADO", fecha=str(hoy),
                                  nrodoc="92002", nombre="YA CONTROLADO")
    with pg_tx.cursor() as cur:
        cur.execute("INSERT INTO ext.pedido_control (documento, nro_fact) VALUES (%s, %s)",
                    (controlado["documento"], controlado["nro_fact"]))

    def _ids(excluir):
        r = list_pedidos(estado="ASIGNADO", search="", pallets="todos", descuentos="todos",
                         deposito="", excluir_deposito="", fecha_desde=hoy - timedelta(days=4),
                         excluir_controlados=excluir, limit=50, offset=0)
        return [p.id for p in r.items], r.total

    # Expedición los sigue viendo (no se cambió el default).
    ids, total = _ids(False)
    assert controlado["nro_fact"] in ids and sin_controlar["nro_fact"] in ids

    # Asignación no: y el TOTAL también baja (el filtro va en el WHERE, no en
    # la pantalla, para que la paginación no devuelva páginas medio vacías).
    ids2, total2 = _ids(True)
    assert controlado["nro_fact"] not in ids2
    assert sin_controlar["nro_fact"] in ids2
    assert total2 == total - 1


# ── Pedidos de DESCUENTOS (31/08) ────────────────────────────────────────
#
# Un pedido de puros artículos D* ("Dto. Bananas madera"…) no lleva mercadería:
# el tomador lo crea SIEMPRE aparte, no se arma, no se controla y no se entrega.
# Marcarlo prioritario no le avisaba a nadie —no aparece en el celu del armador—
# y encima la alarma de la tele se apaga recién cuando el pedido se ENTREGA, así
# que sonaba hasta que alguien se diera cuenta. Pasó el 31/08 con un dto y su
# pedido de mercadería, cargados en el mismo minuto para el mismo cliente.

def _dto(pg_tx, **extra):
    """Pedido de puros descuentos (como los crea el tomador)."""
    return factories.pedido(pg_tx, lineas=(("D01", 2),), **extra)


def test_un_pedido_de_descuentos_no_se_puede_marcar(pg_tx):
    user = _vendedor(pg_tx)
    ped = _dto(pg_tx, estado="ASIGNADO")

    with pytest.raises(HTTPException) as e:
        marcar_prioridad(ped["nro_fact"], PrioridadBody(prioritario=True), user)
    assert e.value.status_code == 400
    assert "descuentos" in e.value.detail.lower()

    # Y no quedó nada escrito: el gate corta ANTES de tocar la tabla.
    with pg_tx.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM ext.pedido_prioridad WHERE nro_fact = %s",
                    (ped["nro_fact"],))
        assert cur.fetchone()[0] == 0


def test_el_pedido_de_mercaderia_del_mismo_cliente_si_se_marca(pg_tx):
    """El caso real: el dto y el pedido bueno entran juntos. Se bloquea uno solo."""
    user = _vendedor(pg_tx)
    mercaderia = factories.pedido(pg_tx, lineas=(("010101", 21),), estado="ASIGNADO")
    out = marcar_prioridad(mercaderia["nro_fact"], PrioridadBody(prioritario=True), user)
    assert out["prioritario"] is True


def test_una_prioridad_vieja_de_un_dto_siempre_se_puede_sacar(pg_tx):
    """Quitar NUNCA se bloquea: si no, los dtos marcados antes del gate
    quedaban trabados sonando y sin botón para apagarlos."""
    user = _vendedor(pg_tx)
    ped = _dto(pg_tx, estado="ASIGNADO")
    factories.insertar(pg_tx, "ext.pedido_prioridad", documento="30  ",
                       nro_fact=ped["nro_fact"], marcado_por=user.id, activo=True)

    out = marcar_prioridad(ped["nro_fact"], PrioridadBody(prioritario=False), user)
    assert out["prioritario"] is False
    with pg_tx.cursor() as cur:
        cur.execute("SELECT activo FROM ext.pedido_prioridad WHERE nro_fact = %s",
                    (ped["nro_fact"],))
        assert cur.fetchone()[0] is False


def test_la_tele_no_suena_por_un_dto_marcado_de_antes(pg_tx, monkeypatch):
    """Los que ya estaban marcados: la tele los ignora sin tocar la base."""
    from app.config import settings
    from app.modules.monitor_entregas.router import monitor

    class _ReqTV:
        query_params = {"k": "tok-tele"}
        headers = {}

    monkeypatch.setattr(settings, "monitor_kiosk_token", "tok-tele")
    hoy = date.today()
    user = _vendedor(pg_tx)
    dto = _dto(pg_tx, estado="ASIGNADO", fecha=str(hoy))
    bueno = factories.pedido(pg_tx, lineas=(("010101", 21),), estado="ASIGNADO",
                             fecha=str(hoy))
    for ped in (dto, bueno):
        factories.insertar(pg_tx, "ext.pedido_prioridad", documento="30  ",
                           nro_fact=ped["nro_fact"], marcado_por=user.id, activo=True)

    data = monitor(_ReqTV(), fecha=str(hoy), dia=None)
    assert [a["nro_fact"] for a in data["prioritarios"]] == [bueno["nro_fact"]]


# ── La alarma arranca cuando el pedido SALE DE CAJA (2/09) ──────────────────
#
# El vendedor marca la prioridad al CREAR el pedido, pero mientras caja no lo
# factura el pedido no le llega a ZAC: la tele pedía a gritos armar algo que el
# depósito ni veía, y no había forma de callarla más que entregarlo.

def _tv(monkeypatch):
    from app.config import settings
    from app.modules.monitor_entregas.router import monitor

    class _ReqTV:
        query_params = {"k": "tok-tele"}
        headers = {}

    monkeypatch.setattr(settings, "monitor_kiosk_token", "tok-tele")
    return lambda hoy: monitor(_ReqTV(), fecha=str(hoy), dia=None)


def test_la_tele_no_suena_mientras_el_pedido_sigue_en_caja(pg_tx, monkeypatch):
    ver = _tv(monkeypatch)
    hoy = date.today()
    user = _vendedor(pg_tx)
    # Cola de caja = FACTURADO 0: el pedido nace así y el estado todavía vacío.
    en_caja = factories.pedido(pg_tx, estado="", facturado=0, fecha=str(hoy))
    marcar_prioridad(en_caja["nro_fact"], PrioridadBody(prioritario=True), user)

    data = ver(hoy)
    assert data["prioritarios"] == []
    # …pero la tele SÍ lo avisa, mudo: "está por caer un prioritario", para que
    # el depósito lo vea venir en vez de descubrirlo cuando aparece gritando.
    assert [a["nro_fact"] for a in data["prioritarios_en_caja"]] == [en_caja["nro_fact"]]

    # El pedido igual viaja marcado: la card de la tele lo pinta, lo que no hay
    # es alarma. La prioridad no se pierde, se posterga.
    from app.modules.monitor_entregas import queries as mq
    from app.pg import fetch_all
    fila = {r["nrofact"]: r for r in fetch_all(mq.PEDIDOS_DEL_DIA_SQL, (hoy,))}[en_caja["nro_fact"]]
    assert (fila["prioritario"], fila["en_caja"]) == (True, True)


def test_apenas_caja_lo_factura_la_alarma_arranca(pg_tx, monkeypatch):
    ver = _tv(monkeypatch)
    hoy = date.today()
    user = _vendedor(pg_tx)
    ped = factories.pedido(pg_tx, estado="", facturado=0, fecha=str(hoy))
    nf = ped["nro_fact"]
    marcar_prioridad(nf, PrioridadBody(prioritario=True), user)
    assert ver(hoy)["prioritarios"] == []

    with pg_tx.cursor() as cur:   # caja lo factura
        cur.execute("UPDATE legacy.cabezal2 SET facturado = 1 WHERE nrofact = %s", (nf,))

    data = ver(hoy)
    assert [a["nro_fact"] for a in data["prioritarios"]] == [nf]
    # y el aviso de "viene" se apaga: ahora está en la alarma de verdad.
    assert data["prioritarios_en_caja"] == []


def test_un_dto_en_caja_tampoco_avisa(pg_tx, monkeypatch):
    """El aviso mudo hereda las mismas exclusiones que la alarma: un pedido de
    puros descuentos no se arma nunca, así que anunciarlo es ruido igual."""
    ver = _tv(monkeypatch)
    hoy = date.today()
    user = _vendedor(pg_tx)
    dto = _dto(pg_tx, estado="", facturado=0, fecha=str(hoy))
    factories.insertar(pg_tx, "ext.pedido_prioridad", documento="30  ",
                       nro_fact=dto["nro_fact"], marcado_por=user.id, activo=True)

    data = ver(hoy)
    assert (data["prioritarios"], data["prioritarios_en_caja"]) == ([], [])


# ── Quién lo marcó prioritario, en la cronología ────────────────────────────

def test_la_cronologia_dice_quien_lo_marco_prioritario(pg_tx):
    from app.modules.expedicion.router import cronologia_pedido

    fila = usuario_db(pg_tx, "venta")
    user = factories.usuario_operario("venta", id=fila["id"])
    ped = factories.pedido(pg_tx, estado="ASIGNADO")
    marcar_prioridad(ped["nro_fact"], PrioridadBody(prioritario=True), user)

    evs = [e for e in cronologia_pedido(ped["nro_fact"]) if e["tipo"] == "prioridad"]
    assert [(e["titulo"], e["usuario"]) for e in evs] == [("Marcado PRIORITARIO", fila["nombre"])]


def test_la_cronologia_tambien_muestra_cuando_se_la_sacaron(pg_tx):
    """Sacar la prioridad es una decisión tan auditable como ponerla: es lo que
    explica que un pedido que salió marcado terminara sin alarma."""
    from app.modules.expedicion.router import cronologia_pedido

    fila = usuario_db(pg_tx, "venta")
    user = factories.usuario_operario("venta", id=fila["id"])
    ped = factories.pedido(pg_tx, estado="ASIGNADO")
    marcar_prioridad(ped["nro_fact"], PrioridadBody(prioritario=True), user)
    marcar_prioridad(ped["nro_fact"], PrioridadBody(prioritario=False), user)

    evs = [e for e in cronologia_pedido(ped["nro_fact"]) if e["tipo"] == "prioridad"]
    assert [e["titulo"] for e in evs] == ["Marcado PRIORITARIO", "Prioridad SACADA"]
    assert evs[0]["detalle"] == "Después se le sacó la prioridad"
    assert all(e["usuario"] == fila["nombre"] for e in evs)
