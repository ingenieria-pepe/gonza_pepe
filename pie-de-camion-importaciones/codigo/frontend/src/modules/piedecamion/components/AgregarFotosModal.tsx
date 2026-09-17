import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { CategoriaFotos } from "./CategoriaFotos";
import { todosLosSlots } from "../fotoCategorias";
import { agregarFotosPieCamion } from "../../../shared/api/piecamion";

const SLOTS = todosLosSlots();
const OTRAS = "__otras__";

/**
 * Agregar fotos a un pie de camión YA ENVIADO (celu desde el Historial, PC desde
 * Ingresos). Las fotos se ANEXAN al final del PDF de fotos, con un título que
 * dice cuándo y quién las sumó — así el informe no aparenta que se tomaron en la
 * recepción.
 *
 * Una tanda = una categoría. Es a propósito: el caso real es "sacamos 3 fotos más
 * de la fruta de atrás", y un formulario con las 25 categorías acá sería la misma
 * pared que el pie completo. Para otra categoría, se agrega de nuevo.
 */
export function AgregarFotosModal({
  pie,
  onClose,
}: {
  pie: { id: number; placa_camion?: string | null; chofer_nombre?: string | null };
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [slug, setSlug] = useState<string>(OTRAS);
  const [fotos, setFotos] = useState<string[]>([]);
  const [nota, setNota] = useState("");
  const [error, setError] = useState<string | null>(null);

  const slot = SLOTS.find((s) => s.slug === slug);
  const label = slot ? slot.pdf : "Otras fotos";

  const enviar = useMutation({
    mutationFn: () =>
      agregarFotosPieCamion(pie.id, {
        // Categorizadas van con su slug + el título que usa el informe; las
        // "Otras fotos" viajan en la galería libre (mismo formato que el create).
        fotos_categoria: slot ? fotos.map((f) => ({ categoria: slot.slug, label: slot.pdf, foto: f })) : [],
        fotos: slot ? [] : fotos,
        nota: nota.trim() || undefined,
      }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["pie-camion"] });
      qc.invalidateQueries({ queryKey: ["pie-camion-pendientes"] });
      qc.invalidateQueries({ queryKey: ["ingresos"] });
      onClose();
    },
    onError: (e: Error) => setError(e.message),
  });

  return (
    <div className="fixed inset-0 z-[80] flex items-end sm:items-center justify-center bg-black/40 p-0 sm:p-4">
      <div className="w-full sm:max-w-lg max-h-[92dvh] flex flex-col rounded-t-2xl sm:rounded-2xl bg-white shadow-2xl overflow-hidden">
        <div className="shrink-0 px-4 py-3 border-b border-pepe-border">
          <h3 className="font-bold text-slate-900 text-lg">Agregar fotos al pie #{pie.id}</h3>
          <p className="text-xs text-slate-500 mt-0.5">
            {pie.placa_camion || "—"}
            {pie.chofer_nombre ? ` · ${pie.chofer_nombre}` : ""}
          </p>
          <p className="mt-2 rounded bg-amber-50 border border-amber-200 px-2.5 py-1.5 text-xs text-amber-900">
            Se suman al final del informe, con la fecha y tu nombre. Las fotos que ya
            están <strong>no se pueden borrar ni cambiar de orden</strong>.
          </p>
        </div>

        <div className="flex-1 min-h-0 overflow-y-auto px-4 py-3 space-y-3">
          <label className="block">
            <span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">
              ¿De qué son estas fotos?
            </span>
            <select
              value={slug}
              onChange={(e) => setSlug(e.target.value)}
              className="mt-1 w-full rounded-lg border border-pepe-border px-3 py-2.5 text-base bg-white"
            >
              <option value={OTRAS}>Otras fotos</option>
              {SLOTS.map((s) => (
                <option key={s.slug} value={s.slug}>{s.pdf}</option>
              ))}
            </select>
          </label>

          <div className="rounded-lg border border-pepe-border p-2">
            <CategoriaFotos label={label} value={fotos} onChange={setFotos} disabled={enviar.isPending} />
          </div>

          <label className="block">
            <span className="block text-xs font-semibold uppercase tracking-wide text-slate-500">
              Motivo (opcional)
            </span>
            <input
              type="text"
              value={nota}
              onChange={(e) => setNota(e.target.value)}
              maxLength={200}
              placeholder="Ej.: nos faltó el pallet del fondo"
              className="mt-1 w-full rounded-lg border border-pepe-border px-3 py-2.5 text-base"
            />
          </label>

          {error && (
            <div className="rounded border border-red-300 bg-red-100 px-3 py-2 text-sm text-red-900">{error}</div>
          )}
        </div>

        <div className="shrink-0 px-4 py-3 border-t border-pepe-border flex items-center gap-2">
          <button
            onClick={onClose}
            disabled={enviar.isPending}
            className="rounded-lg border border-pepe-border px-4 py-2.5 text-sm font-semibold text-slate-600 disabled:opacity-50"
          >
            Cancelar
          </button>
          <div className="flex-1" />
          <button
            onClick={() => enviar.mutate()}
            disabled={enviar.isPending || fotos.length === 0}
            className="rounded-lg bg-pepe-yellow px-5 py-2.5 text-sm font-bold text-pepe-blue shadow disabled:opacity-50"
          >
            {enviar.isPending
              ? "Subiendo…"
              : `Agregar ${fotos.length || ""} foto${fotos.length === 1 ? "" : "s"}`.trim()}
          </button>
        </div>
      </div>
    </div>
  );
}
