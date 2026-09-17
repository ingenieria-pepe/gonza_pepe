"""
Router de Plan de Cargas + Monitor de Camiones.

Dos endpoints públicos (autenticados):
  - /plan-cargas/...    → CRUD del plan (requiere permiso `plan_cargas`)
  - /monitor-camiones   → lectura del dashboard (requiere `monitor_camiones`)

La data vive en PostgreSQL: `ext.plan_de_cargas` (pg_migrations 0001).
"""
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from psycopg2 import errors as pg_errors
from psycopg2.extras import Json

from app.core.deps import CurrentUser, get_current_user, require_any_permission, require_permission
from app.core.kiosk import kiosk_gate
from app.pg import fetch_all, fetch_one, get_cursor
from app.modules.plan_cargas import onedrive_sync as sync
from app.modules.plan_cargas import queries as q
from app.modules.plan_cargas.schemas import (
    CarpetaImportCreate,
    CarpetaImportUpdate,
    PlanCargaCreate,
    PlanCargaOut,
    PlanCargaUpdate,
    STATUS_PENDIENTES,
)

router = APIRouter(prefix="/plan-cargas", tags=["plan_cargas"])
monitor_router = APIRouter(prefix="/monitor-camiones", tags=["monitor_camiones"])


# ─── Puente OneDrive (read-only, temporal) ───────────────────────────────
# Mientras el puente esté activo, el maestro es el Excel: la edición del plan en
# Aloha se bloquea (se pisaría en el próximo sync). Vaciar la URL = cutover.
def _no_en_puente():
    if sync.activo():
        raise HTTPException(
            409,
            "Plan de Cargas está en modo lectura: se sincroniza del Excel. "
            "La edición en Aloha se habilita en el cutover.",
        )


# Lectura amplia: las pantallas que pollean (plan/monitor/pie de camión) pueden
# disparar el sync (es un refresh del espejo desde la fuente, no dato de usuario).
_VER_SYNC = [Depends(require_any_permission("plan_cargas", "monitor_camiones", "pie_camion", "recepcion"))]


@router.get("/sync/estado", dependencies=_VER_SYNC)
def sync_estado():
    return sync.estado()


@router.post("/sync", dependencies=_VER_SYNC)
def sync_now(force: bool = Query(False, description="Forzar bajada aunque no haya cambios")):
    return sync.sincronizar(force=force)


# ─── Helpers ─────────────────────────────────────────────────────────────


def _row_to_out(row: dict) -> PlanCargaOut:
    data = {c: row.get(c) for c in q.DATA_COLUMNS}
    return PlanCargaOut(
        id=row["id"],
        creado_en=row["creado_en"],
        actualizado_en=row["actualizado_en"],
        creado_por_usuario=row.get("creado_por_nombre") or row.get("creado_por_username"),
        actualizado_por_usuario=row.get("actualizado_por_nombre") or row.get("actualizado_por_username"),
        **data,
    )


# ─── /plan-cargas (CRUD) ─────────────────────────────────────────────────


