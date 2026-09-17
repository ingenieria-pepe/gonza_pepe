from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field

Calificacion = Literal["Regular", "Buena", "Muy buena"]
Estado = Literal["pendiente", "ingresado", "anulado"]
LongitudUnidad = Literal["cm", "pulgadas"]
UbicacionCamara = Literal["ZAC", "CR"]

# Cuántas cámaras hay por ubicación (para validar el número).
# CR: son 12 (confirmado 17/07 contra CamContador2, la fuente de verdad del
# conteo — el "13" original era un error de la spec; ningún pie real lo usó).
# Además CR tiene 13 CONTENEDORES que Aloha hoy NO modela — si algún día la
# fruta entra a un contenedor, agregar `tipo_unidad` al modelo y al webhook.
CAMARAS_POR_UBICACION: dict[str, int] = {"ZAC": 30, "CR": 12}


class CamaraInput(BaseModel):
    ubicacion: UbicacionCamara
    numero: int = Field(ge=1, le=30)          # tope real por ubicación se valida abajo
    # Cajas en esta cámara. None = todas las del camión (caso 1-cámara, lo normal).
    # Sólo se llena cuando se reparte la carga en varias cámaras.
    cantidad: int | None = Field(default=None, ge=1)
    # Qué producto (cod_art de una línea de mercadería) fue a esta cámara. None =
    # sin desglose (caso 1-cámara: va todo; o repartos viejos). En reparto con
    # varios productos, cada fila es una asignación producto→cámara.
    cod_art: str | None = Field(default=None, max_length=30)


class ProductoMarcaInput(BaseModel):
    producto: str = Field(min_length=1, max_length=100)
    marca: str | None = Field(default=None, max_length=100)


class FotoCategoria(BaseModel):
    """Una foto del camión etiquetada con su categoría (temp container, pulpa
    adelante, fruta atrás corona, etc.). El front manda la lista en orden canónico;
    el back la persiste (categoria=slug, caption=label) y el informe agrupa por
    categoría respetando ese orden."""
    categoria: str = Field(min_length=1, max_length=40)
    label: str = Field(min_length=1, max_length=200)
    foto: str = Field(min_length=1)          # data URI (o base64 puro) de la imagen


class ProductoMarcaOut(BaseModel):
    producto: str
    marca: str | None = None


# Reuso del concepto de "defecto" del módulo stock — definido acá para no
# acoplar módulos.
class DefectoInput(BaseModel):
    motivo_id: int
    cantidad: float = Field(gt=0)
    notas: str | None = Field(default=None, max_length=500)
    fotos: list[str] = Field(default_factory=list)


class LineaInput(BaseModel):
    cod_art: str = Field(min_length=1, max_length=30)
    # OPCIONAL desde el 05/08: el formulario ya no pregunta el depósito. La
    # mercadería de un camión SIEMPRE ingresa por el mismo (ver
    # DEPOSITO_INGRESO_PIE en el router: 836/836 líneas de ingreso reales en
    # Macrosoft están en 'B'), así que preguntarlo era ruido — y encima el form
    # venía con 'A' por default y había que corregirlo a mano en cada camión.
    # Sigue aceptándose por compatibilidad (clientes viejos, edición de pies
    # históricos que preservan su valor).
    deposito: str | None = Field(default=None, max_length=4)
    cantidad: float = Field(gt=0)
    # Marca del producto a nivel línea (ej. "PY de Primera", "Fischer").
    # Reemplaza la sección "Productos / Marcas" header del form viejo.
    marca: str | None = Field(default=None, max_length=100)
    # "¿Hay reclamos para esta fruta?" (mig 0072). POR PRODUCTO: con un camión de
    # varias frutas una sola respuesta era ambigua. Obligatoria al crear (el
    # router rechaza None); None sólo en la edición y en pies viejos.
    hay_reclamos: bool | None = None
    defectos: list[DefectoInput] = Field(default_factory=list)


TipoRequisito = Literal["numero", "texto", "opciones", "foto"]


class RequisitoOut(BaseModel):
    """Un requisito configurado por el ing. agrónomo para una fruta."""
    id: int
    categoria: str
    tipo: TipoRequisito
    etiqueta: str
    unidad: str | None = None
    opciones: list[str] = Field(default_factory=list)
    obligatorio: bool = True
    orden: int = 0
    activo: bool = True


