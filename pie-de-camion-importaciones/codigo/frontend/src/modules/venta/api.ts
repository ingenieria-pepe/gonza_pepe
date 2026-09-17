import { apiGet, apiPost, apiPut } from "../../api/client";

// ── Tipos ────────────────────────────────────────────────────────────────

export interface ClienteVenta {
  cod: number;
  nombre: string;
  ruc: string;
  direccion: string;
  moneda: number;
  estado_cliente: string; // 'Activo' / 'De Baja' / 'Suspendido' / ''
  pedidos_recientes: number;
}

/** Cliente 999901 del legacy: venta anónima, el nombre se pisa con el del comprador. */
export const CONSUMIDOR_FINAL_COD = 999901;

export interface LineaHistorial {
  cod_art: string;
  descripcion: string;
  cantidad: number; // bultos
  precio: number;
  total_linea: number;
  icono: string | null;
}

export interface PedidoHistorial {
  nro_fact: number;
  nro_doc: string;
  fecha: string | null;
  vendedor_nombre: string | null;
  total: number;
  lineas: LineaHistorial[];
}

export interface UltimoPrecio {
  cod_art: string;
  /** Precio de LISTA (el que fija Valeria en Macrosoft) — la base del ±%. */
  precio_lista: number | null;
  precio: number | null; // último a ESTE cliente (referencia/fallback)
  fecha: string | null;
  precio_global: number | null;
  fecha_global: string | null;
}

export interface LineaPedido {
  cod_art: string;
  descripcion: string;
  icono: string | null;
  cantidad: string; // input controlado (text + inputMode numeric)
  precio: string;
  /** Precio de referencia (último vendido) para el slider −10%/+20%. null = sin referencia. */
  base: number | null;
}

export interface PedidoVentaListItem {
  /** Marcado como PRIORITARIO (sale YA) por un vendedor. */
  prioritario?: boolean;
  nro_fact: number;
  nro_doc: string;
  fecha: string | null;
  hora: string | null;
  cliente_nombre: string;
  cliente_cod: number | null;
  vendedor: number | null;
  vendedor_nombre: string;
  total: number | null;
  credito: boolean;
  estado: string; // 'anulado' | 'en_caja' | 'facturado' | 'entregado' | ...
  observaciones: string;
  es_mio: boolean;
  creado_por: string | null;
  anulable: boolean;
  iconos: string[];              // resumen (con conResumen): íconos de fruta, por bultos desc
  total_bultos: number | null;  // resumen (con conResumen): suma de bultos del pedido
  // Pedido de puros descuentos (artículos D*): no se arma ni se entrega, así
  // que no se puede marcar prioritario. Sólo viaja con conResumen.
  solo_descuentos: boolean;
  videos: number;                // videos del pallet grabados al entregar
}

export interface LineaPedidoOut {
  id: number;
  cod_art: string;
  descripcion: string;
  deposito: string;
  cantidad: number;
  precio: number;
  total_linea: number;
  icono: string | null;
}

export interface PedidoVentaDetail extends PedidoVentaListItem {
  lineas: LineaPedidoOut[];
}

export interface VentaVendedorItem {
  usuario_id: number;
  usuario_nombre: string;
  username: string;
  vendedor: number | null;
  vendedor_nombre: string | null;
  actualizado_en: string | null;
}

export interface EscrituraConfigVenta {
  /** true = ambiente con Macrosoft conectado (prod); false = dev/testing (no envía). */
  conectado: boolean;
}

// ── Llamadas ─────────────────────────────────────────────────────────────

export const getEscrituraConfigVenta = () =>
  apiGet<EscrituraConfigVenta>("/venta/escritura-config");

export const searchClientesVenta = (q: string, limit = 30) =>
  apiGet<ClienteVenta[]>(`/venta/clientes?q=${encodeURIComponent(q)}&limit=${limit}`);

/** Últimas N compras del cliente (producto + precio que le hicimos + bultos). */
export const getHistorialCliente = (cod: number, limit = 3) =>
  apiGet<PedidoHistorial[]>(`/venta/clientes/${cod}/historial?limit=${limit}`);