@router.get(
    "",
    response_model=list[PlanCargaOut],
    # Lectura amplia: el picker de Pie de Camión lista las cargas del plan, así que
    # un rol que sólo tenga `pie_camion` (o `recepcion`) también tiene que leerlas.
    dependencies=[Depends(require_any_permission("plan_cargas", "pie_camion", "recepcion"))],
)
def list_plan_cargas(
    status: str | None = Query(None, description="Filtrar por status exacto"),
    productor: str | None = Query(None, description="Match parcial (LIKE) en productor"),
    frontera: str | None = Query(None, description="Match exacto en frontera"),
    fuente: str | None = Query(None, description="'BR' (Brasil/PY) | 'OTROS' (demás países); None = todas"),
    pendientes: bool = Query(False, description="Si true, sólo los estados no-terminados"),
    limit: int = Query(500, ge=1, le=5000),
):
    """Lista del plan completo con filtros opcionales."""
    where_parts: list[str] = []
    params: list = []

    if status:
        where_parts.append("p.status = %s")
        params.append(status)
    if fuente:
        where_parts.append("p.fuente = %s")
        params.append(fuente)
    if productor:
        # ILIKE: en SQL Server LIKE era case-insensitive (collation CI);
        # en PG hay que pedirlo explícito.
        where_parts.append("p.productor ILIKE %s")
        params.append(f"%{productor.strip()}%")
    if frontera:
        where_parts.append("p.frontera = %s")
        params.append(frontera)
    if pendientes:
        # Pythonic IN — usamos placeholders fijos
        placeholders = ", ".join(["%s"] * len(STATUS_PENDIENTES))
        where_parts.append(f"p.status IN ({placeholders})")
        params.extend(STATUS_PENDIENTES)

    sql = q.LIST_SQL.replace(
        "/* filtros se insertan acá */",
        " ".join(f"AND {w}" for w in where_parts),
    )
    # Tope para no traer 2500 filas si no hace falta
    sql = sql + f"\nLIMIT {limit}"

    rows = fetch_all(sql, tuple(params))
    return [_row_to_out(r) for r in rows]


# Carpetas de importación con saldos (ANTES de /{plan_id} para no matchear ahí).
@router.get("/carpetas", dependencies=[Depends(require_permission("plan_cargas"))])
def listar_carpetas():
    """Control de carpetas: cargado/saldo calculados en vivo desde el plan de
    cargas (suma de cajas por factura). Misma lógica que el Excel viejo."""
    return fetch_all(q.CARPETAS_SQL)


@router.post("/carpetas", status_code=201, dependencies=[Depends(require_permission("plan_cargas"))])
def crear_carpeta(body: CarpetaImportCreate):
    """Alta de carpeta de importación. cargado/saldo NO se guardan: se calculan
    en vivo (la carpeta arranca con cargado=0 hasta que se le asignen camiones)."""
    data = body.model_dump()
    values = [data[c] for c in q.CARPETA_COLS]
    with get_cursor() as cur:
        cur.execute(q.build_carpeta_insert_sql(), tuple(values))
        new_id = cur.fetchone()["id"]
    return fetch_one(q.CARPETA_ONE_SQL, (new_id,))


@router.patch("/carpetas/{carpeta_id}", dependencies=[Depends(require_permission("plan_cargas"))])
def editar_carpeta(carpeta_id: int, body: CarpetaImportUpdate):
    """Edición parcial de una carpeta."""
    changes = body.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(400, "Mandá al menos un campo a actualizar")
    cols = list(changes.keys())
    values = list(changes.values()) + [carpeta_id]
    with get_cursor() as cur:
        cur.execute(q.build_carpeta_update_sql(cols), tuple(values))
    row = fetch_one(q.CARPETA_ONE_SQL, (carpeta_id,))
    if not row:
        raise HTTPException(404, "Carpeta no encontrada")
    return row


@router.delete("/carpetas/{carpeta_id}", status_code=204, dependencies=[Depends(require_permission("plan_cargas"))])
def borrar_carpeta(carpeta_id: int):
    """Borra una carpeta de importación. No afecta al plan de cargas (el saldo
    sólo existía como referencia contra la carpeta)."""
    with get_cursor() as cur:
        cur.execute(q.CARPETA_DELETE_SQL, (carpeta_id,))


@router.get("/factura-datos", dependencies=[Depends(require_permission("plan_cargas"))])
def factura_datos(factura: str = Query(..., min_length=1)):
    """Datos que se repiten para una misma factura (carpeta/exportador/frontera/
    transportista/afidi) para autollenar el form. NO trae productor (eso cambia
    por carga). Busca en carpetas; si no está, en la última carga del plan."""
    f = factura.strip()
    return fetch_one(q.FACTURA_DATOS_CARPETA_SQL, (f,)) or fetch_one(q.FACTURA_DATOS_PLAN_SQL, (f,)) or {}


