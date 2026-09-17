import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { apiGet } from "../../api/client";
import { ArticuloPickerModal } from "../../shared/components/stock/ArticuloPickerModal";
import { DefectosControl } from "../../shared/components/stock/DefectosControl";
import { PhotoUploader } from "../../shared/components/PhotoUploader";
import { UsuarioPicker } from "../../shared/components/UsuarioPicker";
import { AgregarFotosModal } from "./components/AgregarFotosModal";
import { CargaPicker } from "./components/CargaPicker";
import { ResultadoRecepcionViaje } from "./components/RecepcionViajeModal";
import {
  confirmarRecepcionViaje,
  type RecepcionViajeResultado,
  type ViajePendienteRecepcion,
} from "../../shared/api/stock";
import { CategoriaFotos } from "./components/CategoriaFotos";
import { FOTO_SECCIONES, buildFotosCategoria, tieneFotosCat } from "./fotoCategorias";
import { listCategorias, searchArticulos, type Articulo, type DefectoCreate } from "../../shared/api/stock";
import { idbGet, idbSet, idbDel, idbKeys } from "../../shared/idb";
import { imprimirEtiquetas } from "../../shared/zebra/etiqueta";
import type { PlanCarga } from "../../shared/api/planCargas";
import {
  createPieCamion,
  editarPieCamion,
  getPieCamion,
  getRequisitosAplicables,
  listPieCamion,
  openPieCamionPdf,
  openTermografoPdf,
  subirTermografoPdf,
  borrarTermografoPdf,
  CAMARAS_POR_UBICACION,
  getEtiquetaCamion,
  registrarEtiquetaImpresa,
  type EtiquetaCamion,
  type Calificacion,
  type CamaraInput,
  type LineaInput,
  type LongitudUnidad,
  type PieDeCamionCreate,
  type PieDeCamionDetail,
  type PieDeCamionListItem,
  type RequisitosAplicables,
  type UbicacionCamara,
} from "../../shared/api/piecamion";
import { RequisitosFruta } from "./components/RequisitosFruta";
import { RequisitosConfigView } from "./components/RequisitosConfigView";
import { useAuth } from "../../shared/AuthContext";
import { formatDate } from "../../shared/format";

interface LineaDraft extends LineaInput {
  descripcion: string;
  /** Solo display de pies YA guardados. */
  deposito_descripcion?: string;
  icono: string | null;   // SVG de categoría (/categorias/<icono>.svg) — sólo display
}

interface Deposito {
  cod: string;
  descripcion: string;
}

/** Depósito de ingreso PREDETERMINADO (no fijo: hay un selector arriba de la
 *  lista de mercadería). Es B = ZAC porque así se ingresa en Macrosoft en la
 *  práctica (auditoría 06/08: las 836 líneas de ingreso del mirror son 'B');
 *  el default viejo era 'A' = Puesto, que nunca era el correcto. */
const DEPOSITO_INGRESO_DEFAULT = "B";

/** Depósito que ya traen unas líneas (pie que se está editando, borrador
 *  restaurado); si no traen ninguno, el predeterminado. */
function depositoDeLineas(ls: LineaDraft[] | undefined): string {
  return ls?.find((l) => l.deposito?.trim())?.deposito?.trim() || DEPOSITO_INGRESO_DEFAULT;
}

/** Algo obligatorio que falta completar. `id` es el ancla en el DOM del campo:
 *  la lista de faltantes es TOCABLE y salta hasta ahí. */
type Falta = { id: string; que: string };

/** Todo lo obligatorio que falta, junto (no el primero nada más). Es una función
 *  pura para poder recalcularla EN VIVO después del primer intento de guardar:
 *  así el operario ve la lista achicarse mientras completa, en vez de tener que
 *  apretar Guardar de nuevo para enterarse de lo próximo que le falta. */
export function faltantesDelPie(
  form: PieDeCamionCreate,
  lineas: LineaDraft[],
  isEdit: boolean,
  gruposRequisitos: RequisitosAplicables[] = [],
  /** Edición: ids de requisitos-foto que el pie YA tiene guardados (las fotos
   *  viven en el fotos-PDF, no se re-mandan) — cuentan como cumplidos. */
  fotosRequisitoPrevias: Set<number> = new Set(),
): Falta[] {
  const f: Falta[] = [];
  if (!form.chofer_nombre.trim()) f.push({ id: "f-chofer", que: "El nombre del chofer" });
  if (!form.placa_camion.trim()) f.push({ id: "f-placa", que: "La placa del camión" });
  // Es la clave para cruzar el pie con el ingreso de Macrosoft y lo que se
  // imprime en las etiquetas Zebra de los pallets: sin esto el camión queda
  // sin identificar.
  if (!(form.codigo_importador_camion ?? "").trim())
    f.push({ id: "f-codimp", que: "El código de importador / camión" });

  if (!isEdit && lineas.length === 0) {
    f.push({ id: "f-mercaderia", que: "Cargar al menos un producto en la mercadería" });
  } else {
    const sinCant = lineas.filter((l) => !l.cantidad || l.cantidad <= 0).length;
    if (sinCant > 0)
      f.push({
        id: "f-mercaderia",
        que: `Las cajas de ${sinCant === 1 ? "un producto" : `${sinCant} productos`} de la mercadería`,
      });
  }

  // Condiciones generales: obligatorias al CREAR. En edición no se exigen — un
  // pie viejo puede no tenerlas y no queremos trabar una corrección de otra cosa.
  if (!isEdit) {
    if (form.palet_rating == null) f.push({ id: "f-palet", que: "El puntaje del Palet (1 a 5)" });
    if (form.cajas_rating == null) f.push({ id: "f-cajas", que: "El puntaje de las Cajas (1 a 5)" });
    if (form.flejes_rating == null) f.push({ id: "f-flejes", que: "El puntaje de los Flejes (1 a 5)" });
  }

  // La pregunta de reclamos (mig 0072): una POR PRODUCTO. En edición no se
  // pregunta — el back preserva la respuesta y los defectos por cod_art.
  if (!isEdit) {
    lineas.forEach((l, i) => {
      const nombre = nombreCortoProducto(l.descripcion) || l.cod_art;
      if (l.hay_reclamos == null)
        f.push({ id: `f-reclamos-${i}`, que: `Responder si hay reclamos en ${nombre}` });
      else if (l.hay_reclamos && l.defectos.length === 0)
        f.push({ id: `f-reclamos-${i}`, que: `${nombre}: dijiste que HAY reclamos, marcá el defecto` });
      else if (!l.hay_reclamos && l.defectos.length > 0)
        f.push({ id: `f-reclamos-${i}`, que: `${nombre}: dijiste que NO hay reclamos pero marcaste defectos` });
    });
  }

  // Requisitos por fruta del ing. agrónomo (mig 0092): los obligatorios de las
  // frutas presentes en la mercadería.
  for (const grupo of gruposRequisitos) {
    for (const req of grupo.requisitos) {
      if (!req.obligatorio) continue;
      if (req.tipo === "foto") {
        const fotos = form.fotos_cat?.[`req-${req.id}`] ?? [];
        if (fotos.length === 0 && !fotosRequisitoPrevias.has(req.id))
          f.push({ id: `f-req-${req.id}`, que: `${grupo.categoria}: ${req.etiqueta} (foto)` });
      } else if (!(form.requisitos_valores?.[req.id] ?? "").trim()) {
        f.push({ id: `f-req-${req.id}`, que: `${grupo.categoria}: ${req.etiqueta}` });
      }
    }
  }
  return f;
}

/** Lleva la pantalla hasta el campo que falta y le da el foco. */
function irAlCampo(id: string) {
  const el = document.getElementById(id);
  if (!el) return;
  el.scrollIntoView({ behavior: "smooth", block: "center" });
  const foco = el.querySelector<HTMLElement>("input, select, textarea, button");
  window.setTimeout(() => foco?.focus({ preventScroll: true }), 350);
}

type Tab = "nuevo" | "historial";

