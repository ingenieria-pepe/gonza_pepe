import type { RequisitosAplicables } from "../../../shared/api/piecamion";
import { CategoriaFotos } from "./CategoriaFotos";

interface Props {
  /** Requisitos activos de las frutas presentes en la mercadería (del back). */
  grupos: RequisitosAplicables[];
  /** Respuestas del operario, keyed por requisito_id (working store del form). */
  valores: Record<number, string>;
  onValor: (requisitoId: number, valor: string) => void;
  /** Fotos por slug (`req-<id>`), el mismo store fotos_cat del form. */
  fotosCat: Record<string, string[]>;
  onFotos: (slug: string, fotos: string[]) => void;
  /** true después del primer intento de guardar → pinta lo obligatorio vacío. */
  intento: boolean;
}

/**
 * Sección "Requisitos por fruta" del form (mig 0092): lo que el ING. AGRÓNOMO
 * configuró para cada fruta presente en la mercadería. Una tarjeta por fruta;
 * cada requisito rinde según su tipo (número con unidad / texto libre /
 * opciones como botones grandes / foto con la misma fila de fotos del pie).
 */
export function RequisitosFruta({ grupos, valores, onValor, fotosCat, onFotos, intento }: Props) {
  if (grupos.length === 0) return null;
  return (
    <section className="mt-6">
      <h2 className="font-semibold text-slate-800 mb-1">Requisitos por fruta</h2>
      <p className="text-xs text-slate-500 mb-3">
        Controles que pide el ing. agrónomo para la fruta de este camión.
      </p>
      <div className="space-y-4">
        {grupos.map((grupo) => (
          <article key={grupo.categoria} className="rounded-xl border border-pepe-border bg-white p-4">
            <div className="flex items-center gap-2.5 mb-3">
              <img src={`/categorias/${grupo.icono}.svg`} alt="" className="w-8 h-8 object-contain" />
              <h3 className="font-bold text-slate-900">{grupo.categoria}</h3>
            </div>
            <div className="space-y-4">
              {grupo.requisitos.map((req) => {
                const valor = valores[req.id] ?? "";
                const fotos = fotosCat[`req-${req.id}`] ?? [];
                const falta = intento && req.obligatorio
                  && (req.tipo === "foto" ? fotos.length === 0 : !valor.trim());
                return (
                  <div key={req.id} id={`f-req-${req.id}`} className={falta ? "rounded-lg ring-2 ring-rose-300 p-2 -m-2" : ""}>
                    <label className="block text-sm font-medium text-slate-700 mb-1">
                      {req.etiqueta}
                      {req.obligatorio && <span className="text-rose-500"> *</span>}
                    </label>
                    {req.tipo === "numero" && (
                      <div className="flex items-center gap-2">
                        <input
                          type="text"
                          inputMode="decimal"
                          value={valor}
                          onChange={(e) => onValor(req.id, e.target.value)}
                          placeholder="0"
                          className="w-36 rounded-lg border border-pepe-border px-3 py-2.5 text-right text-lg font-bold tabular-nums outline-none focus:border-pepe-blue focus:ring-4 focus:ring-pepe-blue/10"
                        />
                        {req.unidad && <span className="text-sm font-semibold text-slate-500">{req.unidad}</span>}
                      </div>
                    )}
                    {req.tipo === "texto" && (
                      <textarea
                        value={valor}
                        onChange={(e) => onValor(req.id, e.target.value)}
                        rows={2}
                        maxLength={1000}
                        className="w-full resize-y rounded-lg border border-pepe-border px-3 py-2.5 outline-none focus:border-pepe-blue focus:ring-4 focus:ring-pepe-blue/10"
                      />
                    )}
                    {req.tipo === "opciones" && (
                      <div className="flex flex-wrap gap-2">
                        {req.opciones.map((op) => (
                          <button
                            key={op}
                            type="button"
                            onClick={() => onValor(req.id, valor === op ? "" : op)}
                            className={`rounded-xl border-2 px-4 py-2.5 text-sm font-bold transition ${
                              valor === op
                                ? "border-pepe-blue bg-pepe-blue text-white"
                                : "border-pepe-border bg-white text-slate-600 active:bg-slate-50"
                            }`}
                          >
                            {op}
                          </button>
                        ))}
                      </div>
                    )}
                    {req.tipo === "foto" && (
                      <div className="-my-2">
                        <CategoriaFotos
                          label={fotos.length === 0 ? "Sacar la foto" : "Foto cargada"}
                          value={fotos}
                          onChange={(nuevas) => onFotos(`req-${req.id}`, nuevas)}
                        />
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}
