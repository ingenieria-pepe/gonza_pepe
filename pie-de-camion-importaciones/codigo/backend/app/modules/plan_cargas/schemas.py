"""
Schemas Pydantic para Plan de Cargas y Monitor de Camiones.

Mismo dataset (tabla PlanDeCargas). Los endpoints `monitor` son una vista
filtrada (sólo camiones que no terminaron — sirven para una pantalla pública).
"""
from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field

# Valores que vienen de los Excel originales. Si en el futuro aparecen más, los
# agregamos acá. NO usamos CHECK constraint en SQL para no rompernos la cabeza
# en cada nuevo estado — la validación la hace Pydantic.
# 'Cargado'/'Puerto'/'Mar'/'Destruida' vienen de la planilla de OTROS países
# (lo de ultramar viaja en barco). Sincronizar con VALID_STATUS del importador
# (app/scripts/import_plan_cargas.py) y con el front (shared/api/planCargas.ts).
StatusCarga = Literal[
    "Solicitado",   # pedida al productor, sin confirmar carga
    "Confirmado",   # productor confirmó que va a salir
    "Cargado",      # cargó en origen (planilla OTROS)
    "Mar",          # navegando (ultramar, planilla OTROS)
    "Puerto",       # llegó a puerto (ultramar, planilla OTROS)
    "Frontera",     # llegó a la frontera, en trámite
    "Liberado",     # salió de la frontera, en camino al depósito
    "Arribado",     # llegó al depósito, esperando descarga
    "Descargado",   # ya se descargó
    "Cancelado",    # se canceló (no llega)
    "Destruida",    # la carga se destruyó (planilla OTROS; terminal)
]

# De qué planilla viene cada fila (el sync reemplaza SOLO su fuente):
#   'BR' = Brasil/Paraguay (la histórica) · 'OTROS' = demás países.
FuenteCarga = Literal["BR", "OTROS"]

# Lo que el Monitor muestra: SOLO Frontera y Liberado (los que están por
# llegar inmediatamente). Solicitado/Confirmado/Mar son demasiado prematuros y
# Arribado/Descargado ya están en el depósito. (Misma regla para ambas fuentes.)
STATUS_MONITOR: tuple[StatusCarga, ...] = ("Frontera", "Liberado")

# Para el "filtro pendientes" en el plan-cargas: todos los no-terminados.
STATUS_PENDIENTES: tuple[StatusCarga, ...] = (
    "Solicitado", "Confirmado", "Cargado", "Mar", "Puerto", "Frontera", "Liberado", "Arribado"
)


class ProductoCarga(BaseModel):
    """Un producto de la carga (un camión puede traer varios)."""
    descripcion: str = Field(..., max_length=200)
    icono: str | None = Field(default=None, max_length=60)
    # Código de artículo (lo setea el picker). Permite que Pie de Camión arme la
    # línea de mercadería directo, sin re-buscar el artículo. Los productos
    # importados del Drive (texto libre) no lo tienen → Pie de Camión cae a
    # buscar por descripción.
    cod_art: str | None = Field(default=None, max_length=30)


class PlanCargaBase(BaseModel):
    """Campos comunes — usado por Create y Out."""

    carga_semana: str | None = Field(default=None, max_length=20)
    status: StatusCarga = "Solicitado"
    factura: str | None = Field(default=None, max_length=30)
    productor: str | None = Field(default=None, max_length=100)
    fecha_carga: date | None = None
    carpeta_import: str | None = Field(default=None, max_length=40)
    afidi: str | None = Field(default=None, max_length=300)

    transportista: str | None = Field(default=None, max_length=100)
    exportador: str | None = Field(default=None, max_length=150)
    placa_camion: str | None = Field(default=None, max_length=30)
    placa_remolque: str | None = Field(default=None, max_length=30)
    chofer: str | None = Field(default=None, max_length=100)
    celular: str | None = Field(default=None, max_length=40)

    fecha_frontera: date | None = None
    frontera: str | None = Field(default=None, max_length=50)
    inspector_mgap: str | None = Field(default=None, max_length=100)
    fecha_descarga: date | None = None

    tt: int | None = None
    cajas_mic: int | None = Field(default=None, ge=0)
    cajas_desc: int | None = Field(default=None, ge=0)
    cant_pallet: int | None = Field(default=None, ge=0)
    cant_kilos_caja: float | None = Field(default=None, ge=0)
    codigo_viaje: str | None = Field(default=None, max_length=40)
    mic: str | None = Field(default=None, max_length=40)

    observaciones: str | None = Field(default=None, max_length=2000)

    productos: list[ProductoCarga] = Field(default_factory=list)
    pais_origen: str | None = Field(default=None, max_length=60)
    fuente: FuenteCarga = "BR"


class PlanCargaCreate(PlanCargaBase):
    """Body del POST."""
    pass


class PlanCargaUpdate(BaseModel):
    """Body del PATCH — todo opcional, los None NO se aplican (los descartamos
    explícitamente en el router con exclude_unset)."""

    carga_semana: str | None = None
    status: StatusCarga | None = None
    factura: str | None = None
    productor: str | None = None
    fecha_carga: date | None = None
    carpeta_import: str | None = None
    afidi: str | None = None

    transportista: str | None = None
    exportador: str | None = None
    placa_camion: str | None = None
    placa_remolque: str | None = None
    chofer: str | None = None
    celular: str | None = None

    fecha_frontera: date | None = None
    frontera: str | None = None
    inspector_mgap: str | None = None
    fecha_descarga: date | None = None

    tt: int | None = None
    cajas_mic: int | None = None
    cajas_desc: int | None = None
    cant_pallet: int | None = None
    cant_kilos_caja: float | None = None
    codigo_viaje: str | None = None
    mic: str | None = None
    observaciones: str | None = None
    productos: list[ProductoCarga] | None = None
    pais_origen: str | None = None


class PlanCargaOut(PlanCargaBase):
    id: int
    creado_en: datetime
    actualizado_en: datetime
    creado_por_usuario: str | None = None
    actualizado_por_usuario: str | None = None


# ─── Carpetas de importación ──────────────────────────────────────────────
# El "control de carpetas" del Excel viejo. cargado/saldo NO se editan: se
# calculan en vivo (suma de cajas del plan por factura) — ver CARPETAS_SQL.


class CarpetaImportBase(BaseModel):
    fecha: date | None = None
    factura: str | None = Field(default=None, max_length=40)
    carpeta: str | None = Field(default=None, max_length=40)
    exportador: str | None = Field(default=None, max_length=150)
    frontera: str | None = Field(default=None, max_length=60)
    transportista: str | None = Field(default=None, max_length=100)
    cantidad: int | None = Field(default=None, ge=0)
    afidi: str | None = Field(default=None, max_length=300)
    dua: str | None = Field(default=None, max_length=40)


class CarpetaImportCreate(CarpetaImportBase):
    pass


class CarpetaImportUpdate(BaseModel):
    """PATCH — todo opcional; los no-enviados no se tocan (exclude_unset)."""
    fecha: date | None = None
    factura: str | None = None
    carpeta: str | None = None
    exportador: str | None = None
    frontera: str | None = None
    transportista: str | None = None
    cantidad: int | None = None
    afidi: str | None = None
    dua: str | None = None
