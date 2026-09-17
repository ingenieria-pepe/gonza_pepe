import { API_URL, apiGet, apiPost, apiPut, apiDelete } from "../../api/client";
import type { DefectoCreate } from "./stock";

export type Calificacion = "Regular" | "Buena" | "Muy buena";
export type EstadoPieCamion = "pendiente" | "ingresado" | "anulado";
export type LongitudUnidad = "cm" | "pulgadas";

export interface LineaInput {
  cod_art: string;
  /** OPCIONAL desde el 05/08: el formulario ya no lo pide por producto. Si no
   *  va, el back usa el depósito de ingreso predeterminado (DEPOSITO_INGRESO_
   *  DEFAULT = 'B', que es por donde entra TODA la mercadería en Macrosoft). */
  deposito?: string;
  cantidad: number;
  /** Marca del producto a nivel línea (ej "PY de Primera"). Reemplaza la
   *  sección "Productos / Marcas" header que ya no existe. */
  marca?: string | null;
  /** "¿Hay reclamos para esta fruta?" — POR PRODUCTO (mig 0072). Obligatoria al
   *  crear: el back rechaza el pie si alguna línea viene sin responder. */
  hay_reclamos?: boolean | null;
  defectos: DefectoCreate[];
}

export interface ProductoMarca {
  producto: string;
  marca: string | null;
}

/** Una foto etiquetada con su categoría (temp container, pulpa adelante, fruta
 *  atrás corona, etc.). Se manda en orden canónico; el informe agrupa por categoría. */
export interface FotoCategoria {
  categoria: string;   // slug estable
  label: string;       // etiqueta humana (título en el PDF)
  foto: string;        // data URI (image/jpeg)
}

export type UbicacionCamara = "ZAC" | "CR";
/** Cuántas cámaras hay por ubicación (para validar el número). */
// CR: 12 cámaras (confirmado contra CamContador2; el 13 original era error de spec).
export const CAMARAS_POR_UBICACION: Record<UbicacionCamara, number> = { ZAC: 30, CR: 12 };

export interface CamaraInput {
  ubicacion: UbicacionCamara;
  numero: number;                // 1-30 (ZAC) / 1-12 (CR)
  /** Cajas en esta cámara. null = todas (caso 1-cámara, lo normal). */
  cantidad?: number | null;
  /** Qué producto (cod_art de una línea) fue a esta cámara. null = sin desglose
   * (1 cámara = va todo; o repartos viejos). En reparto con varios productos,
   * cada fila es una asignación producto→cámara. */
  cod_art?: string | null;
}

export interface PieDeCamionCreate {
  /** Idempotencia: UUID generado por el celu, vive en el borrador. Si el mismo
   *  pie llega dos veces (reintento tras timeout), el back devuelve el
   *  existente en vez de duplicar. */
  client_ref?: string | null;

  fecha: string;                        // fecha de DESCARGA (recepción), YYYY-MM-DD
  fecha_carga?: string | null;          // fecha en que se cargó el camión (origen)
  hora_inicio?: string | null;          // HH:MM
  hora_fin?: string | null;

  chofer_nombre: string;
  placa_camion: string;

  /** ID de la carga del Plan de Cargas que estamos descargando. Si está
   *  seteado, el back marca esa carga como "Descargado" al guardar. */
  plan_carga_id?: number | null;

  // Multi-producto: lista de {producto, marca}. Campos producto/marca legacy
  // se mantienen para back-compat pero el front nuevo escribe `productos`.
  productos: ProductoMarca[];
  producto?: string | null;
  marca?: string | null;

  exportador?: string | null;
  empresa_transporte?: string | null;
  numero_afidi?: string | null;
  /** Productor (del Plan de Cargas). Se pre-carga al elegir la carga. */
  productor?: string | null;
  codigo_importador_camion?: string | null;

  intervenido_agronomia: boolean;
  inspector_agronomo?: string | null;

  palet_rating?: number | null;
  palet_comentario?: string | null;
  cajas_rating?: number | null;
  cajas_comentario?: string | null;
  flejes_rating?: number | null;
  flejes_comentario?: string | null;

  temp_pulpa_puerta_1?: number | null;
  temp_pulpa_puerta_2?: number | null;
  temp_pulpa_medio_1?: number | null;
  temp_pulpa_medio_2?: number | null;
  temp_pulpa_atras_1?: number | null;
  temp_pulpa_atras_2?: number | null;

