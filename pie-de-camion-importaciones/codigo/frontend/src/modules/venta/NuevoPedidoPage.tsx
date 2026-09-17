import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getStockColores } from "../../shared/api/stock";
import { poolDeVariante } from "../../shared/components/stock/ArticuloPickerModal";
import { ArticuloPickerModal } from "../../shared/components/stock/ArticuloPickerModal";
import type { Articulo } from "../../shared/api/stock";
import { useAuth } from "../../shared/AuthContext";
import { escalonarPrecio, limitesDeBase } from "../../shared/venta/precios";
import { useKeyboardMaxHeight } from "../../shared/hooks/useKeyboardMaxHeight";
import { ReclamoAviso } from "../../shared/components/ReclamoBadge";
import { ConfirmDialog } from "../../shared/components/ConfirmDialog";
import { NumpadModal } from "../../shared/components/NumpadModal";
import { getReclamosCliente } from "../reclamos/api";
import {
  CONSUMIDOR_FINAL_COD,
  agregarLineasPedido,
  crearPedidoVenta,
  disponibleConBorrador,
  errorLegible,
  getEscrituraConfigVenta,
  getHistorialCliente,
  getPedidosHoyCliente,
  getStockDisponible,
  getUltimosPrecios,
  indexarDisponible,
  searchClientesVenta,
  type ClienteVenta,
  type LineaPedido,
  type PedidoHoyCliente,
  type UltimoPrecio,
  crearCliente,
} from "./api";

/* Módulo Venta — Nuevo pedido (tablet del vendedor).
   Flujo del tomador: elegir CLIENTE → cargar PRODUCTOS con el picker POS (precio
   libre, con "último precio vendido" como referencia) → CONFIRMAR → el pedido
   queda en la cola de caja de Macrosoft. Una sola columna; el picker es un modal. */

const fmtMoneda = (n: number) =>
  "$" + n.toLocaleString("es-UY", { minimumFractionDigits: 0, maximumFractionDigits: 2 });

