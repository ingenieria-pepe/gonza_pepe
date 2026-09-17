import { useEffect, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  cancelPlanCarga,
  createPlanCarga,
  deletePlanCarga,
  exportPlanCargasExcel,
  getFacturaDatos,
  getFacturas,
  getSyncEstado,
  listPlanCargas,
  STATUS_VALUES,
  syncPlanCargas,
  updatePlanCarga,
  type FuenteCarga,
  type PlanCarga,
  type PlanCargaCreate,
  type StatusCarga,
} from "../../shared/api/planCargas";
import { ArticuloPickerModal } from "../../shared/components/stock/ArticuloPickerModal";
import { listCategorias } from "../../shared/api/stock";
import { listCatalogo } from "../../shared/api/catalogos";

/**
 * Plan de cargas — vista tabla con filtros y modal de edición.
 * Reemplaza el Excel del OneDrive donde se trackea cada camión BR/PY.
 */
// Columnas filtrables estilo Excel. `accessor` devuelve el valor crudo para
// filtrar/ordenar ("" = vacía); `display` lo formatea para el popover.
type ColDef = {
  key: string;
  label: string;
  accessor: (c: PlanCarga) => string;
  display?: (v: string) => string;
  numeric?: boolean;
  align?: "right";
};

const FILTER_COLS: ColDef[] = [
  { key: "status", label: "Status", accessor: (c) => c.status },
  { key: "productor", label: "Productor", accessor: (c) => c.productor ?? "" },
  { key: "carpeta", label: "Carpeta", accessor: (c) => c.carpeta_import ?? "" },
  { key: "factura", label: "Factura", accessor: (c) => c.factura ?? "" },
  { key: "fecha_carga", label: "Carga", accessor: (c) => c.fecha_carga ?? "", display: fmtDate },
  { key: "fecha_frontera", label: "Frontera", accessor: (c) => c.fecha_frontera ?? "", display: fmtDate },
  { key: "fecha_descarga", label: "Descarga", accessor: (c) => c.fecha_descarga ?? "", display: fmtDate },
  { key: "cajas", label: "Cajas", accessor: (c) => String(c.cajas_mic ?? c.cajas_desc ?? ""), numeric: true, align: "right" },
  { key: "transportista", label: "Transportista", accessor: (c) => c.transportista ?? "" },
  { key: "placa", label: "Placa", accessor: (c) => c.placa_camion ?? "" },
];

// La planilla de OTROS países no tiene Productor: en su lugar mostramos el
// Producto (viene como texto en la col 'Productos' del Excel) y el País.
const FILTER_COLS_OTROS: ColDef[] = [
  { key: "status", label: "Status", accessor: (c) => c.status },
  { key: "producto", label: "Producto", accessor: (c) => c.productos?.[0]?.descripcion ?? "" },
  { key: "pais", label: "País", accessor: (c) => c.pais_origen ?? "" },
  { key: "carpeta", label: "Carpeta", accessor: (c) => c.carpeta_import ?? "" },
  { key: "factura", label: "Factura", accessor: (c) => c.factura ?? "" },
  { key: "fecha_carga", label: "Carga", accessor: (c) => c.fecha_carga ?? "", display: fmtDate },
  { key: "fecha_frontera", label: "Frontera", accessor: (c) => c.fecha_frontera ?? "", display: fmtDate },
  { key: "fecha_descarga", label: "Descarga", accessor: (c) => c.fecha_descarga ?? "", display: fmtDate },
  { key: "cajas", label: "Cajas", accessor: (c) => String(c.cajas_mic ?? c.cajas_desc ?? ""), numeric: true, align: "right" },
  { key: "transportista", label: "Transportista", accessor: (c) => c.transportista ?? "" },
  { key: "placa", label: "Placa", accessor: (c) => c.placa_camion ?? "" },
];