export const getUltimosPrecios = (clienteCod: number | null, codArts: string[]) =>
  apiPost<UltimoPrecio[]>("/venta/ultimos-precios", {
    cliente_cod: clienteCod,
    cod_arts: codArts,
  });

export const crearPedidoVenta = (body: {
  prioritario?: boolean;
  cliente_cod: number;
  consumidor_nombre?: string | null;
  credito: boolean;
  deposito: "A" | "B";
  observaciones?: string | null;
  lineas: { cod_art: string; cantidad: number; precio: number }[];
  /** UUID por intento de envío (idempotencia: reintentar tras timeout no duplica). */
  ref: string;
  /** Encadenar como AGREGADO del pedido original del cliente (nro_fact). */
  agregado_de?: number | null;
}) => apiPost<{ nro_fact: number; nro_doc: string; total: number }>("/venta/pedidos", body);

// ── Agregados ("el cliente agrega productos") ────────────────────────────

export interface PedidoHoyCliente {
  nro_fact: number;
  nro_doc: string;
  hora: string | null;
  /** ENCUOTAS del original — el agregado encadenado lo hereda como default. */
  credito: boolean;
  /** Sigue en la cola de caja (FACTURADO=0) → se le pueden agregar líneas. */
  en_caja: boolean;
  estado: string; // '' (en caja) | PENDIENTE | ASIGNADO | ENTREGADO | PARCIAL | ...
  deposito: string | null;
  total: number;
  items_count: number;
  solo_descuentos: boolean;
  armador_nombre: string;
  armado: boolean;
  entregado_registrado: boolean;
  agregado_de: number | null;
  resumen: string;
}

/** Pedidos de HOY del cliente — para ofrecer "agregar productos" en el tomador. */
export const getPedidosHoyCliente = (cod: number) =>
  apiGet<PedidoHoyCliente[]>(`/venta/clientes/${cod}/pedidos-hoy`);

/** Agrega líneas a un pedido que SIGUE en caja. Solo el 409 con marcador
 *  YA_FACTURADO significa "salió de caja" (→ ofrecer encadenar); cualquier
 *  otro 409 es un envío en vuelo y NO hay que auto-convertir (duplicaría). */
export const agregarLineasPedido = (
  nroFact: number,
  body: {
    lineas: { cod_art: string; cantidad: number; precio: number }[];
    ref: string;
    cliente_cod: number;
  },
) =>
  apiPost<{
    nro_fact: number;
    nro_doc: string;
    lineas_agregadas: number;
    total_agregado: number;
    total_pedido: number;
  }>(`/venta/pedidos/${nroFact}/agregar-lineas`, body);

/** Extrae el `detail` legible de un error de la API (el client antepone
 *  "API 400 Bad Request: {json}" → JSON.parse directo nunca anda). */
export function errorLegible(msg: string): string {
  const m = msg.match(/"detail"\s*:\s*"([^"]+)"/);
  // El prefijo YA_FACTURADO es un marcador para el front, no para el usuario.
  return (m ? m[1] : msg).replace(/^YA_FACTURADO:\s*/, "");
}

export const listPedidosVenta = (params: {
  scope?: "mios" | "todos";
  cliente?: number;
  vendedor?: number;
  fecha?: string;
  conResumen?: boolean;
  limit?: number;
}) => {
  const qs = new URLSearchParams();
  if (params.scope) qs.set("scope", params.scope);
  if (params.cliente != null) qs.set("cliente", String(params.cliente));
  if (params.vendedor != null) qs.set("vendedor", String(params.vendedor));
  if (params.fecha) qs.set("fecha", params.fecha);
  if (params.conResumen) qs.set("con_resumen", "true");
  if (params.limit) qs.set("limit", String(params.limit));
  return apiGet<PedidoVentaListItem[]>(`/venta/pedidos?${qs.toString()}`);
};

export const getPedidoVenta = (nroFact: number) =>
  apiGet<PedidoVentaDetail>(`/venta/pedidos/${nroFact}`);

