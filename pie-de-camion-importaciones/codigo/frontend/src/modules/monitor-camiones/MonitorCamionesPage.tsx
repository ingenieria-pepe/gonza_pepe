import { useQuery } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { listMonitorCamiones, type PlanCarga, type StatusCarga } from "../../shared/api/planCargas";

/**
 * Pantalla pública para mostrar en un monitor del depósito: camiones que están
 * por llegar / en tránsito. Auto-refresh cada 30s. Diseñado para ser legible
 * desde lejos en una TV.
 *
 * Filtro opcional para "sólo Solicitado" — útil para distinguir los que ni
 * siquiera salieron del productor de los que están en camino.
 */
// IP de la tele (sólo dentro de Fully Kiosk, que inyecta window.fully) → para
// llegar al Remote Admin en :2323. En un navegador normal no muestra nada.
function FkbIp() {
  const [ip, setIp] = useState<string | null>(null);
  useEffect(() => {
    try {
      const f = (window as unknown as { fully?: { getIp4Address?: () => string } }).fully;
      const v = f?.getIp4Address?.();
      if (v) setIp(v);
    } catch {
      /* navegador normal */
    }
  }, []);
  if (!ip) return null;
  return <span className="text-[11px] text-white/50 font-mono leading-none">{ip}:2323</span>;
}

export function MonitorCamionesPage() {
  const [onlySolicitados, setOnlySolicitados] = useState(false);
  const [now, setNow] = useState(() => new Date());
  // ?k=<token> → acceso sin login en las teles (igual que /tv/entregas).
  const [params] = useSearchParams();
  const kioskToken = params.get("k") || undefined;

  // Tick para mostrar "Actualizado hace Xs"
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(t);
  }, []);

  // El puente OneDrive lo sincroniza el SERVIDOR solo (loop de fondo), así que la
  // tele en kiosko (sin login) ve los datos al día sin disparar nada: sólo lee.
  const { data, isLoading, dataUpdatedAt } = useQuery({
    queryKey: ["monitor-camiones", kioskToken],
    queryFn: () => listMonitorCamiones(kioskToken),
    refetchInterval: 30_000,
    refetchOnWindowFocus: true,
    staleTime: 0,
  });

  const list = data ?? [];
  const filtered = onlySolicitados ? list.filter((c) => c.status === "Solicitado") : list;
  const secondsAgo = Math.max(0, Math.floor((now.getTime() - dataUpdatedAt) / 1000));

  return (
    <div className="h-full bg-slate-50 flex flex-col overflow-hidden">
      {/* Header. En modo TV (kiosko ?k=) va con la estética Aloha: barra azul +
          logo Pepe, igual que el Monitor de Entregas. Dentro de la app el Layout
          ya pone su header azul con el logo, así que ahí queda el header claro. */}
      {kioskToken ? (
        <header className="px-4 py-2.5 bg-pepe-blue text-white shadow-md flex items-center gap-3 shrink-0">
          <img src="/logo_pepe_transparente.png" alt="Pepe" className="h-9 w-auto object-contain shrink-0" />
          <div className="leading-tight">
            <h1 className="text-xl font-bold tracking-tight">Monitor de camiones</h1>
            <p className="text-xs text-white/70">
              {filtered.length} {filtered.length === 1 ? "camión" : "camiones"} en tránsito
              {onlySolicitados && " (sólo solicitados)"}
            </p>
          </div>
          <div className="ml-auto flex items-center gap-3">
            <button
              onClick={() => setOnlySolicitados((v) => !v)}
              className={`px-3 py-1.5 rounded-md text-sm font-semibold transition-colors border ${
                onlySolicitados
                  ? "bg-pepe-yellow text-pepe-blue-dark border-pepe-yellow"
                  : "bg-white/10 text-white border-white/30 hover:bg-white/20"
              }`}
            >
              {onlySolicitados ? "Sólo solicitados" : "Todos"}
            </button>
            <FkbIp />
            <div className="text-[11px] text-white/60 text-right leading-tight">
              <div>Auto-refresh 30s</div>
              <div>{isLoading ? "Cargando…" : `Hace ${secondsAgo}s`}</div>
            </div>
          </div>
        </header>
      ) : (
        <header className="px-3 sm:px-6 py-3 bg-white border-b border-pepe-border flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between shrink-0">
          <div>
            <h1 className="text-xl sm:text-2xl font-bold text-slate-900 tracking-tight">Monitor de camiones</h1>
            <p className="text-sm text-slate-500 mt-0.5">
              {filtered.length} {filtered.length === 1 ? "camión" : "camiones"} en tránsito
              {onlySolicitados && " (sólo solicitados)"}
            </p>
          </div>
          <div className="flex items-center justify-between sm:justify-start gap-3 sm:gap-4">
            <button
              onClick={() => setOnlySolicitados((v) => !v)}
              className={`px-4 py-2.5 sm:py-2 rounded-lg text-sm font-semibold transition-colors border ${
                onlySolicitados
                  ? "bg-pepe-yellow text-pepe-blue-dark border-pepe-yellow"
                  : "bg-white text-slate-700 border-pepe-border hover:bg-slate-50"
              }`}
            >
              {onlySolicitados ? "Sólo solicitados" : "Todos"}
            </button>
            <div className="text-xs text-slate-400 text-right">
              <div>Auto-refresh 30s</div>
              <div>{isLoading ? "Cargando…" : `Hace ${secondsAgo}s`}</div>
            </div>
          </div>
        </header>
      )}

      {/* Lista. En la TELE (kiosko) NO scrollea: la grilla calcula columnas según
          cuántos camiones hay y estira las filas para LLENAR la pantalla (todo
          visible, sin cortar). Dentro de la app queda la grilla responsive normal. */}
      <main className={`flex-1 min-h-0 p-3 ${kioskToken ? "overflow-hidden" : "overflow-y-auto overscroll-y-contain"}`}>
        {isLoading ? (
          <div className="text-center text-slate-400 py-12 text-xl">Cargando…</div>
        ) : filtered.length === 0 ? (
          <div className="h-full flex flex-col items-center justify-center text-center text-slate-400">
            <svg className="w-24 h-24 mb-4 text-slate-200" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M8 7v8a2 2 0 002 2h6M8 7V5a2 2 0 012-2h4.586a1 1 0 01.707.293l4.414 4.414a1 1 0 01.293.707V15a2 2 0 01-2 2h-2M8 7H6a2 2 0 00-2 2v10a2 2 0 002 2h8a2 2 0 002-2v-2" />
            </svg>
            <div className="text-2xl font-semibold text-slate-700">No hay camiones en tránsito</div>
            <div className="mt-2 text-base text-slate-400">Cuando se planifique una carga, va a aparecer acá</div>
          </div>
        ) : kioskToken ? (
          <div
            className="h-full grid gap-3"
            style={{
              gridTemplateColumns: `repeat(${gridCols(filtered.length)}, minmax(0, 1fr))`,
              gridAutoRows: "1fr",
            }}
          >
            {filtered.map((c) => (
              <CamionCard key={c.id} carga={c} tv />
            ))}
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
            {filtered.map((c) => (
              <CamionCard key={c.id} carga={c} />
            ))}
          </div>
        )}
      </main>
    </div>
  );
}

