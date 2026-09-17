"""Webhook SALIENTE: cuando se registra/confirma un pie de camión, Aloha le avisa a
los dashboards de maduración del compañero (ZAC / Coronel Raíz) con la carga por
cámara, para que la auto-carguen (hoy se hace a mano).

Contrato acordado (ver prompt.txt): el compañero levanta un endpoint idempotente por
`pie_de_camion.id`, location-aware (cada dashboard toma sus cámaras). Aloha **rutea por
ubicación**: sólo le pega a la URL de las ubicaciones presentes en las cámaras del pie.

**Best-effort / fire-and-forget**: se dispara como BackgroundTask (después de la
respuesta) y CUALQUIER error se loguea sin romper nunca la carga del pie. Si no hay
token configurado, la integración está apagada y no se manda nada.
"""
from __future__ import annotations

import logging
import re
import unicodedata
from datetime import date, datetime, timezone

import httpx

from app.config import settings
from app.pg import fetch_all, fetch_one
from app.modules.piedecamion import queries as q

logger = logging.getLogger("piedecamion.webhook")

# Países que sabe mapear (acento-insensible). El compañero re-normaliza (BRASIL→Brasil).
_PAISES = ["BRASIL", "ECUADOR", "PARAGUAY", "BOLIVIA", "COLOMBIA", "PERU",
           "CHILE", "URUGUAY", "MEXICO", "ARGENTINA"]


def _plano(s: str | None) -> str:
    return unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().upper()


def _norm_pais(*textos: str | None) -> str | None:
    """Deduce el país (MAYÚSCULAS, sin acento) del primer texto donde aparezca uno
    conocido — ej. 'Banana Brasil' → 'BRASIL'."""
    for t in textos:
        p = _plano(t)
        for pais in _PAISES:
            if pais in p:
                return pais
    return None


def _familia_limpia(desc: str | None) -> str | None:
    """De una descripción de línea ('Banana Brasil (super)', 'Banana Ecuador Color 4')
    saca una familia legible ('Banana Brasil', 'Banana Ecuador') — quita (super), el
    'Color N' y 'Madura'. Best-effort; el compañero agrupa por origen igual."""
    if not desc:
        return None
    s = re.sub(r"\s*\(s[úu]per\)\s*", " ", desc, flags=re.IGNORECASE)
    s = re.sub(r"\s+color\s+\d+\b", "", s, flags=re.IGNORECASE)
    s = re.sub(r"\s+madura\b", "", s, flags=re.IGNORECASE)
    return s.strip() or desc


def _url_de_ubicacion(ubic: str | None) -> str | None:
    u = _plano(ubic).strip()
    if u == "ZAC":
        return settings.aloha_webhook_zac_url.strip() or None
    if u == "CR":
        return settings.aloha_webhook_cr_url.strip() or None
    return None


def _iso_fecha(v) -> str | None:
    if isinstance(v, (date, datetime)):
        return v.isoformat()[:10]
    return str(v)[:10] if v else None


def _hora(v) -> str | None:
    if v is None:
        return None
    if hasattr(v, "strftime"):        # datetime.time / datetime
        return v.strftime("%H:%M")
    return str(v)[:5]                  # ya viene 'HH:MM'


def _num(v):
    if v is None:
        return None
    try:
        f = float(v)
        return int(f) if f == int(f) else f
    except (TypeError, ValueError):
        return None


