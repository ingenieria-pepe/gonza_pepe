"""Stock vivo POR COLOR de banana (dueño 25/08): que los vendedores no
sobrevendan colores que no hay.

Macrosoft no puede dar esto (sus saldos por color son ficción contable:
Color 1 +690k / Color 4 −420k). Aloha lo triangula con piezas que ya tiene:

    disponible(color) = cajas de las cámaras ZAC que HOY están en ese color
                        (última foto: conteo cíclico o carga del pie posterior)
                      − lo vendido DESPUÉS del conteo de cada cámara
                      − comprometido (pedidos '30' abiertos con -N)

EL ANCLA ES EL CONTEO, NO EL DÍA (3/09). Antes se restaba `vendido_hoy`
entero, y eso descuenta dos veces: medido sobre 14 días, el 80% de la banana
se vende antes de las 7 y la mayoría de las cámaras se cuentan entre las 9 y
las 12 (738 conteos contra 243 de madrugada). O sea que el conteo YA tiene
descontada la venta de la noche. El 3/09 el Color 4 daba −2.469: cámara 1
contada 11:03 con 685 cajas, contra 3.154 vendidas antes de esa hora.

Cada cámara se ancla en SU conteo y aporta su parte proporcional de lo que
salió después. Una contada a las 3 AM descuenta casi todo el día; una contada
a las 11, casi nada.

Lo que NO era el problema: que el color cambie durante la venta. En 14 días
hubo CERO cambios de color entre las 0 y las 7 — se concentran a las 8 y 9,
después de la operativa. Congelar el color al arrancar el día no habría
arreglado nada.

SIEMPRE estimativo y JAMÁS bloquea la venta (regla del disponible por
familia). CR no tiene colores (fruta verde).
"""
from __future__ import annotations

import re
from collections import defaultdict
from datetime import date, timedelta

from app.pg import fetch_all

# Los colores de Charlie vienen como "4", "4-5", "5-6" (rango de maduración).
# Un label cubre las variantes -N de todos sus números.
_NUMS = re.compile(r"\d+")

# Ventas/pedidos por color: cualquier banana madre con sufijo -N. El grupo 01
# son las bananas en el catálogo real (010101 Brasil, 010401 Paraguay, 0107xx
# Ecuador/Bolivia); "Madura" es la variante -7.
# Con la HORA de cada venta: lo que se descuenta no es todo el día, sino lo que
# salió DESPUÉS del conteo de cada cámara (ver stock_por_color). `legacy` guarda
# la hora en horario de Uruguay y `contado_en` de ext.* está en UTC, así que se
# convierte acá para poder compararlas.
VENTAS_COLOR_SQL = """
SELECT SPLIT_PART(BTRIM(l.codart), '-', 2) AS color,
       ((c.fecha::date + COALESCE(c.hora, '00:00'::time))
            AT TIME ZONE 'America/Montevideo') AS ts,
       SUM(l.cantidadhaber - l.cantidaddebe) AS cajas
FROM legacy.lineas l
JOIN legacy.documentos d ON BTRIM(d.documento) = BTRIM(l.documento)
-- LEFT: si el cabezal no está en la ventana del espejo, la venta NO puede
-- desaparecer del cálculo. Sin hora se la trata como posterior a todo conteo
-- (ver stock_por_color), que es el lado prudente: es peor decirle al vendedor
-- que hay de más.
LEFT JOIN legacy.cabezal c ON c.documento = l.documento AND c.nrofact = l.nrofact
WHERE BTRIM(d.tipdoc) = 'V' AND d.afecta = 1
  AND l.fecha::date = %s
  AND BTRIM(l.codart) LIKE '01%%-%%'
GROUP BY 1, 2
"""

COMPROMETIDO_COLOR_SQL = """
SELECT SPLIT_PART(BTRIM(l2.codart), '-', 2) AS color,
       SUM(l2.cantidadhaber) AS cajas
FROM legacy.lineas2 l2
JOIN legacy.cabezal2 c2 ON c2.documento = l2.documento AND c2.nrofact = l2.nrofact
WHERE l2.documento = '30  '
  AND COALESCE(c2.anulada, 0) = 0 AND COALESCE(c2.facturado, 0) = 0
  AND c2.fecha::date >= %s
  AND BTRIM(l2.codart) LIKE '01%%-%%'
GROUP BY 1
"""

