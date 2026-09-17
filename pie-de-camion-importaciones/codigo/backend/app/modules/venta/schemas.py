from datetime import datetime

from pydantic import BaseModel, Field

# Cliente 999901 "Consumidor Final": venta anónima — el NOMBRE del cabezal se
# pisa con el nombre real del comprador (así lo hace el tomador original).
CONSUMIDOR_FINAL_COD = 999901


class ClienteVenta(BaseModel):
    cod: int
    nombre: str
    ruc: str = ""
    direccion: str = ""
    moneda: int = 1
    estado_cliente: str = ""      # campo Localidad del legacy ('Activo'/'De Baja'/…)
    pedidos_recientes: int = 0


class LineaPedidoInput(BaseModel):
    cod_art: str = Field(min_length=1, max_length=30)
    # Topes acordes a las columnas de Macrosoft (CantidadHaber numeric(10,3),
    # TotalLinea numeric(10,2)): sin esto un número gigante revienta el INSERT
    # con un 500 de arithmetic overflow en vez de un 400 legible.
    cantidad: float = Field(gt=0, le=1_000_000)
    # Precio unitario CON IVA incluido, lo fija el vendedor (puede ser 0: hay
    # líneas de regalo/bonificación; el legacy las tiene).
    precio: float = Field(ge=0, le=9_999_999)


class PedidoVentaCreate(BaseModel):
    cliente_cod: int
    # Solo para el cliente Consumidor Final: nombre del comprador (pisa NOMBRE).
    consumidor_nombre: str | None = Field(default=None, max_length=100)
    credito: bool = False          # ENCUOTAS 0=contado / 1=crédito (hint p/ caja)
    deposito: str = Field(default="A", pattern="^[AB]$")  # A=Puesto, B=ZAC
    # Cabezal2.OBSERVACIONES es char(100) — más de 100 revienta el INSERT.
    observaciones: str | None = Field(default=None, max_length=100)
    lineas: list[LineaPedidoInput] = Field(min_length=1, max_length=200)
    # Idempotencia: UUID por intento de envío (la tablet lo repite al reintentar
    # tras un timeout → no se duplica el pedido en la cola de caja).
    ref: str = Field(min_length=36, max_length=36)
    # Nace PRIORITARIO: tiene que salir YA (asignación arriba + alarma en tele).
    prioritario: bool = False
    # AGREGADO encadenado: nro_fact del pedido original del cliente (de HOY) al
    # que este pedido "le agrega" productos. Para Macrosoft es un pedido normal;
    # el vínculo vive en ext.pedido_agregado (siempre re-apuntado a la RAÍZ).
    agregado_de: int | None = None


class PedidoVentaCreado(BaseModel):
    nro_fact: int
    nro_doc: str
    total: float


# ── Agregados ────────────────────────────────────────────────────────────

class PedidoHoyCliente(BaseModel):
    """Un pedido de HOY del cliente, con su situación operativa — para que el
    tomador ofrezca 'agregar productos' al elegir el cliente."""
    nro_fact: int
    nro_doc: str
    hora: str | None = None
    credito: bool = False             # ENCUOTAS del original (el encadenado lo hereda)
    en_caja: bool                     # FACTURADO=0 → se pueden agregar líneas
    estado: str = ""                  # '' (en caja) | PENDIENTE | ASIGNADO | ...
    deposito: str | None = None
    total: float = 0                  # SUM(TotalLinea) — el cabezal puede quedar viejo
    items_count: int = 0
    solo_descuentos: bool = False     # pedido D% → no se le agregan productos
    armador_nombre: str = ""
    armado: bool = False
    entregado_registrado: bool = False
    agregado_de: int | None = None    # este pedido ya es un agregado de otro
    resumen: str = ""                 # "40× Banana Brasil · 10× Kiwi Chile"


class AgregarLineasInput(BaseModel):
    lineas: list[LineaPedidoInput] = Field(min_length=1, max_length=200)
    # Idempotencia (mismo mecanismo que crear: ext.venta_envio por ref).
    ref: str = Field(min_length=36, max_length=36)
    # Candado anti borrador-viejo / número equivocado: el back verifica que el
    # pedido destino sea de ESTE cliente (y de HOY) antes de insertar nada.
    cliente_cod: int


class LineasAgregadasOut(BaseModel):
    nro_fact: int
    nro_doc: str
    lineas_agregadas: int
    total_agregado: float
    total_pedido: float               # total real del pedido (suma de líneas)


class LineaPedidoOut(BaseModel):
    id: int
    cod_art: str
    descripcion: str
    deposito: str = ""
    cantidad: float
    precio: float
    total_linea: float
    icono: str | None = None