def _build_payload(pie: dict, camaras: list[dict], productos: list[dict],
                   lineas: list[dict], pais: str | None, estado: str, evento: str) -> dict:
    """Arma el JSON del contrato a partir de la fila del pie, cámaras, productos y
    LÍNEAS (la mercadería real). El header `productos` suele venir VACÍO en la práctica,
    así que familia/origen se derivan de las líneas (cod_art + descripción con el país)."""
    nombres = [p.get("producto") for p in productos if p.get("producto")]
    if not nombres and pie.get("producto"):
        nombres = [pie["producto"]]
    if not nombres:  # header vacío → sacar de la mercadería real (las líneas)
        nombres = [f for l in lineas if (f := _familia_limpia(l.get("descripcion")))]
    familia = nombres[0] if nombres else None
    # país: el del plan si estaba linkeado; si no, deducido de familia/líneas/productor/exportador.
    origen = _norm_pais(pais) or _norm_pais(
        familia, pie.get("productor"), pie.get("exportador"),
        *[l.get("descripcion") for l in lineas],
    )

    # Familia/origen/cantidad POR PRODUCTO (cod_art) de la mercadería. El país se
    # deduce por línea ('Kiwi Chile' → CHILE) con fallback al del pie/plan.
    por_cod: dict[str, dict] = {}
    for l in lineas:
        cod = (l.get("cod_art") or "").strip()
        if not cod:
            continue
        agg = por_cod.setdefault(cod, {
            "familia": _familia_limpia(l.get("descripcion")) or familia,
            "origen": _norm_pais(l.get("descripcion")) or origen,
            "cantidad": 0,
        })
        agg["cantidad"] += _num(l.get("cantidad")) or 0

    def _sumar(dest: dict, info: dict, cajas) -> None:
        """Acumula un producto en `dest` agrupando por (origen, familia)."""
        key = (info.get("origen"), info.get("familia"))
        e = dest.setdefault(key, {"origen": info.get("origen"), "familia": info.get("familia"), "cantidad_cajas": 0})
        e["cantidad_cajas"] += cajas or 0

    # Lista completa de la mercadería (fallback: 1 sola cámara = va todo ahí; y
    # repartos viejos sin desglose → mejor la lista entera que un producto errado).
    todos_grp: dict[tuple, dict] = {}
    for info in por_cod.values():
        _sumar(todos_grp, info, info["cantidad"])
    todos = list(todos_grp.values())

    total_cajas = _num(pie.get("total_cajas"))
    # Agrupar filas por cámara FÍSICA (ubicación+número): con el desglose
    # producto→cámara una misma cámara puede tener varias filas (una por producto).
    fisicas: dict[tuple, dict] = {}
    for c in camaras:
        key = ((c.get("ubicacion") or "").strip(), _num(c.get("numero")))
        f = fisicas.setdefault(key, {"cajas": 0, "todas": False, "asigs": {}})
        cant = _num(c.get("cantidad"))
        cod = (c.get("cod_art") or "").strip()
        if cod and cod in por_cod:
            # Fila DESGLOSADA (producto→cámara). Sin cantidad = toda la línea de ese
            # producto — NUNCA "todo el camión" (eso inflaría las cajas de la cámara).
            cajas_fila = cant if cant is not None else por_cod[cod]["cantidad"]
            f["cajas"] += cajas_fila
            _sumar(f["asigs"], por_cod[cod], cajas_fila)
        elif cant is None:            # sin producto y sin cantidad = todas (caso 1-cámara)
            f["todas"] = True
        else:
            f["cajas"] += cant

    cams = []
    for (ubic, num), f in fisicas.items():
        cajas = total_cajas if f["todas"] else f["cajas"]
        if f["asigs"]:
            prods = list(f["asigs"].values())
        elif todos:
            prods = todos
        else:
            prods = ([{"origen": origen, "familia": familia, "cantidad_cajas": cajas}]
                     if (origen or familia) else [])
        cams.append({
            "ubicacion": ubic,
            "numero": num,
            "cajas": cajas,
            "productos": prods,
        })

    def temps(*vals):
        return [_num(v) for v in vals if v is not None]

    now = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return {
        "evento": evento,
        "enviado_en": now,
        "pie_de_camion": {
            "id": pie.get("id"),
            "estado": estado,
            "fecha_descarga": _iso_fecha(pie.get("fecha")),
            "fecha_carga": _iso_fecha(pie.get("fecha_carga")),
            "hora_inicio": _hora(pie.get("hora_inicio")),
            "hora_fin": _hora(pie.get("hora_fin")),
            "chofer": pie.get("chofer_nombre"),
            "placa_camion": pie.get("placa_camion"),
            "exportador": pie.get("exportador"),
            "transportista": pie.get("empresa_transporte"),
            "productor": pie.get("productor"),
            "codigo_importador": pie.get("codigo_importador_camion"),
            "numero_afidi": pie.get("numero_afidi"),
            "total_cajas": total_cajas,
            "camaras": cams,
            "calidad": {
                "temp_pulpa": {
                    "puerta": temps(pie.get("temp_pulpa_puerta_1"), pie.get("temp_pulpa_puerta_2")),
                    "medio": temps(pie.get("temp_pulpa_medio_1"), pie.get("temp_pulpa_medio_2")),
                    "atras": temps(pie.get("temp_pulpa_atras_1"), pie.get("temp_pulpa_atras_2")),
                },
                "peso_caja_kg": {
                    "puerta": temps(pie.get("peso_caja_puerta_1"), pie.get("peso_caja_puerta_2")),
                    "medio": temps(pie.get("peso_caja_medio_1"), pie.get("peso_caja_medio_2")),
                    "atras": temps(pie.get("peso_caja_atras_1"), pie.get("peso_caja_atras_2")),
                },
                "calibracion": {
                    "puerta": _num(pie.get("calibracion_puerta")),
                    "medio": _num(pie.get("calibracion_medio")),
                    "atras": _num(pie.get("calibracion_atras")),
                },
                "corona": pie.get("corona"),
                "quemada": pie.get("quemada"),
                "rameada": pie.get("rameada"),
            },
        },
    }


