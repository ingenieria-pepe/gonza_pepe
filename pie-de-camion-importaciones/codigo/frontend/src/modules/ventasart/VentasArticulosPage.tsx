import { useEffect, useMemo, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  buscarArticulos, buscarClientes, descargarExcelVentas, descargarPdfVentas, verInformeVentas,
  type ArticuloBusqueda, type ClienteBusqueda, type FilaDetalleVenta,
} from "./api";

const fmt = (n: number, dec = 2) =>
  n.toLocaleString("es-UY", { minimumFractionDigits: dec, maximumFractionDigits: dec });

const fmtDia = (iso: string) => iso.split("-").reverse().join("/");

function hoyISO(): string {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}

function primeroDelMesISO(): string {
  return hoyISO().slice(0, 8) + "01";
}

function IconoDescarga() {
  return (
    <svg className="h-4 w-4 shrink-0" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
      <path d="M10.75 2.75a.75.75 0 0 0-1.5 0v8.19L6.28 7.97a.75.75 0 0 0-1.06 1.06l4.25 4.25a.75.75 0 0 0 1.06 0l4.25-4.25a.75.75 0 1 0-1.06-1.06l-2.97 2.97V2.75Z" />
      <path d="M3.5 12.75a.75.75 0 0 0-1.5 0v2.5A2.75 2.75 0 0 0 4.75 18h10.5A2.75 2.75 0 0 0 18 15.25v-2.5a.75.75 0 0 0-1.5 0v2.5c0 .69-.56 1.25-1.25 1.25H4.75c-.69 0-1.25-.56-1.25-1.25v-2.5Z" />
    </svg>
  );
}

/** Filtro por cliente del INFORME (cambia la consulta, no la tabla): dropdown
 *  con búsqueda por nombre, RUT o código. Sin cliente = todas las ventas.
 *  Distinto del buscador con lupa de abajo, que solo filtra lo ya cargado. */