class RequisitoUpsert(BaseModel):
    """Fila del ABM: sin id = nueva; con id = actualizar. Las que falten de la
    lista se desactivan (histórico intacto: las respuestas snapshotean)."""
    id: int | None = None
    tipo: TipoRequisito
    etiqueta: str = Field(min_length=1, max_length=200)
    unidad: str | None = Field(default=None, max_length=20)
    opciones: list[str] = Field(default_factory=list)
    obligatorio: bool = True


class RequisitosCategoriaUpsert(BaseModel):
    requisitos: list[RequisitoUpsert] = Field(default_factory=list)


class RequisitoRespuestaInput(BaseModel):
    """Respuesta del operario a un requisito. Los requisitos van POR FRUTA
    (categoría): un camión con dos variedades de kiwi responde UNA vez los
    checks de Kiwi. `valor`: texto libre / opción elegida / número como string
    ("13,5" ok). Para tipo=foto el valor no aplica: las fotos viajan en
    fotos_categoria con categoria="req-<requisito_id>"."""
    requisito_id: int
    valor: str | None = Field(default=None, max_length=1000)


class RequisitosAplicablesOut(BaseModel):
    """Requisitos activos agrupados por fruta PRESENTE en la mercadería."""
    categoria: str
    icono: str
    requisitos: list["RequisitoOut"] = Field(default_factory=list)


class RequisitoRespuestaOut(BaseModel):
    requisito_id: int | None = None
    producto: str
    categoria: str
    tipo: str
    etiqueta: str
    unidad: str | None = None
    valor_numero: float | None = None
    valor_texto: str | None = None
    fotos_n: int = 0


class EtiquetaImpresaCreate(BaseModel):
    """Impresión de etiquetas Zebra: deja el código de importador asociado al
    camión (placa+fecha) para que el celular no lo tenga que re-tipear."""
    placa: str = Field(min_length=1, max_length=20)
    fecha: date                                  # fecha de DESCARGA (la del pie)
    codigo: str = Field(min_length=1, max_length=30)
    cantidad: int | None = Field(default=None, ge=1, le=500)
    plan_carga_id: int | None = None             # informativo (el id del plan cambia con el sync)


class EtiquetaCamionOut(BaseModel):
    placa: str
    fecha: date
    codigo: str
    cantidad: int | None = None
    impreso_en: datetime
    impreso_por: str | None = None


class AgregarFotosRequest(BaseModel):
    """Fotos que se suman a un pie YA ENVIADO (mig 0069). Mismo formato que el
    create: categorizadas (con su label) y/o galería libre. Se ANEXAN al final
    del PDF de fotos — las anteriores no se tocan."""
    fotos_categoria: list[FotoCategoria] = Field(default_factory=list)
    fotos: list[str] = Field(default_factory=list)
    nota: str | None = Field(default=None, max_length=200)  # va en el título del anexo