// "hace 12s" / "hace 3 min" / "hace 2 h" desde un ISO datetime.
function fmtHace(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  if (!Number.isFinite(ms) || ms < 0) return "recién";
  const s = Math.floor(ms / 1000);
  if (s < 60) return `hace ${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `hace ${m} min`;
  return `hace ${Math.floor(m / 60)} h`;
}

export function PlanCargasPage() {
  // Tab de planilla: BR (Brasil/PY, la histórica) | OTROS (demás países).
  const [fuente, setFuente] = useState<FuenteCarga>("BR");
  const COLS = fuente === "OTROS" ? FILTER_COLS_OTROS : FILTER_COLS;
  const [search, setSearch] = useState("");
  const [onlyPendientes, setOnlyPendientes] = useState(true);
  const [editing, setEditing] = useState<PlanCarga | null>(null);
  const [creating, setCreating] = useState(false);
  // Filtros por columna: key → set de valores SELECCIONADOS (null = sin filtro)
  const [colFilters, setColFilters] = useState<Record<string, Set<string> | null>>({});
  const [sort, setSort] = useState<{ key: string; dir: "asc" | "desc" } | null>(null);

  const qc = useQueryClient();

  const { data: cargas = [], isLoading } = useQuery({
    queryKey: ["plan-cargas", { pendientes: onlyPendientes, fuente }],
    queryFn: () => listPlanCargas({ pendientes: onlyPendientes, fuente, limit: 1000 }),
    staleTime: 30_000,
  });

  // Al cambiar de planilla, los filtros/orden por columna dejan de tener sentido
  // (las columnas cambian) → se limpian.
  useEffect(() => {
    setColFilters({});
    setSort(null);
  }, [fuente]);

  // Puente OneDrive (read-only temporal): el SERVIDOR sincroniza solo cada 30s
  // (loop de fondo). Acá sólo LEEMOS el estado para el banner y para refrescar la
  // grilla cuando hubo cambios; el botón fuerza una bajada. Key propia para que
  // invalidar la grilla no toque este query.
  const { data: sync } = useQuery({
    queryKey: ["plan-cargas-sync"],
    queryFn: () => getSyncEstado(),
    refetchInterval: 30_000,
    refetchOnWindowFocus: false,
  });
  // Refrescar la grilla cuando CUALQUIERA de las dos planillas sincronizó con
  // cambios (el top-level del estado espeja solo BR — mirar `fuentes`).
  const syncMsgs = [sync?.mensaje, sync?.fuentes?.BR?.mensaje, sync?.fuentes?.OTROS?.mensaje]
    .filter(Boolean)
    .join("|");
  useEffect(() => {
    if (syncMsgs.includes("OK ·")) {
      qc.invalidateQueries({ queryKey: ["plan-cargas"] }); // refresca la grilla (no el sync)
    }
  }, [syncMsgs]); // eslint-disable-line react-hooks/exhaustive-deps
  const syncNow = useMutation({
    mutationFn: () => syncPlanCargas(true),
    onSuccess: (data) => {
      qc.setQueryData(["plan-cargas-sync"], data);
      qc.invalidateQueries({ queryKey: ["plan-cargas"] });
    },
  });
  const enPuente = !!sync?.activo; // hay ALGÚN puente → edición bloqueada
  // Estado de la planilla del tab activo (para el banner).
  const syncFuente = sync?.fuentes?.[fuente] ?? sync;

  // Valores disponibles por columna. Como en Excel: la lista de cada columna
  // respeta los filtros aplicados en las DEMÁS columnas.
  const valuesByCol = useMemo(() => {
    const out: Record<string, string[]> = {};
    for (const col of COLS) {
      const rows = cargas.filter((c) =>
        COLS.every((o) => {
          if (o.key === col.key) return true;
          const sel = colFilters[o.key];
          return !sel || sel.has(o.accessor(c));
        })
      );
      const uniq = Array.from(new Set(rows.map(col.accessor)));
      uniq.sort((a, b) => {
        if (a === "") return -1;
        if (b === "") return 1;
        return col.numeric ? Number(a) - Number(b) : a.localeCompare(b);
      });
      out[col.key] = uniq;
    }
    return out;
  }, [cargas, colFilters, COLS]);

  const activeFilterCount = Object.values(colFilters).filter(Boolean).length;

  // Filtros locales en memoria (los del server son sólo "pendientes")
  const filtered = useMemo(() => {
    const s = search.trim().toLowerCase();
    return cargas.filter((c) => {
      for (const col of COLS) {
        const sel = colFilters[col.key];
        if (sel && !sel.has(col.accessor(c))) return false;
      }
      if (!s) return true;
      return [
        c.productor, c.factura, c.carpeta_import, c.transportista,
        c.placa_camion, c.placa_remolque, c.chofer, c.codigo_viaje,
        c.productos?.[0]?.descripcion, c.pais_origen,
      ].some((v) => v?.toLowerCase().includes(s));
    });
  }, [cargas, search, colFilters, COLS]);

  // Orden por columna (click en el header). Las fechas son ISO → ordenan bien
  // como texto; las numéricas por número; el resto alfabético. Vacíos al final.
  const sorted = useMemo(() => {
    if (!sort) return filtered;
    const col = COLS.find((c) => c.key === sort.key);
    if (!col) return filtered;
    const dir = sort.dir === "asc" ? 1 : -1;
    return [...filtered].sort((a, b) => {
      const va = col.accessor(a), vb = col.accessor(b);
      if (va === vb) return 0;
      if (va === "") return 1;
      if (vb === "") return -1;
      if (col.numeric) return (Number(va) - Number(vb)) * dir;
      return va.localeCompare(vb, "es", { numeric: true }) * dir;
    });
  }, [filtered, sort, COLS]);

  return (
    <div className="h-full overflow-y-auto overscroll-y-contain p-4 sm:p-6">
      <div className="max-w-7xl mx-auto space-y-4">
        {/* Header */}
        <header className="flex items-center justify-between gap-3 flex-wrap">
          <div>
            <h1 className="text-2xl font-bold text-slate-900">Plan de cargas</h1>
            <p className="text-sm text-slate-500 mt-0.5">
              {fuente === "BR"
                ? "Camiones planificados de BR/PY. Reemplaza el Excel de OneDrive."
                : "Arribos de los demás países (EC, CL, BO, PE… y ultramar). Espeja su Excel de OneDrive."}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <ExportarExcelButton pendientes={onlyPendientes} fuente={fuente} />
            {!enPuente && (
              <button
                onClick={() => setCreating(true)}
                className="inline-flex items-center gap-2 px-4 py-2 rounded bg-pepe-blue text-white font-semibold hover:bg-pepe-blue-dark"
              >
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M12 4v16m8-8H4" />
                </svg>
                Nueva carga
              </button>
            )}
          </div>
        </header>

        {/* Tab de planilla: Brasil/PY | Otros países */}
        <div className="inline-flex rounded-lg border border-pepe-border overflow-hidden">
          {(
            [
              ["BR", "Brasil / PY"],
              ["OTROS", "Otros países"],
            ] as [FuenteCarga, string][]
          ).map(([f, label]) => (
            <button
              key={f}
              onClick={() => setFuente(f)}
              className={`px-4 py-2 text-sm font-semibold ${
                fuente === f ? "bg-pepe-blue text-white" : "bg-white text-slate-600 hover:bg-slate-50"
              }`}
            >
              {label}
            </button>
          ))}
        </div>

        {/* Puente OneDrive: banner de modo lectura + estado + sync manual */}
        {enPuente && (
          <div className={`rounded-md px-3 py-2.5 flex items-center gap-3 flex-wrap text-sm border ${
            syncFuente?.ok === false ? "bg-rose-50 border-rose-300" : "bg-violet-50 border-violet-300"
          }`}>
            <span className="inline-flex items-center gap-1.5 font-semibold text-violet-800">
              <svg className="w-4 h-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
                <path strokeLinecap="round" strokeLinejoin="round" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z" />
              </svg>
              Modo lectura — el maestro es el Excel de OneDrive
            </span>
            <span className={syncFuente?.ok === false ? "text-rose-700 font-medium" : "text-slate-600"}>
              {syncFuente?.activo === false
                ? "esta planilla no está conectada (falta la URL de sync en el servidor)"
                : <>
                    {syncFuente?.mensaje}
                    {syncFuente?.ultima_sync ? ` · sincronizado ${fmtHace(syncFuente.ultima_sync)}` : ""}
                  </>}
            </span>
            <button
              onClick={() => syncNow.mutate()}
              disabled={syncNow.isPending}
              className="ml-auto inline-flex items-center gap-1.5 px-3 py-1.5 rounded border border-violet-400 bg-white text-violet-700 font-medium hover:bg-violet-100 disabled:opacity-50"
            >
              <svg className={`w-4 h-4 ${syncNow.isPending ? "animate-spin" : ""}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M4 4v6h6M20 20v-6h-6M5.5 9a7.5 7.5 0 0113 -2M18.5 15a7.5 7.5 0 01-13 2" />
              </svg>
              {syncNow.isPending ? "Sincronizando…" : "Sincronizar ahora"}
            </button>
          </div>
        )}

        {/* Filtros */}
        <div className="bg-white border border-pepe-border rounded-md p-3 flex flex-wrap items-center gap-3">
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Buscar productor, factura, transportista, placa…"
            className="flex-1 min-w-[200px] px-3 py-2 border border-pepe-border rounded text-sm"
          />
          <label className="inline-flex items-center gap-2 text-sm text-slate-700 cursor-pointer">
            <input
              type="checkbox"
              checked={onlyPendientes}
              onChange={(e) => setOnlyPendientes(e.target.checked)}
              className="w-4 h-4"
            />
            Sólo pendientes
          </label>
          {activeFilterCount > 0 && (
            <button
              onClick={() => setColFilters({})}
              className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded border border-pepe-blue/40 bg-pepe-blue/5 text-pepe-blue text-sm font-medium hover:bg-pepe-blue/10"
            >
              <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
              Limpiar filtros ({activeFilterCount})
            </button>
          )}
        </div>

        {/* Tabla */}
        <div className="bg-white border border-pepe-border rounded-md overflow-hidden">
          <div className="tabla-scroll">
            <table className="w-full min-w-[1050px] text-sm">
              <thead className="bg-slate-50 border-b border-pepe-border text-xs uppercase tracking-wider text-slate-500">
                <tr>
                  {COLS.map((col) => (
                    <FilterHeader
                      key={col.key}
                      col={col}
                      values={valuesByCol[col.key] ?? []}
                      selected={colFilters[col.key] ?? null}
                      onChange={(sel) => setColFilters((p) => ({ ...p, [col.key]: sel }))}
                      sortDir={sort?.key === col.key ? sort.dir : null}
                      onSort={() =>
                        setSort((p) =>
                          p?.key === col.key
                            ? { key: col.key, dir: p.dir === "asc" ? "desc" : "asc" }
                            : { key: col.key, dir: "asc" },
                        )
                      }
                    />
                  ))}
                  <th className="px-3 py-2 w-10"></th>
                </tr>
              </thead>
              <tbody className="divide-y divide-pepe-border">
                {isLoading ? (
                  <tr><td colSpan={COLS.length + 1} className="px-4 py-6 text-center text-slate-400">Cargando…</td></tr>
                ) : sorted.length === 0 ? (
                  <tr><td colSpan={COLS.length + 1} className="px-4 py-6 text-center text-slate-400">Sin resultados</td></tr>
                ) : sorted.map((c) => (
                  <tr key={c.id} className={`hover:bg-slate-50 ${enPuente ? "" : "cursor-pointer"}`} onClick={enPuente ? undefined : () => setEditing(c)}>
                    <td className="px-3 py-2">
                      <StatusCell carga={c} readonly={enPuente} />
                    </td>
                    {fuente === "OTROS" ? (
                      <>
                        <td className="px-3 py-2 font-medium">{c.productos?.[0]?.descripcion ?? "—"}</td>
                        <td className="px-3 py-2 font-mono text-xs text-slate-600">{c.pais_origen ?? "—"}</td>
                      </>
                    ) : (
                      <td className="px-3 py-2 font-medium">{c.productor ?? "—"}</td>
                    )}
                    <td className="px-3 py-2 font-mono text-xs text-slate-600">{c.carpeta_import ?? "—"}</td>
                    <td className="px-3 py-2 text-slate-600">{c.factura ?? "—"}</td>
                    <td className="px-3 py-2 text-slate-600 whitespace-nowrap">{fmtDate(c.fecha_carga)}</td>
                    <td className="px-3 py-2 text-slate-600 whitespace-nowrap">{fmtDate(c.fecha_frontera)}</td>
                    <td className="px-3 py-2 text-slate-600 whitespace-nowrap">{fmtDate(c.fecha_descarga)}</td>
                    <td className="px-3 py-2 text-right font-mono">{c.cajas_mic ?? c.cajas_desc ?? "—"}</td>
                    <td className="px-3 py-2 text-slate-600">{c.transportista ?? "—"}</td>
                    <td className="px-3 py-2 text-slate-600 font-mono text-xs">{c.placa_camion ?? "—"}</td>
                    <td className="px-3 py-2 text-slate-400">›</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      {creating && (
        <CargaEditModal
          mode="create"
          fuente={fuente}
          onClose={() => setCreating(false)}
        />
      )}
      {editing && (
        <CargaEditModal
          mode="edit"
          carga={editing}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

// ─── Exportar a Excel ────────────────────────────────────────────────────

function ExportarExcelButton({ pendientes, fuente }: { pendientes: boolean; fuente: FuenteCarga }) {
  const [downloading, setDownloading] = useState(false);
  const [error, setError] = useState(false);

  async function handleClick() {
    setDownloading(true);
    setError(false);
    try {
      await exportPlanCargasExcel(pendientes, fuente);
    } catch {
      setError(true);
      setTimeout(() => setError(false), 4000);
    } finally {
      setDownloading(false);
    }
  }

  return (
    <button
      onClick={handleClick}
      disabled={downloading}
      className={`inline-flex items-center gap-2 px-4 py-2 rounded border text-sm font-semibold disabled:opacity-50 ${
        error
          ? "border-rose-300 bg-rose-50 text-rose-700"
          : "border-pepe-border bg-white text-slate-700 hover:bg-slate-50"
      }`}
      title="Descarga el plan completo como planilla de Excel"
    >
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" />
      </svg>
      {error ? "No se pudo exportar" : downloading ? "Exportando…" : "Exportar a Excel"}
    </button>
  );
}

// ─── Status clickeable: tocás el badge y elegís el nuevo estado ──────────

function StatusCell({ carga, readonly }: { carga: PlanCarga; readonly?: boolean }) {
  const qc = useQueryClient();
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);

  // OJO: todos los hooks ANTES del return condicional — `readonly` (= puente
  // activo) puede flipar en caliente y cambiar la cantidad de hooks rompería
  // el render ("Rendered fewer hooks...").
  const mut = useMutation({
    mutationFn: (status: StatusCarga) => updatePlanCarga(carga.id, { status }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["plan-cargas"] });
      qc.invalidateQueries({ queryKey: ["monitor-camiones"] });
      setPos(null);
    },
  });

  // Modo puente (lectura): el estado lo manda el Excel → badge fijo, sin dropdown.
  if (readonly) {
    return (
      <span
        className={`inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold ${statusClass(carga.status)}`}
        title="El estado lo define el Excel (modo lectura)"
      >
        {carga.status}
      </span>
    );
  }

  return (
    <>
      <button
        onClick={(e) => {
          e.stopPropagation();
          const r = e.currentTarget.getBoundingClientRect();
          setPos({ top: r.bottom + 4, left: Math.min(r.left, window.innerWidth - 200) });
        }}
        disabled={mut.isPending}
        className={`inline-flex items-center gap-1 px-2.5 sm:px-2 py-1.5 sm:py-0.5 rounded text-xs font-semibold ${statusClass(carga.status)} hover:ring-2 hover:ring-pepe-blue/30 disabled:opacity-50`}
        title="Cambiar estado"
      >
        {mut.isPending ? "Guardando…" : carga.status}
        <svg className="w-3 h-3 opacity-60" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M19.5 8.25l-7.5 7.5-7.5-7.5" />
        </svg>
      </button>

      {pos && (
        <>
          <div
            className="fixed inset-0 z-40"
            onClick={(e) => { e.stopPropagation(); setPos(null); }}
          />
          <div
            className="fixed z-50 bg-white border border-pepe-border rounded-md shadow-xl py-1 w-44 max-h-[55dvh] overflow-y-auto sm:max-h-none sm:overflow-visible"
            style={{ top: pos.top, left: pos.left }}
            onClick={(e) => e.stopPropagation()}
          >
            {STATUS_VALUES.map((s) => (
              <button
                key={s}
                onClick={() => mut.mutate(s)}
                disabled={s === carga.status}
                className="w-full flex items-center justify-between gap-2 px-3 py-2 text-left text-sm hover:bg-slate-50 disabled:bg-slate-100"
              >
                <span className={`inline-block px-2 py-0.5 rounded text-xs font-semibold ${statusClass(s)}`}>
                  {s}
                </span>
                {s === carga.status && (
                  <svg className="w-4 h-4 text-pepe-blue" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
                  </svg>
                )}
              </button>
            ))}
          </div>
        </>
      )}
    </>
  );
}

// ─── Header con filtro estilo Excel ──────────────────────────────────────

function FilterHeader({
  col,
  values,
  selected,
  onChange,
  sortDir,
  onSort,
}: {
  col: ColDef;
  values: string[];
  selected: Set<string> | null;
  onChange: (sel: Set<string> | null) => void;
  sortDir: "asc" | "desc" | null;
  onSort: () => void;
}) {
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);
  const active = selected !== null;
  const allChecked = !active || values.every((v) => selected!.has(v));

  function toggle(v: string) {
    const cur = new Set(selected ?? values);
    if (cur.has(v)) cur.delete(v);
    else cur.add(v);
    // Si quedó todo seleccionado, es como no tener filtro
    onChange(values.every((x) => cur.has(x)) ? null : cur);
  }

  function toggleAll() {
    onChange(allChecked ? new Set<string>() : null);
  }

  return (
    <th className={`px-3 py-1.5 ${col.align === "right" ? "text-right" : "text-left"}`}>
      <span className={`inline-flex items-center gap-1 ${col.align === "right" ? "flex-row-reverse" : ""}`}>
        <button
          onClick={onSort}
          className={`inline-flex items-center gap-1 uppercase tracking-wider font-semibold hover:text-pepe-blue ${sortDir ? "text-pepe-blue" : ""}`}
          title={`Ordenar por ${col.label}`}
        >
          {col.label}
          {sortDir && (
            <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={3}>
              <path strokeLinecap="round" strokeLinejoin="round" d={sortDir === "asc" ? "M5 15l7-7 7 7" : "M19 9l-7 7-7-7"} />
            </svg>
          )}
        </button>
        <button
          onClick={(e) => {
            const r = e.currentTarget.getBoundingClientRect();
            setPos({ top: r.bottom + 4, left: Math.min(r.left, window.innerWidth - 240) });
          }}
          className={`p-1.5 sm:p-0.5 rounded hover:text-pepe-blue ${active ? "text-pepe-blue" : "text-slate-400"}`}
          title={`Filtrar por ${col.label}`}
        >
          <svg className="w-3.5 h-3.5" fill={active ? "currentColor" : "none"} viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 3c2.755 0 5.455.232 8.083.678.533.09.917.556.917 1.096v1.044a2.25 2.25 0 01-.659 1.591l-5.432 5.432a2.25 2.25 0 00-.659 1.591v2.927a2.25 2.25 0 01-1.244 2.013L9.75 21v-6.568a2.25 2.25 0 00-.659-1.591L3.659 7.409A2.25 2.25 0 013 5.818V4.774c0-.54.384-1.006.917-1.096A48.32 48.32 0 0112 3z" />
          </svg>
        </button>
      </span>

      {pos && (
        <>
          <div className="fixed inset-0 z-40" onClick={() => setPos(null)} />
          <div
            className="fixed z-50 bg-white border border-pepe-border rounded-md shadow-xl w-56 max-h-[70dvh] sm:max-h-none flex flex-col normal-case tracking-normal text-left"
            style={{ top: pos.top, left: pos.left }}
          >
            <label className="flex items-center gap-2.5 px-3 py-2 border-b border-pepe-border text-sm font-semibold text-slate-700 cursor-pointer hover:bg-slate-50">
              <input type="checkbox" checked={allChecked} onChange={toggleAll} className="w-4 h-4" />
              Seleccionar todo
            </label>
            <div className="overflow-y-auto max-h-64 py-1">
              {values.map((v) => (
                <label key={v} className="flex items-center gap-2.5 px-3 py-1.5 text-sm text-slate-800 cursor-pointer hover:bg-slate-50">
                  <input
                    type="checkbox"
                    checked={!active || selected!.has(v)}
                    onChange={() => toggle(v)}
                    className="w-4 h-4 shrink-0"
                  />
                  <span className={`truncate ${v === "" ? "text-slate-500 italic" : ""}`}>
                    {v === "" ? "(Vacías)" : (col.display?.(v) ?? v)}
                  </span>
                </label>
              ))}
              {values.length === 0 && (
                <div className="px-3 py-2 text-sm text-slate-400">Sin valores</div>
              )}
            </div>
            <div className="flex items-center justify-between gap-2 px-3 py-2 border-t border-pepe-border">
              <button
                onClick={() => { onChange(null); setPos(null); }}
                className="text-sm text-slate-500 hover:text-slate-700"
              >
                Borrar filtro
              </button>
              <button
                onClick={() => setPos(null)}
                className="px-3 py-1 rounded bg-pepe-blue text-white text-sm font-semibold hover:bg-pepe-blue-dark"
              >
                Listo
              </button>
            </div>
          </div>
        </>
      )}
    </th>
  );
}

// ─── Modal de edición ────────────────────────────────────────────────────

function CargaEditModal({
  mode,
  carga,
  fuente = "BR",
  onClose,
}: {
  mode: "create" | "edit";
  carga?: PlanCarga;
  fuente?: FuenteCarga;  // planilla destino al CREAR (edit usa la de la carga)
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [form, setForm] = useState<Partial<PlanCargaCreate>>(() => {
    if (carga) {
      return {
        carga_semana: carga.carga_semana,
        status: carga.status,
        factura: carga.factura,
        productor: carga.productor,
        fecha_carga: carga.fecha_carga,
        carpeta_import: carga.carpeta_import,
        afidi: carga.afidi,
        transportista: carga.transportista,
        exportador: carga.exportador,
        placa_camion: carga.placa_camion,
        placa_remolque: carga.placa_remolque,
        chofer: carga.chofer,
        celular: carga.celular,
        fecha_frontera: carga.fecha_frontera,
        frontera: carga.frontera,
        inspector_mgap: carga.inspector_mgap,
        fecha_descarga: carga.fecha_descarga,
        tt: carga.tt,
        cajas_mic: carga.cajas_mic,
        cajas_desc: carga.cajas_desc,
        cant_pallet: carga.cant_pallet,
        cant_kilos_caja: carga.cant_kilos_caja,
        codigo_viaje: carga.codigo_viaje,
        mic: carga.mic,
        observaciones: carga.observaciones,
        productos: carga.productos,
        pais_origen: carga.pais_origen,
      };
    }
    return { status: "Solicitado" };
  });
  const [pickProd, setPickProd] = useState(false);
  const [confirmDel, setConfirmDel] = useState(false);
  // Para mapear el artículo elegido → ícono SVG de su categoría (display).
  const { data: cats = [] } = useQuery({ queryKey: ["lookups", "categorias"], queryFn: () => listCategorias(), staleTime: 5 * 60_000 });
  // Catálogos para los desplegables (chofer/productor/transportista/frontera).
  const { data: choferes = [] } = useQuery({ queryKey: ["catalogo", "choferes"], queryFn: () => listCatalogo("choferes"), staleTime: 5 * 60_000 });
  const { data: productores = [] } = useQuery({ queryKey: ["catalogo", "productores"], queryFn: () => listCatalogo("productores"), staleTime: 5 * 60_000 });
  const { data: transportistas = [] } = useQuery({ queryKey: ["catalogo", "transportistas"], queryFn: () => listCatalogo("transportistas"), staleTime: 5 * 60_000 });
  const { data: fronteras = [] } = useQuery({ queryKey: ["catalogo", "fronteras"], queryFn: () => listCatalogo("fronteras"), staleTime: 5 * 60_000 });
  const { data: facturas = [] } = useQuery({ queryKey: ["facturas"], queryFn: getFacturas, staleTime: 5 * 60_000 });

  function update<K extends keyof PlanCargaCreate>(k: K, v: PlanCargaCreate[K] | null) {
    setForm((p) => ({ ...p, [k]: v }));
  }

  // Al salir del campo Factura: autollena lo que se repite por factura (carpeta,
  // exportador, frontera, transportista, afidi) sin pisar lo que ya escribiste.
  // El productor NO se toca (es lo único que cambia por carga).
  async function autollenarPorFactura() {
    const f = (form.factura ?? "").trim();
    if (!f) return;
    try {
      const d = await getFacturaDatos(f);
      setForm((p) => ({
        ...p,
        carpeta_import: p.carpeta_import || d.carpeta_import || null,
        exportador: p.exportador || d.exportador || null,
        frontera: p.frontera || d.frontera || null,
        transportista: p.transportista || d.transportista || null,
        afidi: p.afidi || d.afidi || null,
      }));
    } catch {
      /* factura desconocida o error de red → sin autollenado */
    }
  }

  const mut = useMutation({
    mutationFn: () => {
      if (mode === "create") {
        return createPlanCarga({ ...form, fuente } as PlanCargaCreate);
      }
      return updatePlanCarga(carga!.id, form);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["plan-cargas"] });
      qc.invalidateQueries({ queryKey: ["monitor-camiones"] });
      qc.invalidateQueries({ queryKey: ["carpetas"] });
      onClose();
    },
  });

  const delMut = useMutation({
    mutationFn: () => deletePlanCarga(carga!.id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["plan-cargas"] });
      qc.invalidateQueries({ queryKey: ["monitor-camiones"] });
      qc.invalidateQueries({ queryKey: ["carpetas"] });
      onClose();
    },
    onError: () => setConfirmDel(false),
  });

  const cancelMut = useMutation({
    mutationFn: () => cancelPlanCarga(carga!.id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["plan-cargas"] });
      qc.invalidateQueries({ queryKey: ["monitor-camiones"] });
      onClose();
    },
  });

  return (
    <>
    <div className="fixed inset-0 z-50 bg-slate-900/50 flex items-end sm:items-center justify-center p-0 sm:p-4" onClick={onClose}>
      <div
        onClick={(e) => e.stopPropagation()}
        className="bg-white rounded-t-xl sm:rounded-xl shadow-2xl w-full max-w-3xl border border-pepe-border max-h-[92dvh] sm:max-h-[95vh] flex flex-col"
      >
        <header className="px-5 py-3 border-b border-pepe-border flex items-center justify-between">
          <h2 className="text-lg font-semibold text-slate-900">
            {mode === "create" ? "Nueva carga" : `Editar carga #${carga?.id}`}
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-600 text-2xl leading-none">×</button>
        </header>
        <div className="flex-1 overflow-y-auto p-5 space-y-4">
          {/* Desplegables (combobox: sugieren del catálogo, permiten texto libre). */}
          <datalist id="cat-choferes">{choferes.map((c) => <option key={c.id} value={c.nombre} />)}</datalist>
          <datalist id="cat-productores">{productores.map((c) => <option key={c.id} value={c.nombre} />)}</datalist>
          <datalist id="cat-transportistas">{transportistas.map((c) => <option key={c.id} value={c.nombre} />)}</datalist>
          <datalist id="cat-fronteras">{fronteras.map((c) => <option key={c.id} value={c.nombre} />)}</datalist>
          <datalist id="cat-facturas">{facturas.map((f) => <option key={f} value={f} />)}</datalist>
          {/* Identificación */}
          <Section title="Identificación">
            <Grid>
              <Field label="Status">
                <select
                  value={form.status ?? "Solicitado"}
                  onChange={(e) => update("status", e.target.value as StatusCarga)}
                  className="input"
                >
                  {STATUS_VALUES.map((s) => <option key={s} value={s}>{s}</option>)}
                </select>
              </Field>
              <Field label="Semana">
                <input value={form.carga_semana ?? ""} onChange={(e) => update("carga_semana", e.target.value || null)} className="input" />
              </Field>
              <Field label="Factura">
                <input list="cat-facturas" value={form.factura ?? ""} onChange={(e) => update("factura", e.target.value || null)} onBlur={autollenarPorFactura} placeholder="001/26" className="input" />
              </Field>
              <Field label="Productor" wide>
                <input list="cat-productores" value={form.productor ?? ""} onChange={(e) => update("productor", e.target.value || null)} placeholder="Valdemar" className="input" />
              </Field>
              <Field label="Carpeta import.">
                <input value={form.carpeta_import ?? ""} onChange={(e) => update("carpeta_import", e.target.value.toUpperCase() || null)} placeholder="BRB001" className="input" />
              </Field>
              <Field label="AFIDI" wide>
                <input value={form.afidi ?? ""} onChange={(e) => update("afidi", e.target.value || null)} placeholder="148,17,39 (puede haber varios)" className="input" />
              </Field>
            </Grid>
          </Section>

          {/* Transporte */}
          <Section title="Transporte">
            <Grid>
              <Field label="Transportista" wide>
                <input list="cat-transportistas" value={form.transportista ?? ""} onChange={(e) => update("transportista", e.target.value || null)} className="input" />
              </Field>
              <Field label="Exportador" wide>
                <input value={form.exportador ?? ""} onChange={(e) => update("exportador", e.target.value || null)} className="input" />
              </Field>
              <Field label="N° Placa Camión">
                <input value={form.placa_camion ?? ""} onChange={(e) => update("placa_camion", e.target.value.toUpperCase() || null)} className="input" />
              </Field>
              <Field label="Placa remolque">
                <input value={form.placa_remolque ?? ""} onChange={(e) => update("placa_remolque", e.target.value.toUpperCase() || null)} className="input" />
              </Field>
              <Field label="Chofer">
                <input
                  list="cat-choferes"
                  value={form.chofer ?? ""}
                  onChange={(e) => {
                    const v = e.target.value;
                    update("chofer", v || null);
                    const c = choferes.find((x) => x.nombre === v);
                    if (c?.celular) update("celular", c.celular);  // autollenar celular
                  }}
                  className="input"
                />
              </Field>
              <Field label="Celular">
                <input value={form.celular ?? ""} onChange={(e) => update("celular", e.target.value || null)} placeholder="+55..." className="input" />
              </Field>
            </Grid>
          </Section>

          {/* Tránsito + descarga */}
          <Section title="Tránsito y descarga">
            <Grid>
              <Field label="Fecha carga">
                <input type="date" value={form.fecha_carga ?? ""} onChange={(e) => update("fecha_carga", e.target.value || null)} className="input" />
              </Field>
              <Field label="Fecha frontera">
                <input type="date" value={form.fecha_frontera ?? ""} onChange={(e) => update("fecha_frontera", e.target.value || null)} className="input" />
              </Field>
              <Field label="Fecha descarga">
                <input type="date" value={form.fecha_descarga ?? ""} onChange={(e) => update("fecha_descarga", e.target.value || null)} className="input" />
              </Field>
              <Field label="Frontera">
                <input list="cat-fronteras" value={form.frontera ?? ""} onChange={(e) => update("frontera", e.target.value || null)} placeholder="Rio Branco" className="input" />
              </Field>
              <Field label="Inspector MGAP" wide>
                <input value={form.inspector_mgap ?? ""} onChange={(e) => update("inspector_mgap", e.target.value || null)} className="input" />
              </Field>
            </Grid>
          </Section>

          {/* Mercadería */}
          <Section title="Mercadería">
            <Grid>
              <Field label="Productos" wide>
                <div className="flex flex-wrap items-center gap-1.5">
                  {(form.productos ?? []).map((p, i) => (
                    <span key={i} className="inline-flex items-center gap-1.5 pl-2 pr-1 py-1 rounded-lg border border-pepe-border bg-slate-50 text-sm">
                      {p.icono && <img src={`/categorias/${p.icono}.svg`} alt="" className="w-4 h-4 object-contain" />}
                      <span>{p.descripcion}</span>
                      <button
                        type="button"
                        onClick={() => update("productos", (form.productos ?? []).filter((_, idx) => idx !== i))}
                        className="text-slate-400 hover:text-rose-600 text-base leading-none px-0.5"
                        title="Quitar"
                      >
                        ×
                      </button>
                    </span>
                  ))}
                  <button
                    type="button"
                    onClick={() => setPickProd(true)}
                    className="px-3 py-1.5 rounded-lg border border-pepe-blue text-pepe-blue text-sm font-medium hover:bg-pepe-blue/5"
                  >
                    + Agregar producto
                  </button>
                </div>
              </Field>
              <Field label="País de origen">
                <input
                  list="paises-origen"
                  value={form.pais_origen ?? ""}
                  onChange={(e) => update("pais_origen", e.target.value || null)}
                  placeholder="Brasil, Paraguay, Ecuador…"
                  className="input"
                />
                <datalist id="paises-origen">
                  <option value="Brasil" />
                  <option value="Paraguay" />
                  <option value="Ecuador" />
                  <option value="Bolivia" />
                  <option value="Argentina" />
                  <option value="Perú" />
                </datalist>
              </Field>
              <Field label="Cajas (MIC)">
                <input type="number" value={form.cajas_mic ?? ""} onChange={(e) => update("cajas_mic", parseIntOrNull(e.target.value))} className="input text-right font-mono" />
              </Field>
              <Field label="Cajas descargadas">
                <input type="number" value={form.cajas_desc ?? ""} onChange={(e) => update("cajas_desc", parseIntOrNull(e.target.value))} className="input text-right font-mono" />
              </Field>
              <Field label="Pallets">
                <input type="number" value={form.cant_pallet ?? ""} onChange={(e) => update("cant_pallet", parseIntOrNull(e.target.value))} className="input text-right font-mono" />
              </Field>
              <Field label="Kg/caja">
                <input type="number" step="0.01" value={form.cant_kilos_caja ?? ""} onChange={(e) => update("cant_kilos_caja", parseFloatOrNull(e.target.value))} className="input text-right font-mono" />
              </Field>
              <Field label="Código viaje">
                <input value={form.codigo_viaje ?? ""} onChange={(e) => update("codigo_viaje", e.target.value || null)} className="input" />
              </Field>
              <Field label="MIC">
                <input value={form.mic ?? ""} onChange={(e) => update("mic", e.target.value || null)} className="input" />
              </Field>
            </Grid>
          </Section>

          {/* Observaciones */}
          <Section title="Observaciones">
            <textarea
              value={form.observaciones ?? ""}
              onChange={(e) => update("observaciones", e.target.value || null)}
              rows={3}
              className="w-full px-3 py-2 border border-pepe-border rounded text-sm"
              placeholder="Notas, comentarios, problemas en el tránsito…"
            />
          </Section>

          {(mut.error || cancelMut.error || delMut.error) && (
            <div className="px-3 py-2 rounded bg-rose-50 border border-rose-200 text-sm text-rose-800">
              {((mut.error || cancelMut.error || delMut.error) as Error).message}
            </div>
          )}
        </div>
        <footer className="px-5 py-3 border-t border-pepe-border flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
          {mode === "edit" && (
            <div className="flex items-center gap-3">
              {carga?.status !== "Cancelado" && carga?.status !== "Descargado" && (
                <button
                  onClick={() => cancelMut.mutate()}
                  disabled={cancelMut.isPending}
                  className="text-sm text-amber-700 hover:text-amber-900 font-medium"
                >
                  Cancelar carga
                </button>
              )}
              {confirmDel ? (
                <span className="flex items-center gap-1.5 text-sm">
                  <span className="text-slate-600">¿Eliminar?</span>
                  <button onClick={() => delMut.mutate()} disabled={delMut.isPending} className="px-2.5 py-1 rounded bg-rose-600 text-white font-medium hover:bg-rose-700">Sí</button>
                  <button onClick={() => setConfirmDel(false)} className="px-2.5 py-1 rounded border border-pepe-border text-slate-600">No</button>
                </span>
              ) : (
                <button onClick={() => setConfirmDel(true)} className="text-sm text-rose-700 hover:text-rose-900 font-medium">
                  Eliminar
                </button>
              )}
            </div>
          )}
          <div className="flex items-center gap-2 ml-auto">
            <button onClick={onClose} className="px-4 py-2 rounded border border-pepe-border bg-white text-sm font-medium hover:bg-slate-50">
              Cerrar
            </button>
            <button
              onClick={() => mut.mutate()}
              disabled={mut.isPending}
              className="px-4 py-2 rounded bg-pepe-blue text-white text-sm font-semibold hover:bg-pepe-blue-dark disabled:opacity-50"
            >
              {mut.isPending ? "Guardando…" : "Guardar"}
            </button>
          </div>
        </footer>
      </div>
      <style>{`
        .input {
          width: 100%;
          padding: 0.5rem 0.75rem;
          border: 1px solid var(--pepe-border, #e2e8f0);
          border-radius: 0.25rem;
          font-size: 0.875rem;
          background: white;
        }
      `}</style>
    </div>
    {pickProd && (
      <ArticuloPickerModal
        onClose={() => setPickProd(false)}
        onSelect={(a) => {
          const icono = cats.find((c) => c.nombre === a.categoria)?.icono ?? null;
          update("productos", [...(form.productos ?? []), { descripcion: a.descripcion, icono, cod_art: a.cod }]);
          setPickProd(false);
        }}
      />
    )}
    </>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h3 className="text-xs uppercase tracking-wider text-slate-500 font-semibold mb-2">{title}</h3>
      {children}
    </section>
  );
}