  peso_caja_puerta_1?: number | null;
  peso_caja_puerta_2?: number | null;
  peso_caja_medio_1?: number | null;
  peso_caja_medio_2?: number | null;
  peso_caja_atras_1?: number | null;
  peso_caja_atras_2?: number | null;

  calibracion_puerta?: number | null;
  calibracion_medio?: number | null;
  calibracion_atras?: number | null;

  longitud_puerta?: number | null;
  longitud_medio?: number | null;
  longitud_atras?: number | null;
  longitud_unidad: LongitudUnidad;

  corona?: Calificacion | null;
  quemada?: Calificacion | null;
  rameada?: Calificacion | null;

  descarga_autorizada_por?: string | null;
  inspeccion_realizada_por?: string | null;

  total_cajas?: number | null;
  observaciones?: string | null;

  /** "¿Hay reclamos para esta fruta?" — obligatoria al crear (mig 0071).
   *  null = todavía sin responder (el front bloquea el envío). En EDICIÓN va
   *  null a propósito: el back preserva la respuesta que ya tenía el pie. */
  hay_reclamos?: boolean | null;

  lineas: LineaInput[];

  /** Fotos del camión, data URIs (image/jpeg). Comprimidas en el cliente
   *  antes de mandar (max 1280px JPEG 75%). */
  fotos: string[];

  /** Documentación A4 escaneada (recorte automático en el celu). Cada string es
   *  un data URI de una página ya enderezada. El back arma un PDF aparte. */
  documentacion?: string[];

  /** Working store del form: fotos por categoría, keyed por slug. NO se manda al
   *  back (se transforma a `fotos_categoria` en el submit); se persiste en el borrador. */
  fotos_cat?: Record<string, string[]>;

  /** Payload real al back: fotos categorizadas en orden canónico (temperatura
   *  container, pulpa adelante, fruta atrás corona, etc.). */
  fotos_categoria?: FotoCategoria[];

  /** Cámara(s) de maduración donde ingresó la fruta. Normalmente una (todo el
   *  camión). Se puede repartir en varias con su cantidad de cajas. */
  camaras?: CamaraInput[];

  /** Working store del form (mig 0092): respuestas a los requisitos por fruta,
   *  keyed por requisito_id. NO se manda al back (se transforma en `requisitos`
   *  al submit); se persiste en el borrador. Las FOTOS de requisitos van en
   *  fotos_cat con slug `req-<id>`. */
  requisitos_valores?: Record<number, string>;

  /** Payload real al back: respuestas a los requisitos del ing. agrónomo. */
  requisitos?: { requisito_id: number; valor: string | null }[];
}

// ── Requisitos por fruta (mig 0092): lo que el ING. AGRÓNOMO pide al ingreso ──

export type TipoRequisito = "numero" | "texto" | "opciones" | "foto";

export interface Requisito {
  id: number;
  categoria: string;
  tipo: TipoRequisito;
  etiqueta: string;
  unidad: string | null;
  opciones: string[];
  obligatorio: boolean;
  orden: number;
  activo: boolean;
}

export interface RequisitoUpsert {
  id?: number | null;
  tipo: TipoRequisito;
  etiqueta: string;
  unidad?: string | null;
  opciones?: string[];
  obligatorio: boolean;
}

/** Requisitos activos de las frutas PRESENTES en la mercadería del form. */
export interface RequisitosAplicables {
  categoria: string;
  icono: string;
  requisitos: Requisito[];
}

export interface RequisitoRespuestaOut {
  requisito_id: number | null;
  producto: string;
  categoria: string;
  tipo: string;
  etiqueta: string;
  unidad: string | null;
  valor_numero: number | null;
  valor_texto: string | null;
  fotos_n: number;
}

export function listRequisitos(incluirInactivos = false): Promise<Requisito[]> {
  return apiGet<Requisito[]>(`/pie-camion/requisitos${incluirInactivos ? "?incluir_inactivos=true" : ""}`);
}

export function putRequisitosCategoria(categoria: string, requisitos: RequisitoUpsert[]): Promise<Requisito[]> {
  return apiPut<Requisito[]>(`/pie-camion/requisitos/${encodeURIComponent(categoria)}`, { requisitos });
}

export function getRequisitosAplicables(cods: string[]): Promise<RequisitosAplicables[]> {
  return apiGet<RequisitosAplicables[]>(`/pie-camion/requisitos/aplicables?cods=${encodeURIComponent(cods.join(","))}`);
}

