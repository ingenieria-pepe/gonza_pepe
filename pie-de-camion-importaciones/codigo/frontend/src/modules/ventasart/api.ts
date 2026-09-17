import { API_URL, AUTH_TOKEN_KEY, apiGet } from "../../api/client";

export interface FilaDetalleVenta {
  fecha: string;
  comprobante: string;
  nro_doc: number | null;
  codart: string;
  descripcion: string;
  deposito: string;
  cantidad: number;
  /** Precio unitario cargado en la línea de Macrosoft (con IVA, salvo los
   *  artículos "Super" que vienen sin IVA). Solo en la vista completa. */
  precio_lista?: number;
  /** Solo en la vista completa (contadora): el back los recorta para caja. */
  importe_sin_iva?: number;
  iva?: number;
  /** Con impuestos (= importe_sin_iva + iva, mismo signo). */
  importe: number;
  /** importe / cantidad de la línea. null con cantidad 0. */
  precio_unitario: number | null;
  cod_cliente: number | null;
  cliente: string;
  ruc: string;
  vendedor: string;
  tipo_cfe: string;
  efact_serie: string;
  efact_nro: number | null;
  /** Identidad interna del comprobante en Macrosoft (Documento + NroFact). */
  doc_cod: string;
  nrofact: number | null;
  /** Si la línea es de una N/C: la factura que anula (Lineas.DocRef +
   *  Lineas.Referencia — el mismo mecanismo con que imputan los recibos).
   *  null = sin referencia (ej. líneas de descuento de la N/C). */
  ref_doc: string | null;
  ref_nrofact: number | null;
}

export interface InformeVentas {
  filas: FilaDetalleVenta[];
  totales: {
    lineas: number;
    cantidad: number;
    /** Solo en la vista completa (contadora). */
    importe_sin_iva?: number;
    iva?: number;
    importe: number;
  };
  /** La decide el BACK según permisos: "cajero" llega sin desglose de IVA. */
  vista: "completa" | "cajero";
  desde: string;
  hasta: string;
  /** Comprobantes de venta del rango en OTRA moneda (no se suman, se avisa). */
  otras_monedas_n: number;
  cliente: { cod: number; nombre: string } | null;
  articulo: { cod: string; descripcion: string } | null;
  /** true = vinieron las primeras N líneas; el Excel baja todo. */
  truncado: boolean;
}

export interface ClienteBusqueda {
  cod: number;
  nombre: string;
  ruc: string;
}

export interface ArticuloBusqueda {
  cod: string;
  descripcion: string;
}

/** Los dos filtros opcionales del informe (sin ninguno = todas las ventas). */
export interface FiltrosInforme {
  cliente: ClienteBusqueda | null;
  articulo: ArticuloBusqueda | null;
  /** Solo facturas a crédito con saldo sin cancelar (recibos + N/C imputados). */
  pendientes?: boolean;
}

function qsFiltros(f: FiltrosInforme): string {
  const c = f.cliente ? `&cliente=${f.cliente.cod}` : "";
  const a = f.articulo ? `&articulo=${encodeURIComponent(f.articulo.cod)}` : "";
  const p = f.pendientes ? "&pendientes=true" : "";
  return c + a + p;
}

export function verInformeVentas(desde: string, hasta: string, f: FiltrosInforme) {
  return apiGet<InformeVentas>(`/ventas-articulos?desde=${desde}&hasta=${hasta}${qsFiltros(f)}`);
}

export function buscarClientes(q: string) {
  return apiGet<ClienteBusqueda[]>(`/ventas-articulos/clientes?q=${encodeURIComponent(q)}`);
}

export function buscarArticulos(q: string) {
  return apiGet<ArticuloBusqueda[]>(`/ventas-articulos/articulos?q=${encodeURIComponent(q)}`);
}

async function bajarExport(
  formato: "excel" | "pdf", desde: string, hasta: string, f: FiltrosInforme,
): Promise<void> {
  const token = localStorage.getItem(AUTH_TOKEN_KEY);
  const res = await fetch(
    `${API_URL}/ventas-articulos/${formato}?desde=${desde}&hasta=${hasta}${qsFiltros(f)}`,
    { headers: token ? { Authorization: `Bearer ${token}` } : {} },
  );
  if (!res.ok) throw new Error(await res.text());
  const blob = await res.blob();
  const objUrl = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = objUrl;
  const ddmm = (x: string) => x.split("-").reverse().join(".");
  const suf = (f.cliente ? ` - ${f.cliente.nombre || f.cliente.cod}` : "") +
    (f.articulo ? ` - ${f.articulo.descripcion || f.articulo.cod}` : "");
  const ext = formato === "excel" ? "xlsx" : "pdf";
  a.download = `INFORME DE VENTAS ${ddmm(desde)} al ${ddmm(hasta)}${suf}.${ext}`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(objUrl);
}

/** Vista completa (contadora): Excel con el desglose de IVA. */
export function descargarExcelVentas(desde: string, hasta: string, f: FiltrosInforme): Promise<void> {
  return bajarExport("excel", desde, hasta, f);
}

/** Vista cajero: PDF sin desglose de IVA (no editable — por eso no hay Excel). */
export function descargarPdfVentas(desde: string, hasta: string, f: FiltrosInforme): Promise<void> {
  return bajarExport("pdf", desde, hasta, f);
}
