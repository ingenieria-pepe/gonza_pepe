// @vitest-environment jsdom
/** El picker de «Elegir camión del Plan de Cargas», donde arranca un pie.
 *
 *  Los viajes CR→ZAC pendientes salen arriba con badge VIAJE. Se muestran SÓLO
 *  los de HOY (dueño 2/09): un camión de CR no se queda sin recepcionar, así que
 *  uno de hace tres días es ruido para el que está descargando ahora. Pero no se
 *  esconde en silencio — el contador dice cuántos quedaron atrás. */
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hoyUY } from "../../shared/format";

const getViajes = vi.fn();
const listCargas = vi.fn();
vi.mock("../../shared/api/stock", () => ({ getViajesPendientesRecepcion: () => getViajes() }));
vi.mock("../../shared/api/planCargas", () => ({ listPlanCargas: () => listCargas() }));

const { CargaPicker } = await import("./components/CargaPicker");

afterEach(() => { cleanup(); getViajes.mockReset(); listCargas.mockReset(); });

const HOY = hoyUY();
const viaje = (id: number, numero: number, fecha: string, productos: unknown[] = []) => ({
  id, numero_del_dia: numero, fecha, egreso_nro_fact: 900_000 + id, productos,
});

function abrir() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={qc}>
      <CargaPicker selected={null} onSelect={vi.fn()} onPickViaje={vi.fn()} />
    </QueryClientProvider>,
  );
  fireEvent.click(screen.getByText(/Elegir camión del Plan de Cargas/));
}

describe("Viajes en el picker del pie de camión", () => {
  it("muestra los de HOY y deja los viejos atrás, contados", async () => {
    listCargas.mockResolvedValue([]);
    getViajes.mockResolvedValue([
      viaje(1, 3, HOY),
      viaje(2, 1, "2026-08-31"),
      viaje(3, 4, "2026-08-30"),
    ]);
    abrir();

    expect(await screen.findByText(/Viaje 3/)).toBeTruthy();
    expect(screen.queryByText(/Viaje 1/)).toBeNull();
    expect(screen.getByText(/2 viajes de días anteriores/)).toBeTruthy();
  });

  it("el contador los trae de vuelta con un click", async () => {
    listCargas.mockResolvedValue([]);
    getViajes.mockResolvedValue([viaje(1, 3, HOY), viaje(2, 1, "2026-08-31")]);
    abrir();

    fireEvent.click(await screen.findByText(/1 viaje de días anteriores/));
    expect(screen.getByText(/Viaje 1/)).toBeTruthy();
    expect(screen.queryByText(/de días anteriores/)).toBeNull();
  });

  it("sin viajes viejos no aparece la línea del contador", async () => {
    listCargas.mockResolvedValue([]);
    getViajes.mockResolvedValue([viaje(1, 3, HOY)]);
    abrir();

    expect(await screen.findByText(/Viaje 3/)).toBeTruthy();
    expect(screen.queryByText(/de días anteriores/)).toBeNull();
  });

  it("el viaje trae los PRODUCTOS declarados para pre-cargar el pie", async () => {
    // Ciego a medias (3/09): vienen los productos, NO las cantidades. La
    // ceguera de productos hacía que el receptor eligiera el artículo hermano.
    const onPick = vi.fn();
    listCargas.mockResolvedValue([]);
    getViajes.mockResolvedValue([viaje(1, 3, HOY, [
      { cod_art: "940105", descripcion: "Melon Valenciano (Super)" },
      { cod_art: "600860", descripcion: "Palta Mexico Calibre 60" },
    ])]);
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    render(
      <QueryClientProvider client={qc}>
        <CargaPicker selected={null} onSelect={vi.fn()} onPickViaje={onPick} />
      </QueryClientProvider>,
    );
    fireEvent.click(screen.getByText(/Elegir camión del Plan de Cargas/));
    fireEvent.click(await screen.findByText(/Viaje 3/));

    const v = onPick.mock.calls[0][0];
    expect(v.productos.map((p: { cod_art: string }) => p.cod_art)).toEqual(["940105", "600860"]);
    expect(v.productos.every((p: Record<string, unknown>) => !("cantidad" in p))).toBe(true);
  });

  it("con un viaje pendiente y CERO cargas del plan, el viaje igual se ve", async () => {
    // Antes el vacío miraba sólo las cargas y se comía el viaje de hoy.
    listCargas.mockResolvedValue([]);
    getViajes.mockResolvedValue([viaje(1, 2, HOY)]);
    abrir();

    expect(await screen.findByText(/Viaje 2/)).toBeTruthy();
    expect(screen.queryByText(/No hay cargas planificadas/)).toBeNull();
  });
});
