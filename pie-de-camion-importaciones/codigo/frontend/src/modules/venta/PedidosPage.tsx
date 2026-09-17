import { useEffect, useRef, useState } from "react";
import { partirOrigen } from "../../shared/origen";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuth } from "../../shared/AuthContext";
import { useKeyboardMaxHeight } from "../../shared/hooks/useKeyboardMaxHeight";
import { listVendedores } from "../../shared/api/lookups";
// El video del pallet vive en Entregas pero se mira desde acá: al vendedor
// le reclaman por su pedido, no por la entrega.
import { VideosDelPedido } from "../entregas/components/VideosDelPedido";
import { EntregaElevadoristaDePedido } from "../elevadoristas/AsignarElevadorista";
import {
  anularPedidoVenta,
  marcarPrioridadPedido,
  errorLegible,
  getPedidoVenta,
  listPedidosVenta,
  searchClientesVenta,
  type ClienteVenta,
  type PedidoVentaListItem,
} from "./api";

/* Módulo Venta — Pedidos: Míos / Todos (con filtro por vendedor, solo venta_todos)
   / Por cliente (historial completo de un cliente, feature nueva). */

type Tab = "mios" | "todos" | "cliente";

const fmtMoneda = (n: number) =>
  "$" + n.toLocaleString("es-UY", { minimumFractionDigits: 0, maximumFractionDigits: 2 });

const CHIP: Record<string, { label: string; cls: string }> = {
  en_caja: { label: "En caja", cls: "bg-amber-100 text-amber-800" },
  facturado: { label: "Facturado", cls: "bg-blue-100 text-blue-800" },
  asignado: { label: "Asignado", cls: "bg-indigo-100 text-indigo-800" },
  entregado: { label: "Entregado", cls: "bg-green-100 text-green-800" },
  parcial: { label: "Parcial", cls: "bg-orange-100 text-orange-800" },
  devuelto: { label: "Devuelto", cls: "bg-red-100 text-red-700" },
  anulado: { label: "Anulado", cls: "bg-slate-200 text-slate-600" },
};

function EstadoChip({ estado }: { estado: string }) {
  const c = CHIP[estado] ?? { label: estado, cls: "bg-slate-100 text-slate-600" };
  return (
    <span className={`inline-block px-2 py-0.5 rounded-full text-xs font-semibold ${c.cls}`}>
      {c.label}
    </span>
  );
}

