"""Informe de Ventas detallado — endpoints.

Consulta Macrosoft prod EN VIVO (solo lectura): el rango es libre y el espejo
de Lineas solo guarda unas semanas. Puede tardar unos segundos con rangos
largos, igual que saldos-mes.
"""

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, Response

from app.core.deps import CurrentUser, get_current_user, require_any_permission
from app.pg import fetch_all
from app.modules.informes import ventas_articulos as va
from app.modules.venta import queries as venta_q

router = APIRouter(prefix="/ventas-articulos", tags=["informes"])

# Dos niveles (pedido de Lucas 17/08): la contadora (informe_ventas /
# administracion / admin) ve TODO y baja Excel; el cajero (permiso caja) ve la
# vista sin el desglose de IVA y baja SOLO PDF (el Excel se edita, el PDF no).
# El recorte se decide ACÁ y en el service — nunca en el front.
_PERMISOS_COMPLETA = ("admin", "administracion", "informe_ventas")
_PUEDE_VER = require_any_permission(*_PERMISOS_COMPLETA, "caja")
_SOLO_COMPLETA = require_any_permission(*_PERMISOS_COMPLETA)


def _vista_de(user: CurrentUser) -> str:
    if user.es_admin or any(p in user.permisos for p in _PERMISOS_COMPLETA):
        return "completa"
    return "cajero"

# Macrosoft ofrece hasta "Todo el año"; con margen. Más que esto es un escaneo
# muy pesado sobre Lineas de prod para un solo request.
_MAX_DIAS = 400

# El detallado de un año son cientos de miles de líneas: a la pantalla van las
# primeras N (con aviso); el Excel siempre baja completo. 100 alcanza para
# ojear — el detalle completo es cosa del Excel (pedido de Lucas 14/08).
_MAX_FILAS_JSON = 100


def _validar_rango(desde: date, hasta: date) -> None:
    if hasta < desde:
        raise HTTPException(400, "El 'hasta' no puede ser anterior al 'desde'")
    if (hasta - desde).days > _MAX_DIAS:
        raise HTTPException(400, f"Máximo {_MAX_DIAS} días por consulta (pedilo por partes)")


@router.get("", dependencies=[Depends(_PUEDE_VER)])
def ver(desde: date = Query(...), hasta: date = Query(...),
        cliente: int | None = Query(None, description="CodCliente de Macrosoft (opcional)"),
        articulo: str | None = Query(None, description="CodArt exacto (opcional)"),
        pendientes: bool = Query(False, description="Solo facturas a crédito con saldo sin cancelar"),
        user: CurrentUser = Depends(get_current_user)):
    """El detallado por comprobante (todas las columnas de Macrosoft más el
    precio por unidad). A la pantalla van las primeras N líneas (truncado=True
    avisa) con los totales de TODO el rango calculados en el servidor; el
    export baja todas. La vista del cajero llega SIN el desglose de IVA — el
    recorte es del back, no del front."""
    _validar_rango(desde, hasta)
    datos = va.detalle(desde, hasta, cliente, articulo, limite=_MAX_FILAS_JSON,
                       solo_pendientes=pendientes)
    if _vista_de(user) == "cajero":
        datos = va.vista_cajero(datos)
    else:
        datos["vista"] = "completa"
    datos["truncado"] = datos["totales"]["lineas"] > len(datos["filas"])
    return datos


@router.get("/articulos", dependencies=[Depends(_PUEDE_VER)])
def buscar_articulos(q: str = Query("", description="código o descripción"),
                     limit: int = Query(15, ge=1, le=50)):
    """Buscador para el filtro por artículo (pedido de la contadora 26/08):
    por código (prefijo) o descripción, acento-insensible, del catálogo
    espejado."""
    term = q.strip()
    if not term:
        return []
    rows = fetch_all(
        """SELECT BTRIM(codarticulo) AS cod, BTRIM(descripcion) AS descripcion
           FROM legacy.articulos
           WHERE BTRIM(codarticulo) ILIKE %s || '%%'
              OR translate(lower(descripcion), 'áéíóúü', 'aeiouu')
                 LIKE '%%' || translate(lower(%s), 'áéíóúü', 'aeiouu') || '%%'
           ORDER BY (BTRIM(codarticulo) ILIKE %s || '%%') DESC, BTRIM(descripcion)
           LIMIT %s""",
        (term, term, term, limit))
    return [{"cod": r["cod"], "descripcion": r["descripcion"] or ""} for r in rows]


@router.get("/clientes", dependencies=[Depends(_PUEDE_VER)])
def buscar_clientes(q: str = Query("", description="nombre, RUT o código"),
                    limit: int = Query(15, ge=1, le=50)):
    """Buscador para el filtro por cliente — la misma búsqueda del módulo Venta
    (acento-insensible, ordenada por actividad reciente), con permisos de acá."""
    term = q.strip()
    if not term:
        return []
    rows = fetch_all(venta_q.SEARCH_CLIENTES_SQL, (term, term, term, limit))
    return [{"cod": r["codcliente"], "nombre": r["nombre"], "ruc": r["ruc"] or ""}
            for r in rows]


def _nombre_export(datos: dict, desde: date, hasta: date, ext: str) -> str:
    rango = f"{desde.strftime('%d.%m.%Y')} al {hasta.strftime('%d.%m.%Y')}"
    sufijo = ""
    if datos.get("cliente"):
        c = datos["cliente"]
        sufijo = f" - {(c['nombre'] or str(c['cod'])).strip()}"
    if datos.get("articulo"):
        a = datos["articulo"]
        sufijo += f" - {(a['descripcion'] or a['cod']).strip()}"
    return f"INFORME DE VENTAS {rango}{sufijo}.{ext}"


# SOLO la vista completa: el Excel trae el desglose de IVA y es editable —
# los cajeros no pasan por acá aunque armen la URL a mano.
@router.get("/excel", dependencies=[Depends(_SOLO_COMPLETA)])
def descargar_excel(desde: date = Query(...), hasta: date = Query(...),
                    cliente: int | None = Query(None),
                    articulo: str | None = Query(None),
                    pendientes: bool = Query(False)):
    _validar_rango(desde, hasta)
    datos = va.detalle(desde, hasta, cliente, articulo, solo_pendientes=pendientes)
    contenido = va.construir_excel(datos)
    return Response(
        content=contenido,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="{_nombre_export(datos, desde, hasta, "xlsx")}"'},
    )


@router.get("/pdf", dependencies=[Depends(_PUEDE_VER)])
def descargar_pdf(desde: date = Query(...), hasta: date = Query(...),
                  cliente: int | None = Query(None),
                  articulo: str | None = Query(None),
                  pendientes: bool = Query(False)):
    """El export del cajero: PDF sin el desglose de IVA, no editable."""
    _validar_rango(desde, hasta)
    datos = va.detalle(desde, hasta, cliente, articulo, solo_pendientes=pendientes)
    contenido = va.construir_pdf(datos)
    return Response(
        content=contenido,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{_nombre_export(datos, desde, hasta, "pdf")}"'},
    )