class PieDeCamionCreate(BaseModel):
    # Idempotencia (mig 0058): UUID generado por el celu, vive en el borrador.
    # Si el mismo pie llega dos veces (reintento tras timeout con el body ya
    # procesado), el create devuelve el existente en vez de duplicar.
    client_ref: str | None = Field(default=None, max_length=64)

    fecha: date                              # fecha de DESCARGA (recepción)
    fecha_carga: date | None = None          # fecha en que se cargó el camión (origen)
    hora_inicio: str | None = Field(default=None, pattern=r"^\d{2}:\d{2}$")
    hora_fin: str | None = Field(default=None, pattern=r"^\d{2}:\d{2}$")

    chofer_nombre: str = Field(min_length=1, max_length=100)
    placa_camion: str = Field(min_length=1, max_length=20)

    # Si el operario eligió la carga del Plan al iniciar el pie de camión,
    # acá viene el id. El back valida que existe + cambia su status a
    # "Descargado" al guardar exitosamente este pie de camión.
    plan_carga_id: int | None = None

    # Multi-producto: lista de {producto, marca}. Si vacío y producto está seteado,
    # mantiene compat con clientes viejos.
    productos: list[ProductoMarcaInput] = Field(default_factory=list)
    producto: str | None = Field(default=None, max_length=100)   # deprecated, queda para back-compat
    marca: str | None = Field(default=None, max_length=100)       # idem

    exportador: str | None = Field(default=None, max_length=150)
    empresa_transporte: str | None = Field(default=None, max_length=150)
    numero_afidi: str | None = Field(default=None, max_length=50)
    # Productor (del Plan de Cargas): quién produjo la fruta. Se pre-carga del Plan.
    productor: str | None = Field(default=None, max_length=200)
    # Código de importador + nº de camión (ej. "FH-044"). Eventualmente
    # vendrá leído de un barcode pero por ahora se ingresa a mano.
    codigo_importador_camion: str | None = Field(default=None, max_length=30)

    intervenido_agronomia: bool = False
    inspector_agronomo: str | None = Field(default=None, max_length=100)

    palet_rating: int | None = Field(default=None, ge=1, le=5)
    palet_comentario: str | None = Field(default=None, max_length=200)
    cajas_rating: int | None = Field(default=None, ge=1, le=5)
    cajas_comentario: str | None = Field(default=None, max_length=200)
    flejes_rating: int | None = Field(default=None, ge=1, le=5)
    flejes_comentario: str | None = Field(default=None, max_length=200)

    temp_pulpa_puerta_1: float | None = None
    temp_pulpa_puerta_2: float | None = None
    temp_pulpa_medio_1: float | None = None
    temp_pulpa_medio_2: float | None = None
    temp_pulpa_atras_1: float | None = None
    temp_pulpa_atras_2: float | None = None

    peso_caja_puerta_1: float | None = None
    peso_caja_puerta_2: float | None = None
    peso_caja_medio_1: float | None = None
    peso_caja_medio_2: float | None = None
    peso_caja_atras_1: float | None = None
    peso_caja_atras_2: float | None = None

    calibracion_puerta: int | None = None
    calibracion_medio: int | None = None
    calibracion_atras: int | None = None

    longitud_puerta: float | None = None
    longitud_medio: float | None = None
    longitud_atras: float | None = None
    longitud_unidad: LongitudUnidad = "cm"

    corona: Calificacion | None = None
    quemada: Calificacion | None = None
    rameada: Calificacion | None = None

    descarga_autorizada_por: str | None = Field(default=None, max_length=100)
    inspeccion_realizada_por: str | None = Field(default=None, max_length=100)

    total_cajas: int | None = Field(default=None, ge=0)
    observaciones: str | None = Field(default=None, max_length=500)

    # "¿Hay reclamos para esta fruta?" — respuesta OBLIGATORIA al crear (mig 0071).
    # Antes, un pie sin defectos era ambiguo: no se sabía si la fruta vino bien o
    # si se pasaron de revisarla. None solo lo mandan los clientes viejos y la
    # EDICIÓN (donde el back preserva lo que ya estaba, ver editar_pie_camion).
    hay_reclamos: bool | None = None

    # NUEVO: la mercadería que se está descargando.
    lineas: list[LineaInput] = Field(default_factory=list)

    # Fotos del camión (no de defectos puntuales — esas van por línea).
    # Cada string es un data URI o base64 puro (jpg). El cliente las
    # comprime antes de mandarlas. Sin tope de cantidad (el cliente las
    # comprime a ~300KB c/u; el router skipea las > 2MB por seguridad).
    # Estas son las "Otras fotos" (galería libre, sin categoría).
    fotos: list[str] = Field(default_factory=list)

    # Fotos organizadas por categoría (temperatura container, ticket peaje, puerta,
    # temperaturas pulpa adelante/medio/atrás, pallet, balanza, estado de la fruta
    # por posición, etc.). En orden canónico; el informe agrupa por categoría.
    fotos_categoria: list[FotoCategoria] = Field(default_factory=list)

    # Documentación A4 escaneada con el celu (recorte automático en el cliente).
    # Cada string = data URI/base64 de una página ya enderezada. El back arma un
    # PDF APARTE de la planilla y lo sube junto al pie (ver doc_pdf_* en la tabla).
    documentacion: list[str] = Field(default_factory=list)

    # Cámara(s) de maduración donde ingresó la fruta. Normalmente UNA (toda la
    # carga entera). Se puede repartir en varias con su cantidad de cajas.
    camaras: list[CamaraInput] = Field(default_factory=list)

    # Respuestas a los requisitos por fruta del ing. agrónomo (mig 0092),
    # una por (requisito, producto). Las fotos de requisitos tipo foto van en
    # fotos_categoria con categoria="req-<id>-p<índice>".
    requisitos: list[RequisitoRespuestaInput] = Field(default_factory=list)