def _post(payload: dict, camaras: list[dict]) -> None:
    """Rutea por ubicación y hace el POST best-effort a cada URL. Nunca lanza."""
    if not settings.aloha_webhook_token:
        return  # integración apagada
    pie_id = payload.get("pie_de_camion", {}).get("id")
    urls = {u for c in camaras if (u := _url_de_ubicacion(c.get("ubicacion")))}
    if not urls:
        return  # sin cámaras mapeables (o URL no configurada) → nada que auto-cargar
    # UA browser-like: el Cloudflare de camcontador2 devuelve 403 (error 1010,
    # browser integrity check) a los user-agents de librerías Python.
    headers = {
        "Authorization": f"Bearer {settings.aloha_webhook_token}",
        "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AlohaERP/1.0",
    }
    try:
        with httpx.Client(timeout=8.0) as client:
            for url in urls:
                try:
                    r = client.post(url, json=payload, headers=headers)
                    if r.status_code >= 400:
                        logger.warning("webhook pie %s → %s: HTTP %s %s", pie_id, url, r.status_code, r.text[:300])
                    else:
                        logger.info("webhook pie %s → %s OK", pie_id, url)
                except Exception as e:
                    logger.warning("webhook pie %s → %s falló: %s", pie_id, url, e)
    except Exception as e:  # noqa: BLE001 — best-effort, nunca romper
        logger.warning("webhook pie %s: error inesperado: %s", pie_id, e, exc_info=True)


def _build_desde_db(pie_id: int, estado: str, evento: str):
    """Reconstruye el payload desde la DB (pie + cámaras + productos + LÍNEAS + país del
    plan). Devuelve (payload, camaras) o None si el pie no existe."""
    pie = fetch_one(q.WEBHOOK_PIE_SQL, (pie_id,))
    if not pie:
        return None
    camaras = fetch_all(q.GET_CAMARAS_SQL, (pie_id,))
    productos = fetch_all(q.GET_PRODUCTOS_SQL, (pie_id,))
    lineas = fetch_all(q.GET_LINEAS_SQL, (pie_id,))
    payload = _build_payload(pie, camaras, productos, lineas, pie.get("pais_origen"), estado, evento)
    return payload, camaras


def enviar_registrado(pie_id: int) -> None:
    """Al REGISTRAR el pie (estado 'pendiente'). Best-effort — corre como BackgroundTask
    (después del commit → las líneas/cámaras ya están en la DB)."""
    try:
        built = _build_desde_db(pie_id, "pendiente", "pie_de_camion.registrado")
        if built:
            _post(*built)
    except Exception as e:  # noqa: BLE001
        logger.warning("webhook 'registrado' pie %s: %s", pie_id, e, exc_info=True)


def enviar_ingresado(pie_id: int) -> None:
    """Al CONFIRMAR el pie (estado 'ingresado'). Idempotente del lado del compañero
    (upsert por id) → sólo actualiza el estado. Best-effort."""
    try:
        built = _build_desde_db(pie_id, "ingresado", "pie_de_camion.ingresado")
        if built:
            _post(*built)
    except Exception as e:  # noqa: BLE001
        logger.warning("webhook 'ingresado' pie %s: %s", pie_id, e, exc_info=True)
