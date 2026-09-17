import { useState } from "react";
import { useMutation } from "@tanstack/react-query";
import {
  recontarRecepcionViaje,
  abrirInformeRecepcionViaje,
  type RecepcionViajeResultado,
  type ViajePendienteRecepcion,
} from "../../../shared/api/stock";
import { useAuth } from "../../../shared/AuthContext";
import { AjustarSalidaModal } from "../../stock/AjustarSalidaModal";

/** Resultado de la recepción CIEGA de un viaje CR→ZAC (26/08): verde si lo
 * contado coincide con lo que CR declaró; alerta ROJA con la tabla de
 * diferencias si no (lo resuelven entre ellos). Link al informe PDF.
 *
 * Con diferencia hay dos caminos (dueño 27/08), los DOS disponibles a la vez
 * — recontar es una opción, no un requisito:
 *  · «Volver a contar» — si pudo errar la cuenta: descarta el conteo y el
 *    viaje vuelve al picker.
 *  · «Volver a contar» — descarta el conteo y el viaje vuelve al picker.
 *
 * Y aparte, coincida o no: «Confirmar el ingreso a ZAC», que CREA el 400 con lo
 * contado (y corrige el 190 si hubo diferencia). Requiere permiso de Macrosoft:
 * el receptor normalmente no lo tiene y lo confirma después el back-office
 * desde Ingresos.
 */
export function ResultadoRecepcionViaje({
  viaje,
  resultado,
  onClose,
  onRecontar,
}: {
  viaje: ViajePendienteRecepcion;
  resultado: RecepcionViajeResultado;
  onClose: () => void;
  /** Vuelve al conteo con el viaje elegido y el formulario en blanco. */
  onRecontar?: () => void;
}) {
  const { hasPermission } = useAuth();
  const [popup, setPopup] = useState(false);
  const [ajustado, setAjustado] = useState(false);
  const recuento = useMutation({
    mutationFn: () => recontarRecepcionViaje(resultado.recepcion_id),
    onSuccess: () => onRecontar?.(),
  });
  const puedeAjustar = !resultado.coincide && hasPermission("ingreso_macrosoft");

  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-lg rounded-xl bg-white p-5 shadow-2xl space-y-4">
        <h3 className="text-lg font-bold text-slate-900">
          Viaje {viaje.numero_del_dia} · {viaje.fecha}
          {resultado.intento > 1 && (
            <span className="ml-2 rounded-full bg-slate-100 px-2 py-0.5 text-[11px] font-semibold text-slate-500">
              {resultado.intento}º conteo
            </span>
          )}
        </h3>
        {resultado.coincide ? (
          <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-3 text-emerald-800 font-semibold">
            Todo coincide: lo recibido es igual a lo que CR declaró.
          </div>
        ) : (
          <div className="rounded-lg border-2 border-red-300 bg-red-50 px-4 py-3 space-y-2">
            <div className="font-bold text-red-800">
              NO COINCIDE con lo declarado por CR — avisale al puesto:
            </div>
            <table className="w-full text-sm">
              <thead className="text-[11px] uppercase text-red-700">
                <tr>
                  <th className="text-left py-1">Producto</th>
                  <th className="text-right">Declarado</th>
                  <th className="text-right">Recibido</th>
                  <th className="text-right">Dif.</th>
                </tr>
              </thead>
              <tbody>
                {resultado.diferencias.map((d) => (
                  <tr key={d.cod_art} className="text-red-900">
                    <td className="py-0.5">{d.descripcion.trim()}</td>
                    <td className="text-right font-mono">{d.declarado}</td>
                    <td className="text-right font-mono">{d.recibido}</td>
                    <td className="text-right font-mono font-bold">
                      {d.diferencia > 0 ? "+" : ""}{d.diferencia}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {/* Confirmar el ingreso va SIEMPRE, coincida o no: es el paso que crea
            el 400 —lo que entra a ZAC— con lo que se contó acá. Antes aparecía
            sólo con diferencia, porque era "ajustar la salida"; con el flujo
            nuevo, un viaje que llegó completo nunca habría entrado a stock. */}
        {!ajustado && puedeAjustar && (
          <div className="space-y-1">
            <button
              onClick={() => setPopup(true)}
              className="w-full rounded-lg border-2 border-emerald-500 bg-emerald-100 px-4 py-3 text-base font-bold text-emerald-900 active:brightness-95"
            >
              Confirmar el ingreso a ZAC
            </button>
            <p className="text-[11px] leading-snug text-slate-500">
              Crea el 400 en Macrosoft con lo que contaste
              {!resultado.coincide && " y corrige el 190 de CR a lo que llegó"}.
              Te muestra qué va a hacer antes.
            </p>
          </div>
        )}

        {!resultado.coincide && !ajustado && (
          <div className="space-y-2">
            <div className="space-y-1">
              <button
                onClick={() => {
                  // Descartar el conteo borra lo cargado (fotos y observaciones
                  // incluidas): se pregunta antes, no hay vuelta atrás.
                  if (window.confirm(
                    "Se descarta este conteo y empezás de cero: se pierden las fotos y " +
                    "observaciones que cargaste. ¿Volver a contar?",
                  )) recuento.mutate();
                }}
                disabled={recuento.isPending}
                className="w-full rounded-lg border-2 border-pepe-blue bg-white px-4 py-3 text-base font-bold text-pepe-blue active:bg-pepe-blue/5 disabled:opacity-50"
              >
                {recuento.isPending ? "Volviendo…" : "Volver a contar"}
              </button>
              <p className="text-[11px] leading-snug text-slate-500">
                Si pudiste haber errado la cuenta: se descarta este conteo y el viaje
                vuelve a la lista para contarlo de nuevo.
              </p>
              {recuento.isError && (
                <p className="text-xs font-semibold text-red-700">{(recuento.error as Error).message}</p>
              )}
            </div>
          </div>
        )}

        {ajustado && (
          <div className="rounded-lg border border-emerald-200 bg-emerald-50 px-4 py-2.5 text-sm font-semibold text-emerald-800">
            Ingresado a ZAC: el 400 quedó en Macrosoft con lo que contaste.
          </div>
        )}

        <div className="flex justify-between items-center">
          <button
            onClick={() => void abrirInformeRecepcionViaje(resultado.recepcion_id)}
            className="text-sm font-semibold text-pepe-blue hover:underline"
          >
            Ver informe PDF
          </button>
          <button
            onClick={onClose}
            className="rounded-lg bg-pepe-blue px-5 py-2.5 text-sm font-bold text-white"
          >
            Listo
          </button>
        </div>
      </div>

      {popup && (
        <AjustarSalidaModal
          recepcionId={resultado.recepcion_id}
          onClose={() => setPopup(false)}
          onAjustado={() => { setAjustado(true); setPopup(false); }}
        />
      )}
    </div>
  );
}