class CamaraOut(BaseModel):
    ubicacion: str
    numero: int
    cantidad: int | None = None
    cod_art: str | None = None


class DefectoOut(BaseModel):
    """Un defecto ya registrado en una línea (para pre-cargar el editar-reclamo).
    Las fotos NO viajan (viven solo en el PDF del reclamo) — solo su cantidad."""
    motivo_id: int
    motivo: str
    cantidad: float
    notas: str | None = None
    cantidad_fotos: int = 0


class LineaOut(BaseModel):
    id: int
    cod_art: str
    descripcion: str
    deposito: str
    deposito_descripcion: str | None = None
    cantidad: float
    marca: str | None = None
    cantidad_defectuosa: float = 0
    # Respuesta a "¿hay reclamos?" de ESTA línea (mig 0072). None = línea vieja.
    hay_reclamos: bool | None = None
    motivos_defecto: list[str] = Field(default_factory=list)
    defectos: list[DefectoOut] = Field(default_factory=list)
    # Slug del ícono de fruta (/categorias/<icono>.svg), derivado de la
    # descripción. None si la línea no matchea ninguna categoría.
    icono: str | None = None


class PieDeCamionFotoOut(BaseModel):
    id: int
    size_bytes: int
    orden: int
    caption: str | None = None


class PieDeCamionListItem(BaseModel):
    id: int
    fecha: date
    hora_inicio: str | None
    hora_fin: str | None
    chofer_nombre: str
    placa_camion: str
    producto: str | None   # primero de la lista, o el campo legacy si la tabla nueva está vacía
    productos: list[ProductoMarcaOut] = Field(default_factory=list)
    # Íconos de fruta (slugs de /categorias/<slug>.svg) de la mercadería del pie,
    # ordenados por cantidad desc y sin repetir. Para reconocer de un vistazo en la
    # lista de Ingresos ("el camión de banana + coco"), igual que el Monitor A/B.
    iconos: list[str] = Field(default_factory=list)
    exportador: str | None
    empresa_transporte: str | None
    numero_afidi: str | None
    codigo_importador_camion: str | None = None
    total_cajas: int | None
    pdf_filename: str
    pdf_size_bytes: int
    # Tamaño del PDF de documentación escaneada (None si el pie no trae). Ingresos
    # usa esto para mostrar el botón "Documentación".
    doc_pdf_size_bytes: int | None = None
    # Tamaño del PDF del termógrafo (None si no se adjuntó). El front lo usa para
    # marcar el pie con "Termógrafo ✓". El PDF va fusionado en el informe (/pdf).
    termografo_pdf_size_bytes: int | None = None
    termografo_pdf_filename: str | None = None   # nombre del archivo adjunto (verificación)
    creado_en: datetime
    creado_por_usuario: str | None
    # Estado y trazabilidad
    estado: Estado
    ingreso_documento: str | None = None
    ingreso_nro_fact: int | None = None
    # Reservado y sin cerrar (mig 0112): alguien empezó a confirmarlo y no se
    # sabe si Macrosoft llegó a escribir. La pantalla manda a revisar allá en
    # vez de ofrecer un reintento que podría duplicar el camión.
    confirmando_en: datetime | None = None
    confirmado_en: datetime | None = None
    confirmado_por_usuario: str | None = None
    reclamo_id: int | None = None
    # Respuesta a "¿hay reclamos?" (mig 0071). None = pie anterior al cambio.
    hay_reclamos: bool | None = None
    # Marca "descargado/revisado": se setea al bajar la planilla desde Ingresos.
    descargado_en: datetime | None = None
    # Fotos agregadas DESPUÉS de enviar el pie (mig 0069).
    fotos_anexos_n: int = 0
    fotos_anexo_en: datetime | None = None
    # Totales calculados
    n_lineas: int = 0
    cantidad_total: float = 0
    cantidad_defectuosa_total: float = 0


