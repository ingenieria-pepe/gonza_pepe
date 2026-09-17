import { useState } from "react";
import { CameraCapture } from "../../../shared/components/CameraCapture";
import { ImageLightbox } from "../../../shared/components/ImageLightbox";
import { compressImage } from "../../../shared/components/PhotoUploader";

interface Props {
  /** Etiqueta de la fila (categoría). */
  label: string;
  /** Data URIs de las fotos de esta categoría. */
  value: string[];
  onChange: (fotos: string[]) => void;
  maxSize?: number;
  quality?: number;
  disabled?: boolean;
}

/**
 * Fila compacta para subir fotos de UNA categoría del pie de camión.
 * Layout: etiqueta a la izquierda, botones Cámara + Galería a la derecha, y las
 * miniaturas debajo. Reusa la compresión, la cámara in-app (FKB) y el lightbox del
 * PhotoUploader, pero en formato chico para poder apilar ~25 categorías sin que sea
 * una pared. Cámara: si hay getUserMedia (FKB) abre el visor multi-disparo; si no,
 * capture nativo. Galería: input `multiple` para elegir varias ya sacadas.
 */
export function CategoriaFotos({ label, value, onChange, maxSize = 1280, quality = 0.75, disabled }: Props) {
  const [busy, setBusy] = useState(false);
  const [cameraOpen, setCameraOpen] = useState(false);
  const [zoom, setZoom] = useState<string | null>(null);
  const [supportsGUM] = useState(
    () =>
      typeof navigator !== "undefined" &&
      !!navigator.mediaDevices &&
      typeof navigator.mediaDevices.getUserMedia === "function",
  );

  async function onFiles(files: FileList | null) {
    if (!files || files.length === 0) return;
    setBusy(true);
    try {
      const added: string[] = [];
      for (const f of Array.from(files)) {
        try {
          added.push(await compressImage(f, maxSize, quality));
        } catch {
          // foto ilegible → la salteamos
        }
      }
      if (added.length) onChange([...value, ...added]);
    } finally {
      setBusy(false);
    }
  }

  function removeAt(idx: number) {
    onChange(value.filter((_, i) => i !== idx));
  }

  const btn =
    "px-2.5 py-1.5 min-h-[36px] rounded border border-pepe-blue/40 bg-pepe-blue/5 text-pepe-blue text-xs font-medium inline-flex items-center gap-1 " +
    (busy || disabled ? "opacity-40 cursor-not-allowed" : "cursor-pointer hover:bg-pepe-blue/10");

  return (
    <div className="py-2">
      <div className="flex items-center justify-between gap-2">
        {/* La etiqueta SE ENVUELVE (break-words), no se trunca: en el celo angosto
            los dos botones se comían el ancho y el texto se cortaba a "Foto de…". */}
        <span className="text-sm text-slate-700 min-w-0 break-words leading-snug">
          {label}
          {value.length > 0 && (
            <span className="ml-1.5 inline-block align-middle text-[10px] font-semibold text-emerald-700 bg-emerald-50 border border-emerald-200 rounded-full px-1.5">
              {value.length}
            </span>
          )}
        </span>
        <div className="flex items-center gap-1.5 shrink-0">
          {/* Cámara: visor in-app (FKB) o capture nativo. */}
          {supportsGUM ? (
            <button type="button" onClick={() => setCameraOpen(true)} disabled={busy || disabled} className={btn}>
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
                <path strokeLinecap="round" strokeLinejoin="round" d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
              Cámara
            </button>
          ) : (
            <label className={btn}>
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z" />
                <path strokeLinecap="round" strokeLinejoin="round" d="M15 13a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
              Cámara
              <input
                type="file"
                accept="image/*"
                capture="environment"
                className="hidden"
                disabled={busy || disabled}
                onChange={(e) => {
                  const el = e.currentTarget;
                  void onFiles(el.files).finally(() => { el.value = ""; });
                }}
              />
            </label>
          )}
          {/* Galería: varias ya sacadas. */}
          <label className={btn}>
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M2.25 15.75l5.159-5.159a2.25 2.25 0 013.182 0l5.159 5.159m-1.5-1.5l1.409-1.409a2.25 2.25 0 013.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 001.5-1.5V6a1.5 1.5 0 00-1.5-1.5H3.75A1.5 1.5 0 002.25 6v12a1.5 1.5 0 001.5 1.5z" />
            </svg>
            Galería
            <input
              type="file"
              accept="image/*"
              multiple
              className="hidden"
              disabled={busy || disabled}
              onChange={(e) => {
                const el = e.currentTarget;
                void onFiles(el.files).finally(() => { el.value = ""; });
              }}
            />
          </label>
        </div>
      </div>

      {value.length > 0 && (
        <div className="grid grid-cols-4 sm:grid-cols-6 gap-1.5 mt-2">
          {value.map((dataUri, idx) => (
            <div key={idx} className="relative aspect-[4/3] rounded border border-pepe-border overflow-hidden bg-slate-100">
              <img
                src={dataUri}
                className="w-full h-full object-cover cursor-zoom-in"
                alt={`${label} ${idx + 1}`}
                onClick={() => setZoom(dataUri)}
              />
              <button
                type="button"
                onClick={() => removeAt(idx)}
                disabled={busy || disabled}
                title="Quitar foto"
                className="absolute top-0.5 right-0.5 w-7 h-7 sm:w-6 sm:h-6 rounded-full bg-black/70 text-white inline-flex items-center justify-center hover:bg-rose-600 disabled:opacity-50"
              >
                <svg className="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
          ))}
        </div>
      )}

      {supportsGUM && (
        <CameraCapture
          open={cameraOpen}
          onClose={() => setCameraOpen(false)}
          onCapture={(fotos) => { if (fotos.length) onChange([...value, ...fotos]); }}
          maxSize={maxSize}
          quality={quality}
        />
      )}

      <ImageLightbox src={zoom} onClose={() => setZoom(null)} />
    </div>
  );
}