@router.get("/facturas", dependencies=[Depends(require_permission("plan_cargas"))])
def listar_facturas():
    """Facturas conocidas (carpetas + plan) para el combobox del form."""
    return [r["factura"] for r in fetch_all(q.FACTURAS_SQL)]


# OJO: declarado ANTES de /{plan_id} para que "export.xlsx" no matchee ahí.
@router.get(
    "/export.xlsx",
    dependencies=[Depends(require_permission("plan_cargas"))],
)
def export_excel(
    pendientes: bool = Query(False, description="Si true, sólo los estados no-terminados"),
    fuente: str | None = Query(None, description="'BR' | 'OTROS'; None = todas"),
):
    """Exporta el plan completo a un .xlsx con autofiltro y encabezado fijo —
    la misma vista que la planilla vieja de OneDrive, para quien la prefiera."""
    from datetime import date as _date
    from io import BytesIO

    from fastapi import Response as FastAPIResponse
    from openpyxl import Workbook
    from openpyxl.styles import Alignment, Font, PatternFill
    from openpyxl.utils import get_column_letter

    where = ""
    params: tuple = ()
    if pendientes:
        placeholders = ", ".join(["%s"] * len(STATUS_PENDIENTES))
        where = f"AND p.status IN ({placeholders})"
        params = tuple(STATUS_PENDIENTES)
    if fuente:
        where += " AND p.fuente = %s"
        params = params + (fuente,)
    sql = q.LIST_SQL.replace("/* filtros se insertan acá */", where)
    rows = fetch_all(sql, params)

    # (label, key, width, formato)
    COLS = [
        ("Semana", "carga_semana", 9, None),
        ("Status", "status", 12, None),
        ("Factura", "factura", 10, None),
        ("Productor", "productor", 18, None),
        ("País", "pais_origen", 7, None),
        ("Fecha carga", "fecha_carga", 12, "DD/MM/YYYY"),
        ("Carpeta", "carpeta_import", 10, None),
        ("AFIDI", "afidi", 14, None),
        ("Transportista", "transportista", 18, None),
        ("Exportador", "exportador", 18, None),
        ("Placa camión", "placa_camion", 12, None),
        ("Placa remolque", "placa_remolque", 13, None),
        ("Chofer", "chofer", 16, None),
        ("Celular", "celular", 14, None),
        ("Fecha frontera", "fecha_frontera", 12, "DD/MM/YYYY"),
        ("Frontera", "frontera", 11, None),
        ("Inspector MGAP", "inspector_mgap", 16, None),
        ("Fecha descarga", "fecha_descarga", 12, "DD/MM/YYYY"),
        ("TT", "tt", 6, None),
        ("Cajas MIC", "cajas_mic", 9, None),
        ("Cajas desc.", "cajas_desc", 9, None),
        ("Pallets", "cant_pallet", 8, None),
        ("Kg/caja", "cant_kilos_caja", 8, None),
        ("Código viaje", "codigo_viaje", 11, None),
        ("MIC", "mic", 12, None),
        ("Observaciones", "observaciones", 40, None),
    ]

    wb = Workbook()
    ws = wb.active
    ws.title = "Plan de cargas"

    header_font = Font(bold=True, color="FFFFFF")
    header_fill = PatternFill("solid", fgColor="1E3A8A")  # azul Pepe oscuro
    for i, (label, _, width, _fmt) in enumerate(COLS, start=1):
        cell = ws.cell(row=1, column=i, value=label)
        cell.font = header_font
        cell.fill = header_fill
        cell.alignment = Alignment(vertical="center")
        ws.column_dimensions[get_column_letter(i)].width = width

    for r, row in enumerate(rows, start=2):
        for i, (_, key, _w, fmt) in enumerate(COLS, start=1):
            cell = ws.cell(row=r, column=i, value=row.get(key))
            if fmt:
                cell.number_format = fmt

    ws.freeze_panes = "A2"
    ws.auto_filter.ref = f"A1:{get_column_letter(len(COLS))}{max(len(rows) + 1, 2)}"

    bio = BytesIO()
    wb.save(bio)
    filename = f"plan-cargas-{_date.today().isoformat()}.xlsx"
    return FastAPIResponse(
        content=bio.getvalue(),
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get(
    "/{plan_id}",
    response_model=PlanCargaOut,
    dependencies=[Depends(require_permission("plan_cargas"))],
)
def get_plan_carga(plan_id: int):
    row = fetch_one(q.build_get_by_id_sql(), (plan_id,))
    if not row:
        raise HTTPException(404, "Carga no encontrada")
    return _row_to_out(row)


@router.post(
    "",
    response_model=PlanCargaOut,
    status_code=201,
    dependencies=[Depends(require_permission("plan_cargas")), Depends(_no_en_puente)],
)
def create_plan_carga(body: PlanCargaCreate, user: CurrentUser = Depends(get_current_user)):
    data = body.model_dump()
    values = [Json(data.get(c)) if c == "productos" else data.get(c) for c in q.DATA_COLUMNS] + [user.id, user.id]

    with get_cursor() as cur:
        cur.execute(q.build_insert_sql(), tuple(values))
        new_id = cur.fetchone()["id"]

    row = fetch_one(q.build_get_by_id_sql(), (new_id,))
    return _row_to_out(row)


@router.patch(
    "/{plan_id}",
    response_model=PlanCargaOut,
    dependencies=[Depends(require_permission("plan_cargas")), Depends(_no_en_puente)],
)
def update_plan_carga(
    plan_id: int,
    body: PlanCargaUpdate,
    user: CurrentUser = Depends(get_current_user),
):
    changes = body.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(400, "Mandá al menos un campo a actualizar")

    cols = list(changes.keys())
    values = [Json(v) if k == "productos" else v for k, v in changes.items()] + [user.id, plan_id]
    with get_cursor() as cur:
        cur.execute(q.build_update_sql(cols), tuple(values))

    row = fetch_one(q.build_get_by_id_sql(), (plan_id,))
    if not row:
        raise HTTPException(404, "Carga no encontrada")
    return _row_to_out(row)


@router.delete(
    "/{plan_id}",
    status_code=204,
    dependencies=[Depends(require_permission("plan_cargas")), Depends(_no_en_puente)],
)
def cancel_plan_carga(
    plan_id: int,
    definitivo: bool = Query(False, description="true = borra la fila; false = sólo cancela"),
    user: CurrentUser = Depends(get_current_user),
):
    """definitivo=false (default): soft-delete → estado Cancelado (mantiene
    historial). definitivo=true: BORRA la fila (con confirmación en el front).
    Si la carga está vinculada a un Pie de Camión no se puede borrar (FK)."""
    with get_cursor() as cur:
        if definitivo:
            try:
                cur.execute(q.DELETE_SQL, (plan_id,))
            except pg_errors.ForeignKeyViolation:
                raise HTTPException(409, "No se puede eliminar: la carga está vinculada a un Pie de Camión. Cancelala en su lugar.")
        else:
            cur.execute(q.CANCEL_SQL, (user.id, plan_id))


# ─── /monitor-camiones (lectura) ─────────────────────────────────────────


@monitor_router.get("", response_model=list[PlanCargaOut])
def monitor_camiones(request: Request):
    """Sólo los camiones que NO terminaron — los que van a llegar / están en
    tránsito. Pensado para mostrar en una pantalla del depósito.

    Acceso: token de kiosko (?k=, las teles) o IP conocida → sin login; si no,
    sesión iniciada. Igual que el Monitor de Entregas. La visibilidad del módulo
    para usuarios logueados la maneja el permiso `monitor_camiones` en el front.

    Ordenado por estado (Arribado→Solicitado) y después por fecha estimada
    de descarga (o de frontera si no hay descarga estimada).
    """
    kiosk_gate(request)
    rows = fetch_all(q.MONITOR_SQL)
    return [_row_to_out(r) for r in rows]
