import base64
import logging
import re
from datetime import date, datetime
from io import BytesIO
from zoneinfo import ZoneInfo

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Response
from psycopg2 import errors as pg_errors

from app.config import settings
from app.core import s3
from app.core.categorias import CATEGORIAS, categoria_de, icono_de, iconos_de_productos
from app.core.pdf_merge import merge_pdfs
from app.core.deps import CurrentUser, get_current_user, require_any_permission, require_permission
from app.modules.piedecamion import webhook
# Este módulo vive en Postgres (ext.* + legacy.*). SQL Server queda SOLO para
# el confirmar→ingreso, que escribe Cabezal/Lineas vía la conexión CFE
# (prod: Macrosoft REAL; dev: GestionPepe de testing).
from app.db import get_cfe_cursor
from psycopg2.extras import Json

from app.pg import fetch_all, fetch_one, get_cursor


# Depósito PREDETERMINADO de la mercadería de un pie. NO es un valor fijo: el
# formulario lo trae elegido y el operario puede cambiarlo; esto es solo el
# respaldo para cuando la línea llega sin depósito (clientes viejos, borradores
# de antes del cambio del 05/08). Es 'B' porque es lo que se hace de verdad:
# las 836 líneas de ingreso (docs 400/402) de Macrosoft están en 'B' sin una
# sola excepción — hasta la fruta que después va a Coronel Raíz entra por B.
# Antes el form ofrecía 'A' por default y había que corregirlo camión por camión.
DEPOSITO_INGRESO_DEFAULT = "B"

def _deposito_de(linea) -> str:
    """Depósito de la línea: el que mandó el front, o el predeterminado si no
    vino (el formulario dejó de pedirlo por producto el 05/08)."""
    dep = (getattr(linea, "deposito", None) or "").strip()
    return dep or DEPOSITO_INGRESO_DEFAULT


def _validar_reclamos_por_linea(body) -> None:
    """"¿Hay reclamos para esta fruta?" es obligatoria y POR PRODUCTO (mig 0072).

    Se valida en el back y no sólo en la UI: el reclamo al proveedor se genera con
    cualquier defecto que venga en el body, así que sin esto se podría responder
    NO y mandar defectos igual, o responder SÍ y no marcar nada.

    Compatibilidad hacia atrás, en dos escalones:
      · body con la respuesta a nivel PIE pero no por línea (front de la mig 0071)
        → se baja esa respuesta a todas las líneas y se sigue.
      · body sin ninguna respuesta (front anterior a todo esto, o una pestaña
        vieja abierta desde antes del deploy) → 400 que dice RECARGAR. Sin ese
        mensaje el operario ve un error críptico a las 3 AM y no sabe qué hacer.
    """
    if not body.lineas:
        return
    if all(l.hay_reclamos is None for l in body.lineas):
        if body.hay_reclamos is None:
            raise HTTPException(400, (
                "Recargá la página: el formulario cambió y ahora hay que responder "
                "si hay reclamos en cada fruta."
            ))
        for l in body.lineas:
            l.hay_reclamos = body.hay_reclamos

    for l in body.lineas:
        cod = l.cod_art.strip()
        n_def = len(l.defectos or [])
        if l.hay_reclamos is None:
            raise HTTPException(400, f"Falta responder si hay reclamos en {cod}.")
        if l.hay_reclamos and n_def == 0:
            raise HTTPException(400, (
                f"En {cod} respondiste que HAY reclamos: marcá el defecto "
                "(motivo, cajas y foto)."
            ))
        if not l.hay_reclamos and n_def > 0:
            raise HTTPException(400, (
                f"En {cod} respondiste que NO hay reclamos, pero quedaron defectos "
                "marcados. Corregí una de las dos cosas."
            ))


_DATA_URI_RE = re.compile(r"^data:[a-z0-9.+/-]+;base64,(.+)$", re.IGNORECASE)
logger = logging.getLogger("piedecamion")
# ext.* guarda en UTC; lo que se ESCRIBE para leer (el título del anexo de fotos)
# va en hora de Uruguay.
_UY = ZoneInfo("America/Montevideo")


def _decode_image_data_uri(s: str) -> bytes:
    """Acepta un data URI (`data:image/jpeg;base64,...`) o base64 puro y
    devuelve los bytes. Lanza si no se puede decodificar.

    Por qué soportamos los dos formatos: distintos celus / FKB pueden devolver
    la foto en cualquiera de las dos formas. Es simétrico al manejo de fotos
    de defectos del módulo `stock`.
    """
    s = s.strip()
    if not s:
        raise ValueError("foto vacía")
    m = _DATA_URI_RE.match(s)
    payload = m.group(1) if m else s
    return base64.b64decode(payload, validate=False)


def _fotos_grupos_de_body(body: "PieDeCamionCreate") -> list[tuple[str, list[bytes]]]:
    """Decodifica y agrupa las fotos del body (categorizadas + galería libre) para
    el fotos-PDF. NO toca la DB. Consecutivas de la misma categoría van bajo su
    label; las sin categoría van juntas como 'Otras fotos'. Fotos corruptas o >2MB
    se saltean. Mismo agrupado que hacía el create embebido."""
    return _fotos_grupos(body.fotos_categoria, body.fotos)


def _fotos_grupos(fotos_categoria, fotos) -> list[tuple[str, list[bytes]]]:
    """El agrupado en sí, sobre las dos listas — lo comparten el create/editar
    (body completo) y el anexo de fotos de un pie ya enviado."""
    grupos: list[tuple[str, list[bytes]]] = []
    last_cat: str | None = None
    for fc in fotos_categoria:
        try:
            blob = _decode_image_data_uri(fc.foto)
        except Exception:
            continue
        if len(blob) > 2 * 1024 * 1024:
            continue
        if grupos and last_cat == fc.categoria:
            grupos[-1][1].append(blob)
        else:
            grupos.append((fc.label, [blob]))
        last_cat = fc.categoria
    otras: list[bytes] = []
    for f_str in fotos:
        try:
            blob = _decode_image_data_uri(f_str)
        except Exception:
            continue
        if len(blob) > 2 * 1024 * 1024:
            continue
        otras.append(blob)
    if otras:
        grupos.append(("Otras fotos", otras))
    return grupos


def _paginas_pdf(b: bytes) -> int:
    """Páginas de un PDF, o -1 si no se pudo leer. Sirve para verificar que un
    merge realmente anexó (merge_pdfs falla en silencio a propósito)."""
    try:
        from pypdf import PdfReader

        return len(PdfReader(BytesIO(b)).pages)
    except Exception:
        return -1


def _derive_productos_from_lineas(lineas_for_pdf: list[dict]) -> list[dict]:
    """Aplana las líneas a una lista de {producto, marca} única por par
    descripción+marca. Se usa para el header del PDF de control que ve
    Ingresos — históricamente era una sección aparte ("Productos / Marcas"),
    ahora la derivamos para no tener data duplicada.
    """
    seen: set[tuple[str, str | None]] = set()
    out: list[dict] = []
    for l in lineas_for_pdf:
        desc = (l.get("descripcion") or "").strip()
        marca = (l.get("marca") or None)
        marca_norm = marca.strip() if isinstance(marca, str) else marca
        key = (desc, marca_norm)
        if not desc or key in seen:
            continue
        seen.add(key)
        out.append({"producto": desc, "marca": marca_norm})
    return out
from app.modules.piedecamion import pdf as pdf_gen
from app.modules.piedecamion import queries as q
from app.modules.piedecamion.schemas import (
    CAMARAS_POR_UBICACION,
    AgregarFotosRequest,
    CamaraOut,
    ConfirmarIngresoRequest,
    DefectoOut,
    EtiquetaCamionOut,
    EtiquetaImpresaCreate,
    LineaOut,
    PieDeCamionCreate,
    PieDeCamionDetail,
    PieDeCamionListItem,
    ProductoMarcaOut,
    ReclamoPieCreate,
    RequisitoOut,
    RequisitoRespuestaOut,
    RequisitosAplicablesOut,
    RequisitosCategoriaUpsert,
    TermografoPdfUpload,
)
from app.modules.stock import pdf as reclamo_pdf
from app.modules.stock import queries as stock_q
from app.modules.stock import reclamos_queries as rq
from app.modules.stock.router import dual_write_ingreso_to_legacy

router = APIRouter(
    prefix="/pie-camion",
    tags=["pie_camion"],
    # Lectura/uso amplio: el equipo de recepción (recepcion) también opera acá
    # (firma "Descarga autorizada" / "Inspección realizada" en el formulario).
    # `stock` también entra: la página de Ingresos (permiso stock) lee los pie de
    # camión pendientes, baja sus PDF y los confirma → ingreso. La creación queda
    # restringida aparte (ver create_pie_camion), que es "write específico".
    # `consulta` (Buscar pedido, universal): su pestaña de QR/pie de camión lee
    # el pie por código → necesita pasar esta puerta de lectura amplia.
    # `pie_requisitos_config` (ing. agrónomo): entra a leer para poder llegar a
    # su ABM de requisitos aunque no tenga ningún otro permiso del módulo.
    dependencies=[Depends(require_any_permission(
        "pie_camion", "recepcion", "stock", "consulta", "pie_requisitos_config",
    ))],
)


def _fetch_productos(pie_camion_id: int) -> list[ProductoMarcaOut]:
    """Trae los productos de la tabla nueva. Si está vacía, devuelve lista vacía
    (el caller cae al campo legacy `producto` de la fila principal)."""
    rows = fetch_all(q.GET_PRODUCTOS_SQL, (pie_camion_id,))
    return [ProductoMarcaOut(producto=r["producto"], marca=r.get("marca")) for r in rows]


def _list_item(row: dict, productos: list[ProductoMarcaOut] | None = None) -> PieDeCamionListItem:
    if productos is None:
        productos = _fetch_productos(row["id"])
    return PieDeCamionListItem(
        id=row["id"],
        fecha=row["fecha"],
        hora_inicio=row.get("hora_inicio"),
        hora_fin=row.get("hora_fin"),
        chofer_nombre=row["chofer_nombre"],
        placa_camion=row["placa_camion"],
        producto=(productos[0].producto if productos else row.get("producto")),
        productos=productos,
        iconos=iconos_de_productos([(ln.get("d"), ln.get("c") or 0) for ln in (row.get("lineas_iconos") or [])]),
        exportador=row.get("exportador"),
        empresa_transporte=row.get("empresa_transporte"),
        numero_afidi=row.get("numero_afidi"),
        codigo_importador_camion=row.get("codigo_importador_camion"),
        total_cajas=row.get("total_cajas"),
        pdf_filename=row["pdf_filename"],
        pdf_size_bytes=row["pdf_size_bytes"],
        doc_pdf_size_bytes=row.get("doc_pdf_size_bytes"),
        termografo_pdf_size_bytes=row.get("termografo_pdf_size_bytes"),
        termografo_pdf_filename=row.get("termografo_pdf_filename"),
        creado_en=row["creado_en"],
        creado_por_usuario=row.get("creado_por_nombre") or row.get("creado_por_username"),
        estado=row.get("estado") or "pendiente",
        ingreso_documento=row.get("ingreso_documento"),
        ingreso_nro_fact=row.get("ingreso_nro_fact"),
        confirmado_en=row.get("confirmado_en"),
        confirmado_por_usuario=row.get("confirmado_por_nombre") or row.get("confirmado_por_username"),
        reclamo_id=row.get("reclamo_id"),
        hay_reclamos=row.get("hay_reclamos"),
        descargado_en=row.get("descargado_en"),
        n_lineas=row.get("n_lineas") or 0,
        cantidad_total=float(row.get("cantidad_total") or 0),
        cantidad_defectuosa_total=float(row.get("cantidad_defectuosa_total") or 0),
    )


@router.get("", response_model=list[PieDeCamionListItem])
def list_pie_camion(estado: str | None = None):
    rows = fetch_all(q.LIST_SQL)
    items = [_list_item(r) for r in rows]
    if estado:
        items = [i for i in items if i.estado == estado]
    return items


def _fetch_lineas_con_defectos(pie_camion_id: int) -> list[LineaOut]:
    out: list[LineaOut] = []
    for l in fetch_all(q.GET_LINEAS_SQL, (pie_camion_id,)):
        defectos = fetch_all(q.GET_LINEA_DEFECTOS_SQL, (l["id"],))
        cant_def = sum(float(d["cantidad"]) for d in defectos)
        motivos = list({d["motivo"] for d in defectos})
        out.append(LineaOut(
            id=l["id"],
            cod_art=l["cod_art"],
            descripcion=l["descripcion"],
            deposito=l["deposito"],
            deposito_descripcion=l.get("deposito_descripcion"),
            cantidad=float(l["cantidad"]),
            marca=l.get("marca"),
            cantidad_defectuosa=cant_def,
            hay_reclamos=l.get("hay_reclamos"),
            motivos_defecto=motivos,
            defectos=[DefectoOut(**d) for d in defectos],
            icono=icono_de(categoria_de(l["descripcion"])) if categoria_de(l["descripcion"]) else None,
        ))
    return out