const fmtFechaCorta = (iso: string | null) => {
  if (!iso) return "";
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y?.slice(2)}`;
};

/** Parsea números como se escriben acá (es-UY): PUNTO = miles, COMA = decimal.
 *  "2.000" = dos mil, "1.500,50" = 1500.5, "2,5" = 2.5, "1.5" = 1.5. */
function parseNum(s: string): number {
  const t = String(s).trim();
  if (!t) return NaN;
  if (/^\d{1,3}(\.\d{3})+(,\d+)?$/.test(t)) return Number(t.replace(/\./g, "").replace(",", "."));
  if (/^\d+(,\d+)?$/.test(t)) return Number(t.replace(",", "."));
  if (/^\d+(\.\d+)?$/.test(t)) return Number(t);
  return NaN;
}

const esDescuento = (cod: string) => cod.trim().toUpperCase().startsWith("D");

// Límite duro de precio (regla en shared/venta/precios.ts, compartida con el
// paso de precio del picker). Los descuentos (Dto.) quedan EXENTOS (su
// "precio" es el monto del descuento por bulto, lo fija el vendedor). Sin base
// (producto sin historial) → sin límite acá, pero el picker directamente no
// deja elegirlos (bloquearSinPrecio).
function limitesPrecio(l: LineaPedido): { min: number; max: number } | null {
  if (esDescuento(l.cod_art)) return null;
  return limitesDeBase(l.base);
}
function clampPrecio(l: LineaPedido, valor: string): string {
  const lim = limitesPrecio(l);
  if (!lim) return valor;
  const p = parseNum(valor);
  if (!(p > 0)) return valor; // vacío/0 → se valida aparte en confirmar()
  if (p < lim.min) return String(lim.min);
  if (p > lim.max) return String(lim.max);
  return valor;
}

// Puesto (A) / ZAC (B): HOY el depósito lo asigna EXPEDICIÓN (Aloha reescribe
// Lineas2.Deposito ahí), así que el vendedor no lo elige — el pedido nace en 'A'
// y expedición lo rutea. A FUTURO la idea es que el vendedor decida acá: poner
// este flag en true reactiva el selector (el código ya está abajo, no borrar).
const VENDEDOR_ELIGE_DEPOSITO = false;

// ¿Mostrar el teclado en pantalla (numpad) al tocar cantidad/precio?
// Producción: SOLO en dispositivos táctiles (tablet/iPad). Para probar en PC:
// abrir con ?teclado=1 (queda pegado en localStorage) o ?teclado=0 para apagarlo.
function usarTecladoEnPantalla(): boolean {
  try {
    const p = new URLSearchParams(window.location.search).get("teclado");
    if (p === "1") { localStorage.setItem("venta.teclado", "1"); return true; }
    if (p === "0") { localStorage.setItem("venta.teclado", "0"); return false; }
    const ls = localStorage.getItem("venta.teclado");
    if (ls === "1") return true;
    if (ls === "0") return false;
  } catch {
    /* sin localStorage/URL → caemos a la detección táctil */
  }
  return (navigator.maxTouchPoints ?? 0) > 0 || window.matchMedia?.("(pointer: coarse)")?.matches === true;
}

// ── Borrador del pedido (localStorage) ────────────────────────────────────
// Persistimos lo que el vendedor va armando para que sobreviva una recarga o el
// bloqueo del celu. Scopeado por usuario (celus compartidos). Bump de VERSION si
// cambia la forma de LineaPedido/ClienteVenta → los borradores viejos se descartan.
type VentaDraft = {
  cliente: ClienteVenta | null;
  consumidorNombre: string;
  credito: boolean;
  deposito: "A" | "B";
  lineas: LineaPedido[];
  observaciones: string;
  // Modo AGREGADO: el pedido de hoy del cliente al que se le agrega. Persistido
  // para que una recarga a mitad de camino no convierta el agregado en un
  // pedido nuevo suelto. Opcional: los borradores viejos no lo traen.
  agregarA?: PedidoHoyCliente | null;
};
const DRAFT_VERSION = 1;
function leerBorrador(key: string): VentaDraft | null {
  try {
    const raw = localStorage.getItem(key);
    if (!raw) return null;
    const d = JSON.parse(raw);
    if (!d || d._v !== DRAFT_VERSION) return null;
    return d as VentaDraft;
  } catch {
    return null;
  }
}
function guardarBorrador(key: string, d: VentaDraft) {
  try {
    localStorage.setItem(key, JSON.stringify({ ...d, _v: DRAFT_VERSION }));
  } catch {
    /* localStorage lleno / no disponible → el borrador es best-effort */
  }
}
function borrarBorrador(key: string) {
  try {
    localStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}

export function NuevoPedidoPage() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const { user } = useAuth();
  // Borrador persistido por usuario (los celus son compartidos): sobrevive una
  // recarga de la página o el bloqueo del celu. Se lee UNA vez al montar y se
  // usa para pre-cargar el estado inicial.
  const draftKey = `venta.draft.${user?.id ?? "anon"}`;
  const [draft0] = useState(() => leerBorrador(draftKey));

  const [cliente, setCliente] = useState<ClienteVenta | null>(draft0?.cliente ?? null);
  const [consumidorNombre, setConsumidorNombre] = useState(draft0?.consumidorNombre ?? "");
  const [credito, setCredito] = useState(draft0?.credito ?? false);
  const [prioritario, setPrioritario] = useState(false);
  const [deposito, setDeposito] = useState<"A" | "B">(draft0?.deposito ?? "A");
  const [lineas, setLineas] = useState<LineaPedido[]>(draft0?.lineas ?? []);
  const [observaciones, setObservaciones] = useState(draft0?.observaciones ?? "");

  // Stock disponible: saldo de la familia menos los pedidos que ya están en la
  // cola de caja. Se refresca solo, porque lo que carga otro vendedor tiene que
  // aparecer acá sin que nadie recargue la pantalla (llega en <=15 s por el
  // mirror). Si falla, no se muestra nada: mejor sin número que con uno inventado.
  const { data: stockResp } = useQuery({
    queryKey: ["venta", "stock-disponible"],
    queryFn: getStockDisponible,
    refetchInterval: 20_000,
    refetchOnWindowFocus: true,
  });

  // Stock por color de banana (cámaras × Charlie − ventas): para que el chip
  // de una línea -N muestre SU color y no el total de la familia (que
  // engañaba: "13.186 disp." sobre Color 4). Solo si hay variantes cargadas.
  const hayVariantes = lineas.some((l) => l.cod_art.includes("-") && l.cod_art.trim().startsWith("01"));
  const { data: coloresBanana } = useQuery({
    queryKey: ["venta", "stock-colores"],
    queryFn: getStockColores,
    enabled: hayVariantes,
    staleTime: 60_000,
    retry: false,
  });
  const stockIndex = useMemo(() => indexarDisponible(stockResp), [stockResp]);
  // El borrador todavía no existe en Macrosoft, así que se resta acá.
  const borradorPorArt = useMemo(
    () => lineas.map((l) => ({ cod_art: l.cod_art, cantidad: parseNum(l.cantidad) })),
    [lineas],
  );
  const [error, setError] = useState<string | null>(null);
  /** El nombre que se muestra en la confirmación. Para consumidor final vale
   *  el que tipeó el vendedor: «CONSUMIDOR FINAL» a secas no le dice nada
   *  cuando tiene tres pedidos seguidos de mostrador. */
  function nombreDelCliente(): string | undefined {
    if (!cliente) return undefined;
    if (cliente.cod === CONSUMIDOR_FINAL_COD && consumidorNombre.trim()) {
      return consumidorNombre.trim();
    }
    return cliente.nombre;
  }

  const [creado, setCreado] = useState<{
    tipo: "nuevo" | "editado" | "encadenado";
    nro_doc: string;
    total: number;
    original_doc?: string;
    total_agregado?: number;
    // A quién se le hizo (dueño 3/09). Va CONGELADO acá y no leído del estado
    // `cliente`: la pantalla de confirmación queda abierta hasta que el
    // vendedor toca «Nuevo pedido», y para entonces el reset ya lo borró.
    cliente_nombre?: string;
  } | null>(null);
  // Modo AGREGADO: pedido de HOY del cliente al que se le agregan productos.
  // en_caja=true → se EDITA el mismo pedido en la cola; false → se crea un
  // pedido nuevo ENCADENADO (para Macrosoft es un pedido normal).
  const [agregarA, setAgregarA] = useState<PedidoHoyCliente | null>(draft0?.agregarA ?? null);
  const [avisoAgregado, setAvisoAgregado] = useState<string | null>(null);
  // Cambiar de cliente CON productos cargados: preguntar qué hacer con ellos
  // (se equivocaron de cliente vs. quedó un pedido a medias del anterior).
  const [cambioClienteOpen, setCambioClienteOpen] = useState(false);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [flash, setFlash] = useState<string | null>(null);
  // Confirm in-house de "enviar a caja" (con el detalle línea por línea).
  const [confirmOpen, setConfirmOpen] = useState(false);
  // Teclado en pantalla (tablet): qué campo se está editando con el numpad.
  const [teclado] = useState(usarTecladoEnPantalla);
  const [numpad, setNumpad] = useState<
    { cod: string; campo: "cantidad" | "precio"; titulo: string; decimal: boolean } | null
  >(null);

  // Último precio vendido por artículo (a ESTE cliente + global). Cache local.
  const [ultimos, setUltimos] = useState<Record<string, UltimoPrecio>>({});
  // Códigos ya pedidos (dedup del fetch de precios). Se resetea al cambiar cliente.
  const pedidosRef = useRef<Set<string>>(new Set());
  useEffect(() => {
    pedidosRef.current = new Set();
  }, [cliente?.cod]);

  // Persistir el borrador ante cualquier cambio (best-effort). No guardamos la
  // pantalla de éxito (creado): si recargan ahí, arrancan un pedido nuevo limpio.
  useEffect(() => {
    if (creado) return;
    if (!cliente && lineas.length === 0) {
      borrarBorrador(draftKey);
      return;
    }
    guardarBorrador(draftKey, { cliente, consumidorNombre, credito, deposito, lineas, observaciones, agregarA });
  }, [cliente, consumidorNombre, credito, deposito, lineas, observaciones, agregarA, creado, draftKey]);

  // Ref de idempotencia por intento de envío (reintentar tras timeout no duplica).
  const [envioRef, setEnvioRef] = useState<string>(() => crypto.randomUUID());
  useEffect(() => {
    setEnvioRef(crypto.randomUUID());
  }, [lineas, cliente, credito, deposito, observaciones, consumidorNombre, agregarA]);

  // Pedidos de HOY del cliente → ofrecer "agregar productos" (feature 28/07).
  // Consumidor Final queda afuera: bajo el 999901 conviven compradores distintos.
  const { data: pedidosHoyData, isSuccess: pedidosHoyOk } = useQuery({
    queryKey: ["venta-pedidos-hoy", cliente?.cod],
    queryFn: () => getPedidosHoyCliente(cliente!.cod),
    enabled: !!cliente && cliente.cod !== CONSUMIDOR_FINAL_COD,
    refetchInterval: 30_000,
  });
  const pedidosHoy = pedidosHoyData ?? [];

  // Cambio de cliente → el modo agregado del cliente anterior no aplica más.
  // (Con guardia de primer render: al montar NO hay cambio — si no, pisaría el
  // agregarA restaurado del borrador.)
  const clientePrevRef = useRef<number | undefined>(cliente?.cod);
  useEffect(() => {
    if (clientePrevRef.current === cliente?.cod) return;
    clientePrevRef.current = cliente?.cod;
    setAgregarA(null);
    setAvisoAgregado(null);
  }, [cliente?.cod]);

  // Anti borrador-viejo: cuando llega la lista fresca de pedidos-de-hoy, el
  // agregarA restaurado se re-valida contra ella. Si el pedido ya no es de hoy
  // (o se anuló) se sale del modo con aviso; si cambió su situación (p.ej. ya
  // no está en caja) se actualiza para que el envío use el camino correcto.
  const pedidosHoyKey = pedidosHoy.map((p) => `${p.nro_fact}:${p.en_caja ? 1 : 0}`).join(",");
  useEffect(() => {
    // Solo con la lista CONFIRMADA (query exitosa) — con la query cargando,
    // pedidosHoy=[] y esto echaría del modo agregado al montar con borrador.
    if (!pedidosHoyOk || !agregarA || !cliente || cliente.cod === CONSUMIDOR_FINAL_COD) return;
    const fresco = pedidosHoy.find((p) => p.nro_fact === agregarA.nro_fact);
    if (!fresco) {
      setAgregarA(null);
      setAvisoAgregado(
        `El pedido #${agregarA.nro_doc} del borrador ya no está entre los de hoy — se sale del modo agregado.`,
      );
    } else if (fresco.en_caja !== agregarA.en_caja) {
      setAgregarA(fresco);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pedidosHoyKey, pedidosHoyOk]);

  const { data: escritura } = useQuery({
    queryKey: ["venta-escritura-config"],
    queryFn: getEscrituraConfigVenta,
    staleTime: 5 * 60 * 1000,
  });

  // No conformidades / particularidades VIGENTES del cliente elegido — el
  // vendedor las ve arriba (igual que el armador) y puede cargar nuevas.
  const { data: avisosCliente = [] } = useQuery({
    queryKey: ["reclamos-cliente", cliente?.cod],
    queryFn: () => getReclamosCliente(cliente!.cod),
    enabled: !!cliente,
    staleTime: 60_000,
  });

  const total = useMemo(
    () =>
      lineas.reduce((s, l) => {
        const c = parseNum(l.cantidad);
        const p = parseNum(l.precio);
        return s + (c > 0 && p >= 0 ? c * p : 0);
      }, 0),
    [lineas],
  );
  const totalBultos = useMemo(
    () => lineas.reduce((s, l) => { const c = parseNum(l.cantidad); return s + (c > 0 ? c : 0); }, 0),
    [lineas],
  );

  const hayDto = lineas.some((l) => esDescuento(l.cod_art));
  const hayMercaderia = lineas.some((l) => !esDescuento(l.cod_art));
  const mezclaInvalida = hayDto && hayMercaderia;

  const lineasPayload = () =>
    lineas.map((l) => ({
      cod_art: l.cod_art,
      cantidad: parseNum(l.cantidad),
      precio: parseNum(l.precio),
    }));

  const mut = useMutation({
    mutationFn: async () => {
      // Caso A: el pedido sigue en caja → se le AGREGAN líneas al mismo pedido.
      if (agregarA?.en_caja) {
        const r = await agregarLineasPedido(agregarA.nro_fact, {
          lineas: lineasPayload(),
          ref: envioRef,
          cliente_cod: cliente!.cod,
        });
        return {
          tipo: "editado" as const,
          nro_doc: r.nro_doc,
          total: r.total_pedido,
          total_agregado: r.total_agregado,
          cliente_nombre: nombreDelCliente(),
        };
      }
      // Pedido nuevo (normal o encadenado como AGREGADO del original).
      const r = await crearPedidoVenta({
        cliente_cod: cliente!.cod,
        consumidor_nombre:
          cliente!.cod === CONSUMIDOR_FINAL_COD && consumidorNombre.trim()
            ? consumidorNombre.trim()
            : null,
        credito,
        // El botón no está en un pedido de descuentos, pero el flag pudo
        // quedar prendido de antes de agregar la línea Dto.: no viaja.
        prioritario: prioritario && !hayDto,
        deposito,
        observaciones: observaciones.trim() || null,
        lineas: lineasPayload(),
        ref: envioRef,
        agregado_de: agregarA ? agregarA.nro_fact : null,
      });
      return {
        tipo: agregarA ? ("encadenado" as const) : ("nuevo" as const),
        nro_doc: r.nro_doc,
        total: r.total,
        original_doc: agregarA?.nro_doc,
        cliente_nombre: nombreDelCliente(),
      };
    },
    onSuccess: (r) => {
      qc.invalidateQueries({ queryKey: ["venta-pedidos"] });
      qc.invalidateQueries({ queryKey: ["venta-pedidos-hoy"] });
      borrarBorrador(draftKey); // ya se envió → el borrador no debe revivir en una recarga
      setCreado(r);
    },
    onError: (e: Error) => {
      // Carrera del caso A: caja facturó el pedido MIENTRAS se cargaba el
      // agregado → el back devuelve 409 con el marcador YA_FACTURADO (nada se
      // escribió). SOLO ese 409 convierte al camino B: el 409 de idempotencia
      // ("envío ya en proceso") NO debe convertir — el envío original puede
      // estar en vuelo y encadenar acá duplicaría la mercadería.
      if (agregarA?.en_caja && /\b409\b/.test(e.message) && e.message.includes("YA_FACTURADO")) {
        setAgregarA({ ...agregarA, en_caja: false });
        setAvisoAgregado(
          `El pedido #${agregarA.nro_doc} salió de caja mientras cargabas: los productos se van a enviar como pedido AGREGADO encadenado. Confirmá de nuevo.`,
        );
        setError(null);
        return;
      }
      setError(errorLegible(e.message));
    },
  });

  /** Vuelve al paso 1 (elegir cliente). `limpiar` decide si los productos ya
   *  cargados se descartan o viajan al cliente nuevo. Los precios de referencia
   *  se re-piden solos para el cliente nuevo (effect de preciosMap). */
  function cambiarCliente(limpiar: boolean) {
    setCliente(null);
    setConsumidorNombre("");
    setUltimos({});
    setError(null);
    setAgregarA(null);
    setAvisoAgregado(null);
    // Contado/crédito es condición del CLIENTE, no del carrito → siempre vuelve
    // al default; si no, el pedido nuevo heredaba el crédito del anterior.
    setCredito(false);
    setPrioritario(false);
    if (limpiar) {
      setLineas([]);
      setObservaciones("");
    } else {
      // Conservar productos: los precios del cliente ANTERIOR no valen para el
      // nuevo. Se borran precio y base para que el effect de preciosMap los
      // re-llene con los del cliente que se elija (si no llegan, `confirmar()`
      // corta con "no tiene precio de referencia" en vez de mandar un precio
      // de otro cliente a caja).
      setLineas((prev) => prev.map((l) => ({ ...l, precio: "", base: null })));
    }
    setCambioClienteOpen(false);
  }

  function resetTodo() {
    setCliente(null);
    setConsumidorNombre("");
    setCredito(false);
    setPrioritario(false);
    setDeposito("A");
    setLineas([]);
    setObservaciones("");
    setError(null);
    setCreado(null);
    setUltimos({});
    setPickerOpen(false);
    setAgregarA(null);
    setAvisoAgregado(null);
    setCambioClienteOpen(false);
    setEnvioRef(crypto.randomUUID());
    borrarBorrador(draftKey);
  }

  // Mapa cod → precio de venta de referencia (a este cliente, con fallback global).
  const preciosMap = useMemo(() => {
    const m: Record<string, number | null> = {};
    // Prioridad (27/07): precio de LISTA (el que fija Valeria en Macrosoft)
    // → última venta a este cliente → última venta global. Antes solo se usaba
    // la última venta y el precio fijado quedaba invisible.
    for (const [cod, u] of Object.entries(ultimos))
      m[cod] = u.precio_lista ?? u.precio ?? u.precio_global ?? null;
    return m;
  }, [ultimos]);

  // Trae el "último precio vendido" de los códigos pedidos (picker o alta), con
  // dedup. Lo cachea en `ultimos`. El picker lo llama con lo que muestra (lazy).
  const needPrecios = useCallback(
    (cods: string[]) => {
      const c = cliente;
      if (!c) return;
      const faltan = cods.filter((cod) => !pedidosRef.current.has(cod));
      if (!faltan.length) return;
      faltan.forEach((cod) => pedidosRef.current.add(cod));
      getUltimosPrecios(c.cod, faltan)
        .then((rs) =>
          setUltimos((prev) => {
            const next = { ...prev };
            rs.forEach((r) => { next[r.cod_art] = r; });
            return next;
          }),
        )
        .catch(() => faltan.forEach((cod) => pedidosRef.current.delete(cod)));
    },
    [cliente],
  );

  // Re-pedir precios de las líneas YA cargadas al montar con borrador o cambiar
  // de cliente: sin esto, una línea restaurada de un borrador quedaba sin `base`
  // (= sin límites de precio) para siempre. El dedup de pedidosRef se resetea
  // al cambiar de cliente, así que esto pide exactamente lo que falta.
  useEffect(() => {
    if (lineas.length) needPrecios(lineas.map((l) => l.cod_art));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cliente?.cod, needPrecios]);

  // Cuando llega el precio de un artículo, fijo/REFRESCO su `base` (la
  // referencia del −10%/+20%) y pre-lleno el precio si el vendedor no lo tocó.
  // La base se actualiza SIEMPRE al último valor consultado — antes solo se
  // fijaba si era null, y un borrador restaurado (o un cambio de cliente)
  // dejaba bases de días anteriores: el vendedor veía y confirmaba precios
  // vencidos (bug detectado en la auditoría CERIANI 27/07). El precio tipeado
  // por el vendedor NO se pisa; solo se pisa si estaba vacío o intacto
  // (== base vieja, o sea nunca ajustado).
  useEffect(() => {
    setLineas((prev) => {
      let cambio = false;
      const next = prev.map((l) => {
        const sug = preciosMap[l.cod_art];
        if (sug == null) return l;
        const intacto = l.precio.trim() === "" || (l.base != null && parseNum(l.precio) === l.base);
        const nuevoPrecio = intacto ? String(sug) : l.precio;
        if (l.base === sug && nuevoPrecio === l.precio) return l;
        cambio = true;
        return { ...l, base: sug, precio: nuevoPrecio };
      });
      return cambio ? next : prev;
    });
  }, [preciosMap]);

  // Botones −/+ de precio: fijan el valor ya escalonado (de a $50, ver
  // escalonarPrecio) — el clamp al rango −10%/+20% viene calculado.
  function setPrecioValor(cod: string, valor: number) {
    setLineas((prev) => prev.map((l) => (l.cod_art === cod ? { ...l, precio: String(valor) } : l)));
  }

  function agregarArticulo(a: Articulo, cantidad?: number, precioElegido?: number) {
    if (!cliente) return;
    // El picker (conCantidad) ya trae los bultos cargados; sin eso, 1 (y un
    // segundo tap suma de a uno, como el stepper del tomador).
    const cant = cantidad && cantidad > 0 ? Math.floor(cantidad) : 1;
    // Defensa extra al bloqueo del picker: si YA sabemos que no tiene precio de
    // referencia (consultado y null), no se agrega — sin base no hay contra qué
    // acotar el −10%/+20%. Para venderlo está el tomador de Macrosoft.
    if (!esDescuento(a.cod) && preciosMap[a.cod] === null) {
      // Cerrar el picker para que el error se VEA (el modal tapa la barra donde
      // se pinta; si el tap llegó hasta acá, el engrisado no alcanzó).
      setPickerOpen(false);
      setError(`"${a.descripcion}" no tiene precio de referencia y no se puede vender desde acá.`);
      return;
    }
    setError(null);
    setFlash(cant > 1 ? `${cant} × ${a.descripcion}` : a.descripcion);
    window.clearTimeout((agregarArticulo as unknown as { _t?: number })._t);
    (agregarArticulo as unknown as { _t?: number })._t = window.setTimeout(() => setFlash(null), 1400);

    const sug = preciosMap[a.cod] ?? null;
    // Precio elegido en el mismo paso del picker (pedido vendedores 27/08): si
    // vino, manda sobre el sugerido — el vendedor lo acaba de decidir.
    const precioIni = precioElegido != null && precioElegido > 0 ? precioElegido : null;
    setLineas((prev) => {
      const ya = prev.find((l) => l.cod_art === a.cod);
      if (ya) {
        // Producto repetido: SUMA la cantidad nueva a la que ya tenía (y si el
        // vendedor eligió precio en el picker, la línea toma ese precio).
        return prev.map((l) =>
          l.cod_art === a.cod
            ? {
                ...l,
                cantidad: String((parseNum(l.cantidad) || 0) + cant),
                precio: precioIni != null ? String(precioIni) : l.precio,
              }
            : l,
        );
      }
      return [
        ...prev,
        {
          cod_art: a.cod,
          descripcion: a.descripcion,
          icono: a.icono ?? null,
          cantidad: String(cant),
          precio: precioIni != null ? String(precioIni) : sug != null ? String(sug) : "",
          base: sug, // referencia para el slider; si aún no llegó, la fija el effect
        },
      ];
    });
    needPrecios([a.cod]); // por si el picker no llegó a traerlo (el efecto pre-llena)
  }

  function updateLinea(cod: string, campo: "cantidad" | "precio", valor: string) {
    // Cantidad = bultos enteros (sin coma/punto); precio admite decimal.
    const patron = campo === "cantidad" ? /^\d*$/ : /^[\d.,]*$/;
    if (!patron.test(valor)) return;
    setLineas((prev) => prev.map((l) => (l.cod_art === cod ? { ...l, [campo]: valor } : l)));
  }

  // Al terminar de editar el precio, lo recorto al rango −10%/+20% permitido (si aplica).
  function commitPrecio(cod: string) {
    setLineas((prev) => prev.map((l) => (l.cod_art === cod ? { ...l, precio: clampPrecio(l, l.precio) } : l)));
  }

  function confirmar() {
    setError(null);
    if (!cliente) return setError("Elegí el cliente primero.");
    if (lineas.length === 0) return setError("Agregá al menos un producto.");
    if (mezclaInvalida)
      return setError("Los descuentos (Dto.) van en un pedido aparte de la mercadería. Hacé dos pedidos.");
    if (agregarA?.en_caja && hayDto)
      return setError("Los descuentos (Dto.) no se agregan a un pedido existente — hacé un pedido de descuentos aparte.");
    for (const l of lineas) {
      const c = parseNum(l.cantidad);
      const p = parseNum(l.precio);
      if (!(c > 0)) return setError(`Cantidad inválida en ${l.descripcion}.`);
      if (!(p >= 0) || l.precio.trim() === "") return setError(`Falta el precio de ${l.descripcion}.`);
      // Sin base no hay contra qué acotar el −10%/+20% → no se puede confirmar.
      // Cierra la carrera del picker (agregado antes de que llegara el precio),
      // el fetch de precios fallido y los borradores viejos: sin excepciones,
      // ninguna línea sale a caja con precio libre. Se vende desde Macrosoft.
      if (!esDescuento(l.cod_art) && (!l.base || l.base <= 0))
        return setError(
          `${l.descripcion} no tiene precio de referencia — quitalo del pedido (ese se vende desde el tomador de Macrosoft).`,
        );
      const lim = limitesPrecio(l);
      if (lim && (p < lim.min || p > lim.max))
        return setError(
          `El precio de ${l.descripcion} tiene que estar entre ${fmtMoneda(lim.min)} y ${fmtMoneda(lim.max)} (de −10% a +20% del último precio).`,
        );
    }
    // Confirm in-house con el detalle línea por línea (pedido 27/07: el
    // window.confirm nativo solo decía "N productos · $total" y en la tablet
    // se aceptaba sin ver QUÉ se estaba mandando a caja).
    setConfirmOpen(true);
  }

  // ── Pantalla de éxito ──────────────────────────────────────────────────
  if (creado) {
    return (
      <div className="h-full overflow-y-auto">
        <div className="max-w-xl mx-auto mt-10 px-4 text-center space-y-4">
          <div className="mx-auto w-16 h-16 rounded-full bg-green-100 flex items-center justify-center">
            <svg className="w-9 h-9 text-green-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
            </svg>
          </div>
          {creado.cliente_nombre && (
            <p className="text-lg font-semibold text-pepe-blue">{creado.cliente_nombre}</p>
          )}
          <h2 className="text-2xl font-bold text-slate-900">
            {creado.tipo === "editado"
              ? `Productos agregados al pedido #${creado.nro_doc}`
              : creado.tipo === "encadenado"
              ? `Agregado #${creado.nro_doc} enviado a caja`
              : `Pedido #${creado.nro_doc} enviado a caja`}
          </h2>
          {creado.tipo === "editado" ? (
            <p className="text-slate-500">
              Se sumaron {fmtMoneda(creado.total_agregado ?? 0)} · el pedido ahora totaliza {fmtMoneda(creado.total)}
            </p>
          ) : creado.tipo === "encadenado" ? (
            <p className="text-slate-500">
              Total {fmtMoneda(creado.total)} · encadenado al pedido #{creado.original_doc}
            </p>
          ) : (
            <p className="text-slate-500">Total {fmtMoneda(creado.total)}</p>
          )}
          <button
            onClick={resetTodo}
            className="mt-4 px-8 py-4 rounded-lg bg-pepe-blue text-white text-lg font-semibold hover:bg-pepe-blue-dark"
          >
            Nuevo pedido
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="h-full overflow-y-auto overscroll-y-contain">
      <div className="max-w-screen-2xl mx-auto p-4 sm:p-6 space-y-4">
        <h2 className="text-xl font-bold text-slate-900">Nuevo pedido</h2>

        {escritura && !escritura.conectado && (
          <div className="px-3 py-2.5 rounded-md bg-amber-50 border border-amber-300 text-sm text-amber-900">
            Ambiente de <strong>prueba</strong>: no está conectado a Macrosoft, así que podés armar el
            pedido pero el envío no hace nada real.
          </div>
        )}

        {/* ── Paso 1: cliente ── */}
        {!cliente ? (
          <ClientePicker onSelect={setCliente} />
        ) : (
          <div className="p-4 rounded-lg border border-pepe-border bg-white flex items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="text-lg font-semibold text-pepe-blue truncate">{cliente.nombre}</div>
              <div className="text-xs text-slate-500 mt-0.5">
                Código {cliente.cod}
                {cliente.ruc ? ` · RUT ${cliente.ruc}` : " · sin RUT"}
              </div>
              {cliente.cod === CONSUMIDOR_FINAL_COD && (
                <input
                  value={consumidorNombre}
                  onChange={(e) => setConsumidorNombre(e.target.value)}
                  placeholder="Nombre del comprador (opcional)"
                  maxLength={100}
                  className="mt-2 w-full sm:w-80 px-3 py-2.5 rounded-md border border-pepe-border text-base"
                />
              )}
            </div>
            <button
              onClick={() => {
                // Con productos cargados no se cambia en silencio: el vendedor
                // decide si eran para este cliente o para el nuevo.
                if (lineas.length > 0) return setCambioClienteOpen(true);
                cambiarCliente(false);
              }}
              className="shrink-0 px-3 py-2 rounded border border-pepe-border text-sm font-medium text-slate-600 hover:bg-slate-50"
            >
              Cambiar cliente
            </button>
          </div>
        )}

        {cliente && (
          <div className="space-y-2">
            {avisosCliente.map((r) => (
              <ReclamoAviso key={r.tipo} r={r} />
            ))}
            <button
              onClick={() =>
                navigate(`/reclamos?cliente=${cliente.cod}&nombre=${encodeURIComponent(cliente.nombre)}`)
              }
              className="inline-flex items-center gap-1.5 px-3 py-2.5 sm:py-1.5 rounded-lg border border-pepe-border text-xs font-semibold text-slate-600 hover:bg-slate-50"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
              </svg>
              Cargar no conformidad / particularidad
            </button>
          </div>
        )}

        {/* ── Pedidos de HOY del cliente → "agregar productos" ── */}
        {cliente && !agregarA && pedidosHoy.length > 0 && (
          <PedidosHoyBanner
            pedidos={pedidosHoy}
            onAgregar={(p) => {
              setAgregarA(p);
              setError(null);
              // El encadenado hereda contado/crédito del original (editable).
              if (!p.en_caja) setCredito(p.credito);
            }}
          />
        )}

        {/* ── Modo AGREGADO activo ── */}
        {cliente && agregarA && (
          <div className={`p-3 rounded-lg border-2 ${agregarA.en_caja ? "border-sky-300 bg-sky-50" : "border-indigo-300 bg-indigo-50"}`}>
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0 text-sm">
                <div className={`font-bold ${agregarA.en_caja ? "text-sky-800" : "text-indigo-800"}`}>
                  {agregarA.en_caja
                    ? `Agregando productos al pedido #${agregarA.nro_doc} (sigue en caja)`
                    : `Agregado ENCADENADO al pedido #${agregarA.nro_doc}`}
                </div>
                <div className="text-xs text-slate-600 mt-0.5">
                  {agregarA.en_caja
                    ? "Las líneas nuevas se suman al MISMO pedido — caja lo factura todo junto."
                    : agregarA.entregado_registrado || agregarA.estado === "ENTREGADO"
                    ? "El original YA SE ENTREGÓ: esto sale como pedido nuevo, avisando en depósito."
                    : "Sale como pedido nuevo para caja, pero queda atado al original en todo el circuito."}
                </div>
                {agregarA.en_caja && observaciones.trim() && (
                  <div className="text-xs font-semibold text-amber-700 mt-1">
                    Ojo: las observaciones tipeadas no se guardan al agregar al mismo pedido
                    (el pedido conserva las suyas).
                  </div>
                )}
              </div>
              <button
                onClick={() => { setAgregarA(null); setAvisoAgregado(null); }}
                className="shrink-0 px-3 py-2 rounded border border-pepe-border bg-white text-xs font-semibold text-slate-600 hover:bg-slate-50"
              >
                Salir del modo agregado
              </button>
            </div>
          </div>
        )}

        {avisoAgregado && (
          <div className="px-3 py-2.5 rounded-md bg-amber-50 border border-amber-300 text-sm text-amber-900">
            {avisoAgregado}
          </div>
        )}

        {cliente && (
          <>
            {/* ── Pago (+ depósito, hoy oculto: lo asigna expedición) ── */}
            {!agregarA?.en_caja && (
            <div className="flex flex-wrap gap-3">
              <Segmented
                value={credito ? "credito" : "contado"}
                onChange={(v) => setCredito(v === "credito")}
                options={[
                  { value: "contado", label: "Contado" },
                  { value: "credito", label: "Crédito" },
                ]}
              />
              {/* PRIORITARIO: este pedido tiene que salir YA — va arriba de
                  todo en asignación, le avisa al armador y suena en la tele.
                  En un pedido de DESCUENTOS no aparece: no lleva mercadería, no
                  se arma ni se entrega, así que marcarlo no le avisa a nadie y
                  la alarma —que se apaga al entregar— quedaría sonando sola
                  (pasó el 31/08). El back lo ignora igual, por las dudas. */}
              {!hayDto && (
              <button
                type="button"
                onClick={() => setPrioritario((p) => !p)}
                className={`inline-flex items-center gap-2 rounded-lg border-2 px-4 py-2 text-sm font-bold transition-colors ${
                  prioritario
                    ? "border-red-600 bg-red-600 text-white animate-glow-prioridad"
                    : "border-pepe-border bg-white text-slate-600 hover:border-red-300"
                }`}
              >
                <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 13.5l10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75z" />
                </svg>
                {prioritario ? "PRIORITARIO — sale YA" : "Marcar prioritario"}
              </button>
              )}
              {/* Selector de depósito — reactivar poniendo VENDEDOR_ELIGE_DEPOSITO=true
                  cuando la operación quiera que el vendedor decida Puesto/ZAC. */}
              {VENDEDOR_ELIGE_DEPOSITO && (
                <Segmented
                  value={deposito}
                  onChange={(v) => setDeposito(v as "A" | "B")}
                  options={[
                    { value: "A", label: "Puesto (A)" },
                    { value: "B", label: "ZAC (B)" },
                  ]}
                />
              )}
            </div>
            )}

            <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 items-start">
            {/* ── Historial del cliente (referencia de precio) — izquierda en desktop ── */}
            <HistorialClienteCol clienteCod={cliente.cod} clienteNombre={cliente.nombre} className="order-2 lg:order-1" />

            {/* ── Pedido — derecha en desktop, arriba en mobile ── */}
            <section className="order-1 lg:order-2 p-4 rounded-lg border border-pepe-border bg-white space-y-3">
              <div className="flex items-center justify-between gap-3">
                <h3 className="text-sm font-semibold text-slate-700">Pedido</h3>
                <button
                  onClick={() => setPickerOpen(true)}
                  className="inline-flex items-center gap-2 px-4 py-2.5 rounded-lg bg-pepe-blue text-white text-sm font-semibold hover:bg-pepe-blue-dark"
                >
                  <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
                  </svg>
                  Agregar productos
                </button>
              </div>

              {lineas.length === 0 ? (
                <button
                  onClick={() => setPickerOpen(true)}
                  className="w-full py-10 rounded-lg border-2 border-dashed border-pepe-border text-slate-400 hover:border-pepe-blue hover:text-pepe-blue"
                >
                  Tocá <strong>Agregar productos</strong> para armar el pedido
                </button>
              ) : (
                <ul className="divide-y divide-pepe-border">
                  {lineas.map((l) => {
                    const c = parseNum(l.cantidad);
                    const p = parseNum(l.precio);
                    const sub = c > 0 && p >= 0 ? c * p : null;
                    const u = ultimos[l.cod_art];
                    const esDto = esDescuento(l.cod_art);
                    // Botones −/+ de precio: de a $50, con límites −10%/+20%.
                    const base = l.base;
                    const lim = limitesPrecio(l); // rango permitido, o null si exento (descuento/sin base)
                    const pctExact = base && base > 0 && p > 0 ? Math.round((p / base - 1) * 100) : 0;
                    // Precio de partida del escalón: el tipeado, o el base si el
                    // campo está vacío (así el primer tap ya mueve desde el base).
                    const pActual = p > 0 ? p : (base ?? 0);
                    const precioMas = escalonarPrecio(pActual, 1, lim, base);
                    const precioMenos = escalonarPrecio(pActual, -1, lim, base);
                    const fueraDeRango = !!lim && p > 0 && (p < lim.min || p > lim.max);
                    // Disponible de la familia, ya restadas las otras líneas del
                    // borrador. null = no sabemos (no toda la lista lleva stock):
                    // desconocido no es cero, así que no se muestra nada.
                    const disp = esDto ? null : disponibleConBorrador(stockIndex, l.cod_art, borradorPorArt);
                    return (
                      <li key={l.cod_art} className="py-3 space-y-2">
                        <div className="flex items-center gap-2">
                          <IconoCat icono={l.icono} />
                          <div className="min-w-0 flex-1">
                            <div className="text-[11px] text-slate-400 flex items-center gap-1.5 flex-wrap">
                              <span>{l.cod_art}</span>
                              {(() => {
                                const esVariante = l.cod_art.includes("-") && l.cod_art.trim().startsWith("01");
                                const pool = esVariante ? poolDeVariante(l.cod_art, coloresBanana?.pools ?? []) : null;
                                if (pool) return <ColorStockBadge pool={pool} />;
                                if (disp !== null) return <StockBadge disponible={disp} esFamilia={esVariante} />;
                                return null;
                              })()}
                            </div>
                            {/* Sin truncate (mismo motivo que el confirm): el nombre
                                completo distingue BR/PY/EC en pantallas angostas. */}
                            <div className="text-sm font-medium text-slate-900 break-words leading-tight">{l.descripcion}</div>
                          </div>
                          <button
                            onClick={() => setLineas((prev) => prev.filter((x) => x.cod_art !== l.cod_art))}
                            className="shrink-0 p-2.5 sm:p-2 rounded-full text-red-500 hover:bg-red-50"
                            title="Quitar"
                          >
                            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                            </svg>
                          </button>
                        </div>
                        <div className="flex items-center gap-2">
                          <label className="flex-1">
                            <span className="block text-[10px] uppercase text-slate-400">Cantidad</span>
                            <input
                              type="text"
                              inputMode={teclado ? "none" : "decimal"}
                              readOnly={teclado}
                              value={l.cantidad}
                              onChange={teclado ? undefined : (e) => updateLinea(l.cod_art, "cantidad", e.target.value)}
                              onClick={
                                teclado
                                  ? () => setNumpad({ cod: l.cod_art, campo: "cantidad", titulo: "Cantidad (bultos)", decimal: false })
                                  : undefined
                              }
                              className={`w-full px-3 py-2.5 rounded-md border border-pepe-border text-center text-base font-semibold ${teclado ? "cursor-pointer" : ""}`}
                            />
                          </label>
                          <label className="flex-1">
                            <span className="block text-[10px] uppercase text-slate-400">Precio</span>
                            <input
                              type="text"
                              inputMode={teclado ? "none" : "decimal"}
                              readOnly={teclado}
                              value={l.precio}
                              onChange={teclado ? undefined : (e) => updateLinea(l.cod_art, "precio", e.target.value)}
                              onBlur={teclado ? undefined : () => commitPrecio(l.cod_art)}
                              onClick={
                                teclado
                                  ? () => setNumpad({ cod: l.cod_art, campo: "precio", titulo: `Precio · ${l.descripcion}`, decimal: true })
                                  : undefined
                              }
                              placeholder={u?.precio != null ? String(u.precio) : ""}
                              className={`w-full px-3 py-2.5 rounded-md border border-pepe-border text-center text-base font-semibold ${teclado ? "cursor-pointer" : ""}`}
                            />
                          </label>
                          <div className="flex-1 text-right">
                            <span className="block text-[10px] uppercase text-slate-400">Subtotal</span>
                            <span className="text-base font-bold text-slate-900">
                              {sub != null ? fmtMoneda(sub) : "—"}
                            </span>
                          </div>
                        </div>
                        {!esDto && base != null && base > 0 && (
                          <div className="space-y-1">
                            {/* Botones −5%/+5% (reemplazan al slider: en la tablet
                                el slider se corría de más con el dedo). */}
                            <div className="flex items-center gap-2">
                              <button
                                type="button"
                                onClick={() => setPrecioValor(l.cod_art, precioMenos)}
                                disabled={!!lim && pActual <= lim.min}
                                title="Bajar el precio $50"
                                className="w-12 h-12 sm:w-10 sm:h-10 shrink-0 rounded-lg border border-pepe-border bg-white text-xl font-bold text-red-600 active:bg-red-50 disabled:opacity-30 disabled:cursor-not-allowed"
                              >
                                −
                              </button>
                              <span
                                className={`flex-1 text-center text-sm font-bold tabular-nums ${
                                  fueraDeRango
                                    ? "text-amber-600"
                                    : pctExact > 0
                                    ? "text-green-600"
                                    : pctExact < 0
                                    ? "text-red-600"
                                    : "text-slate-400"
                                }`}
                                title={fueraDeRango ? "Fuera del rango permitido (−10% a +20% del último precio)" : undefined}
                              >
                                {pctExact === 0 ? "precio base" : `${pctExact > 0 ? "+" : ""}${pctExact}%`}
                              </span>
                              <button
                                type="button"
                                onClick={() => setPrecioValor(l.cod_art, precioMas)}
                                disabled={!!lim && pActual >= lim.max}
                                title="Subir el precio $50"
                                className="w-12 h-12 sm:w-10 sm:h-10 shrink-0 rounded-lg border border-pepe-border bg-white text-xl font-bold text-green-600 active:bg-green-50 disabled:opacity-30 disabled:cursor-not-allowed"
                              >
                                +
                              </button>
                            </div>
                            {lim && (
                              <div className="text-[10px] text-slate-400 text-center">
                                Permitido {fmtMoneda(lim.min)}–{fmtMoneda(lim.max)} (−10% a +20%, de a $50)
                              </div>
                            )}
                          </div>
                        )}
                        {u && u.precio_lista != null && (
                          <div className="text-[11px] text-slate-500">
                            Precio de lista: <strong className="text-slate-700">{fmtMoneda(u.precio_lista)}</strong>
                          </div>
                        )}
                        {u && (u.precio != null || u.precio_global != null) && (
                          <div className="text-[11px] text-slate-500">
                            Últ. vendido{" "}
                            {u.precio != null ? (
                              <>
                                a este cliente: <strong>{fmtMoneda(u.precio)}</strong> ({fmtFechaCorta(u.fecha)})
                              </>
                            ) : (
                              <>
                                (general): <strong>{fmtMoneda(u.precio_global!)}</strong> ({fmtFechaCorta(u.fecha_global)})
                              </>
                            )}
                          </div>
                        )}
                      </li>
                    );
                  })}
                </ul>
              )}

              {mezclaInvalida && (
                <div className="px-3 py-2 rounded bg-amber-50 border border-amber-300 text-xs text-amber-900">
                  <strong>Descuentos aparte:</strong> los "Dto." no pueden ir junto con mercadería — hacé un
                  pedido solo de descuentos y otro con la fruta.
                </div>
              )}

              {/* Agregando al MISMO pedido no se toca el cabezal → sin obs. */}
              {!agregarA?.en_caja && (
                <textarea
                  value={observaciones}
                  onChange={(e) => setObservaciones(e.target.value)}
                  maxLength={100} /* Cabezal2.OBSERVACIONES es char(100) en Macrosoft */
                  rows={2}
                  placeholder="Observaciones (opcional)"
                  className="w-full px-3 py-2.5 rounded-md border border-pepe-border text-base"
                />
              )}
            </section>
            </div>

            {/* Barra de acción sticky: Total + botones siempre al pie, aunque el
                pedido tenga muchas líneas (no hace falta scrollear hasta abajo). */}
            <div className="sticky bottom-0 z-20 -mx-4 sm:-mx-6 -mb-4 sm:-mb-6 px-4 sm:px-6 pt-3 pb-safe bg-white/95 backdrop-blur border-t border-pepe-border space-y-2">
              {error && (
                <div className="px-3 py-2 rounded bg-red-50 border border-red-200 text-sm text-red-700">{error}</div>
              )}
              <div className="flex items-center justify-between gap-3 flex-wrap">
                <div className="flex items-baseline gap-3">
                  <span className="text-sm text-slate-500">Total</span>
                  <span className="text-base font-semibold text-slate-500 tabular-nums">
                    {totalBultos % 1 === 0 ? totalBultos : totalBultos.toFixed(1)} bultos
                  </span>
                  <span className="text-2xl font-bold text-slate-900">{fmtMoneda(total)}</span>
                </div>
                <div className="flex gap-3 w-full sm:w-auto">
                  <button
                    onClick={() => {
                      if (lineas.length && !window.confirm("¿Cancelar el pedido y empezar de nuevo?")) return;
                      resetTodo();
                    }}
                    className="flex-1 sm:flex-none whitespace-nowrap px-4 sm:px-5 py-2.5 sm:py-3 rounded-lg border border-red-300 text-red-600 font-semibold hover:bg-red-50"
                  >
                    Cancelar
                  </button>
                  <button
                    onClick={confirmar}
                    disabled={mut.isPending || lineas.length === 0 || mezclaInvalida}
                    className="flex-1 sm:flex-none whitespace-nowrap px-4 sm:px-6 py-2.5 sm:py-3 rounded-lg bg-pepe-yellow text-slate-900 text-base sm:text-lg font-bold hover:brightness-95 disabled:opacity-50"
                  >
                    {mut.isPending
                      ? "Enviando…"
                      : agregarA?.en_caja
                      ? `Agregar al pedido #${agregarA.nro_doc}`
                      : agregarA
                      ? "Confirmar agregado"
                      : "Confirmar pedido"}
                  </button>
                </div>
              </div>
            </div>
          </>
        )}
      </div>

      {/* Confirm in-house de "enviar a caja": detalle línea por línea (mismo
          molde visual que las "últimas 3 compras") — en la tablet el confirm
          nativo se aceptaba sin ver qué se mandaba. */}
      {confirmOpen && cliente && (
        <ConfirmDialog
          size="lg"
          title={
            agregarA?.en_caja
              ? `¿Agregar estos productos al pedido #${agregarA.nro_doc} de ${cliente.nombre}?`
              : agregarA
              ? `¿Enviar el AGREGADO al pedido #${agregarA.nro_doc} de ${cliente.nombre}?`
              : `¿Enviar a caja el pedido de ${cliente.nombre}?`
          }
          message={
            <div className="space-y-3">
              <div className="rounded-lg border border-pepe-border/70 bg-slate-50/60 p-3">
                <ul className="space-y-1.5">
                  {lineas.map((l) => {
                    const c = parseNum(l.cantidad);
                    const p = parseNum(l.precio);
                    const pct = !esDescuento(l.cod_art) && l.base && l.base > 0 && p > 0
                      ? Math.round((p / l.base - 1) * 100)
                      : null;
                    return (
                      <li key={l.cod_art} className="flex items-center gap-2 text-sm">
                        {l.icono ? (
                          <img src={`/categorias/${l.icono}.svg`} alt="" className="w-5 h-5 object-contain shrink-0" />
                        ) : (
                          <span className="w-5 h-5 shrink-0" aria-hidden />
                        )}
                        {/* Sin truncate: en el celu "Banana Paraguay…" y "Banana Brasil…"
                            quedaban iguales ("Banan…") — el nombre baja de línea entero. */}
                        <span className="flex-1 min-w-0 break-words leading-tight text-slate-700">{l.descripcion}</span>
                        {pct != null && pct !== 0 && (
                          <span className={`shrink-0 text-[11px] font-bold ${pct > 0 ? "text-green-600" : "text-red-600"}`}>
                            {pct > 0 ? "+" : ""}{pct}%
                          </span>
                        )}
                        <span className="shrink-0 whitespace-nowrap text-slate-500 tabular-nums">
                          {c % 1 === 0 ? c : c.toFixed(1)} blt × <strong className="text-slate-900">{fmtMoneda(p)}</strong>{" "}
                          = <strong className="text-slate-900">{fmtMoneda(c * p)}</strong>
                        </span>
                      </li>
                    );
                  })}
                </ul>
                <div className="mt-2 pt-2 border-t border-pepe-border/70 flex items-center justify-between text-sm">
                  <span className="text-slate-500">
                    {lineas.length} producto{lineas.length === 1 ? "" : "s"} ·{" "}
                    {totalBultos % 1 === 0 ? totalBultos : totalBultos.toFixed(1)} bultos
                  </span>
                  <span className="font-bold text-base text-slate-900">{fmtMoneda(total)}</span>
                </div>
              </div>
              <div className="flex items-center gap-2 text-xs flex-wrap">
                {agregarA ? (
                  <span className={`inline-flex px-2 py-0.5 rounded font-bold ${agregarA.en_caja ? "bg-sky-100 text-sky-800" : "bg-indigo-100 text-indigo-800"}`}>
                    {agregarA.en_caja ? `SE AGREGA AL PEDIDO #${agregarA.nro_doc}` : `AGREGADO DEL #${agregarA.nro_doc}`}
                  </span>
                ) : null}
                {!agregarA?.en_caja && (
                  <>
                    <span className={`inline-flex px-2 py-0.5 rounded font-medium ${credito ? "bg-amber-100 text-amber-800" : "bg-emerald-100 text-emerald-800"}`}>
                      {credito ? "CRÉDITO" : "CONTADO"}
                    </span>
                    <span className="inline-flex px-2 py-0.5 rounded font-medium bg-slate-100 text-slate-700">
                      Depósito {deposito}
                    </span>
                    {observaciones.trim() && (
                      <span className="text-slate-500 truncate">Obs: {observaciones.trim()}</span>
                    )}
                  </>
                )}
              </div>
            </div>
          }
          confirmLabel="Enviar a caja"
          cancelLabel="Seguir editando"
          confirmOnEnter={false}
          onConfirm={() => {
            setConfirmOpen(false);
            mut.mutate();
          }}
          onCancel={() => setConfirmOpen(false)}
        />
      )}

      {/* Cambiar de cliente con productos cargados: ¿se equivocaron de cliente
          (conservar) o quedó un pedido a medias del anterior (limpiar)? */}
      {cambioClienteOpen && (
        <div
          className="fixed inset-0 z-[75] bg-black/50 flex items-center justify-center p-4"
          onClick={() => setCambioClienteOpen(false)}
        >
          <div
            onClick={(e) => e.stopPropagation()}
            className="bg-white rounded-2xl shadow-2xl w-full max-w-md p-5 space-y-4 max-h-[85dvh] overflow-y-auto"
          >
            <div>
              <h3 className="text-lg font-bold text-slate-900">Cambiar de cliente</h3>
              <p className="text-sm text-slate-500 mt-1">
                Tenés {lineas.length} producto{lineas.length === 1 ? "" : "s"} cargado
                {lineas.length === 1 ? "" : "s"} ({totalBultos % 1 === 0 ? totalBultos : totalBultos.toFixed(1)}{" "}
                bultos). ¿Qué hacemos con {lineas.length === 1 ? "él" : "ellos"}?
              </p>
            </div>

            <button
              onClick={() => cambiarCliente(false)}
              className="w-full text-left p-4 rounded-xl border-2 border-pepe-blue bg-pepe-blue/5 hover:bg-pepe-blue/10"
            >
              <div className="font-bold text-pepe-blue">Conservar los productos</div>
              <div className="text-xs text-slate-600 mt-0.5">
                Me equivoqué de cliente: paso los mismos productos y bultos al nuevo. Los precios se
                vuelven a calcular con la lista del cliente que elija (los ajustes que hayas hecho a
                mano se pierden).
              </div>
            </button>

            <button
              onClick={() => cambiarCliente(true)}
              className="w-full text-left p-4 rounded-xl border-2 border-red-300 bg-red-50/60 hover:bg-red-50"
            >
              <div className="font-bold text-red-700">Limpiar y empezar de cero</div>
              <div className="text-xs text-slate-600 mt-0.5">
                Descarto {lineas.length === 1 ? "el producto" : "los productos"} y arranco un pedido
                nuevo para el otro cliente.
              </div>
            </button>

            <button
              onClick={() => setCambioClienteOpen(false)}
              className="w-full py-3 rounded-xl border border-pepe-border text-slate-600 font-semibold hover:bg-slate-50"
            >
              Cancelar (seguir con {cliente?.nombre ?? "este cliente"})
            </button>
          </div>
        </div>
      )}

      {/* Picker POS (categorías → país → producto → color de banana). Queda
          abierto para agregar varios (stayOpen). */}
      {pickerOpen && cliente && (
        <ArticuloPickerModal
          conVariantes
          stayOpen
          ordenVentas
          conDescuentos
          conEnvases
          conCantidad
          conPrecio
          precios={preciosMap}
          onNeedPrecios={needPrecios}
          bloquearSinPrecio
          onClose={() => setPickerOpen(false)}
          onSelect={agregarArticulo}
        />
      )}

      {/* Teclado en pantalla (tablet): editar cantidad/precio con el numpad */}
      {numpad && (
        <NumpadModal
          titulo={numpad.titulo}
          decimal={numpad.decimal}
          onConfirm={(v) => {
            const linea = lineas.find((l) => l.cod_art === numpad.cod);
            const val = numpad.campo === "precio" && linea ? clampPrecio(linea, v) : v;
            updateLinea(numpad.cod, numpad.campo, val);
            setNumpad(null);
          }}
          onClose={() => setNumpad(null)}
        />
      )}

      {/* Feedback de "agregado" (sobre el modal) */}
      {flash && (
        <div className="fixed bottom-4 left-1/2 -translate-x-1/2 z-[80] px-4 py-2.5 rounded-lg bg-slate-900 text-white text-sm shadow-lg flex items-center gap-2">
          <svg className="w-4 h-4 text-green-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
          </svg>
          <span className="truncate max-w-[70vw]">{flash} agregado</span>
        </div>
      )}
    </div>
  );
}