export const anularPedidoVenta = (nroFact: number) =>
  apiPost<{ ok: boolean }>(`/venta/pedidos/${nroFact}/anular`, {});

export const getVendedoresConfig = () =>
  apiGet<VentaVendedorItem[]>("/venta/vendedores-config");

export const setVendedorUsuario = (usuarioId: number, vendedor: number | null) =>
  apiPut<{ ok: boolean }>("/venta/vendedores-config", { usuario_id: usuarioId, vendedor });

// ── Stock disponible ─────────────────────────────────────────────────────
// El pedido '30' NO descuenta stock en Macrosoft (lo descuenta la factura de
// caja), así que el saldo oficial no se mueve entre que un vendedor carga y
// que caja factura — y otro vendedor puede vender la misma fruta. El back le
// resta los pedidos vigentes; acá además se restan las líneas del borrador,
// que todavía no existen en ningún lado.

export interface StockDisponibleArticulo {
  cod_art: string;
  cod_stock: string;
  familia: string | null;
  saldo_familia: number;
  comprometido: number;
  /** saldo − comprometido. Puede venir NEGATIVO: es el residuo del ledger de
   *  maduración (Banana Fibra −90, Naranja −1), no un faltante. Se muestra
   *  como "sin stock". */
  disponible: number;
  pedidos_pendientes: number;
  ranking: number;
}

export interface StockDisponibleResp {
  generado_en: string;
  /** Última vez que el mirror recalculó el saldo. null = todavía sin lectura:
   *  no mostrar ceros como si fueran datos. */
  macrosoft_actualizado_en: string | null;
  disponible: StockDisponibleArticulo[];
}

export const getStockDisponible = () =>
  apiGet<StockDisponibleResp>("/venta/stock-disponible");

/** El back ya mandó en cada artículo el número de SU familia, así que alcanza
 *  con indexar por código. Se guarda también el `cod_stock` porque el borrador
 *  hay que restarlo por familia: si el vendedor carga Color 1 y Color 4 de la
 *  misma banana, las dos líneas comen del mismo pozo. */
export function indexarDisponible(resp: StockDisponibleResp | undefined) {
  const m: Record<string, { disponible: number; codStock: string }> = {};
  for (const a of resp?.disponible ?? []) {
    m[a.cod_art] = { disponible: a.disponible, codStock: a.cod_stock };
  }
  return m;
}

/** Disponible de un artículo descontando lo que hay en el borrador actual.
 *  El borrador todavía no existe en ningún lado —ni en Macrosoft ni en el
 *  espejo— así que esta resta es puramente del lado del navegador.
 *  Devuelve null si no sabemos el stock de ese artículo: desconocido no es cero. */
export function disponibleConBorrador(
  index: Record<string, { disponible: number; codStock: string }>,
  codArt: string,
  borrador: { cod_art: string; cantidad: number }[],
): number | null {
  const info = index[codArt];
  if (!info) return null;
  const enBorrador = borrador.reduce(
    (acc, l) => (index[l.cod_art]?.codStock === info.codStock ? acc + l.cantidad : acc),
    0,
  );
  return info.disponible - enBorrador;
}

/** Marca o quita la PRIORIDAD de un pedido (sale YA: asignación arriba de
 *  todo + aviso al armador + alarma en la tele). */
export const marcarPrioridadPedido = (nroFact: number, prioritario: boolean) =>
  apiPost<{ nro_fact: number; prioritario: boolean }>(
    `/venta/pedidos/${nroFact}/prioridad`,
    { prioritario },
  );

export interface ClienteCreatePayload {
  nombre: string;
  ruc?: string | null;
  nombre_fantasia?: string | null;
  direccion?: string | null;
  telefono?: string | null;
}

/** Alta mínima en Macrosoft: código autogenerado, nace Activo como cliente común. */
export const crearCliente = (body: ClienteCreatePayload) =>
  apiPost<{ cod: number; nombre: string }>("/venta/clientes", body);