def _lineas_full_with_defectos(pie_camion_id: int) -> list[dict]:
    """Para el PDF: cada línea con su lista de defectos (motivo + cantidad)."""
    out = []
    for l in fetch_all(q.GET_LINEAS_SQL, (pie_camion_id,)):
        defectos = fetch_all(q.GET_LINEA_DEFECTOS_SQL, (l["id"],))
        out.append({
            "cod_art": l["cod_art"],
            "descripcion": l["descripcion"],
            "marca": l.get("marca"),   # para la sección Producto/Marca del PDF
            "deposito": l["deposito"],
            "deposito_descripcion": l.get("deposito_descripcion"),
            "cantidad": float(l["cantidad"]),
            "defectos": [
                {"motivo": d["motivo"], "cantidad": float(d["cantidad"])}
                for d in defectos
            ],
        })
    return out


@router.get("/etiqueta-qr")
def etiqueta_qr(cod: str):
    """QR (SVG) para la etiqueta: codifica SOLO el código (texto plano, sin link ni
    dominio). Se escanea DESDE Aloha (tab QR de Consulta). DEFINIDO ANTES de /{pdc_id}
    para que 'etiqueta-qr' no lo capture como id."""
    from app.modules.piedecamion import publico
    return {"svg": publico.qr_svg(cod.strip().upper())}


def _placa_norm(placa: str | None) -> str:
    return (placa or "").strip().upper()


# ── Requisitos por fruta (mig 0092): lo que el ING. AGRÓNOMO pide al ingreso ──
# Rutas literales definidas ANTES de /{pdc_id} para que no las capture como id.

_CATEGORIAS_VALIDAS = {canon for canon, _icono, _palabras in CATEGORIAS}


def _requisito_out(row: dict) -> RequisitoOut:
    return RequisitoOut(
        id=row["id"],
        categoria=row["categoria"],
        tipo=row["tipo"],
        etiqueta=row["etiqueta"],
        unidad=row.get("unidad"),
        opciones=list(row.get("opciones") or []),
        obligatorio=row["obligatorio"],
        orden=row["orden"],
        activo=row["activo"],
    )


@router.get("/requisitos", response_model=list[RequisitoOut])
def list_requisitos(incluir_inactivos: bool = False):
    """Config completa (todas las frutas). El form del pie la usa para armar la
    sección de requisitos de cada producto; el ABM del agrónomo también."""
    return [_requisito_out(r) for r in fetch_all(q.LIST_REQUISITOS_SQL, (incluir_inactivos,))]


@router.get("/requisitos/aplicables", response_model=list[RequisitosAplicablesOut])
def requisitos_aplicables(cods: str = ""):
    """Requisitos activos de las frutas PRESENTES en la mercadería del form.
    `cods` = cod_art separados por coma; el back resuelve descripción →
    categoría (el front no duplica el matching). Definida ANTES de
    /requisitos/{categoria} y de /{pdc_id} (rutas literales primero)."""
    vistas: list[str] = []
    for cod in cods.split(","):
        cod = cod.strip()
        if not cod:
            continue
        art = fetch_one(q.ARTICULO_DESCRIPCION_SQL, (cod,))
        cat = categoria_de(art["descripcion"] if art else None)
        if cat and cat not in vistas:
            vistas.append(cat)
    if not vistas:
        return []
    config = [_requisito_out(r) for r in fetch_all(q.LIST_REQUISITOS_SQL, (False,))]
    out: list[RequisitosAplicablesOut] = []
    for cat in vistas:
        reqs = [r for r in config if r.categoria == cat]
        if reqs:
            out.append(RequisitosAplicablesOut(categoria=cat, icono=icono_de(cat), requisitos=reqs))
    return out


@router.put(
    "/requisitos/{categoria}",
    response_model=list[RequisitoOut],
    # El ABM es del ING. AGRÓNOMO: permiso propio `pie_requisitos_config`.
    # Los operarios de recepción sólo RESPONDEN los requisitos, no los definen.
    dependencies=[Depends(require_any_permission("pie_requisitos_config"))],
)
def upsert_requisitos_categoria(
    categoria: str,
    body: RequisitosCategoriaUpsert,
    user: CurrentUser = Depends(get_current_user),
):
    """Reemplaza la lista de requisitos de UNA fruta. Filas con id se
    actualizan, sin id se crean, y las que falten se DESACTIVAN (el histórico
    no se toca: las respuestas viejas tienen su snapshot)."""
    if categoria not in _CATEGORIAS_VALIDAS:
        raise HTTPException(400, f"Categoría desconocida: {categoria}")
    for r in body.requisitos:
        if r.tipo == "opciones" and len([o for o in r.opciones if o.strip()]) < 2:
            raise HTTPException(400, f"«{r.etiqueta}»: un requisito de opciones necesita al menos 2 opciones")

    with get_cursor() as cur:
        vigentes: list[int] = []
        for orden, r in enumerate(body.requisitos):
            opciones = (
                Json([o.strip() for o in r.opciones if o.strip()])
                if r.tipo == "opciones" else None
            )
            unidad = (r.unidad or "").strip() or None if r.tipo == "numero" else None
            if r.id is not None:
                cur.execute(q.UPDATE_REQUISITO_SQL, (
                    r.tipo, r.etiqueta.strip(), unidad, opciones,
                    r.obligatorio, orden, r.id, categoria,
                ))
                fila = cur.fetchone()
                if not fila:
                    raise HTTPException(400, f"El requisito {r.id} no existe en {categoria}")
                vigentes.append(fila["id"])
            else:
                cur.execute(q.INSERT_REQUISITO_SQL, (
                    categoria, r.tipo, r.etiqueta.strip(), unidad, opciones,
                    r.obligatorio, orden, user.id,
                ))
                vigentes.append(cur.fetchone()["id"])
        cur.execute(q.DESACTIVAR_REQUISITOS_SQL, (categoria, vigentes or [0]))

    return [
        _requisito_out(r)
        for r in fetch_all(q.LIST_REQUISITOS_SQL, (False,))
        if r["categoria"] == categoria
    ]


def _categorias_de_body(body: PieDeCamionCreate) -> list[str]:
    """Frutas presentes en el camión, en orden de aparición: por las LÍNEAS de
    mercadería (el form nuevo — la descripción sale del catálogo) y por la
    lista legacy de productos (clientes viejos)."""
    vistas: list[str] = []

    def _sumar(cat: str | None) -> None:
        if cat and cat not in vistas:
            vistas.append(cat)

    for linea in body.lineas:
        art = fetch_one(q.ARTICULO_DESCRIPCION_SQL, (linea.cod_art.strip(),))
        _sumar(categoria_de(art["descripcion"] if art else None))
    for p in body.productos:
        _sumar(categoria_de(p.producto))
    if body.producto:
        _sumar(categoria_de(body.producto))
    return vistas


def _respuestas_requisitos(
    body: PieDeCamionCreate,
    fotos_previas: dict[int, int] | None = None,
) -> tuple[list[dict], list[str]]:
    """Valida las respuestas contra la config y arma las filas snapshot a
    persistir. Los requisitos van POR FRUTA presente en la mercadería; los
    obligatorios se exigen contra la config ACTIVA. Respuestas a requisitos
    desactivados entre que el celu cargó el form y mandó, se conservan igual
    (nunca perder datos). `fotos_previas` (edición): requisito_id → fotos_n ya
    guardadas — las fotos viven en el fotos-PDF y NO se re-mandan al editar,
    así que cuentan como cumplidas. Devuelve (filas, faltantes legibles)."""
    fotos_previas = fotos_previas or {}
    config = {r["id"]: r for r in fetch_all(q.LIST_REQUISITOS_SQL, (True,))}
    activos_por_cat: dict[str, list[dict]] = {}
    for r in config.values():
        if r["activo"]:
            activos_por_cat.setdefault(r["categoria"], []).append(r)

    respuestas_idx = {resp.requisito_id: resp for resp in body.requisitos}
    filas: list[dict] = []
    faltantes: list[str] = []
    orden = 0

    def _armar_fila(req: dict, *, valor_numero=None, valor_texto=None, fotos_n=0):
        nonlocal orden
        filas.append({
            "requisito_id": req["id"],
            "producto": req["categoria"],
            "categoria": req["categoria"],
            "tipo": req["tipo"],
            "etiqueta": req["etiqueta"],
            "unidad": req.get("unidad"),
            "valor_numero": valor_numero,
            "valor_texto": valor_texto,
            "fotos_n": fotos_n,
            "orden": orden,
        })
        orden += 1

    vistos: set[int] = set()
    for cat in _categorias_de_body(body):
        for req in sorted(activos_por_cat.get(cat, []), key=lambda r: (r["orden"], r["id"])):
            vistos.add(req["id"])
            if req["tipo"] == "foto":
                fotos_n = sum(
                    1 for fc in body.fotos_categoria
                    if fc.categoria == f"req-{req['id']}"
                ) or fotos_previas.get(req["id"], 0)
                if req["obligatorio"] and fotos_n == 0:
                    faltantes.append(f"{cat}: {req['etiqueta']} (falta la foto)")
                elif fotos_n:
                    _armar_fila(req, fotos_n=fotos_n)
                continue
            resp = respuestas_idx.get(req["id"])
            valor = (resp.valor or "").strip() if resp else ""
            if not valor:
                if req["obligatorio"]:
                    faltantes.append(f"{cat}: {req['etiqueta']}")
                continue
            if req["tipo"] == "numero":
                try:
                    _armar_fila(req, valor_numero=float(valor.replace(",", ".")))
                except ValueError:
                    faltantes.append(f"{cat}: {req['etiqueta']} (no es un número)")
            elif req["tipo"] == "opciones":
                if valor not in (req.get("opciones") or []):
                    faltantes.append(f"{cat}: {req['etiqueta']} (opción inválida: {valor})")
                else:
                    _armar_fila(req, valor_texto=valor)
            else:
                _armar_fila(req, valor_texto=valor[:1000])

    # Respuestas a requisitos que se desactivaron mientras el form estaba
    # abierto: se guardan igual, con el snapshot de la config (aunque inactiva).
    for resp in body.requisitos:
        req = config.get(resp.requisito_id)
        if not req or req["id"] in vistos or req["tipo"] == "foto":
            continue
        valor = (resp.valor or "").strip()
        if not valor:
            continue
        if req["tipo"] == "numero":
            try:
                _armar_fila(req, valor_numero=float(valor.replace(",", ".")))
            except ValueError:
                continue
        else:
            _armar_fila(req, valor_texto=valor[:1000])

    return filas, faltantes


def _persistir_respuestas(cur, pie_camion_id: int, filas: list[dict]) -> None:
    for f in filas:
        cur.execute(q.INSERT_REQUISITO_RESPUESTA_SQL, (
            pie_camion_id, f["requisito_id"], f["producto"], f["categoria"],
            f["tipo"], f["etiqueta"], f["unidad"], f["valor_numero"],
            f["valor_texto"], f["fotos_n"], f["orden"],
        ))


def _requisitos_para_pdf(filas: list[dict]) -> list[dict]:
    """Agrupa las respuestas por producto para la sección del informe."""
    grupos: dict[str, list[dict]] = {}
    for f in filas:
        valor = (
            f"{f['valor_numero']:g} {f['unidad']}".strip() if f["valor_numero"] is not None
            else f["valor_texto"] if f["valor_texto"]
            else f"{f['fotos_n']} foto(s) — ver informe de fotos" if f["fotos_n"]
            else "—"
        )
        grupos.setdefault(f["producto"], []).append({"etiqueta": f["etiqueta"], "valor": valor})
    return [{"producto": prod, "items": items} for prod, items in grupos.items()]


@router.post("/etiqueta-impresa", response_model=EtiquetaCamionOut)
def registrar_etiqueta_impresa(
    body: EtiquetaImpresaCreate,
    user: CurrentUser = Depends(get_current_user),
):
    """Deja el código de importador ASOCIADO al camión al imprimir las etiquetas.

    El código se tipeaba dos veces (PC para imprimir, celular para el pie) y
    cuando no coincidían, el QR de la etiqueta apuntaba a un código que el pie
    no tenía. Con esto el celular lo pre-carga solo.

    Clave (placa, fecha): la última impresión pisa a la anterior — vale el papel
    que quedó pegado en los pallets. ANTES de /{pdc_id}.
    """
    placa = _placa_norm(body.placa)
    codigo = body.codigo.strip().upper()
    if not placa or not codigo:
        raise HTTPException(400, "Faltan la placa o el código para asociar la etiqueta.")
    # get_cursor (no fetch_one): fetch_one es un helper de LECTURA y no commitea
    # — el INSERT devolvía la fila por el RETURNING y después se hacía rollback.
    with get_cursor() as cur:
        cur.execute(q.UPSERT_ETIQUETA_SQL, (
            placa, body.fecha, codigo, body.cantidad, body.plan_carga_id, user.id,
        ))
        row = cur.fetchone()
    return EtiquetaCamionOut(**row)