// ── Pedidos de HOY del cliente: banner "agregar productos" ──────────────────

function chipEstadoHoy(p: PedidoHoyCliente): { label: string; cls: string } {
  if (p.en_caja) return { label: "EN CAJA", cls: "bg-sky-100 text-sky-800" };
  if (p.entregado_registrado || p.estado === "ENTREGADO")
    return { label: "YA ENTREGADO", cls: "bg-emerald-100 text-emerald-800" };
  switch (p.estado) {
    case "ASIGNADO": return { label: "EN DEPÓSITO", cls: "bg-blue-100 text-pepe-blue" };
    case "PARCIAL": return { label: "ENTREGA PARCIAL", cls: "bg-purple-100 text-purple-800" };
    case "DEVUELTO": return { label: "DEVUELTO", cls: "bg-rose-100 text-rose-800" };
    default: return { label: "SALIÓ DE CAJA", cls: "bg-amber-100 text-amber-800" };
  }
}

function PedidosHoyBanner({
  pedidos,
  onAgregar,
}: {
  pedidos: PedidoHoyCliente[];
  onAgregar: (p: PedidoHoyCliente) => void;
}) {
  const visibles = pedidos.filter((p) => !p.solo_descuentos);
  if (visibles.length === 0) return null;
  return (
    <div className="p-3 rounded-lg border border-sky-200 bg-sky-50/60 space-y-2">
      <div className="text-xs font-bold uppercase tracking-wide text-sky-800">
        Este cliente ya tiene {visibles.length === 1 ? "un pedido" : `${visibles.length} pedidos`} hoy
      </div>
      <ul className="space-y-2">
        {visibles.map((p) => {
          const chip = chipEstadoHoy(p);
          return (
            <li key={p.nro_fact} className="p-2.5 rounded-md border border-pepe-border bg-white flex items-center gap-3 flex-wrap">
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2 flex-wrap text-sm">
                  <span className="font-mono font-bold text-slate-900">#{p.nro_doc}</span>
                  {p.hora && <span className="text-xs text-slate-400">{p.hora}</span>}
                  <span className={`inline-flex px-1.5 py-0.5 rounded text-[10px] font-bold ${chip.cls}`}>{chip.label}</span>
                  {p.deposito && !p.en_caja && (
                    <span className="text-[10px] text-slate-500 font-semibold">Dep. {p.deposito}</span>
                  )}
                  {p.armador_nombre && !p.en_caja && (
                    <span className="text-[10px] text-slate-500">arma {p.armador_nombre}</span>
                  )}
                  {p.agregado_de != null && (
                    <span className="inline-flex px-1.5 py-0.5 rounded text-[10px] font-bold bg-indigo-100 text-indigo-700">
                      YA ES AGREGADO
                    </span>
                  )}
                </div>
                {p.resumen && <div className="text-xs text-slate-500 truncate mt-0.5">{p.resumen}</div>}
              </div>
              <div className="shrink-0 text-right">
                <div className="text-xs text-slate-500 mb-1">{fmtMoneda(p.total)}</div>
                <button
                  onClick={() => onAgregar(p)}
                  className={`px-3 py-2 rounded-md text-xs font-bold border ${
                    p.en_caja
                      ? "bg-sky-600 border-sky-600 text-white hover:bg-sky-700"
                      : "bg-white border-indigo-300 text-indigo-700 hover:bg-indigo-50"
                  }`}
                >
                  {p.en_caja ? "Agregar a este pedido" : "Encadenar agregado"}
                </button>
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

// ── Picker de cliente (búsqueda inline) ─────────────────────────────────────

function ClientePicker({ onSelect }: { onSelect: (c: ClienteVenta) => void }) {
  const [q, setQ] = useState("");
  const [creando, setCreando] = useState(false);
  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setDebounced(q.trim()), 250);
    return () => clearTimeout(t);
  }, [q]);

  const { data: resultados, isFetching } = useQuery({
    queryKey: ["venta-clientes", debounced],
    queryFn: () => searchClientesVenta(debounced),
    enabled: debounced.length >= 2,
  });

  // iPad: acota la lista de resultados al alto visible arriba del teclado (si no,
  // el teclado nativo la tapa). Ver el hook. En desktop no limita nada.
  const listRef = useRef<HTMLUListElement>(null);
  const maxH = useKeyboardMaxHeight(listRef, [debounced, resultados]);

  return (
    <section className="p-4 rounded-lg border border-pepe-border bg-white space-y-3">
      <h3 className="text-sm font-semibold text-slate-700">Cliente</h3>
      <div className="flex flex-col sm:flex-row gap-2">
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Buscar por nombre, RUT o código…"
          autoFocus
          className="flex-1 min-w-0 px-3 py-2.5 rounded-lg border border-pepe-border text-base"
        />
        <button
          onClick={() => setCreando(true)}
          className="shrink-0 w-full sm:w-auto inline-flex items-center justify-center gap-1.5 px-4 py-2.5 rounded-lg bg-pepe-blue text-sm font-semibold text-white hover:bg-pepe-blue/90"
        >
          <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
          </svg>
          Crear cliente
        </button>
        <button
          onClick={() =>
            onSelect({
              cod: CONSUMIDOR_FINAL_COD,
              nombre: "Consumidor Final",
              ruc: "",
              direccion: "",
              moneda: 1,
              estado_cliente: "Activo",
              pedidos_recientes: 0,
            })
          }
          className="shrink-0 w-full sm:w-auto px-4 py-2.5 rounded-lg border border-pepe-border text-sm font-semibold text-slate-700 hover:bg-slate-50"
        >
          Consumidor final
        </button>
      </div>
      {debounced.length >= 2 && (
        <ul
          ref={listRef}
          style={maxH ? { maxHeight: maxH } : undefined}
          className={`grid grid-cols-1 sm:grid-cols-2 gap-2 ${maxH ? "overflow-y-auto overscroll-contain" : ""}`}
        >
          {(resultados ?? []).map((c) => (
            <li key={c.cod}>
              <button
                onClick={() => onSelect(c)}
                className="w-full text-left p-3 rounded-lg border border-pepe-border hover:border-pepe-blue hover:bg-pepe-blue/5"
              >
                <div className="font-semibold text-pepe-blue truncate">{c.nombre}</div>
                <div className="text-xs text-slate-500 mt-0.5">
                  Código {c.cod}
                  {c.ruc ? ` · RUT ${c.ruc}` : ""}
                  {c.pedidos_recientes > 0 && ` · ${c.pedidos_recientes} pedidos (90d)`}
                </div>
                {c.estado_cliente && c.estado_cliente !== "Activo" && (
                  <span className="inline-block mt-1 px-1.5 py-0.5 rounded bg-amber-100 text-amber-800 text-[10px] font-semibold">
                    {c.estado_cliente}
                  </span>
                )}
              </button>
            </li>
          ))}
          {resultados && resultados.length === 0 && !isFetching && (
            <li className="text-sm text-slate-400 p-2">Sin resultados para "{debounced}".</li>
          )}
        </ul>
      )}
      {creando && (
        <CrearClienteModal
          nombreInicial={debounced}
          onClose={() => setCreando(false)}
          onCreado={(c) => {
            setCreando(false);
            onSelect(c);
          }}
        />
      )}
    </section>
  );
}

/** Alta mínima: Nombre obligatorio; RUT/teléfono/dirección opcionales. El
 * cliente nace Activo en Macrosoft (código autogenerado) y queda ELEGIDO. */
function CrearClienteModal({
  nombreInicial,
  onClose,
  onCreado,
}: {
  nombreInicial: string;
  onClose: () => void;
  onCreado: (c: ClienteVenta) => void;
}) {
  const qc = useQueryClient();
  const [nombre, setNombre] = useState(nombreInicial);
  const [ruc, setRuc] = useState("");
  const [telefono, setTelefono] = useState("");
  const [direccion, setDireccion] = useState("");
  const crear = useMutation({
    mutationFn: () =>
      crearCliente({
        nombre: nombre.trim(),
        ruc: ruc.trim() || null,
        telefono: telefono.trim() || null,
        direccion: direccion.trim() || null,
      }),
    onSuccess: (out) => {
      qc.invalidateQueries({ queryKey: ["venta-clientes"] });
      onCreado({
        cod: out.cod,
        nombre: out.nombre,
        ruc: ruc.trim(),
        direccion: direccion.trim(),
        moneda: 1,
        estado_cliente: "Activo",
        pedidos_recientes: 0,
      });
    },
  });
  const valido = nombre.trim().length >= 3;
  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/40 p-4" onClick={onClose}>
      <div className="w-full max-w-md rounded-xl bg-white p-5 shadow-2xl space-y-3" onClick={(e) => e.stopPropagation()}>
        <h3 className="text-lg font-semibold text-slate-900">Crear cliente nuevo</h3>
        <p className="text-xs text-slate-500">
          Se crea en Macrosoft al instante. Solo el nombre es obligatorio; el RUT
          hace falta si va a facturar con RUT o a crédito.
        </p>
        <label className="block">
          <span className="text-xs font-bold uppercase tracking-wider text-slate-500">Nombre *</span>
          <input value={nombre} onChange={(e) => setNombre(e.target.value)} autoFocus
                 maxLength={150}
                 className="mt-1 w-full rounded-lg border border-pepe-border px-3 py-2.5 text-base" />
        </label>
        <label className="block">
          <span className="text-xs font-bold uppercase tracking-wider text-slate-500">RUT (opcional)</span>
          <input value={ruc} onChange={(e) => setRuc(e.target.value.replace(/[^0-9]/g, ""))}
                 type="text" inputMode="numeric" maxLength={12} placeholder="12 dígitos"
                 className="mt-1 w-full rounded-lg border border-pepe-border px-3 py-2.5 text-base" />
        </label>
        <div className="grid grid-cols-2 gap-2">
          <label className="block">
            <span className="text-xs font-bold uppercase tracking-wider text-slate-500">Teléfono</span>
            <input value={telefono} onChange={(e) => setTelefono(e.target.value)} maxLength={20}
                   type="text" inputMode="tel"
                   className="mt-1 w-full rounded-lg border border-pepe-border px-3 py-2.5 text-base" />
          </label>
          <label className="block">
            <span className="text-xs font-bold uppercase tracking-wider text-slate-500">Dirección</span>
            <input value={direccion} onChange={(e) => setDireccion(e.target.value)} maxLength={80}
                   className="mt-1 w-full rounded-lg border border-pepe-border px-3 py-2.5 text-base" />
          </label>
        </div>
        {crear.isError && (
          <div className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800">
            {(crear.error as Error).message}
          </div>
        )}
        <div className="flex justify-end gap-2 pt-1">
          <button onClick={onClose} className="rounded-lg px-4 py-2.5 text-sm font-medium text-slate-600 hover:bg-slate-100">
            Cancelar
          </button>
          <button
            onClick={() => crear.mutate()}
            disabled={!valido || crear.isPending}
            className="rounded-lg bg-pepe-blue px-5 py-2.5 text-sm font-bold text-white hover:bg-pepe-blue/90 disabled:opacity-50"
          >
            {crear.isPending ? "Creando…" : "Crear y elegir"}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── Historial del cliente: últimas compras con precio y bultos (referencia) ──

function HistorialClienteCol({
  clienteCod,
  clienteNombre,
  className = "",
}: {
  clienteCod: number;
  clienteNombre: string;
  className?: string;
}) {
  const navigate = useNavigate();
  const { data: historial, isLoading } = useQuery({
    queryKey: ["venta-historial", clienteCod],
    queryFn: () => getHistorialCliente(clienteCod),
    staleTime: 60 * 1000,
  });

  return (
    <section className={`p-4 rounded-lg border border-pepe-border bg-white space-y-3 ${className}`}>
      <h3 className="text-sm font-semibold text-slate-700">Últimas compras de este cliente</h3>
      {isLoading ? (
        <p className="text-sm text-slate-400">Cargando…</p>
      ) : !historial || historial.length === 0 ? (
        <p className="text-sm text-slate-400">Sin compras en los últimos 30 días.</p>
      ) : (
        <ul className="space-y-3">
          {historial.map((p) => (
            <li key={p.nro_fact} className="rounded-lg border border-pepe-border/70 bg-slate-50/60 p-3">
              <div className="flex items-center justify-between text-xs text-slate-500 mb-2">
                <span className="font-medium min-w-0 truncate">
                  #{p.nro_doc} · {fmtFechaCorta(p.fecha)}
                  {p.vendedor_nombre ? (
                    <span className="text-slate-400"> · {p.vendedor_nombre}</span>
                  ) : null}
                </span>
                <span className="shrink-0 font-semibold text-slate-700">{fmtMoneda(p.total)}</span>
              </div>
              <ul className="space-y-1.5">
                {p.lineas.map((l, i) => (
                  <li key={i} className="flex items-center gap-2 text-sm">
                    {l.icono ? (
                      <img src={`/categorias/${l.icono}.svg`} alt="" className="w-5 h-5 object-contain shrink-0" />
                    ) : (
                      <span className="w-5 h-5 shrink-0" aria-hidden />
                    )}
                    <span className="flex-1 min-w-0 truncate text-slate-700">{l.descripcion}</span>
                    <span className="shrink-0 whitespace-nowrap text-slate-500 tabular-nums">
                      {l.cantidad % 1 === 0 ? l.cantidad : l.cantidad.toFixed(1)} blt ×{" "}
                      <strong className="text-slate-900">{fmtMoneda(l.precio)}</strong>
                    </span>
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ul>
      )}
      <button
        onClick={() =>
          navigate(`/venta/pedidos?cliente=${clienteCod}&nombre=${encodeURIComponent(clienteNombre)}`)
        }
        className="w-full flex items-center justify-center gap-1.5 px-3 py-2.5 rounded-lg border border-pepe-border text-sm font-semibold text-pepe-blue hover:bg-pepe-blue/5"
      >
        Ver todos los pedidos de este cliente
        <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M13.5 4.5L21 12m0 0l-7.5 7.5M21 12H3" />
        </svg>
      </button>
    </section>
  );
}

function IconoCat({ icono }: { icono: string | null }) {
  if (!icono) return <span className="shrink-0 w-8 h-8 rounded bg-slate-100" aria-hidden />;
  return <img src={`/categorias/${icono}.svg`} alt="" className="shrink-0 w-8 h-8 object-contain" />;
}

/** Disponible de la FAMILIA del artículo, no el del color: el saldo por color
 *  es ficción (la fruta entra como Color 1 y se vende madura), así que todos
 *  los colores de una banana muestran el mismo número.
 *  <= 0 se muestra como "sin stock": los negativos chicos son residuo del
 *  ledger de maduración, no un faltante, y "−90" no le sirve a nadie. */
function StockBadge({ disponible, esFamilia = false }: { disponible: number; esFamilia?: boolean }) {
  if (disponible <= 0) {
    return (
      <span className="px-1.5 py-0.5 rounded bg-rose-100 text-rose-700 text-[10px] font-bold uppercase tracking-wide whitespace-nowrap">
        Sin stock
      </span>
    );
  }
  return (
    <span
      title={
        esFamilia
          ? "Total de TODA la familia (todos los colores juntos) — sin dato del color de esta línea"
          : "Disponible de la familia, descontando los pedidos que ya están en la cola de caja"
      }
      className="px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-800 text-[11px] font-bold tabular-nums whitespace-nowrap"
    >
      {esFamilia ? "familia: " : ""}{disponible.toLocaleString("es-UY", { maximumFractionDigits: 0 })} disp.
    </span>
  );
}

/** Chip del COLOR de la línea (cámaras en ese color según Charlie − vendido
 * hoy − comprometido). Estimativo (~) y jamás bloquea. */
function ColorStockBadge({ pool }: { pool: import("../../shared/api/stock").StockColorPool }) {
  const disp = pool.disponible_estimado;
  const cls =
    disp <= 0
      ? "bg-rose-100 text-rose-700"
      : disp < 100
        ? "bg-amber-100 text-amber-800"
        : "bg-emerald-100 text-emerald-800";
  return (
    <span
      title={`Color ${pool.color} · cámaras ${pool.camaras.map((c) => c.numero).join(", ")} · vendido hoy ${pool.vendido_hoy} · comprometido ${pool.comprometido}. Estimado, se re-ancla con el conteo de la mañana.`}
      className={`px-1.5 py-0.5 rounded text-[11px] font-bold tabular-nums whitespace-nowrap ${cls}`}
    >
      {disp <= 0 ? "Sin stock color" : `~${Math.round(disp).toLocaleString("es-UY")} color ${pool.color}`}
    </span>
  );
}

function Segmented({
  value,
  onChange,
  options,
}: {
  value: string;
  onChange: (v: string) => void;
  options: { value: string; label: string }[];
}) {
  return (
    <div className="inline-flex rounded-lg border border-pepe-border overflow-hidden">
      {options.map((o) => (
        <button
          key={o.value}
          onClick={() => onChange(o.value)}
          className={`px-5 py-3 text-base font-semibold ${
            value === o.value ? "bg-pepe-blue text-white" : "bg-white text-slate-600 hover:bg-slate-50"
          }`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