export function PedidosVentaPage() {
  const { hasPermission } = useAuth();
  const puedeTodos = ["admin", "venta_todos"].some(hasPermission);
  // Deep-link desde "Nuevo pedido" (?cliente=<cod>&nombre=<nombre>): abre la
  // pestaña "Por cliente" con ese cliente ya elegido para ver todo su historial.
  const [params] = useSearchParams();
  const codParam = params.get("cliente");
  const nombreParam = params.get("nombre");
  const [tab, setTab] = useState<Tab>(codParam ? "cliente" : "mios");
  const [fecha, setFecha] = useState("");
  const [vendedor, setVendedor] = useState<number | "">("");
  const [cliente, setCliente] = useState<ClienteVenta | null>(
    codParam
      ? {
          cod: Number(codParam),
          nombre: nombreParam ?? `Cliente ${codParam}`,
          ruc: "",
          direccion: "",
          moneda: 0,
          estado_cliente: "",
          pedidos_recientes: 0,
        }
      : null,
  );

  return (
    <div className="h-full overflow-y-auto overscroll-y-contain">
      <div className="max-w-screen-2xl mx-auto p-4 sm:p-6 space-y-4 pb-10">
      <h2 className="text-xl font-bold text-slate-900">Pedidos</h2>

      <div className="flex flex-wrap items-center gap-2">
        <div className="inline-flex rounded-lg border border-pepe-border overflow-hidden">
          {(
            [
              ["mios", "Mis pedidos"],
              ...(puedeTodos ? ([["todos", "Todos"]] as const) : []),
              ["cliente", "Por cliente"],
            ] as [Tab, string][]
          ).map(([t, label]) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`px-4 py-2.5 text-sm font-semibold ${
                tab === t ? "bg-pepe-blue text-white" : "bg-white text-slate-600 hover:bg-slate-50"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {tab !== "cliente" && (
          <input
            type="date"
            value={fecha}
            onChange={(e) => setFecha(e.target.value)}
            className="px-3 py-2 rounded-md border border-pepe-border text-sm"
          />
        )}
        {tab === "todos" && <VendedorFilter value={vendedor} onChange={setVendedor} />}
      </div>

      {tab === "cliente" && (
        <ClienteSearchInline cliente={cliente} onSelect={setCliente} onClear={() => setCliente(null)} />
      )}

      {tab === "cliente" ? (
        // Vista "Por cliente" = vistazo rápido de qué compra el cliente:
        // íconos + bultos + total por pedido, detalle en el desplegable.
        cliente && <TablaPedidosCliente clienteCod={cliente.cod} />
      ) : (
        <TablaPedidos
          tab={tab}
          fecha={fecha || undefined}
          vendedor={tab === "todos" && vendedor !== "" ? vendedor : undefined}
        />
      )}
      </div>
    </div>
  );
}

function VendedorFilter({
  value,
  onChange,
}: {
  value: number | "";
  onChange: (v: number | "") => void;
}) {
  const { data } = useQuery({ queryKey: ["lookups-vendedores"], queryFn: listVendedores, staleTime: 10 * 60 * 1000 });
  return (
    <select
      value={value === "" ? "" : String(value)}
      onChange={(e) => onChange(e.target.value === "" ? "" : Number(e.target.value))}
      className="px-3 py-2 rounded-md border border-pepe-border text-sm bg-white"
    >
      <option value="">Todos los vendedores</option>
      {(data ?? []).map((v) => (
        <option key={v.cod} value={v.cod}>
          {v.cod} — {v.nombre}
        </option>
      ))}
    </select>
  );
}

function ClienteSearchInline({
  cliente,
  onSelect,
  onClear,
}: {
  cliente: ClienteVenta | null;
  onSelect: (c: ClienteVenta) => void;
  onClear: () => void;
}) {
  const [q, setQ] = useState("");
  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setDebounced(q.trim()), 250);
    return () => clearTimeout(t);
  }, [q]);
  const { data } = useQuery({
    queryKey: ["venta-clientes", debounced],
    queryFn: () => searchClientesVenta(debounced),
    enabled: !cliente && debounced.length >= 2,
  });
  // iPad: acota los resultados al alto visible arriba del teclado (ver hook).
  const listRef = useRef<HTMLUListElement>(null);
  const maxH = useKeyboardMaxHeight(listRef, [debounced, data]);

  if (cliente) {
    return (
      <div className="p-3 rounded-lg border border-pepe-border bg-white flex items-center justify-between gap-3">
        <div>
          <span className="font-semibold text-pepe-blue">{cliente.nombre}</span>
          <span className="text-xs text-slate-500 ml-2">Código {cliente.cod}</span>
        </div>
        <button onClick={onClear} className="text-sm text-slate-500 underline px-3 py-2 -mx-3 -my-2 sm:p-0 sm:m-0">
          Cambiar
        </button>
      </div>
    );
  }
  return (
    <div className="space-y-2">
      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Buscar cliente por nombre, RUT o código…"
        autoFocus
        className="w-full sm:w-96 px-4 py-3 rounded-lg border border-pepe-border text-base"
      />
      {debounced.length >= 2 && (
        <ul
          ref={listRef}
          style={maxH ? { maxHeight: maxH } : undefined}
          className={`grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-2 ${maxH ? "overflow-y-auto overscroll-contain" : ""}`}
        >
          {(data ?? []).map((c) => (
            <li key={c.cod}>
              <button
                onClick={() => onSelect(c)}
                className="w-full text-left p-3 rounded-lg border border-pepe-border hover:border-pepe-blue hover:bg-pepe-blue/5"
              >
                <div className="font-semibold text-pepe-blue truncate">{c.nombre}</div>
                <div className="text-xs text-slate-500">
                  Código {c.cod}
                  {c.pedidos_recientes > 0 && ` · ${c.pedidos_recientes} pedidos (90d)`}
                </div>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function TablaPedidos({
  tab,
  fecha,
  vendedor,
  clienteCod,
}: {
  tab: Tab;
  fecha?: string;
  vendedor?: number;
  clienteCod?: number;
}) {
  const qc = useQueryClient();
  const [abierto, setAbierto] = useState<number | null>(null);

  const { data: pedidos, isLoading } = useQuery({
    queryKey: ["venta-pedidos", tab, fecha ?? null, vendedor ?? null, clienteCod ?? null],
    queryFn: () =>
      listPedidosVenta({
        scope: tab === "todos" ? "todos" : "mios",
        cliente: clienteCod,
        vendedor,
        fecha,
        conResumen: true, // íconos + bultos por pedido
      }),
    refetchInterval: 30_000, // el estado (caja/entregas) cambia solo
  });

  const anular = useMutation({
    mutationFn: (nroFact: number) => anularPedidoVenta(nroFact),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["venta-pedidos"] }),
    onError: (e: Error) => {
      window.alert(errorLegible(e.message));
      qc.invalidateQueries({ queryKey: ["venta-pedidos"] });
    },
  });

  const prioridad = useMutation({
    mutationFn: ({ nroFact, prioritario }: { nroFact: number; prioritario: boolean }) =>
      marcarPrioridadPedido(nroFact, prioritario),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["venta-pedidos"] }),
    onError: (e: Error) => window.alert(errorLegible(e.message)),
  });

  if (isLoading) return <p className="text-sm text-slate-400">Cargando…</p>;
  if (!pedidos || pedidos.length === 0)
    return <p className="text-sm text-slate-400">No hay pedidos para mostrar.</p>;

  return (
    <div className="tabla-scroll rounded-lg border border-pepe-border bg-white">
      <table className="min-w-[1040px] w-full text-sm">
        <thead>
          <tr className="text-left text-xs uppercase text-slate-400 border-b border-pepe-border">
            <th className="px-3 py-2.5">Nº</th>
            <th className="px-3 py-2.5">Fecha</th>
            <th className="px-3 py-2.5">Hora</th>
            <th className="px-3 py-2.5">Cliente</th>
            <th className="px-3 py-2.5">Vendedor</th>
            <th className="px-3 py-2.5">Productos</th>
            <th className="px-3 py-2.5 text-right">Bultos</th>
            <th className="px-3 py-2.5 text-right">Total</th>
            <th className="px-3 py-2.5">Pago</th>
            <th className="px-3 py-2.5">Estado</th>
            <th className="px-3 py-2.5" />
          </tr>
        </thead>
        <tbody>
          {pedidos.map((p) => (
            <FilaPedido
              key={p.nro_fact}
              p={p}
              abierto={abierto === p.nro_fact}
              onToggle={() => setAbierto(abierto === p.nro_fact ? null : p.nro_fact)}
              onAnular={() => {
                if (window.confirm(`¿Anular el pedido #${p.nro_doc || p.nro_fact} de ${p.cliente_nombre}? Sale de la cola de caja.`))
                  anular.mutate(p.nro_fact);
              }}
              anulando={anular.isPending}
              onPrioridad={() => {
                // El aviso al MARCAR dice que la alarma no se apaga sola: así el
                // vendedor sabe desde el principio que la saca desde acá mismo.
                const msg = p.prioritario
                  ? `¿Quitar la prioridad del pedido #${p.nro_doc || p.nro_fact} de ${p.cliente_nombre}?\n\nDeja de sonar la alarma de la tele y vuelve al orden normal en asignación.`
                  : `¿Marcar el pedido #${p.nro_doc || p.nro_fact} de ${p.cliente_nombre} como PRIORITARIO?\n\nVa a aparecer primero en asignación, le avisa al armador y la tele suena cada 20 segundos hasta que se entregue o le saques la prioridad desde este mismo botón.`;
                if (window.confirm(msg)) prioridad.mutate({ nroFact: p.nro_fact, prioritario: !p.prioritario });
              }}
            />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function FilaPedido({
  p,
  abierto,
  onToggle,
  onAnular,
  anulando,
  onPrioridad,
}: {
  p: PedidoVentaListItem;
  abierto: boolean;
  onToggle: () => void;
  onAnular: () => void;
  anulando: boolean;
  onPrioridad: () => void;
}) {
  const { data: detail } = useQuery({
    queryKey: ["venta-pedido-detail", p.nro_fact],
    queryFn: () => getPedidoVenta(p.nro_fact),
    enabled: abierto,
  });

  const fmtFecha = (iso: string | null) => {
    if (!iso) return "—";
    const [y, m, d] = iso.split("-");
    return `${d}/${m}/${y?.slice(2)}`;
  };

  return (
    <>
      <tr
        onClick={onToggle}
        className={`border-b border-pepe-border cursor-pointer ${
          p.prioritario
            ? "bg-red-50 hover:bg-red-100/70 shadow-[inset_4px_0_0_0_#dc2626]"
            : "hover:bg-slate-50"
        } ${p.estado === "anulado" ? "opacity-50" : ""}`}
      >
        <td className="px-3 py-2.5 font-semibold text-slate-900 whitespace-nowrap">
          {p.nro_doc || p.nro_fact}
          {p.prioritario && (
            <span className="ml-1.5 inline-flex items-center gap-0.5 rounded bg-red-600 px-1.5 py-0.5 text-[10px] font-bold text-white align-middle">
              <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M3.75 13.5l10.5-11.25L12 10.5h8.25L9.75 21.75 12 13.5H3.75z" />
              </svg>
              PRIORITARIO
            </span>
          )}
        </td>
        <td className="px-3 py-2.5 whitespace-nowrap">{fmtFecha(p.fecha)}</td>
        <td className="px-3 py-2.5 whitespace-nowrap">{p.hora ?? "—"}</td>
        <td className="px-3 py-2.5 max-w-[220px] truncate">{p.cliente_nombre}</td>
        <td className="px-3 py-2.5 whitespace-nowrap">
          {p.vendedor_nombre || (p.vendedor != null ? `#${p.vendedor}` : "—")}
          {p.creado_por && (
            <span className="block text-[10px] text-slate-400">Aloha: {p.creado_por}</span>
          )}
        </td>
        <td className="px-3 py-2.5">
          <div className="flex items-center gap-1">
            {p.iconos.slice(0, 8).map((ic) => (
              <img key={ic} src={`/categorias/${ic}.svg`} alt="" className="w-6 h-6 object-contain shrink-0" />
            ))}
            {p.iconos.length > 8 && <span className="text-xs text-slate-400">+{p.iconos.length - 8}</span>}
            {p.iconos.length === 0 && <span className="text-xs text-slate-300">—</span>}
          </div>
        </td>
        <td className="px-3 py-2.5 text-right tabular-nums whitespace-nowrap">
          {p.total_bultos != null ? (p.total_bultos % 1 === 0 ? p.total_bultos : p.total_bultos.toFixed(1)) : "—"}
        </td>
        <td className="px-3 py-2.5 text-right font-semibold whitespace-nowrap">
          {p.total != null ? fmtMoneda(p.total) : "—"}
        </td>
        <td className="px-3 py-2.5 whitespace-nowrap">{p.credito ? "Crédito" : "Contado"}</td>
        <td className="px-3 py-2.5 whitespace-nowrap">
          <EstadoChip estado={p.estado} />
          {/* Hay video del pallet: el vendedor lo ve acá mismo cuando le
              reclaman, sin pedírselo a nadie. */}
          {p.videos > 0 && (
            <span className="ml-1.5 inline-flex items-center gap-1 rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-bold text-emerald-800 align-middle">
              <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 10.5l4.72-4.72a.75.75 0 011.28.53v11.38a.75.75 0 01-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 002.25-2.25v-9a2.25 2.25 0 00-2.25-2.25h-9A2.25 2.25 0 002.25 7.5v9a2.25 2.25 0 002.25 2.25z" />
              </svg>
              VIDEO
            </span>
          )}
        </td>
        <td className="px-3 py-2.5 text-right whitespace-nowrap">
          {p.estado !== "anulado" && p.estado !== "entregado" && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                onPrioridad();
              }}
              /* Un pedido de puros descuentos no se puede marcar: no lleva
                 mercadería, así que no se arma ni se entrega — el armador nunca
                 lo ve y la alarma de la tele, que se apaga al entregar, no se
                 apagaría nunca (pasó el 31/08). QUITAR sí se puede siempre: si
                 no, los que quedaron marcados de antes no tienen cómo apagarse. */
              disabled={p.solo_descuentos && !p.prioritario}
              title={
                p.solo_descuentos && !p.prioritario
                  ? "Es un pedido de descuentos: no se arma ni se entrega, marcarlo no le avisa a nadie"
                  : undefined
              }
              className={`mr-1.5 px-4 py-2.5 sm:px-3 sm:py-1.5 rounded text-xs font-semibold inline-flex items-center gap-1 align-middle ${
                p.prioritario
                  ? "border border-red-700 bg-red-600 text-white hover:bg-red-700"
                  : "border border-slate-300 text-slate-600 hover:bg-slate-50 disabled:cursor-not-allowed disabled:border-slate-200 disabled:text-slate-300 disabled:hover:bg-white"
              }`}
            >
              {p.prioritario ? (
                <>
                  {/* Rojo = ESTE es el prioritario; el texto dice qué pasa si lo tocás. */}
                  <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                  Quitar prioridad
                </>
              ) : (
                "Prioritario"
              )}
            </button>
          )}
          {p.anulable && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                onAnular();
              }}
              disabled={anulando}
              className="px-4 py-2.5 sm:px-3 sm:py-1.5 rounded border border-red-300 text-red-600 text-xs font-semibold hover:bg-red-50 disabled:opacity-50"
            >
              Anular
            </button>
          )}
        </td>
      </tr>
      {abierto && (
        <tr className="border-b border-pepe-border bg-slate-50/60">
          <td colSpan={11} className="px-4 py-3">
            {!detail ? (
              <span className="inline-block text-sm text-slate-400 sticky left-0 max-w-[calc(100vw_-_4rem)] sm:static sm:max-w-none">Cargando líneas…</span>
            ) : (
              /* En celu, sticky horizontal dentro de .tabla-scroll: el detalle queda visible sin scrollear */
              <div className="space-y-2 sticky left-0 max-w-[calc(100vw_-_4rem)] sm:static sm:max-w-none">
                <BotonNoConformidad p={p} />
                <ul className="space-y-1.5">
                  {detail.lineas.map((l) => (
                    <li key={l.id} className="flex items-center gap-2 text-sm">
                      {l.icono ? (
                        <img src={`/categorias/${l.icono}.svg`} alt="" className="w-5 h-5 object-contain shrink-0" />
                      ) : (
                        <span className="w-5 h-5 shrink-0" aria-hidden />
                      )}
                      <span className="text-slate-400 text-xs">{l.cod_art}</span>
                      <LineaDescripcion descripcion={l.descripcion} />
                      <span className="font-medium whitespace-nowrap tabular-nums">
                        {l.cantidad} × {fmtMoneda(l.precio)} = {fmtMoneda(l.total_linea)}
                      </span>
                    </li>
                  ))}
                </ul>
                {detail.observaciones && (
                  <p className="text-xs text-slate-500">
                    <strong>Obs.:</strong> {detail.observaciones}
                  </p>
                )}
                <VideosDelPedido nroFact={p.nro_fact} />
                <EntregaElevadoristaDePedido nroFact={p.nro_fact} />
              </div>
            )}
          </td>
        </tr>
      )}
    </>
  );
}

