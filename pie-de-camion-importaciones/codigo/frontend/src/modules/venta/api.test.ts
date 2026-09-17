import { describe, expect, it } from "vitest";
import {
  disponibleConBorrador,
  errorLegible,
  indexarDisponible,
  type StockDisponibleResp,
} from "./api";
import { API_URL } from "../../api/client";

// venta/api.ts importa api/client.ts, que evalúa API_URL en el top-level del
// módulo. En node (sin window) tiene que caer al fallback localhost y NO
// explotar el import — este archivo entero es la verificación de que se puede
// importar bajo entorno node.

describe("gotcha: api/client importable en node", () => {
  it("API_URL resuelve a localhost sin window", () => {
    expect(API_URL).toBe("http://localhost:8000");
  });
});

// Regla R363: los errores del back se muestran vía errorLegible (extrae el
// detail del JSON), nunca el "API 409 Conflict: {...}" crudo.
// Regla R152 (borde front): YA_FACTURADO: es un MARCADOR para el auto-switch
// a encadenar, no un texto para el usuario — errorLegible lo pela.
describe("errorLegible (venta)", () => {
  it("extrae el detail del formato real de client.ts [R363]", () => {
    const msg = 'API 400 Bad Request: {"detail":"El cliente no existe"}';
    expect(errorLegible(msg)).toBe("El cliente no existe");
  });

  it("pela el marcador YA_FACTURADO: (es para el front, no para el usuario) [R152]", () => {
    const msg = 'API 409 Conflict: {"detail":"YA_FACTURADO: el pedido ya salió de caja"}';
    expect(errorLegible(msg)).toBe("el pedido ya salió de caja");
  });

  it("sin detail extraíble devuelve el mensaje tal cual", () => {
    expect(errorLegible("Failed to fetch")).toBe("Failed to fetch");
    // detail no-string (validación de FastAPI) → no matchea la regex → crudo.
    const validacion = 'API 422 Unprocessable Entity: {"detail":[{"loc":["body"]}]}';
    expect(errorLegible(validacion)).toBe(validacion);
  });
});

// ── Stock disponible del tomador ─────────────────────────────────────────
// Regla R317 (lado front): el disponible es POR FAMILIA (cod_stock) — el
// saldo por color es ficción. Dos variantes de la misma banana en el borrador
// comen del MISMO pozo. Y desconocido → null, NUNCA cero (cero bloquearía la
// venta de un artículo que quizás tiene stock de sobra).

const resp = (
  arts: { cod_art: string; cod_stock: string; disponible: number }[],
): StockDisponibleResp => ({
  generado_en: "2026-08-13T06:00:00",
  macrosoft_actualizado_en: "2026-08-13T05:59:00",
  disponible: arts.map((a, i) => ({
    ...a,
    familia: null,
    saldo_familia: a.disponible,
    comprometido: 0,
    pedidos_pendientes: 0,
    ranking: i + 1,
  })),
});

describe("indexarDisponible", () => {
  it("indexa por cod_art guardando disponible y cod_stock (la familia)", () => {
    const idx = indexarDisponible(
      resp([{ cod_art: "010101", cod_stock: "0101", disponible: 120 }]),
    );
    expect(idx["010101"]).toEqual({ disponible: 120, codStock: "0101" });
  });

  it("respuesta undefined (query sin datos aún) → índice vacío", () => {
    expect(indexarDisponible(undefined)).toEqual({});
  });
});

describe("disponibleConBorrador", () => {
  // Banana Color 1 y Color 4 comparten familia (pozo "0101"); la naranja no.
  const idx = indexarDisponible(
    resp([
      { cod_art: "010101", cod_stock: "0101", disponible: 100 },
      { cod_art: "010104", cod_stock: "0101", disponible: 100 },
      { cod_art: "050505", cod_stock: "0505", disponible: 50 },
    ]),
  );

  it("resta TODO lo del borrador que comparte familia, no solo el mismo código [R317]", () => {
    const borrador = [
      { cod_art: "010101", cantidad: 10 },
      { cod_art: "010104", cantidad: 5 },
      { cod_art: "050505", cantidad: 3 },
    ];
    // Las dos bananas comen del pozo 0101: 100 − (10+5) = 85, desde cualquiera.
    expect(disponibleConBorrador(idx, "010101", borrador)).toBe(85);
    expect(disponibleConBorrador(idx, "010104", borrador)).toBe(85);
    // La naranja solo descuenta lo suyo.
    expect(disponibleConBorrador(idx, "050505", borrador)).toBe(47);
  });

  it("artículo desconocido → null, NO cero (desconocido no es sin stock) [R317]", () => {
    expect(disponibleConBorrador(idx, "999999", [])).toBeNull();
  });

  it("líneas del borrador de artículos fuera del índice no restan de nadie", () => {
    const borrador = [{ cod_art: "999999", cantidad: 40 }];
    expect(disponibleConBorrador(idx, "010101", borrador)).toBe(100);
  });

  it("negativo legítimo: el residuo del ledger de maduración se devuelve tal cual", () => {
    const negativo = indexarDisponible(
      resp([{ cod_art: "020202", cod_stock: "0202", disponible: -90 }]),
    );
    expect(disponibleConBorrador(negativo, "020202", [])).toBe(-90);
    // Y el borrador lo hunde más — sin clamp a cero.
    expect(
      disponibleConBorrador(negativo, "020202", [{ cod_art: "020202", cantidad: 5 }]),
    ).toBe(-95);
  });

  it("borrador vacío → el disponible del índice sin tocar", () => {
    expect(disponibleConBorrador(idx, "010101", [])).toBe(100);
  });
});