export interface LineaOut {
  id: number;
  cod_art: string;
  descripcion: string;
  deposito: string;
  deposito_descripcion: string | null;
  cantidad: number;
  marca?: string | null;
  cantidad_defectuosa: number;
  /** Respuesta de ESTA línea. null = línea vieja, anterior a la mig 0072. */
  hay_reclamos?: boolean | null;
  motivos_defecto: string[];
  /** Defectos ya registrados (para pre-cargar el editar-reclamo). Las fotos NO
   * viajan (viven solo en el PDF del reclamo) — solo su cantidad. */
  defectos: {
    motivo_id: number;
    motivo: string;
    cantidad: number;
    notas: string | null;
    cantidad_fotos: number;
  }[];
  /** Slug del ícono de fruta (/categorias/<icono>.svg), null si no matchea. */
  icono: string | null;
}

export interface PieDeCamionListItem {
  id: number;
  fecha: string;
  hora_inicio: string | null;
  hora_fin: string | null;
  chofer_nombre: string;
  placa_camion: string;
  producto: string | null;       // primero de la lista (legacy)
  productos: ProductoMarca[];
  exportador: string | null;
  empresa_transporte: string | null;
  numero_afidi: string | null;
  codigo_importador_camion: string | null;
  total_cajas: number | null;
  pdf_filename: string;
  pdf_size_bytes: number;
  /** Tamaño del PDF de documentación escaneada (null si el pie no trae). */
  doc_pdf_size_bytes: number | null;
  /** Tamaño del PDF del termógrafo (null si no se adjuntó). Va fusionado en el informe. */
  termografo_pdf_size_bytes: number | null;
  /** Nombre del archivo del termógrafo adjunto (para verificar cuál se subió). */
  termografo_pdf_filename: string | null;
  creado_en: string;
  creado_por_usuario: string | null;
  estado: EstadoPieCamion;
  ingreso_documento: string | null;
  ingreso_nro_fact: number | null;
  /** Reservado y sin cerrar (mig 0112): alguien empezó a confirmarlo y no se
   *  sabe si Macrosoft llegó a escribir. No se reintenta a ciegas. */
  confirmando_en?: string | null;
  confirmado_en: string | null;
  confirmado_por_usuario: string | null;
  reclamo_id: number | null;
  /** Marca "descargado/revisado": se setea al bajar la planilla desde Ingresos. */
  descargado_en: string | null;
  /** Respuesta a "¿Hay reclamos?" (mig 0071). null = pie viejo, no se preguntó. */
  hay_reclamos?: boolean | null;
  /** Fotos agregadas DESPUÉS de enviar el pie (tandas anexadas al informe). */
  fotos_anexos_n?: number;
  fotos_anexo_en?: string | null;
  n_lineas: number;
  cantidad_total: number;
  cantidad_defectuosa_total: number;
  /** Íconos de fruta (slugs de /categorias/<slug>.svg), ordenados por cantidad. */
  iconos: string[];
}

export interface PieDeCamionDetail extends PieDeCamionListItem {
  /** Observaciones del RECLAMO (no del pie) — para pre-cargar el editar-reclamo. */
  reclamo_observaciones: string | null;
  /** true = el reclamo guarda su doc de fotos aparte → editar sin subir fotos las conserva. */
  reclamo_tiene_fotos_pdf: boolean | null;
  // Echo de todos los campos del form (los importantes para mostrar)
  fecha_carga: string | null;
  productor: string | null;
  marca: string | null;
  intervenido_agronomia: boolean;
  inspector_agronomo: string | null;
  palet_rating: number | null;
  palet_comentario: string | null;
  cajas_rating: number | null;
  cajas_comentario: string | null;
  flejes_rating: number | null;
  flejes_comentario: string | null;
  temp_pulpa_puerta_1: number | null;
  temp_pulpa_puerta_2: number | null;
  temp_pulpa_medio_1: number | null;
  temp_pulpa_medio_2: number | null;
  temp_pulpa_atras_1: number | null;
  temp_pulpa_atras_2: number | null;
  peso_caja_puerta_1: number | null;
  peso_caja_puerta_2: number | null;
  peso_caja_medio_1: number | null;
  peso_caja_medio_2: number | null;
  peso_caja_atras_1: number | null;
  peso_caja_atras_2: number | null;
  calibracion_puerta: number | null;
  calibracion_medio: number | null;
  calibracion_atras: number | null;
  longitud_puerta: number | null;
  longitud_medio: number | null;
  longitud_atras: number | null;
  longitud_unidad: LongitudUnidad;
  corona: Calificacion | null;
  quemada: Calificacion | null;
  rameada: Calificacion | null;
  descarga_autorizada_por: string | null;
  inspeccion_realizada_por: string | null;
  observaciones: string | null;
  lineas: LineaOut[];
  camaras: CamaraInput[];
  /** Respuestas snapshoteadas a los requisitos por fruta (mig 0092). */
  requisitos: RequisitoRespuestaOut[];
}

