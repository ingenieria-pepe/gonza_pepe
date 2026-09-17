// @vitest-environment jsdom
/** Requisitos por fruta (mig 0092): la sección dinámica del form del pie y la
 *  regla de faltantes. Lo que configura el ing. agrónomo se pide al operario. */
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { RequisitosFruta } from "./components/RequisitosFruta";
import { faltantesDelPie } from "./PieDeCamionPage";
import type { PieDeCamionCreate, RequisitosAplicables } from "../../shared/api/piecamion";

afterEach(cleanup);

const GRUPOS: RequisitosAplicables[] = [{
  categoria: "Kiwi",
  icono: "kiwi",
  requisitos: [
    { id: 1, categoria: "Kiwi", tipo: "numero", etiqueta: "Presión de pulpa", unidad: "kgf", opciones: [], obligatorio: true, orden: 0, activo: true },
    { id: 2, categoria: "Kiwi", tipo: "opciones", etiqueta: "Estado de la cáscara", unidad: null, opciones: ["Sana", "Dañada"], obligatorio: true, orden: 1, activo: true },
    { id: 3, categoria: "Kiwi", tipo: "foto", etiqueta: "Foto de la pulpa", unidad: null, opciones: [], obligatorio: true, orden: 2, activo: true },
  ],
}];

describe("RequisitosFruta (sección del form)", () => {
  it("rinde cada tipo: número con unidad, opciones como botones y foto", () => {
    const onValor = vi.fn();
    render(
      <RequisitosFruta grupos={GRUPOS} valores={{}} onValor={onValor} fotosCat={{}} onFotos={vi.fn()} intento={false} />,
    );
    expect(screen.getByText("Kiwi")).toBeTruthy();
    expect(screen.getByText("kgf")).toBeTruthy();

    fireEvent.click(screen.getByRole("button", { name: "Sana" }));
    expect(onValor).toHaveBeenCalledWith(2, "Sana");

    // El slot de foto usa la fila de fotos del pie (botón Cámara/Galería)
    expect(screen.getByText("Foto de la pulpa")).toBeTruthy();
    expect(screen.getAllByText(/Cámara/).length).toBeGreaterThan(0);
  });

  it("sin grupos no rinde nada (banana sin config: el form no cambia)", () => {
    const { container } = render(
      <RequisitosFruta grupos={[]} valores={{}} onValor={vi.fn()} fotosCat={{}} onFotos={vi.fn()} intento={false} />,
    );
    expect(container.innerHTML).toBe("");
  });
});

describe("faltantesDelPie con requisitos", () => {
  const base = {
    fecha: "2026-08-19", chofer_nombre: "Chofer", placa_camion: "ABC123",
    codigo_importador_camion: "FH-001", palet_rating: 5, cajas_rating: 5,
    flejes_rating: 5, lineas: [], fotos: [], requisitos_valores: {}, fotos_cat: {},
  } as unknown as PieDeCamionCreate;
  const linea = { cod_art: "080301", cantidad: 10, hay_reclamos: false, defectos: [], descripcion: "Kiwi", icono: "kiwi" };

  it("lista los obligatorios sin responder, con la fruta adelante", () => {
    const faltas = faltantesDelPie(base, [linea], false, GRUPOS);
    const textos = faltas.map((f) => f.que);
    expect(textos).toContain("Kiwi: Presión de pulpa");
    expect(textos).toContain("Kiwi: Foto de la pulpa (foto)");
  });

  it("respondidos y con foto, desaparecen", () => {
    const form = {
      ...base,
      requisitos_valores: { 1: "6,5", 2: "Sana" },
      fotos_cat: { "req-3": ["data:image/jpeg;base64,x"] },
    } as unknown as PieDeCamionCreate;
    const faltas = faltantesDelPie(form, [linea], false, GRUPOS);
    expect(faltas.filter((f) => f.id.startsWith("f-req-"))).toEqual([]);
  });

  it("en edición, la foto ya guardada en el pie cuenta como cumplida", () => {
    const faltas = faltantesDelPie(
      { ...base, requisitos_valores: { 1: "6", 2: "Sana" } } as unknown as PieDeCamionCreate,
      [linea], true, GRUPOS, new Set([3]),
    );
    expect(faltas.filter((f) => f.id.startsWith("f-req-"))).toEqual([]);
  });
});
