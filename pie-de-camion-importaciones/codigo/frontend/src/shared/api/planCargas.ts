import { API_URL, apiDelete, apiGet, apiPatch, apiPost } from "../../api/client";

// 'Cargado'/'Mar'/'Puerto'/'Destruida' vienen de la planilla de OTROS países
// (lo de ultramar viaja en barco). Sincronizar con StatusCarga del back.
export type StatusCarga =
  | "Solicitado"
  | "Confirmado"
  | "Cargado"
  | "Mar"
  | "Puerto"
  | "Frontera"
  | "Liberado"
  | "Arribado"
  | "Descargado"
  | "Cancelado"
  | "Destruida";

export const STATUS_VALUES: StatusCarga[] = [
  "Solicitado",
  "Confirmado",
  "Cargado",
  "Mar",
  "Puerto",
  "Frontera",
  "Liberado",
  "Arribado",
  "Descargado",
  "Cancelado",
  "Destruida",
];

export const STATUS_PENDIENTES: StatusCarga[] = [
  "Solicitado",
  "Confirmado",
  "Cargado",
  "Mar",
  "Puerto",
  "Frontera",
  "Liberado",
  "Arribado",
];

// De qué planilla viene cada fila: BR = Brasil/Paraguay; OTROS = demás países.
export type FuenteCarga = "BR" | "OTROS";

export interface ProductoCarga {
  descripcion: string;
  icono: string | null;
  cod_art: string | null;   // lo setea el picker; los importados del Drive = null
}

export interface PlanCarga {
  id: number;
  carga_semana: string | null;
  status: StatusCarga;
  factura: string | null;
  productor: string | null;
  fecha_carga: string | null;        // YYYY-MM-DD
  carpeta_import: string | null;
  afidi: string | null;

  transportista: string | null;
  exportador: string | null;
  placa_camion: string | null;
  placa_remolque: string | null;
  chofer: string | null;
  celular: string | null;

  fecha_frontera: string | null;
  frontera: string | null;
  inspector_mgap: string | null;
  fecha_descarga: string | null;

  tt: number | null;
  cajas_mic: number | null;
  cajas_desc: number | null;
  cant_pallet: number | null;
  cant_kilos_caja: number | null;
  codigo_viaje: string | null;
  mic: string | null;

  observaciones: string | null;

  productos: ProductoCarga[];
  pais_origen: string | null;
  fuente: FuenteCarga;

  creado_en: string;
  actualizado_en: string;
  creado_por_usuario: string | null;
  actualizado_por_usuario: string | null;
}

export type PlanCargaCreate = Omit<
  PlanCarga,
  "id" | "creado_en" | "actualizado_en" | "creado_por_usuario" | "actualizado_por_usuario"
>;

export type PlanCargaUpdate = Partial<PlanCargaCreate>;

// Datos que se repiten para una misma factura (autollenado del form). NO trae
// productor (eso cambia por carga). Vacío {} si la factura no se conoce.
export interface FacturaDatos {
  carpeta_import?: string | null;
  exportador?: string | null;
  frontera?: string | null;
  transportista?: string | null;
  afidi?: string | null;
}
export const getFacturaDatos = (factura: string) =>
  apiGet<FacturaDatos>(`/plan-cargas/factura-datos?factura=${encodeURIComponent(factura)}`);

// Facturas conocidas (carpetas + plan) para el combobox del form.
export const getFacturas = () => apiGet<string[]>("/plan-cargas/facturas");

interface ListFilters {
  status?: StatusCarga;
  productor?: string;
  frontera?: string;
  fuente?: FuenteCarga;
  pendientes?: boolean;
  limit?: number;
}

export function listPlanCargas(filters: ListFilters = {}) {
  const params = new URLSearchParams();
  if (filters.status) params.set("status", filters.status);
  if (filters.productor) params.set("productor", filters.productor);
  if (filters.frontera) params.set("frontera", filters.frontera);
  if (filters.fuente) params.set("fuente", filters.fuente);
  if (filters.pendientes) params.set("pendientes", "true");
  if (filters.limit) params.set("limit", String(filters.limit));
  const qs = params.toString();
  return apiGet<PlanCarga[]>(`/plan-cargas${qs ? `?${qs}` : ""}`);
}

export function getPlanCarga(id: number) {
  return apiGet<PlanCarga>(`/plan-cargas/${id}`);
}

export function createPlanCarga(body: PlanCargaCreate) {
  return apiPost<PlanCarga>("/plan-cargas", body);
}

export function updatePlanCarga(id: number, body: PlanCargaUpdate) {
  return apiPatch<PlanCarga>(`/plan-cargas/${id}`, body);
}

export function cancelPlanCarga(id: number) {
  return apiDelete(`/plan-cargas/${id}`);
}

// Borra la carga definitivamente (con confirmación en el front). Falla (409) si
// está vinculada a un Pie de Camión.
export function deletePlanCarga(id: number) {
  return apiDelete(`/plan-cargas/${id}?definitivo=true`);
}

// ── Puente OneDrive (read-only, temporal): estado + disparo de sync ────────
export interface SyncFuenteEstado {
  activo: boolean;
  ultima_sync: string | null; // ISO datetime
  ok: boolean | null;
  filas: number | null;
  mensaje: string;
}

export interface SyncEstado extends SyncFuenteEstado {
  // activo = hay ALGÚN puente activo; el top-level espeja la fuente BR (compat).
  // Detalle por planilla (el banner muestra el del tab activo):
  fuentes?: Record<FuenteCarga, SyncFuenteEstado>;
}

// Lee el estado del último sync (sin disparar nada).
export function getSyncEstado() {
  return apiGet<SyncEstado>("/plan-cargas/sync/estado");
}

// Dispara un sync. force=false: baja sólo si el Excel cambió (lo usa el poll de
// 30s). force=true: baja sí o sí (el botón "Sincronizar ahora").
export function syncPlanCargas(force = false) {
  return apiPost<SyncEstado>(`/plan-cargas/sync?force=${force}`);
}

// Monitor: misma data, endpoint distinto. En la TV (kiosko) va con el token
// ?k=; logueado, apiGet manda el header de sesión.
export function listMonitorCamiones(k?: string) {
  const qs = k ? `?k=${encodeURIComponent(k)}` : "";
  return apiGet<PlanCarga[]>(`/monitor-camiones${qs}`);
}

/**
 * Descarga el plan como .xlsx (con Authorization header — un <a href> directo
 * no andaría). Dispara la descarga del archivo en el browser.
 */
export async function exportPlanCargasExcel(pendientes: boolean, fuente?: FuenteCarga): Promise<void> {
  const token = localStorage.getItem("aloha.auth_token") ?? "";
  const qs = `pendientes=${pendientes}${fuente ? `&fuente=${fuente}` : ""}`;
  const r = await fetch(`${API_URL}/plan-cargas/export.xlsx?${qs}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!r.ok) throw new Error(`No se pudo exportar (${r.status})`);
  const blob = await r.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = `plan-cargas-${new Date().toISOString().slice(0, 10)}.xlsx`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