class PieDeCamionDetail(PieDeCamionListItem):
    # Datos completos del formulario (mismos que PieDeCamionCreate, salvo lineas que ahora son OUT).
    # Observaciones del RECLAMO (no del pie) — para pre-cargar el editar-reclamo.
    reclamo_observaciones: str | None = None
    # ¿El reclamo guarda su doc de fotos aparte (post-0047)? True → editar sin subir
    # fotos las conserva; False/None con fotos = reclamo viejo (viven en el PDF único
    # y se pierden al re-hacerlo). El front elige el aviso según esto.
    reclamo_tiene_fotos_pdf: bool | None = None
    # Respuesta a "¿Hay reclamos?" (mig 0071). None = pie viejo, no se preguntó.
    hay_reclamos: bool | None = None
    fecha_carga: date | None = None
    productor: str | None = None
    marca: str | None = None
    longitud_unidad: LongitudUnidad = "cm"
    intervenido_agronomia: bool = False
    inspector_agronomo: str | None = None
    palet_rating: int | None = None
    palet_comentario: str | None = None
    cajas_rating: int | None = None
    cajas_comentario: str | None = None
    flejes_rating: int | None = None
    flejes_comentario: str | None = None
    temp_pulpa_puerta_1: float | None = None
    temp_pulpa_puerta_2: float | None = None
    temp_pulpa_medio_1: float | None = None
    temp_pulpa_medio_2: float | None = None
    temp_pulpa_atras_1: float | None = None
    temp_pulpa_atras_2: float | None = None
    peso_caja_puerta_1: float | None = None
    peso_caja_puerta_2: float | None = None
    peso_caja_medio_1: float | None = None
    peso_caja_medio_2: float | None = None
    peso_caja_atras_1: float | None = None
    peso_caja_atras_2: float | None = None
    calibracion_puerta: int | None = None
    calibracion_medio: int | None = None
    calibracion_atras: int | None = None
    longitud_puerta: float | None = None
    longitud_medio: float | None = None
    longitud_atras: float | None = None
    corona: Calificacion | None = None
    quemada: Calificacion | None = None
    rameada: Calificacion | None = None
    descarga_autorizada_por: str | None = None
    inspeccion_realizada_por: str | None = None
    observaciones: str | None = None
    lineas: list[LineaOut] = Field(default_factory=list)
    camaras: list[CamaraOut] = Field(default_factory=list)
    # Respuestas snapshoteadas a los requisitos por fruta (mig 0092).
    requisitos: list[RequisitoRespuestaOut] = Field(default_factory=list)


class TermografoPdfUpload(BaseModel):
    """Subida del PDF del termógrafo desde el Historial (USB en una compu)."""
    pdf: str = Field(min_length=1)          # data URI (data:application/pdf;base64,...) o base64 puro
    filename: str | None = Field(default=None, max_length=200)


class ReclamoDefectoInput(BaseModel):
    """Un defecto marcado DESPUÉS de cargar el pie (reclamo post-hoc desde Ingresos).
    Referencia la línea por id (el pie ya existe, con sus líneas)."""
    linea_id: int
    motivo_id: int
    cantidad: float = Field(gt=0)
    notas: str | None = Field(default=None, max_length=500)
    # data URIs / base64 (jpg comprimido por el cliente). SIN tope de cantidad
    # (05/08: un reclamo real traía 46 fotos de un pallet y el 422 lo frenaba).
    # El límite que importa no es cuántas sino cuánto pesan: lo controla
    # `_exigir_peso_fotos` en el router, con un mensaje que se entiende.
    fotos: list[str] = Field(default_factory=list)


class ReclamoPieCreate(BaseModel):
    """Generar el reclamo al proveedor sobre un pie YA cargado (cuando al que ingresó
    el pie se le pasó marcar los defectos). Solo para pies SIN reclamo previo."""
    defectos: list[ReclamoDefectoInput] = Field(min_length=1)
    observaciones: str | None = Field(default=None, max_length=500)
    # Al RE-HACER un reclamo, las fotos nuevas se ANEXAN a las que ya tenía.
    # Antes lo reemplazaban y se perdían las anteriores sin aviso útil: el
    # incidente del pie 87 (07/08) — cargaron las fotos de la lima y se borraron
    # las de la papaya, que ya no existen en ningún lado (Aloha guarda el PDF
    # armado, no las imágenes sueltas). Reemplazar ahora es EXPLÍCITO.
    reemplazar_fotos: bool = False


class ConfirmarIngresoRequest(BaseModel):
    """Cuando el de Ingresos confirma un pie de camión. El documento lo
    DERIVA el back del depósito del pie (B→402, C→181); si el cliente lo
    manda igual (front viejo), tiene que coincidir o se rechaza."""
    documento: str | None = Field(default=None, description="Derivado del depósito; opcional (compat)")