function todayISO(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function nowHHMM(): string {
  const d = new Date();
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function PieDeCamionPage() {
  const [tab, setTab] = useState<Tab>("nuevo");
  const { hasPermission } = useAuth();
  // El ABM de requisitos por fruta es del ING. AGRÓNOMO: permiso propio
  // `pie_requisitos_config` — los operarios de recepción no lo ven.
  const puedeConfigurar = hasPermission("pie_requisitos_config");
  const [configAbierta, setConfigAbierta] = useState(false);
  return (
    <div className="h-full overflow-y-auto overflow-x-hidden overscroll-y-contain p-4 sm:p-6">
      <div className="max-w-5xl mx-auto">
        <header className="mb-4 flex items-start justify-between gap-3">
          <div>
            <h1 className="text-2xl font-semibold text-slate-900">Pie de camión</h1>
            <p className="text-sm text-slate-500 mt-0.5">
              Control de mercadería a pie de camión. Reemplaza la planilla de papel.
            </p>
          </div>
          {puedeConfigurar && (
            <button
              onClick={() => setConfigAbierta(true)}
              title="Requisitos por fruta (ing. agrónomo)"
              aria-label="Configurar requisitos por fruta"
              className="p-3 rounded-xl border border-pepe-border bg-white text-slate-500 hover:text-pepe-blue hover:border-pepe-blue shadow-sm"
            >
              <svg className="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.24-.438.613-.431.992a6.759 6.759 0 010 .255c-.007.378.138.75.43.99l1.005.828c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.57 6.57 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.28c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.02-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 010-.255c.007-.378-.138-.75-.43-.99l-1.004-.828a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.281z" />
                <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
            </button>
          )}
        </header>

        <nav className="flex border-b border-pepe-border mb-4">
          <SubTab active={tab === "nuevo"} onClick={() => setTab("nuevo")}>
            Nuevo registro
          </SubTab>
          <SubTab active={tab === "historial"} onClick={() => setTab("historial")}>
            Historial
          </SubTab>
        </nav>

        {tab === "nuevo" ? <NuevoForm onSaved={() => setTab("historial")} /> : <HistorialView />}
      </div>
      {configAbierta && puedeConfigurar && <RequisitosConfigView onClose={() => setConfigAbierta(false)} />}
    </div>
  );
}

function SubTab({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button
      onClick={onClick}
      className={`px-4 py-3 sm:py-2 text-sm font-medium border-b-2 transition-colors ${
        active
          ? "border-pepe-blue text-pepe-blue"
          : "border-transparent text-slate-500 hover:text-slate-800"
      }`}
    >
      {children}
    </button>
  );
}

// =====================================================================
// FORM
// =====================================================================

const EMPTY: PieDeCamionCreate = {
  fecha: todayISO(),
  fecha_carga: null,
  hora_inicio: nowHHMM(),
  hora_fin: null,
  chofer_nombre: "",
  placa_camion: "",
  plan_carga_id: null,
  productos: [],     // legacy — el nuevo front escribe `marca` por línea
  producto: "",
  marca: "",
  exportador: "",
  empresa_transporte: "",
  numero_afidi: "",
  productor: null,
  codigo_importador_camion: "",
  intervenido_agronomia: false,
  inspector_agronomo: null,
  palet_rating: null,
  palet_comentario: null,
  cajas_rating: null,
  cajas_comentario: null,
  flejes_rating: null,
  flejes_comentario: null,
  longitud_unidad: "cm",
  total_cajas: null,
  observaciones: null,
  lineas: [],
  fotos: [],
  fotos_cat: {},
  documentacion: [],
  camaras: [],
  requisitos_valores: {},
};

// ── Borrador en IndexedDB: si recargan, BLOQUEAN EL CELU o se cierra la app sin
//    guardar, no se pierde NADA — INCLUIDAS LAS FOTOS. IndexedDB banca cientos de
//    MB (localStorage no) y persiste como localStorage. Se borra al guardar o al
//    vaciar el form. Funciona offline (no depende de señal).

const DRAFT_KEY = "piedecamion.draft";              // clave en IndexedDB
const OLD_LS_KEY = "aloha.piedecamion.draft";       // borrador viejo (localStorage) → limpiar
const DRAFT_TTL_MS = 24 * 60 * 60 * 1000;           // 24h; borradores más viejos se descartan

interface Draft {
  form: PieDeCamionCreate;
  lineas: LineaDraft[];
  carga: PlanCarga | null;
  savedAt: number;
}

function tieneContenido(form: PieDeCamionCreate, lineas: LineaDraft[]): boolean {
  return !!(
    form.chofer_nombre?.trim() ||
    form.placa_camion?.trim() ||
    form.numero_afidi ||
    form.plan_carga_id ||
    lineas.length ||
    form.fotos.length ||
    tieneFotosCat(form.fotos_cat) ||
    form.documentacion?.length ||
    form.camaras?.some((c) => c.numero != null && !Number.isNaN(c.numero))
  );
}

// ── Cola de operaciones del borrador: TODO lo que toca DRAFT_KEY/papelera va
//    EN SERIE. Sin esto, dos clearDraft/saveDraft/loadDraft concurrentes (el
//    debounce de 400ms vs el onSuccess del envío vs el remount) intercalaban
//    sus get/set/del y podían resucitar un draft borrado o duplicar backups
//    (review adversarial 22/07).
let colaIdb: Promise<unknown> = Promise.resolve();
function enColaIdb<T>(fn: () => Promise<T>): Promise<T> {
  const p = colaIdb.then(fn, fn);
  colaIdb = p.then(
    () => undefined,
    () => undefined,
  );
  return p;
}

function loadDraft(): Promise<Draft | null> {
  return enColaIdb(async () => {
    try {
      const d = await idbGet<Draft>(DRAFT_KEY);
      if (!d?.savedAt || Date.now() - d.savedAt > DRAFT_TTL_MS) {
        // Vencido: A LA PAPELERA, no al tacho — un borrador del viernes tiene
        // que poder rescatarse el lunes (la papelera dura 7 días).
        if (d) {
          await moverAPapeleraInterno(d, "vencido");
          await idbDel(DRAFT_KEY);
        }
        return null;
      }
      return d;
    } catch {
      return null;
    }
  });
}

function saveDraft(form: PieDeCamionCreate, lineas: LineaDraft[], carga: PlanCarga | null): Promise<void> {
  return enColaIdb(async () => {
    try {
      // AHORA guardamos también las fotos (form.fotos + defectos.fotos): IndexedDB
      // aguanta el peso y así una recarga / bloqueo de celu no las pierde.
      await idbSet(DRAFT_KEY, { form, lineas, carga, savedAt: Date.now() } satisfies Draft);
    } catch {
      /* cuota u otro → no es crítico, seguimos */
    }
  });
}

// ── Papelera de seguridad: NUNCA se borra un borrador con contenido de una.
//    Al enviar/descartar/vaciar se MUEVE a una clave con timestamp y queda 7
//    días recuperable (incidente 22/07: un pie se descartó creyendo que se
//    había enviado, y el envío nunca había llegado al server — irrecuperable).
const PAPELERA_PREFIX = "piedecamion.papelera.";
const PAPELERA_TTL_MS = 7 * 24 * 60 * 60 * 1000;
// Cupos POR MOTIVO (la poda ciega dejaba que dos envíos exitosos —backups
// livianos e inofrecibles— desalojaran al descartado valioso con fotos):
// hasta 2 "valiosos" (descartado/vaciado/vencido, completos) y 1 "enviado"
// (liviano, sin fotos). Acotado así no le come la cuota al borrador ACTIVO.
const PAPELERA_MAX_VALIOSOS = 2;
const PAPELERA_MAX_ENVIADOS = 1;

type MotivoPapelera = "enviado" | "descartado" | "vaciado" | "vencido";

/** Copia liviana de un borrador: sin fotos ni documentos (los campos pesados).
 *  Para los backups de pies ENVIADOS con éxito: el server ya tiene las fotos
 *  (van en el informe/fotos-PDF), acá solo conservamos los datos por las dudas. */
function draftSinFotos(d: Draft): Draft {
  return {
    ...d,
    form: { ...d.form, fotos: [], fotos_cat: {}, documentacion: [] },
    lineas: d.lineas.map((l) => ({
      ...l,
      defectos: l.defectos.map((df) => ({ ...df, fotos: [] })),
    })),
  };
}

/** ¿Amerita un cupo de papelera? Solo TRABAJO REAL (mercadería, fotos o
 *  documentos): un par de campos de texto tipeados y borrados no valen un
 *  cupo — los "vaciado" triviales evictaban al descartado valioso (review v2). */
function valeBackup(d: Draft): boolean {
  return !!(
    d.lineas.length ||
    d.form.fotos.length ||
    tieneFotosCat(d.form.fotos_cat) ||
    d.form.documentacion?.length
  );
}

/** Mueve `d` a la papelera y poda. SOLO llamar desde adentro de la cola
 *  (clearDraft / loadDraft) — no re-encola. Devuelve si guardó el backup. */
async function moverAPapeleraInterno(d: Draft, motivo: MotivoPapelera): Promise<boolean> {
  let guardado = false;
  try {
    if (valeBackup(d)) {
      const key = `${PAPELERA_PREFIX}${Date.now()}.${motivo}`;
      const liviano = motivo === "enviado";
      try {
        await idbSet(key, liviano ? draftSinFotos(d) : d);
        guardado = true;
      } catch {
        // Cuota llena con el backup completo → al menos salvar los DATOS
        // (chofer/placa/mercadería/cámaras) sin fotos.
        try {
          await idbSet(key, draftSinFotos(d));
          guardado = true;
        } catch { /* sin lugar ni para eso */ }
      }
    }
    // Podar por edad y por cupo POR MOTIVO (claves = prefijo + ts + motivo,
    // el sort desc deja las más nuevas primero).
    const keys = (await idbKeys(PAPELERA_PREFIX)).sort().reverse();
    let enviados = 0;
    let valiosos = 0;
    for (const k of keys) {
      const ts = Number(k.slice(PAPELERA_PREFIX.length).split(".")[0]);
      const esEnviado = k.endsWith(".enviado");
      const idx = esEnviado ? enviados++ : valiosos++;
      const cupo = esEnviado ? PAPELERA_MAX_ENVIADOS : PAPELERA_MAX_VALIOSOS;
      if (idx >= cupo || !ts || Date.now() - ts > PAPELERA_TTL_MS) await idbDel(k);
    }
  } catch { /* la papelera es best-effort, nunca bloquea el flujo */ }
  return guardado;
}

/** Último backup RECUPERABLE de la papelera (con su clave, para consumirlo al
 *  recuperar). Los `.enviado` NO se ofrecen (re-mandarían un pie duplicado);
 *  quedan guardados igual por si hay que rescatarlos a mano. */
function ultimaPapelera(): Promise<{ key: string; d: Draft } | null> {
  return enColaIdb(async () => {
    try {
      const keys = (await idbKeys(PAPELERA_PREFIX))
        .filter((k) => !k.endsWith(".enviado"))
        .sort()
        .reverse();
      // Si la más nueva está corrupta/ilegible, probar la siguiente (no rendirse).
      for (const key of keys) {
        const d = await idbGet<Draft>(key);
        if (d) return { key, d };
      }
      return null;
    } catch {
      return null;
    }
  });
}

/** Consume (borra) una clave de la papelera — al recuperarla al form. Sin esto,
 *  el banner re-ofrecía un pie que ya se había recuperado Y enviado → duplicado. */
function consumirPapelera(key: string): Promise<void> {
  return enColaIdb(async () => {
    try { await idbDel(key); } catch { /* noop */ }
  });
}

/** Mueve el borrador a la papelera y lo borra. Devuelve si movió algo. */
function clearDraft(motivo: MotivoPapelera = "enviado"): Promise<boolean> {
  return enColaIdb(async () => {
    let movio = false;
    try {
      const d = await idbGet<Draft>(DRAFT_KEY);
      if (d) movio = await moverAPapeleraInterno(d, motivo);
      await idbDel(DRAFT_KEY);
    } catch { /* noop */ }
    try { localStorage.removeItem(OLD_LS_KEY); } catch { /* noop */ }
    return movio;
  });
}

/** ¿El guardado falló por FALTA DE INTERNET (no por un error del server)?
 *  Un `fetch` sin conexión rechaza con TypeError ("Failed to fetch" en Chrome,
 *  "Load failed" en Safari/iOS, "NetworkError" en Firefox) — nunca llega al back,
 *  así que NO viene envuelto como "API <status>". Sumamos navigator.onLine como
 *  refuerzo. Sirve para mostrar un aviso claro (el trabajo ya quedó en el celu). */
function esErrorDeRed(e: Error): boolean {
  if (typeof navigator !== "undefined" && navigator.onLine === false) return true;
  if (e instanceof TypeError) return true;
  // Abort (timeout de envío o "Cancelar envío"): es DOMException, no TypeError.
  // Lo tratamos como problema de red → cartel tranquilizador + Reintentar.
  if (e.name === "AbortError") return true;
  const m = e.message.toLowerCase();
  return m.includes("failed to fetch") || m.includes("load failed") || m.includes("network") || m.includes("abort");
}

function NuevoForm({
  onSaved,
  editId,
  initialForm,
  initialLineas,
  fotosRequisitoPrevias,
  onCancel,
}: {
  onSaved: () => void;
  /** Si está seteado → modo EDICIÓN de ese pie (no borrador, submit por PUT). */
  editId?: number;
  initialForm?: PieDeCamionCreate;
  initialLineas?: LineaDraft[];
  /** Edición: requisitos-foto que el pie ya tiene (cuentan como cumplidos). */
  fotosRequisitoPrevias?: Set<number>;
  onCancel?: () => void;
}) {
  const isEdit = editId != null;
  const qc = useQueryClient();
  const [form, setForm] = useState<PieDeCamionCreate>(
    () => initialForm ?? { ...EMPTY, fecha: todayISO(), hora_inicio: nowHHMM(), lineas: [], client_ref: crypto.randomUUID() },
  );
  const [lineas, setLineas] = useState<LineaDraft[]>(() => initialLineas ?? []);
  // Depósito de ingreso: UNO para todo el camión (antes se elegía en cada línea,
  // que era ruido: un camión descarga en un solo lado). Vive acá arriba para que
  // sea la única fuente de verdad del envío — que la elección no pueda quedar
  // desincronizada de las líneas (ej. líneas pre-cargadas desde el Plan).
  const [depositoIngreso, setDepositoIngreso] = useState<string>(
    () => depositoDeLineas(initialLineas),
  );
  const [error, setError] = useState<string | null>(null);
  // Validación de campos obligatorios. `intentoEnvio` se prende al primer
  // Guardar: recién ahí se pintan los faltantes (no molestamos mientras carga).
  // Desde ese momento la lista se recalcula EN VIVO y se va achicando sola.
  const [intentoEnvio, setIntentoEnvio] = useState(false);
  // Errores de coherencia del reparto por cámaras: no son "falta completar X"
  // sino "esto no cierra", pero van por la misma UI (lista tocable).
  const [otroError, setOtroError] = useState<Falta | null>(null);
  // Se separa del `error` normal: si el guardado falló por falta de señal,
  // mostramos un cartel tranquilizador + botón Reintentar (el borrador con las
  // fotos ya quedó guardado en el celu; no se pierde nada).
  const [sinInternet, setSinInternet] = useState(false);
  // Si el usuario eligió una carga del plan, la guardamos para mostrarla
  // arriba; el id va a form.plan_carga_id para que el back marque la carga
  // como Descargado al guardar el pie de camión.
  const [cargaSeleccionada, setCargaSeleccionada] = useState<PlanCarga | null>(null);
  const [viajeARecibir, setViajeARecibir] = useState<ViajePendienteRecepcion | null>(null);
  const [resultadoViaje, setResultadoViaje] = useState<RecepcionViajeResultado | null>(null);
  // Aviso no-bloqueante si algún producto del plan no se pudo mapear a un artículo.
  const [avisoCarga, setAvisoCarga] = useState<string | null>(null);
  // Cartel "recuperamos lo que estabas cargando" (sólo si el borrador tenía algo).
  const [restaurado, setRestaurado] = useState(false);
  // El borrador se lee de IndexedDB (async). Hasta que termine, NO guardamos (para
  // no pisar el borrador con el form vacío inicial).
  const [draftReady, setDraftReady] = useState(false);

  // ¿Hay un backup en la papelera para ofrecer "Recuperar"? Se muestra CON los
  // datos del pie (placa/chofer/cuándo): los celus son compartidos y el backup
  // puede ser de otro turno — el operario tiene que poder reconocerlo.
  const [papeleraInfo, setPapeleraInfo] = useState<{ placa: string; chofer: string; cuando: string } | null>(null);

  async function refrescarPapelera() {
    const p = await ultimaPapelera();
    if (!p) { setPapeleraInfo(null); return; }
    // Fecha del TRABAJO (savedAt), no del movimiento a papelera: un borrador
    // del viernes movido el lunes por vencido tiene que decir "viernes".
    const f = p.d.savedAt ? new Date(p.d.savedAt) : null;
    setPapeleraInfo({
      placa: p.d.form.placa_camion?.trim() || "sin placa",
      chofer: p.d.form.chofer_nombre?.trim() || "sin chofer",
      cuando: f
        ? `${String(f.getDate()).padStart(2, "0")}/${String(f.getMonth() + 1).padStart(2, "0")} ${String(f.getHours()).padStart(2, "0")}:${String(f.getMinutes()).padStart(2, "0")}`
        : "",
    });
  }

  // Cargar el borrador (IndexedDB, con fotos) al montar. 1 sola vez. En EDICIÓN no
  // hay borrador (los datos vienen del pie) → no lo tocamos.
  useEffect(() => {
    if (isEdit) { setDraftReady(true); return; }
    let alive = true;
    loadDraft().then((d) => {
      if (!alive) return;
      if (d) {
        setForm(d.form);
        setLineas(d.lineas);
        setDepositoIngreso(depositoDeLineas(d.lineas));
        setCargaSeleccionada(d.carga);
        setRestaurado(tieneContenido(d.form, d.lineas));
      }
      if (!d || !tieneContenido(d.form, d.lineas)) {
        void refrescarPapelera().then(() => { if (!alive) setPapeleraInfo(null); });
      }
      setDraftReady(true);
    });
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isEdit]);

  async function recuperarDePapelera() {
    // Matar el debounce "vaciado" pendiente del form vacío: si disparara después
    // del saveDraft de acá abajo, borraría el borrador recién restaurado.
    invalidarDraftPendiente();
    const p = await ultimaPapelera();
    if (!p) { setPapeleraInfo(null); return; }
    // ORDEN CRÍTICO: primero persistir lo recuperado como borrador ACTIVO y
    // recién después consumir la clave de papelera (ambas encoladas en orden).
    // Al revés había una ventana de ~400ms (hasta el debounce) donde un reload
    // de FKB dejaba el pie sin copia en NINGÚN lado (review v2).
    await saveDraft(p.d.form, p.d.lineas, p.d.carga);
    await consumirPapelera(p.key);
    // CONSUMIR evita que el banner re-ofrezca un pie ya recuperado/enviado
    // (→ duplicado). Lo recuperado ya es el borrador activo: no se pierde.
    setForm(p.d.form);
    setLineas(p.d.lineas);
    setDepositoIngreso(depositoDeLineas(p.d.lineas));
    setCargaSeleccionada(p.d.carga);
    setRestaurado(true);
    setPapeleraInfo(null);
  }


  // Persistimos el borrador (CON fotos) en cada cambio, debounced (evita reescribir
  // megabytes en cada tecla). Si el form queda vacío, borramos el borrador. En
  // EDICIÓN NO persistimos (para no pisar el borrador del "nuevo registro").
  //
  // ÉPOCA + ref del timer: un timer vencido mientras window.confirm bloqueaba el
  // hilo (o mientras resolvía el POST) disparaba DESPUÉS del clearDraft de
  // resetForm/onSuccess y RESUCITABA el draft con el closure viejo (review v2).
  // resetForm/onSuccess suben la época y matan el timer pendiente; si igual
  // llegara a correr, el chequeo de época lo hace no-op.
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const epocaDraftRef = useRef(0);
  function invalidarDraftPendiente() {
    epocaDraftRef.current++;
    if (debounceRef.current) clearTimeout(debounceRef.current);
  }
  useEffect(() => {
    if (isEdit || !draftReady) return;
    const epoca = epocaDraftRef.current;
    const t = setTimeout(() => {
      if (epoca !== epocaDraftRef.current) return; // reset/envío invalidó este contenido
      if (tieneContenido(form, lineas)) void saveDraft(form, lineas, cargaSeleccionada);
      else void clearDraft("vaciado").then((movio) => { if (movio) void refrescarPapelera(); });
    }, 400);
    debounceRef.current = t;
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form, lineas, cargaSeleccionada, draftReady]);

  // Confirmación SIEMPRE que haya contenido (Descartar y Limpiar eran un solo
  // toque — así se perdió un pie el 22/07). Igual va a la papelera por 7 días.
  // OJO con el texto: NO decir "si ya lo guardaste está en el Historial" como
  // afirmación — la creencia "seguro ya se mandó" fue exactamente lo que causó
  // el incidente. El texto manda a VERIFICAR primero.
  async function resetForm() {
    if (
      tieneContenido(form, lineas) &&
      !window.confirm(
        "¿Borrar todo lo cargado (fotos incluidas)?\n\nOJO: si creés que este pie ya se envió, tocá Cancelar y andá al Historial a confirmar que aparezca. Si no aparece, NO borres: tocá Guardar de nuevo.",
      )
    )
      return;
    invalidarDraftPendiente();
    await clearDraft("descartado");
    setForm({ ...EMPTY, fecha: todayISO(), hora_inicio: nowHHMM(), lineas: [], client_ref: crypto.randomUUID() });
    setLineas([]);
    setDepositoIngreso(DEPOSITO_INGRESO_DEFAULT);   // el camión siguiente arranca del predeterminado
    setIntentoEnvio(false);
    setOtroError(null);
    setCargaSeleccionada(null);
    setAvisoCarga(null);
    setRestaurado(false);
    // El banner "Recuperar" tiene que aparecer YA (antes solo se calculaba al
    // montar): si descartaron por error, el camino de vuelta está a la vista.
    void refrescarPapelera();
  }

  function update<K extends keyof PieDeCamionCreate>(key: K, value: PieDeCamionCreate[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  // ¿Ya se imprimieron etiquetas Zebra para este camión? La clave es placa +
  // fecha de descarga (lo mismo que identifica al camión en el QR). Si las hay,
  // el código de importador se pre-carga solo: antes se tipeaba en la PC para
  // imprimir y OTRA VEZ en el celular, y cuando no coincidían el QR de la
  // etiqueta apuntaba a un código que el pie no tenía.
  const placaBusqueda = (form.placa_camion ?? "").trim().toUpperCase();
  const { data: etiqueta, refetch: refetchEtiqueta } = useQuery({
    queryKey: ["etiqueta-camion", placaBusqueda, form.fecha],
    queryFn: () => getEtiquetaCamion(placaBusqueda, form.fecha),
    enabled: placaBusqueda.length >= 4 && !!form.fecha,
    staleTime: 30_000,
  });

  // Pre-carga: sólo si el campo está VACÍO — nunca pisamos lo que el operario
  // tipeó. En edición tampoco (el pie ya tiene su código guardado).
  const etiquetaAplicadaRef = useRef<string | null>(null);
  useEffect(() => {
    if (isEdit || !etiqueta?.codigo) return;
    const clave = `${etiqueta.placa}|${etiqueta.fecha}|${etiqueta.codigo}`;
    if (etiquetaAplicadaRef.current === clave) return;
    if ((form.codigo_importador_camion ?? "").trim()) return;
    etiquetaAplicadaRef.current = clave;
    setForm((prev) =>
      (prev.codigo_importador_camion ?? "").trim()
        ? prev
        : { ...prev, codigo_importador_camion: etiqueta.codigo },
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [etiqueta, isEdit]);

  // Requisitos por fruta del ing. agrónomo (mig 0092): el back resuelve qué
  // frutas hay a partir de los cod_art de la mercadería. Best-effort: si no
  // hay señal la sección no aparece (el back valida igual al guardar).
  const codsRequisitos = useMemo(
    () => Array.from(new Set(lineas.map((l) => l.cod_art))).sort().join(","),
    [lineas],
  );
  const requisitosQuery = useQuery({
    queryKey: ["pie-requisitos", "aplicables", codsRequisitos],
    queryFn: () => getRequisitosAplicables(codsRequisitos.split(",")),
    enabled: codsRequisitos.length > 0,
  });
  const gruposRequisitos = useMemo(
    () => (codsRequisitos.length > 0 ? requisitosQuery.data ?? [] : []),
    [requisitosQuery.data, codsRequisitos],
  );

  // Lo que falta, recalculado en vivo. Vacío hasta el primer intento de guardar.
  const faltantesLive = useMemo(
    () => faltantesDelPie(form, lineas, isEdit, gruposRequisitos, fotosRequisitoPrevias),
    [form, lineas, isEdit, gruposRequisitos, fotosRequisitoPrevias],
  );
  const faltantes = intentoEnvio ? faltantesLive : [];
  const faltaIds = useMemo(
    () => new Set([...faltantes.map((f) => f.id), ...(otroError ? [otroError.id] : [])]),
    [faltantes, otroError],
  );
  useEffect(() => { setOtroError(null); }, [form.camaras, lineas]);
  /** Error de coherencia del reparto por cámaras (se usa como `return faltaCamara(...)`). */
  function faltaCamara(msg: string) {
    setOtroError({ id: "f-camaras", que: msg });
    irAlCampo("f-camaras");
  }

  /** Respuesta a "¿Hay reclamos para esta fruta?". Al pasar a NO con defectos ya
   *  marcados hay que limpiarlos (si no, el back generaría el reclamo igual y la
   *  respuesta sería mentira). Se avisa porque se pierden las fotos sacadas. */
  function setHayReclamosLinea(idx: number, valor: boolean) {
    const marcados = lineas[idx]?.defectos.length ?? 0;
    if (!valor && marcados > 0) {
      if (!window.confirm(
        `Este producto tiene ${marcados} defecto${marcados === 1 ? "" : "s"} marcado${marcados === 1 ? "" : "s"} (con sus fotos).\n\n` +
        "Si respondés que NO hay reclamos se borran. ¿Seguro?",
      )) return;
    }
    setLineas((prev) =>
      prev.map((l, i) =>
        i === idx ? { ...l, hay_reclamos: valor, defectos: valor ? l.defectos : [] } : l,
      ),
    );
  }

  // Setea las fotos de UNA categoría. Funcional (lee prev.fotos_cat) para que
  // subir a dos categorías seguidas no se pise entre re-renders.
  function setFotoSlot(slug: string, fotos: string[]) {
    setForm((prev) => ({ ...prev, fotos_cat: { ...(prev.fotos_cat ?? {}), [slug]: fotos } }));
  }

  /** Trae los productos que el plan dice que carga el camión y arma las líneas
   *  de mercadería. Sólo si todavía no hay líneas (no pisa lo que el operario
   *  ya cargó). Con cod_art arma la línea directo; los productos importados del
   *  Drive (texto) los resuelve buscando el artículo por descripción. */
  async function poblarLineasDesdePlan(carga: PlanCarga) {
    const prods = carga.productos ?? [];
    if (prods.length === 0) return;
    const nuevas: LineaDraft[] = [];
    const faltan: string[] = [];
    for (const p of prods) {
      let cod = p.cod_art;
      let desc = p.descripcion;
      if (!cod && p.descripcion.trim()) {
        try {
          const res = await searchArticulos({ search: p.descripcion, mode: "descripcion", limit: 5 });
          const m = res.find((a) => a.descripcion.trim().toLowerCase() === p.descripcion.trim().toLowerCase()) ?? res[0];
          if (m) { cod = m.cod; desc = m.descripcion; }
        } catch { /* si la búsqueda falla lo tratamos como no encontrado */ }
      }
      if (!cod) { faltan.push(p.descripcion); continue; }
      nuevas.push({
        cod_art: cod,
        descripcion: desc,
        icono: p.icono,
        // Con UN solo producto la cantidad planificada (cajas MIC) es de esa
        // línea. Con varios, el plan no tiene cajas por producto → queda en 0 y
        // el operario las completa (la cantidad es editable en la lista).
        cantidad: prods.length === 1 && carga.cajas_mic ? carga.cajas_mic : 0,
        // La marca de línea YA NO se auto-llena con el productor: el productor ahora
        // tiene su propio campo. La marca queda para el grado del producto si aplica.
        marca: null,
        // El depósito elegido, para que el borrador lo recuerde: si el celu se
        // recarga después de importar del Plan, al restaurar el selector vuelve
        // a mostrar lo que el operario había elegido (y no el predeterminado).
        deposito: depositoIngreso,
        defectos: [],
      });
    }
    if (nuevas.length) setLineas(nuevas);
    setAvisoCarga(
      faltan.length
        ? `No se encontró el artículo de: ${faltan.join(", ")}. Agregalo a mano en Mercadería.`
        : null,
    );
  }

  /** Auto-fill del form a partir de la carga del Plan. Mantenemos lo que
   *  el usuario ya tipeó (no piso campos no vacíos). */
  function aplicarCarga(carga: PlanCarga | null) {
    const removida = cargaSeleccionada;   // la que estaba puesta (para limpiar al quitar)
    setCargaSeleccionada(carga);
    setAvisoCarga(null);
    if (!carga) {
      // Al QUITAR el camión: limpiar los campos que trajo el plan, PERO sólo los que
      // el operario NO editó a mano (siguen iguales a lo que puso el plan). No toca
      // la mercadería (líneas).
      setForm((prev) => {
        const eq = (a?: string | null, b?: string | null) =>
          (a ?? "").trim().toUpperCase() === (b ?? "").trim().toUpperCase();
        const next: PieDeCamionCreate = { ...prev, plan_carga_id: null };
        if (removida) {
          if (eq(prev.chofer_nombre, removida.chofer)) next.chofer_nombre = "";
          if (eq(prev.placa_camion, removida.placa_camion)) next.placa_camion = "";
          if (eq(prev.exportador, removida.exportador)) next.exportador = null;
          if (eq(prev.productor, removida.productor)) next.productor = null;
          if (eq(prev.empresa_transporte, removida.transportista)) next.empresa_transporte = null;
          if (eq(prev.numero_afidi, removida.afidi)) next.numero_afidi = null;
        }
        return next;
      });
      return;
    }
    setForm((prev) => ({
      ...prev,
      plan_carga_id: carga.id,
      // Sólo pisamos campos vacíos — respetamos lo que ya tipeó el operario.
      chofer_nombre: prev.chofer_nombre || carga.chofer || "",
      placa_camion: prev.placa_camion || carga.placa_camion || "",
      exportador: prev.exportador || carga.exportador || null,
      productor: prev.productor || carga.productor || null,
      empresa_transporte: prev.empresa_transporte || carga.transportista || null,
      numero_afidi: prev.numero_afidi || carga.afidi || null,
      // OJO: el "código importador / camión" NO es la carpeta de importación del
      // plan — son cosas distintas. Por ahora se carga a mano (a futuro se
      // autogenera), así que NO lo traemos del plan.
      // La fecha de descarga NO se toca: es el día en que se hace el pie, ni
      // antes ni después (dueño 1/09). El plan trae una fecha ESTIMADA que con
      // los camiones de tránsito largo casi siempre está vieja —Bolivia demora
      // de 5 a 12 días— y pisarla con eso mandaba el ingreso a un día ya
      // cerrado, ahora que el pie escribe el movimiento en Macrosoft.
    }));
    // Sólo poblamos las líneas si todavía no hay (no pisamos lo cargado a mano).
    if (lineas.length === 0) void poblarLineasDesdePlan(carga);
  }

  // Timeout del envío: el fetch pelado puede colgar >10 min con wifi degradado
  // (TCP estancado) y el operario quedaba ATRAPADO en el overlay. Se aborta solo
  // con un timeout ADAPTATIVO al peso (3 min base + ~1s por cada 10KB de fotos,
  // tope 10 min — un timeout fijo mataba envíos grandes legítimos y los mandaba
  // a un loop de Reintentar). El botón "Cancelar envío" (a los 45s) usa el mismo
  // AbortController. Abort → esErrorDeRed → cartel "quedó guardado, reintentá".
  // Reintentar es seguro: el client_ref hace el POST idempotente (mig 0058).
  const abortRef = useRef<AbortController | null>(null);
  const envioBytesRef = useRef(0);

  const recepcionMut = useMutation({
    mutationFn: (body: Parameters<typeof confirmarRecepcionViaje>[1]) =>
      confirmarRecepcionViaje(viajeARecibir!.id, body),
    onSuccess: (out) => setResultadoViaje(out),
    onError: (e: Error) => setError(e.message),
  });

  const mut = useMutation({
    mutationFn: (body: PieDeCamionCreate) => {
      const ctrl = new AbortController();
      abortRef.current = ctrl;
      // bytes/10 = ms → presupuesto de ~10KB/s (peor caso de wifi degradado).
      const timeoutMs = Math.min(10 * 60_000, 3 * 60_000 + Math.round(envioBytesRef.current / 10));
      const t = setTimeout(() => ctrl.abort(), timeoutMs);
      const req = isEdit ? editarPieCamion(editId!, body, ctrl.signal) : createPieCamion(body, ctrl.signal);
      return req.finally(() => clearTimeout(t));
    },
    onSuccess: async () => {
      qc.invalidateQueries({ queryKey: ["pie-camion"] });
      qc.invalidateQueries({ queryKey: ["pie-camion-pendientes"] });
      qc.invalidateQueries({ queryKey: ["pie-camion-detail", editId] });
      if (isEdit) {
        onSaved();   // en edición no limpiamos el borrador del nuevo registro
        return;
      }
      // AWAIT a propósito: el borrador tiene que estar movido/borrado ANTES de
      // resetear el form y saltar al Historial — si no, el debounce o un
      // remount podían leer el draft viejo y resucitarlo (review 22/07).
      invalidarDraftPendiente();
      await clearDraft("enviado");
      setForm({ ...EMPTY, fecha: todayISO(), hora_inicio: nowHHMM(), lineas: [], client_ref: crypto.randomUUID() });
      setLineas([]);
      setDepositoIngreso(DEPOSITO_INGRESO_DEFAULT);
      setIntentoEnvio(false);
      setOtroError(null);
      setCargaSeleccionada(null);
      setRestaurado(false);
      onSaved();
    },
    onError: (e: Error) => {
      if (esErrorDeRed(e)) {
        // Sin señal: NO mostramos el error técnico. El form + fotos ya están en
        // el borrador (IndexedDB); avisamos claro y ofrecemos Reintentar.
        setSinInternet(true);
        setError(null);
      } else {
        setSinInternet(false);
        setError(e.message);
      }
    },
  });

  // Mientras SUBE (upload pesado de fotos): pedir que la pantalla NO se apague.
  // Los FKB recargan la página al prenderse la pantalla (reloadOnScreenOn) y eso
  // mató un envío a mitad de camino el 22/07 (el POST nunca llegó al server).
  // WakeLock es best-effort (Chrome/WebView 84+); se suelta al terminar. El flag
  // `activo` evita el leak: si el request() resuelve DESPUÉS del cleanup (envío
  // rapidísimo o error inmediato), se libera al toque en vez de quedar tomado.
  useEffect(() => {
    if (!mut.isPending) return;
    let activo = true;
    let lock: { release?: () => Promise<void> } | null = null;
    const wl = (navigator as Navigator & { wakeLock?: { request: (t: string) => Promise<typeof lock> } }).wakeLock;
    wl?.request("screen")
      .then((l) => {
        if (activo) lock = l;
        else void l?.release?.().catch(() => { /* noop */ });
      })
      .catch(() => { /* sin soporte → nada */ });
    return () => {
      activo = false;
      void lock?.release?.().catch(() => { /* noop */ });
    };
  }, [mut.isPending]);

  // "Cancelar envío": aparece a los 45s de upload — la salida de emergencia si
  // el POST quedó colgado (antes el overlay era una trampa sin escape y la única
  // salida era bloquear el celu, justo lo que el texto prohíbe).
  const [puedeCancelarEnvio, setPuedeCancelarEnvio] = useState(false);
  useEffect(() => {
    if (!mut.isPending) { setPuedeCancelarEnvio(false); return; }
    const t = setTimeout(() => setPuedeCancelarEnvio(true), 45_000);
    return () => clearTimeout(t);
  }, [mut.isPending]);

  function submit() {
    setError(null);
    setSinInternet(false);
    setOtroError(null);
    // RECEPCIÓN CIEGA DE VIAJE (26/08): el pie sigue normal pero el envío NO
    // crea un pie — compara lo cargado contra lo declarado por CR en el 190.
    // Solo exige mercadería; cámara/fotos/observaciones como siempre.
    if (viajeARecibir) {
      if (lineas.length === 0)
        return setError("Cargá los productos que llegaron en el viaje.");
      if (lineas.some((l) => !(l.cantidad > 0)))
        return setError("Hay un producto sin cantidad.");
      const camarasV = (form.camaras ?? []).filter(
        (c) => c.numero != null && !Number.isNaN(c.numero),
      );
      const camaraDe = (cod: string): number | null =>
        camarasV.find((c) => (c.cod_art ?? "") === cod)?.numero ??
        (camarasV.length >= 1 ? camarasV[0].numero : null);
      recepcionMut.mutate({
        lineas: lineas.map((l) => ({
          cod_art: l.cod_art,
          cantidad: l.cantidad,
          camara_numero: camaraDe(l.cod_art),
        })),
        observaciones: form.observaciones || null,
        fotos: [...form.fotos, ...Object.values(form.fotos_cat ?? {}).flat()],
      });
      return;
    }
    // Se muestra TODO lo que falta junto (no el primer error nada más) y la lista
    // queda tocable: cada ítem salta a su campo. A partir de acá se recalcula en
    // vivo, así el operario ve la lista achicarse mientras completa.
    setIntentoEnvio(true);
    // OJO: `faltantesLive`, no `faltantes` — este último depende de `intentoEnvio`,
    // que en este render todavía vale false (el setState de arriba recién impacta
    // en el próximo). Mirándolo se guardaría un pie incompleto en el primer click.
    if (faltantesLive.length > 0) {
      irAlCampo(faltantesLive[0].id);
      return;
    }
    // total_cajas: si el user lo seteó manual (form.total_cajas != null) lo
    // respetamos. Si no, lo derivamos de la suma de líneas.
    const totalCajas =
      form.total_cajas != null
        ? form.total_cajas
        : lineas.length
          ? Math.round(lineas.reduce((s, l) => s + l.cantidad, 0))
          : null;
    // Cámaras. En modo simple (1 fila) es opcional: sin número → va vacío. En
    // REPARTO una fila a medias (con producto o cajas pero sin Cámara N°) NO se
    // descarta en silencio: con el desglose pre-armado es fácil olvidar un número
    // y esa asignación se perdería sin aviso.
    const camarasTodas = form.camaras ?? [];
    if (
      camarasTodas.length > 1 &&
      camarasTodas.some(
        (c) =>
          (c.numero == null || Number.isNaN(c.numero)) &&
          (c.cod_art || (c.cantidad != null && !Number.isNaN(c.cantidad))),
      )
    )
      return faltaCamara("En el reparto hay una cámara sin número. Completalo o quitá esa fila.");
    const camaras = camarasTodas.filter((c) => c.numero != null && !Number.isNaN(c.numero));
    for (const c of camaras) {
      const tope = CAMARAS_POR_UBICACION[c.ubicacion];
      if (c.numero < 1 || c.numero > tope)
        return faltaCamara(`Cámara ${c.ubicacion} ${c.numero}: en ${c.ubicacion} el número va de 1 a ${tope}.`);
    }
    // Si es una sola cámara, la cantidad va null (= todas las cajas) y sin producto
    // (va todo). En reparto, sólo cantidades > 0 (0/vacío/NaN → null; el back exige
    // cajas >= 1) y con el desglose por producto:
    //  - varios productos → cada fila tiene que decir QUÉ producto fue a esa cámara.
    //  - un solo producto → se asigna solo (sin molestar al operario).
    const codsDistintos = [...new Set(lineas.map((l) => l.cod_art.trim()).filter(Boolean))];
    // Asignaciones huérfanas: si se quitó esa línea de mercadería DESPUÉS de armar el
    // reparto, el producto ya no existe → se limpia (y con varios productos, la
    // validación de abajo pide re-elegir en vez de un error críptico del server).
    const camarasSan = camaras.map((c) =>
      c.cod_art && !codsDistintos.includes(c.cod_art) ? { ...c, cod_art: null } : c,
    );
    // Con varios productos, el reparto tiene que decir qué producto fue a cada
    // cámara. EXCEPCIÓN: editar un pie VIEJO (reparto anterior al desglose, sin
    // producto en NINGUNA fila) — no se obliga a retro-asignar para poder corregir
    // cualquier otro campo; si se toca alguna fila, ahí sí se pide completo.
    const sinProducto = camarasSan.filter((c) => !c.cod_art).length;
    const repartoLegacy = isEdit && sinProducto === camarasSan.length;
    if (camarasSan.length > 1 && codsDistintos.length > 1 && sinProducto > 0 && !repartoLegacy)
      return faltaCamara("En el reparto por cámaras falta elegir qué producto fue a cada cámara.");
    // En reparto cada fila necesita sus cajas: una fila sin cajas no dice nada y el
    // aviso a maduración saldría con cantidades infladas. (En un reparto legacy que
    // solo se está corrigiendo, no se exige retro-completar.)
    if (
      camarasSan.length > 1 &&
      !repartoLegacy &&
      camarasSan.some((c) => c.cantidad == null || Number.isNaN(c.cantidad) || c.cantidad <= 0)
    )
      return faltaCamara("En el reparto hay una cámara sin cajas. Poné cuántas cajas fueron a cada una.");
    // TODAS las cajas tienen que quedar asignadas a alguna cámara (regla nueva) al
    // CREAR un pie: no se guarda con cajas sin cámara. En modo simple (1 cámara) va
    // todo ahí (OK); en reparto la suma tiene que cerrar (por producto si hay varios).
    // Sólo al crear — editar un pie viejo NO se bloquea (puede traer datos legacy);
    // igual los chips del reparto muestran en vivo si algo no cierra.
    if (!isEdit && camarasSan.length === 0)
      return faltaCamara("Asigná las cajas a una cámara de maduración antes de guardar.");
    if (!isEdit && camarasSan.length > 1) {
      const prods = productosDeLineas(lineas);
      if (prods.length > 1) {
        // Varios productos: cada uno tiene que estar completamente asignado.
        for (const p of prods) {
          const asig = camarasSan.reduce(
            (s, c) => s + (c.cod_art === p.cod_art && c.cantidad != null && !Number.isNaN(c.cantidad) ? c.cantidad : 0),
            0,
          );
          const falta = Math.round(p.total) - asig;
          if (falta > 0)
            return faltaCamara(`Faltan asignar ${falta} caja${falta === 1 ? "" : "s"} de ${nombreCortoProducto(p.descripcion)} a una cámara.`);
          if (falta < 0)
            return faltaCamara(`Asignaste ${-falta} caja${falta === -1 ? "" : "s"} de más de ${nombreCortoProducto(p.descripcion)}. Revisá el reparto.`);
        }
      } else {
        // Un solo producto: la suma total tiene que cerrar con el total de cajas.
        const asignado = camarasSan.reduce(
          (s, c) => s + (c.cantidad != null && !Number.isNaN(c.cantidad) ? c.cantidad : 0),
          0,
        );
        const falta = totalCajas != null ? Math.round(totalCajas) - asignado : 0;
        if (falta > 0)
          return faltaCamara(`Faltan asignar ${falta} caja${falta === 1 ? "" : "s"} a una cámara.`);
        if (falta < 0)
          return faltaCamara(`Asignaste ${-falta} caja${falta === -1 ? "" : "s"} de más. Revisá el reparto.`);
      }
    }
    const camarasClean: CamaraInput[] =
      camarasSan.length <= 1
        ? camarasSan.map((c) => ({ ubicacion: c.ubicacion, numero: c.numero, cantidad: null, cod_art: null }))
        : camarasSan.map((c) => ({
            ubicacion: c.ubicacion,
            numero: c.numero,
            cantidad: c.cantidad != null && !Number.isNaN(c.cantidad) && c.cantidad > 0 ? c.cantidad : null,
            cod_art: c.cod_art ?? (codsDistintos.length === 1 ? codsDistintos[0] : null),
          }));
    // Todas las imágenes (fotos del camión + documentación + fotos de defectos)
    // viajan en UN solo POST. Si el total supera lo que el server acepta, cortamos
    // acá con un mensaje claro en vez de que nginx tire un 413 incomprensible.
    // (data URI base64 → largo del string ≈ bytes que se mandan.)
    const MAX_ENVIO = 45 * 1024 * 1024; // nginx permite 50m; dejamos margen p/ el JSON
    const fotosCatFlat = Object.values(form.fotos_cat ?? {}).flat();
    const bytesImgs =
      [...form.fotos, ...fotosCatFlat, ...(form.documentacion ?? [])].reduce((s, d) => s + d.length, 0) +
      lineas.reduce((s, l) => s + l.defectos.reduce((s2, d) => s2 + d.fotos.reduce((s3, f) => s3 + f.length, 0), 0), 0);
    if (bytesImgs > MAX_ENVIO)
      return setError("Hay demasiadas fotos y el envío es muy pesado. Quitá algunas fotos (o documentos) y probá de nuevo.");
    envioBytesRef.current = bytesImgs; // para el timeout adaptativo del envío
    // Idempotencia: garantizar el client_ref ANTES de mandar (borradores viejos
    // de antes de esta feature no lo traen). Queda en el state → un Reintentar
    // re-manda el MISMO ref y el back devuelve el pie existente si ya entró.
    const clientRef = form.client_ref || crypto.randomUUID();
    if (!form.client_ref) update("client_ref", clientRef);
    // Requisitos por fruta: respuestas no-vacías + fotos de requisitos (van en
    // fotos_categoria con slug `req-<id>` y su etiqueta legible para el PDF).
    const requisitosPayload = Object.entries(form.requisitos_valores ?? {})
      .map(([id, valor]) => ({ requisito_id: Number(id), valor: valor.trim() || null }))
      .filter((r) => r.valor !== null);
    const fotosRequisitos = gruposRequisitos.flatMap((grupo) =>
      grupo.requisitos
        .filter((r) => r.tipo === "foto")
        .flatMap((r) =>
          (form.fotos_cat?.[`req-${r.id}`] ?? []).map((foto) => ({
            categoria: `req-${r.id}`,
            label: `${grupo.categoria} — ${r.etiqueta}`,
            foto,
          })),
        ),
    );
    mut.mutate({
      ...form,
      client_ref: clientRef,
      total_cajas: totalCajas,
      camaras: camarasClean,
      // Los working stores NO se mandan; se transforman al contrato del back.
      fotos_cat: undefined,
      requisitos_valores: undefined,
      requisitos: requisitosPayload,
      fotos_categoria: [...buildFotosCategoria(form.fotos_cat), ...fotosRequisitos],
      lineas: lineas.map((l) => ({
        cod_art: l.cod_art,
        cantidad: l.cantidad,
        marca: l.marca ?? null,
        // Un solo depósito para todo el camión: el del selector, siempre —
        // nunca el que traiga la línea (una línea pre-cargada del Plan no lo
        // trae, y ahí el envío no puede contradecir lo que se ve en pantalla).
        deposito: depositoIngreso,
        // La respuesta va POR LÍNEA (mig 0072). El back deriva la del pie
        // (= true si alguna fruta tiene reclamo) y valida la coherencia.
        hay_reclamos: l.hay_reclamos ?? null,
        defectos: l.defectos,
      })),
    });
  }

  // Total de cajas EN VIVO (para el chequeo de reparto por cámara): el manual si
  // el usuario lo seteó, si no la suma de líneas.
  const totalCajasActual =
    form.total_cajas != null
      ? form.total_cajas
      : lineas.length
        ? Math.round(lineas.reduce((s, l) => s + l.cantidad, 0))
        : null;

  return (
    <div className="space-y-4 pb-24 sm:pb-0">
      {isEdit && (
        <div className="px-3 py-2.5 rounded-md bg-amber-50 border border-amber-200 flex items-start justify-between gap-3">
          <div>
            <div className="text-sm font-semibold text-amber-900">Editando pie #{editId}</div>
            <div className="text-xs text-amber-800 mt-0.5">
              Las fotos, la documentación y los reclamos se conservan. El informe (PDF) se re-genera con los cambios.
            </div>
          </div>
          {onCancel && (
            <button type="button" onClick={onCancel} className="text-xs font-semibold text-slate-600 hover:text-slate-900 underline whitespace-nowrap shrink-0">
              Cancelar
            </button>
          )}
        </div>
      )}
      {restaurado && !isEdit && (
        <div className="px-3 py-2.5 rounded-md bg-pepe-blue/10 border border-pepe-blue/30 text-sm text-pepe-blue-dark flex items-center justify-between gap-3">
          <span>Recuperamos lo que estabas cargando.</span>
          <button type="button" onClick={resetForm} className="text-xs font-semibold underline whitespace-nowrap shrink-0">
            Descartar
          </button>
        </div>
      )}
      {/* Papelera: si el form está vacío pero hay una copia de seguridad
          recuperable (descartado/vaciado/vencido, 7 días), ofrecer traerla —
          identificada con placa/chofer/fecha (los celus son compartidos). */}
      {papeleraInfo && !restaurado && !isEdit && !tieneContenido(form, lineas) && (
        <div className="px-3 py-2.5 rounded-md bg-slate-100 border border-pepe-border text-sm text-slate-700 flex items-center justify-between gap-3">
          <span>
            Hay una copia de seguridad: <strong>{papeleraInfo.placa}</strong> · {papeleraInfo.chofer}
            {papeleraInfo.cuando && <span className="text-slate-500"> · {papeleraInfo.cuando}</span>}
          </span>
          <span className="shrink-0 flex items-center gap-2">
            <button
              type="button"
              onClick={() => void recuperarDePapelera()}
              className="px-3 py-2 rounded border border-pepe-border bg-white text-sm font-semibold text-pepe-blue hover:bg-slate-50"
            >
              Recuperar
            </button>
            <button
              type="button"
              onClick={() => setPapeleraInfo(null)}
              title="Ocultar este aviso (la copia queda guardada 7 días)"
              className="px-2.5 py-2 rounded text-sm text-slate-500 hover:bg-slate-200"
            >
              Ocultar
            </button>
          </span>
        </div>
      )}
      {/* Candado visual durante el envío: el upload de fotos puede tardar y si
          bloquean el celu, FKB recarga al desbloquear y mata el POST (22/07).
          A los 45s aparece "Cancelar envío" (salida si el POST quedó colgado);
          a los 3 min el envío se aborta solo (timeout del AbortController). */}
      {mut.isPending && (
        <div className="fixed inset-0 z-[100] bg-white/90 flex flex-col items-center justify-center gap-4 p-6 text-center">
          <svg className="w-12 h-12 text-pepe-blue animate-spin" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" d="M12 3a9 9 0 019 9" />
          </svg>
          <div className="text-lg font-bold text-slate-900">
            {isEdit ? "Guardando los cambios…" : "Enviando el pie de camión…"}
          </div>
          <div className="text-sm text-slate-600 max-w-xs">
            Las fotos pueden tardar en subir. <strong>No bloquees el celu ni salgas de la página</strong> hasta que termine.
          </div>
          {puedeCancelarEnvio && (
            <button
              type="button"
              onClick={() => abortRef.current?.abort()}
              className="mt-2 px-4 py-2.5 rounded border border-pepe-border bg-white text-sm font-semibold text-slate-700 hover:bg-slate-50"
            >
              Está tardando mucho — cancelar envío
            </button>
          )}
        </div>
      )}
      {/* Picker de carga del Plan: si la operación está planificada, el
          operario elige el camión y los campos coincidentes se auto-llenan.
          Si no, sigue siendo opcional (se puede llenar todo a mano). En edición
          NO se muestra (el camión ya está cargado). */}
      {!isEdit && (
        <Section title="Camión del plan (opcional)">
          <p className="text-xs text-slate-500 mb-2">
            Si la carga estaba planificada, elegila para traer transportista, exportador, placa, chofer, AFIDI <strong>y los productos que trae el camión</strong>.
          </p>
          <CargaPicker
            selected={cargaSeleccionada}
            onSelect={aplicarCarga}
            onPickViaje={(v) => {
              setViajeARecibir(v);
              // PRE-CARGA de los productos declarados por CR, con la cantidad
              // en CERO (dueño 3/09). La ceguera que sirve es la de la
              // cantidad: el receptor tiene que contar. Adivinar el ARTÍCULO
              // no agregaba control — el viaje 1 del 3/09 se contó cuatro
              // veces y las cuatro se eligió el hermano («Melon Valenciano
              // (Super)» en vez de «Melon Valenciano Brasil»), con las
              // cantidades perfectas. Igual se pueden agregar y quitar.
              setLineas((v.productos ?? []).map((p) => ({
                cod_art: p.cod_art,
                descripcion: p.descripcion ?? p.cod_art,
                icono: null,
                cantidad: 0,
                marca: null,
                deposito: depositoIngreso,
                defectos: [],
              })));
            }}
          />
          {viajeARecibir && (
            <div className="mt-2 flex items-center gap-2 rounded-md border border-indigo-200 bg-indigo-50 px-3 py-2">
              <span className="px-1.5 py-0.5 rounded bg-indigo-600 text-white text-[10px] font-bold uppercase tracking-wide">VIAJE</span>
              <span className="text-sm font-semibold text-indigo-900">
                Recepción · Viaje {viajeARecibir.numero_del_dia} · {viajeARecibir.fecha}
              </span>
              <span className="text-xs text-indigo-700 hidden sm:inline">
                — vienen los productos que mandó CR; contá cuánto llegó de cada uno
                (podés agregar o quitar). Las cantidades no se muestran.
              </span>
              <button
                type="button"
                onClick={() => setViajeARecibir(null)}
                className="ml-auto text-xs font-semibold text-indigo-700 hover:underline"
              >
                Quitar
              </button>
            </div>
          )}
          {resultadoViaje && viajeARecibir && (
            <ResultadoRecepcionViaje
              viaje={viajeARecibir}
              resultado={resultadoViaje}
              onClose={() => {
                setResultadoViaje(null);
                setViajeARecibir(null);
                setForm({ ...EMPTY });
                setLineas([]);
              }}
              // «Volver a contar»: el viaje SIGUE elegido (no se pierde el
              // modo viaje) y el formulario arranca limpio para contar de nuevo.
              onRecontar={() => {
                setResultadoViaje(null);
                setForm({ ...EMPTY });
                setLineas([]);
              }}
            />
          )}
          {avisoCarga && (
            <div className="mt-2 px-3 py-2 rounded bg-amber-50 border border-amber-200 text-xs text-amber-900">
              {avisoCarga}
            </div>
          )}
        </Section>
      )}

      {/* Orden = igual a la planilla de papel: identificación + agronomía juntas,
          después mercadería (nuestra extensión), después las condiciones. */}
      {!viajeARecibir && (
      <SectionIdentificacion
        form={form}
        update={update}
        faltaIds={faltaIds}
        etiqueta={etiqueta ?? null}
        onEtiquetaRegistrada={() => void refetchEtiqueta()}
      />
      )}
      <SectionMercaderia
        lineas={lineas}
        setLineas={setLineas}
        marcaDefault={null}
        deposito={depositoIngreso}
        setDeposito={setDepositoIngreso}
        setHayReclamosLinea={setHayReclamosLinea}
        faltaIds={faltaIds}
        isEdit={isEdit}
        sinReclamos={!!viajeARecibir}
      />
      {/* Requisitos por fruta del ing. agrónomo (mig 0092): aparecen solos
          cuando la mercadería trae una fruta con requisitos configurados.
          En modo VIAJE no van (27/08): la fruta ya se controló al entrar por
          CR — acá solo se cuenta lo que llegó. */}
      {!viajeARecibir && (
      <RequisitosFruta
        grupos={gruposRequisitos}
        valores={form.requisitos_valores ?? {}}
        onValor={(id, valor) =>
          setForm((prev) => ({
            ...prev,
            requisitos_valores: { ...(prev.requisitos_valores ?? {}), [id]: valor },
          }))
        }
        fotosCat={form.fotos_cat ?? {}}
        onFotos={setFotoSlot}
        intento={intentoEnvio}
      />
      )}
      <SectionCamara form={form} update={update} totalCajas={totalCajasActual} lineas={lineas} falta={faltaIds.has("f-camaras")} />
      {!viajeARecibir && (
      <SectionCondicionesGenerales form={form} update={update} faltaIds={faltaIds} />
      )}
      {!viajeARecibir && (
      <SectionCondicionesBanano form={form} update={update} />
      )}
      {!viajeARecibir && (
      <SectionCalificaciones form={form} update={update} />
      )}
      {/* Fotos y documentación: en EDICIÓN no se editan (se conservan las que tiene). */}
      {!isEdit && !viajeARecibir && (
        <SectionFotosCategorias
          fotosCat={form.fotos_cat}
          setFotoSlot={setFotoSlot}
          otras={form.fotos}
          setOtras={(fotos) => update("fotos", fotos)}
        />
      )}
      {viajeARecibir && (
        <Section title="Fotos (opcional)">
          <p className="text-xs text-slate-500 mb-2">
            Si algo llegó golpeado o querés dejar constancia, sacá las fotos que
            necesites — van al informe de la recepción.
          </p>
          <input
            type="file"
            accept="image/*"
            multiple
            capture="environment"
            onChange={(e) => {
              const files = e.target.files;
              if (!files) return;
              for (const f of Array.from(files)) {
                const reader = new FileReader();
                reader.onload = () =>
                  update("fotos", [...form.fotos, String(reader.result)]);
                reader.readAsDataURL(f);
              }
              e.target.value = "";
            }}
            className="block w-full text-sm text-slate-500 file:mr-3 file:rounded-md file:border-0 file:bg-pepe-blue file:px-4 file:py-2 file:text-sm file:font-semibold file:text-white hover:file:bg-pepe-blue/90"
          />
          {form.fotos.length > 0 && (
            <div className="mt-2 flex items-center gap-2 text-sm text-slate-600">
              <span className="font-semibold">{form.fotos.length} foto(s)</span>
              <button
                type="button"
                onClick={() => update("fotos", [])}
                className="text-xs text-rose-600 hover:underline"
              >
                Quitar todas
              </button>
            </div>
          )}
        </Section>
      )}
      {!isEdit && !viajeARecibir && <SectionDocumentacion form={form} update={update} />}
      {!viajeARecibir && (
      <SectionFirmas form={form} update={update} />
      )}
      <SectionTotalObservaciones form={form} update={update} lineas={lineas} />

      {sinInternet && (
        <div className="px-3 py-3 rounded-md bg-amber-50 border border-amber-300 text-amber-900 flex items-start gap-3">
          <svg viewBox="0 0 24 24" className="w-6 h-6 shrink-0 mt-0.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M1 1l22 22" />
            <path d="M16.72 11.06A10.94 10.94 0 0119 12.55" />
            <path d="M5 12.55a10.94 10.94 0 015.17-2.39" />
            <path d="M10.71 5.05A16 16 0 0122.58 9" />
            <path d="M1.42 9a15.91 15.91 0 014.7-2.88" />
            <path d="M8.53 16.11a6 6 0 016.95 0" />
            <line x1="12" y1="20" x2="12.01" y2="20" />
          </svg>
          <div className="flex-1 min-w-0">
            <p className="font-semibold text-sm">No se pudo enviar (sin señal o tardó demasiado).</p>
            {isEdit ? (
              // En EDICIÓN no hay borrador local: los cambios viven en esta
              // pantalla. No prometer un guardado que no existe (review v2).
              <p className="text-sm mt-0.5">
                Los cambios siguen en esta pantalla. <strong>No salgas de la página</strong> y tocá Reintentar cuando haya señal.
              </p>
            ) : (
              <>
                <p className="text-sm mt-0.5">
                  Tu trabajo <strong>quedó guardado en el celular</strong>, con las fotos.
                </p>
                <p className="text-sm mt-1">
                  Cuando haya señal, tocá Reintentar — si el pie ya había llegado, no se duplica.
                </p>
              </>
            )}
            <button
              type="button"
              onClick={submit}
              disabled={mut.isPending}
              className="mt-2.5 px-5 py-2.5 rounded bg-amber-500 text-white text-sm font-bold hover:bg-amber-600 disabled:opacity-40 min-h-[44px]"
            >
              {mut.isPending ? "Reintentando…" : "Reintentar"}
            </button>
          </div>
        </div>
      )}

      {error && (
        <div className="px-3 py-2 rounded bg-rose-50 border border-rose-200 text-sm text-rose-800">
          {error}
        </div>
      )}

      {/* Qué falta para poder guardar. Aparece acá, pegado al botón: el operario
          acaba de tocarlo y está mirando justo esto. Cada ítem es un botón que
          lleva hasta el campo — antes era una sola línea de texto y había que
          salir a buscarlo a mano en un formulario largo. */}
      {(faltantes.length > 0 || otroError) && (
        <div className="rounded-lg border-2 border-amber-400 bg-amber-50 p-3">
          <div className="flex items-start gap-2">
            <svg className="w-6 h-6 text-amber-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
            </svg>
            <div className="min-w-0 flex-1">
              <div className="font-bold text-amber-900">
                {otroError && faltantes.length === 0
                  ? "Falta corregir esto para guardar"
                  : `Falta completar ${faltantes.length} cosa${faltantes.length === 1 ? "" : "s"} para guardar`}
              </div>
              <p className="text-xs text-amber-800/80 mt-0.5">Tocá cada una y te llevo al campo.</p>
              <ul className="mt-2 space-y-1.5">
                {[...faltantes, ...(otroError ? [otroError] : [])].map((f, i) => (
                  <li key={`${f.id}-${i}`}>
                    <button
                      type="button"
                      onClick={() => irAlCampo(f.id)}
                      className="w-full text-left px-3 py-2.5 rounded-md bg-white border border-amber-300 text-sm text-slate-800 font-medium min-h-[44px] flex items-center justify-between gap-2 hover:bg-amber-100/60 active:bg-amber-100"
                    >
                      <span className="min-w-0">{f.que}</span>
                      <svg className="w-4 h-4 text-amber-600 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                        <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
                      </svg>
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          </div>
        </div>
      )}

      {/* Barra de acciones AL FINAL del form (no sticky — para que no la
          toquen sin querer mientras llenan). Botón guardar grande, botón
          limpiar más chico y a un costado para evitar tap accidental. */}
      <div className="pt-2 pb-8 flex flex-col-reverse sm:flex-row sm:items-center sm:justify-end gap-3">
        <button
          onClick={isEdit ? onCancel : resetForm}
          disabled={mut.isPending}
          className="px-4 py-3 sm:py-2 rounded border border-pepe-border bg-white text-sm font-medium text-slate-700 hover:bg-slate-100 min-h-[48px] sm:min-h-0"
        >
          {isEdit ? "Cancelar" : "Limpiar"}
        </button>
        <button
          onClick={submit}
          disabled={mut.isPending}
          className="px-6 py-4 sm:py-2.5 rounded bg-pepe-blue text-white text-base sm:text-sm font-bold sm:font-semibold hover:bg-pepe-blue-dark disabled:opacity-40 min-h-[56px] sm:min-h-0 shadow-sm"
        >
          {mut.isPending ? "Guardando…" : isEdit ? "Guardar cambios" : "Guardar pie de camión"}
        </button>
      </div>
    </div>
  );
}

// ─── Edición (desde Ingresos) ─────────────────────────────────────────

/** Convierte el detalle del pie a la forma del formulario (form + líneas). Las fotos
 *  NO se cargan (se conservan del lado del back); los defectos tampoco (se preservan
 *  por cod_art). El link al plan no se re-edita. */
function pieDetailToFormState(d: PieDeCamionDetail): { form: PieDeCamionCreate; lineas: LineaDraft[] } {
  const form: PieDeCamionCreate = {
    fecha: d.fecha,
    fecha_carga: d.fecha_carga ?? null,
    hora_inicio: d.hora_inicio ?? null,
    hora_fin: d.hora_fin ?? null,
    chofer_nombre: d.chofer_nombre ?? "",
    placa_camion: d.placa_camion ?? "",
    plan_carga_id: null,
    productos: (d.productos ?? []).map((p) => ({ producto: p.producto, marca: p.marca ?? null })),
    producto: d.producto ?? null,
    marca: d.marca ?? null,
    exportador: d.exportador ?? null,
    empresa_transporte: d.empresa_transporte ?? null,
    numero_afidi: d.numero_afidi ?? null,
    productor: d.productor ?? null,
    codigo_importador_camion: d.codigo_importador_camion ?? null,
    intervenido_agronomia: d.intervenido_agronomia ?? false,
    inspector_agronomo: d.inspector_agronomo ?? null,
    palet_rating: d.palet_rating ?? null,
    palet_comentario: d.palet_comentario ?? null,
    cajas_rating: d.cajas_rating ?? null,
    cajas_comentario: d.cajas_comentario ?? null,
    flejes_rating: d.flejes_rating ?? null,
    flejes_comentario: d.flejes_comentario ?? null,
    temp_pulpa_puerta_1: d.temp_pulpa_puerta_1 ?? null,
    temp_pulpa_puerta_2: d.temp_pulpa_puerta_2 ?? null,
    temp_pulpa_medio_1: d.temp_pulpa_medio_1 ?? null,
    temp_pulpa_medio_2: d.temp_pulpa_medio_2 ?? null,
    temp_pulpa_atras_1: d.temp_pulpa_atras_1 ?? null,
    temp_pulpa_atras_2: d.temp_pulpa_atras_2 ?? null,
    peso_caja_puerta_1: d.peso_caja_puerta_1 ?? null,
    peso_caja_puerta_2: d.peso_caja_puerta_2 ?? null,
    peso_caja_medio_1: d.peso_caja_medio_1 ?? null,
    peso_caja_medio_2: d.peso_caja_medio_2 ?? null,
    peso_caja_atras_1: d.peso_caja_atras_1 ?? null,
    peso_caja_atras_2: d.peso_caja_atras_2 ?? null,
    calibracion_puerta: d.calibracion_puerta ?? null,
    calibracion_medio: d.calibracion_medio ?? null,
    calibracion_atras: d.calibracion_atras ?? null,
    longitud_puerta: d.longitud_puerta ?? null,
    longitud_medio: d.longitud_medio ?? null,
    longitud_atras: d.longitud_atras ?? null,
    longitud_unidad: d.longitud_unidad ?? "cm",
    corona: d.corona ?? null,
    quemada: d.quemada ?? null,
    rameada: d.rameada ?? null,
    descarga_autorizada_por: d.descarga_autorizada_por ?? null,
    inspeccion_realizada_por: d.inspeccion_realizada_por ?? null,
    total_cajas: d.total_cajas ?? null,
    observaciones: d.observaciones ?? null,
    lineas: [],
    fotos: [],
    fotos_cat: {},
    documentacion: [],
    camaras: (d.camaras ?? []).map((c) => ({
      ubicacion: c.ubicacion as UbicacionCamara,
      numero: c.numero,
      cantidad: c.cantidad ?? null,
      cod_art: c.cod_art ?? null,
    })),
    // Pre-carga de las respuestas a requisitos (mig 0092). Las FOTOS no se
    // re-cargan (viven en el fotos-PDF): el back las preserva al editar.
    requisitos_valores: Object.fromEntries(
      (d.requisitos ?? [])
        .filter((r) => r.requisito_id != null && r.tipo !== "foto")
        .map((r) => [
          r.requisito_id as number,
          r.valor_numero != null ? String(r.valor_numero) : (r.valor_texto ?? ""),
        ]),
    ),
  };
  const lineas: LineaDraft[] = (d.lineas ?? []).map((l) => ({
    cod_art: l.cod_art,
    deposito: l.deposito ?? "",
    cantidad: l.cantidad,
    marca: l.marca ?? null,
    hay_reclamos: l.hay_reclamos ?? null,   // display; el back la preserva por cod_art
    defectos: [],   // se preservan server-side por cod_art (no se re-editan)
    descripcion: l.descripcion ?? "",
    deposito_descripcion: l.deposito_descripcion ?? "",
    icono: l.icono ?? null,
  }));
  return { form, lineas };
}

/** Modal a pantalla completa para editar un pie de camión (desde Ingresos). Trae el
 *  detalle, lo convierte y reusa el formulario en modo edición. NO cierra al clickear
 *  afuera (para no perder cambios): sólo con Cancelar/Guardar. */
export function EditarPieModal({ pieId, onClose }: { pieId: number; onClose: () => void }) {
  const { data, isLoading, isError } = useQuery({
    queryKey: ["pie-camion-detail", pieId],
    queryFn: () => getPieCamion(pieId),
  });
  const converted = useMemo(() => (data ? pieDetailToFormState(data) : null), [data]);
  return (
    <div className="fixed inset-0 z-[80] bg-black/50 flex items-start justify-center overflow-y-auto overscroll-contain p-2 sm:p-4">
      <div className="bg-slate-50 rounded-lg shadow-2xl w-full max-w-5xl my-2 sm:my-6 p-4 sm:p-6">
        {isLoading ? (
          <p className="text-center text-sm text-slate-400 py-10">Cargando pie…</p>
        ) : isError || !converted ? (
          <div className="text-center py-8">
            <p className="text-sm text-rose-700">No se pudo cargar el pie de camión.</p>
            <button type="button" onClick={onClose} className="mt-3 px-4 py-2 rounded border border-pepe-border text-sm font-medium hover:bg-slate-100">
              Cerrar
            </button>
          </div>
        ) : (
          <NuevoForm
            editId={pieId}
            initialForm={converted.form}
            initialLineas={converted.lineas}
            fotosRequisitoPrevias={new Set(
              (data?.requisitos ?? [])
                .filter((r) => r.tipo === "foto" && r.fotos_n > 0 && r.requisito_id != null)
                .map((r) => r.requisito_id as number),
            )}
            onSaved={onClose}
            onCancel={onClose}
          />
        )}
      </div>
    </div>
  );
}

// ─── Helpers de UI ────────────────────────────────────────────────────

function Section({ id, title, children, falta = false }: { id?: string; title: string; children: React.ReactNode; falta?: boolean }) {
  return (
    <section
      id={id}
      className={`bg-white border rounded-md p-3.5 sm:p-4 ${falta ? "border-rose-400 ring-2 ring-rose-300" : "border-pepe-border"}`}
    >
      <h2 className="text-sm sm:text-xs sm:uppercase sm:tracking-wider text-slate-700 sm:text-slate-500 font-semibold mb-3">
        {title}
      </h2>
      {children}
    </section>
  );
}

function Field({
  id,
  label,
  children,
  span = 1,
  falta = false,
}: {
  /** Ancla para que la lista de faltantes pueda saltar hasta acá. */
  id?: string;
  label: string;
  children: React.ReactNode;
  span?: 1 | 2 | 3 | 4;
  /** Obligatorio y sin completar → se pinta en rojo. */
  falta?: boolean;
}) {
  const spanCls =
    span === 4 ? "sm:col-span-4" :
    span === 3 ? "sm:col-span-3" :
    span === 2 ? "sm:col-span-2" : "sm:col-span-1";
  return (
    <div id={id} className={`${spanCls} ${falta ? "rounded-md ring-2 ring-rose-400 ring-offset-2 p-1 -m-1" : ""}`}>
      <label className={`block text-xs sm:text-[11px] uppercase tracking-wide font-semibold mb-1 ${falta ? "text-rose-700" : "text-slate-600 sm:text-slate-500"}`}>
        {label}{falta && <span className="normal-case"> — falta</span>}
      </label>
      {children}
    </div>
  );
}

function TextInput(props: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      {...props}
      className="w-full min-w-0 px-3 py-2.5 sm:py-1.5 border border-pepe-border rounded text-base sm:text-sm min-h-[44px] sm:min-h-0"
    />
  );
}

function NumberInput(props: React.InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      type="number"
      inputMode="decimal"
      {...props}
      className="w-full min-w-0 px-3 py-2.5 sm:py-1.5 border border-pepe-border rounded text-base sm:text-sm text-right font-mono min-h-[44px] sm:min-h-0"
    />
  );
}

function nullableNumber(v: string): number | null {
  if (v === "" || v === undefined || v === null) return null;
  const n = Number(v);
  return Number.isNaN(n) ? null : n;
}

// ─── Sección Mercadería (productos recibidos + defectos por línea) ───

function SectionMercaderia({
  lineas,
  setLineas,
  marcaDefault,
  deposito,
  setDeposito,
  setHayReclamosLinea,
  faltaIds,
  isEdit,
  sinReclamos,
}: {
  lineas: LineaDraft[];
  setLineas: (l: LineaDraft[] | ((p: LineaDraft[]) => LineaDraft[])) => void;
  /** Depósito de ingreso del camión entero (lo dueña el form padre). */
  deposito: string;
  setDeposito: (cod: string) => void;
  /** Si el operario eligió una carga del Plan, sugerimos el productor
   *  como marca pre-cargada en el input — la puede sobreescribir. */
  marcaDefault?: string | null;
  /** Responde "¿hay reclamos?" de UNA línea (mig 0072). Al pasar a NO con
   *  defectos ya marcados, el padre pide confirmación y los limpia. */
  setHayReclamosLinea: (idx: number, v: boolean) => void;
  /** Ids de los campos que quedaron sin completar (para pintarlos). */
  faltaIds: Set<string>;
  /** En edición los defectos no se re-editan (el back los preserva por cod_art). */
  isEdit?: boolean;
  /** Modo VIAJE: sin pregunta de reclamos por fruta (la recepción no la usa). */
  sinReclamos?: boolean;
}) {
  const [art, setArt] = useState<Articulo | null>(null);
  const [marca, setMarca] = useState("");
  const [cantidad, setCantidad] = useState("");
  const [showPicker, setShowPicker] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const { data: depositos = [] } = useQuery({
    queryKey: ["lookups", "depositos"],
    queryFn: () => apiGet<Deposito[]>("/lookups/depositos"),
    staleTime: 60 * 60_000,
  });

  // Depósitos distintos entre las líneas cargadas (solo puede pasar en pies
  // viejos: el alta de hoy tiene un único selector).
  const depositosMezclados = useMemo(
    () => [...new Set(lineas.map((l) => (l.deposito ?? "").trim()).filter(Boolean))],
    [lineas],
  );

  // El depósito lo manda el padre (única fuente de verdad del envío). Acá sólo
  // se elige, y se estampa en las líneas para que el borrador lo recuerde.
  function cambiarDeposito(cod: string) {
    setDeposito(cod);
    setLineas((prev) => prev.map((l) => ({ ...l, deposito: cod })));
  }

  // Cuando cambia el marcaDefault (porque se eligió/cambió la carga), si
  // el input de marca está vacío, lo pre-llenamos. Si el operario ya tipeó
  // algo, no pisamos.
  useEffect(() => {
    if (marcaDefault && !marca) {
      setMarca(marcaDefault);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [marcaDefault]);

  // Categorías → para mostrar el SVG a color de la fruta en cada línea.
  const { data: cats = [] } = useQuery({
    queryKey: ["lookups", "categorias"],
    queryFn: () => listCategorias(),
    staleTime: 5 * 60_000,
  });

  const totalCantidad = useMemo(
    () => lineas.reduce((s, l) => s + l.cantidad, 0),
    [lineas],
  );
  const totalDefectuoso = useMemo(
    () => lineas.reduce((s, l) => s + l.defectos.reduce((a, d) => a + d.cantidad, 0), 0),
    [lineas],
  );

  function agregarLinea() {
    setError(null);
    if (!art) return setError("Elegí un producto");
    const cant = Number(cantidad);
    if (!cant || cant <= 0) return setError("Cantidad debe ser > 0");

    const icono = cats.find((c) => c.nombre === art.categoria)?.icono ?? null;
    const marcaClean = marca.trim();
    setLineas((prev) => [
      ...prev,
      {
        cod_art: art.cod,
        descripcion: art.descripcion,
        icono,
        cantidad: cant,
        marca: marcaClean || null,
        deposito,
        defectos: [],
      },
    ]);
    setArt(null);
    setCantidad("");
    // Mantenemos la marca tipeada — típicamente todas las líneas del mismo
    // camión comparten la marca, evita re-tipear.
  }

  function quitarLinea(idx: number) {
    setLineas((prev) => prev.filter((_, i) => i !== idx));
  }

  function setDefectos(idx: number, defectos: DefectoCreate[]) {
    setLineas((prev) => prev.map((l, i) => (i === idx ? { ...l, defectos } : l)));
  }

  // Cantidad editable en la lista: clave para las líneas pre-cargadas desde el
  // plan (las de multi-producto vienen en 0 y el operario completa las cajas).
  function setCantidadLinea(idx: number, v: string) {
    const n = Number(v);
    setLineas((prev) => prev.map((l, i) => (i === idx ? { ...l, cantidad: Number.isNaN(n) || n < 0 ? 0 : n } : l)));
  }

  return (
    <Section id="f-mercaderia" title="Mercadería recibida y reclamos">
      {/* Mini explicación de cómo levantar reclamos */}
      <div className="mb-3 px-3 py-2 rounded bg-rose-50/50 border border-rose-200/60 text-xs text-rose-900/80">
        {isEdit ? (
          <>
            <strong className="font-semibold">Los reclamos no se editan acá.</strong> Los defectos que ya tenga el pie se conservan tal cual. Para reclamar sobre este pie usá el botón <strong>Reclamar</strong> en Ingresos.
          </>
        ) : (
          <>
            <strong className="font-semibold">¿Vino mercadería con defecto?</strong> Agregá el producto abajo, después respondé que SÍ hay reclamos y marcá el defecto desde la fila (motivo + cantidad de cajas + foto). Al guardar se genera un <strong>PDF de reclamo al proveedor</strong>.
          </>
        )}
      </div>
      {/* Agregar línea */}
      <div className="flex flex-col gap-3 sm:grid sm:grid-cols-12 sm:gap-3 sm:items-end mb-4">
        <div className="sm:col-span-6">
          <label className="block text-xs uppercase tracking-wide text-slate-500 font-semibold mb-1">
            Producto
          </label>
          <button
            onClick={() => setShowPicker(true)}
            type="button"
            className="w-full text-left px-3 py-3 sm:py-1.5 border border-pepe-border rounded text-sm bg-white hover:bg-slate-50 min-h-[44px]"
          >
            {art ? (
              <span>
                <span className="font-mono text-xs text-slate-500">{art.cod}</span>
                {" — "}{art.descripcion}
              </span>
            ) : (
              <span className="text-slate-400">Elegir producto…</span>
            )}
          </button>
        </div>
        <div className="sm:col-span-4">
          <label className="block text-xs uppercase tracking-wide text-slate-500 font-semibold mb-1">
            Marca
          </label>
          <input
            value={marca}
            onChange={(e) => setMarca(e.target.value)}
            placeholder="ej. PY de Primera"
            className="w-full px-3 py-3 sm:py-1.5 border border-pepe-border rounded text-base sm:text-sm min-h-[44px]"
          />
        </div>
        <div className="sm:col-span-1">
          <label className="block text-xs uppercase tracking-wide text-slate-500 font-semibold mb-1">
            Cant.
          </label>
          <input
            type="number"
            inputMode="decimal"
            value={cantidad}
            onChange={(e) => setCantidad(e.target.value)}
            min="0"
            step="0.001"
            placeholder="0"
            className="w-full px-3 py-3 sm:py-1.5 border border-pepe-border rounded text-base sm:text-sm text-right font-mono min-h-[44px]"
          />
        </div>
        <div className="sm:col-span-1">
          <button
            onClick={agregarLinea}
            className="w-full px-3 py-3 sm:py-1.5 rounded bg-pepe-blue text-white text-base sm:text-sm font-medium hover:bg-pepe-blue-dark min-h-[44px] inline-flex items-center justify-center gap-2"
          >
            <svg className="w-5 h-5 sm:hidden" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
            </svg>
            <span className="sm:hidden">Agregar producto</span>
            <span className="hidden sm:inline">+</span>
          </button>
        </div>
      </div>

      {error && (
        <div className="px-3 py-2 mb-3 rounded bg-rose-50 border border-rose-200 text-sm text-rose-800">
          {error}
        </div>
      )}

      {/* Depósito de ingreso: uno solo para todo el camión. Va acá arriba (y no
          en cada producto) porque un camión descarga en un solo lado. */}
      <div className="mb-3 flex flex-wrap items-center gap-x-3 gap-y-1">
        <label
          htmlFor="dep-ingreso"
          className="text-xs uppercase tracking-wide text-slate-500 font-semibold"
        >
          Depósito de ingreso
        </label>
        <select
          id="dep-ingreso"
          value={deposito}
          onChange={(e) => cambiarDeposito(e.target.value)}
          className="px-3 py-2 sm:py-1.5 border border-pepe-border rounded text-base sm:text-sm bg-white min-h-[44px] sm:min-h-0"
        >
          {(depositos.length ? depositos : [{ cod: deposito, descripcion: deposito }]).map((d) => (
            <option key={d.cod} value={d.cod}>
              {d.cod} — {d.descripcion}
            </option>
          ))}
        </select>
        <span className="text-xs text-slate-400">Dónde entra el stock. Es el mismo para todos los productos del camión.</span>
      </div>

      {/* Pie viejo cargado con la versión que pedía depósito POR LÍNEA: si tiene
          varios, guardar los unifica. Se avisa — cambiar dónde entra el stock sin
          decirlo sería peor que el ruido del cartel. */}
      {depositosMezclados.length > 1 && (
        <div className="mb-3 px-3 py-2 rounded bg-amber-50 border border-amber-300 text-xs text-amber-900">
          <strong className="font-semibold">Ojo:</strong> este pie tiene productos en depósitos distintos
          ({depositosMezclados.join(", ")}). Al guardar, <strong>todos</strong> quedan en{" "}
          <strong>{deposito}</strong>. Si no es lo que querés, cancelá la edición.
        </div>
      )}

      {/* Lista de líneas (mobile cards + desktop tabla compartiendo data) */}
      <div className="border border-pepe-border rounded-md overflow-hidden">
        <header className="px-4 py-2 bg-slate-50 border-b border-pepe-border text-xs text-slate-600 flex justify-between">
          <span>{lineas.length} {lineas.length === 1 ? "línea" : "líneas"}</span>
          <span>
            Total <strong className="text-slate-900">{totalCantidad.toFixed(2)}</strong>
            {totalDefectuoso > 0 && <> · <strong className="text-rose-700">{totalDefectuoso.toFixed(2)}</strong> con defecto</>}
          </span>
        </header>
        {lineas.length === 0 ? (
          <div className="px-4 py-6 text-center text-sm text-slate-400">
            No agregaste productos todavía.
          </div>
        ) : (
          <ul className="divide-y divide-pepe-border">
            {lineas.map((l, idx) => (
              <li key={`${l.cod_art}-${idx}`} className="px-4 py-3">
                <div className="flex items-start gap-3">
                  {l.icono && (
                    <img src={`/categorias/${l.icono}.svg`} alt="" className="w-11 h-11 object-contain shrink-0" />
                  )}
                  <div className="flex-1 min-w-0">
                    <div className="font-medium text-slate-900 leading-tight">{l.descripcion}</div>
                    <div className="text-[11px] font-mono text-slate-400 mt-0.5">{l.cod_art}</div>
                    <div className="flex items-center gap-3 mt-1.5 text-xs flex-wrap">
                      <span className="inline-flex items-center gap-1">
                        <input
                          type="number"
                          inputMode="decimal"
                          min="0"
                          step="0.001"
                          value={l.cantidad || ""}
                          onChange={(e) => setCantidadLinea(idx, e.target.value)}
                          placeholder="0"
                          className={`w-20 px-2 py-1 border rounded text-right font-mono text-sm min-h-[36px] ${
                            l.cantidad > 0 ? "border-pepe-border text-slate-900" : "border-amber-300 bg-amber-50 text-amber-900"
                          }`}
                        />
                        <span className="text-slate-400">cajas</span>
                      </span>
                      {l.marca && (
                        <span className="px-1.5 py-0.5 rounded bg-pepe-yellow/30 text-amber-900 italic">
                          {l.marca}
                        </span>
                      )}
                    </div>
                  </div>
                  <button
                    onClick={() => quitarLinea(idx)}
                    title="Quitar línea"
                    className="w-12 h-12 sm:w-10 sm:h-10 rounded border border-pepe-border bg-white inline-flex items-center justify-center text-slate-600 hover:bg-rose-50 hover:text-rose-700 hover:border-rose-200 transition-colors shrink-0"
                  >
                    <svg className="w-5 h-5 sm:w-4 sm:h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
                {/* La pregunta es POR FRUTA (mig 0072): con un camión de banana
                    y kiwi, "¿hay reclamos para esta fruta?" a nivel camión no
                    se sabía a cuál se refería.
                    En EDICIÓN no se pregunta ni se marcan defectos: el PUT los
                    preserva por cod_art e IGNORA los del body, así que un
                    control editable acá tiraba a la basura lo que se cargara
                    (el detalle ni siquiera trae los defectos que ya existen).
                    Para reclamar sobre un pie ya guardado está el botón
                    "Reclamar" de Ingresos. */}
                {!isEdit && !sinReclamos && (
                  <div
                    id={`f-reclamos-${idx}`}
                    className={`mt-2.5 rounded-lg border-2 p-2.5 ${
                      faltaIds.has(`f-reclamos-${idx}`)
                        ? "border-rose-400 bg-rose-50/60"
                        : l.hay_reclamos == null
                          ? "border-amber-300 bg-amber-50/60"
                          : l.hay_reclamos
                            ? "border-rose-300 bg-rose-50"
                            : "border-emerald-300 bg-emerald-50"
                    }`}
                  >
                    <div className="text-sm font-bold text-slate-900">
                      ¿Hay reclamos en {nombreCortoProducto(l.descripcion) || l.cod_art}?
                    </div>
                    <div className="mt-2 flex gap-2">
                      <button
                        type="button"
                        onClick={() => setHayReclamosLinea(idx, true)}
                        className={`flex-1 px-3 py-2.5 rounded-lg border-2 font-bold text-sm min-h-[44px] ${
                          l.hay_reclamos === true
                            ? "border-rose-600 bg-rose-600 text-white"
                            : "border-pepe-border bg-white text-slate-700 active:bg-slate-50"
                        }`}
                      >
                        SÍ, hay reclamos
                      </button>
                      <button
                        type="button"
                        onClick={() => setHayReclamosLinea(idx, false)}
                        className={`flex-1 px-3 py-2.5 rounded-lg border-2 font-bold text-sm min-h-[44px] ${
                          l.hay_reclamos === false
                            ? "border-emerald-600 bg-emerald-600 text-white"
                            : "border-pepe-border bg-white text-slate-700 active:bg-slate-50"
                        }`}
                      >
                        NO, vino bien
                      </button>
                    </div>
                    {l.hay_reclamos === true && l.defectos.length === 0 && (
                      <p className="mt-1.5 text-xs text-rose-700">
                        Marcá el defecto abajo: motivo, cuántas cajas y una foto.
                      </p>
                    )}
                  </div>
                )}
                {!isEdit && l.hay_reclamos === true && (
                  <DefectosControl
                    lineaCantidad={l.cantidad}
                    defectos={l.defectos}
                    onChange={(d) => setDefectos(idx, d)}
                  />
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      {showPicker && (
        <ArticuloPickerModal
          onClose={() => setShowPicker(false)}
          onSelect={(a) => {
            setArt(a);
            setShowPicker(false);
          }}
          // Nivel de color (igual que Pre-carga): la banana se ingresa por COLOR
          // (en la práctica siempre Color 1, que es como entra verde y como la
          // ingresan a mano en Macrosoft — auditoría 13/07: 010101 → 010101-1).
          // Así el pie queda con el mismo código que el ingreso real.
          conVariantes
        />
      )}
    </Section>
  );
}

// ─── Sección 1: Identificación ────────────────────────────────────────

function SectionIdentificacion({
  form,
  update,
  faltaIds,
  etiqueta,
  onEtiquetaRegistrada,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
  faltaIds: Set<string>;
  /** Etiquetas ya impresas para este camión (placa+fecha), si las hay. */
  etiqueta: EtiquetaCamion | null;
  onEtiquetaRegistrada?: () => void;
}) {
  // Impresión de etiquetas Zebra del código de importador (para pegar en pallets).
  // String para que se pueda BORRAR todo el campo y escribir libre (un number
  // forzaría el valor a 1 al vaciarlo). Se parsea + clampa recién al imprimir.
  const [cantidad, setCantidad] = useState("30");
  const [imprimiendo, setImprimiendo] = useState(false);
  const codigoCoincide =
    (form.codigo_importador_camion ?? "").trim().toUpperCase() ===
    (etiqueta?.codigo ?? "").trim().toUpperCase();
  const [printMsg, setPrintMsg] = useState<{ ok: boolean; texto: string } | null>(null);

  async function imprimir() {
    const cod = (form.codigo_importador_camion ?? "").trim();
    if (!cod) {
      setPrintMsg({ ok: false, texto: "Escribí el código de importador primero." });
      return;
    }
    const placa = (form.placa_camion ?? "").trim();
    const n = Math.max(1, Math.min(200, parseInt(cantidad, 10) || 1));
    setImprimiendo(true);
    setPrintMsg(null);
    try {
      await imprimirEtiquetas(cod, form.fecha, n, form.placa_camion, form.fecha_carga, form.productor);
      // El código queda ASOCIADO AL CAMIÓN (placa + fecha de descarga): en el
      // celular, al elegir el camión, se pre-carga solo. Antes se tipeaba dos
      // veces y cuando no coincidía, el QR de la etiqueta apuntaba a un código
      // que el pie no tenía.
      let extra = "";
      if (placa) {
        try {
          await registrarEtiquetaImpresa({
            placa,
            fecha: form.fecha,
            codigo: cod,
            cantidad: n,
            plan_carga_id: form.plan_carga_id ?? null,
          });
          onEtiquetaRegistrada?.();
          extra = " El código queda guardado para este camión: en el celular ya va a estar cargado.";
        } catch {
          // El papel YA salió: que falle el registro no puede leerse como
          // "no se imprimió". Se avisa y se sigue.
          extra = " (No se pudo guardar el código para el camión — cargalo a mano en el celular.)";
        }
      } else {
        extra = " Poné la placa del camión para que el código quede guardado y no haya que re-escribirlo en el celular.";
      }
      setPrintMsg({
        ok: true,
        texto: `Enviado a imprimir ${n} etiqueta${n === 1 ? "" : "s"}. Si aparece el diálogo, elegí la Zebra.${extra}`,
      });
    } catch (e) {
      setPrintMsg({ ok: false, texto: e instanceof Error ? e.message : "No se pudo imprimir." });
    } finally {
      setImprimiendo(false);
    }
  }

  return (
    <Section title="Identificación">
      <div className="grid grid-cols-1 sm:grid-cols-4 gap-3">
        <Field label="Fecha de carga">
          <TextInput type="date" value={form.fecha_carga ?? ""} onChange={(e) => update("fecha_carga", e.target.value || null)} />
        </Field>
        {/* La descarga es HOY: el pie se hace mientras se descarga el camión, y
            el ingreso a Macrosoft va con esa fecha. Tipeable era una trampa —
            el 1/09 alguien copió la fecha planificada de la carpeta (29/08) y
            el movimiento de stock quedó tres días atrás. */}
        <Field label="Fecha de descarga">
          <TextInput type="date" value={form.fecha} readOnly disabled
                     title="Es el día en que se hace el pie: el camión se descarga ahora" />
        </Field>
        <Field label="Hora inicio">
          <TextInput type="time" value={form.hora_inicio ?? ""} onChange={(e) => update("hora_inicio", e.target.value || null)} />
        </Field>
        <Field label="Hora fin">
          <TextInput type="time" value={form.hora_fin ?? ""} onChange={(e) => update("hora_fin", e.target.value || null)} />
        </Field>
        <Field label="N° de Afidi">
          <TextInput value={form.numero_afidi ?? ""} onChange={(e) => update("numero_afidi", e.target.value || null)} placeholder="1559792" />
        </Field>

        <Field id="f-chofer" label="Nombre Chofer" span={2} falta={faltaIds.has("f-chofer")}>
          <TextInput value={form.chofer_nombre} onChange={(e) => update("chofer_nombre", e.target.value)} placeholder="Cristian Gimenez" />
        </Field>
        <Field id="f-placa" label="Placa camión" span={2} falta={faltaIds.has("f-placa")}>
          <TextInput value={form.placa_camion} onChange={(e) => update("placa_camion", e.target.value.toUpperCase())} placeholder="AAHG849" autoCapitalize="characters" />
        </Field>
      </div>

      {/* Productor, exportador, transportadora, código importador */}
      <div className="grid grid-cols-1 sm:grid-cols-4 gap-3 mt-3">
        <Field label="Productor" span={2}>
          <TextInput value={form.productor ?? ""} onChange={(e) => update("productor", e.target.value || null)} placeholder="Fischer" />
        </Field>
        <Field label="Exportador" span={2}>
          <TextInput value={form.exportador ?? ""} onChange={(e) => update("exportador", e.target.value || null)} placeholder="Hugo Franco" />
        </Field>
        <Field label="Empresa transportadora" span={2}>
          <TextInput value={form.empresa_transporte ?? ""} onChange={(e) => update("empresa_transporte", e.target.value || null)} placeholder="Mega Logística" />
        </Field>

        <Field id="f-codimp" label="Código importador / camión" span={2} falta={faltaIds.has("f-codimp")}>
          <TextInput
            value={form.codigo_importador_camion ?? ""}
            onChange={(e) => update("codigo_importador_camion", e.target.value.toUpperCase() || null)}
            placeholder="FH-044"
            autoCapitalize="characters"
          />
          {/* El código que ya se imprimió en las etiquetas de este camión. Si el
              del pie no coincide, el QR de la etiqueta apunta a un código que el
              pie no tiene — que es justo el problema que esto viene a evitar. */}
          {etiqueta && (
            codigoCoincide ? (
              <p className="mt-1 text-xs text-emerald-700">
                Coincide con las {etiqueta.cantidad ?? ""} etiquetas impresas
                {etiqueta.impreso_por ? ` por ${etiqueta.impreso_por}` : ""}.
              </p>
            ) : (
              <div className="mt-1 px-2 py-1.5 rounded bg-amber-50 border border-amber-300 text-xs text-amber-900">
                <strong className="font-semibold">Las etiquetas de este camión dicen{" "}
                {etiqueta.codigo}</strong>. Si guardás con otro código, el QR de la
                etiqueta no va a encontrar este pie.
                <button
                  type="button"
                  onClick={() => update("codigo_importador_camion", etiqueta.codigo)}
                  className="ml-1 underline font-semibold"
                >
                  Usar {etiqueta.codigo}
                </button>
              </div>
            )
          )}
        </Field>
      </div>

      {/* Impresión de etiquetas Zebra del código importador (para los pallets).
          Se imprime desde la PC que tiene la Zebra + Zebra Browser Print. */}
      <div className="mt-3 rounded-md border border-pepe-border bg-slate-50 px-3 py-3">
        <div className="flex flex-wrap items-end gap-3">
          <div>
            <label className="block text-xs uppercase tracking-wide text-slate-500 font-semibold mb-1.5">
              Etiquetas a imprimir
            </label>
            <input
              type="number"
              min={1}
              max={200}
              inputMode="numeric"
              value={cantidad}
              onChange={(e) => setCantidad(e.target.value)}
              onBlur={(e) => {
                const v = e.target.value.trim();
                if (v !== "") setCantidad(String(Math.max(1, Math.min(200, parseInt(v, 10) || 1))));
              }}
              className="w-24 px-3 py-2.5 sm:py-2 border border-pepe-border rounded text-base sm:text-sm focus:outline-none focus:ring-2 focus:ring-pepe-blue/30 focus:border-pepe-blue"
            />
          </div>
          <button
            type="button"
            onClick={imprimir}
            disabled={imprimiendo}
            className="px-5 py-3 sm:py-2.5 rounded bg-pepe-blue text-white text-sm font-bold hover:bg-pepe-blue-dark disabled:opacity-40 min-h-[48px] sm:min-h-0 inline-flex items-center gap-2"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M17 17h2a2 2 0 002-2v-4a2 2 0 00-2-2H5a2 2 0 00-2 2v4a2 2 0 002 2h2m2 4h6a2 2 0 002-2v-4a2 2 0 00-2-2H9a2 2 0 00-2 2v4a2 2 0 002 2zm8-12V5a2 2 0 00-2-2H9a2 2 0 00-2 2v4h10z" />
            </svg>
            {imprimiendo ? "Imprimiendo…" : "Imprimir etiquetas"}
          </button>
          <span className="text-xs text-slate-500 self-center">
            Etiquetas del código para pegar en los pallets (Zebra).
          </span>
        </div>
        {printMsg && (
          <div className={`mt-2 text-sm ${printMsg.ok ? "text-emerald-700" : "text-rose-700"}`}>
            {printMsg.texto}
          </div>
        )}
      </div>

      {/* Agronomía: misma sección como en la planilla física */}
      <div className="mt-4 pt-4 border-t border-pepe-border">
        <label className="block text-xs uppercase tracking-wide text-slate-500 font-semibold mb-1.5">
          Camión intervenido por Agronomía
        </label>
        <div className="flex flex-wrap items-center gap-3">
          <ToggleSiNo
            value={form.intervenido_agronomia}
            onChange={(v) => {
              update("intervenido_agronomia", v);
              if (!v) update("inspector_agronomo", null);
            }}
          />
          {form.intervenido_agronomia && (
            <div className="flex-1 min-w-0 sm:min-w-[200px]">
              <TextInput
                value={form.inspector_agronomo ?? ""}
                onChange={(e) => update("inspector_agronomo", e.target.value || null)}
                placeholder="Nombre del inspector agrónomo"
              />
            </div>
          )}
        </div>
      </div>
    </Section>
  );
}

function ToggleSiNo({ value, onChange }: { value: boolean; onChange: (v: boolean) => void }) {
  return (
    <div className="inline-flex rounded-md border border-pepe-border overflow-hidden">
      <button
        onClick={() => onChange(false)}
        className={`px-4 py-2 text-sm font-medium min-w-[60px] ${
          !value ? "bg-pepe-blue text-white" : "bg-white text-slate-700 hover:bg-slate-50"
        }`}
      >
        NO
      </button>
      <button
        onClick={() => onChange(true)}
        className={`px-4 py-2 text-sm font-medium min-w-[60px] border-l border-pepe-border ${
          value ? "bg-pepe-blue text-white" : "bg-white text-slate-700 hover:bg-slate-50"
        }`}
      >
        SÍ
      </button>
    </div>
  );
}

// ─── Sección 3: Condiciones Generales ─────────────────────────────────

function SectionCondicionesGenerales({
  form,
  update,
  faltaIds,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
  faltaIds: Set<string>;
}) {
  return (
    <Section title="Condiciones generales (1 = mal, 5 = excelente)">
      <div className="space-y-3">
        <RatingRow
          id="f-palet"
          falta={faltaIds.has("f-palet")}
          label="Palet"
          rating={form.palet_rating ?? null}
          comentario={form.palet_comentario ?? ""}
          onRating={(v) => update("palet_rating", v)}
          onComentario={(v) => update("palet_comentario", v || null)}
        />
        <RatingRow
          id="f-cajas"
          falta={faltaIds.has("f-cajas")}
          label="Cajas"
          rating={form.cajas_rating ?? null}
          comentario={form.cajas_comentario ?? ""}
          onRating={(v) => update("cajas_rating", v)}
          onComentario={(v) => update("cajas_comentario", v || null)}
        />
        <RatingRow
          id="f-flejes"
          falta={faltaIds.has("f-flejes")}
          label="Flejes"
          rating={form.flejes_rating ?? null}
          comentario={form.flejes_comentario ?? ""}
          onRating={(v) => update("flejes_rating", v)}
          onComentario={(v) => update("flejes_comentario", v || null)}
        />
      </div>
    </Section>
  );
}

function RatingRow({
  id,
  falta = false,
  label,
  rating,
  comentario,
  onRating,
  onComentario,
}: {
  id?: string;
  falta?: boolean;
  label: string;
  rating: number | null;
  comentario: string;
  onRating: (v: number | null) => void;
  onComentario: (v: string) => void;
}) {
  // Colores pastel rojo → verde. Cuando el botón está seleccionado, color
  // saturado; cuando no, color suave de su tier.
  const ratingColors: Record<number, { selected: string; unselected: string }> = {
    1: { selected: "bg-rose-500 text-white",   unselected: "bg-rose-100 text-rose-700 hover:bg-rose-200" },
    2: { selected: "bg-orange-500 text-white", unselected: "bg-orange-100 text-orange-700 hover:bg-orange-200" },
    3: { selected: "bg-amber-500 text-white",  unselected: "bg-amber-100 text-amber-700 hover:bg-amber-200" },
    4: { selected: "bg-lime-500 text-white",   unselected: "bg-lime-100 text-lime-700 hover:bg-lime-200" },
    5: { selected: "bg-emerald-500 text-white",unselected: "bg-emerald-100 text-emerald-700 hover:bg-emerald-200" },
  };
  return (
    <div
      id={id}
      className={`space-y-2 sm:space-y-0 sm:flex sm:items-center sm:gap-3 ${
        falta ? "rounded-md ring-2 ring-rose-400 ring-offset-2 p-1.5 -m-1.5" : ""
      }`}
    >
      <div className={`sm:w-20 text-base sm:text-sm font-semibold ${falta ? "text-rose-700" : "text-slate-700"}`}>
        {label}
        {falta && <span className="block text-[11px] font-medium text-rose-600">falta el puntaje</span>}
      </div>
      <div className="grid grid-cols-5 gap-1.5 sm:flex sm:gap-1.5">
        {[1, 2, 3, 4, 5].map((n) => {
          const c = ratingColors[n];
          const selected = rating === n;
          return (
            <button
              key={n}
              onClick={() => onRating(rating === n ? null : n)}
              className={`h-12 sm:w-9 sm:h-9 rounded font-mono font-bold text-base sm:text-sm transition-colors ${selected ? c.selected : c.unselected}`}
            >
              {n}
            </button>
          );
        })}
      </div>
      <div className="flex-1">
        <input
          type="text"
          value={comentario}
          onChange={(e) => onComentario(e.target.value)}
          placeholder="Comentario (opcional)"
          className="w-full px-3 py-2 border border-pepe-border rounded text-sm"
        />
      </div>
    </div>
  );
}

// ─── Sección 4: Condiciones del Banano (Puerta/Medio/Atrás) ──────────

function SectionCondicionesBanano({
  form,
  update,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
}) {
  return (
    <Section title="Condiciones del banano EC">
      <div className="space-y-4">
        <DualRow
          label="Temperatura de pulpa (°C)"
          values={[
            form.temp_pulpa_puerta_1, form.temp_pulpa_puerta_2,
            form.temp_pulpa_medio_1, form.temp_pulpa_medio_2,
            form.temp_pulpa_atras_1, form.temp_pulpa_atras_2,
          ]}
          onChange={[
            (v) => update("temp_pulpa_puerta_1", v), (v) => update("temp_pulpa_puerta_2", v),
            (v) => update("temp_pulpa_medio_1", v), (v) => update("temp_pulpa_medio_2", v),
            (v) => update("temp_pulpa_atras_1", v), (v) => update("temp_pulpa_atras_2", v),
          ]}
        />
        <DualRow
          label="Peso de cajas (kg)"
          values={[
            form.peso_caja_puerta_1, form.peso_caja_puerta_2,
            form.peso_caja_medio_1, form.peso_caja_medio_2,
            form.peso_caja_atras_1, form.peso_caja_atras_2,
          ]}
          onChange={[
            (v) => update("peso_caja_puerta_1", v), (v) => update("peso_caja_puerta_2", v),
            (v) => update("peso_caja_medio_1", v), (v) => update("peso_caja_medio_2", v),
            (v) => update("peso_caja_atras_1", v), (v) => update("peso_caja_atras_2", v),
          ]}
        />
        <SingleRow
          label="Calibración"
          values={[form.calibracion_puerta, form.calibracion_medio, form.calibracion_atras]}
          onChange={[
            (v) => update("calibracion_puerta", v),
            (v) => update("calibracion_medio", v),
            (v) => update("calibracion_atras", v),
          ]}
        />
        <div>
          <div className="flex items-center justify-between mb-2">
            <div className="text-sm font-semibold text-slate-700">
              Longitud banano ({form.longitud_unidad})
            </div>
            <UnitToggle
              value={form.longitud_unidad}
              onChange={(u) => update("longitud_unidad", u)}
            />
          </div>
          <SingleRow
            label=""
            values={[form.longitud_puerta, form.longitud_medio, form.longitud_atras]}
            onChange={[
              (v) => update("longitud_puerta", v),
              (v) => update("longitud_medio", v),
              (v) => update("longitud_atras", v),
            ]}
          />
        </div>
      </div>
    </Section>
  );
}

function UnitToggle({
  value,
  onChange,
}: {
  value: LongitudUnidad;
  onChange: (u: LongitudUnidad) => void;
}) {
  return (
    <div className="inline-flex rounded-md border border-pepe-border overflow-hidden text-xs">
      <button
        type="button"
        onClick={() => onChange("cm")}
        className={`px-2.5 py-1 font-medium ${
          value === "cm" ? "bg-pepe-blue text-white" : "bg-white text-slate-600 hover:bg-slate-50"
        }`}
      >
        cm
      </button>
      <button
        type="button"
        onClick={() => onChange("pulgadas")}
        className={`px-2.5 py-1 font-medium border-l border-pepe-border ${
          value === "pulgadas" ? "bg-pepe-blue text-white" : "bg-white text-slate-600 hover:bg-slate-50"
        }`}
      >
        pulgadas
      </button>
    </div>
  );
}


function DualRow({
  label,
  values,
  onChange,
}: {
  label: string;
  values: (number | null | undefined)[];
  onChange: ((v: number | null) => void)[];
}) {
  // Mobile: stack las 3 zonas verticalmente (cada una con sus 2 inputs lado a lado).
  // Desktop: 3 columnas con cada zona con sus 2 inputs adentro.
  return (
    <div>
      <div className="text-base sm:text-sm font-semibold text-slate-700 mb-2">{label}</div>
      <div className="space-y-2 sm:space-y-0 sm:grid sm:grid-cols-3 sm:gap-3">
        {(["Puerta", "Medio", "Atrás"] as const).map((zona, zi) => (
          <div key={zona} className="flex sm:block items-center gap-3 sm:gap-0">
            <div className="w-16 sm:w-auto shrink-0 sm:mb-1 text-xs uppercase tracking-wider text-slate-500 font-bold sm:text-center">
              {zona}
            </div>
            <div className="grid grid-cols-2 gap-1.5 flex-1">
              <NumberInput
                step="0.01"
                value={values[zi * 2] ?? ""}
                onChange={(e) => onChange[zi * 2](nullableNumber(e.target.value))}
                placeholder="—"
              />
              <NumberInput
                step="0.01"
                value={values[zi * 2 + 1] ?? ""}
                onChange={(e) => onChange[zi * 2 + 1](nullableNumber(e.target.value))}
                placeholder="—"
              />
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function SingleRow({
  label,
  values,
  onChange,
}: {
  label: string;
  values: (number | null | undefined)[];
  onChange: ((v: number | null) => void)[];
}) {
  // Mobile: cada zona en su fila con label a la izquierda + input a la derecha.
  // Desktop: 3 columnas con label arriba e input abajo.
  return (
    <div>
      {label && <div className="text-base sm:text-sm font-semibold text-slate-700 mb-2">{label}</div>}
      <div className="space-y-2 sm:space-y-0 sm:grid sm:grid-cols-3 sm:gap-3">
        {(["Puerta", "Medio", "Atrás"] as const).map((zona, zi) => (
          <div key={zona} className="flex sm:block items-center gap-3 sm:gap-0">
            <div className="w-16 sm:w-auto shrink-0 sm:mb-1 text-xs uppercase tracking-wider text-slate-500 font-bold sm:text-center">
              {zona}
            </div>
            <NumberInput
              step="0.01"
              value={values[zi] ?? ""}
              onChange={(e) => onChange[zi](nullableNumber(e.target.value))}
              placeholder="—"
            />
          </div>
        ))}
      </div>
    </div>
  );
}

// ─── Sección 5: Calificaciones ────────────────────────────────────────

function SectionCalificaciones({
  form,
  update,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
}) {
  return (
    <Section title="Calificación del banano">
      <div className="space-y-3">
        <CalificacionRow label="Corona" value={form.corona ?? null} onChange={(v) => update("corona", v)} />
        <CalificacionRow label="Quemada" value={form.quemada ?? null} onChange={(v) => update("quemada", v)} />
        <CalificacionRow label="Rameada" value={form.rameada ?? null} onChange={(v) => update("rameada", v)} />
      </div>
    </Section>
  );
}

function CalificacionRow({
  label,
  value,
  onChange,
}: {
  label: string;
  value: Calificacion | null;
  onChange: (v: Calificacion | null) => void;
}) {
  const opciones: Calificacion[] = ["Regular", "Buena", "Muy buena"];
  // Colores indicativos: Regular = ámbar, Buena = lime, Muy buena = verde.
  const colorByOp: Record<Calificacion, { selected: string; unselected: string }> = {
    "Regular":   { selected: "bg-amber-500 text-white",   unselected: "bg-amber-50 text-amber-800 border border-amber-200 hover:bg-amber-100" },
    "Buena":     { selected: "bg-lime-500 text-white",    unselected: "bg-lime-50 text-lime-800 border border-lime-200 hover:bg-lime-100" },
    "Muy buena": { selected: "bg-emerald-500 text-white", unselected: "bg-emerald-50 text-emerald-800 border border-emerald-200 hover:bg-emerald-100" },
  };
  return (
    <div className="space-y-1.5 sm:space-y-0 sm:flex sm:items-center sm:gap-3">
      <div className="sm:w-24 text-base sm:text-sm font-semibold text-slate-700">{label}</div>
      <div className="grid grid-cols-3 gap-2 flex-1">
        {opciones.map((op) => {
          const c = colorByOp[op];
          const selected = value === op;
          return (
            <button
              key={op}
              onClick={() => onChange(value === op ? null : op)}
              className={`px-3 py-3 sm:py-2 rounded text-sm font-semibold min-h-[48px] sm:min-h-0 transition-colors ${
                selected ? c.selected : c.unselected
              }`}
            >
              {op}
            </button>
          );
        })}
      </div>
    </div>
  );
}

// ─── Sección 6: Firmas ────────────────────────────────────────────────

function SectionFirmas({
  form,
  update,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
}) {
  return (
    <Section title="Autorizaciones">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <Field label="Descarga autorizada por">
          <UsuarioPicker
            permiso={["pie_camion", "recepcion"]}
            value={form.descarga_autorizada_por ?? null}
            onChange={(v) => update("descarga_autorizada_por", v)}
            placeholder="Elegir del equipo…"
          />
        </Field>
        <Field label="Inspección realizada por">
          <UsuarioPicker
            permiso={["pie_camion", "recepcion"]}
            value={form.inspeccion_realizada_por ?? null}
            onChange={(v) => update("inspeccion_realizada_por", v)}
            placeholder="Elegir del equipo…"
          />
        </Field>
      </div>
      <p className="mt-2 text-[11px] text-slate-500">
        Aparecen los usuarios con acceso a <strong>Pie de camión</strong> o rol <strong>Recepción</strong>. Si te falta alguien, pedile al admin que le dé el acceso.
      </p>
    </Section>
  );
}

// ─── Sección Fotos del camión ─────────────────────────────────────────

function SectionFotosCategorias({
  fotosCat,
  setFotoSlot,
  otras,
  setOtras,
}: {
  fotosCat: Record<string, string[]> | undefined;
  setFotoSlot: (slug: string, fotos: string[]) => void;
  otras: string[];
  setOtras: (fotos: string[]) => void;
}) {
  const cat = fotosCat ?? {};
  return (
    <Section title="Fotos del camión">
      <p className="text-xs text-slate-500 mb-3">
        Sacá las fotos de cada categoría con la cámara o <strong>elegí varias de la galería</strong>.
        Es todo opcional — subí lo que puedas. Van agrupadas por categoría en el PDF que recibe Ingresos.
      </p>

      <div className="space-y-4">
        {FOTO_SECCIONES.map((sec) => (
          <div key={sec.titulo} className="border border-pepe-border rounded-md overflow-hidden">
            <div className="px-3 py-2 bg-slate-50 border-b border-pepe-border">
              <div className="text-sm font-semibold text-slate-800">{sec.titulo}</div>
              {sec.ayuda && <div className="text-xs text-slate-500 mt-0.5">{sec.ayuda}</div>}
            </div>
            <div className="px-3">
              {/* Sub-grupos por posición PRIMERO (Estado de la fruta: Adelante/Medio/Atrás). */}
              {sec.subgrupos?.map((grupo) => (
                <div key={grupo.titulo} className="py-1">
                  <div className="text-xs font-semibold uppercase tracking-wide text-pepe-blue/80 pt-2 pb-1">
                    {grupo.titulo}
                  </div>
                  <div className="divide-y divide-pepe-border/60">
                    {grupo.slots.map((slot) => (
                      <CategoriaFotos
                        key={slot.slug}
                        label={slot.fila}
                        value={cat[slot.slug] ?? []}
                        onChange={(fotos) => setFotoSlot(slot.slug, fotos)}
                      />
                    ))}
                  </div>
                </div>
              ))}
              {/* Slots directos DESPUÉS. En secciones simples son el único contenido;
                  en Estado de la fruta es el código (una vez), separado de las posiciones. */}
              {sec.slots && (
                <div className={`divide-y divide-pepe-border/60 ${sec.subgrupos ? "border-t border-pepe-border/60 mt-2 pt-1" : ""}`}>
                  {sec.slots.map((slot) => (
                    <CategoriaFotos
                      key={slot.slug}
                      label={slot.fila}
                      value={cat[slot.slug] ?? []}
                      onChange={(fotos) => setFotoSlot(slot.slug, fotos)}
                    />
                  ))}
                </div>
              )}
            </div>
          </div>
        ))}

        {/* Otras fotos: galería libre para lo que no encaje en ninguna categoría. */}
        <div className="border border-pepe-border rounded-md overflow-hidden">
          <div className="px-3 py-2 bg-slate-50 border-b border-pepe-border">
            <div className="text-sm font-semibold text-slate-800">Otras fotos</div>
            <div className="text-xs text-slate-500 mt-0.5">Cualquier otra cosa que quieras dejar registrada.</div>
          </div>
          <div className="p-3">
            <PhotoUploader value={otras} onChange={setOtras} />
          </div>
        </div>
      </div>
    </Section>
  );
}

// ─── Sección: Documentación (fotos de los papeles → PDF a Ingresos) ──────

function SectionDocumentacion({
  form,
  update,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
}) {
  return (
    <Section title="Documentación (fotos)">
      <p className="text-xs text-slate-500 mb-3">
        Sacale fotos a los papeles (remitos, certificados, etc.) — una por hoja, bien
        derecho y con buena luz. Con todas se arma un <strong>PDF aparte</strong> que recibe
        Ingresos junto a la planilla.
      </p>
      {/* maxSize alto (2600px) + calidad 0.9: la documentación se estira a toda
          la hoja A4 en el PDF, y a 1600px un papel con letra chica (MIC/DTA,
          recibos de aduana) quedaba borroso (~215 DPI). 2600px → ~260-350 DPI =
          nítido. Son pocas páginas por pie, así que el peso extra no molesta.
          Las fotos del camión NO cambian (siguen livianas, van al anexo chico). */}
      <PhotoUploader
        value={form.documentacion ?? []}
        onChange={(docs) => update("documentacion", docs)}
        maxSize={2600}
        quality={0.9}
      />
    </Section>
  );
}

// ─── Sección 7: Total + observaciones ────────────────────────────────

function SectionTotalObservaciones({
  form,
  update,
  lineas,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
  lineas: LineaDraft[];
}) {
  const totalAuto = Math.round(lineas.reduce((s, l) => s + l.cantidad, 0));
  // Modo manual = el usuario clickeó editar. Se acuerda en form.total_cajas:
  // si está set, es manual. Si es null, mostramos el auto.
  const manualMode = form.total_cajas != null;

  function startEdit() {
    // Al editar, partimos del valor auto actual para que el usuario sólo
    // ajuste si lo necesita.
    update("total_cajas", lineas.length ? totalAuto : 0);
  }
  function backToAuto() {
    update("total_cajas", null);
  }

  return (
    <Section title="Totales y observaciones">
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <Field label={manualMode ? "Total de cajas (manual)" : "Total de cajas (auto)"}>
          {manualMode ? (
            <div className="space-y-1">
              <NumberInput
                step="1"
                value={form.total_cajas ?? ""}
                onChange={(e) => update("total_cajas", nullableNumber(e.target.value) ?? 0)}
                placeholder="0"
              />
              <button
                type="button"
                onClick={backToAuto}
                className="text-[11px] text-pepe-blue hover:text-pepe-blue-dark inline-flex items-center gap-1"
              >
                <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4 4v6h6M20 20v-6h-6M5.5 9a7.5 7.5 0 0113 -2M18.5 15a7.5 7.5 0 01-13 2" />
                </svg>
                Volver al auto ({totalAuto})
              </button>
            </div>
          ) : (
            <div className="space-y-1">
              <div className="w-full px-3 py-2.5 sm:py-1.5 border border-pepe-border rounded text-base sm:text-sm text-right font-mono bg-slate-50 text-slate-700 min-h-[44px] sm:min-h-0 flex items-center justify-end">
                {lineas.length === 0 ? (
                  <span className="text-slate-400 text-xs italic">sin líneas</span>
                ) : (
                  totalAuto.toLocaleString("es-UY")
                )}
              </div>
              <div className="flex items-center justify-between">
                <p className="text-[10px] text-slate-400 leading-tight">
                  Suma de {lineas.length} {lineas.length === 1 ? "línea" : "líneas"}
                </p>
                <button
                  type="button"
                  onClick={startEdit}
                  className="text-[11px] text-pepe-blue hover:text-pepe-blue-dark inline-flex items-center gap-1"
                >
                  <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M16.862 4.487l1.687-1.688a1.875 1.875 0 112.652 2.652L10.582 16.07a4.5 4.5 0 01-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 011.13-1.897l8.932-8.931zm0 0L19.5 7.125M18 14v4.75A2.25 2.25 0 0115.75 21H5.25A2.25 2.25 0 013 18.75V8.25A2.25 2.25 0 015.25 6H10" />
                  </svg>
                  Editar
                </button>
              </div>
            </div>
          )}
        </Field>
        <Field label="Observaciones generales" span={2}>
          <textarea
            value={form.observaciones ?? ""}
            onChange={(e) => update("observaciones", e.target.value || null)}
            placeholder="Anotaciones del viaje (demora, sello, etc.). Defectos de fruta van por línea ↑"
            rows={3}
            className="w-full px-3 py-2 border border-pepe-border rounded text-sm"
          />
        </Field>
      </div>
    </Section>
  );
}

// ─── Sección Cámara de ingreso ───────────────────────────────────────
// A qué cámara de maduración entró la fruta. Default: UNA sola cámara (todo el
// camión). Botón "Separar en varias cámaras" → repartir por cantidad de cajas.

function UbicacionToggle({
  value,
  onChange,
}: {
  value: UbicacionCamara;
  onChange: (u: UbicacionCamara) => void;
}) {
  const opts: UbicacionCamara[] = ["ZAC", "CR"];
  return (
    <div className="inline-flex rounded-lg border border-pepe-border overflow-hidden shrink-0">
      {opts.map((u, i) => (
        <button
          key={u}
          type="button"
          onClick={() => onChange(u)}
          className={`px-4 py-2.5 sm:py-1.5 text-sm font-semibold min-h-[44px] sm:min-h-0 transition-colors ${
            value === u ? "bg-pepe-blue text-white" : "bg-white text-slate-600 hover:bg-slate-50"
          } ${i > 0 ? "border-l border-pepe-border" : ""}`}
        >
          {u}
        </button>
      ))}
    </div>
  );
}

function NumeroCamaraInput({
  ubicacion,
  value,
  onChange,
}: {
  ubicacion: UbicacionCamara;
  value: number | undefined;
  onChange: (n: number) => void;
}) {
  const tope = CAMARAS_POR_UBICACION[ubicacion];
  const tieneNum = value != null && !Number.isNaN(value);
  const shown = tieneNum ? String(value) : "";
  const fuera = tieneNum && (value! < 1 || value! > tope);
  return (
    <div>
      <input
        type="text"
        inputMode="numeric"
        value={shown}
        onChange={(e) => {
          const digits = e.target.value.replace(/\D/g, "").slice(0, 2);
          onChange(digits === "" ? NaN : parseInt(digits, 10));
        }}
        placeholder={`1-${tope}`}
        className={`w-20 px-3 py-2.5 sm:py-1.5 border rounded text-base sm:text-sm text-center font-mono min-h-[44px] sm:min-h-0 ${
          fuera ? "border-rose-400 bg-rose-50 text-rose-700" : "border-pepe-border"
        }`}
      />
      {fuera && <p className="text-[10px] text-rose-600 mt-0.5">En {ubicacion} es 1-{tope}</p>}
    </div>
  );
}

const NUEVA_CAMARA = (ubic: UbicacionCamara = "ZAC"): CamaraInput => ({
  ubicacion: ubic,
  numero: NaN,
  cantidad: null,
  cod_art: null,
});

/** Productos distintos de la mercadería (dedup por cod_art, sumando cajas) — para
 * el desglose producto→cámara del reparto. */
function productosDeLineas(lineas: LineaDraft[]) {
  const map = new Map<string, { cod_art: string; descripcion: string; icono: string | null; total: number }>();
  for (const l of lineas) {
    const cod = l.cod_art.trim();
    if (!cod) continue;
    const cant = Number.isFinite(l.cantidad) ? l.cantidad : 0;
    const e = map.get(cod);
    if (e) e.total += cant;
    else map.set(cod, { cod_art: cod, descripcion: l.descripcion || cod, icono: l.icono, total: cant });
  }
  return [...map.values()];
}

/** Nombre corto de un producto para chips ("Kiwi Chile Calibre 23…" → "Kiwi Chile"). */
function nombreCortoProducto(descripcion: string): string {
  return descripcion.split(/\s+/).slice(0, 2).join(" ");
}

function SectionCamara({
  form,
  update,
  totalCajas,
  lineas,
  falta = false,
}: {
  form: PieDeCamionCreate;
  update: <K extends keyof PieDeCamionCreate>(k: K, v: PieDeCamionCreate[K]) => void;
  totalCajas: number | null;
  lineas: LineaDraft[];
  /** El reparto por cámaras no cierra → se resalta la sección. */
  falta?: boolean;
}) {
  const camaras = form.camaras ?? [];
  // Con varios productos, el reparto se desglosa por producto (una fila = un
  // producto en una cámara). Con uno solo no hace falta preguntar.
  const productos = productosDeLineas(lineas);
  const multiProducto = productos.length > 1;
  const [separado, setSeparado] = useState(() => camaras.length > 1);
  // Al restaurar un borrador con varias cámaras (o si crecen), entrar en modo
  // repartido; si el form se limpió/descartó (cero filas), volver al modo simple.
  useEffect(() => {
    if (camaras.length > 1) setSeparado(true);
    else if (camaras.length === 0) setSeparado(false);
  }, [camaras.length]);

  const setCamaras = (next: CamaraInput[]) => update("camaras", next);

  // ── Simple: una sola cámara. cantidad = null (todas las cajas del camión).
  if (!separado) {
    const c = camaras[0];
    const ubic: UbicacionCamara = c?.ubicacion ?? "ZAC";
    const setUnica = (patch: Partial<CamaraInput>) =>
      setCamaras([
        {
          ubicacion: patch.ubicacion ?? ubic,
          numero: patch.numero !== undefined ? patch.numero : c?.numero ?? NaN,
          cantidad: null,
          cod_art: null,
        },
      ]);
    return (
      <Section id="f-camaras" title="Cámara de ingreso" falta={falta}>
        <p className="text-xs text-slate-500 mb-3">
          ¿A qué cámara de maduración entró la fruta? Por defecto toda la carga va a una sola cámara.
        </p>
        <div className="flex flex-wrap items-end gap-3">
          <div>
            <label className="block text-xs sm:text-[11px] uppercase tracking-wide text-slate-600 sm:text-slate-500 font-semibold mb-1">
              Ubicación
            </label>
            <UbicacionToggle value={ubic} onChange={(u) => setUnica({ ubicacion: u })} />
          </div>
          <div>
            <label className="block text-xs sm:text-[11px] uppercase tracking-wide text-slate-600 sm:text-slate-500 font-semibold mb-1">
              Cámara N°
            </label>
            <NumeroCamaraInput ubicacion={ubic} value={c?.numero} onChange={(n) => setUnica({ numero: n })} />
          </div>
        </div>
        {c && Number.isNaN(c.numero) && (
          <p className="text-[11px] text-amber-600 mt-2 flex items-center gap-1">
            <svg className="w-3.5 h-3.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v4m0 4h.01M10.29 3.86l-8.2 14.2A1.5 1.5 0 003.39 20.5h17.22a1.5 1.5 0 001.3-2.44l-8.2-14.2a1.5 1.5 0 00-2.6 0z" />
            </svg>
            Elegiste la ubicación pero falta el número de la cámara.
          </p>
        )}
        <button
          type="button"
          onClick={() => {
            const base = camaras.length ? camaras : [NUEVA_CAMARA()];
            if (multiProducto) {
              // Varios productos → una fila POR PRODUCTO, con sus cajas pre-cargadas:
              // el operario solo completa el número de cámara de cada una.
              setCamaras(productos.map((p, idx) => ({
                ubicacion: base[0].ubicacion,
                numero: idx === 0 ? base[0].numero : NaN,
                cantidad: p.total > 0 ? Math.round(p.total) : null,
                cod_art: p.cod_art,
              })));
            } else {
              // La primera cámara arranca con TODAS las cajas (no en blanco): repartís
              // agregando cámaras y bajándole a ésta. La 2ª fila queda vacía para llenar.
              const first: CamaraInput = { ...base[0], cantidad: base[0].cantidad ?? totalCajas ?? null };
              setCamaras([first, ...base.slice(1), NUEVA_CAMARA(base[base.length - 1].ubicacion)]);
            }
            setSeparado(true);
          }}
          className="mt-3 inline-flex items-center gap-1.5 py-2.5 sm:py-0 min-h-[44px] sm:min-h-0 text-sm text-pepe-blue hover:text-pepe-blue-dark font-medium"
        >
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M8 7h12m0 0l-4-4m4 4l-4 4M16 17H4m0 0l4 4m-4-4l4-4" />
          </svg>
          Separar en varias cámaras
        </button>
      </Section>
    );
  }

  // ── Repartido: varias cámaras, cada una con su cantidad de cajas (y su producto,
  // si el camión trae varios: cada fila = "N cajas del producto X a la cámara Y").
  const patch = (i: number, p: Partial<CamaraInput>) =>
    setCamaras(camaras.map((c, idx) => (idx === i ? { ...c, ...p } : c)));
  const asignado = camaras.reduce(
    (s, c) => s + (c.cantidad != null && !Number.isNaN(c.cantidad) ? c.cantidad : 0),
    0,
  );
  const resto = totalCajas != null ? totalCajas - asignado : null;
  // Cuánto va asignado de cada producto (para los chips y el auto-carga de cajas).
  const porProducto = productos.map((p) => {
    const asig = camaras.reduce(
      (s, c) => s + (c.cod_art === p.cod_art && c.cantidad != null && !Number.isNaN(c.cantidad) ? c.cantidad : 0),
      0,
    );
    return { ...p, asignado: asig, resto: Math.round(p.total) - asig };
  });
  const faltaProducto =
    multiProducto && camaras.some((c) => !c.cod_art || !productos.some((p) => p.cod_art === c.cod_art));

  return (
    <Section id="f-camaras" title="Cámara de ingreso — repartido" falta={falta}>
      <div className="space-y-2">
        {camaras.map((c, i) => (
          <div key={i} className="flex flex-wrap items-end gap-2 p-2 rounded-lg border border-pepe-border bg-slate-50/60">
            <div>
              <label className="block text-xs sm:text-[11px] uppercase tracking-wide text-slate-600 sm:text-slate-500 font-semibold mb-1">Ubicación</label>
              <UbicacionToggle value={c.ubicacion} onChange={(u) => patch(i, { ubicacion: u })} />
            </div>
            <div>
              <label className="block text-xs sm:text-[11px] uppercase tracking-wide text-slate-600 sm:text-slate-500 font-semibold mb-1">Cámara N°</label>
              <NumeroCamaraInput ubicacion={c.ubicacion} value={c.numero} onChange={(n) => patch(i, { numero: n })} />
            </div>
            {multiProducto && (
              <div className="flex-1 min-w-[150px]">
                <label className="block text-xs sm:text-[11px] uppercase tracking-wide text-slate-600 sm:text-slate-500 font-semibold mb-1">Producto</label>
                <select
                  value={c.cod_art ?? ""}
                  onChange={(e) => {
                    const cod = e.target.value || null;
                    // Auto-cargar las cajas si están vacías: lo que falta asignar de
                    // ese producto (defaults pre-cargados, el operario solo ajusta).
                    let cantidad = c.cantidad;
                    if (cod && (cantidad == null || Number.isNaN(cantidad))) {
                      const p = porProducto.find((pp) => pp.cod_art === cod);
                      if (p && p.resto > 0) cantidad = p.resto;
                    }
                    patch(i, { cod_art: cod, cantidad });
                  }}
                  className={`w-full px-2 py-2.5 sm:py-1.5 border rounded text-base sm:text-sm bg-white min-h-[44px] sm:min-h-0 ${
                    c.cod_art && productos.some((p) => p.cod_art === c.cod_art)
                      ? "border-pepe-border"
                      : "border-amber-400"
                  }`}
                >
                  <option value="">Producto…</option>
                  {productos.map((p) => (
                    <option key={p.cod_art} value={p.cod_art}>{p.descripcion}</option>
                  ))}
                </select>
              </div>
            )}
            <div className="flex-1 min-w-[90px]">
              <label className="block text-xs sm:text-[11px] uppercase tracking-wide text-slate-600 sm:text-slate-500 font-semibold mb-1">Cajas</label>
              <input
                type="text"
                inputMode="numeric"
                value={c.cantidad != null && !Number.isNaN(c.cantidad) ? String(c.cantidad) : ""}
                onChange={(e) => {
                  // 0 (o vacío) = "sin asignar" → null (el back exige cajas >= 1).
                  const n = parseInt(e.target.value.replace(/\D/g, ""), 10);
                  patch(i, { cantidad: n > 0 ? n : null });
                }}
                placeholder="cajas"
                className="w-full px-3 py-2.5 sm:py-1.5 border border-pepe-border rounded text-base sm:text-sm text-right font-mono min-h-[44px] sm:min-h-0"
              />
            </div>
            <button
              type="button"
              onClick={() => {
                const next = camaras.filter((_, idx) => idx !== i);
                setCamaras(next);
                if (next.length <= 1) setSeparado(false);
              }}
              className="p-2.5 text-slate-400 hover:text-rose-600 min-h-[44px] flex items-center"
              title="Quitar esta cámara"
            >
              <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
        ))}
      </div>

      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <button
          type="button"
          onClick={() => setCamaras([...camaras, NUEVA_CAMARA(camaras[camaras.length - 1]?.ubicacion ?? "ZAC")])}
          className="inline-flex items-center gap-1.5 py-2.5 sm:py-0 min-h-[44px] sm:min-h-0 text-sm text-pepe-blue hover:text-pepe-blue-dark font-medium"
        >
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
          </svg>
          Agregar cámara
        </button>
        {multiProducto ? (
          // Estado por producto: cuántas cajas de cada fruta llevás asignadas.
          <div className="flex flex-wrap items-center gap-1.5">
            {porProducto.map((p) => (
              <span
                key={p.cod_art}
                className={`inline-flex items-center gap-1 px-2 py-0.5 rounded border text-xs font-semibold ${
                  p.resto === 0
                    ? "bg-emerald-50 text-emerald-700 border-emerald-200"
                    : p.resto > 0
                      ? "bg-amber-50 text-amber-700 border-amber-200"
                      : "bg-rose-50 text-rose-700 border-rose-200"
                }`}
                title={p.descripcion}
              >
                {p.icono && <img src={`/categorias/${p.icono}.svg`} alt="" className="w-4 h-4 object-contain" />}
                {nombreCortoProducto(p.descripcion)} {p.asignado.toLocaleString("es-UY")}/{Math.round(p.total).toLocaleString("es-UY")}
              </span>
            ))}
          </div>
        ) : (
          totalCajas != null && (
            <span
              className={`text-xs font-semibold ${
                resto === 0 ? "text-emerald-600" : resto! > 0 ? "text-amber-600" : "text-rose-600"
              }`}
            >
              Asignás {asignado.toLocaleString("es-UY")} de {totalCajas.toLocaleString("es-UY")} cajas
              {resto! > 0 && ` · faltan ${resto!.toLocaleString("es-UY")}`}
              {resto! < 0 && ` · sobran ${(-resto!).toLocaleString("es-UY")}`}
            </span>
          )
        )}
      </div>

      {faltaProducto && (
        <p className="mt-2 text-[11px] text-amber-600 flex items-center gap-1">
          <svg className="w-3.5 h-3.5 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v4m0 4h.01M10.29 3.86l-8.2 14.2A1.5 1.5 0 003.39 20.5h17.22a1.5 1.5 0 001.3-2.44l-8.2-14.2a1.5 1.5 0 00-2.6 0z" />
          </svg>
          Falta elegir el producto en alguna cámara.
        </p>
      )}

      <button
        type="button"
        onClick={() => {
          // Descarta todas menos la primera → confirmar si hay más de una con datos
          // (evita perder el reparto de un toque a las 2-6 AM).
          const conDatos = camaras.filter(
            (c) => !Number.isNaN(c.numero) || (c.cantidad != null && !Number.isNaN(c.cantidad)),
          );
          if (conDatos.length > 1 && !window.confirm("Vas a volver a UNA sola cámara y se borran las demás. ¿Seguir?"))
            return;
          // Una sola cámara = va TODO el camión → sin cantidad ni producto.
          setCamaras([{ ...(camaras[0] ?? NUEVA_CAMARA()), cantidad: null, cod_art: null }]);
          setSeparado(false);
        }}
        className="mt-2 inline-flex items-center py-2.5 sm:py-0 min-h-[44px] sm:min-h-0 text-[11px] text-slate-500 hover:text-slate-700 underline"
      >
        Volver a una sola cámara
      </button>
    </Section>
  );
}

// =====================================================================
// HISTORIAL
// =====================================================================

// Lee un File como data URI (data:...;base64,...) SIN comprimir (para el PDF).
function fileToDataUri(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(r.result as string);
    r.onerror = () => reject(new Error("No se pudo leer el archivo"));
    r.readAsDataURL(file);
  });
}

type PdfCand = { name: string; file: File; url: string; size: number };

// El REPORTE va primero: los que NO parecen certificado/validación/calibración
// primero, y a igualdad el más pesado (el reporte suele pesar más que el certificado).
function rankearPdfs(cands: PdfCand[]): PdfCand[] {
  const esCert = (n: string) => /cert|valida|calibr/i.test(n);
  return [...cands].sort((a, b) => Number(esCert(a.name)) - Number(esCert(b.name)) || b.size - a.size);
}

/**
 * Botón "Termógrafo": adjunta el PDF del termógrafo USB (cadena de frío) a un pie.
 * En Chrome/Edge (compu) abre el selector de UNIDAD (el navegador NO puede escanear
 * el USB solo), junta TODOS los .pdf y abre un selector con PREVIEW para elegir cuál
 * (algunos aparatos traen 2: el reporte + un certificado). Safari/Firefox: elegir a
 * mano. El back lo fusiona con la planilla al descargar el informe. Re-subir reemplaza.
 */
function TermografoButton({ pie }: { pie: PieDeCamionListItem }) {
  const qc = useQueryClient();
  const fileRef = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [cands, setCands] = useState<PdfCand[] | null>(null); // != null → modal abierto
  const [confirmarBorrar, setConfirmarBorrar] = useState(false);
  const yaTiene = pie.termografo_pdf_size_bytes != null;

  async function borrar() {
    setBusy(true);
    setErr(null);
    try {
      await borrarTermografoPdf(pie.id);
      await qc.invalidateQueries({ queryKey: ["pie-camion"] });
      setConfirmarBorrar(false);
    } catch (e) {
      const m = (e as Error).message || "";
      const detalle = m.match(/"detail"\s*:\s*"([^"]+)"/);
      setErr(detalle ? detalle[1] : "No se pudo borrar el termógrafo. Probá de nuevo.");
    } finally {
      setBusy(false);
    }
  }

  // Soltar los object URLs de los previews al desmontar (ej. si se va del Historial).
  const candsRef = useRef<PdfCand[] | null>(null);
  candsRef.current = cands;
  useEffect(() => () => candsRef.current?.forEach((c) => URL.revokeObjectURL(c.url)), []);

  // Si el adjunto CAMBIA (se borró, se reemplazó, o lo tocó otro operario en la
  // terminal compartida y llegó por refetch), cancelamos cualquier "¿Borrar?" colgado
  // y su error: si no, el confirm podría reaparecer solo sobre un PDF nuevo y borrar el
  // bueno. Un borrado que FALLA no cambia el adjunto → el error queda visible (correcto).
  const termoIdent = `${pie.termografo_pdf_size_bytes ?? ""}|${pie.termografo_pdf_filename ?? ""}`;
  useEffect(() => {
    setConfirmarBorrar(false);
    setErr(null);
  }, [termoIdent]);

  function cerrarPicker() {
    setCands((prev) => {
      prev?.forEach((c) => URL.revokeObjectURL(c.url));
      return null;
    });
  }

  function abrirCandidatos(files: PdfCand[]) {
    if (!files.length) {
      files.forEach((c) => URL.revokeObjectURL(c.url));
      setErr("No encontré ningún PDF.");
      return;
    }
    setCands(rankearPdfs(files));
  }

  async function adjuntar(c: PdfCand) {
    setBusy(true);
    setErr(null);
    try {
      await subirTermografoPdf(pie.id, await fileToDataUri(c.file), c.name);
      await qc.invalidateQueries({ queryKey: ["pie-camion"] });
      cerrarPicker();
    } catch (e) {
      // El back manda un detalle claro en español; lo mostramos tal cual.
      const m = (e as Error).message || "";
      const detalle = m.match(/"detail"\s*:\s*"([^"]+)"/);
      setErr(detalle ? detalle[1] : "No se pudo adjuntar el PDF. Probá de nuevo.");
    } finally {
      setBusy(false);
    }
  }

  async function onClick() {
    setErr(null);
    setConfirmarBorrar(false); // arrancar una subida cancela cualquier "¿Borrar?" abierto
    const w = window as unknown as { showDirectoryPicker?: () => Promise<unknown> };
    if (typeof w.showDirectoryPicker === "function") {
      // `found` se declara AFUERA del try para poder liberar sus object URLs si la
      // enumeración del USB se corta a mitad (error de lectura) — si no, quedan colgados.
      const found: PdfCand[] = [];
      try {
        setBusy(true);
        const dir = (await w.showDirectoryPicker()) as AsyncIterable<[string, { kind: string; getFile: () => Promise<File> }]>;
        for await (const [name, handle] of dir) {
          if (handle.kind === "file" && name.toLowerCase().endsWith(".pdf")) {
            // getFile() SOBRE el handle vivo (no desprender el método → "Illegal invocation").
            const file = await handle.getFile();
            found.push({ name, file, url: URL.createObjectURL(file), size: file.size });
          }
        }
        setBusy(false);
        if (!found.length) {
          setErr("No encontré ningún PDF en esa unidad. ¿Elegiste la unidad del termógrafo?");
          return;
        }
        abrirCandidatos(found);
      } catch (e) {
        found.forEach((c) => URL.revokeObjectURL(c.url)); // no dejar blobs colgados
        if ((e as { name?: string })?.name !== "AbortError") setErr("No se pudo leer la unidad USB.");
        setBusy(false);
      }
    } else {
      fileRef.current?.click();
    }
  }

  function onFile(files: FileList | null) {
    const f = files?.[0];
    if (fileRef.current) fileRef.current.value = "";
    if (f) abrirCandidatos([{ name: f.name, file: f, url: URL.createObjectURL(f), size: f.size }]);
  }

  return (
    <span className="inline-flex flex-col items-end">
      <button
        type="button"
        onClick={onClick}
        disabled={busy}
        title={
          yaTiene
            ? `Adjunto: ${pie.termografo_pdf_filename ?? "PDF"} — clic para reemplazar`
            : "Agregar PDF del termógrafo (USB)"
        }
        className={`inline-flex items-center gap-1 px-3 sm:px-2 py-1 min-h-[44px] sm:min-h-0 rounded border text-xs disabled:opacity-50 ${
          yaTiene
            ? "border-emerald-300 bg-emerald-50 text-emerald-800 hover:bg-emerald-100"
            : "border-pepe-border bg-white text-slate-700 hover:bg-slate-50"
        }`}
      >
        {busy && !cands ? (
          <svg className="w-3.5 h-3.5 animate-spin" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
          </svg>
        ) : yaTiene ? (
          <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
          </svg>
        ) : (
          <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 3v18M3 12h18M6 6l12 12M18 6L6 18" />
          </svg>
        )}
        Termógrafo
      </button>
      <input ref={fileRef} type="file" accept="application/pdf,.pdf" className="hidden" onChange={(e) => onFile(e.target.files)} />
      {yaTiene && !confirmarBorrar && (
        <span className="inline-flex items-center gap-1 mt-0.5 max-w-[170px]">
          {pie.termografo_pdf_filename && (
            <button
              type="button"
              onClick={() => void openTermografoPdf(pie.id)}
              disabled={busy}
              className="text-[10px] text-emerald-700 hover:text-emerald-900 underline truncate disabled:opacity-50"
              title={`Ver: ${pie.termografo_pdf_filename}`}
            >
              {pie.termografo_pdf_filename}
            </button>
          )}
          <button
            type="button"
            onClick={() => { setErr(null); setConfirmarBorrar(true); }}
            disabled={busy}
            className="shrink-0 text-slate-400 hover:text-rose-600 disabled:opacity-50"
            title="Borrar el termógrafo adjunto"
            aria-label="Borrar el termógrafo adjunto"
          >
            <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 7h12M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2m-7 0v11a1 1 0 001 1h6a1 1 0 001-1V7" />
            </svg>
          </button>
        </span>
      )}
      {yaTiene && confirmarBorrar && (
        <span className="inline-flex items-center gap-1.5 mt-0.5">
          <span className="text-[10px] text-slate-600">¿Borrar?</span>
          <button
            type="button"
            onClick={() => void borrar()}
            disabled={busy}
            className="text-[10px] font-semibold px-1.5 py-0.5 rounded bg-rose-600 text-white hover:bg-rose-700 disabled:opacity-50"
          >
            {busy ? "Borrando…" : "Sí, borrar"}
          </button>
          <button
            type="button"
            onClick={() => { setConfirmarBorrar(false); setErr(null); }}
            disabled={busy}
            className="text-[10px] px-1.5 py-0.5 rounded border border-pepe-border text-slate-600 hover:bg-slate-50 disabled:opacity-50"
          >
            No
          </button>
        </span>
      )}
      {err && !cands && <span className="text-[10px] text-rose-600 mt-0.5 max-w-[150px] text-right">{err}</span>}
      {cands && (
        <TermografoPicker cands={cands} busy={busy} err={err} yaTiene={yaTiene} onAdjuntar={adjuntar} onClose={cerrarPicker} />
      )}
    </span>
  );
}

// Modal: previsualiza los PDFs del USB y deja elegir cuál adjuntar.
function TermografoPicker({
  cands,
  busy,
  err,
  yaTiene,
  onAdjuntar,
  onClose,
}: {
  cands: PdfCand[];
  busy: boolean;
  err: string | null;
  yaTiene: boolean;
  onAdjuntar: (c: PdfCand) => void;
  onClose: () => void;
}) {
  const [sel, setSel] = useState(0);
  const c = cands[Math.min(sel, cands.length - 1)];
  const varios = cands.length > 1;
  return (
    <div
      className="fixed inset-0 z-[90] bg-black/60 flex items-center justify-center p-4"
      onClick={() => { if (!busy) onClose(); }}
    >
      <div
        className="bg-white rounded-xl w-full max-w-3xl h-[85dvh] sm:h-[85vh] flex flex-col overflow-hidden shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="px-4 py-3 border-b border-pepe-border flex items-start justify-between gap-3">
          <div>
            <h3 className="font-semibold text-slate-900">
              {varios ? "Elegí el PDF del termógrafo" : "Confirmá el PDF del termógrafo"}
            </h3>
            <p className="text-xs text-slate-500 mt-0.5">
              {varios
                ? `Este USB trae ${cands.length} PDFs. Previsualizá y elegí el del reporte de temperatura.`
                : "Revisá que sea el correcto antes de adjuntarlo."}
            </p>
          </div>
          <button type="button" onClick={onClose} className="p-1.5 text-slate-400 hover:text-slate-700 shrink-0" title="Cerrar">
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="flex-1 min-h-0 flex flex-col sm:flex-row">
          {varios && (
            <div className="w-full max-h-36 border-b border-pepe-border sm:w-52 sm:max-h-none sm:border-b-0 sm:border-r shrink-0 overflow-y-auto p-2 space-y-1">
              {cands.map((cd, i) => (
                <button
                  key={i}
                  type="button"
                  onClick={() => setSel(i)}
                  className={`w-full text-left px-2 py-2 rounded text-xs ${
                    i === sel ? "bg-pepe-blue/10 border border-pepe-blue/40" : "border border-transparent hover:bg-slate-50"
                  }`}
                >
                  <div className="font-medium text-slate-800 truncate" title={cd.name}>{cd.name}</div>
                  <div className="text-[10px] text-slate-400">{Math.round(cd.size / 1024)} KB</div>
                </button>
              ))}
            </div>
          )}
          <iframe title="Vista previa del PDF" src={c.url} className="flex-1 min-w-0 bg-slate-100" />
        </div>

        <div className="px-4 py-3 border-t border-pepe-border flex items-center justify-between gap-3">
          {err ? (
            <span className="text-xs text-rose-600 truncate max-w-[50%]" title={err}>{err}</span>
          ) : (
            <span className="text-xs text-slate-500 truncate max-w-[50%]" title={c.name}>{c.name}</span>
          )}
          <div className="flex items-center gap-2 shrink-0">
            <button
              type="button"
              onClick={onClose}
              disabled={busy}
              className="px-3 py-2 rounded border border-pepe-border bg-white text-sm font-medium text-slate-700 hover:bg-slate-100 disabled:opacity-50"
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={() => onAdjuntar(c)}
              disabled={busy}
              className="px-4 py-2 rounded bg-pepe-blue text-white text-sm font-semibold hover:bg-pepe-blue-dark disabled:opacity-50"
            >
              {busy ? "Adjuntando…" : yaTiene ? "Reemplazar con este" : "Adjuntar este PDF"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function HistorialView() {
  const { data: items = [], isLoading } = useQuery({
    queryKey: ["pie-camion"],
    queryFn: () => listPieCamion(),
    refetchInterval: 60_000,
  });
  // Agregar fotos a un pie ya enviado (se anexan al informe).
  const [fotosDe, setFotosDe] = useState<PieDeCamionListItem | null>(null);

  return (
    <section className="bg-white border border-pepe-border rounded-md overflow-hidden">
      {/* Regla de la casa: tabla ancha va en .tabla-scroll + min-w (ver index.css). */}
      <div className="tabla-scroll">
      <table className="w-full min-w-[860px] text-sm">
        <thead className="bg-slate-100">
          <tr className="text-left text-xs uppercase tracking-wide text-slate-600">
            <th className="px-4 py-2 font-semibold w-16">ID</th>
            <th className="px-4 py-2 font-semibold w-28">Fecha</th>
            <th className="px-4 py-2 font-semibold w-24">Hora</th>
            <th className="px-4 py-2 font-semibold">Chofer / Placa</th>
            <th className="px-4 py-2 font-semibold">Producto / Exportador</th>
            <th className="px-4 py-2 font-semibold w-20 text-right">Cajas</th>
            <th className="px-4 py-2 font-semibold w-32">Cargado por</th>
            <th className="px-4 py-2 font-semibold w-72 text-right">Informe / termógrafo</th>
          </tr>
        </thead>
        <tbody>
          {isLoading && (
            <tr><td colSpan={8} className="px-4 py-6 text-center text-slate-400">Cargando…</td></tr>
          )}
          {!isLoading && items.length === 0 && (
            <tr><td colSpan={8} className="px-4 py-6 text-center text-slate-400">
              No hay registros de pie de camión todavía.
            </td></tr>
          )}
          {items.map((p) => (
            <tr key={p.id} className="border-t border-pepe-border">
              <td className="px-4 py-1.5 font-mono text-xs">#{p.id}</td>
              <td className="px-4 py-1.5">{formatDate(p.fecha)}</td>
              <td className="px-4 py-1.5 text-xs text-slate-600 font-mono">
                {p.hora_inicio || "—"}
                {p.hora_fin && <> → {p.hora_fin}</>}
              </td>
              <td className="px-4 py-1.5">
                <div className="font-medium text-slate-900">{p.chofer_nombre}</div>
                <div className="text-xs font-mono text-slate-500">{p.placa_camion}</div>
              </td>
              <td className="px-4 py-1.5 text-xs">
                <div>{p.producto ?? "—"}</div>
                <div className="text-slate-500">{p.exportador ?? "—"}</div>
              </td>
              <td className="px-4 py-1.5 text-right font-mono">{p.total_cajas ?? "—"}</td>
              <td className="px-4 py-1.5 text-xs text-slate-600">{p.creado_por_usuario ?? "—"}</td>
              <td className="px-4 py-1.5">
                <div className="flex items-center gap-1.5 justify-end">
                  {/* Agregar fotos DESPUÉS de enviar el pie: se anexan al final
                      del informe (no reemplazan ni reordenan las anteriores). */}
                  <button
                    onClick={() => setFotosDe(p)}
                    className="inline-flex items-center gap-1 px-3 sm:px-2 py-1 min-h-[44px] sm:min-h-0 rounded border border-pepe-border bg-white text-xs hover:bg-slate-50"
                    title="Agregar fotos a este pie (se anexan al informe)"
                  >
                    <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
                      <path strokeLinecap="round" strokeLinejoin="round" d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
                    </svg>
                    Fotos
                    {(p.fotos_anexos_n ?? 0) > 0 && (
                      <span className="ml-0.5 rounded bg-emerald-100 px-1 text-[10px] font-bold text-emerald-700">
                        +{p.fotos_anexos_n}
                      </span>
                    )}
                  </button>
                  <TermografoButton pie={p} />
                  <button
                    onClick={() => void openPieCamionPdf(p.id)}
                    className="inline-flex items-center gap-1 px-3 sm:px-2 py-1 min-h-[44px] sm:min-h-0 rounded border border-pepe-border bg-white text-xs hover:bg-slate-50"
                    title="Ver informe (planilla + termógrafo si tiene)"
                  >
                    <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M19 14l-7 7m0 0l-7-7m7 7V3" />
                    </svg>
                    PDF
                  </button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      </div>
      {fotosDe && <AgregarFotosModal pie={fotosDe} onClose={() => setFotosDe(null)} />}
    </section>
  );
}