function Grid({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">{children}</div>;
}

function Field({ label, children, wide }: { label: string; children: React.ReactNode; wide?: boolean }) {
  return (
    <div className={wide ? "sm:col-span-2" : ""}>
      <label className="block text-[11px] uppercase tracking-wide text-slate-500 font-semibold mb-1">{label}</label>
      {children}
    </div>
  );
}

// ─── Helpers ────────────────────────────────────────────────────────────

function statusClass(status: StatusCarga): string {
  switch (status) {
    case "Solicitado": return "bg-slate-100 text-slate-700";
    case "Confirmado": return "bg-blue-100 text-blue-800";
    case "Cargado": return "bg-sky-100 text-sky-800";
    case "Mar": return "bg-indigo-100 text-indigo-800";
    case "Puerto": return "bg-cyan-100 text-cyan-800";
    case "Frontera": return "bg-amber-100 text-amber-800";
    case "Liberado": return "bg-emerald-100 text-emerald-800";
    case "Arribado": return "bg-teal-100 text-teal-800";
    case "Descargado": return "bg-pepe-blue/10 text-pepe-blue";
    case "Cancelado": return "bg-rose-100 text-rose-800";
    case "Destruida": return "bg-rose-200 text-rose-900";
  }
}

function fmtDate(iso: string | null): string {
  if (!iso) return "—";
  const [y, m, d] = iso.split("-");
  return `${d}/${m}/${y.slice(2)}`;
}

function parseIntOrNull(v: string): number | null {
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
}

function parseFloatOrNull(v: string): number | null {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : null;
}