@router.get("/etiqueta-camion", response_model=EtiquetaCamionOut | None)
def etiqueta_de_camion(placa: str, fecha: date):
    """Código de importador que se imprimió para este camión (placa+fecha), si
    hubo impresión. El form del pie lo usa para pre-cargar el campo. ANTES de
    /{pdc_id}."""
    placa_n = _placa_norm(placa)
    if not placa_n:
        return None
    row = fetch_one(q.GET_ETIQUETA_SQL, (placa_n, fecha))
    return EtiquetaCamionOut(**row) if row else None


@router.get("/por-codigo", response_model=list[PieDeCamionListItem])
def pie_por_codigo(cod: str):
    """Busca pie(s) de camión por el QR de la etiqueta (o código tipeado a mano).
    El QR nuevo codifica `CÓDIGO|PLACA|FECHA` (único: el mismo camión no trae el mismo
    código dos veces el mismo día); un código pelado (QR viejo / tipeo) matchea sólo
    por código. Devuelve la LISTA de candidatos no anulados: el front abre directo si
    hay 1 y muestra una lista si hay varios. ANTES de /{pdc_id}."""
    partes = cod.split("|")
    codigo = partes[0].strip()
    placa = partes[1].strip() if len(partes) > 1 else ""
    fecha = partes[2].strip() if len(partes) > 2 else ""
    if not codigo:
        return []
    rows = fetch_all(q.LIST_BY_CODIGO_SQL, (codigo, placa, placa))
    # Plan B: la etiqueta pudo imprimirse con un código distinto al que le cargaron
    # al pie ("EXOTICO" vs "MK017 / EXOTICO") — si el QR trae la PLACA, con eso
    # alcanza para encontrar el camión (la fecha desempata abajo).
    if not rows and placa:
        rows = fetch_all(q.LIST_BY_PLACA_SQL, (placa,))
    # Plan C: código parcial (contención en cualquier dirección), p/ códigos
    # tipeados a mano o QR viejos sin placa. Con >=3 letras para no matchear basura.
    if not rows and len(codigo) >= 3:
        rows = fetch_all(q.LIST_BY_CODIGO_PARCIAL_SQL, (codigo, codigo, placa, placa))
    # Preferir la fecha exacta del QR (si hay match). Si el pie se cargó cruzando la
    # medianoche y la fecha no coincide, NO filtramos → cae a la lista por código/placa.
    if fecha:
        exactos = [r for r in rows if str(r.get("fecha")) == fecha]
        if exactos:
            rows = exactos
    return [_list_item(r) for r in rows]


@router.get("/{pdc_id}", response_model=PieDeCamionDetail)
def get_pie_camion(pdc_id: int):
    row = fetch_one(q.build_get_detail_sql(), (pdc_id,))
    if not row:
        raise HTTPException(404, "Pie de camión no encontrado")
    raw = dict(row)
    raw["intervenido_agronomia"] = bool(raw.get("intervenido_agronomia"))
    for k, v in list(raw.items()):
        if v is not None and v.__class__.__name__ == "Decimal":
            raw[k] = float(v)

    base_kwargs = {k: v for k, v in raw.items()
                   if k not in ("creado_por_nombre", "creado_por_username",
                                "confirmado_por_nombre", "confirmado_por_username")}
    base_kwargs["creado_por_usuario"] = raw.get("creado_por_nombre") or raw.get("creado_por_username")
    base_kwargs["confirmado_por_usuario"] = raw.get("confirmado_por_nombre") or raw.get("confirmado_por_username")
    base_kwargs["estado"] = raw.get("estado") or "pendiente"

    lineas = _fetch_lineas_con_defectos(pdc_id)
    base_kwargs["lineas"] = lineas
    base_kwargs["iconos"] = iconos_de_productos([(l.descripcion, l.cantidad) for l in lineas])
    base_kwargs["n_lineas"] = len(lineas)
    base_kwargs["cantidad_total"] = sum(l.cantidad for l in lineas)
    base_kwargs["cantidad_defectuosa_total"] = sum(l.cantidad_defectuosa for l in lineas)

    productos = _fetch_productos(pdc_id)
    base_kwargs["productos"] = productos
    # campo legacy `producto`: si la tabla nueva tiene algo, usar el primero
    if productos:
        base_kwargs["producto"] = productos[0].producto
        base_kwargs["marca"] = productos[0].marca

    base_kwargs["camaras"] = [CamaraOut(**c) for c in fetch_all(q.GET_CAMARAS_SQL, (pdc_id,))]
    base_kwargs["requisitos"] = [
        RequisitoRespuestaOut(**r) for r in fetch_all(q.GET_RESPUESTAS_SQL, (pdc_id,))
    ]
    return PieDeCamionDetail(**base_kwargs)


@router.post(
    "",
    response_model=PieDeCamionListItem,
    status_code=201,
    # Crear el pie de camión (la inspección de recepción) es específico del equipo
    # de recepción — `stock` puede ver/confirmar pero NO crear (write específico).
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion"))],
)
def create_pie_camion(
    body: PieDeCamionCreate,
    background_tasks: BackgroundTasks,
    user: CurrentUser = Depends(get_current_user),
):
    # Idempotencia: si este client_ref ya existe, el celu está re-mandando un pie
    # que YA se guardó (reintento tras un timeout donde la respuesta se perdió).
    # Devolvemos el existente — nunca un duplicado.
    if body.client_ref and body.client_ref.strip():
        ya = fetch_one(q.PIE_POR_CLIENT_REF_SQL, (body.client_ref.strip(),))
        if ya:
            return _list_item(fetch_one(q.GET_ONE_ITEM_SQL, (ya["id"],)))

    try:
        return _create_pie_camion_impl(body, background_tasks, user)
    except pg_errors.UniqueViolation:
        # Carrera del reintento: el request anterior (que el celu abortó por
        # timeout) TODAVÍA estaba commiteando cuando llegó este — el precheck no
        # lo vio y el índice único de client_ref (mig 0058) frenó el INSERT.
        # Ahora el otro ya commiteó: devolver ese en vez de un 500 críptico.
        if body.client_ref and body.client_ref.strip():
            ya = fetch_one(q.PIE_POR_CLIENT_REF_SQL, (body.client_ref.strip(),))
            if ya:
                return _list_item(fetch_one(q.GET_ONE_ITEM_SQL, (ya["id"],)))
        raise