class PedidoVentaListItem(BaseModel):
    nro_fact: int
    nro_doc: str
    fecha: str | None = None       # ISO date
    hora: str | None = None        # HH:MM
    cliente_nombre: str
    cliente_cod: int | None = None
    vendedor: int | None = None
    vendedor_nombre: str = ""
    total: float | None = None     # NULL en filas viejas del espejo (pre-columna)
    credito: bool = False
    # Chip de estado derivado: 'anulado' | 'en_caja' | 'facturado' | estado
    # operativo en minúsculas ('entregado'/'asignado'/'parcial'/'devuelto').
    estado: str
    observaciones: str = ""
    es_mio: bool = False
    # Marcado como PRIORITARIO (tiene que salir YA) por un vendedor.
    prioritario: bool = False
    # Pedido de puros descuentos (artículos D*): no se arma ni se entrega, así
    # que no se puede marcar prioritario. Sólo viaja con ?con_resumen=true, que
    # es donde está el botón. Quitar una prioridad vieja sí se puede.
    solo_descuentos: bool = False
    creado_por: str | None = None  # usuario Aloha (solo pedidos creados acá)
    anulable: bool = False
    # Resumen de líneas para el vistazo rápido (solo con ?con_resumen=true, ej.
    # la vista "Por cliente"): íconos de fruta (dedup, por bultos desc) + bultos.
    iconos: list[str] = []
    total_bultos: float | None = None
    # Cuántos videos del pallet tiene (chip VIDEO): el vendedor al que le
    # reclaman los mira desde acá sin pasar por Entregas.
    videos: int = 0


class PedidoVentaDetail(PedidoVentaListItem):
    lineas: list[LineaPedidoOut] = []


class LineaHistorial(BaseModel):
    cod_art: str
    descripcion: str
    cantidad: float        # bultos (CantidadHaber)
    precio: float          # precio unitario que le hicimos
    total_linea: float
    icono: str | None = None


class PedidoHistorial(BaseModel):
    """Una compra anterior del cliente (para mostrar como referencia de precio)."""
    nro_fact: int
    nro_doc: str
    fecha: str | None = None
    vendedor_nombre: str | None = None
    total: float = 0
    lineas: list[LineaHistorial] = []


class UltimoPrecio(BaseModel):
    cod_art: str
    # Precio de LISTA (el que fija Valeria en Macrosoft, según la lista del
    # cliente). Desde el 27/07 es LA base del −10%/+20% del vendedor; los
    # últimos vendidos quedan como referencia/fallback.
    precio_lista: float | None = None
    precio: float | None = None          # último precio a ESTE cliente
    fecha: str | None = None
    precio_global: float | None = None   # último precio a cualquiera (referencia)
    fecha_global: str | None = None


class UltimosPreciosInput(BaseModel):
    cliente_cod: int | None = None
    cod_arts: list[str] = Field(min_length=1, max_length=100)


class VentaVendedorItem(BaseModel):
    usuario_id: int
    usuario_nombre: str
    username: str
    vendedor: int | None = None          # código Macrosoft asignado (None = sin asignar)
    vendedor_nombre: str | None = None
    actualizado_en: datetime | None = None


class VentaVendedorInput(BaseModel):
    usuario_id: int
    vendedor: int | None = Field(default=None, ge=1, le=99)  # None = desasignar


class EscrituraConfigVenta(BaseModel):
    # True = ambiente con Macrosoft real conectado (prod) → los pedidos se envían.
    # False = dev/testing sin conexión → solo se puede probar la pantalla.
    conectado: bool


class StockDisponibleArticulo(BaseModel):
    """Disponible de UN artículo, que es el de su familia (Articulos.CodStock).

    El saldo por color es ficción —la fruta entra como Color 1 y se vende
    madura—, así que todos los colores de una familia comparten el mismo
    número. Se devuelve por código para que el front lo busque directo por el
    artículo que ya tiene, sin mapear nada.
    """
    cod_art: str
    cod_stock: str
    familia: str | None = None
    saldo_familia: float          # lo que informa Macrosoft (DOYSTOCK)
    comprometido: float           # pedidos '30' vigentes de la familia
    disponible: float             # saldo − comprometido. Puede ser negativo: ver abajo
    pedidos_pendientes: int
    ranking: int                  # sólo para ordenar el picker; no filtra nada


class StockDisponibleResp(BaseModel):
    generado_en: datetime
    # Última vez que el mirror recalculó el saldo de Macrosoft (UTC-naive).
    # None = todavía no hay lectura: el front NO debe mostrar ceros como si
    # fueran datos.
    macrosoft_actualizado_en: datetime | None = None
    disponible: list[StockDisponibleArticulo]


class PrioridadBody(BaseModel):
    prioritario: bool


class ClienteCreate(BaseModel):
    """Alta mínima (26/08): Nombre obligatorio; el resto opcional. Los largos
    son los CHAR reales de Macrosoft."""
    nombre: str = Field(min_length=3, max_length=150)
    ruc: str | None = Field(default=None, max_length=20)
    nombre_fantasia: str | None = Field(default=None, max_length=150)
    direccion: str | None = Field(default=None, max_length=80)
    telefono: str | None = Field(default=None, max_length=20)


class ClienteCreado(BaseModel):
    cod: int
    nombre: str
