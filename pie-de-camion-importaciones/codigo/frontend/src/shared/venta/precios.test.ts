import { describe, expect, it } from "vitest";
import { escalonarPrecio, limitesDeBase, PASO_PRECIO } from "./precios";

// Regla R157 (la parte del front) + pedido del dueño 13/08: el precio se mueve
// de a $50 y los límites −10%/+20% del base siguen siendo DUROS — el último
// paso se recorta para clavarse en el límite, nunca lo pasa.
describe("escalonarPrecio — de a $50 dentro de −10%/+20%", () => {
  // base 1000 → permitido 900–1200 (ceil/floor hacia adentro no juega acá)
  const lim = { min: 900, max: 1200 };

  it("el paso es de $50", () => {
    expect(PASO_PRECIO).toBe(50);
    expect(escalonarPrecio(1000, 1, lim)).toBe(1050);
    expect(escalonarPrecio(1000, -1, lim)).toBe(950);
  });

  it("clava en el límite cuando el paso completo se pasa", () => {
    expect(escalonarPrecio(1180, 1, lim)).toBe(1200);   // +50 daría 1230
    expect(escalonarPrecio(920, -1, lim)).toBe(900);    // −50 daría 870
  });

  it("desde el límite no se mueve más", () => {
    expect(escalonarPrecio(1200, 1, lim)).toBe(1200);
    expect(escalonarPrecio(900, -1, lim)).toBe(900);
  });

  it("un precio tipeado FUERA de rango vuelve al límite con un paso", () => {
    // commitPrecio ya lo recorta al salir del campo, pero si quedó fuera
    // (placeholder viejo, edición a mano), el botón lo trae de vuelta.
    expect(escalonarPrecio(1300, -1, lim)).toBe(1200);
    expect(escalonarPrecio(850, 1, lim)).toBe(900);
  });

  it("sin límites (descuentos / sin base) el paso va pelado", () => {
    expect(escalonarPrecio(500, 1, null)).toBe(550);
    expect(escalonarPrecio(500, -1, null)).toBe(450);
  });

  it("el precio BASE es parada obligada en ambos sentidos (caso banana 13/08)", () => {
    // base 750 → permitido 675–900. Desde 725, "+" NO saltea el base:
    // 725 → 750 → 800 → 850 → 900. Y bajando desde 775: 775 → 750 → 700 → 675.
    const limB = { min: 675, max: 900 };
    expect(escalonarPrecio(725, 1, limB, 750)).toBe(750);
    expect(escalonarPrecio(750, 1, limB, 750)).toBe(800);
    expect(escalonarPrecio(775, -1, limB, 750)).toBe(750);
    expect(escalonarPrecio(750, -1, limB, 750)).toBe(700);
    // Un paso que NO cruza el base sigue normal.
    expect(escalonarPrecio(675, 1, limB, 750)).toBe(725);
  });

  it("con rango más angosto que $50 (bases chicas) igual respeta los bordes", () => {
    // base 300 → permitido 270–360: un paso de 50 siempre choca con un borde.
    const chico = { min: 270, max: 360 };
    expect(escalonarPrecio(300, 1, chico)).toBe(350);
    expect(escalonarPrecio(350, 1, chico)).toBe(360);
    expect(escalonarPrecio(300, -1, chico)).toBe(270);
  });
});

describe("limitesDeBase — rango −10%/+20% hacia adentro", () => {
  it("base 1000 → 900–1200", () => {
    expect(limitesDeBase(1000)).toEqual({ min: 900, max: 1200 });
  });
  it("redondea HACIA ADENTRO con bases chicas (nunca queda fuera de rango)", () => {
    // 85 → min 76,5 sube a 77; max 102 exacto.
    expect(limitesDeBase(85)).toEqual({ min: 77, max: 102 });
  });
  it("sin base (null/0/negativa) → sin límites", () => {
    expect(limitesDeBase(null)).toBeNull();
    expect(limitesDeBase(0)).toBeNull();
    expect(limitesDeBase(-10)).toBeNull();
  });
});