def _create_pie_camion_impl(
    body: PieDeCamionCreate,
    background_tasks: BackgroundTasks,
    user: CurrentUser,
):
    # Las fotos de defectos del alta ya no tienen tope de cantidad: se controla
    # el peso, igual que en el reclamo post-hoc.
    _exigir_peso_fotos([d for l in body.lineas for d in (l.defectos or [])])
    _validar_reclamos_por_linea(body)
    # Requisitos por fruta del ing. agrónomo (mig 0092): validar ANTES de tocar
    # nada — si falta un obligatorio, el 400 lista exactamente qué.
    filas_requisitos, faltantes_requisitos = _respuestas_requisitos(body)
    if faltantes_requisitos:
        raise HTTPException(
            400,
            "Faltan requisitos del ing. agrónomo: " + " · ".join(faltantes_requisitos),
        )
    data = body.model_dump(exclude={"lineas", "productos", "fotos", "documentacion", "camaras", "requisitos"})
    # El pie hereda el ROLL-UP de sus líneas (mig 0072): hay reclamos en el camión
    # si los hay en alguna fruta. Todo lo que ya lee `pie.hay_reclamos` (informe,
    # listado, reclamo post-hoc) sigue andando sin cambios.
    if body.lineas:
        data["hay_reclamos"] = any(l.hay_reclamos for l in body.lineas)
    # Si vinieron productos en la lista nueva, los campos legacy se rellenan con
    # el primero para compatibilidad (queries viejas que usen `producto`/`marca`).
    if body.productos:
        data["producto"] = body.productos[0].producto
        data["marca"] = body.productos[0].marca

    # El link con la carga del plan es OPCIONAL. Sólo sirve para marcarla como
    # "Descargado", y como el plan es un espejo SOLO-LECTURA del Excel (la sync
    # re-inyecta la carga desde el Excel), ese marcado es best-effort. NUNCA
    # bloquear el pie de camión por esto: si la carga ya no existe (el plan se
    # re-sincroniza desde el Drive y reemplaza filas → cambian los ids, el que
    # eligió el operario queda viejo) o está Cancelada, guardamos igual sin
    # linkear. Lo importante es no perder el control del camión.
    if body.plan_carga_id is not None:
        plan_row = fetch_one(q.PLAN_CARGA_STATUS_SQL, (body.plan_carga_id,))
        if not plan_row or plan_row.get("status") == "Cancelado":
            body.plan_carga_id = None
            data["plan_carga_id"] = None

    # Validar lineas: producto debe existir + suma de defectos no supera cantidad
    for linea in body.lineas:
        cod = linea.cod_art.strip()
        if not fetch_one(q.ARTICULO_EXISTS_SQL, (cod,)):
            raise HTTPException(400, f"Artículo '{cod}' no existe")
        cant_def = sum(d.cantidad for d in linea.defectos)
        if cant_def > linea.cantidad:
            raise HTTPException(400, f"En {cod}: defectos ({cant_def}) superan la cantidad ({linea.cantidad})")
        for d in linea.defectos:
            if not fetch_one(rq.GET_MOTIVO_NOMBRE_SQL, (d.motivo_id,)):
                raise HTTPException(400, f"Motivo {d.motivo_id} inválido")

    # Validar cámaras: número dentro del tope real de cada ubicación (ZAC 30, CR 13),
    # y si la fila trae producto (desglose del reparto), que exista en la mercadería.
    _cods_lineas = {l.cod_art.strip() for l in body.lineas}
    for c in body.camaras:
        tope = CAMARAS_POR_UBICACION.get(c.ubicacion, 30)
        if not (1 <= c.numero <= tope):
            raise HTTPException(400, f"Cámara {c.ubicacion} {c.numero}: en {c.ubicacion} el número va de 1 a {tope}")
        if c.cod_art and c.cod_art.strip() not in _cods_lineas:
            raise HTTPException(400, f"Cámara {c.ubicacion} {c.numero}: el producto {c.cod_art} no está en la mercadería")

    # PDF placeholder (luego lo re-generamos con id real)
    filename_base = f"pie-camion-{body.fecha.strftime('%Y%m%d')}-{body.placa_camion.strip().replace(' ', '_')}"
    placeholder_pdf = pdf_gen.generate_piedecamion_pdf(
        data, creado_por_nombre=user.nombre or user.username, id_documento=0, lineas=[],
    )
    doc_pdf_bytes: bytes | None = None  # PDF de documentación escaneada (si trae)
    fotos_pdf: bytes | None = None      # PDF de fotos (aparte del informe de datos)

    with get_cursor() as cur:
        # Cerrar el race con la sync del plan: entre que resolvimos la carga
        # (arriba, fuera de la transacción) y este INSERT, la sync del Excel pudo
        # borrarla (borra + re-inserta con ids nuevos). La bloqueamos con FOR KEY
        # SHARE; si ya no está, guardamos sin linkear. Así la FK nunca tumba el
        # guardado del pie de camión (que es lo que importa).
        if data.get("plan_carga_id") is not None:
            cur.execute(
                "SELECT id FROM ext.plan_de_cargas WHERE id = %s FOR KEY SHARE",
                (data["plan_carga_id"],),
            )
            if cur.fetchone() is None:
                data["plan_carga_id"] = None
                body.plan_carga_id = None

        # Insert encabezado
        values = [data.get(c) for c in q.DATA_COLUMNS] + [
            (body.client_ref.strip() if body.client_ref and body.client_ref.strip() else None),
            filename_base + ".pdf", placeholder_pdf, len(placeholder_pdf), user.id,
        ]
        cur.execute(q.build_insert_sql(), tuple(values))
        new_id = cur.fetchone()["id"]

        # Insert tabla productos (multi-producto)
        for orden, pm in enumerate(body.productos):
            cur.execute(q.INSERT_PRODUCTO_SQL, (
                new_id, pm.producto.strip()[:100],
                (pm.marca.strip()[:100] if pm.marca else None),
                orden,
            ))

        # Insert cámaras de ingreso (1 = todo el camión / varias = repartido, cada
        # fila con su producto si el operario desglosó).
        for orden, c in enumerate(body.camaras):
            cur.execute(q.INSERT_CAMARA_SQL, (
                new_id, c.ubicacion, c.numero, c.cantidad,
                (c.cod_art.strip() if c.cod_art else None), orden,
            ))

        # Respuestas a los requisitos por fruta (snapshot, mig 0092).
        _persistir_respuestas(cur, new_id, filas_requisitos)

        # Insert lineas (y guardamos info para PDF y reclamo)
        lineas_for_pdf: list[dict] = []
        defectos_for_reclamo: list[dict] = []
        for orden, linea in enumerate(body.lineas):
            cod = linea.cod_art.strip()
            art_row = fetch_one(q.ARTICULO_DESCRIPCION_SQL, (cod,))
            descripcion = (art_row["descripcion"] if art_row else cod)[:200]
            dep = _deposito_de(linea)
            dep_row = fetch_one(q.DEPOSITO_DESCRIPCION_SQL, (dep,))
            dep_desc = dep_row["descripcion"] if dep_row else None

            cur.execute(q.INSERT_LINEA_SQL, (
                new_id, cod, descripcion, dep,
                linea.cantidad,
                (linea.marca.strip()[:100] if linea.marca else None),
                orden, linea.hay_reclamos,
            ))
            linea_id = cur.fetchone()["id"]

            defectos_pdf = []
            for d in linea.defectos:
                motivo_row = fetch_one(rq.GET_MOTIVO_NOMBRE_SQL, (d.motivo_id,))
                motivo_nombre = motivo_row["nombre"]
                cur.execute(q.INSERT_DEFECTO_SQL, (
                    linea_id, d.motivo_id, d.cantidad, d.notas, len(d.fotos),
                ))
                defectos_pdf.append({"motivo": motivo_nombre, "cantidad": d.cantidad})
                defectos_for_reclamo.append({
                    "cod_art": cod,
                    "descripcion": descripcion,
                    "cantidad_recibida": linea.cantidad,
                    "cantidad_defectuosa": d.cantidad,
                    "motivo": motivo_nombre,
                    "motivo_id": d.motivo_id,
                    "notas": d.notas,
                    "fotos": d.fotos,
                })

            lineas_for_pdf.append({
                "cod_art": cod, "descripcion": descripcion,
                "deposito": dep, "deposito_descripcion": dep_desc,
                "cantidad": linea.cantidad,
                "marca": (linea.marca or None),
                "hay_reclamos": linea.hay_reclamos,
                "defectos": defectos_pdf,
            })

        # Si hay defectos, generamos Reclamo + PDF (linkeado al pie_camion)
        reclamo_id_created = None
        if defectos_for_reclamo:
            proveedor = None
            for d_pdf in defectos_for_reclamo:
                p = fetch_one(q.PROVEEDOR_DE_ARTICULO_SQL, (d_pdf["cod_art"],))
                if p:
                    proveedor = p["nombre"]
                    break

            reclamo_pdf_bytes = reclamo_pdf.generate_reclamo_pdf(
                documento="(pie de camión)",
                nro_fact=new_id,
                fecha=body.fecha,
                creado_por_nombre=user.nombre or user.username,
                proveedor_nombre=proveedor,
                observaciones=body.observaciones,
                defectos=defectos_for_reclamo,
            )
            # Doc de fotos APARTE (None si no hay) — se fusiona al descargar y
            # sobrevive a las ediciones del reclamo.
            reclamo_fotos_pdf = reclamo_pdf.generate_reclamo_fotos_pdf(
                documento="(pie de camión)",
                nro_fact=new_id,
                defectos=defectos_for_reclamo,
            )
            reclamo_filename = f"reclamo-pie-{new_id}-{body.placa_camion.strip()}.pdf"
            # Reclamo con documento/nro_fact NULL — los seteamos al confirmar
            cur.execute("""
                INSERT INTO ext.reclamo
                    (documento, nro_fact, generado_por_usuario_id, observaciones,
                     pdf_filename, pdf_blob, pdf_size_bytes, pie_camion_id,
                     fotos_pdf_blob, fotos_pdf_size_bytes)
                VALUES (NULL, NULL, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
            """, (user.id, body.observaciones, reclamo_filename, reclamo_pdf_bytes, len(reclamo_pdf_bytes), new_id,
                  reclamo_fotos_pdf, len(reclamo_fotos_pdf) if reclamo_fotos_pdf else None))
            reclamo_id_created = cur.fetchone()["id"]
            cur.execute(q.UPDATE_RECLAMO_ID_SQL, (reclamo_id_created, new_id))

            # Líneas del reclamo (cantidad defectuosa por producto/motivo). SIN esto
            # el reclamo queda "vacío": el dashboard suma ext.reclamo_linea y mostraba
            # "0 cajas / —" (el módulo de stock sí las inserta; el pie no lo hacía).
            for d_rl in defectos_for_reclamo:
                cur.execute(rq.INSERT_RECLAMO_LINEA_SQL, (
                    reclamo_id_created,
                    d_rl["cod_art"],
                    d_rl["descripcion"],
                    d_rl["cantidad_defectuosa"],
                    d_rl["motivo_id"],
                    d_rl["notas"],
                    len(d_rl["fotos"]),
                ))

        # Fotos del camión → agrupadas por categoría para el fotos-PDF (aparte del
        # informe de datos, se fusiona al descargar). Ya NO se guardan individuales.
        fotos_grupos = _fotos_grupos_de_body(body)

        # Derivar lista de "Producto / Marca" para el header del PDF a partir
        # de las líneas (deduplicado por descripción+marca).
        productos_for_pdf = _derive_productos_from_lineas(lineas_for_pdf)

        # Informe de DATOS (sin fotos) con id real + lineas + defectos + productos + cámaras.
        final_pdf = pdf_gen.generate_piedecamion_pdf(
            data,
            creado_por_nombre=user.nombre or user.username,
            id_documento=new_id,
            lineas=lineas_for_pdf,
            productos=productos_for_pdf,
            camaras=[c.model_dump() for c in body.camaras],
            requisitos=_requisitos_para_pdf(filas_requisitos),
        )
        # Nombre de archivo identificable: pie-camion-<#>-<fecha>-<placa>.pdf
        final_filename = (
            f"pie-camion-{new_id}-{body.fecha.strftime('%Y%m%d')}"
            f"-{body.placa_camion.strip().replace(' ', '_')}.pdf"
        )
        cur.execute(q.UPDATE_PDF_SQL, (final_pdf, len(final_pdf), final_filename, new_id))

        # Fotos → PDF APARTE (se fusiona al descargar). None si no hay fotos.
        # Best-effort: una foto patológica (LayoutError, etc.) NO debe voltear la
        # creación del pie — se crea sin fotos y se re-suben editando (como el doc-PDF).
        try:
            fotos_pdf = pdf_gen.generate_piedecamion_fotos_pdf(id_documento=new_id, fotos_grupos=fotos_grupos)
            if fotos_pdf:
                cur.execute(q.UPDATE_FOTOS_PDF_SQL, (fotos_pdf, len(fotos_pdf), new_id))
        except Exception as e:
            fotos_pdf = None
            logger.warning(f"no pude generar el fotos-PDF del pie {new_id}, lo creo sin fotos: {e}")

        # PDF de DOCUMENTACIÓN escaneada (aparte de la planilla). Decodificamos
        # cada página (mismo helper que las fotos), armamos un PDF A4 (1 página por
        # imagen) y lo guardamos en las columnas doc_pdf_*. Best-effort: páginas
        # corruptas o gigantes se skipean; si no queda ninguna, no se genera nada.
        doc_pages_bytes: list[bytes] = []
        for pagina in body.documentacion:
            try:
                blob = _decode_image_data_uri(pagina)
            except Exception:
                continue
            if len(blob) > 5 * 1024 * 1024:  # una página A4 escaneada; tope holgado
                continue
            doc_pages_bytes.append(blob)
        if doc_pages_bytes:
            # Best-effort de verdad: el PDF de documentación es secundario. Si su
            # armado falla (imagen patológica, LayoutError de reportlab, etc.) NO
            # puede tumbar el guardado del pie entero — se pierde toda la carga
            # (fotos incluidas). Guardamos el pie sin el doc y seguimos.
            try:
                generado = pdf_gen.generate_documentacion_pdf(doc_pages_bytes, id_documento=new_id)
            except Exception:
                logger.exception("PDF de documentación falló; guardo el pie sin él (pie=%s)", new_id)
                generado = None
            if generado:
                doc_pdf_bytes = generado
                doc_filename = (
                    f"pie-camion-{new_id}-{body.fecha.strftime('%Y%m%d')}"
                    f"-{body.placa_camion.strip().replace(' ', '_')}-documentacion.pdf"
                )
                cur.execute(q.UPDATE_DOC_PDF_SQL, (doc_pdf_bytes, len(doc_pdf_bytes), doc_filename, new_id))

        # Si veníamos linkeados a una carga del plan, marcarla como
        # Descargado. Las cargas Cancelado/Descargado no se tocan
        # (el WHERE del UPDATE las skipea).
        if body.plan_carga_id is not None:
            cur.execute(
                q.UPDATE_PLAN_CARGA_DESCARGADO_SQL,
                (user.id, body.fecha, body.plan_carga_id),
            )

    # Offload de los documentos a S3 (best-effort → libera el blob de Postgres).
    # DESPUÉS de la respuesta (background), no en el request: con muchas fotos y
    # un S3 lento, hacerlo sincrónico colgaría la carga del pie en la tablet. Si
    # S3 no está o falla, el blob queda y todo sigue igual (read() usa el blob).
    def _offloads() -> None:
        s3.offload_pdf("pie_de_camion", new_id, final_pdf, "piedecamion")
        if reclamo_id_created:
            s3.offload_pdf("reclamo", reclamo_id_created, reclamo_pdf_bytes, "reclamos")
            if reclamo_fotos_pdf:
                s3.offload_pdf(
                    "reclamo", reclamo_id_created, reclamo_fotos_pdf, "reclamos_fotos",
                    blob_col="fotos_pdf_blob", s3_col="fotos_pdf_s3_key",
                )
        if doc_pdf_bytes:
            s3.offload_pdf(
                "pie_de_camion", new_id, doc_pdf_bytes, "piedecamion_doc",
                blob_col="doc_pdf_blob", s3_col="doc_pdf_s3_key",
            )
        if fotos_pdf:
            s3.offload_pdf(
                "pie_de_camion", new_id, fotos_pdf, "piedecamion_fotos",
                blob_col="fotos_pdf_blob", s3_col="fotos_pdf_s3_key",
            )

    background_tasks.add_task(_offloads)

    # Avisar a los dashboards de maduración del compañero (auto-carga de cámara).
    # Best-effort: corre DESPUÉS de la respuesta (el commit ya pasó → líneas/cámaras
    # en la DB) y nunca rompe la carga del pie.
    background_tasks.add_task(webhook.enviar_registrado, new_id)

    fresh = fetch_one(q.GET_ONE_ITEM_SQL, (new_id,))
    return _list_item(fresh)


def _fotos_grupos_de_db(pdc_id: int) -> list[tuple[str, list[bytes]]]:
    """Reconstruye los grupos de fotos (label, [bytes]) desde la DB para re-generar el
    informe al editar. Agrupa consecutivas por categoría (el `caption` es el label);
    las sin categoría van juntas como 'Otras fotos'. Mismo formato que arma el create."""
    grupos: list[tuple[str, list[bytes]]] = []
    last: str | None = None
    for r in fetch_all(q.GET_FOTOS_PARA_PDF_SQL, (pdc_id,)):
        cat = (r.get("categoria") or "").strip() or None
        key = cat or "__otras__"
        label = (r.get("caption") or cat) if cat else "Otras fotos"
        blob = s3.read(r.get("foto_s3_key"), r.get("foto_blob"))
        if grupos and last == key:
            grupos[-1][1].append(blob)
        else:
            grupos.append((label, [blob]))
        last = key
    return grupos


def regenerar_pie_split(pdc_id: int) -> tuple[bytes, bytes | None]:
    """BACKFILL: migra un pie VIEJO al modelo partido. Regenera el informe de DATOS
    (sin fotos) desde la DB y arma el fotos-PDF a partir de las fotos individuales
    que tenía. Guarda ambos y devuelve (datos_pdf, fotos_pdf) para offloadear. Es la
    misma reconstrucción que hace el reclamo (build_get_detail_sql + lineas c/defectos)."""
    pie = fetch_one(q.build_get_detail_sql(), (pdc_id,))
    if not pie:
        raise ValueError(f"pie {pdc_id} no existe")
    pie = dict(pie)
    for k, v in list(pie.items()):
        if v is not None and v.__class__.__name__ == "Decimal":
            pie[k] = float(v)
    lineas_for_pdf = _lineas_full_with_defectos(pdc_id)
    datos_pdf = pdf_gen.generate_piedecamion_pdf(
        pie,
        creado_por_nombre=pie.get("creado_por_nombre") or pie.get("creado_por_username") or "",
        id_documento=pdc_id,
        lineas=lineas_for_pdf,
        productos=_derive_productos_from_lineas(lineas_for_pdf),
        camaras=fetch_all(q.GET_CAMARAS_SQL, (pdc_id,)),
    )
    fotos_pdf = pdf_gen.generate_piedecamion_fotos_pdf(
        id_documento=pdc_id, fotos_grupos=_fotos_grupos_de_db(pdc_id),
    )
    filename = pie.get("pdf_filename") or f"pie-camion-{pdc_id}.pdf"
    with get_cursor() as cur:
        cur.execute(q.UPDATE_PDF_SQL, (datos_pdf, len(datos_pdf), filename, pdc_id))
        if fotos_pdf:
            cur.execute(q.UPDATE_FOTOS_PDF_SQL, (fotos_pdf, len(fotos_pdf), pdc_id))
    return datos_pdf, fotos_pdf


