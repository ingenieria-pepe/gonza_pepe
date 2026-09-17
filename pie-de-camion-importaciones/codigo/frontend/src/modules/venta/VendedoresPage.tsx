import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { listVendedores } from "../../shared/api/lookups";
import { errorLegible, getVendedoresConfig, setVendedorUsuario, type VentaVendedorItem } from "./api";

/* Venta → Vendedores (admin del módulo): a cada usuario Aloha con permiso `venta`
   se le asigna su código de vendedor de Macrosoft (tabla Vendedores del legacy:
   1=Matias … 7=Facundo). Sin código asignado, el usuario NO puede crear pedidos. */

export function VendedoresVentaPage() {
  const qc = useQueryClient();
  const [err, setErr] = useState<string | null>(null);

  const { data: filas, isLoading } = useQuery({
    queryKey: ["venta-vendedores-config"],
    queryFn: getVendedoresConfig,
  });
  const { data: catalogo } = useQuery({
    queryKey: ["lookups-vendedores"],
    queryFn: listVendedores,
    staleTime: 10 * 60 * 1000,
  });

  const mut = useMutation({
    mutationFn: ({ usuarioId, vendedor }: { usuarioId: number; vendedor: number | null }) =>
      setVendedorUsuario(usuarioId, vendedor),
    onSuccess: () => {
      setErr(null);
      qc.invalidateQueries({ queryKey: ["venta-vendedores-config"] });
    },
    onError: (e: Error) => setErr(errorLegible(e.message)),
  });

  return (
    <div className="h-full overflow-y-auto overscroll-y-contain">
      <div className="max-w-3xl mx-auto p-4 sm:p-6 space-y-4 pb-10">
      <div>
        <h2 className="text-xl font-bold text-slate-900">Vendedores</h2>
        <p className="text-sm text-slate-500 mt-1">
          Usuarios con acceso a Venta y su <strong>código de vendedor de Macrosoft</strong>. El
          pedido sale a caja con este código. Sin código asignado, el usuario no puede crear
          pedidos.
        </p>
      </div>

      {err && (
        <div className="px-3 py-2 rounded bg-red-50 border border-red-200 text-sm text-red-700">{err}</div>
      )}

      {isLoading ? (
        <p className="text-sm text-slate-400">Cargando…</p>
      ) : !filas || filas.length === 0 ? (
        <p className="text-sm text-slate-400">
          Ningún usuario tiene el permiso <strong>venta</strong> todavía — asignalo primero en
          Administración → Roles.
        </p>
      ) : (
        <ul className="divide-y divide-pepe-border rounded-lg border border-pepe-border bg-white">
          {filas.map((f: VentaVendedorItem) => (
            <li key={f.usuario_id} className="p-3 sm:p-4 flex items-center gap-3">
              <div className="min-w-0 flex-1">
                <div className="font-semibold text-slate-900 truncate">{f.usuario_nombre}</div>
                <div className="text-xs text-slate-400">@{f.username}</div>
              </div>
              <select
                value={f.vendedor ?? ""}
                onChange={(e) =>
                  mut.mutate({
                    usuarioId: f.usuario_id,
                    vendedor: e.target.value === "" ? null : Number(e.target.value),
                  })
                }
                disabled={mut.isPending}
                className={`px-3 py-2.5 max-w-[50vw] sm:max-w-none rounded-md border text-base bg-white ${
                  f.vendedor == null ? "border-amber-400 text-amber-700" : "border-pepe-border"
                }`}
              >
                <option value="">Sin asignar</option>
                {(catalogo ?? []).map((v) => (
                  <option key={v.cod} value={v.cod}>
                    {v.cod} — {v.nombre}
                  </option>
                ))}
              </select>
            </li>
          ))}
        </ul>
      )}
      </div>
    </div>
  );
}
