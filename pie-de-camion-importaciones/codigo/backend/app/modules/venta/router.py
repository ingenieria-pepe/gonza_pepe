"""Módulo VENTA — el vendedor arma el pedido en la tablet y va directo a la cola
de caja de Macrosoft (Cabezal2/Lineas2, doc '30', FACTURADO=0) — indistinguible
del "Tomador de pedidos" original. Contrato relevado y verificado el 14/07
(memoria reference_tomador_pedidos_macrosoft).

Acceso gateado por el permiso `venta`; en ambientes sin Macrosoft conectado
(dev/testing) el envío se corta con 403 (settings.venta_escribe_macrosoft_real).
"""
import logging
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query

from app.config import settings
from app.core.categorias import categoria_de, icono_de, iconos_de_productos
from app.core.deps import CurrentUser, get_current_user, require_any_permission
from app.db import get_venta_cursor, venta_fetch_all
from app.modules.stock import curation as stock_curation
from app.modules.stock import queries as stock_q
from app.modules.usuarios import queries as uq
from app.modules.venta import queries as q
from app.modules.expedicion import queries as exp_q
from app.modules.venta.schemas import (
    ClienteCreate,
    ClienteCreado,
    CONSUMIDOR_FINAL_COD,
    AgregarLineasInput,
    ClienteVenta,
    EscrituraConfigVenta,
    LineaHistorial,
    LineaPedidoOut,
    LineasAgregadasOut,
    PedidoHistorial,
    PedidoHoyCliente,
    PedidoVentaCreado,
    PedidoVentaCreate,
    PedidoVentaDetail,
    PedidoVentaListItem,
    StockDisponibleArticulo,
    StockDisponibleResp,
    UltimoPrecio,
    UltimosPreciosInput,
    VentaVendedorInput,
    VentaVendedorItem,
    PrioridadBody,
)
from app.pg import fetch_all, fetch_one, get_cursor

logger = logging.getLogger("venta")

router = APIRouter(prefix="/venta", tags=["venta"])

TZ_UY = ZoneInfo("America/Montevideo")
_C2 = Decimal("0.01")  # cuantizador a 2 decimales (montos)


def _es_descuento(cod_art: str) -> bool:
    """Artículos 'D%' (D01 'Dto. Bananas madera'…): SIEMPRE van en un pedido '30'
    aparte — en el legacy hay cero pedidos mixtos (368 solo-descuento en mayo)."""
    return cod_art.strip().upper().startswith("D")


def _pedido_solo_descuentos(nro_fact: int) -> bool:
    """¿TODAS las líneas del pedido son descuentos? (pedido sin mercadería)."""
    r = fetch_one(q.ES_SOLO_DESCUENTOS_SQL, (nro_fact,))
    if not r:
        return False
    lineas = int(r["lineas"] or 0)
    return lineas > 0 and int(r["dtos"] or 0) == lineas


def _puede_ver_todos(user: CurrentUser) -> bool:
    return user.es_admin or bool({"admin", "venta_todos"} & user.permisos)


def _es_admin_total(user: CurrentUser) -> bool:
    return user.es_admin or "admin" in user.permisos


def _assert_escritura_habilitada() -> None:
    """Quién puede vender lo gatea el permiso `venta`. Acá solo cortamos si el
    ambiente NO tiene un Macrosoft real configurado (dev/testing sin VENTA_MSSQL_*
    ni CFE) → no se escribe (nunca contra el espejo)."""
    if not settings.venta_escribe_macrosoft_real:
        raise HTTPException(
            403,
            "En este ambiente no hay Macrosoft conectado — no se pueden enviar "
            "pedidos (es solo prueba de la pantalla).",
        )


