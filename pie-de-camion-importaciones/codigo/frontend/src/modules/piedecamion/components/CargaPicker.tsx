import { useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";
import { listPlanCargas, type PlanCarga, type StatusCarga } from "../../../shared/api/planCargas";
import { getViajesPendientesRecepcion, type ViajePendienteRecepcion } from "../../../shared/api/stock";
import { hoyUY } from "../../../shared/format";

interface Props {
  /** Carga seleccionada (la mostramos como "elegida"). */
  selected: PlanCarga | null;
  onSelect: (carga: PlanCarga | null) => void;
  /** Recepción ciega (26/08): al elegir un VIAJE CR→ZAC pendiente. */
  onPickViaje?: (v: ViajePendienteRecepcion) => void;
  disabled?: boolean;
}

/**
 * Picker de cargas del Plan para iniciar un pie de camión. Muestra las
 * cargas que están "listas para llegar / llegando" (Frontera, Liberado,
 * Arribado) ordenadas por fecha estimada de descarga.
 *
 * Si querés cargar a mano (sin matchear con el Plan), no elegís nada y el
 * form se queda en blanco como antes.
 */
export function CargaPicker({ selected, onSelect, onPickViaje, disabled }: Props) {
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const containerRef = useRef<HTMLDivElement>(null);

  // Traemos las pendientes — el plan tiene Solicitado/Confirmado/Frontera/Liberado/Arribado.
  // Solicitado/Confirmado son raros pero los dejamos por si el operario se adelanta.
  const { data: cargas = [], isLoading } = useQuery({
    queryKey: ["plan-cargas", { pendientes: true }],
    queryFn: () => listPlanCargas({ pendientes: true, limit: 200 }),
    staleTime: 60_000,
  });

  // Viajes CR→ZAC sin recepción: salen ARRIBA con badge VIAJE (ciego).
  const { data: viajes = [] } = useQuery({
    queryKey: ["stock", "viajes-pendientes-recepcion"],
    queryFn: getViajesPendientesRecepcion,
    enabled: !!onPickViaje && open,
    staleTime: 60_000,
    retry: false,
  });

  // Los viajes, SÓLO los de HOY (dueño 2/09). Un camión de CR no se queda sin
  // recepcionar: si aparece uno de hace tres días es que se recibió por fuera de
  // Aloha, y en la lista sólo sirve para marear al que está descargando ahora.
  // No se esconden en silencio —esa es la regla de la casa—: el contador dice
  // cuántos quedaron atrás y se pueden ver con un click.
  const [verViajesViejos, setVerViajesViejos] = useState(false);
  const hoy = hoyUY();
  const viajesDeHoy = viajes.filter((v) => v.fecha === hoy);
  const viajesViejos = viajes.length - viajesDeHoy.length;
  const viajesVisibles = verViajesViejos ? viajes : viajesDeHoy;

  // Filtro local por search + ORDEN por estado: primero los que están llegando
  // (Frontera/Liberado), después Arribado/Confirmado, y al final los Solicitado.
  // Dentro de cada grupo, por fecha estimada de llegada (la más próxima primero).
  const filtered = useMemo(() => {
    const s = search.trim().toLowerCase();
    const base = !s
      ? cargas
      : cargas.filter((c) =>
          [c.productor, c.factura, c.carpeta_import, c.transportista, c.placa_camion, c.chofer,
           c.productos?.[0]?.descripcion, c.pais_origen]
            .some((v) => v?.toLowerCase().includes(s))
        );
    return [...base].sort((a, b) => {
      const dr = statusRank(a.status) - statusRank(b.status);
      if (dr !== 0) return dr;
      const fa = a.fecha_descarga || a.fecha_frontera || "9999-99-99";
      const fb = b.fecha_descarga || b.fecha_frontera || "9999-99-99";
      if (fa !== fb) return fa < fb ? -1 : 1;
      return a.id - b.id;
    });
  }, [cargas, search]);

  useEffect(() => {
    function handler(e: MouseEvent) {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, []);

  return (
    <div ref={containerRef} className="relative">
      {/* Botón "elegir carga" o card de la elegida */}
      {selected ? (
        <SelectedCard
          carga={selected}
          onClear={() => onSelect(null)}
          onChange={() => setOpen(true)}
          disabled={disabled}
        />
      ) : (
        <button
          type="button"
          onClick={() => !disabled && setOpen(true)}
          disabled={disabled}
          className="w-full px-4 py-3 rounded-md border-2 border-dashed border-pepe-blue/40 bg-pepe-blue/5 text-pepe-blue text-sm font-medium hover:bg-pepe-blue/10 disabled:opacity-50 inline-flex items-center justify-center gap-2"
        >
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 17a2 2 0 11-4 0 2 2 0 014 0zM19 17a2 2 0 11-4 0 2 2 0 014 0z" />
            <path strokeLinecap="round" strokeLinejoin="round" d="M13 16V6a1 1 0 00-1-1H4a1 1 0 00-1 1v10a1 1 0 001 1h1m8-1a1 1 0 01-1 1H9m4-1V8a1 1 0 011-1h2.586a1 1 0 01.707.293l3.414 3.414a1 1 0 01.293.707V16a1 1 0 01-1 1h-1m-6-1a1 1 0 001 1h1M5 17a2 2 0 104 0m-4 0a2 2 0 114 0m6 0a2 2 0 104 0m-4 0a2 2 0 114 0" />
          </svg>
          Elegir camión del Plan de Cargas
        </button>
      )}

      {/* Dropdown con la lista */}
      {open && (
        <div className="absolute left-0 right-0 mt-1 z-30 bg-white border border-pepe-border rounded-md shadow-lg max-h-96 overflow-hidden flex flex-col">
          <div className="p-2 border-b border-pepe-border bg-slate-50 sticky top-0">
            <input
              type="text"
              inputMode="search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Buscar productor, factura, carpeta, transportista…"
              className="w-full px-3 py-1.5 border border-pepe-border rounded text-sm focus:outline-none focus:ring-2 focus:ring-pepe-blue/30"
            />
          </div>

          <div className="overflow-y-auto overscroll-y-contain flex-1">
            {isLoading ? (
              <div className="px-3 py-6 text-center text-sm text-slate-400">Cargando…</div>
            ) : filtered.length === 0 && viajesVisibles.length === 0 ? (
              /* El vacío mira las DOS listas: con un viaje pendiente y ninguna
                 carga del plan, antes decía "no hay cargas" y se comía el viaje. */
              <div className="px-3 py-6 text-center text-sm text-slate-400">
                {cargas.length === 0 && viajes.length === 0
                  ? "No hay cargas planificadas. Cargá una desde 'Plan de cargas'."
                  : "Sin resultados."}
              </div>
            ) : (
              <>
              {viajesVisibles.map((v) => (
                <button
                  key={`viaje-${v.id}`}
                  type="button"
                  onClick={() => {
                    onPickViaje?.(v);
                    setOpen(false);
                  }}
                  className="w-full text-left px-3 py-2.5 border-b border-slate-100 hover:bg-indigo-50/60"
                >
                  <div className="flex items-center gap-2">
                    <span className="px-1.5 py-0.5 rounded bg-indigo-100 text-indigo-700 text-[10px] font-bold uppercase tracking-wide">
                      VIAJE
                    </span>
                    <span className="font-semibold text-slate-800 text-sm">
                      CR → ZAC · Viaje {v.numero_del_dia}
                    </span>
                    <span className="ml-auto text-xs text-slate-400">{v.fecha}</span>
                  </div>
                  <div className="text-xs text-slate-500 mt-0.5">
                    Conteo ciego: cargá lo que llegó y el sistema compara al confirmar.
                  </div>
                </button>
              ))}
              {viajesViejos > 0 && !verViajesViejos && (
                <button
                  type="button"
                  onClick={() => setVerViajesViejos(true)}
                  className="w-full px-3 py-1.5 border-b border-slate-100 text-left text-xs text-slate-500 hover:bg-slate-50"
                >
                  {viajesViejos} {viajesViejos === 1 ? "viaje" : "viajes"} de días anteriores
                  <span className="ml-1 font-semibold text-pepe-blue">Ver</span>
                </button>
              )}
              {filtered.map((c) => (
                <CargaRow
                  key={c.id}
                  carga={c}
                  isSelected={selected?.id === c.id}
                  onClick={() => {
                    onSelect(c);
                    setOpen(false);
                    setSearch("");
                  }}
                />
              ))}
              </>
            )}
          </div>

          <div className="p-2 border-t border-pepe-border bg-slate-50 text-center">
            <button
              type="button"
              onClick={() => {
                onSelect(null);
                setOpen(false);
                setSearch("");
              }}
              className="inline-flex items-center justify-center min-h-[40px] sm:min-h-0 px-3 sm:px-0 py-2 sm:py-0 text-xs text-slate-500 hover:text-slate-700"
            >
              Continuar sin elegir carga del plan
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

// ─── Card de la carga elegida ───────────────────────────────────────────

function SelectedCard({
  carga,
  onClear,
  onChange,
  disabled,
}: {
  carga: PlanCarga;
  onClear: () => void;
  onChange: () => void;
  disabled?: boolean;
}) {
  return (
    <div className="px-4 py-3 rounded-md border-2 border-pepe-blue bg-pepe-blue/5">
      <div className="flex items-start gap-3">
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 mb-1">
            <span className={`inline-block px-2 py-0.5 rounded text-xs font-semibold ${statusBadge(carga.status)}`}>
              {carga.status}
            </span>
            {carga.carpeta_import && (
              <span className="text-xs font-mono text-slate-500">{carga.carpeta_import}</span>
            )}
          </div>
          <div className="text-base font-bold text-slate-900 break-words">
            {tituloCarga(carga)}
          </div>
          <div className="text-xs text-slate-600 mt-1 flex flex-wrap gap-x-3 gap-y-0.5">
            {carga.transportista && (
              <span className="inline-flex items-center gap-1">
                <IconTruck /> {carga.transportista}
              </span>
            )}
            {carga.placa_camion && <span className="font-mono">{carga.placa_camion}</span>}
            {carga.chofer && (
              <span className="inline-flex items-center gap-1">
                <IconUser /> {carga.chofer}
              </span>
            )}
            {carga.frontera && (
              <span className="inline-flex items-center gap-1">
                <IconLocation /> {carga.frontera}
              </span>
            )}
            {carga.cajas_mic && <span>{carga.cajas_mic.toLocaleString("es-UY")} cajas (MIC)</span>}
          </div>
        </div>
        <div className="flex flex-col gap-1 shrink-0">
          <button
            type="button"
            onClick={onChange}
            disabled={disabled}
            className="text-xs text-pepe-blue hover:text-pepe-blue-dark font-medium disabled:opacity-50"
          >
            Cambiar
          </button>
          <button
            type="button"
            onClick={onClear}
            disabled={disabled}
            className="text-xs text-slate-500 hover:text-rose-600 disabled:opacity-50"
          >
            Quitar
          </button>
        </div>
      </div>
    </div>
  );
}

// ─── Fila de cada carga en el dropdown ──────────────────────────────────

function CargaRow({
  carga,
  isSelected,
  onClick,
}: {
  carga: PlanCarga;
  isSelected: boolean;
  onClick: () => void;
}) {
  const fechaLlegada = carga.fecha_descarga || carga.fecha_frontera;
  return (
    <button
      type="button"
      onClick={onClick}
      className={`w-full text-left px-3 py-2 border-b border-pepe-border hover:bg-slate-50 ${
        isSelected ? "bg-pepe-blue/10" : ""
      }`}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="flex items-start gap-2 min-w-0 flex-1">
          <span className={`shrink-0 inline-block px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider ${statusBadge(carga.status)}`}>
            {carga.status}
          </span>
          <span className="font-semibold text-slate-900 break-words">{tituloCarga(carga)}</span>
        </div>
        {fechaLlegada && (
          <span className="text-xs text-slate-500 font-mono whitespace-nowrap shrink-0">
            {fmtDate(fechaLlegada)}
          </span>
        )}
      </div>
      <div className="text-xs text-slate-500 mt-0.5 flex flex-wrap gap-x-3">
        {carga.carpeta_import && <span className="font-mono text-slate-400">{carga.carpeta_import}</span>}
        {carga.transportista && <span>{carga.transportista}</span>}
        {carga.placa_camion && <span className="font-mono">{carga.placa_camion}</span>}
        {carga.cajas_mic && <span>{carga.cajas_mic.toLocaleString("es-UY")} cajas</span>}
      </div>
    </button>
  );
}

// ─── Helpers ────────────────────────────────────────────────────────────

// Orden del picker: Frontera/Liberado (llegando) arriba, Solicitado al final.
function statusRank(status: StatusCarga): number {
  switch (status) {
    case "Frontera": return 0;
    case "Liberado": return 0;
    case "Arribado": return 1;
    case "Confirmado": return 2;
    case "Solicitado": return 3;
    default: return 4;
  }
}

function statusBadge(status: StatusCarga): string {
  switch (status) {
    case "Liberado": return "bg-emerald-100 text-emerald-800";
    case "Frontera": return "bg-amber-100 text-amber-800";
    case "Arribado": return "bg-pepe-blue/10 text-pepe-blue";
    case "Confirmado": return "bg-blue-100 text-blue-800";
    case "Solicitado": return "bg-slate-100 text-slate-700";
    default: return "bg-slate-100 text-slate-700";
  }
}

function fmtDate(iso: string): string {
  const [, m, d] = iso.split("-");
  return `${d}/${m}`;
}

// ─── Iconos (SVG inline, sin emojis) ────────────────────────────────────

function IconTruck() {
  return (
    <svg className="w-3.5 h-3.5 text-slate-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M9 17a2 2 0 11-4 0 2 2 0 014 0zM19 17a2 2 0 11-4 0 2 2 0 014 0z" />
      <path strokeLinecap="round" strokeLinejoin="round" d="M13 16V6a1 1 0 00-1-1H4a1 1 0 00-1 1v10a1 1 0 001 1h1m8-1a1 1 0 01-1 1H9m4-1V8a1 1 0 011-1h2.586a1 1 0 01.707.293l3.414 3.414a1 1 0 01.293.707V16a1 1 0 01-1 1h-1m-6-1a1 1 0 001 1h1" />
    </svg>
  );
}

function IconUser() {
  return (
    <svg className="w-3.5 h-3.5 text-slate-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z" />
    </svg>
  );
}

function IconLocation() {
  return (
    <svg className="w-3.5 h-3.5 text-slate-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.8}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M17.657 16.657L13.414 20.9a2 2 0 01-2.828 0l-4.244-4.243a8 8 0 1111.314 0z" />
      <path strokeLinecap="round" strokeLinejoin="round" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
    </svg>
  );
}

// Título de la carga: la planilla BR identifica por PRODUCTOR; la de OTROS
// países no lo tiene → producto (+ país). Nunca "—" mudo si hay algo que mostrar.
function tituloCarga(c: { productor: string | null; productos: { descripcion: string }[]; pais_origen: string | null }): string {
  if (c.productor) return c.productor;
  const prod = c.productos?.[0]?.descripcion;
  if (prod) return c.pais_origen ? `${prod} (${c.pais_origen})` : prod;
  return c.pais_origen ?? "—";
}