// ─── Card por camión ────────────────────────────────────────────────────

function CamionCard({ carga, tv = false }: { carga: PlanCarga; tv?: boolean }) {
  const fechaLlegada = carga.fecha_descarga || carga.fecha_frontera;
  const diasFalta = fechaLlegada ? daysUntil(fechaLlegada) : null;

  return (
    <div className="h-full min-h-0 flex flex-col bg-white rounded-lg border border-pepe-border shadow-sm overflow-hidden hover:shadow-md hover:border-slate-300 transition-all">
      {/* Cabecera con status (colores fuertes → leíble desde lejos en la TV) */}
      <div className={`${tv ? "px-5 py-2.5" : "px-4 py-2"} ${statusBgClass(carga.status)} flex items-center justify-between shrink-0`}>
        <span className={`${tv ? "text-lg" : "text-base"} font-bold uppercase tracking-wider`}>{carga.status}</span>
        {diasFalta !== null && (
          <span className={`${tv ? "text-base" : "text-sm"} font-bold opacity-90`}>{fmtDiasFalta(diasFalta)}</span>
        )}
      </div>

      {/* Body: llena la celda; el transportista se ancla abajo (mt-auto). */}
      <div className={`flex-1 min-h-0 flex flex-col ${tv ? "px-5 py-3.5 gap-2.5" : "px-4 py-3 gap-2"}`}>
        {/* Productor + carpeta destacados */}
        <div>
          <div className={`${tv ? "text-3xl" : "text-xl"} font-bold text-slate-900 leading-tight`}>
            {/* BR identifica por productor; OTROS no lo tiene → producto (+ país) */}
            {carga.productor || carga.productos?.[0]?.descripcion || "—"}
          </div>
          {(carga.carpeta_import || (!carga.productor && carga.pais_origen)) && (
            <div className={`${tv ? "text-base" : "text-xs"} text-slate-500 font-mono mt-0.5`}>
              {[carga.carpeta_import, !carga.productor ? carga.pais_origen : null].filter(Boolean).join(" · ")}
            </div>
          )}
        </div>

        {/* Fecha de llegada (lo más importante) */}
        {fechaLlegada && (
          <div className={`flex items-center gap-2 ${tv ? "text-2xl" : "text-base"} text-amber-700`}>
            <svg className={tv ? "w-6 h-6" : "w-4 h-4"} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
            </svg>
            <span className="font-bold">{fmtDate(fechaLlegada)}</span>
            <span className={`${tv ? "text-base" : "text-xs"} text-slate-400`}>{carga.fecha_descarga ? "descarga" : "frontera"}</span>
          </div>
        )}

        {/* Fecha de carga en origen */}
        {carga.fecha_carga && (
          <div className={`flex items-center gap-2 ${tv ? "text-lg" : "text-sm"} text-slate-600`}>
            <svg className={tv ? "w-5 h-5 text-slate-400" : "w-4 h-4 text-slate-400"} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
            </svg>
            <span>cargado <span className="font-semibold text-slate-800">{fmtDate(carga.fecha_carga)}</span></span>
          </div>
        )}

        {/* Frontera */}
        {carga.frontera && (
          <div className={`${tv ? "text-lg" : "text-sm"} text-slate-700`}>
            <span className="text-slate-400">por</span> {carga.frontera}
          </div>
        )}

        {/* Cajas */}
        {carga.cajas_mic && (
          <div className="text-slate-700">
            <span className={`font-mono font-bold ${tv ? "text-3xl" : "text-lg"} text-slate-900`}>{carga.cajas_mic.toLocaleString("es-UY")}</span>
            <span className={`${tv ? "text-lg" : "text-sm"} text-slate-500 ml-1.5`}>cajas (MIC)</span>
          </div>
        )}

        {/* Transportista + matrícula — anclado al fondo de la card. */}
        {(carga.transportista || carga.placa_camion || carga.placa_remolque) && (
          <div className={`mt-auto pt-2 border-t border-pepe-border flex items-center justify-between gap-2`}>
            <span className={`${tv ? "text-base" : "text-xs"} text-slate-500 truncate`}>{carga.transportista || "—"}</span>
            {(carga.placa_camion || carga.placa_remolque) && (
              <span className="inline-flex items-center gap-1.5 rounded-md border border-slate-300 bg-slate-50 px-2 py-1 shrink-0">
                <svg className={tv ? "w-5 h-5 text-slate-400" : "w-4 h-4 text-slate-400"} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M9 17a2 2 0 11-4 0 2 2 0 014 0zm10 0a2 2 0 11-4 0 2 2 0 014 0z" />
                  <path strokeLinecap="round" strokeLinejoin="round" d="M13 16V6a1 1 0 00-1-1H4a1 1 0 00-1 1v10a1 1 0 001 1h1m8-1a1 1 0 01-1 1H9m4-1V8h4l3 3v5a1 1 0 01-1 1h-1m-4 0H9" />
                </svg>
                <span className={`font-mono font-bold ${tv ? "text-lg" : "text-sm"} text-slate-900 tracking-wide`}>
                  {carga.placa_camion || "—"}
                  {carga.placa_remolque && (
                    <span className="text-slate-400 font-normal"> / {carga.placa_remolque}</span>
                  )}
                </span>
              </span>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

// Columnas de la grilla en la TELE según cuántos camiones hay, para que TODO entre
// y llene la pantalla 16:9 sin scroll (con gridAutoRows:1fr las filas estiran).
function gridCols(n: number): number {
  if (n <= 3) return n;   // 1, 2 o 3 en una fila
  if (n <= 4) return 2;   // 2×2
  if (n <= 6) return 3;   // 3×2
  if (n <= 9) return 3;   // 3×3
  if (n <= 12) return 4;  // 4×3
  return 5;
}

// ─── Helpers ────────────────────────────────────────────────────────────

function statusBgClass(status: StatusCarga): string {
  // Colores fuertes saturados — son la única zona oscura de la card para
  // que los estados sean leíbles a distancia desde el monitor del depósito.
  switch (status) {
    case "Liberado":
      return "bg-emerald-600 text-emerald-50";   // ya viene en ruta, foco máximo
    case "Frontera":
      return "bg-amber-500 text-amber-950";      // en trámite, atención
    case "Arribado":
      return "bg-pepe-blue text-white";
    case "Confirmado":
      return "bg-slate-300 text-slate-800";
    case "Solicitado":
      return "bg-slate-200 text-slate-700";
    default:
      return "bg-slate-200 text-slate-700";
  }
}

function fmtDate(iso: string): string {
  // YYYY-MM-DD → DD/MM
  const [, m, d] = iso.split("-");
  return `${d}/${m}`;
}

function daysUntil(iso: string): number {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const target = new Date(iso + "T00:00:00");
  const diffMs = target.getTime() - today.getTime();
  return Math.round(diffMs / 86_400_000);
}

function fmtDiasFalta(d: number): string {
  if (d === 0) return "HOY";
  if (d === 1) return "MAÑANA";
  if (d < 0) return `${-d}d atrás`;
  return `en ${d}d`;
}
