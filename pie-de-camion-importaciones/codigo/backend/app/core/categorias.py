"""
Categorías de mercadería para el picker estilo POS (Pie de camión).

Macrosoft NO tiene un campo de categoría usable (SupFlia/Grupo son códigos
jerárquicos numéricos; todo lo vendible cae en SupFlia=1 / Grupo 1.1). Pero la
DESCRIPCIÓN empieza siempre con el tipo de producto ("Banana Brasil", "Kiwi
Chile", "Cebolla Blanca"…), así que derivamos la categoría de la primera
palabra. Eso además filtra la basura contable (DEUDORES, MUEBLES, REDONDEOS…)
y los no-vendibles (BINS, Pallets, Dto.): no matchean ninguna categoría →
quedan fuera del picker (igual son buscables por texto).

Cada categoría tiene un ícono SVG en el front: /categorias/<icono>.svg
(set fluent-emoji-flat). Para agregar una categoría nueva: sumar la tupla
acá + el SVG en front-almar-erp/public/categorias/.
"""
import unicodedata

# (nombre canónico, slug del ícono, [primeras-palabras que mapean acá])
# El orden es el orden de display en la grilla.
CATEGORIAS: list[tuple[str, str, list[str]]] = [
    ("Banana", "banana", ["banana", "bananas"]),
    ("Kiwi", "kiwi", ["kiwi"]),
    # Cebollín adentro de Cebolla (dueño 24/08): en el picker es la misma
    # familia — el vendedor entra a "Cebolla" y tiene que ver los cebollines.
    ("Cebolla", "cebolla", ["cebolla", "cebollas", "cebollin", "cebollines", "verdeo"]),
    ("Ajo", "ajo", ["ajo", "ajos"]),
    ("Papa", "papa", ["papa", "papas"]),
    ("Boniato", "boniato", ["boniato", "boniatos"]),
    ("Zanahoria", "zanahoria", ["zanahoria", "zanahorias"]),
    ("Choclo", "choclo", ["choclo", "choclos"]),
    ("Espárrago", "esparrago", ["esparrago", "esparragos"]),
    ("Jengibre", "jengibre", ["jengibre"]),
    ("Limón", "limon", ["limon", "limones"]),
    ("Lima", "lima", ["lima", "limas"]),
    ("Naranja", "naranja", ["naranja", "naranjas"]),
    ("Pomelo", "pomelo", ["pomelo", "pomelos"]),
    ("Uva", "uva", ["uva", "uvas"]),
    ("Pera", "pera", ["pera", "peras"]),
    ("Manzana", "manzana", ["manzana", "manzanas"]),
    ("Papaya", "papaya", ["papaya", "papayas"]),
    ("Mango", "mango", ["mango", "mangos"]),
    ("Piña", "pina", ["pina", "pinas", "abacaxi", "anana", "ananas"]),
    ("Sandía", "sandia", ["sandia", "sandias"]),
    ("Melón", "melon", ["melon", "melones"]),
    # Nectarines: la ficha técnica de los agrónomos los agrupa con Duraznos
    # (misma especie, Prunus persica) — comparten requisitos de ingreso.
    ("Durazno", "durazno", ["durazno", "duraznos", "melocoton", "nectarin", "nectarines", "nectarina", "nectarinas"]),
    ("Ciruela", "ciruela", ["ciruela", "ciruelas"]),
    ("Palta", "palta", ["palta", "paltas", "aguacate"]),
    ("Arándanos", "arandanos", ["arandano", "arandanos"]),
    ("Plátano", "banana", ["platano", "platanos"]),
    ("Morrón", "morron", ["morron", "morrones", "pimiento", "pimientos"]),
    ("Tomate", "tomate", ["tomate", "tomates"]),
    ("Coco", "coco", ["coco", "cocos"]),
    ("Maní", "mani", ["mani", "manies"]),
    ("Cereza", "cereza", ["cereza", "cerezas"]),
    ("Mandarina", "naranja", ["mandarina", "mandarinas"]),
    ("Caqui", "caqui", ["caqui", "caquis", "kaki", "kakis"]),
    ("Pitaya", "pitaya", ["pitaya", "pitayas", "pitahaya", "pitahayas"]),
    ("Mandioca", "mandioca", ["mandioca", "mandiocas", "yuca", "yucas"]),
    ("Cúrcuma", "jengibre", ["curcuma", "curcumas"]),
    # Temporada 24/08: lo que faltaba del catálogo real (Frutilla/Zapallo/
    # Zapallito/Papín estaban ACTIVOS sin ícono; Cebollín se fusionó en Cebolla)
    # + Berenjena/Pepino
    # que tienen ficha de los agrónomos y van a entrar cuando llegue la época.
    ("Frutilla", "frutilla", ["frutilla", "frutillas", "fresa", "fresas"]),
    ("Zapallo", "zapallo", ["zapallo", "zapallos", "cabutia", "kabutia", "calabaza", "calabazas"]),
    # Zapallito (redondo verde) tiene ícono propio (tomate fluent recoloreado —
    # no existe emoji); el zucchini/calabacín alargado va con el pepino.
    ("Zapallito", "zapallito", ["zapallito", "zapallitos"]),
    ("Zucchini", "pepino", ["zucchini", "zuchini", "calabacin", "calabacines"]),
    ("Papín", "papa", ["papin", "papines"]),
    ("Berenjena", "berenjena", ["berenjena", "berenjenas"]),
    ("Pepino", "pepino", ["pepino", "pepinos"]),
]