@router.put(
    "/{pdc_id}",
    response_model=PieDeCamionListItem,
    # Editar es del equipo de recepción (mismo permiso que crear). `stock` NO edita.
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion"))],
)
def editar_pie_camion(
    pdc_id: int,
    body: PieDeCamionCreate,
    background_tasks: BackgroundTasks,
    user: CurrentUser = Depends(get_current_user),
):
    """Edita un pie de camión PENDIENTE (desde Ingresos): actualiza todos los campos de
    datos + mercadería + cámaras + productos y RE-GENERA el informe de datos. Las FOTOS
    del body, si vienen, REEMPLAZAN el fotos-PDF; si no vienen, se conserva el que había
    (igual que el reclamo). Los `defectos` de las líneas se preservan por cod_art (para
    NO perder el reclamo ni sus fotos, que viven en el PDF del reclamo)."""
    row = fetch_one(
        "SELECT BTRIM(estado) AS estado, plan_carga_id, hay_reclamos "
        "FROM ext.pie_de_camion WHERE id = %s", (pdc_id,),
    )
    if not row:
        raise HTTPException(404, "Pie de camión no encontrado")
    if row["estado"] != "pendiente":
        raise HTTPException(409, f"El pie está '{row['estado']}': solo se puede editar mientras está pendiente.")

    # Validaciones (producto existe + cámaras en rango). Los defectos NO se validan
    # acá: no se editan, se preservan.
    for linea in body.lineas:
        if not fetch_one(q.ARTICULO_EXISTS_SQL, (linea.cod_art.strip(),)):
            raise HTTPException(400, f"Artículo '{linea.cod_art.strip()}' no existe")
    _cods_lineas = {l.cod_art.strip() for l in body.lineas}
    for c in body.camaras:
        tope = CAMARAS_POR_UBICACION.get(c.ubicacion, 30)
        if not (1 <= c.numero <= tope):
            raise HTTPException(400, f"Cámara {c.ubicacion} {c.numero}: en {c.ubicacion} el número va de 1 a {tope}")
        if c.cod_art and c.cod_art.strip() not in _cods_lineas:
            raise HTTPException(400, f"Cámara {c.ubicacion} {c.numero}: el producto {c.cod_art} no está en la mercadería")

    data = body.model_dump(exclude={"lineas", "productos", "fotos", "documentacion", "camaras", "fotos_categoria", "requisitos"})
    if body.productos:
        data["producto"] = body.productos[0].producto
        data["marca"] = body.productos[0].marca
    # El link al plan NO se re-edita: preservamos el que ya tenía el pie (el form no lo
    # trae). Así editar no desvincula la carga del Plan.
    data["plan_carga_id"] = row["plan_carga_id"]
    # Ídem "¿hay reclamos?": la edición NO toca los defectos (se preservan por
    # cod_art más abajo), así que TAMPOCO puede cambiar la respuesta — se ignora
    # lo que venga en el body y se conserva SIEMPRE la que ya estaba. Sin esto,
    # el UPDATE de DATA_COLUMNS la dejaba en NULL (front que no la manda) o
    # permitía por API declarar "no hay reclamos" en un pie con defectos.
    data["hay_reclamos"] = row.get("hay_reclamos")
    fotos_pdf: bytes | None = None  # se genera solo si la edición trae fotos nuevas

    with get_cursor() as cur:
        cur.execute(q.build_update_data_sql(), tuple(data.get(c) for c in q.DATA_COLUMNS) + (user.id, pdc_id))
        # Race-safe: si otro proceso confirmó el pie entre el chequeo y esto, el UPDATE
        # (WHERE estado='pendiente') no toca nada → abortamos toda la edición.
        if cur.rowcount != 1:
            raise HTTPException(409, "El pie dejó de estar pendiente mientras lo editabas. Recargá y probá de nuevo.")

        # Snapshot de defectos por cod_art ANTES de borrar las líneas → los re-adjuntamos
        # a la línea del mismo cod_art (el reclamo y sus fotos quedan intactos). DENTRO
        # de la tx (el UPDATE de arriba ya lockeó la fila del pie): un reclamo post-hoc
        # concurrente o ya commiteó sus defectos (los vemos acá) o está esperando este
        # lock — nunca se pierden en el CASCADE del DELETE de líneas.
        defectos_por_cod: dict[str, list[dict]] = {}
        cur.execute(q.GET_DEFECTOS_POR_COD_SQL, (pdc_id,))
        for d in cur.fetchall():
            defectos_por_cod.setdefault(d["cod_art"], []).append(d)

        # Ídem con la respuesta "¿hay reclamos?" de cada línea (mig 0072): la
        # edición la conserva por cod_art, como los defectos.
        cur.execute(
            "SELECT BTRIM(cod_art) AS cod_art, hay_reclamos FROM ext.pie_de_camion_linea "
            "WHERE pie_camion_id = %s AND hay_reclamos IS NOT NULL",
            (pdc_id,),
        )
        reclamos_por_cod: dict[str, bool] = {r["cod_art"]: r["hay_reclamos"] for r in cur.fetchall()}

        # Los defectos se preservan por cod_art: si la edición SACA un producto que
        # tiene defectos, o le baja las cajas por debajo de lo defectuoso, quedaban
        # tirados en silencio (el pie seguía con reclamo_id y hay_reclamos=true pero
        # la planilla re-generada ya no mostraba el defecto). Se corta antes de tocar
        # nada — la tx hace rollback y el mensaje dice qué hacer.
        if defectos_por_cod:
            cajas_por_cod: dict[str, float] = {}
            for linea in body.lineas:
                cajas_por_cod[linea.cod_art.strip()] = (
                    cajas_por_cod.get(linea.cod_art.strip(), 0) + float(linea.cantidad)
                )
            for cod_def, defs in defectos_por_cod.items():
                defectuoso = sum(float(d["cantidad"]) for d in defs)
                if cod_def not in cajas_por_cod:
                    raise HTTPException(409, (
                        f"El producto {cod_def} tiene un defecto reclamado: no se puede quitar "
                        "desde acá. Primero editá el reclamo (botón «Editar reclamo» en Ingresos) "
                        "y sacá ese defecto."
                    ))
                if cajas_por_cod[cod_def] < defectuoso:
                    raise HTTPException(409, (
                        f"En {cod_def} pusiste {cajas_por_cod[cod_def]:g} cajas pero hay "
                        f"{defectuoso:g} reclamadas como defectuosas. Subí las cajas o editá "
                        "el reclamo primero."
                    ))

        cur.execute(q.DELETE_PRODUCTOS_SQL, (pdc_id,))
        for orden, pm in enumerate(body.productos):
            cur.execute(q.INSERT_PRODUCTO_SQL, (
                pdc_id, pm.producto.strip()[:100],
                (pm.marca.strip()[:100] if pm.marca else None), orden,
            ))

        # Requisitos por fruta: si la edición TRAE respuestas, reemplazan a las
        # anteriores (validando obligatorios como el alta; las FOTOS ya
        # guardadas cuentan — viven en el fotos-PDF y el form no las re-manda).
        # Si NO trae, se conservan las que había (pies viejos editables).
        if body.requisitos:
            previas = fetch_all(q.GET_RESPUESTAS_SQL, (pdc_id,))
            fotos_previas = {
                r["requisito_id"]: r["fotos_n"]
                for r in previas
                if r["tipo"] == "foto" and r["requisito_id"] is not None
            }
            filas_requisitos, faltantes_requisitos = _respuestas_requisitos(body, fotos_previas)
            if faltantes_requisitos:
                raise HTTPException(
                    400,
                    "Faltan requisitos del ing. agrónomo: " + " · ".join(faltantes_requisitos),
                )
            cur.execute(q.DELETE_RESPUESTAS_SQL, (pdc_id,))
            _persistir_respuestas(cur, pdc_id, filas_requisitos)
        else:
            filas_requisitos = fetch_all(q.GET_RESPUESTAS_SQL, (pdc_id,))

        cur.execute(q.DELETE_CAMARAS_SQL, (pdc_id,))
        for orden, c in enumerate(body.camaras):
            cur.execute(q.INSERT_CAMARA_SQL, (
                pdc_id, c.ubicacion, c.numero, c.cantidad,
                (c.cod_art.strip() if c.cod_art else None), orden,
            ))

        cur.execute(q.DELETE_LINEAS_SQL, (pdc_id,))   # CASCADE borra los defectos viejos
        lineas_for_pdf: list[dict] = []
        for orden, linea in enumerate(body.lineas):
            cod = linea.cod_art.strip()
            art_row = fetch_one(q.ARTICULO_DESCRIPCION_SQL, (cod,))
            descripcion = (art_row["descripcion"] if art_row else cod)[:200]
            dep = _deposito_de(linea)
            dep_row = fetch_one(q.DEPOSITO_DESCRIPCION_SQL, (dep,))
            dep_desc = dep_row["descripcion"] if dep_row else None
            cur.execute(q.INSERT_LINEA_SQL, (
                pdc_id, cod, descripcion, dep, linea.cantidad,
                (linea.marca.strip()[:100] if linea.marca else None), orden,
                # La edición NO re-pregunta ni toca los defectos → tampoco puede
                # cambiar la respuesta: se preserva la de este cod_art. Una línea
                # NUEVA agregada al editar queda en NULL (no se sabe, y el informe
                # no declara nada para ella).
                reclamos_por_cod.get(cod),
            ))
            linea_id = cur.fetchone()["id"]
            # Re-adjuntar los defectos preservados de este cod_art (reclamo intacto).
            # .pop (no .get): cada defecto se asigna UNA sola vez → si dos líneas
            # comparten cod_art, no se duplican (irían todos a la primera).
            defectos_pdf = []
            for d in defectos_por_cod.pop(cod, []):
                cur.execute(q.INSERT_DEFECTO_SQL, (
                    linea_id, d["motivo_id"], d["cantidad"], d["notas"], d["cantidad_fotos"],
                ))
                mrow = fetch_one(rq.GET_MOTIVO_NOMBRE_SQL, (d["motivo_id"],))
                defectos_pdf.append({"motivo": mrow["nombre"] if mrow else "—", "cantidad": d["cantidad"]})
            lineas_for_pdf.append({
                "cod_art": cod, "descripcion": descripcion,
                "deposito": dep, "deposito_descripcion": dep_desc,
                "cantidad": linea.cantidad, "marca": (linea.marca or None),
                "hay_reclamos": reclamos_por_cod.get(cod),
                "defectos": defectos_pdf,
            })

        # Re-generar el informe de DATOS (sin fotos).
        productos_for_pdf = _derive_productos_from_lineas(lineas_for_pdf)
        final_pdf = pdf_gen.generate_piedecamion_pdf(
            data,
            creado_por_nombre=user.nombre or user.username,
            id_documento=pdc_id,
            lineas=lineas_for_pdf,
            productos=productos_for_pdf,
            camaras=[c.model_dump() for c in body.camaras],
            requisitos=_requisitos_para_pdf([dict(f) for f in filas_requisitos]),
        )
        final_filename = (
            f"pie-camion-{pdc_id}-{body.fecha.strftime('%Y%m%d')}"
            f"-{body.placa_camion.strip().replace(' ', '_')}.pdf"
        )
        cur.execute(q.UPDATE_PDF_SQL, (final_pdf, len(final_pdf), final_filename, pdc_id))

        # Fotos: si la edición TRAE fotos, reemplazan el fotos-PDF. Si NO trae:
        # conservar el que había; y si el pie es VIEJO (fotos individuales, sin
        # fotos_pdf todavía), migrarlo AHORA desde las individuales — si no, al
        # regenerar el datos-PDF (que ya no lleva fotos) se perderían del informe.
        fotos_grupos = _fotos_grupos_de_body(body)
        if not fotos_grupos:
            tiene = fetch_one(
                "SELECT (fotos_pdf_blob IS NOT NULL) AS b, fotos_pdf_s3_key "
                "FROM ext.pie_de_camion WHERE id = %s", (pdc_id,),
            )
            if not (tiene and (tiene["b"] or tiene.get("fotos_pdf_s3_key"))):
                fotos_grupos = _fotos_grupos_de_db(pdc_id)  # pie viejo → migrar sus fotos
        if fotos_grupos:
            fotos_pdf = pdf_gen.generate_piedecamion_fotos_pdf(id_documento=pdc_id, fotos_grupos=fotos_grupos)
            if fotos_pdf:
                cur.execute(q.UPDATE_FOTOS_PDF_SQL, (fotos_pdf, len(fotos_pdf), pdc_id))

    # Offload de los PDF re-generados a S3 (best-effort, fuera de la tx).
    s3.offload_pdf("pie_de_camion", pdc_id, final_pdf, "piedecamion")
    if fotos_pdf:
        s3.offload_pdf(
            "pie_de_camion", pdc_id, fotos_pdf, "piedecamion_fotos",
            blob_col="fotos_pdf_blob", s3_col="fotos_pdf_s3_key",
        )
    # Re-avisar al webhook (best-effort): la cámara/producto pudo cambiar; su flujo de
    # revisión (idempotente por id) lo maneja.
    background_tasks.add_task(webhook.enviar_registrado, pdc_id)

    return _list_item(fetch_one(q.GET_ONE_ITEM_SQL, (pdc_id,)))


