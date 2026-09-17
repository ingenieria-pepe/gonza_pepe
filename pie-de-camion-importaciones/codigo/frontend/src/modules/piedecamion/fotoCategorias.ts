import type { FotoCategoria } from "../../shared/api/piecamion";

// Árbol de categorías de fotos del pie de camión. Es la ÚNICA fuente de verdad:
// alimenta el formulario (qué slots se muestran y en qué orden) y define el
// `label` completo que viaja al back → informe PDF (agrupado por categoría).
//
// Un "slot" = un lugar donde se suben fotos. `slug` es el id estable (va a la
// columna `categoria`), `fila` es la etiqueta corta en el form, `pdf` es el
// título completo (con contexto de posición) que se ve en el informe.

export interface FotoSlot {
  slug: string;
  fila: string;   // etiqueta en la fila del formulario
  pdf: string;    // título completo para el informe PDF
}

export interface FotoSubgrupo {
  titulo: string;      // sub-encabezado (posición): Adelante / Medio / Atrás
  slots: FotoSlot[];
}

export interface FotoSeccion {
  titulo: string;
  ayuda?: string;              // texto de ayuda opcional bajo el título
  slots?: FotoSlot[];          // slots directos (sin sub-grupos)
  subgrupos?: FotoSubgrupo[];  // sub-grupos por posición (Estado de la fruta)
}

// Detalles que se fotografían de la fruta EN CADA POSICIÓN. El código de producto
// NO va acá: se pide una sola vez (slot suelto al final de la sección).
const DETALLES_FRUTA = [
  { sfx: "caja", label: "Caja abierta" },
  { sfx: "corona", label: "Corona" },
  { sfx: "calibre", label: "Calibre" },
  { sfx: "longitud", label: "Longitud" },
];

// Posición → slug sin acentos (para el id estable de la columna).
const POSICIONES: { titulo: string; slug: string }[] = [
  { titulo: "Adelante", slug: "adelante" },
  { titulo: "Medio", slug: "medio" },
  { titulo: "Atrás", slug: "atras" },
];

export const FOTO_SECCIONES: FotoSeccion[] = [
  { titulo: "Temperatura container", slots: [{ slug: "temp_container", fila: "Display del equipo", pdf: "Temperatura container" }] },
  { titulo: "Ticket del peaje", slots: [{ slug: "ticket_peaje", fila: "Ticket", pdf: "Ticket del peaje" }] },
  { titulo: "Puerta del camión (matrícula)", slots: [{ slug: "puerta_matricula", fila: "Con la matrícula", pdf: "Puerta del camión (matrícula)" }] },
  {
    titulo: "Temperaturas pulpa",
    ayuda: "Foto del termómetro en cada posición.",
    slots: [
      { slug: "pulpa_adelante", fila: "Adelante", pdf: "Temperaturas pulpa · Adelante" },
      { slug: "pulpa_medio", fila: "Medio", pdf: "Temperaturas pulpa · Medio" },
      { slug: "pulpa_atras", fila: "Atrás", pdf: "Temperaturas pulpa · Atrás" },
    ],
  },
  { titulo: "Estado del pallet", ayuda: "Incluí el sello de fumigación (abajo).", slots: [{ slug: "pallet", fila: "Pallet + sello", pdf: "Estado del pallet (sello fumigación)" }] },
  { titulo: "Balanza", ayuda: "Que se vea clara la mercadería y el peso.", slots: [{ slug: "balanza", fila: "Balanza + peso", pdf: "Balanza (mercadería + peso)" }] },
  {
    titulo: "Estado de la fruta",
    ayuda: "En cada posición: caja abierta, corona, calibre y longitud. El código de la caja va una sola vez, al final.",
    subgrupos: POSICIONES.map((pos) => ({
      titulo: pos.titulo,
      slots: DETALLES_FRUTA.map((d) => ({
        slug: `fruta_${pos.slug}_${d.sfx}`,
        fila: d.label,
        pdf: `Estado fruta · ${pos.titulo} · ${d.label}`,
      })),
    })),
    // Código de producto en la caja: UNA sola vez (no por posición).
    slots: [{ slug: "fruta_codigo", fila: "Código de producto en la caja", pdf: "Estado fruta · Código en la caja" }],
  },
];

/** Todos los slots aplanados en orden canónico (para iterar el store). Una sección
 *  puede tener AMBOS subgrupos y slots directos (ej. Estado de la fruta: las 3
 *  posiciones + el código suelto) → primero las posiciones, después los sueltos,
 *  igual que el orden en que se renderizan y en que van al PDF. */
export function todosLosSlots(): FotoSlot[] {
  return FOTO_SECCIONES.flatMap((s) => [
    ...(s.subgrupos?.flatMap((g) => g.slots) ?? []),
    ...(s.slots ?? []),
  ]);
}

/** Transforma el working store `fotos_cat` (Record<slug, dataURIs>) en la lista
 *  `fotos_categoria` en orden canónico que espera el back. */
export function buildFotosCategoria(fotosCat: Record<string, string[]> | undefined): FotoCategoria[] {
  const cat = fotosCat ?? {};
  const out: FotoCategoria[] = [];
  for (const slot of todosLosSlots()) {
    for (const foto of cat[slot.slug] ?? []) {
      out.push({ categoria: slot.slug, label: slot.pdf, foto });
    }
  }
  return out;
}

/** ¿Hay al menos una foto categorizada cargada? (para el borrador). */
export function tieneFotosCat(fotosCat: Record<string, string[]> | undefined): boolean {
  const cat = fotosCat ?? {};
  return Object.values(cat).some((arr) => arr && arr.length > 0);
}