// ── Vista "Por cliente": vistazo rápido de qué compra el cliente ────────────
// Fila = fecha · vendedor · íconos de productos · bultos · total · pago · estado.
// El Nº de pedido, la hora y el detalle (producto/cantidad/precio) van en el
// desplegable. Sirve para que el vendedor vea de un pantallazo el patrón de
// compra del cliente.

function TablaPedidosCliente({ clienteCod }: { clienteCod: number }) {
  const [abierto, setAbierto] = useState<number | null>(null);
  const { data: pedidos, isLoading } = useQuery({
    queryKey: ["venta-pedidos", "cliente", clienteCod, "resumen"],
    queryFn: () => listPedidosVenta({ cliente: clienteCod, conResumen: true }),
    refetchInterval: 30_000,
  });

  if (isLoading) return <p className="text-sm text-slate-400">Cargando…</p>;
  if (!pedidos || pedidos.length === 0)
    return <p className="text-sm text-slate-400">Este cliente no tiene pedidos.</p>;

  return (
    <div className="tabla-scroll rounded-lg border border-pepe-border bg-white">
      <table className="min-w-[720px] w-full text-sm">
        <thead>
          <tr className="text-left text-xs uppercase text-slate-400 border-b border-pepe-border">
            <th className="px-3 py-2.5">Fecha</th>
            <th className="px-3 py-2.5">Vendedor</th>
            <th className="px-3 py-2.5">Productos</th>
            <th className="px-3 py-2.5 text-right">Bultos</th>
            <th className="px-3 py-2.5 text-right">Total</th>
            <th className="px-3 py-2.5">Pago</th>
            <th className="px-3 py-2.5">Estado</th>
            <th className="px-3 py-2.5" />
          </tr>
        </thead>
        <tbody>
          {pedidos.map((p) => (
            <FilaPedidoCliente
              key={p.nro_fact}
              p={p}
              abierto={abierto === p.nro_fact}
              onToggle={() => setAbierto(abierto === p.nro_fact ? null : p.nro_fact)}
            />
          ))}
        </tbody>
      </table>
    </div>
  );
}

