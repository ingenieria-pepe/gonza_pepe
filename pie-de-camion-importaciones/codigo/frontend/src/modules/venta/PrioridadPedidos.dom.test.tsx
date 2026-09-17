// @vitest-environment jsdom
/** Prioridad de un pedido (dueño 28/08).
 *
 *  El problema real: la tele suena cada 20 s mientras el pedido siga
 *  prioritario y sin entregar, y en la tabla NO se veía cuál era el marcado —
 *  todas las filas mostraban el mismo botón rojo lleno y, encima, el pedido
 *  realmente marcado era el que tenía el botón MÁS pálido. Nadie iba a
 *  encontrar ahí el modo de apagar la alarma.
 *
 *  Lo que fija este test: rojo = está marcado, y ese mismo botón lo desmarca. */
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const listar = vi.fn();
const marcar = vi.fn();
vi.mock("./api", async () => {
  const real = await vi.importActual<typeof import("./api")>("./api");
  return {
    ...real,
    listPedidosVenta: (...a: unknown[]) => listar(...a),
    marcarPrioridadPedido: (...a: unknown[]) => marcar(...a),
    getPedidoVenta: vi.fn(),
    anularPedidoVenta: vi.fn(),
  };
});
vi.mock("../entregas/components/VideosDelPedido", () => ({ VideosDelPedido: () => null }));

const { TablaPedidos } = await import("./PedidosPage");

const BASE = {
  fecha: "2026-08-28", hora: "10:16", cliente_cod: 1, vendedor: 7, vendedor_nombre: "Matias",
  total: 2000, credito: false, estado: "asignado", observaciones: "", es_mio: true,
  creado_por: null, anulable: false, iconos: [], total_bultos: 10, videos: 0,
  solo_descuentos: false,
};
const PEDIDOS = [
  { ...BASE, nro_fact: 99648, nro_doc: "99648", cliente_nombre: "SERGIO ESCOBAL", prioritario: true },
  { ...BASE, nro_fact: 99647, nro_doc: "99647", cliente_nombre: "RANUIO", prioritario: false },
];

beforeEach(() => {
  listar.mockResolvedValue(PEDIDOS);
  marcar.mockResolvedValue({ ok: true });
  vi.spyOn(window, "confirm").mockReturnValue(true);
});
afterEach(() => { cleanup(); vi.restoreAllMocks(); listar.mockReset(); marcar.mockReset(); });

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  render(
    <QueryClientProvider client={qc}>
      <TablaPedidos tab="todos" />
    </QueryClientProvider>,
  );
}

const filaDe = (cliente: string) => screen.getByText(cliente).closest("tr")!;

describe("Prioridad de un pedido", () => {
  it("el pedido marcado se distingue de los demás en la fila y en el botón", async () => {
    montar();
    await screen.findByText("SERGIO ESCOBAL");
    const marcado = filaDe("SERGIO ESCOBAL");
    const suelto = filaDe("RANUIO");

    // La fila entera pintada: se ve cuál es sin leer botón por botón.
    expect(marcado.className).toContain("bg-red-50");
    expect(suelto.className).not.toContain("bg-red-50");

    // El botón fuerte es el del MARCADO (antes era al revés).
    const btnMarcado = within(marcado).getByRole("button", { name: /Quitar prioridad/ });
    expect(btnMarcado.className).toContain("bg-red-600");
    const btnSuelto = within(suelto).getByRole("button", { name: /^Prioritario$/ });
    expect(btnSuelto.className).not.toContain("bg-red-600");
  });

  it("el MISMO botón desmarca: es cómo se apaga la alarma de la tele", async () => {
    montar();
    await screen.findByText("SERGIO ESCOBAL");
    fireEvent.click(within(filaDe("SERGIO ESCOBAL")).getByRole("button", { name: /Quitar prioridad/ }));
    await waitFor(() => expect(marcar).toHaveBeenCalledWith(99648, false));
    // Y avisa qué gana con eso, que es lo que el vendedor está buscando.
    expect((window.confirm as ReturnType<typeof vi.fn>).mock.calls[0][0]).toMatch(/Deja de sonar/);
  });

  it("al marcar avisa que la alarma NO se apaga sola", async () => {
    montar();
    await screen.findByText("RANUIO");
    fireEvent.click(within(filaDe("RANUIO")).getByRole("button", { name: /^Prioritario$/ }));
    await waitFor(() => expect(marcar).toHaveBeenCalledWith(99647, true));
    expect((window.confirm as ReturnType<typeof vi.fn>).mock.calls[0][0])
      .toMatch(/hasta que se entregue o le saques la prioridad/);
  });
});

describe("Pedidos de DESCUENTOS (dueño 31/08)", () => {
  /** Un pedido de puros artículos D* no lleva mercadería: no se arma, no se
   *  controla y no se entrega. Marcarlo prioritario no le avisa a nadie —el
   *  armador nunca lo ve— y la alarma de la tele, que se apaga cuando el pedido
   *  se ENTREGA, no se apagaba nunca. Pasó con un dto y su pedido de mercadería
   *  cargados en el mismo minuto para el mismo cliente. */
  const conDto = (extra: Record<string, unknown>) => [
    { ...BASE, nro_fact: 100135, nro_doc: "100135", cliente_nombre: "LAZO PIRIZ",
      total_bultos: 21, prioritario: false, solo_descuentos: false },
    { ...BASE, nro_fact: 100136, nro_doc: "100136", cliente_nombre: "LAZO PIRIZ DTO",
      total_bultos: 2, solo_descuentos: true, prioritario: false, ...extra },
  ];

  it("el botón del dto no se puede tocar y dice por qué", async () => {
    listar.mockResolvedValue(conDto({}));
    montar();
    await screen.findByText("LAZO PIRIZ DTO");
    const btn = within(filaDe("LAZO PIRIZ DTO")).getByRole("button", { name: /^Prioritario$/ });
    expect(btn).toBeDisabled();
    expect(btn.getAttribute("title")).toMatch(/no se arma ni se entrega/);

    fireEvent.click(btn);
    expect(marcar).not.toHaveBeenCalled();
  });

  it("el pedido de mercadería del mismo cliente sí se marca", async () => {
    listar.mockResolvedValue(conDto({}));
    montar();
    await screen.findByText("LAZO PIRIZ");
    fireEvent.click(within(filaDe("LAZO PIRIZ")).getByRole("button", { name: /^Prioritario$/ }));
    await waitFor(() => expect(marcar).toHaveBeenCalledWith(100135, true));
  });

  it("un dto YA marcado se puede desmarcar: si no, la alarma queda trabada", async () => {
    listar.mockResolvedValue(conDto({ prioritario: true }));
    montar();
    await screen.findByText("LAZO PIRIZ DTO");
    const btn = within(filaDe("LAZO PIRIZ DTO")).getByRole("button", { name: /Quitar prioridad/ });
    expect(btn).not.toBeDisabled();
    fireEvent.click(btn);
    await waitFor(() => expect(marcar).toHaveBeenCalledWith(100136, false));
  });
});