@router.post(
    "/clientes",
    response_model=ClienteCreado,
    status_code=201,
    summary="Crear cliente nuevo en Macrosoft (alta mínima)",
    dependencies=[Depends(require_any_permission("venta", "venta_todos", "venta_admin"))],
)
def crear_cliente(body: ClienteCreate):
    """Alta mínima medida contra las 3.834 reales: código autogenerado
    (ref = MAX+2, cod = ref*100+1, bajo UPDLOCK), nace Activo como cliente
    común (C / lista 2 / UYU). Dual-write al espejo para que el picker lo vea
    al instante; el sync FULL lo pisa con la verdad de Macrosoft después."""
    _assert_escritura_habilitada()
    nombre = body.nombre.strip()
    with get_venta_cursor() as cur:
        cur.execute(q.CLIENTE_MAX_SQL)
        max_cod = (cur.fetchone() or {}).get("max_cod") or 0
        ref = (max_cod // 100) + 2
        cod = ref * 100 + 1
        cur.execute(q.CLIENTE_EXISTS_SQL, (cod,))
        if cur.fetchone():
            raise HTTPException(409, "Colisión de código de cliente; reintentá")
        cur.execute(q.CLIENTE_INSERT_SQL, (
            cod, ref, nombre,
            (body.nombre_fantasia or "").strip() or nombre,
            (body.ruc or "").strip() or None,
            (body.direccion or "").strip() or None,
            (body.telefono or "").strip() or None,
        ))
    # Espejo + cache: best-effort (si falla, el sync de 120s lo trae igual).
    try:
        with get_cursor() as pcur:
            pcur.execute(q.CLIENTE_ESPEJO_SQL, (
                cod, ref, nombre,
                (body.nombre_fantasia or "").strip() or nombre,
                (body.ruc or "").strip() or None,
                (body.direccion or "").strip() or None,
                (body.telefono or "").strip() or None,
            ))
        from app.core.lookups_cache import invalidate_prefix

        invalidate_prefix("lookups.clientes")
    except Exception:  # noqa: BLE001
        logging.getLogger("app.venta").warning("dual-write cliente falló", exc_info=True)
    return ClienteCreado(cod=cod, nombre=nombre)



# ── Config de escritura (banner del front) ───────────────────────────────

@router.get(
    "/escritura-config",
    response_model=EscrituraConfigVenta,
    dependencies=[Depends(require_any_permission("venta", "venta_todos", "venta_admin"))],
)
def escritura_config():
    return EscrituraConfigVenta(conectado=settings.venta_escribe_macrosoft_real)


# ── Stock disponible (para no vender dos veces lo mismo) ─────────────────

@router.get(
    "/stock-colores",
    summary="Stock vivo por COLOR de banana (cámaras × Charlie − ventas)",
    dependencies=[Depends(require_any_permission("venta", "venta_todos", "venta_admin"))],
)
def stock_colores():
    """Estimativo y JAMÁS bloquea la venta: cajas de las cámaras que hoy están
    en cada color (Charlie) − vendido hoy − comprometido en pedidos abiertos."""
    from app.modules.venta.stock_colores import stock_por_color_cacheado

    return stock_por_color_cacheado()



@router.get(
    "/stock-disponible",
    response_model=StockDisponibleResp,
    summary="Disponible por artículo = saldo de su familia − pedidos vigentes",
    dependencies=[Depends(require_any_permission("venta", "venta_todos", "venta_admin"))],
)
def stock_disponible():
    """Lo que el saldo oficial de Macrosoft no puede decir.

    El pedido '30' no descuenta stock (lo descuenta la factura de caja), así que
    entre que un vendedor carga y que caja factura, el saldo no se mueve y otro
    vendedor puede vender la misma fruta. Acá se le restan los pedidos vigentes.

    El comprometido sale del espejo de `cabezal2`, así que funciona igual si el
    pedido se cargó desde Aloha o desde el tomador viejo de Macrosoft.

    Latencia: el pedido propio sin enviar lo resta el front contra el borrador
    (instantáneo); el de otro vendedor llega en <=15 s (ciclo del mirror); la baja
    real de caja, en <=5 min (recálculo DOYSTOCK).

    Va en el router de Venta y no en el de Stock porque aquel tiene
    `require_permission("stock")` a nivel router y los vendedores no lo tienen.
    """
    filas = fetch_all(
        stock_q.STOCK_DISPONIBLE_VENTA_SQL,
        (list(stock_curation.FAMILIAS_SIN_STOCK_VENDIBLE),),
    )

    actualizado_en = None
    for f in filas:
        ts = f.get("actualizado_en")
        if ts and (actualizado_en is None or ts > actualizado_en):
            actualizado_en = ts

    return StockDisponibleResp(
        generado_en=datetime.now(tz=timezone.utc),
        macrosoft_actualizado_en=actualizado_en,
        disponible=[
            StockDisponibleArticulo(
                cod_art=f["cod_art"],
                cod_stock=f["codstock"],
                familia=f["familia"],
                saldo_familia=float(f["saldo_familia"] or 0),
                comprometido=float(f["comprometido"] or 0),
                disponible=float(f["disponible"] or 0),
                pedidos_pendientes=int(f["pedidos_pendientes"] or 0),
                ranking=int(f["ranking"] or 0),
            )
            for f in filas
        ],
    )


# ── Clientes / precios (lecturas del espejo) ─────────────────────────────

@router.get(
    "/clientes",
    response_model=list[ClienteVenta],
    # `caja` también: al fraccionar, el cajero elige a qué cliente se le factura
    # cada parte (puede ser otro distinto al del pedido). Lectura amplia, como
    # manda la regla de permisos del proyecto.
    dependencies=[Depends(require_any_permission("venta", "venta_todos", "caja", "admin"))],
)
def search_clientes(
    q_: str = Query("", alias="q", description="nombre, RUT o código"),
    limit: int = Query(30, ge=1, le=100),
):
    """Busca en el espejo de Clientes por nombre (acento-insensible), RUT
    (prefijo) o código (prefijo). Ordena por actividad reciente (90d) para que
    el homónimo correcto salga primero (misma lección que el picker de Pre-carga)."""
    term = q_.strip()
    if not term:
        return []
    rows = fetch_all(q.SEARCH_CLIENTES_SQL, (term, term, term, limit))
    return [
        ClienteVenta(
            cod=r["codcliente"],
            nombre=r["nombre"],
            ruc=r["ruc"] or "",
            direccion=r["direccion"] or "",
            moneda=r["moneda"],
            estado_cliente=r["estado_cliente"] or "",
            pedidos_recientes=r["pedidos_recientes"],
        )
        for r in rows
    ]


@router.post(
    "/ultimos-precios",
    response_model=list[UltimoPrecio],
    dependencies=[Depends(require_any_permission("venta", "venta_todos"))],
)
def ultimos_precios(body: UltimosPreciosInput):
    """Precio de cada artículo para el tomador. Desde el 27/07 la base es el
    precio de LISTA que fija Valeria en Macrosoft (CambiosDePrecios/Precios,
    según la lista del cliente — Clientes.TiposPrecios). Los últimos vendidos
    (a este cliente / global) siguen viajando como referencia y fallback para
    artículos sin precio de lista."""
    cods = [c.strip() for c in body.cod_arts if c.strip()]
    if not cods:
        return []

    # Lista de precios del cliente (default 2 "Venta Público" — el 98% de la
    # clientela). Sin cliente todavía elegido, se usa la 2 igual: el precio de
    # lista no depende del historial.
    lista_cliente = 2
    if body.cliente_cod:
        cli = fetch_one(q.GET_CLIENTE_SQL, (body.cliente_cod,))
        if cli:
            lista_cliente = int(cli["lista_precio"])

    # Precio de lista (espejo de Precios/CambiosDePrecios). Best-effort: si las
    # tablas todavía no existen (ventana del deploy hasta que corra el mirror
    # nuevo), seguimos con última-venta como antes.
    listas: dict[str, dict] = {}
    try:
        for r in fetch_all(q.PRECIOS_LISTA_SQL, (lista_cliente, cods, lista_cliente, lista_cliente)):
            if r["precio"] is not None:
                listas[r["cod"]] = r
    except Exception:
        logger.warning("precios de lista no disponibles (¿espejo sin sincronizar?)")

    por_cliente: dict[str, dict] = {}
    if body.cliente_cod:
        for r in fetch_all(q.ULTIMOS_PRECIOS_CLIENTE_SQL, (body.cliente_cod, cods)):
            por_cliente[r["cod"]] = r
    globales: dict[str, dict] = {}
    for r in fetch_all(q.ULTIMOS_PRECIOS_GLOBAL_SQL, (cods,)):
        globales[r["cod"]] = r

    def _fecha(r: dict | None) -> str | None:
        return r["fecha"].date().isoformat() if r and r.get("fecha") else None

    return [
        UltimoPrecio(
            cod_art=c,
            precio_lista=float(listas[c]["precio"]) if c in listas else None,
            precio=float(por_cliente[c]["precio"]) if c in por_cliente else None,
            fecha=_fecha(por_cliente.get(c)),
            precio_global=float(globales[c]["precio"]) if c in globales else None,
            fecha_global=_fecha(globales.get(c)),
        )
        for c in cods
    ]


@router.get(
    "/clientes/{cod}/historial",
    response_model=list[PedidoHistorial],
    dependencies=[Depends(require_any_permission("venta", "venta_todos"))],
)
def historial_cliente(cod: int, limit: int = Query(3, ge=1, le=10)):
    """Últimas N compras del cliente (por defecto 3), con el precio que le hicimos
    y los bultos por producto — referencia para cotizar. Del espejo (30 días)."""
    heads = fetch_all(q.HISTORIAL_PEDIDOS_SQL, (cod, limit))
    if not heads:
        return []
    nrofacts = [h["nrofact"] for h in heads]
    por_pedido: dict[int, list] = defaultdict(list)
    for l in fetch_all(q.HISTORIAL_LINEAS_SQL, (nrofacts,)):
        por_pedido[l["nrofact"]].append(l)

    out: list[PedidoHistorial] = []
    for h in heads:
        lineas = [
            LineaHistorial(
                cod_art=l["cod_art"],
                descripcion=l["descripcion"],
                cantidad=float(l["cantidad"] or 0),
                precio=float(l["precio"] or 0),
                total_linea=float(l["totallinea"] or 0),
                icono=(icono_de(cat_) if (cat_ := categoria_de(l["descripcion"])) else None),
            )
            for l in por_pedido.get(h["nrofact"], [])
        ]
        out.append(PedidoHistorial(
            nro_fact=h["nrofact"],
            nro_doc=h["nrodoc"] or str(h["nrofact"]),
            fecha=h["fecha"].date().isoformat() if h.get("fecha") else None,
            vendedor_nombre=(h.get("vendedor_nombre") or "").strip() or None,
            total=sum(x.total_linea for x in lineas),
            lineas=lineas,
        ))
    return out


@router.get(
    "/clientes/{cod}/pedidos-hoy",
    response_model=list[PedidoHoyCliente],
    dependencies=[Depends(require_any_permission("venta", "venta_todos"))],
)
def pedidos_hoy_cliente(cod: int):
    """Pedidos de HOY (día UY) del cliente con su situación operativa. El tomador
    lo usa al elegir cliente: si hay pedidos, ofrece 'agregar productos' — al
    MISMO pedido si sigue en caja, o como pedido nuevo ENCADENADO si ya salió.
    Best-effort: sin la mig 0062 (ventana de deploy) devuelve la lista sin el
    campo agregado_de antes que romper el tomador."""
    try:
        rows = fetch_all(q.PEDIDOS_HOY_CLIENTE_SQL, (cod,))
    except Exception:
        logger.warning("pedidos-hoy sin ext.pedido_agregado (¿mig 0062 pendiente?)")
        return []
    if not rows:
        return []
    # Resumen legible de líneas ("40× Banana Brasil · 10× Kiwi Chile") por pedido.
    por_pedido: dict[int, list[str]] = defaultdict(list)
    for l in fetch_all(q.LIST_LINEAS_RESUMEN_SQL, ([r["nrofact"] for r in rows],)):
        cant = float(l["cantidad"] or 0)
        cant_txt = str(int(cant)) if cant == int(cant) else f"{cant:g}"
        por_pedido[l["nrofact"]].append(f"{cant_txt}× {(l['descripcion'] or '').strip()}")
    out = []
    for r in rows:
        partes = por_pedido.get(r["nrofact"], [])
        resumen = " · ".join(partes[:4]) + (f" · +{len(partes) - 4} más" if len(partes) > 4 else "")
        out.append(PedidoHoyCliente(
            nro_fact=r["nrofact"],
            nro_doc=r["nro_doc"] or str(r["nrofact"]),
            hora=r.get("hora"),
            credito=bool(r.get("credito")),
            en_caja=bool(r["en_caja"]),
            estado=r.get("estado") or "",
            deposito=r.get("deposito"),
            total=float(r.get("total") or 0),
            items_count=int(r.get("items_count") or 0),
            solo_descuentos=bool(r.get("solo_descuentos")),
            armador_nombre=(r.get("armador_nombre") or "").strip(),
            armado=bool(r.get("armado")),
            entregado_registrado=bool(r.get("entregado_registrado")) or (r.get("estado") == "ENTREGADO"),
            agregado_de=r.get("agregado_de"),
            resumen=resumen,
        ))
    return out


# ── Agregar líneas a un pedido que SIGUE en caja (caso A) ────────────────

@router.post(
    "/pedidos/{nro_fact}/agregar-lineas",
    response_model=LineasAgregadasOut,
    dependencies=[Depends(require_any_permission("venta"))],
)
def agregar_lineas(nro_fact: int, body: AgregarLineasInput, user: CurrentUser = Depends(get_current_user)):
    """Agrega líneas a un pedido '30' que TODAVÍA está en la cola de caja
    (FACTURADO=0). Contrato NATIVO verificado con datos de prod (28/07): el
    tomador viejo hace exactamente esto a diario — INSERT de Lineas2 copiando
    NroDoc/Fecha/Depósito del pedido, SIN tocar el cabezal (caja factura
    recalculando desde las líneas; los totales del cabezal quedan viejos también
    cuando edita el tomador original — indistinguible).

    Anti-carrera: el SELECT del cabezal va con UPDLOCK+HOLDLOCK y filtro
    FACTURADO=0 → si caja lo está facturando, esperamos; si ya lo facturó, no
    hay fila → 409 y el front ofrece crear un pedido ENCADENADO (caso B).
    """
    _assert_escritura_habilitada()

    if any(_es_descuento(l.cod_art) for l in body.lineas):
        raise HTTPException(
            400,
            "Los descuentos (Dto.) van en un pedido aparte — no se agregan a un pedido de mercadería.",
        )

    lineas_calc, total_agregado, _sub, _iva, _uni = _resolver_lineas(body.lineas)

    # El pedido destino tiene que ser de ESTE cliente y de HOY (candado contra
    # borradores viejos / número equivocado — se re-chequea con el espejo, que
    # para cliente/fecha nunca cambia después de creado el pedido).
    cab_esp = fetch_one(q.GET_CABEZAL_ESPEJO_SQL, (nro_fact,))
    if not cab_esp:
        raise HTTPException(404, "Ese pedido no existe.")
    if int(cab_esp["codcliente"] or 0) != body.cliente_cod:
        raise HTTPException(400, "Ese pedido es de OTRO cliente — revisá el número.")
    if not cab_esp["es_de_hoy"]:
        raise HTTPException(
            409,
            "YA_FACTURADO: Ese pedido no es de hoy — no se le pueden agregar líneas.",
        )

    # Idempotencia (mismo mecanismo que crear): reservar el ref antes de escribir.
    with get_cursor() as pcur:
        pcur.execute(q.RESERVAR_ENVIO_SQL, (body.ref, user.id))
        if pcur.rowcount == 0:
            pcur.execute(q.GET_ENVIO_SQL, (body.ref,))
            envio = pcur.fetchone()
            if envio and envio.get("nro_fact"):
                # Reintento de un agregado que YA entró: devolver lo guardado
                # (total real desde el espejo — 0 acá pintaba "totaliza $0").
                tot = fetch_one(q.TOTAL_LINEAS_ESPEJO_SQL, (envio["nro_fact"],))
                return LineasAgregadasOut(
                    nro_fact=envio["nro_fact"],
                    nro_doc=envio["nro_doc"] or str(envio["nro_fact"]),
                    lineas_agregadas=len(body.lineas),
                    total_agregado=float(envio["total"] or 0),
                    total_pedido=float(tot["total"]) if tot else 0,
                )
            # OJO: este 409 NO lleva el prefijo YA_FACTURADO — el front NO debe
            # auto-convertirlo en encadenado (el envío original puede estar aún
            # en vuelo; convertir acá duplicaría la mercadería).
            raise HTTPException(
                409,
                "Ese envío ya se está procesando (o quedó a medias). Revisá el pedido "
                "antes de volver a intentar.",
            )

    max_id_previo: int | None = None
    try:
        with get_venta_cursor() as cur:
            # Si caja tiene lockeado ESTE cabezal (lo está facturando), cortar a
            # los 5s en vez de colgar la request (el vendedor reintentaría).
            cur.execute(q.SET_LOCK_TIMEOUT_MSSQL)
            cur.execute(q.LOCK_PEDIDO_EN_CAJA_MSSQL, (nro_fact,))
            cab = cur.fetchone()
            if not cab:
                # Ya facturado / anulado → el front ofrece encadenar (caso B).
                # El prefijo YA_FACTURADO es el marcador ESTABLE para ese switch:
                # ningún otro 409 debe llevarlo.
                raise HTTPException(
                    409,
                    "YA_FACTURADO: El pedido ya salió de caja (o está anulado): no se "
                    "le pueden agregar líneas. Se envía como pedido AGREGADO encadenado.",
                )
            cur.execute(q.LINEAS_INFO_MSSQL, (nro_fact,))
            info = cur.fetchone() or {}
            if int(info.get("n_dto") or 0) > 0:
                raise HTTPException(400, "Ese pedido es de descuentos — no se le agrega mercadería.")
            max_id_previo = int(info.get("max_id") or 0)
            cur.execute(q.ULTIMO_DEPOSITO_LINEA_MSSQL, (nro_fact,))
            dep_row = cur.fetchone()
            deposito = (dep_row["deposito"] if dep_row else None) or "A"
            nro_doc = str(cab["NRODOC"] or "").strip() or str(nro_fact)
            fecha = cab["FECHA"]
            moneda = int(cab["MONEDA"] or 1)
            for lc in lineas_calc:
                cur.execute(q.INSERT_LINEA2_MSSQL, (
                    fecha, nro_fact, nro_doc,
                    deposito, lc["cod"], lc["descripcion"],
                    lc["cantidad"], lc["iva_tasa"], moneda,
                    lc["precio"],
                    lc["iva_linea"], lc["sin_iva"], lc["total_linea"], lc["total_linea"],
                ))
            # Sin esto, caja factura el TOTALDEBE viejo y lo agregado no se
            # cobra. Va DENTRO de la misma transacción que los INSERT y bajo el
            # mismo UPDLOCK del cabezal: o entran las líneas y el total, o nada.
            cur.execute(q.SYNC_TOTALES_CABEZAL_MSSQL, (nro_fact,))
    except Exception as exc:
        # ¿Liberar la reserva? Solo si estamos SEGUROS de que Macrosoft no
        # commiteó. Un corte de red DURANTE el commit (commit in-doubt) también
        # cae acá con las líneas YA insertadas — liberar en ese caso habilita a
        # que el reintento del mismo ref las inserte DE NUEVO (duplica bultos).
        if isinstance(exc, HTTPException) or max_id_previo is None:
            liberar = True  # guard propio o falló antes de intentar el INSERT
        else:
            try:
                # Conexión FRESCA: ¿aparecieron líneas nuevas? → el commit entró.
                nuevas = venta_fetch_all(q.READBACK_LINEAS_DESDE_MSSQL, (nro_fact, max_id_previo))
                if nuevas:
                    with get_cursor() as pcur:
                        pcur.execute(q.COMPLETAR_ENVIO_SQL, (
                            nro_fact, str(nro_fact), total_agregado, body.ref,
                        ))
                    liberar = False  # el retry cae en la rama idempotente y no duplica
                else:
                    liberar = True   # rollback real
            except Exception:
                # Ni readback pudimos: dejar la reserva "a medias" (el retry da
                # 409 con "revisá el pedido" — revisión humana antes que duplicar).
                liberar = False
        if liberar:
            try:
                with get_cursor() as pcur:
                    pcur.execute(q.LIBERAR_ENVIO_SQL, (body.ref,))
            except Exception:
                logger.warning("no pude liberar la reserva %s", body.ref, exc_info=True)
        raise

    # ── Post-commit. COMPLETAR va en SU PROPIA tx (si compartiera tx con la
    # auditoría y ésta fallara —p.ej. mig 0062 sin correr—, el rollback dejaría
    # el ref "a medias" para siempre y el retry daría 409 eterno).
    try:
        with get_cursor() as pcur:
            pcur.execute(q.COMPLETAR_ENVIO_SQL, (nro_fact, nro_doc, total_agregado, body.ref))
    except Exception:
        logger.warning("no pude completar la reserva %s", body.ref, exc_info=True)
    detalle = " · ".join(
        f"{lc['cantidad']:g}× {lc['descripcion']} (${lc['precio']:g})" for lc in lineas_calc
    )
    try:
        with get_cursor() as pcur:
            pcur.execute(q.INSERT_LINEA_AGREGADA_SQL, (nro_fact, user.id, detalle, total_agregado))
    except Exception:
        logger.warning("auditoría de agregar-líneas %s no se pudo guardar", nro_fact, exc_info=True)

    total_pedido = float(total_agregado)
    try:
        nuevas = venta_fetch_all(q.READBACK_LINEAS_DESDE_MSSQL, (nro_fact, max_id_previo))
        todas = venta_fetch_all(q.READBACK_LINEAS2_MSSQL, (nro_fact,))
        total_pedido = float(sum(float(l["TotalLinea"] or 0) for l in todas))
        with get_cursor() as pcur:
            for l in nuevas:
                pcur.execute(q.INSERT_LEGACY_LINEA2_SQL, (
                    l["ID"], l["Fecha"], l["Documento"], l["NroFact"], l["NroDoc"],
                    l["Deposito"], l["CodArt"], l["Descripcion"], l["CantidadHaber"],
                    l["Precio"], l["TotalLinea"],
                ))
    except Exception:
        logger.warning("dual-write de líneas agregadas %s falló (el mirror lo trae solo)",
                       nro_fact, exc_info=True)

    return LineasAgregadasOut(
        nro_fact=nro_fact,
        nro_doc=nro_doc,
        lineas_agregadas=len(lineas_calc),
        total_agregado=float(total_agregado),
        total_pedido=total_pedido,
    )


def _resolver_lineas(lineas_in) -> tuple[list[dict], Decimal, Decimal, Decimal, Decimal]:
    """Resuelve artículos y calcula cada línea con el contrato del tomador
    (precio CON IVA incluido; TotalSinIva/IvaLinea POR LÍNEA). Compartido por
    crear pedido y agregar-líneas. Devuelve (lineas_calc, total, subtotal,
    iva_total, unidades)."""
    lineas_calc: list[dict] = []
    total = Decimal("0")
    subtotal = Decimal("0")
    iva_total = Decimal("0")
    unidades = Decimal("0")
    for l in lineas_in:
        art = fetch_one(q.GET_ARTICULO_SQL, (l.cod_art.strip(),))
        if not art:
            raise HTTPException(400, f"Artículo {l.cod_art.strip()} no existe en el catálogo")
        cant = Decimal(str(l.cantidad))
        precio = Decimal(str(l.precio)).quantize(_C2, ROUND_HALF_UP)
        iva_tasa = Decimal(str(art["iva_tasa"]))
        total_linea = (cant * precio).quantize(_C2, ROUND_HALF_UP)
        # Lineas2.TotalLinea es numeric(10,2) → tope duro con error legible en
        # vez de un 500 de arithmetic overflow de SQL Server.
        if total_linea > Decimal("9999999.99"):
            raise HTTPException(
                400,
                f"El total de la línea {art['descripcion']} es demasiado grande "
                f"(${total_linea:,.0f}) — revisá cantidad y precio.",
            )
        sin_iva = (total_linea / (1 + iva_tasa)).quantize(_C2, ROUND_HALF_UP)
        iva_linea = total_linea - sin_iva
        lineas_calc.append({
            "cod": art["cod"],
            "descripcion": art["descripcion"][:100],
            "cantidad": cant,
            "precio": precio,
            "iva_tasa": iva_tasa,
            "total_linea": total_linea,
            "sin_iva": sin_iva,
            "iva_linea": iva_linea,
        })
        total += total_linea
        subtotal += sin_iva
        iva_total += iva_linea
        unidades += cant
    return lineas_calc, total, subtotal, iva_total, unidades


# ── Crear pedido ─────────────────────────────────────────────────────────

@router.post(
    "/pedidos",
    response_model=PedidoVentaCreado,
    status_code=201,
    dependencies=[Depends(require_any_permission("venta"))],
)
def crear_pedido(body: PedidoVentaCreate, user: CurrentUser = Depends(get_current_user)):
    _assert_escritura_habilitada()

    # Vendedor del usuario (lo asigna el admin en Venta → Vendedores).
    vrow = fetch_one(q.GET_VENDEDOR_DE_USUARIO_SQL, (user.id,))
    if not vrow:
        raise HTTPException(
            400,
            "No tenés número de vendedor asignado. Pedile a un administrador que te "
            "lo asigne en Venta → Vendedores.",
        )
    vendedor = int(vrow["vendedor"])

    cliente = fetch_one(q.GET_CLIENTE_SQL, (body.cliente_cod,))
    if not cliente:
        raise HTTPException(404, "Cliente no encontrado")

    # Reglas de mezcla: los descuentos (D%) van en pedido aparte (así lo hace el
    # legacy SIEMPRE — caja los liquida distinto).
    n_dto = sum(1 for l in body.lineas if _es_descuento(l.cod_art))
    if 0 < n_dto < len(body.lineas):
        raise HTTPException(
            400,
            "Los descuentos (Dto.) van en un pedido aparte: crea un pedido solo con "
            "los descuentos y otro con la mercadería.",
        )

    # Resolver artículos (descripción + tasa de IVA real vía catálogo Ivas).
    # Mismos cálculos que el tomador (verificados línea a línea).
    lineas_calc, total, subtotal, iva_total, unidades = _resolver_lineas(body.lineas)

    # AGREGADO encadenado (caso B): validar el original ANTES de escribir nada.
    # Para Macrosoft este pedido es 100% normal; el vínculo es solo de Aloha.
    agregado_raiz: int | None = None
    if body.agregado_de:
        orig = fetch_one(q.GET_CABEZAL_ESPEJO_SQL, (body.agregado_de,))
        if not orig:
            raise HTTPException(404, "El pedido original del agregado no existe.")
        if int(orig["codcliente"] or 0) != body.cliente_cod:
            raise HTTPException(400, "El pedido original es de OTRO cliente — no se puede encadenar.")
        if orig["anulada"]:
            raise HTTPException(409, "El pedido original está anulado — crealo como pedido normal.")
        if not orig["es_de_hoy"]:
            raise HTTPException(
                409,
                "El pedido original no es de HOY — un agregado se encadena solo a "
                "pedidos del día. Crealo como pedido normal.",
            )
        # Si el elegido ya es un agregado, encadenar a SU raíz (grupo único).
        try:
            raiz = fetch_one(q.GET_RAIZ_AGREGADO_SQL, (body.agregado_de,))
        except Exception:
            raiz = None  # mig 0062 todavía sin correr — se encadena directo
        agregado_raiz = int(raiz["nro_fact_original"]) if raiz else body.agregado_de

    # Datos que el pedido copia del cliente (contrato verificado 400/400).
    nombre = cliente["nombre"]
    if body.cliente_cod == CONSUMIDOR_FINAL_COD and (body.consumidor_nombre or "").strip():
        nombre = body.consumidor_nombre.strip()
    consumo_final = 0 if cliente["ruc"] else 1

    ahora = datetime.now(TZ_UY).replace(tzinfo=None)
    fecha = ahora.replace(hour=0, minute=0, second=0, microsecond=0)
    hora = ahora.replace(second=0, microsecond=0)  # el tomador trunca al minuto
    observaciones = (body.observaciones or "").strip()[:100]  # Cabezal2 char(100)

    # ── Idempotencia: reservar el ref ANTES de tocar Macrosoft. Si ya existe,
    # es un reintento: con nro_fact → devolver el pedido ya creado; sin nro_fact
    # → otro envío del mismo ref está (o quedó) en curso.
    with get_cursor() as pcur:
        pcur.execute(q.RESERVAR_ENVIO_SQL, (body.ref, user.id))
        if pcur.rowcount == 0:
            pcur.execute(q.GET_ENVIO_SQL, (body.ref,))
            envio = pcur.fetchone()
            if envio and envio.get("nro_fact"):
                return PedidoVentaCreado(
                    nro_fact=envio["nro_fact"],
                    nro_doc=envio["nro_doc"] or str(envio["nro_fact"]),
                    total=float(envio["total"] or 0),
                )
            raise HTTPException(
                409,
                "Ese envío ya se está procesando (o quedó a medias). Fijate en "
                "Pedidos si el pedido entró antes de volver a intentar.",
            )

    # ── Escritura en Macrosoft: numeración + cabezal + líneas, UNA transacción.
    try:
        with get_venta_cursor() as cur:
            cur.execute(q.NEXT_NROFACT_MSSQL)
            nro_fact = int(cur.fetchone()["next_fact"])
            cur.execute(q.GET_NRODOC_MSSQL)
            doc_row = cur.fetchone()
            if not doc_row:
                raise HTTPException(500, "No existe el documento '30' en el catálogo Documentos")
            nro_doc = int(doc_row["NroDocumento"]) + 1
            cur.execute(q.UPDATE_NRODOC_MSSQL, (nro_doc,))

            cur.execute(q.INSERT_CABEZAL2_MSSQL, (
                fecha, consumo_final, nombre[:100], cliente["direccion"][:80], cliente["ruc"][:20],
                nro_fact, str(nro_doc), vendedor, body.cliente_cod, int(cliente["lista_precio"]),
                int(cliente["moneda"]),
                unidades, subtotal, iva_total, total,
                1 if body.credito else 0, total, hora,
                observaciones,
            ))
            for lc in lineas_calc:
                cur.execute(q.INSERT_LINEA2_MSSQL, (
                    fecha, nro_fact, str(nro_doc),
                    body.deposito, lc["cod"], lc["descripcion"],
                    lc["cantidad"], lc["iva_tasa"], int(cliente["moneda"]),
                    lc["precio"],
                    lc["iva_linea"], lc["sin_iva"], lc["total_linea"], lc["total_linea"],
                ))
    except Exception:
        # Macrosoft NO commiteó → liberar la reserva para que el reintento entre.
        try:
            with get_cursor() as pcur:
                pcur.execute(q.LIBERAR_ENVIO_SQL, (body.ref,))
        except Exception:
            logger.warning("no pude liberar la reserva %s", body.ref, exc_info=True)
        raise

    # ── Post-commit: completar la reserva (idempotencia) + meta + espejo.
    # La reserva es lo primero: si esto falla, el reintento del mismo ref da 409
    # con aviso de "mirá en Pedidos" en vez de duplicar.
    try:
        with get_cursor() as pcur:
            pcur.execute(q.COMPLETAR_ENVIO_SQL, (nro_fact, str(nro_doc), total, body.ref))
            pcur.execute(q.INSERT_PEDIDO_META_SQL, (
                nro_fact, str(nro_doc), user.id, vendedor, body.cliente_cod, total,
            ))
            if body.prioritario and not all(_es_descuento(l.cod_art) for l in body.lineas):
                # Nace PRIORITARIO: va directo arriba en asignación + alarma tele.
                # Un pedido de puros descuentos NO: no se arma ni se entrega, la
                # alarma no se apagaría nunca. El tomador ya esconde el botón;
                # esto es el cinturón por si llega el flag igual.
                pcur.execute(exp_q.MARCAR_PRIORIDAD_SQL, ("30  ", nro_fact, user.id))
    except Exception:
        logger.warning("meta/envío de pedido %s no se pudo guardar", nro_fact, exc_info=True)

    # Vínculo de agregado (caso B) — try propio: si falla (mig 0062 sin correr),
    # el pedido ya existe en Macrosoft y NO se pierde nada más que el encadenado.
    if agregado_raiz:
        try:
            with get_cursor() as pcur:
                pcur.execute(q.INSERT_PEDIDO_AGREGADO_SQL, (nro_fact, agregado_raiz, user.id))
        except Exception:
            logger.warning("no pude encadenar %s → %s", nro_fact, agregado_raiz, exc_info=True)

    _dual_write_pedido_to_legacy(nro_fact)

    return PedidoVentaCreado(nro_fact=nro_fact, nro_doc=str(nro_doc), total=float(total))


def _dual_write_pedido_to_legacy(nro_fact: int) -> None:
    """Copia el pedido recién creado al espejo PG para verlo al instante en los
    listados (el mirror lo pisa con lo mismo en <=15s). Best-effort."""
    try:
        cab = venta_fetch_all(q.READBACK_CABEZAL2_MSSQL, (nro_fact,))
        lins = venta_fetch_all(q.READBACK_LINEAS2_MSSQL, (nro_fact,))
        with get_cursor() as cur:
            for c in cab:
                cur.execute(q.INSERT_LEGACY_CABEZAL2_SQL, (
                    c["DOCUMENTO"], c["NROFACT"], c["NRODOC"], c["FECHA"], c["HORA"],
                    c["NOMBRE"], c["CODCLIENTE"], c["CODVENDEDOR"], c["ESTADO"],
                    c["OBSERVACIONES"], c["FACTURADO"], c["TOTALHABER"], c["ANULADA"],
                    c["DIRECCION"], c["TOTALDEBE"], c["ENCUOTAS"], c["CONSUMOFINAL"],
                ))
            for l in lins:
                cur.execute(q.INSERT_LEGACY_LINEA2_SQL, (
                    l["ID"], l["Fecha"], l["Documento"], l["NroFact"], l["NroDoc"],
                    l["Deposito"], l["CodArt"], l["Descripcion"], l["CantidadHaber"],
                    l["Precio"], l["TotalLinea"],
                ))
    except Exception:
        logger.warning(
            "dual-write a legacy falló para pedido %s (el mirror lo trae solo)",
            nro_fact, exc_info=True,
        )


# ── Prioridad ────────────────────────────────────────────────────────────

@router.post(
    "/pedidos/{nro_fact}/prioridad",
    dependencies=[Depends(require_any_permission("venta", "venta_todos"))],
)
def marcar_prioridad(
    nro_fact: int,
    body: PrioridadBody,
    user: CurrentUser = Depends(get_current_user),
):
    """El vendedor marca (o desmarca) un pedido como PRIORITARIO: tiene que
    salir YA. Se refleja en Asignación (arriba de todo, con glow), en el celu
    del armador y en la tele de entregas (alarma). Vale para CUALQUIER pedido
    '30' vivo — también los del tomador viejo (no hace falta que haya nacido
    en Aloha). Marca en ext.*: no toca Macrosoft."""
    ped = fetch_one(q.GET_PEDIDO_30_SQL, (nro_fact,))
    if not ped:
        raise HTTPException(404, f"Pedido {nro_fact} no encontrado")
    if body.prioritario and int(ped["anulada"] or 0):
        raise HTTPException(400, "El pedido está anulado — no tiene sentido priorizarlo.")
    # Un pedido de DESCUENTOS no lleva mercadería: no se arma, no se controla y
    # no se entrega. Marcarlo prioritario no le avisa a NADIE (no aparece en el
    # celu del armador) y encima la tele quedaba sonando para siempre, porque la
    # alarma se apaga recién cuando el pedido se entrega. Pasó el 31/08.
    # Quitar la prioridad se puede SIEMPRE: si no, un dto marcado de antes
    # quedaba trabado sin forma de apagarlo.
    if body.prioritario and _pedido_solo_descuentos(nro_fact):
        raise HTTPException(
            400,
            "Es un pedido de descuentos: no se arma ni se entrega, así que marcarlo "
            "prioritario no le avisa a nadie. Marcá el pedido de la mercadería.",
        )
    with get_cursor() as cur:
        if body.prioritario:
            cur.execute(exp_q.MARCAR_PRIORIDAD_SQL, ("30  ", nro_fact, user.id))
        else:
            cur.execute(exp_q.DESMARCAR_PRIORIDAD_SQL, (user.id, "30  ", nro_fact))
    return {"nro_fact": nro_fact, "prioritario": body.prioritario}


# ── Anular ───────────────────────────────────────────────────────────────

@router.post(
    "/pedidos/{nro_fact}/anular",
    dependencies=[Depends(require_any_permission("venta", "venta_todos"))],
)
def anular_pedido(nro_fact: int, user: CurrentUser = Depends(get_current_user)):
    """Anula un pedido creado desde Aloha ANTES de que caja lo facture. Efecto
    idéntico al del tomador para la cola de caja (ANULADA=1 + FACTURADO=1), pero
    sin borrar líneas ni pisar el nombre (no destruimos datos)."""
    _assert_escritura_habilitada()

    meta = fetch_one(q.GET_PEDIDO_META_SQL, (nro_fact,))
    if not meta:
        raise HTTPException(404, "Ese pedido no fue creado desde Aloha — anulalo desde el sistema viejo.")
    # Anular es ESCRITURA: solo el dueño del pedido o un admin. `venta_todos` es
    # un permiso de lectura y no alcanza.
    if meta["usuario_id"] != user.id and not _es_admin_total(user):
        raise HTTPException(403, "Solo podés anular tus propios pedidos.")
    if meta.get("anulado_en"):
        raise HTTPException(409, "Ese pedido ya está anulado.")

    with get_venta_cursor() as cur:
        cur.execute(q.ANULAR_PEDIDO_MSSQL, (nro_fact,))
        if cur.rowcount != 1:
            raise HTTPException(
                409, "No se pudo anular: el pedido ya pasó por caja (o ya estaba anulado).",
            )

    try:
        with get_cursor() as pcur:
            pcur.execute(q.ANULAR_LEGACY_CABEZAL2_SQL, (nro_fact,))
            pcur.execute(q.ANULAR_PEDIDO_META_SQL, (user.id, nro_fact))
    except Exception:
        logger.warning("post-anulación PG falló para pedido %s", nro_fact, exc_info=True)
    return {"ok": True}


# ── Listados ─────────────────────────────────────────────────────────────

def _estado_chip(r: dict) -> str:
    if r["anulada"]:
        return "anulado"
    if not r["facturado"]:
        return "en_caja"
    estado = (r["estado"] or "").strip().lower()
    return estado or "facturado"


def _list_item(r: dict, user: CurrentUser, ver_todos: bool) -> PedidoVentaListItem:
    es_mio = r.get("creado_por_usuario_id") == user.id
    return PedidoVentaListItem(
        nro_fact=r["nrofact"],
        nro_doc=r["nrodoc"] or "",
        fecha=r["fecha"].date().isoformat() if r.get("fecha") else None,
        hora=r["hora"].strftime("%H:%M") if r.get("hora") else None,
        cliente_nombre=r["cliente_nombre"] or "",
        cliente_cod=r.get("codcliente"),
        vendedor=r.get("codvendedor"),
        vendedor_nombre=r.get("vendedor_nombre") or "",
        total=float(r["total"]) if r.get("total") is not None else None,
        credito=bool(r.get("encuotas")),
        estado=_estado_chip(r),
        observaciones=r.get("observaciones") or "",
        es_mio=es_mio,
        creado_por=r.get("creado_por_nombre") or r.get("creado_por_username"),
        # La query lo trae (LEFT JOIN ext.pedido_prioridad ... AND pri.activo) pero
        # este item se arma campo por campo y se perdía: viajaba siempre False.
        # Consecuencia en la calle: el botón nunca se veía marcado y mandaba
        # !False = marcar OTRA VEZ, así que la prioridad no se podía sacar y la
        # tele sonaba cada 20 s hasta que el pedido se entregaba (dueño 28/08).
        prioritario=bool(r.get("prioritario")),
        anulable=(
            not r["anulada"] and not r["facturado"]
            and r.get("creado_por_usuario_id") is not None
            and (es_mio or ver_todos)
        ),
    )


@router.get(
    "/pedidos",
    response_model=list[PedidoVentaListItem],
    # `reclamos`: el picker de "pedido asociado" de una no conformidad lista los
    # pedidos del cliente desde la pantalla de No conformidades.
    dependencies=[Depends(require_any_permission("venta", "venta_todos", "reclamos"))],
)
def list_pedidos(
    scope: str = Query("mios", pattern="^(mios|todos)$"),
    cliente: int | None = Query(None, description="todos los pedidos de un cliente (histórico)"),
    vendedor: int | None = Query(None, description="filtro por código de vendedor (scope=todos)"),
    fecha: str | None = Query(None, description="YYYY-MM-DD"),
    con_resumen: bool = Query(False, description="incluir íconos + total de bultos por pedido"),
    limit: int = Query(100, ge=1, le=300),
    user: CurrentUser = Depends(get_current_user),
):
    ver_todos = _puede_ver_todos(user)
    where = []
    params: dict = {"limit": limit}

    if cliente is not None:
        # Historial del cliente: visible para cualquier vendedor (atención al cliente).
        where.append("c.codcliente = %(cliente)s")
        params["cliente"] = cliente
    elif scope == "todos":
        if not ver_todos:
            raise HTTPException(403, "No tenés permiso para ver los pedidos de todos.")
        if vendedor is not None:
            where.append("c.codvendedor = %(vendedor)s")
            params["vendedor"] = vendedor
    else:  # mios
        where.append("m.usuario_id = %(uid)s")
        params["uid"] = user.id

    if fecha:
        try:
            f0 = datetime.strptime(fecha, "%Y-%m-%d")
        except ValueError:
            raise HTTPException(400, "fecha inválida (YYYY-MM-DD)")
        where.append("c.fecha >= %(f0)s AND c.fecha < %(f1)s")
        params["f0"] = f0
        params["f1"] = f0 + timedelta(days=1)

    extra = (" AND " + " AND ".join(where)) if where else ""
    rows = fetch_all(q.LIST_PEDIDOS_SQL_TPL.format(extra_where=extra), params)
    items = [_list_item(r, user, ver_todos) for r in rows]

    # Resumen para el vistazo rápido (vista "Por cliente"): íconos de fruta +
    # total de bultos por pedido, en UNA sola query para todos los nrofacts.
    if con_resumen and rows:
        por_pedido: dict[int, list[tuple[str, float]]] = defaultdict(list)
        nrofacts = [r["nrofact"] for r in rows]
        cods: dict[int, list[str]] = defaultdict(list)
        for l in fetch_all(q.LIST_LINEAS_RESUMEN_SQL, (nrofacts,)):
            por_pedido[l["nrofact"]].append((l["descripcion"], float(l["cantidad"] or 0)))
            cods[l["nrofact"]].append(l["cod_art"] or "")
        for it in items:
            pares = por_pedido.get(it.nro_fact, [])
            it.iconos = iconos_de_productos(pares)
            it.total_bultos = sum(c for _, c in pares)
            # Pedido de puros descuentos: el botón de prioridad se apaga (no se
            # arma ni se entrega, la alarma no se apagaría nunca).
            propios = cods.get(it.nro_fact, [])
            it.solo_descuentos = bool(propios) and all(_es_descuento(c) for c in propios)

    # Chip VIDEO: una sola query para todos los pedidos de la página.
    if rows:
        from app.modules.entregas import video

        por_nf = video.por_pedido([r["nrofact"] for r in rows])
        for it in items:
            it.videos = por_nf.get(it.nro_fact, 0)

    return items


@router.get(
    "/pedidos/{nro_fact}",
    response_model=PedidoVentaDetail,
    dependencies=[Depends(require_any_permission("venta", "venta_todos"))],
)
def get_pedido(nro_fact: int, user: CurrentUser = Depends(get_current_user)):
    rows = fetch_all(
        q.LIST_PEDIDOS_SQL_TPL.format(extra_where=" AND c.nrofact = %(nf)s"),
        {"nf": nro_fact, "limit": 1},
    )
    if not rows:
        raise HTTPException(404, "Pedido no encontrado")
    item = _list_item(rows[0], user, _puede_ver_todos(user))
    lineas = [
        LineaPedidoOut(
            id=l["id"],
            cod_art=l["cod_art"],
            descripcion=l["descripcion"],
            deposito=l["deposito"] or "",
            cantidad=float(l["cantidad"] or 0),
            precio=float(l["precio"] or 0),
            total_linea=float(l["totallinea"] or 0),
            # icono_de espera la CATEGORÍA (no la descripción); None si no es
            # mercadería (ej. líneas de descuento) → el front no muestra ícono.
            icono=(icono_de(cat_) if (cat_ := categoria_de(l["descripcion"])) else None),
        )
        for l in fetch_all(q.GET_PEDIDO_LINEAS_SQL, (nro_fact,))
    ]
    return PedidoVentaDetail(**item.model_dump(), lineas=lineas)


# ── Submódulo Vendedores (admin del módulo) ──────────────────────────────

@router.get(
    "/vendedores-config",
    response_model=list[VentaVendedorItem],
    dependencies=[Depends(require_any_permission("admin", "venta_admin"))],
)
def vendedores_config():
    """Usuarios con acceso al módulo (permiso `venta`) + su código de vendedor de
    Macrosoft. El admin asigna acá quién es quién (tabla Vendedores del legacy)."""
    usuarios = fetch_all(uq.LIST_BY_PERMISSION_SQL, ("venta",))
    asignados = {r["usuario_id"]: r for r in fetch_all(q.LIST_VENTA_VENDEDORES_SQL)}
    nombres = {
        r["vendedor"]: (r["nombre"] or "").strip()
        for r in fetch_all("SELECT vendedor, BTRIM(nombre) AS nombre FROM legacy.vendedores")
    }
    out = []
    for u in usuarios:
        a = asignados.get(u["id"])
        cod = a["vendedor"] if a else None
        out.append(VentaVendedorItem(
            usuario_id=u["id"],
            usuario_nombre=u.get("nombre") or u["username"],
            username=u["username"],
            vendedor=cod,
            vendedor_nombre=nombres.get(cod) if cod is not None else None,
            actualizado_en=a["actualizado_en"] if a else None,
        ))
    return out


@router.put(
    "/vendedores-config",
    dependencies=[Depends(require_any_permission("admin", "venta_admin"))],
)
def set_vendedor(body: VentaVendedorInput, user: CurrentUser = Depends(get_current_user)):
    existe = fetch_one("SELECT id FROM ext.usuarios WHERE id = %s", (body.usuario_id,))
    if not existe:
        raise HTTPException(404, "Usuario no encontrado")
    with get_cursor() as cur:
        if body.vendedor is None:
            cur.execute(q.DELETE_VENTA_VENDEDOR_SQL, (body.usuario_id,))
        else:
            cur.execute(q.UPSERT_VENTA_VENDEDOR_SQL, (body.usuario_id, body.vendedor, user.id))
    return {"ok": True}