function FilaPedidoCliente({
  p,
  abierto,
  onToggle,
}: {
  p: PedidoVentaListItem;
  abierto: boolean;
  onToggle: () => void;
}) {
  const { data: detail } = useQuery({
    queryKey: ["venta-pedido-detail", p.nro_fact],
    queryFn: () => getPedidoVenta(p.nro_fact),
    enabled: abierto,
  });

  const fmtFecha = (iso: string | null) => {
    if (!iso) return "—";
    const [y, m, d] = iso.split("-");
    return `${d}/${m}/${y?.slice(2)}`;
  };
  const fmtBultos = (n: number) => (n % 1 === 0 ? String(n) : n.toFixed(1));
  const MAX_ICONS = 8;

  return (
    <>
      <tr
        onClick={onToggle}
        className={`border-b border-pepe-border cursor-pointer ${
          p.prioritario
            ? "bg-red-50 hover:bg-red-100/70 shadow-[inset_4px_0_0_0_#dc2626]"
            : "hover:bg-slate-50"
        } ${p.estado === "anulado" ? "opacity-50" : ""}`}
      >
        <td className="px-3 py-2.5 whitespace-nowrap">{fmtFecha(p.fecha)}</td>
        <td className="px-3 py-2.5 whitespace-nowrap">
          {p.vendedor_nombre || (p.vendedor != null ? `#${p.vendedor}` : "—")}
        </td>
        <td className="px-3 py-2.5">
          <div className="flex items-center gap-1">
            {p.iconos.slice(0, MAX_ICONS).map((ic) => (
              <img key={ic} src={`/categorias/${ic}.svg`} alt="" className="w-6 h-6 object-contain shrink-0" />
            ))}
            {p.iconos.length > MAX_ICONS && (
              <span className="text-xs text-slate-400">+{p.iconos.length - MAX_ICONS}</span>
            )}
            {p.iconos.length === 0 && <span className="text-xs text-slate-300">—</span>}
          </div>
        </td>
        <td className="px-3 py-2.5 text-right tabular-nums whitespace-nowrap">
          {p.total_bultos != null ? fmtBultos(p.total_bultos) : "—"}
        </td>
        <td className="px-3 py-2.5 text-right font-semibold tabular-nums whitespace-nowrap">
          {p.total != null ? fmtMoneda(p.total) : "—"}
        </td>
        <td className="px-3 py-2.5 whitespace-nowrap">{p.credito ? "Crédito" : "Contado"}</td>
        <td className="px-3 py-2.5 whitespace-nowrap">
          <EstadoChip estado={p.estado} />
          {/* Hay video del pallet: el vendedor lo ve acá mismo cuando le
              reclaman, sin pedírselo a nadie. */}
          {p.videos > 0 && (
            <span className="ml-1.5 inline-flex items-center gap-1 rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-bold text-emerald-800 align-middle">
              <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 10.5l4.72-4.72a.75.75 0 011.28.53v11.38a.75.75 0 01-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 002.25-2.25v-9a2.25 2.25 0 00-2.25-2.25h-9A2.25 2.25 0 002.25 7.5v9a2.25 2.25 0 002.25 2.25z" />
              </svg>
              VIDEO
            </span>
          )}
        </td>
        <td className="px-3 py-2.5 text-right">
          <svg
            className={`w-4 h-4 inline text-slate-400 transition-transform ${abierto ? "rotate-180" : ""}`}
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2}
          >
            <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
          </svg>
        </td>
      </tr>
      {abierto && (
        <tr className="border-b border-pepe-border bg-slate-50/60">
          <td colSpan={8} className="px-4 py-3">
            {!detail ? (
              <span className="inline-block text-sm text-slate-400 sticky left-0 max-w-[calc(100vw_-_4rem)] sm:static sm:max-w-none">Cargando líneas…</span>
            ) : (
              /* En celu, sticky horizontal dentro de .tabla-scroll: el detalle queda visible sin scrollear */
              <div className="space-y-2 sticky left-0 max-w-[calc(100vw_-_4rem)] sm:static sm:max-w-none">
                <div className="flex items-center gap-3 text-xs text-slate-500">
                  <span>
                    Pedido <span className="font-semibold text-slate-700">#{p.nro_doc || p.nro_fact}</span>
                    {p.hora ? ` · ${p.hora}` : ""}
                  </span>
                  <BotonNoConformidad p={p} />
                </div>
                <ul className="space-y-1.5">
                  {detail.lineas.map((l) => (
                    <li key={l.id} className="flex items-center gap-2 text-sm">
                      {l.icono ? (
                        <img src={`/categorias/${l.icono}.svg`} alt="" className="w-5 h-5 object-contain shrink-0" />
                      ) : (
                        <span className="w-5 h-5 shrink-0" aria-hidden />
                      )}
                      <LineaDescripcion descripcion={l.descripcion} />
                      <span className="font-medium whitespace-nowrap tabular-nums">
                        {fmtBultos(l.cantidad)} × {fmtMoneda(l.precio)}
                      </span>
                    </li>
                  ))}
                </ul>
                {detail.observaciones && (
                  <p className="text-xs text-slate-500">
                    <strong>Obs.:</strong> {detail.observaciones}
                  </p>
                )}
                <VideosDelPedido nroFact={p.nro_fact} />
                <EntregaElevadoristaDePedido nroFact={p.nro_fact} />
              </div>
            )}
          </td>
        </tr>
      )}
    </>
  );
}