function FiltroCliente({
  cliente, onElegir,
}: {
  cliente: ClienteBusqueda | null;
  onElegir: (c: ClienteBusqueda | null) => void;
}) {
  const [texto, setTexto] = useState("");
  const [abierto, setAbierto] = useState(false);
  const caja = useRef<HTMLDivElement>(null);

  const { data: opciones } = useQuery({
    queryKey: ["va-clientes", texto],
    queryFn: () => buscarClientes(texto),
    enabled: texto.trim().length >= 2,
  });

  useEffect(() => {
    const fuera = (e: MouseEvent) => {
      if (caja.current && !caja.current.contains(e.target as Node)) setAbierto(false);
    };
    document.addEventListener("mousedown", fuera);
    return () => document.removeEventListener("mousedown", fuera);
  }, []);

  if (cliente) {
    return (
      <span className="inline-flex items-center gap-2 rounded-lg border border-pepe-blue bg-blue-50 px-3 py-2 text-sm">
        <span className="font-medium text-pepe-blue-dark">{cliente.nombre}</span>
        <span className="text-xs text-slate-500 tabular-nums">{cliente.cod}</span>
        <button
          type="button"
          onClick={() => onElegir(null)}
          className="ml-1 font-bold text-slate-400 hover:text-rose-600"
          title="Sacar el filtro de cliente"
        >
          ×
        </button>
      </span>
    );
  }

  return (
    <div ref={caja} className="relative">
      <input
        type="text"
        value={texto}
        onChange={(e) => { setTexto(e.target.value); setAbierto(true); }}
        onFocus={() => setAbierto(true)}
        placeholder="Todos"
        className="w-56 rounded-lg border border-pepe-border py-2 pl-3 pr-8 text-sm"
      />
      {/* Chevron: que se lea como un desplegable de filtro, no como buscador. */}
      <svg
        className="pointer-events-none absolute right-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400"
        viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"
      >
        <path fillRule="evenodd" d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z" clipRule="evenodd" />
      </svg>
      {abierto && (opciones?.length ?? 0) > 0 && (
        <ul className="absolute z-20 mt-1 max-h-72 w-80 overflow-auto rounded-lg border border-pepe-border bg-white shadow-lg">
          {opciones!.map((c) => (
            <li key={c.cod}>
              <button
                type="button"
                onClick={() => { onElegir(c); setTexto(""); setAbierto(false); }}
                className="flex w-full items-baseline justify-between gap-3 px-3 py-2 text-left text-sm hover:bg-slate-50"
              >
                <span className="min-w-0 truncate">{c.nombre}</span>
                <span className="shrink-0 text-xs text-slate-400 tabular-nums">
                  {c.cod}{c.ruc ? ` · ${c.ruc}` : ""}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/** Filtro por ARTÍCULO del informe (pedido de la contadora 26/08): mismo
 *  desplegable con búsqueda que el de cliente, por código o descripción. */
function FiltroArticulo({
  articulo, onElegir,
}: {
  articulo: ArticuloBusqueda | null;
  onElegir: (a: ArticuloBusqueda | null) => void;
}) {
  const [texto, setTexto] = useState("");
  const [abierto, setAbierto] = useState(false);
  const caja = useRef<HTMLDivElement>(null);

  const { data: opciones } = useQuery({
    queryKey: ["va-articulos", texto],
    queryFn: () => buscarArticulos(texto),
    enabled: texto.trim().length >= 2,
  });

  useEffect(() => {
    const fuera = (e: MouseEvent) => {
      if (caja.current && !caja.current.contains(e.target as Node)) setAbierto(false);
    };
    document.addEventListener("mousedown", fuera);
    return () => document.removeEventListener("mousedown", fuera);
  }, []);

  if (articulo) {
    return (
      <span className="inline-flex items-center gap-2 rounded-lg border border-pepe-blue bg-blue-50 px-3 py-2 text-sm">
        <span className="font-medium text-pepe-blue-dark">{articulo.descripcion || articulo.cod}</span>
        <span className="text-xs text-slate-500 tabular-nums">{articulo.cod}</span>
        <button
          type="button"
          onClick={() => onElegir(null)}
          className="ml-1 font-bold text-slate-400 hover:text-rose-600"
          title="Sacar el filtro de artículo"
        >
          ×
        </button>
      </span>
    );
  }

  return (
    <div ref={caja} className="relative">
      <input
        type="text"
        value={texto}
        onChange={(e) => { setTexto(e.target.value); setAbierto(true); }}
        onFocus={() => setAbierto(true)}
        placeholder="Todos"
        className="w-56 rounded-lg border border-pepe-border py-2 pl-3 pr-8 text-sm"
      />
      <svg
        className="pointer-events-none absolute right-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400"
        viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"
      >
        <path fillRule="evenodd" d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z" clipRule="evenodd" />
      </svg>
      {abierto && (opciones?.length ?? 0) > 0 && (
        <ul className="absolute z-20 mt-1 max-h-72 w-80 overflow-auto rounded-lg border border-pepe-border bg-white shadow-lg">
          {opciones!.map((a) => (
            <li key={a.cod}>
              <button
                type="button"
                onClick={() => { onElegir(a); setTexto(""); setAbierto(false); }}
                className="flex w-full items-baseline justify-between gap-3 px-3 py-2 text-left text-sm hover:bg-slate-50"
              >
                <span className="min-w-0 truncate">{a.descripcion || a.cod}</span>
                <span className="shrink-0 text-xs text-slate-400 tabular-nums">{a.cod}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function VentasArticulosPage() {
  const [desde, setDesde] = useState(primeroDelMesISO());
  const [hasta, setHasta] = useState(hoyISO());
  const [cliente, setCliente] = useState<ClienteBusqueda | null>(null);
  const [articulo, setArticulo] = useState<ArticuloBusqueda | null>(null);
  const [pendientes, setPendientes] = useState(false);
  const [busca, setBusca] = useState("");
  // Qué export se está generando (deshabilita ambos botones mientras tanto).
  const [bajando, setBajando] = useState<null | "excel" | "pdf">(null);
  const [error, setError] = useState<string | null>(null);

  const filtros = { cliente, articulo, pendientes };
  const rangoOk = Boolean(desde && hasta && desde <= hasta);
  const { data, isLoading, error: errQuery } = useQuery({
    queryKey: ["informe-ventas", desde, hasta, cliente?.cod ?? null, articulo?.cod ?? null, pendientes],
    queryFn: () => verInformeVentas(desde, hasta, filtros),
    enabled: rangoOk,
  });

  // La vista la decide el BACK por permisos: "cajero" llega sin las columnas
  // de IVA y exporta solo PDF. Acá solo se dibuja lo que vino.
  const completa = data?.vista === "completa";

  const filas = useMemo(() => {
    const f = data?.filas ?? [];
    const q = busca.trim().toLowerCase();
    if (!q) return f;
    return f.filter(
      (x) =>
        x.descripcion.toLowerCase().includes(q) ||
        x.codart.toLowerCase().includes(q) ||
        x.cliente.toLowerCase().includes(q) ||
        x.vendedor.toLowerCase().includes(q) ||
        x.comprobante.toLowerCase().includes(q) ||
        String(x.nro_doc ?? "").includes(q),
    );
  }, [data, busca]);

  const t = data?.totales;

  /** CAJA: las N/C colgadas de su factura (pedido de Lucas 02/09). Cada línea
   *  de N/C trae ref_doc/ref_nrofact (la factura que anula); si esa factura
   *  está en la tabla, la N/C sale como sub-fila chica debajo de su última
   *  línea. Si la factura no está (otro rango, o quedó fuera del truncado),
   *  la N/C se queda como fila normal en su lugar cronológico. */
  const filasCajero = useMemo(() => {
    const clave = (d: string | null | undefined, n: number | null | undefined) => `${d}|${n}`;
    // Última línea de cada comprobante (vienen contiguas: el back ordena por
    // fecha + NroFact).
    const ultimaDe = new Map<string, number>();
    filas.forEach((f, i) => ultimaDe.set(clave(f.doc_cod, f.nrofact), i));
    const colgadas = new Map<number, FilaDetalleVenta[]>();
    const colgada = new Set<FilaDetalleVenta>();
    for (const f of filas) {
      if (f.ref_doc && f.ref_nrofact != null) {
        const idx = ultimaDe.get(clave(f.ref_doc, f.ref_nrofact));
        if (idx !== undefined) {
          const arr = colgadas.get(idx) ?? [];
          arr.push(f);
          colgadas.set(idx, arr);
          colgada.add(f);
        }
      }
    }
    const out: { fila: FilaDetalleVenta; sub: boolean }[] = [];
    filas.forEach((f, i) => {
      if (!colgada.has(f)) out.push({ fila: f, sub: false });
      for (const nc of colgadas.get(i) ?? []) out.push({ fila: nc, sub: true });
    });
    return out;
  }, [filas]);

  // El TOTAL de la tabla del cajero suma LO QUE SE VE (pedido 02/09): con
  // búsqueda o truncado es la suma de las filas mostradas; el total del rango
  // entero sigue en la nota de abajo de la tabla.
  const totalTabla = useMemo(() => ({
    cantidad: filas.reduce((s, f) => s + f.cantidad, 0),
    importe: filas.reduce((s, f) => s + f.importe, 0),
  }), [filas]);

  return (
    // El <main> del Layout es overflow-hidden: cada página pone su scroll.
    <div className="pagina-scroll mx-auto max-w-[1600px] p-4 sm:p-6">
      <h1 className="text-2xl font-bold text-slate-900">Informe de Ventas</h1>
      <p className="mt-1 text-sm text-slate-500">
        El "Estadísticas por Artículo" de Macrosoft, detallado por comprobante y con
        impuestos, más el filtro por cliente y el precio por unidad de cada línea.
      </p>

      {/* ── Controles ── */}
      <div className="mt-4 flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-2 text-sm text-slate-600">
          Del
          <input
            type="date"
            value={desde}
            max={hoyISO()}
            onChange={(e) => setDesde(e.target.value)}
            className="rounded-lg border border-pepe-border px-3 py-2 text-sm"
          />
        </label>
        <label className="flex items-center gap-2 text-sm text-slate-600">
          al
          <input
            type="date"
            value={hasta}
            min={desde}
            max={hoyISO()}
            onChange={(e) => setHasta(e.target.value)}
            className="rounded-lg border border-pepe-border px-3 py-2 text-sm"
          />
        </label>

        <label className="flex items-center gap-2 text-sm text-slate-600">
          Cliente
          <FiltroCliente cliente={cliente} onElegir={setCliente} />
        </label>
        <label className="flex items-center gap-2 text-sm text-slate-600">
          Artículo
          <FiltroArticulo articulo={articulo} onElegir={setArticulo} />
        </label>
        {/* Pendiente = factura a crédito con saldo sin cancelar por recibos/N/C
            (lo resuelve el back contra las imputaciones). El contado nunca está
            pendiente: se paga siempre entero. */}
        <label className="flex cursor-pointer items-center gap-1.5 text-sm text-slate-600">
          <input
            type="checkbox"
            checked={pendientes}
            onChange={(e) => setPendientes(e.target.checked)}
            className="h-3.5 w-3.5 accent-pepe-blue"
          />
          Solo pendientes de cobro
        </label>

        {/* Exports por vista (pedido 02/09): la completa (contadora/admin) tiene
            Excel (todas las columnas) Y PDF (formato de impresión, sin desglose
            de IVA); caja solo PDF — el gate real está en el back (/excel exige
            vista completa). */}
        {data && (
          <div className="ml-auto flex gap-2">
            {completa && (
              <button
                type="button"
                onClick={() => {
                  setBajando("excel");
                  descargarExcelVentas(desde, hasta, filtros)
                    .catch((e) => setError(String(e)))
                    .finally(() => setBajando(null));
                }}
                disabled={bajando !== null}
                title="Baja el detallado completo del rango, con todas las columnas"
                className="flex items-center gap-2 rounded-lg bg-pepe-blue px-3 py-2 text-sm font-medium text-white hover:bg-pepe-blue-dark disabled:opacity-50"
              >
                <IconoDescarga />
                {bajando === "excel" ? "Generando…" : "Excel"}
              </button>
            )}
            <button
              type="button"
              onClick={() => {
                setBajando("pdf");
                descargarPdfVentas(desde, hasta, filtros)
                  .catch((e) => setError(String(e)))
                  .finally(() => setBajando(null));
              }}
              disabled={bajando !== null}
              title="Baja el detallado del rango en PDF (formato de impresión, sin desglose de IVA)"
              className={completa
                ? "flex items-center gap-2 rounded-lg border border-pepe-border bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                : "flex items-center gap-2 rounded-lg bg-pepe-blue px-3 py-2 text-sm font-medium text-white hover:bg-pepe-blue-dark disabled:opacity-50"}
            >
              <IconoDescarga />
              {bajando === "pdf" ? "Generando…" : "PDF"}
            </button>
          </div>
        )}
      </div>

      {(data?.otras_monedas_n ?? 0) > 0 && (
        <p className="mt-2 rounded border border-amber-200 bg-amber-50 px-3 py-1.5 text-xs text-amber-900">
          El rango tiene {data!.otras_monedas_n} comprobante(s) de venta en otra moneda que
          NO están sumados (el informe es solo pesos).
        </p>
      )}

      {error && (
        <div className="mt-3 rounded border border-red-300 bg-red-100 px-3 py-2 text-sm text-red-900">
          {error}
        </div>
      )}

      {isLoading && (
        <p className="mt-6 text-sm text-slate-500">
          Consultando las ventas del período contra Macrosoft… (los rangos largos tardan)
        </p>
      )}
      {errQuery && (
        <div className="mt-6 rounded border border-red-300 bg-red-100 px-3 py-2 text-sm text-red-900">
          {/504|timeout|time-out/i.test((errQuery as Error).message)
            ? "El informe tardó demasiado y se cortó. Probá un rango más corto, o filtrá por cliente o artículo."
            : (errQuery as Error).message}
        </div>
      )}

      {data && (
        <>
          <div className="mt-4 flex flex-wrap items-center gap-3">
            {/* Lupa = busca EN LA TABLA cargada; el filtro de cliente de arriba
                es el que cambia el informe. */}
            <div className="relative w-full sm:w-72">
              <svg
                className="pointer-events-none absolute left-2.5 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400"
                viewBox="0 0 20 20" fill="currentColor" aria-hidden="true"
              >
                <path fillRule="evenodd" d="M9 3.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 0 0 0-11ZM2 9a7 7 0 1 1 12.452 4.391l3.328 3.329a.75.75 0 1 1-1.06 1.06l-3.329-3.328A7 7 0 0 1 2 9Z" clipRule="evenodd" />
              </svg>
              <input
                type="text"
                value={busca}
                onChange={(e) => setBusca(e.target.value)}
                placeholder="Buscar en la tabla (artículo, cliente…)"
                className="w-full rounded-lg border border-pepe-border py-2 pl-8 pr-3 text-sm"
              />
            </div>
            <span className="text-xs text-slate-500">
              {filas.length} de {data.filas.length} líneas · importes con impuestos
            </span>
          </div>

          {data.truncado && (
            <p className="mt-2 rounded border border-amber-200 bg-amber-50 px-3 py-1.5 text-xs text-amber-900">
              Se muestran las primeras {data.filas.length} líneas de {t!.lineas} — el Excel
              baja el detallado completo.
            </p>
          )}

          <div className="tabla-scroll mt-3 rounded-xl border border-pepe-border bg-white">
            <table className={`w-full text-sm ${completa ? "min-w-[1560px]" : "min-w-[1020px]"}`}>
              <thead className="border-b border-pepe-border bg-slate-50 text-xs uppercase text-slate-500">
                {/* Dos plantillas separadas: la vista completa (contadora) y la de
                    caja divergen en columnas Y en orden — condicionales por celda
                    acá serían ilegibles. Caja (pedido 19/08): Fecha, Código,
                    Cliente, Cantidad, Precio/u, CFE, Importe. El Importe va ÚLTIMO,
                    resaltado y CONGELADO al borde derecho (sticky); el separador va
                    por box-shadow y no por border — con border-collapse Chrome se
                    come el borde de las celdas sticky (lección de Deudores). */}
                {completa ? (
                  <tr>
                    <th className="px-3 py-2 text-left font-medium">Fecha</th>
                    <th className="px-3 py-2 text-left font-medium">Comprobante</th>
                    <th className="px-3 py-2 text-left font-medium">Código</th>
                    <th className="px-3 py-2 text-left font-medium">Artículo</th>
                    <th className="px-3 py-2 text-left font-medium">Dep.</th>
                    <th className="px-3 py-2 text-right font-medium">Cantidad</th>
                    <th className="px-3 py-2 text-right font-medium">Precio lista</th>
                    <th className="px-3 py-2 text-right font-medium">Sin IVA</th>
                    <th className="px-3 py-2 text-right font-medium">IVA</th>
                    <th className="px-3 py-2 text-right font-medium">Importe</th>
                    <th className="px-3 py-2 text-right font-medium">Precio/u</th>
                    <th className="px-3 py-2 text-left font-medium">Cliente</th>
                    <th className="px-3 py-2 text-left font-medium">RUT</th>
                    <th className="px-3 py-2 text-left font-medium">Vendedor</th>
                    <th className="px-3 py-2 text-left font-medium">CFE</th>
                  </tr>
                ) : (
                  <tr>
                    <th className="px-3 py-2 text-left font-medium">Fecha</th>
                    <th className="px-3 py-2 text-left font-medium">Código</th>
                    <th className="px-3 py-2 text-left font-medium">Cliente</th>
                    <th className="px-3 py-2 text-left font-medium">CFE</th>
                    <th className="px-3 py-2 text-left font-medium">Artículo</th>
                    <th className="px-3 py-2 text-right font-medium">Cantidad</th>
                    <th className="px-3 py-2 text-right font-medium">Precio/u</th>
                    <th className="sticky right-0 z-10 bg-amber-200 px-3 py-2 text-right font-semibold text-amber-950 shadow-[-1px_0_0_0_#FCD34D]">
                      Importe
                    </th>
                  </tr>
                )}
              </thead>
              <tbody className="divide-y divide-slate-100">
                {completa && filas.map((f, i) => (
                    <tr key={i} className="hover:bg-slate-50">
                      <td className="whitespace-nowrap px-3 py-1.5 tabular-nums text-slate-600">
                        {fmtDia(f.fecha)}
                      </td>
                      <td className="whitespace-nowrap px-3 py-1.5">
                        {f.comprobante}
                        <span className="ml-1 text-xs text-slate-400 tabular-nums">{f.nro_doc ?? ""}</span>
                      </td>
                      <td className="px-3 py-1.5 tabular-nums text-slate-500">{f.codart}</td>
                      <td className="px-3 py-1.5">{f.descripcion}</td>
                      <td className="px-3 py-1.5 text-slate-500">{f.deposito}</td>
                      <td className={`px-3 py-1.5 text-right tabular-nums ${f.cantidad < 0 ? "text-rose-600" : ""}`}>
                        {fmt(f.cantidad, 0)}
                      </td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-slate-600">
                        {fmt(f.precio_lista ?? 0)}
                      </td>
                      <td className={`px-3 py-1.5 text-right tabular-nums text-slate-600 ${(f.importe_sin_iva ?? 0) < 0 ? "text-rose-600" : ""}`}>
                        {fmt(f.importe_sin_iva ?? 0)}
                      </td>
                      <td className={`px-3 py-1.5 text-right tabular-nums text-slate-600 ${(f.iva ?? 0) < 0 ? "text-rose-600" : ""}`}>
                        {fmt(f.iva ?? 0)}
                      </td>
                      <td className={`px-3 py-1.5 text-right font-medium tabular-nums ${f.importe < 0 ? "text-rose-600" : ""}`}>
                        {fmt(f.importe)}
                      </td>
                      <td className="px-3 py-1.5 text-right font-medium tabular-nums">
                        {f.precio_unitario === null ? "" : fmt(f.precio_unitario)}
                      </td>
                      <td className="max-w-[200px] px-3 py-1.5">
                        <span className="block truncate" title={f.cliente}>{f.cliente}</span>
                        <span className="text-xs text-slate-400 tabular-nums">{f.cod_cliente ?? ""}</span>
                      </td>
                      <td className="whitespace-nowrap px-3 py-1.5 tabular-nums text-slate-500">{f.ruc}</td>
                      <td className="whitespace-nowrap px-3 py-1.5">{f.vendedor}</td>
                      <td className="whitespace-nowrap px-3 py-1.5 text-slate-600">
                        {f.tipo_cfe}
                        {f.efact_nro != null && (
                          <span className="ml-1 text-xs text-slate-400 tabular-nums">
                            {f.efact_serie} {f.efact_nro}
                          </span>
                        )}
                      </td>
                    </tr>
                ))}
                {/* Caja: menos columnas, las que se usan en el mostrador. Las
                    N/C con referencia salen como SUB-FILA chica y rosada debajo
                    de la factura que anulan, con todos sus datos. El código de
                    artículo lleva el nombre como title (hover). */}
                {!completa && filasCajero.map(({ fila: f, sub }, i) => (
                    <tr key={i} className={sub ? "bg-rose-50/40 text-xs hover:bg-rose-50/70" : "hover:bg-slate-50"}>
                      <td className={`whitespace-nowrap px-3 tabular-nums text-slate-600 ${sub ? "py-1 pl-5" : "py-1.5"}`}>
                        {sub && (
                          <span className="mr-1.5 rounded bg-rose-100 px-1 py-0.5 text-[10px] font-semibold text-rose-700 ring-1 ring-inset ring-rose-200">
                            N/C
                          </span>
                        )}
                        {fmtDia(f.fecha)}
                      </td>
                      <td className={`px-3 tabular-nums text-slate-500 ${sub ? "py-1" : "py-1.5"}`} title={f.descripcion}>
                        {f.codart}
                      </td>
                      <td className={`max-w-[240px] px-3 ${sub ? "py-1" : "py-1.5"}`}>
                        <span className="block truncate" title={f.cliente}>{f.cliente}</span>
                        {!sub && (
                          <span className="text-xs text-slate-400 tabular-nums">{f.cod_cliente ?? ""}</span>
                        )}
                      </td>
                      <td className={`whitespace-nowrap px-3 text-slate-600 ${sub ? "py-1" : "py-1.5"}`}>
                        {f.tipo_cfe}
                        {f.efact_nro != null && (
                          <span className="ml-1 text-xs text-slate-400 tabular-nums">
                            {f.efact_serie} {f.efact_nro}
                          </span>
                        )}
                      </td>
                      <td className={`max-w-[220px] truncate px-3 ${sub ? "py-1" : "py-1.5"}`} title={f.descripcion}>
                        {f.descripcion}
                      </td>
                      <td className={`px-3 text-right tabular-nums ${sub ? "py-1" : "py-1.5"} ${f.cantidad < 0 ? "text-rose-600" : ""}`}>
                        {fmt(f.cantidad, 0)}
                      </td>
                      <td className={`px-3 text-right font-medium tabular-nums ${sub ? "py-1" : "py-1.5"}`}>
                        {f.precio_unitario === null ? "" : fmt(f.precio_unitario)}
                      </td>
                      <td className={`sticky right-0 z-10 whitespace-nowrap bg-amber-100 px-3 text-right font-semibold tabular-nums shadow-[-1px_0_0_0_#FCD34D] ${
                        sub ? "py-1" : "py-1.5"
                      } ${f.importe < 0 ? "text-rose-600" : "text-slate-900"}`}>
                        {fmt(f.importe)}
                      </td>
                    </tr>
                ))}
              </tbody>
              {(completa ? Boolean(t && !data.truncado && !busca) : filas.length > 0) && (
                <tfoot className="border-t-2 border-slate-300 bg-slate-50 font-semibold">
                  {completa && t ? (
                    <tr>
                      <td className="px-3 py-2" colSpan={5}>TOTAL</td>
                      <td className="px-3 py-2 text-right tabular-nums">{fmt(t.cantidad, 0)}</td>
                      <td />
                      <td className="px-3 py-2 text-right tabular-nums">{fmt(t.importe_sin_iva ?? 0)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{fmt(t.iva ?? 0)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{fmt(t.importe)}</td>
                      <td colSpan={5} />
                    </tr>
                  ) : (
                    // Caja: el TOTAL suma SIEMPRE lo que hay en la tabla (pedido
                    // 02/09) — con búsqueda o truncado es la suma de lo mostrado,
                    // y se aclara; el total del rango entero está en la nota de
                    // abajo.
                    <tr>
                      <td className="px-3 py-2" colSpan={5}>
                        TOTAL{data.truncado || busca ? " (de lo mostrado)" : ""}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">{fmt(totalTabla.cantidad, 0)}</td>
                      <td />
                      <td className="sticky right-0 z-10 whitespace-nowrap bg-amber-200 px-3 py-2 text-right tabular-nums text-amber-950 shadow-[-1px_0_0_0_#FCD34D]">
                        {fmt(totalTabla.importe)}
                      </td>
                    </tr>
                  )}
                </tfoot>
              )}
            </table>
          </div>

          {data.truncado && t && (
            <p className="mt-2 text-right text-xs text-slate-500">
              Total del rango completo: {fmt(t.cantidad, 0)} unidades · $ {fmt(t.importe)} con
              impuestos{completa ? ` (${fmt(t.importe_sin_iva ?? 0)} + IVA ${fmt(t.iva ?? 0)})` : ""}
            </p>
          )}
        </>
      )}
    </div>
  );
}
