import { useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { listCategorias } from "../../../shared/api/stock";
import {
  listRequisitos,
  putRequisitosCategoria,
  type Requisito,
  type RequisitoUpsert,
  type TipoRequisito,
} from "../../../shared/api/piecamion";

const TIPOS: { valor: TipoRequisito; label: string; ayuda: string }[] = [
  { valor: "numero", label: "Número", ayuda: "Un dato medido (presión, °Brix…)" },
  { valor: "opciones", label: "Opciones", ayuda: "Elegir una entre varias" },
  { valor: "texto", label: "Texto", ayuda: "Texto libre" },
  { valor: "foto", label: "Foto", ayuda: "Foto obligatoria u opcional" },
];

interface Fila extends RequisitoUpsert {
  key: string;
}

function uuid(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID();
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function filaDe(r: Requisito): Fila {
  return {
    key: `${r.id}`, id: r.id, tipo: r.tipo, etiqueta: r.etiqueta,
    unidad: r.unidad, opciones: r.opciones, obligatorio: r.obligatorio,
  };
}

/**
 * ABM de requisitos por fruta (mig 0092) — para el ING. AGRÓNOMO. Elegís la
 * fruta, definís qué se pide al ingreso (número / opciones / texto / foto) y
 * guardás. Lo que se saca de la lista se DESACTIVA (el histórico no se toca).
 */
export function RequisitosConfigView({ onClose }: { onClose: () => void }) {
  const queryClient = useQueryClient();
  const categorias = useQuery({ queryKey: ["lookups", "categorias"], queryFn: () => listCategorias() });
  const config = useQuery({ queryKey: ["pie-requisitos", "config"], queryFn: () => listRequisitos() });
  const [categoria, setCategoria] = useState<string | null>(null);
  const [filas, setFilas] = useState<Fila[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [ok, setOk] = useState(false);

  const porCategoria = useMemo(() => {
    const m = new Map<string, Requisito[]>();
    for (const r of config.data ?? []) {
      m.set(r.categoria, [...(m.get(r.categoria) ?? []), r]);
    }
    return m;
  }, [config.data]);

  function abrir(cat: string) {
    setCategoria(cat);
    setFilas((porCategoria.get(cat) ?? []).map(filaDe));
    setError(null);
    setOk(false);
  }

  const guardar = useMutation({
    mutationFn: () => putRequisitosCategoria(categoria!, filas.map(({ key: _key, ...r }) => r)),
    onSuccess: async () => {
      setOk(true);
      setError(null);
      await queryClient.invalidateQueries({ queryKey: ["pie-requisitos"] });
    },
    onError: (e: unknown) => setError(e instanceof Error ? e.message : "No se pudo guardar"),
  });

  function editar(key: string, cambios: Partial<Fila>) {
    setOk(false);
    setFilas((prev) => prev.map((f) => (f.key === key ? { ...f, ...cambios } : f)));
  }

  function mover(key: string, delta: number) {
    setOk(false);
    setFilas((prev) => {
      const i = prev.findIndex((f) => f.key === key);
      const j = i + delta;
      if (i < 0 || j < 0 || j >= prev.length) return prev;
      const copia = [...prev];
      [copia[i], copia[j]] = [copia[j], copia[i]];
      return copia;
    });
  }

  const invalidas = filas.filter((f) =>
    !f.etiqueta.trim()
    || (f.tipo === "opciones" && (f.opciones ?? []).filter((o) => o.trim()).length < 2));

  return (
    <div className="fixed inset-0 z-40 bg-slate-50 overflow-y-auto overscroll-y-contain">
      <div className="sticky top-0 z-10 bg-white border-b border-pepe-border px-4 sm:px-6 py-3 flex items-center justify-between gap-3">
        <div>
          <h2 className="text-lg font-semibold text-slate-900">Requisitos por fruta</h2>
          <p className="text-xs text-slate-500">Qué se pide al ingreso de cada fruta (define el ing. agrónomo)</p>
        </div>
        <button
          onClick={onClose}
          className="flex items-center gap-2 rounded-xl border border-pepe-border bg-white px-4 py-2.5 text-sm font-semibold text-slate-600"
        >
          <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
            <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
          Cerrar
        </button>
      </div>

      <div className="max-w-4xl mx-auto p-4 sm:p-6">
        {/* Selector de fruta */}
        <div className="grid grid-cols-3 sm:grid-cols-5 gap-2 mb-5">
          {(categorias.data ?? []).map((c) => {
            const n = (porCategoria.get(c.nombre) ?? []).length;
            return (
              <button
                key={c.nombre}
                onClick={() => abrir(c.nombre)}
                className={`flex flex-col items-center gap-1 rounded-xl border-2 px-2 py-3 transition ${
                  categoria === c.nombre ? "border-pepe-blue bg-blue-50/60" : "border-pepe-border bg-white active:bg-slate-50"
                }`}
              >
                <img src={`/categorias/${c.icono}.svg`} alt="" className="w-9 h-9 object-contain" />
                <span className="text-xs font-bold text-slate-800">{c.nombre}</span>
                {n > 0 && (
                  <span className="rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-bold text-emerald-700">
                    {n} requisito{n === 1 ? "" : "s"}
                  </span>
                )}
              </button>
            );
          })}
        </div>

        {categoria === null ? (
          <div className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-10 text-center text-sm text-slate-400">
            Elegí una fruta para definir (o ver) sus requisitos de ingreso.
          </div>
        ) : (
          <div className="rounded-2xl border border-pepe-border bg-white p-4 sm:p-5">
            <h3 className="font-bold text-slate-900 mb-3">Requisitos de {categoria}</h3>
            {error && <div className="mb-3 rounded-lg border border-rose-200 bg-rose-50 px-3 py-2.5 text-sm text-rose-700">{error}</div>}
            {ok && <div className="mb-3 rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2.5 text-sm text-emerald-800">Guardado. El form del pie ya pide esto.</div>}

            {filas.length === 0 && (
              <div className="mb-3 rounded-lg bg-slate-50 px-3 py-4 text-center text-sm text-slate-400">
                {categoria} no tiene requisitos: el pie se carga como siempre.
              </div>
            )}

            <div className="space-y-3">
              {filas.map((f, i) => (
                <div key={f.key} className="rounded-xl border border-slate-200 p-3">
                  <div className="flex flex-wrap items-center gap-2 mb-2">
                    {TIPOS.map((t) => (
                      <button
                        key={t.valor}
                        type="button"
                        title={t.ayuda}
                        onClick={() => editar(f.key, { tipo: t.valor })}
                        className={`rounded-lg border px-3 py-1.5 text-xs font-bold ${
                          f.tipo === t.valor ? "border-pepe-blue bg-pepe-blue text-white" : "border-pepe-border bg-white text-slate-500"
                        }`}
                      >
                        {t.label}
                      </button>
                    ))}
                    <span className="flex-1" />
                    <button type="button" onClick={() => mover(f.key, -1)} disabled={i === 0} className="rounded-lg border border-pepe-border px-2 py-1 text-xs disabled:opacity-30" aria-label="Subir">↑</button>
                    <button type="button" onClick={() => mover(f.key, +1)} disabled={i === filas.length - 1} className="rounded-lg border border-pepe-border px-2 py-1 text-xs disabled:opacity-30" aria-label="Bajar">↓</button>
                    <button
                      type="button"
                      onClick={() => { setOk(false); setFilas((prev) => prev.filter((x) => x.key !== f.key)); }}
                      className="rounded-lg px-2.5 py-1 text-xs font-semibold text-rose-500 hover:bg-rose-50"
                    >
                      Quitar
                    </button>
                  </div>
                  <div className="grid gap-2 sm:grid-cols-[minmax(0,1fr)_auto_auto]">
                    <input
                      value={f.etiqueta}
                      onChange={(e) => editar(f.key, { etiqueta: e.target.value })}
                      placeholder={f.tipo === "foto" ? "Ej. Foto de la pulpa" : "Ej. Presión de pulpa"}
                      maxLength={200}
                      className="rounded-lg border border-pepe-border px-3 py-2.5 outline-none focus:border-pepe-blue focus:ring-4 focus:ring-pepe-blue/10"
                    />
                    {f.tipo === "numero" && (
                      <input
                        value={f.unidad ?? ""}
                        onChange={(e) => editar(f.key, { unidad: e.target.value })}
                        placeholder="Unidad (kgf, °Brix…)"
                        maxLength={20}
                        className="w-40 rounded-lg border border-pepe-border px-3 py-2.5 outline-none focus:border-pepe-blue focus:ring-4 focus:ring-pepe-blue/10"
                      />
                    )}
                    <label className="flex items-center gap-2 text-sm font-semibold text-slate-600">
                      <input
                        type="checkbox"
                        checked={f.obligatorio}
                        onChange={(e) => editar(f.key, { obligatorio: e.target.checked })}
                        className="w-5 h-5 rounded border-slate-300 text-pepe-blue focus:ring-pepe-blue"
                      />
                      Obligatorio
                    </label>
                  </div>
                  {f.tipo === "opciones" && (
                    <OpcionesEditor
                      opciones={f.opciones ?? []}
                      onChange={(ops) => editar(f.key, { opciones: ops })}
                    />
                  )}
                </div>
              ))}
            </div>

            <div className="mt-4 flex flex-wrap items-center gap-3">
              <button
                type="button"
                onClick={() => {
                  setOk(false);
                  setFilas((prev) => [...prev, { key: uuid(), tipo: "numero", etiqueta: "", unidad: "", opciones: [], obligatorio: true }]);
                }}
                className="rounded-xl border border-pepe-blue/40 bg-blue-50/50 px-4 py-2.5 text-sm font-bold text-pepe-blue"
              >
                + Agregar requisito
              </button>
              <span className="flex-1" />
              <button
                type="button"
                disabled={guardar.isPending || invalidas.length > 0}
                onClick={() => guardar.mutate()}
                className="rounded-xl bg-pepe-yellow px-6 py-2.5 text-sm font-bold text-slate-900 disabled:opacity-40"
              >
                {guardar.isPending ? "Guardando…" : `Guardar ${categoria}`}
              </button>
            </div>
            {invalidas.length > 0 && (
              <p className="mt-2 text-xs text-rose-600">
                Completá la etiqueta de cada requisito (y al menos 2 opciones en los de tipo Opciones).
              </p>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function OpcionesEditor({ opciones, onChange }: { opciones: string[]; onChange: (ops: string[]) => void }) {
  const [nueva, setNueva] = useState("");
  function agregar() {
    const v = nueva.trim();
    if (!v || opciones.includes(v)) return;
    onChange([...opciones, v]);
    setNueva("");
  }
  return (
    <div className="mt-2">
      <div className="flex flex-wrap items-center gap-2">
        {opciones.map((op) => (
          <span key={op} className="inline-flex items-center gap-1.5 rounded-full bg-slate-100 px-3 py-1.5 text-sm font-semibold text-slate-700">
            {op}
            <button type="button" onClick={() => onChange(opciones.filter((o) => o !== op))} className="text-slate-400 hover:text-rose-500" aria-label={`Quitar ${op}`}>×</button>
          </span>
        ))}
        <input
          value={nueva}
          onChange={(e) => setNueva(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); agregar(); } }}
          placeholder="Opción nueva…"
          className="w-40 rounded-lg border border-pepe-border px-3 py-1.5 text-sm outline-none focus:border-pepe-blue"
        />
        <button type="button" onClick={agregar} className="rounded-lg border border-pepe-border px-3 py-1.5 text-sm font-bold text-slate-600">+</button>
      </div>
    </div>
  );
}