# Cargas del pie a cámaras ZAC de los últimos 2 días (por si el camión entró
# DESPUÉS del conteo de la mañana). cantidad NULL = todo el camión.
CARGAS_PIE_SQL = """
SELECT pc.numero, p.fecha,
       COALESCE(pc.cantidad,
                (SELECT SUM(l.cantidad) FROM ext.pie_de_camion_linea l
                  WHERE l.pie_camion_id = p.id)) AS cajas
FROM ext.pie_de_camion_camara pc
JOIN ext.pie_de_camion p ON p.id = pc.pie_camion_id
WHERE BTRIM(pc.ubicacion) = 'ZAC' AND p.estado <> 'anulado'
  AND p.fecha >= %s
"""


def stock_por_color() -> dict:
    from app.modules.inventarios_ciclicos import charlie_ingestor
    from app.modules.stock import queries as stock_q

    hoy = date.today()
    colores, _temps = charlie_ingestor.datos_charlie_para_mapa("ZAC")

    # Última foto por cámara ZAC (misma query del mapa, sin ventana).
    unidades = fetch_all(stock_q.MAPA_CAMARAS_ULTIMA_REVISION_SQL, ("ZAC",))
    revision_ids = [u["revision_id"] for u in unidades if u.get("revision_id")]
    cajas_por_revision: dict[int, float] = defaultdict(float)
    if revision_ids:
        for row in fetch_all(stock_q.MAPA_CAMARAS_LINEAS_SQL, (revision_ids,)):
            cajas_por_revision[row["revision_id"]] += float(row["cantidad"] or 0)

    cargas: dict[int, list[dict]] = defaultdict(list)
    for c in fetch_all(CARGAS_PIE_SQL, (hoy - timedelta(days=1),)):
        cargas[c["numero"]].append(c)

    # Ventas del día con su hora, para poder preguntar "¿cuánto salió DESPUÉS
    # de tal conteo?". El total del día viaja igual, para el tooltip.
    ventas: dict[str, list[tuple]] = defaultdict(list)
    vendido: dict[str, float] = defaultdict(float)
    for r in fetch_all(VENTAS_COLOR_SQL, (hoy,)):
        cajas = float(r["cajas"] or 0)
        ventas[r["color"]].append((r["ts"], cajas))
        vendido[r["color"]] += cajas
    comprometido = {r["color"]: float(r["cajas"] or 0)
                    for r in fetch_all(COMPROMETIDO_COLOR_SQL, (hoy - timedelta(days=1),))}

    pools: dict[str, dict] = {}
    for u in unidades:
        if (u.get("tipo") or "") != "camara" or u.get("numero") is None:
            continue
        label = colores.get(u["numero"])
        if not label:
            continue  # cámara sin color según Charlie: no aporta a ningún pool
        # REGLA DEL DUEÑO (26/08): el label SIEMPRE asigna al color más chico
        # ("3-4", "4-3" y "3" suman todos a 3). Sin solapamientos: cada caja
        # cuenta para UN solo color.
        nums = _NUMS.findall(label)
        if not nums:
            continue
        label = str(min(int(n) for n in nums))
        cajas = cajas_por_revision.get(u.get("revision_id") or -1, 0.0)
        contado_en = u.get("contado_en")
        carga_pie = 0.0
        for c in cargas.get(u["numero"], []):
            # La carga del pie pisa/suma solo si es POSTERIOR al último conteo.
            if contado_en is None or c["fecha"] > contado_en.date():
                carga_pie += float(c["cajas"] or 0)
        pool = pools.setdefault(label, {
            "color": label, "camaras": [], "cajas_contadas": 0.0,
            "cargas_pie": 0.0,
        })
        pool["camaras"].append({
            "numero": u["numero"],
            "cajas": cajas,
            "carga_pie": carga_pie,
            "contado_en": contado_en,   # datetime; se serializa al final
        })
        pool["cajas_contadas"] += cajas
        pool["cargas_pie"] += carga_pie

    out = []
    for label, pool in sorted(pools.items()):
        v = vendido.get(label, 0.0)
        comp = comprometido.get(label, 0.0)
        total = pool["cajas_contadas"] + pool["cargas_pie"]
        # Cada cámara descuenta SU parte de lo que salió después de SU conteo.
        # El reparto es proporcional a lo que aporta al pool: no sabemos de qué
        # cámara salió cada caja —la factura dice el color, no el número— pero
        # sí que una cámara contada tarde no pudo aportar a una venta temprana.
        lista = ventas.get(label, [])
        descontado = 0.0
        for cam in pool["camaras"]:
            aporta = float(cam["cajas"] or 0) + float(cam["carga_pie"] or 0)
            if total <= 0 or aporta <= 0:
                continue
            t = cam["contado_en"]
            # Se descuenta la venta si es POSTERIOR al conteo, y también si no
            # se sabe cuándo fue (sin hora) o si la cámara no tiene conteo:
            # ante la duda, restar. Es peor decirle al vendedor que hay de más.
            posteriores = sum(
                q for ts, q in lista if t is None or ts is None or ts > t
            )
            descontado += posteriores * (aporta / total)
        out.append({
            **pool,
            "camaras": [
                {**c, "contado_en": c["contado_en"].isoformat() if c["contado_en"] else None}
                for c in pool["camaras"]
            ],
            "vendido_hoy": v,
            # Lo que REALMENTE se resta. Que viaje aparte de `vendido_hoy` hace
            # auditable la cuenta desde el tooltip, sin abrir la base.
            "vendido_post_conteo": round(descontado, 2),
            "comprometido": comp,
            "disponible_estimado": round(total - descontado - comp, 2),
        })
    return {
        "pools": out,
        "colores_actualizados": bool(colores),
        # Variantes que ningún pool cubre quedan "sin dato" en el front (no 0).
        "colores_con_camara": sorted(p["color"] for p in out),
    }