# Construir índices a partir de la lista
_WORD_TO_CAT: dict[str, str] = {}
_CAT_ICONO: dict[str, str] = {}
_CAT_ORDEN: dict[str, int] = {}
for _i, (_canon, _icono, _words) in enumerate(CATEGORIAS):
    _CAT_ICONO[_canon] = _icono
    _CAT_ORDEN[_canon] = _i
    for _w in _words:
        _WORD_TO_CAT[_w] = _canon


def _normalizar(s: str) -> str:
    """Saca acentos, baja a minúsculas, quita signos del borde."""
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode()
    return s.lower().strip()


def categoria_de(descripcion: str | None) -> str | None:
    """Devuelve la categoría canónica de un producto según su descripción,
    o None si no matchea ninguna (basura contable, envases, etc.)."""
    if not descripcion:
        return None
    primera = _normalizar(descripcion).split(" ", 1)[0].strip("().,-")
    return _WORD_TO_CAT.get(primera)


def categoria_de_descuento(descripcion: str | None) -> str | None:
    """Fruta nombrada en un descuento ('Dto. Bananas madera' → 'Banana'), para
    poder mostrar su ícono en el picker. A diferencia de categoria_de, escanea
    TODAS las palabras (no solo la primera, porque el texto arranca con
    'Dto.'/'Descuento'). None si no nombra ninguna fruta (ej. 'Dto. Precio
    genérico')."""
    if not descripcion:
        return None
    for w in _normalizar(descripcion).replace(".", " ").split():
        cat = _WORD_TO_CAT.get(w.strip("().,-"))
        if cat:
            return cat
    return None


def icono_de(categoria: str | None) -> str:
    return _CAT_ICONO.get(categoria or "", "otros")


def orden_de(categoria: str) -> int:
    return _CAT_ORDEN.get(categoria, 999)


def iconos_de_productos(pares: list[tuple[str | None, float]]) -> list[str]:
    """Slugs de ícono de un conjunto de líneas, ordenados por cantidad (bultos)
    desc y sin repetir. Cada par es (descripción, cantidad). Las líneas sin
    categoría reconocida (basura contable, envases) se ignoran.

    Se usa para el reconocimiento "de un vistazo" (Monitor A/B, lista de
    Ingresos): un pedido de banana + arándanos muestra esos dos íconos."""
    por_cat: dict[str, float] = {}
    for desc, cant in pares:
        cat = categoria_de(desc)
        if not cat:
            continue
        por_cat[cat] = por_cat.get(cat, 0.0) + float(cant or 0)
    iconos: list[str] = []
    vistos: set[str] = set()
    for cat, _ in sorted(por_cat.items(), key=lambda kv: kv[1], reverse=True):
        ic = icono_de(cat)
        if ic in vistos:
            continue
        vistos.add(ic)
        iconos.append(ic)
    return iconos