export function listPieCamion(estado?: EstadoPieCamion) {
  const q = estado ? `?estado=${estado}` : "";
  return apiGet<PieDeCamionListItem[]>(`/pie-camion${q}`);
}

export function getPieCamion(id: number) {
  return apiGet<PieDeCamionDetail>(`/pie-camion/${id}`);
}

export function confirmarPieCamion(id: number) {
  // El documento lo deriva el BACK del depósito del pie (B→402, C→181).
  return apiPost<PieDeCamionListItem>(`/pie-camion/${id}/confirmar`, {});
}

export function createPieCamion(body: PieDeCamionCreate, signal?: AbortSignal) {
  return apiPost<PieDeCamionListItem>("/pie-camion", body, { signal });
}

/** Edita un pie de camión PENDIENTE (desde Ingresos): actualiza todos los campos de
 *  datos + mercadería + cámaras + productos y re-genera el informe. Las fotos, la
 *  documentación y los reclamos se conservan (el back ignora `fotos`/`documentacion`
 *  del body y preserva los defectos). Solo funciona con estado `pendiente`. */
export function editarPieCamion(id: number, body: PieDeCamionCreate, signal?: AbortSignal) {
  return apiPut<PieDeCamionListItem>(`/pie-camion/${id}`, body, { signal });
}

/** Agrega fotos a un pie YA ENVIADO. Se ANEXAN al final del PDF de fotos (que se
 *  fusiona con el informe al descargar), con un título que dice cuándo y quién las
 *  sumó. Las fotos anteriores no se pueden borrar ni reordenar: desde el split de
 *  julio no se guardan sueltas, viven adentro del PDF. */
export function agregarFotosPieCamion(
  id: number,
  body: { fotos_categoria?: FotoCategoria[]; fotos?: string[]; nota?: string },
  signal?: AbortSignal,
) {
  return apiPost<{ ok: boolean; fotos_agregadas: number }>(`/pie-camion/${id}/fotos`, body, { signal });
}

/** Adjunta el PDF del termógrafo (cadena de frío) a un pie ya guardado. `pdf` es
 *  un data URI (data:application/pdf;base64,...). El back lo fusiona con la planilla
 *  al descargar el informe. Re-subir reemplaza. */
export function subirTermografoPdf(id: number, pdf: string, filename: string) {
  return apiPost<PieDeCamionListItem>(`/pie-camion/${id}/termografo-pdf`, { pdf, filename });
}

/** Borra el PDF del termógrafo adjunto (si lo subieron mal). La planilla base no se
 *  toca: el informe vuelve a servirse sin el termógrafo. Idempotente. */
export function borrarTermografoPdf(id: number) {
  return apiDelete<PieDeCamionListItem>(`/pie-camion/${id}/termografo-pdf`);
}

/** Marca el pie de camión como "descargado/revisado" (compartido). Lo llama
 *  Ingresos al bajar la planilla, para ver cuáles ya se revisaron. */
/** Defecto para el reclamo post-hoc (sobre un pie YA cargado, desde Ingresos). */
export interface ReclamoDefectoInput {
  linea_id: number;
  motivo_id: number;
  cantidad: number;
  notas?: string | null;
  fotos: string[];
}

/** Genera el reclamo al proveedor sobre un pie ya cargado (cuando se pasó marcar
 * los defectos al ingresarlo). Solo pies sin reclamo previo. */
export function crearReclamoPie(
  id: number,
  /** `reemplazar_fotos`: por defecto las fotos nuevas se SUMAN a las que ya
   *  tenía el reclamo. En true las reemplaza (las anteriores se pierden). */
  body: { defectos: ReclamoDefectoInput[]; observaciones?: string | null; reemplazar_fotos?: boolean },
): Promise<{ reclamo_id: number }> {
  return apiPost<{ reclamo_id: number }>(`/pie-camion/${id}/reclamo`, body);
}