// Cargar una NO CONFORMIDAD asociada a este pedido: lleva a la pantalla de
// No conformidades con el cliente Y el pedido ya elegidos (query params).
function BotonNoConformidad({ p }: { p: PedidoVentaListItem }) {
  const navigate = useNavigate();
  if (p.cliente_cod == null) return null;
  return (
    <button
      onClick={(e) => {
        e.stopPropagation();
        navigate(
          `/reclamos?cliente=${p.cliente_cod}&nombre=${encodeURIComponent(p.cliente_nombre)}` +
            `&pedido=${p.nro_fact}&pedido_doc=${encodeURIComponent(p.nro_doc || String(p.nro_fact))}&tipo=no_conformidad`,
        );
      }}
      className="inline-flex items-center gap-1 px-3 py-2 sm:px-2 sm:py-1 rounded border border-fuchsia-300 text-fuchsia-700 text-xs font-semibold hover:bg-fuchsia-50"
      title="Cargar una no conformidad asociada a este pedido"
    >
      <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
      </svg>
      No conformidad
    </button>
  );
}


/** Nombre del producto con el ORIGEN adelante como etiqueta.
 *
 *  En el celular la descripción se trunca y quedaba «Banana P…» / «Banana Ec…»
 *  — imposible saber qué banana es, que es justo lo que hay que saber (dueño
 *  3/09). El origen va PRIMERO porque el truncado corta por el final: dejarlo
 *  donde estaba, aunque abreviado, se seguía perdiendo. */
function LineaDescripcion({ descripcion }: { descripcion: string }) {
  const { origen, resto } = partirOrigen(descripcion);
  return (
    <span className="flex-1 min-w-0 flex items-center gap-1.5">
      {origen && (
        <span className="shrink-0 rounded bg-slate-200 px-1 text-[10px] font-bold leading-4 tracking-wide text-slate-700">
          {origen}
        </span>
      )}
      <span className="truncate">{resto}</span>
    </span>
  );
}