@router.post(
    "/{pdc_id}/fotos",
    # Mismo permiso que crear/editar: es documentación de recepción.
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion"))],
)
def agregar_fotos(
    pdc_id: int,
    body: AgregarFotosRequest,
    user: CurrentUser = Depends(get_current_user),
):
    """Suma fotos a un pie YA ENVIADO. Las fotos viven en un PDF aparte (mig 0056)
    que se fusiona con el informe al descargar, así que agregar = ANEXAR páginas
    a ese PDF. Se puede en cualquier estado: es documentación, no toca Macrosoft.

    Lo que NO se puede (y por qué): borrar o reordenar las fotos anteriores —
    desde la 0056 no se guardan sueltas, existen sólo adentro del PDF.
    """
    grupos = _fotos_grupos(body.fotos_categoria, body.fotos)
    if not grupos:
        raise HTTPException(400, "No llegó ninguna foto válida (el tope es 2 MB por foto).")
    if not fetch_one("SELECT 1 AS x FROM ext.pie_de_camion WHERE id = %s", (pdc_id,)):
        raise HTTPException(404, "Pie de camión no encontrado")

    # El anexo va FECHADO y firmado en el PDF: si no, en el informe parecerían
    # tomadas en la recepción.
    quien = (user.nombre or user.username or "").strip()
    titulo = f"Fotos agregadas el {datetime.now(_UY):%d/%m/%Y %H:%M}"
    if quien:
        titulo += f" por {quien}"
    if (body.nota or "").strip():
        titulo += f" — {body.nota.strip()}"
    nuevas_pdf = pdf_gen.generate_piedecamion_fotos_pdf(
        id_documento=pdc_id, fotos_grupos=grupos, titulo=titulo,
    )
    if not nuevas_pdf:
        raise HTTPException(400, "No se pudo armar el PDF con esas fotos.")

    n_fotos = sum(len(fs) for _, fs in grupos)
    with get_cursor() as cur:
        # Serializa contra otro anexo simultáneo: los dos leerían el MISMO PDF
        # viejo y el segundo pisaría al primero (fotos perdidas sin aviso).
        cur.execute("SELECT pg_advisory_xact_lock(42069, %s)", (pdc_id,))
        cur.execute(q.GET_FOTOS_PDF_SQL, (pdc_id,))
        row = cur.fetchone()
        previo: bytes | None = None
        if row and (row["fotos_pdf_s3_key"] or row["fotos_pdf_blob"]):
            previo = s3.read(row["fotos_pdf_s3_key"], row["fotos_pdf_blob"])
        else:
            # Pie VIEJO (fotos como filas individuales, sin fotos-PDF todavía):
            # se arma primero el suyo, si no el anexo se comería las originales.
            viejos = _fotos_grupos_de_db(pdc_id)
            if viejos:
                previo = pdf_gen.generate_piedecamion_fotos_pdf(
                    id_documento=pdc_id, fotos_grupos=viejos,
                )
        final = nuevas_pdf
        if previo:
            final = merge_pdfs(previo, nuevas_pdf)
            # merge_pdfs es best-effort: ante cualquier problema devuelve SOLO la
            # base. Para la descarga está bien (nunca romper el informe), pero acá
            # sería perder las fotos nuevas en silencio después de decir "listo".
            # Se verifica por cantidad de páginas y, si no cierra, se aborta: el
            # raise deja la transacción sin efecto (nada cambió).
            pp, pn, pf = _paginas_pdf(previo), _paginas_pdf(nuevas_pdf), _paginas_pdf(final)
            if pp < 0 or pn < 0 or pf != pp + pn:
                logger.error("pie %s: el anexo de fotos no cerró (%s + %s -> %s)", pdc_id, pp, pn, pf)
                raise HTTPException(
                    500,
                    "No se pudieron anexar las fotos al informe. No se cambió nada: "
                    "probá de nuevo y si sigue igual avisá.",
                )
        cur.execute(q.ANEXAR_FOTOS_PDF_SQL, (final, len(final), user.id, pdc_id))

    # Offload a S3 fuera de la transacción (best-effort, igual que crear/editar).
    s3.offload_pdf(
        "pie_de_camion", pdc_id, final, "piedecamion_fotos",
        blob_col="fotos_pdf_blob", s3_col="fotos_pdf_s3_key",
    )
    logger.info("pie %s: %d foto(s) agregadas por %s", pdc_id, n_fotos, quien or user.id)
    return {"ok": True, "fotos_agregadas": n_fotos}


@router.post(
    "/{pdc_id}/marcar-descargado",
    status_code=204,
    # Write: no lo abre `consulta` (que sólo entra a la puerta de lectura).
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion", "stock"))],
)
def marcar_descargado(pdc_id: int, user: CurrentUser = Depends(get_current_user)):
    """Marca el pie de camión como 'descargado/revisado' (compartido entre celus).
    Lo llama Ingresos al bajar la planilla, para ver cuáles ya se revisaron."""
    with get_cursor() as cur:
        cur.execute(q.MARCAR_DESCARGADO_SQL, (user.id, pdc_id))
    return Response(status_code=204)


# Tope de PESO de las fotos de un envío. No hay tope de CANTIDAD (un reclamo real
# trajo 46 fotos de un pallet): el problema nunca fue cuántas sino cuánto pesan.
# nginx corta el body en 50 MB y devuelve un 413 en HTML que el front no sabe
# explicar; acá se corta antes, con un mensaje que dice qué hacer. base64 infla
# ~33%, así que 30 MB de fotos ≈ 40 MB de body: entra con margen.
_MAX_FOTOS_BYTES = 30 * 1024 * 1024


def _exigir_peso_fotos(defectos) -> None:
    """413 legible si las fotos de este envío pesan más de lo que aguanta el POST."""
    total = 0
    n = 0
    for d in defectos:
        for f in getattr(d, "fotos", None) or []:
            # len(base64) * 3/4 ≈ bytes reales, sin decodificar (que costaría RAM).
            total += len(f) * 3 // 4
            n += 1
    if total > _MAX_FOTOS_BYTES:
        raise HTTPException(
            413,
            f"Las {n} fotos pesan {total / 1024 / 1024:.0f} MB y el tope por envío es "
            f"{_MAX_FOTOS_BYTES // 1024 // 1024} MB. Mandá el reclamo con menos fotos "
            f"(podés agregar más después) o sacalas de nuevo con menos resolución.",
        )