# ── Cache stale-while-revalidate (26/08: "demora mucho en cargar") ───────────
#
# El costo real es la ida a la PC de Charlie (SQL Server por Tailscale) en el
# primer request de cada ventana de 90s. Acá el endpoint sirve SIEMPRE lo
# último calculado al instante y refresca en un hilo de fondo cuando venció
# el TTL. Solo el primerísimo request tras un boot paga el cálculo — y el
# warmup del arranque (main.py) suele ganarle a ese request.
import threading
import time as _time

_TTL_SEGUNDOS = 60.0
_cache: dict = {"data": None, "ts": 0.0, "refrescando": False}
_lock = threading.Lock()


def _refrescar() -> None:
    try:
        data = stock_por_color()
        with _lock:
            _cache["data"] = data
            _cache["ts"] = _time.monotonic()
    except Exception:  # noqa: BLE001 — se sigue sirviendo lo último bueno
        import logging

        logging.getLogger("app.venta").warning("refresh stock-colores falló", exc_info=True)
    finally:
        with _lock:
            _cache["refrescando"] = False


def stock_por_color_cacheado() -> dict:
    """Instantáneo: devuelve lo último calculado; si venció el TTL dispara el
    refresh en fondo. Solo calcula inline si NUNCA se calculó (primer boot)."""
    with _lock:
        data = _cache["data"]
        vencido = _time.monotonic() - _cache["ts"] > _TTL_SEGUNDOS
        disparar = vencido and not _cache["refrescando"] and data is not None
        if disparar:
            _cache["refrescando"] = True
    if data is None:
        _refrescar()
        with _lock:
            return _cache["data"] or {"pools": [], "colores_actualizados": False,
                                      "colores_con_camara": []}
    if disparar:
        threading.Thread(target=_refrescar, daemon=True, name="stock-colores-refresh").start()
    return data


def warmup() -> None:
    """Precalienta el cache al arrancar la app (hilo, no bloquea el boot)."""
    with _lock:
        if _cache["refrescando"]:
            return
        _cache["refrescando"] = True
    threading.Thread(target=_refrescar, daemon=True, name="stock-colores-warmup").start()
