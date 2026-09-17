import { describe, expect, it } from "vitest";
import {
  FOTO_SECCIONES,
  buildFotosCategoria,
  tieneFotosCat,
  todosLosSlots,
} from "./fotoCategorias";

// Fotos por categoría del pie de camión (memoria
// reference_piedecamion_fotos_categorias, sin ID en el inventario): el orden
// de todosLosSlots ES el orden del fotos-PDF — cambiarlo reordena el informe
// que ya conocen en la oficina. El árbol es la única fuente de verdad: el
// form itera los mismos slots que viajan al back.

// Orden canónico completo. Si esto rompe porque se AGREGÓ un slot, actualizar
// a conciencia (cambia el PDF); si rompe porque se REORDENÓ, revisar primero.
const ORDEN_CANONICO = [
  "temp_container",
  "ticket_peaje",
  "puerta_matricula",
  "pulpa_adelante",
  "pulpa_medio",
  "pulpa_atras",
  "pallet",
  "balanza",
  // Estado de la fruta: primero las 3 posiciones (4 detalles cada una)…
  "fruta_adelante_caja",
  "fruta_adelante_corona",
  "fruta_adelante_calibre",
  "fruta_adelante_longitud",
  "fruta_medio_caja",
  "fruta_medio_corona",
  "fruta_medio_calibre",
  "fruta_medio_longitud",
  "fruta_atras_caja",
  "fruta_atras_corona",
  "fruta_atras_calibre",
  "fruta_atras_longitud",
  // …y el código de producto UNA sola vez, al final.
  "fruta_codigo",
];

describe("todosLosSlots — orden canónico (define el orden del PDF)", () => {
  it("los slugs salen exactamente en el orden canónico", () => {
    expect(todosLosSlots().map((s) => s.slug)).toEqual(ORDEN_CANONICO);
  });

  it("no hay slugs duplicados (el slug es la key estable de la columna)", () => {
    const slugs = todosLosSlots().map((s) => s.slug);
    expect(new Set(slugs).size).toBe(slugs.length);
  });

  it("en la sección con subgrupos Y slots directos, los subgrupos van primero", () => {
    const fruta = FOTO_SECCIONES.find((s) => s.titulo === "Estado de la fruta")!;
    expect(fruta.subgrupos).toBeDefined();
    expect(fruta.slots).toBeDefined();
    const slugs = todosLosSlots().map((s) => s.slug);
    // El código suelto queda DESPUÉS del último detalle de la última posición.
    expect(slugs.indexOf("fruta_codigo")).toBeGreaterThan(slugs.indexOf("fruta_atras_longitud"));
  });

  it("todo slot tiene fila (form) y pdf (título del informe) no vacíos", () => {
    for (const s of todosLosSlots()) {
      expect(s.fila.trim().length, `fila vacía en ${s.slug}`).toBeGreaterThan(0);
      expect(s.pdf.trim().length, `pdf vacío en ${s.slug}`).toBeGreaterThan(0);
    }
  });
});

describe("buildFotosCategoria", () => {
  it("aplana el store en orden canónico, no en el orden del Record", () => {
    // El Record llega con las keys "al revés" a propósito.
    const out = buildFotosCategoria({
      fruta_codigo: ["data:f-codigo"],
      temp_container: ["data:temp-1", "data:temp-2"],
      pallet: ["data:pallet"],
    });
    expect(out.map((f) => f.foto)).toEqual([
      "data:temp-1",
      "data:temp-2",
      "data:pallet",
      "data:f-codigo",
    ]);
  });

  it("cada foto viaja con su slug y el label COMPLETO del PDF", () => {
    const out = buildFotosCategoria({ pulpa_atras: ["data:x"] });
    expect(out).toEqual([
      { categoria: "pulpa_atras", label: "Temperaturas pulpa · Atrás", foto: "data:x" },
    ]);
  });

  it("las fotos de un mismo slot conservan su orden interno", () => {
    const out = buildFotosCategoria({ balanza: ["data:1", "data:2", "data:3"] });
    expect(out.map((f) => f.foto)).toEqual(["data:1", "data:2", "data:3"]);
  });

  it("slugs desconocidos en el store se ignoran (no inventan categoría)", () => {
    expect(buildFotosCategoria({ slot_viejo_borrado: ["data:x"] })).toEqual([]);
  });

  it("store undefined o vacío → lista vacía", () => {
    expect(buildFotosCategoria(undefined)).toEqual([]);
    expect(buildFotosCategoria({})).toEqual([]);
  });
});

describe("tieneFotosCat", () => {
  it("undefined / vacío / arrays vacíos → false", () => {
    expect(tieneFotosCat(undefined)).toBe(false);
    expect(tieneFotosCat({})).toBe(false);
    expect(tieneFotosCat({ pallet: [], balanza: [] })).toBe(false);
  });

  it("con al menos una foto → true (dispara el backup del borrador)", () => {
    expect(tieneFotosCat({ pallet: [], balanza: ["data:x"] })).toBe(true);
  });
});