def _reclamo_pie(pdc_id: int, body: ReclamoPieCreate, user: CurrentUser, reemplazar: bool) -> dict:
    """Genera (reemplazar=False) o RE-HACE (reemplazar=True) el reclamo al proveedor de
    un pie ya cargado. En ambos casos: valida los defectos contra las líneas reales,
    genera el PDF de reclamo (mismo formato que el del alta) y RE-GENERA el informe
    para que la planilla muestre los defectos.

    Al re-hacer, los defectos NUEVOS reemplazan a TODOS los anteriores (las fotos
    viejas viven solo en el PDF viejo → no se conservan; el front lo avisa)."""
    _exigir_peso_fotos(body.defectos)
    pie = fetch_one(q.build_get_detail_sql(), (pdc_id,))
    if not pie:
        raise HTTPException(404, "Pie de camión no encontrado")
    pie = dict(pie)
    for k, v in list(pie.items()):
        if v is not None and v.__class__.__name__ == "Decimal":
            pie[k] = float(v)
    estado = (pie.get("estado") or "pendiente").strip()
    if estado == "anulado":
        raise HTTPException(409, "El pie está anulado: no se puede reclamar.")
    if not reemplazar and pie.get("reclamo_id"):
        raise HTTPException(409, "Este pie ya tiene un reclamo generado.")
    if reemplazar and not pie.get("reclamo_id"):
        raise HTTPException(409, "Este pie no tiene reclamo para editar.")

    # Validar defectos contra las líneas reales del pie. Al re-hacer, los previos
    # se van a borrar → no cuentan para el tope por línea (ni van al informe).
    lineas_db = fetch_all(q.GET_LINEAS_SQL, (pdc_id,))
    por_id = {l["id"]: l for l in lineas_db}
    defectos_previos = (
        {l["id"]: [] for l in lineas_db}
        if reemplazar
        else {l["id"]: fetch_all(q.GET_LINEA_DEFECTOS_SQL, (l["id"],)) for l in lineas_db}
    )
    nuevos_por_linea: dict[int, list] = {}
    motivo_nombre: dict[int, str] = {}
    for d in body.defectos:
        if d.linea_id not in por_id:
            raise HTTPException(400, f"La línea {d.linea_id} no pertenece a este pie")
        if d.motivo_id not in motivo_nombre:
            m = fetch_one(rq.GET_MOTIVO_NOMBRE_SQL, (d.motivo_id,))
            if not m:
                raise HTTPException(400, f"Motivo {d.motivo_id} inválido")
            motivo_nombre[d.motivo_id] = m["nombre"]
        nuevos_por_linea.setdefault(d.linea_id, []).append(d)
    for lid, ds in nuevos_por_linea.items():
        linea = por_id[lid]
        total_def = sum(float(e["cantidad"]) for e in defectos_previos[lid]) + sum(x.cantidad for x in ds)
        if total_def > float(linea["cantidad"]):
            raise HTTPException(
                400,
                f"En {linea['cod_art'].strip()}: defectos ({total_def}) superan la cantidad ({float(linea['cantidad'])})",
            )

    # Armar los datos del reclamo y del informe re-generado (los defectos nuevos aún
    # no están en la DB → se mezclan en memoria).
    defectos_for_reclamo: list[dict] = []
    lineas_for_pdf: list[dict] = []
    for l in lineas_db:
        cod = l["cod_art"].strip()
        defectos_pdf = [
            {"motivo": e["motivo"], "cantidad": float(e["cantidad"])}
            for e in defectos_previos[l["id"]]
        ]
        for d in nuevos_por_linea.get(l["id"], []):
            defectos_pdf.append({"motivo": motivo_nombre[d.motivo_id], "cantidad": d.cantidad})
            defectos_for_reclamo.append({
                "cod_art": cod,
                "descripcion": l["descripcion"],
                "cantidad_recibida": float(l["cantidad"]),
                "cantidad_defectuosa": d.cantidad,
                "motivo": motivo_nombre[d.motivo_id],
                "motivo_id": d.motivo_id,
                "notas": d.notas,
                "fotos": d.fotos,
            })
        lineas_for_pdf.append({
            "cod_art": cod, "descripcion": l["descripcion"],
            "deposito": l["deposito"], "deposito_descripcion": l.get("deposito_descripcion"),
            "cantidad": float(l["cantidad"]), "marca": l.get("marca"),
            # Reclamar post-hoc sobre esta línea la pone en SÍ (abajo se persiste).
            "hay_reclamos": True if l["id"] in nuevos_por_linea else l.get("hay_reclamos"),
            "defectos": defectos_pdf,
        })

    proveedor = None
    for d_pdf in defectos_for_reclamo:
        p = fetch_one(q.PROVEEDOR_DE_ARTICULO_SQL, (d_pdf["cod_art"],))
        if p:
            proveedor = p["nombre"]
            break

    # Fallback de observaciones: al EDITAR, si el body no trae, se conservan las del
    # RECLAMO actual (pisarlas con las del pie destruía texto propio del reclamo,
    # ej. "el chofer firmó constancia"). Al crear, caen a las del pie como siempre.
    if reemplazar:
        observaciones = body.observaciones or pie.get("reclamo_observaciones") or pie.get("observaciones")
    else:
        observaciones = body.observaciones or pie.get("observaciones")
    reclamo_pdf_bytes = reclamo_pdf.generate_reclamo_pdf(
        documento="(pie de camión)",
        nro_fact=pdc_id,
        fecha=pie["fecha"],
        creado_por_nombre=user.nombre or user.username,
        proveedor_nombre=proveedor,
        observaciones=observaciones,
        defectos=defectos_for_reclamo,
    )
    # Doc de fotos aparte. None = esta pasada no trajo fotos → al EDITAR se
    # conserva el doc de fotos anterior (ese era el punto de separarlos).
    reclamo_fotos_pdf = reclamo_pdf.generate_reclamo_fotos_pdf(
        documento="(pie de camión)",
        nro_fact=pdc_id,
        defectos=defectos_for_reclamo,
    )
    reclamo_filename = f"reclamo-pie-{pdc_id}-{(pie.get('placa_camion') or '').strip()}.pdf"

    # Informe de datos re-generado con los defectos visibles en la mercadería. Las
    # fotos del pie viven aparte (fotos_pdf) y no las toca el reclamo.
    # Reclamar post-hoc CONTRADICE un "no hay reclamos" del alta: el pie pasa a
    # tener reclamo, así que la declaración del informe se corrige acá y en la DB
    # (si no, el informe seguiría diciendo "SIN RECLAMOS" con el reclamo adjunto).
    pie["hay_reclamos"] = True
    informe_pdf = pdf_gen.generate_piedecamion_pdf(
        pie,
        creado_por_nombre=pie.get("creado_por_nombre") or pie.get("creado_por_username") or "",
        id_documento=pdc_id,
        lineas=lineas_for_pdf,
        productos=_derive_productos_from_lineas(lineas_for_pdf),
        camaras=fetch_all(q.GET_CAMARAS_SQL, (pdc_id,)),
    )

    with get_cursor() as cur:
        # Lock de la fila del pie + RE-lectura: confirmar/editar también arrancan su
        # tx tocando esta fila, así que esto serializa los tres. La lectura de arriba
        # (fuera de tx, con dos PDFs generados en el medio) puede estar VIEJA.
        cur.execute("""
            SELECT BTRIM(estado) AS estado, reclamo_id, ingreso_documento, ingreso_nro_fact
            FROM ext.pie_de_camion WHERE id = %s FOR UPDATE
        """, (pdc_id,))
        fresco = cur.fetchone()
        if not fresco:
            raise HTTPException(404, "Pie de camión no encontrado")
        if not reemplazar and fresco["reclamo_id"]:
            raise HTTPException(409, "Este pie ya tiene un reclamo generado.")
        if reemplazar and not fresco["reclamo_id"]:
            raise HTTPException(409, "Este pie no tiene reclamo para editar.")
        if fresco["estado"] == "anulado":
            raise HTTPException(409, "El pie está anulado: no se puede reclamar.")
        # Una edición concurrente re-crea las líneas con ids nuevos → si insertáramos
        # con los ids viejos: FK violation o defectos colgados de líneas muertas.
        cur.execute("SELECT id FROM ext.pie_de_camion_linea WHERE pie_camion_id = %s", (pdc_id,))
        ids_actuales = {r["id"] for r in cur.fetchall()}
        if not set(nuevos_por_linea).issubset(ids_actuales):
            raise HTTPException(409, "El pie fue editado mientras marcabas los defectos. Cerrá el reclamo y volvé a abrirlo.")

        # Cuántas fotos tenía YA cada defecto (cod_art + motivo). El modal
        # pre-carga los defectos pero NO las imágenes (viven sólo dentro del
        # PDF), así que sin esto un re-hacer los dejaba en 0 fotos aunque las
        # fotos siguieran en el documento.
        fotos_previas: dict[tuple[str, int], int] = {}
        if reemplazar:
            cur.execute(q.FOTOS_PREVIAS_POR_DEFECTO_SQL, (pdc_id,))
            fotos_previas = {
                (r["cod_art"], r["motivo_id"]): int(r["cantidad_fotos"] or 0)
                for r in cur.fetchall()
            }
            # Re-hacer = los defectos nuevos REEMPLAZAN a todos los anteriores.
            cur.execute(q.DELETE_DEFECTOS_DEL_PIE_SQL, (pdc_id,))
        cod_de_linea = {l["id"]: (l["cod_art"] or "").strip() for l in lineas_db}
        for lid, ds in nuevos_por_linea.items():
            for d in ds:
                n_fotos = len(d.fotos)
                if n_fotos == 0 and not body.reemplazar_fotos:
                    # Sin fotos nuevas: sus fotos anteriores siguen en el PDF.
                    n_fotos = fotos_previas.get((cod_de_linea.get(lid, ""), d.motivo_id), 0)
                cur.execute(q.INSERT_DEFECTO_SQL, (lid, d.motivo_id, d.cantidad, d.notas, n_fotos))

        if reemplazar:
            reclamo_id = fresco["reclamo_id"]
            cur.execute(q.UPDATE_RECLAMO_SQL, (
                observaciones, reclamo_filename, reclamo_pdf_bytes, len(reclamo_pdf_bytes),
                reclamo_id,
            ))
            # Fotos: si esta edición trajo fotos nuevas se ANEXAN al documento
            # que ya tenía (antes lo REEMPLAZABAN y las anteriores se perdían
            # para siempre — incidente del pie 87 el 07/08: subieron las de la
            # lima y desaparecieron las de la papaya). Reemplazar es explícito.
            # Sin fotos nuevas el doc queda intacto, como siempre.
            if reclamo_fotos_pdf:
                fotos_final = reclamo_fotos_pdf
                if not body.reemplazar_fotos:
                    cur.execute(q.GET_RECLAMO_FOTOS_SQL, (reclamo_id,))
                    prev = cur.fetchone()
                    anterior = s3.read(prev["fotos_pdf_s3_key"], prev["fotos_pdf_blob"]) if prev else None
                    if anterior:
                        # merge_pdfs es best-effort: si el PDF viejo estuviera
                        # corrupto devuelve sólo la base — nunca pierde las nuevas.
                        fotos_final = merge_pdfs(anterior, reclamo_fotos_pdf)
                cur.execute(q.UPDATE_RECLAMO_FOTOS_SQL, (
                    fotos_final, len(fotos_final), reclamo_id,
                ))
                reclamo_fotos_pdf = fotos_final   # el offload a S3 sube el fusionado
            cur.execute(q.DELETE_RECLAMO_LINEAS_SQL, (reclamo_id,))
        else:
            # Si el pie ya se confirmó, el reclamo nace linkeado al movimiento de
            # Macrosoft (valores FRESCOS, no los de la lectura inicial); si sigue
            # pendiente queda NULL (lo setea el confirmar, como en el alta).
            cur.execute("""
                INSERT INTO ext.reclamo
                    (documento, nro_fact, generado_por_usuario_id, observaciones,
                     pdf_filename, pdf_blob, pdf_size_bytes, pie_camion_id,
                     fotos_pdf_blob, fotos_pdf_size_bytes)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                RETURNING id
            """, (fresco.get("ingreso_documento"), fresco.get("ingreso_nro_fact"), user.id,
                  observaciones, reclamo_filename, reclamo_pdf_bytes, len(reclamo_pdf_bytes), pdc_id,
                  reclamo_fotos_pdf, len(reclamo_fotos_pdf) if reclamo_fotos_pdf else None))
            reclamo_id = cur.fetchone()["id"]
            # Race-safe: si otro generó un reclamo en el medio, abortamos todo.
            cur.execute(
                "UPDATE ext.pie_de_camion SET reclamo_id = %s WHERE id = %s AND reclamo_id IS NULL",
                (reclamo_id, pdc_id),
            )
            if cur.rowcount != 1:
                raise HTTPException(409, "Este pie ya tiene un reclamo generado.")
        for d_rl in defectos_for_reclamo:
            cur.execute(rq.INSERT_RECLAMO_LINEA_SQL, (
                reclamo_id, d_rl["cod_art"], d_rl["descripcion"],
                d_rl["cantidad_defectuosa"], d_rl["motivo_id"], d_rl["notas"],
                len(d_rl["fotos"]),
            ))
        cur.execute("UPDATE ext.pie_de_camion SET hay_reclamos = TRUE WHERE id = %s", (pdc_id,))
        # …y la línea reclamada también: si el operario había declarado que ESA
        # fruta vino bien, el reclamo la desmiente (mig 0072).
        if nuevos_por_linea:
            cur.execute(
                "UPDATE ext.pie_de_camion_linea SET hay_reclamos = TRUE "
                "WHERE pie_camion_id = %s AND id = ANY(%s)",
                (pdc_id, list(nuevos_por_linea.keys())),
            )
        cur.execute(q.UPDATE_PDF_SQL, (informe_pdf, len(informe_pdf), pie["pdf_filename"], pdc_id))

    # Offload a S3 (best-effort, fuera de la tx).
    s3.offload_pdf("reclamo", reclamo_id, reclamo_pdf_bytes, "reclamos")
    if reclamo_fotos_pdf:
        s3.offload_pdf(
            "reclamo", reclamo_id, reclamo_fotos_pdf, "reclamos_fotos",
            blob_col="fotos_pdf_blob", s3_col="fotos_pdf_s3_key",
        )
    s3.offload_pdf("pie_de_camion", pdc_id, informe_pdf, "piedecamion")
    return {"reclamo_id": reclamo_id}


@router.post(
    "/{pdc_id}/reclamo",
    status_code=201,
    # Write iniciado desde Ingresos (stock); recepción también puede (es quien se
    # olvidó de marcar los defectos al cargar). `consulta` NO (solo lectura).
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion", "stock"))],
)
def crear_reclamo_pie(
    pdc_id: int,
    body: ReclamoPieCreate,
    user: CurrentUser = Depends(get_current_user),
):
    """Genera el reclamo al proveedor sobre un pie YA cargado — para cuando al que
    ingresó el pie se le pasó marcar los defectos. Solo pies SIN reclamo previo."""
    return _reclamo_pie(pdc_id, body, user, reemplazar=False)


@router.put(
    "/{pdc_id}/reclamo",
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion", "stock"))],
)
def editar_reclamo_pie(
    pdc_id: int,
    body: ReclamoPieCreate,
    user: CurrentUser = Depends(get_current_user),
):
    """RE-HACE el reclamo de un pie (por si se cargó mal): los defectos nuevos
    reemplazan a todos los anteriores y se re-generan el informe del reclamo y la
    planilla. El reclamo conserva su id y su link al movimiento (documento/nro_fact).
    Fotos: el doc de fotos guardado (fotos_pdf_*) se CONSERVA salvo que esta edición
    traiga fotos nuevas (en ese caso lo reemplazan). Reclamos viejos pre-0047 no
    tienen doc de fotos aparte → sus fotos viven en el PDF único y se pierden."""
    return _reclamo_pie(pdc_id, body, user, reemplazar=True)


@router.get("/{pdc_id}/pdf")
def download_pdf(pdc_id: int):
    row = fetch_one(q.GET_PDF_SQL, (pdc_id,))
    if not row:
        raise HTTPException(404, "Pie de camión no encontrado")
    # Desde S3 si ya se subió; si no, desde el blob (registros viejos / S3 off).
    data = s3.get(row["pdf_s3_key"]) if row.get("pdf_s3_key") else bytes(row["pdf_blob"])
    # Fotos: van en un PDF aparte que se fusiona DESPUÉS del informe de datos.
    # Los pies VIEJOS no tienen fotos_pdf (sus fotos están embebidas en el pdf_blob) →
    # el guard las deja pasar sin doble-render. Best-effort: si falla, sirve sin fotos.
    if row.get("fotos_pdf_s3_key") or row.get("fotos_pdf_blob"):
        try:
            fotos = (
                s3.get(row["fotos_pdf_s3_key"])
                if row.get("fotos_pdf_s3_key")
                else bytes(row["fotos_pdf_blob"])
            )
            data = merge_pdfs(data, fotos)
        except Exception as e:
            logger.warning(f"no pude traer el fotos-PDF del pie {pdc_id}, sirvo sin fotos: {e}")
    # Si el pie tiene PDF de termógrafo, lo fusionamos al final (informe todo junto).
    # TODO best-effort: si la BAJADA del termógrafo (S3) o el merge fallan, servimos
    # la planilla sola — NUNCA rompemos la descarga del informe (Ingresos lo necesita).
    if row.get("termografo_pdf_s3_key") or row.get("termografo_pdf_blob"):
        try:
            term = (
                s3.get(row["termografo_pdf_s3_key"])
                if row.get("termografo_pdf_s3_key")
                else bytes(row["termografo_pdf_blob"])
            )
            data = merge_pdfs(data, term)
        except Exception as e:
            logger.warning(f"no pude traer el termógrafo del pie {pdc_id}, sirvo la planilla: {e}")
    return Response(
        content=data,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="{row["pdf_filename"]}"'},
    )


@router.post(
    "/{pdc_id}/termografo-pdf",
    response_model=PieDeCamionListItem,
    # Se hace en una compu desde el Historial: equipo de recepción / stock.
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion", "stock"))],
)
def subir_termografo_pdf(pdc_id: int, body: TermografoPdfUpload):
    """Adjunta el PDF del termógrafo (cadena de frío) al pie. Se guarda aparte; el
    download del informe (`/pdf`) lo fusiona con la planilla. Re-subir reemplaza."""
    if not fetch_one("SELECT 1 FROM ext.pie_de_camion WHERE id = %s", (pdc_id,)):
        raise HTTPException(404, "Pie de camión no encontrado")
    try:
        blob = _decode_image_data_uri(body.pdf)   # genérico: data URI o base64 puro
    except Exception:
        raise HTTPException(400, "No se pudo leer el PDF del termógrafo.")
    if blob[:4] != b"%PDF":
        raise HTTPException(400, "El archivo no es un PDF válido.")
    if len(blob) > 15 * 1024 * 1024:
        raise HTTPException(400, "El PDF del termógrafo es demasiado grande.")
    # Verificar que se pueda LEER (y por ende fusionar): así el "Termógrafo ✓" no
    # miente — sólo aceptamos PDFs que después el informe va a poder fusionar.
    try:
        from pypdf import PdfReader

        if not PdfReader(BytesIO(blob)).pages:
            raise ValueError("PDF sin páginas")
    except Exception:
        raise HTTPException(400, "El PDF del termógrafo no se pudo leer. Volvé a exportarlo del aparato.")
    filename = ((body.filename or f"termografo-{pdc_id}.pdf").strip() or f"termografo-{pdc_id}.pdf")[:200]
    with get_cursor() as cur:
        cur.execute(q.UPDATE_TERMOGRAFO_PDF_SQL, (blob, len(blob), filename, pdc_id))
    s3.offload_pdf(
        "pie_de_camion", pdc_id, blob, "piedecamion_termografo",
        blob_col="termografo_pdf_blob", s3_col="termografo_pdf_s3_key",
    )
    return _list_item(fetch_one(q.GET_ONE_ITEM_SQL, (pdc_id,)))