/** RE-HACE el reclamo de un pie: los defectos nuevos reemplazan a todos los
 * anteriores y se re-generan ambos PDFs.
 *
 * Las FOTOS, en cambio, se SUMAN a las que ya tenía (desde el 07/08): antes las
 * reemplazaban y se perdían para siempre — Aloha guarda el PDF armado, no las
 * imágenes sueltas. `reemplazar_fotos: true` vuelve al comportamiento viejo,
 * pero hay que pedirlo explícitamente. */
export function editarReclamoPie(
  id: number,
  body: { defectos: ReclamoDefectoInput[]; observaciones?: string | null; reemplazar_fotos?: boolean },
): Promise<{ reclamo_id: number }> {
  return apiPut<{ reclamo_id: number }>(`/pie-camion/${id}/reclamo`, body);
}

export function marcarPieDescargado(id: number): Promise<void> {
  return apiPost<void>(`/pie-camion/${id}/marcar-descargado`);
}

/** QR (SVG) para la etiqueta: codifica SOLO el código (texto plano, sin link ni
 *  dominio). Se escanea DESDE Aloha (tab QR de Consulta). */
export function getEtiquetaQr(cod: string): Promise<{ svg: string }> {
  return apiGet<{ svg: string }>(`/pie-camion/etiqueta-qr?cod=${encodeURIComponent(cod)}`);
}

/** Código de importador que quedó asociado a un camión al imprimir sus etiquetas
 *  Zebra. El form del pie lo pre-carga para que no haya que re-tipearlo (y que
 *  el QR de la etiqueta no termine apuntando a un código distinto al del pie). */
export interface EtiquetaCamion {
  placa: string;
  fecha: string;          // YYYY-MM-DD (fecha de descarga)
  codigo: string;
  cantidad: number | null;
  impreso_en: string;
  impreso_por: string | null;
}

/** Deja el código asociado al camión (placa+fecha). Se llama al imprimir. */
export function registrarEtiquetaImpresa(body: {
  placa: string;
  fecha: string;
  codigo: string;
  cantidad?: number | null;
  plan_carga_id?: number | null;
}): Promise<EtiquetaCamion> {
  return apiPost<EtiquetaCamion>("/pie-camion/etiqueta-impresa", body);
}

/** ¿Se imprimieron etiquetas para este camión? null = no hay. */
export function getEtiquetaCamion(placa: string, fecha: string): Promise<EtiquetaCamion | null> {
  return apiGet<EtiquetaCamion | null>(
    `/pie-camion/etiqueta-camion?placa=${encodeURIComponent(placa)}&fecha=${encodeURIComponent(fecha)}`,
  );
}

/** Busca pie(s) de camión por el QR de la etiqueta (o código tipeado). El QR nuevo
 *  codifica `CÓDIGO|PLACA|FECHA` (único); un código pelado matchea sólo por código.
 *  Devuelve la LISTA de candidatos no anulados (0, 1 o varios → el front decide). */
export function buscarPiePorCodigo(cod: string): Promise<PieDeCamionListItem[]> {
  return apiGet<PieDeCamionListItem[]>(`/pie-camion/por-codigo?cod=${encodeURIComponent(cod)}`);
}

/** Descarga el PDF y lo abre en nueva pestaña (con Authorization header). */
export async function openPieCamionPdf(id: number): Promise<void> {
  await abrirPdf(`/pie-camion/${id}/pdf`);
}

/** Descarga el PDF de documentación escaneada (aparte de la planilla). */
export async function openDocumentacionPdf(id: number): Promise<void> {
  await abrirPdf(`/pie-camion/${id}/documentacion-pdf`);
}

/** Abre SOLO el PDF del termógrafo adjunto (para verificar cuál se cargó). */
export async function openTermografoPdf(id: number): Promise<void> {
  await abrirPdf(`/pie-camion/${id}/termografo-pdf`);
}

async function abrirPdf(path: string): Promise<void> {
  const token = localStorage.getItem("aloha.auth_token") ?? "";
  const r = await fetch(`${API_URL}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!r.ok) throw new Error(`No se pudo descargar el PDF (${r.status})`);
  const blob = await r.blob();
  const url = URL.createObjectURL(blob);
  window.open(url, "_blank", "noopener");
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