@router.delete(
    "/{pdc_id}/termografo-pdf",
    response_model=PieDeCamionListItem,
    dependencies=[Depends(require_any_permission("pie_camion", "recepcion", "stock"))],
)
def borrar_termografo_pdf(pdc_id: int):
    """Borra el termógrafo adjunto (si lo subieron mal). Limpia el registro y borra
    el objeto de S3 (best-effort). La planilla base no se toca: el informe (`/pdf`)
    vuelve a servirse solo. Idempotente: si no había termógrafo, no falla."""
    row = fetch_one(q.GET_TERMOGRAFO_PDF_SQL, (pdc_id,))
    if not row:
        raise HTTPException(404, "Pie de camión no encontrado")
    s3_key = row.get("termografo_pdf_s3_key")
    with get_cursor() as cur:
        cur.execute(q.CLEAR_TERMOGRAFO_PDF_SQL, (pdc_id,))
    # Borrar el objeto de S3 recién DESPUÉS de limpiar la DB (best-effort: si S3
    # falla, el registro ya quedó sin referencia → el objeto queda huérfano pero
    # inofensivo, y NUNCA rompemos el borrado desde la vista del usuario).
    if s3_key:
        try:
            s3.delete(s3_key)
        except Exception as e:
            logger.warning(f"no pude borrar el termógrafo del pie {pdc_id} de S3 ({s3_key}): {e}")
    return _list_item(fetch_one(q.GET_ONE_ITEM_SQL, (pdc_id,)))


@router.get("/{pdc_id}/termografo-pdf")
def download_termografo_pdf(pdc_id: int):
    """PDF del termógrafo SOLO (para previsualizar cuál se adjuntó). En el informe
    (`/pdf`) va fusionado con la planilla; acá se sirve suelto. 404 si no tiene."""
    row = fetch_one(q.GET_TERMOGRAFO_PDF_SQL, (pdc_id,))
    if not row or (not row.get("termografo_pdf_s3_key") and not row.get("termografo_pdf_blob")):
        raise HTTPException(404, "Este pie de camión no tiene termógrafo")
    data = s3.get(row["termografo_pdf_s3_key"]) if row.get("termografo_pdf_s3_key") else bytes(row["termografo_pdf_blob"])
    return Response(
        content=data,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="{row["termografo_pdf_filename"]}"'},
    )


@router.get("/{pdc_id}/documentacion-pdf")
def download_documentacion_pdf(pdc_id: int):
    """PDF de la documentación escaneada (aparte de la planilla). 404 si el pie no
    tiene documentación cargada."""
    row = fetch_one(q.GET_DOC_PDF_SQL, (pdc_id,))
    if not row or (not row.get("doc_pdf_s3_key") and not row.get("doc_pdf_blob")):
        raise HTTPException(404, "Este pie de camión no tiene documentación")
    data = s3.get(row["doc_pdf_s3_key"]) if row.get("doc_pdf_s3_key") else bytes(row["doc_pdf_blob"])
    return Response(
        content=data,
        media_type="application/pdf",
        headers={"Content-Disposition": f'inline; filename="{row["doc_pdf_filename"]}"'},
    )


# El documento de ingreso lo decide el DEPÓSITO del pie (relevado 21/08 en el
# libro real): descarga de importación en ZAC = 402, en CR = 181. El 400 NO es
# de camiones — es la pata ZAC de un "viaje" CR→ZAC (par 190+400) y lo carga
# otro flujo. El Puesto (A) no tiene documento de importación.
DOC_POR_DEPOSITO = {"B": "402", "C": "181"}


@router.post(
    "/{pdc_id}/confirmar",
    response_model=PieDeCamionListItem,
    # ESCRIBE en el Macrosoft real → permiso propio (lo da el dueño a mano);
    # `stock`/`pie_camion` solas ya no alcanzan.
    dependencies=[Depends(require_permission("ingreso_macrosoft"))],
)
def confirmar_ingreso(
    pdc_id: int,
    body: ConfirmarIngresoRequest,
    background_tasks: BackgroundTasks,
    user: CurrentUser = Depends(get_current_user),
):
    """El back-office confirma un pie de camión: crea el Cabezal+Lineas en
    Macrosoft (402 en ZAC / 181 en CR, con el costo de la Lista de Costo,
    igual que el formulario de Macrosoft) y marca el pie como ingresado."""
    # Apagado POR AHORA: no se ingresa stock a Macrosoft (sólo ver planilla y
    # reclamos). Guard server-side para que no sea bypasseable por API.
    if not settings.ingresos_a_macrosoft_habilitado:
        raise HTTPException(409, "Los ingresos a Macrosoft están deshabilitados por ahora.")
    if not settings.cfe_escribe_macrosoft_real:
        # Sin CFE_MSSQL_* la conexión caería al espejo/sumidero: jamás escribir ahí.
        raise HTTPException(
            403,
            "En este ambiente no hay Macrosoft conectado — no se pueden registrar "
            "ingresos (es solo prueba de la pantalla).",
        )
    # Validar estado y traer lineas
    row = fetch_one(q.build_get_detail_sql(), (pdc_id,))
    if not row:
        raise HTTPException(404, "Pie de camión no encontrado")
    if row.get("estado") != "pendiente":
        raise HTTPException(400, f"Pie de camión está {row.get('estado')}, no se puede confirmar de nuevo")

    lineas = fetch_all(q.GET_LINEAS_SQL, (pdc_id,))
    if not lineas:
        raise HTTPException(400, "El pie de camión no tiene líneas — nada que ingresar")

    depositos = {(l["deposito"] or "").strip() for l in lineas}
    if len(depositos) > 1:
        raise HTTPException(
            400,
            f"El pie tiene líneas en más de un depósito ({', '.join(sorted(depositos))}) "
            "— un ingreso es de UN depósito; corregí las líneas antes de confirmar.",
        )
    deposito = depositos.pop()
    documento = DOC_POR_DEPOSITO.get(deposito)
    if not documento:
        raise HTTPException(
            400,
            f"El depósito '{deposito}' no tiene documento de ingreso de importación "
            "(sólo B — ZAC → 402 y C — CR → 181).",
        )
    # Compat: si el cliente todavía manda `documento`, tiene que coincidir con
    # el derivado — un mismatch es señal de front viejo o de un pie mal cargado.
    if body.documento and body.documento != documento:
        raise HTTPException(
            400,
            f"El depósito {deposito} ingresa con documento {documento}, no {body.documento}.",
        )

    doc_padded = f"{documento:<4}"
    # La fecha del INGRESO es HOY, siempre (dueño 1/09). Los camiones se ingresan
    # al momento de descargarlos, nunca días después, así que el movimiento de
    # stock va al día en que se hace.
    #
    # Antes salía del campo `fecha` del pie, y eso lo volvía tipeable: el 1/09 un
    # pie se cargó con la fecha PLANIFICADA de la carpeta (29/08) y el ingreso
    # quedó imputado tres días atrás — el stock total daba bien, pero el
    # movimiento caía en un período ya cerrado y ensuciaba la conciliación.
    fecha_dt = datetime.combine(datetime.now(_UY).date(), datetime.min.time())
    # Mismos textos que los documentos que el back-office carga a mano: el
    # Nombre agrupa en su pantalla y las Observaciones llevan la identidad del
    # camión (así la conciliación por AFIDI/placa/código sigue funcionando).
    nombre_doc = "INGRESOS DE STOCK"
    partes_obs = [
        f"AFIDI {row['numero_afidi']}" if row.get("numero_afidi") else None,
        (row.get("exportador") or "").strip() or None,
        (row.get("codigo_importador_camion") or "").strip() or None,
        (row.get("placa_camion") or "").strip() or None,
        f"Pie #{pdc_id}",
    ]
    obs = " ".join(p for p in partes_obs if p)[:200]

    # 0) RESERVA en PG (mig 0112) — antes de tocar Macrosoft, porque son dos
    #    bases sin transacción común. El chequeo de estado de más arriba NO
    #    alcanza: entre ese SELECT y esta escritura entran dos requests (dos
    #    clicks, dos pestañas, el reintento del navegador) y los DOS crearían su
    #    documento. Acá el segundo no saca fila y corta sin haber escrito nada.
    with get_cursor() as cur:
        cur.execute(q.RESERVAR_CONFIRMACION_SQL, (user.id, pdc_id))
        if cur.fetchone() is None:
            raise HTTPException(
                409,
                "Este pie ya se está confirmando (o ya se confirmó). Si te dio error "
                "antes, NO reintentes: fijate en Macrosoft si el ingreso se creó.",
            )

    # 1) Macrosoft (SQL Server, conexión CFE): crear el movimiento real.
    #    Si esto falla, Macrosoft no commiteó nada → se libera la reserva para
    #    que el reintento pueda entrar. Si commiteó y falla después, la reserva
    #    QUEDA puesta a propósito: es la marca de que hay un documento dando
    #    vueltas y de que el pie no se puede reintentar a ciegas.
    try:
        with get_cfe_cursor() as cur:
            # Next NroFact y NroDoc
            cur.execute(stock_q.NEXT_NRO_FACT_SQL)
            nro_fact = cur.fetchone()["next_nro"]
            # NroDoc sale del contador oficial de Documentos, que se actualiza al
            # final de esta misma transacción (ver stock/queries.py).
            cur.execute(stock_q.GET_NRO_DOC_SQL, (documento, documento))
            fila_nro = cur.fetchone()
            if not fila_nro:
                raise HTTPException(400, f"El documento {documento} no existe en Macrosoft")
            nro_doc_int = int(fila_nro["ultimo_usado"] or 0) + 1
            nro_doc = str(nro_doc_int)

            # Insert Cabezal
            cur.execute(stock_q.INSERT_CABEZAL_INGRESO_SQL, (
                fecha_dt, doc_padded, nro_fact, nro_doc, nombre_doc, obs,
            ))

            # Insert lineas en Macrosoft, con el costo de la Lista de Costo (la
            # misma regla que el formulario de Macrosoft; sin costo cargado → 0).
            for l in lineas:
                cur.execute(stock_q.PRECIO_LISTA_COSTO_SQL, (l["cod_art"].strip(),))
                fila_precio = cur.fetchone()
                precio = float(fila_precio["Precio"]) if fila_precio and fila_precio.get("Precio") else 0.0
                cantidad = float(l["cantidad"])
                cur.execute(stock_q.INSERT_LINEA_INGRESO_SQL, (
                    fecha_dt, doc_padded, nro_fact, nro_doc,
                    l["deposito"], l["cod_art"], l["descripcion"],
                    cantidad,                   # CantidadDebe
                    0,                          # CantidadHaber
                    precio,                     # Precio (Lista de Costo)
                    round(cantidad * precio, 2),  # TotalLinea
                    "A",
                ))

            # Dejar el contador de Macrosoft donde corresponde (ver stock/router.py).
            cur.execute(stock_q.UPDATE_NRO_DOC_SQL, (nro_doc_int, documento))

    except Exception:
        # Macrosoft NO commiteó → liberar la reserva para que el reintento
        # entre. Si hubiera commiteado no pasaríamos por acá.
        try:
            with get_cursor() as cur:
                cur.execute(q.LIBERAR_CONFIRMACION_SQL, (pdc_id,))
        except Exception:
            logger.warning("no pude liberar la reserva del pie %s", pdc_id, exc_info=True)
        raise

    # Dual-write del ingreso a legacy.* para que la lista de stock lo vea ya.
    dual_write_ingreso_to_legacy(doc_padded, nro_fact)

    # 2) Postgres: metadata + estado del pie + link del reclamo.
    #    Si esto falla después de que Macrosoft commiteó, el pie queda
    #    'pendiente' con un ingreso ya creado — NO reintentar confirmar:
    #    revisar el ingreso en Macrosoft y marcar el pie a mano.
    with get_cursor() as cur:
        cur.execute(q.INSERT_META_SQL, (documento, nro_fact, user.id))
        cur.execute(q.CONFIRMAR_INGRESO_SQL, (documento, nro_fact, user.id, pdc_id))
        if cur.rowcount != 1:
            # No debería pasar (la reserva ya nos hizo dueños del pie), pero si
            # pasa hay un documento en Macrosoft sin pie cerrado: que quede en
            # el log con el número, que es lo que se necesita para arreglarlo.
            logger.error(
                "pie %s: el ingreso %s #%s quedó creado en Macrosoft pero el pie no cerró",
                pdc_id, documento, nro_fact,
            )
        # Siempre (no solo si `row` traía reclamo_id): un reclamo post-hoc pudo
        # commitear después de nuestra lectura del pie. No-op si no hay reclamo.
        cur.execute(q.UPDATE_RECLAMO_INGRESO_SQL, (documento, nro_fact, pdc_id))

    # Reenviar a los dashboards con estado 'ingresado' (idempotente del lado del
    # compañero → sólo actualiza el estado). Best-effort, después de la respuesta.
    background_tasks.add_task(webhook.enviar_ingresado, pdc_id)

    fresh = fetch_one(q.GET_ONE_ITEM_SQL, (pdc_id,))
    return _list_item(fresh)
