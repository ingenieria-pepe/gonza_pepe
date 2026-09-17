"""
Generador del PDF de Pie de Camión.

Replica la planilla de papel "Control De Mercadería A Pie Camión" en digital.
Buscamos densidad de información parecida al original — no es un PDF estético,
sino un comprobante operativo que puede imprimirse o archivarse.
"""
from __future__ import annotations

import os
from io import BytesIO

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm, mm
from reportlab.platypus import (
    Image,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

AZUL_PEPE = colors.HexColor("#3856C1")
AZUL_OSCURO = colors.HexColor("#1E418E")
GRIS_BORDE = colors.HexColor("#94A3B8")
GRIS_BG = colors.HexColor("#F1F5F9")
GRIS_TEXTO = colors.HexColor("#475569")

# Íconos de fruta rasterizados (PNG) — reportlab no renderiza SVG, así que
# usamos los PNG generados de /categorias/*.svg (ver app/assets/categorias/).
_CATEGORIAS_PNG_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "categorias")


def _icono_img_tag(descripcion: str | None, size: int = 11) -> str:
    """Tag <img> inline para el ícono de fruta de una descripción (para meter
    dentro de un Paragraph). "" si la descripción no matchea ninguna categoría o
    falta el PNG."""
    from app.core.categorias import categoria_de, icono_de

    cat = categoria_de(descripcion)
    if not cat:
        return ""
    path = os.path.join(_CATEGORIAS_PNG_DIR, f"{icono_de(cat)}.png")
    if not os.path.exists(path):
        return ""
    return f'<img src="{path}" width="{size}" height="{size}" valign="-2"/> '


def _f(v) -> str:
    """Formatea un valor para una celda: vacío si None."""
    if v is None or v == "":
        return ""
    if isinstance(v, float):
        return f"{v:.2f}"
    return str(v)


def _rating_box(rating: int | None) -> str:
    """Renderiza '1 2 3 4 5' con el seleccionado en negrita."""
    if rating is None:
        return "1   2   3   4   5"
    cells = []
    for i in range(1, 6):
        if i == rating:
            cells.append(f"<b><font color='#1E418E'>[{i}]</font></b>")
        else:
            cells.append(str(i))
    return "   ".join(cells)


def _calif_box(value: str | None) -> str:
    """Regular / Buena / Muy buena con el seleccionado destacado. NO usa glifos
    de círculo (●/○): Helvetica no los tiene y reportlab los dibuja como ■ para
    todos → no se distinguía el elegido. El seleccionado va en [azul negrita], el
    resto en gris."""
    opciones = ["Regular", "Buena", "Muy buena"]
    cells = []
    for op in opciones:
        if value and op == value:
            cells.append(f"<b><font color='#1E418E'>[{op}]</font></b>")
        else:
            cells.append(f"<font color='#9CA3AF'>{op}</font>")
    return "        ".join(cells)


def generate_piedecamion_pdf(
    data: dict,
    *,
    creado_por_nombre: str,
    id_documento: int,
    lineas: list[dict] | None = None,
    productos: list[dict] | None = None,
    camaras: list[dict] | None = None,
    requisitos: list[dict] | None = None,
) -> bytes:
    """Genera el informe de DATOS (sin fotos) y devuelve los bytes. Las fotos van en
    un PDF aparte (generate_piedecamion_fotos_pdf) que se fusiona al descargar.
    `data`: dict con todas las columnas (mismo orden que en el form/SQL).
    `lineas`: opcional, lista de dicts con keys cod_art, descripcion, deposito,
              deposito_descripcion, cantidad, defectos: [{motivo, cantidad}].
    `productos`: opcional, lista de dicts con keys `producto` y `marca` —
                 cuando el camión trae varios productos a la vez.
    """
    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf,
        pagesize=A4,
        leftMargin=15 * mm, rightMargin=15 * mm,
        topMargin=12 * mm, bottomMargin=12 * mm,
        title=f"Pie de Camión #{id_documento}",
        author="Sistema Aloha",
    )
    base = getSampleStyleSheet()
    p_normal = ParagraphStyle("n", parent=base["BodyText"], fontName="Helvetica", fontSize=9, leading=11)
    p_label = ParagraphStyle("l", parent=base["BodyText"], fontName="Helvetica-Bold", fontSize=8, leading=10, textColor=GRIS_TEXTO)
    p_valor = ParagraphStyle("v", parent=base["BodyText"], fontName="Helvetica", fontSize=10, leading=12)
    p_rating = ParagraphStyle("r", parent=base["BodyText"], fontName="Helvetica", fontSize=10, leading=13)

    story = []

    # ── Header (logo Pepe + Sistema Aloha + título)
    titulo_txt = Paragraph(
        "<para align='left'><b><font size=14 color='#1E418E'>CONTROL DE MERCADERÍA A PIE DE CAMIÓN</font></b><br/>"
        f"<font size=8 color='#64748B'>Sistema Aloha · Pepe Banana · Almar S.A. · Pie de camión #{id_documento}</font></para>",
        p_normal,
    )
    _logo_path = os.path.join(os.path.dirname(__file__), "..", "..", "assets", "logo_pepe.png")
    if os.path.exists(_logo_path):
        _logo = Image(_logo_path, width=20 * mm, height=20 * mm, kind="proportional")
        header_tbl = Table([[_logo, titulo_txt]], colWidths=[24 * mm, None])
        header_tbl.setStyle(TableStyle([
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 0),
            ("RIGHTPADDING", (0, 0), (-1, -1), 0),
            ("LINEBELOW", (0, 0), (-1, -1), 1, AZUL_PEPE),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ("TOPPADDING", (0, 0), (-1, -1), 0),
        ]))
        story.append(header_tbl)
    else:
        story.append(titulo_txt)
    story.append(Spacer(1, 8))

    # ── Datos generales (tabla)
    fecha_str = data["fecha"].strftime("%d/%m/%Y") if data.get("fecha") else ""
    horas_str = f"{_f(data.get('hora_inicio'))} → {_f(data.get('hora_fin'))}"

    # Productos: si vinieron varios, los mostramos como lista. Si no, caemos al
    # campo legacy producto/marca.
    productos = productos or []
    if productos:
        _lineas_prod = []
        for p in productos:
            nombre = p.get("producto", "")
            # Ícono de fruta si matchea; si no, el bullet de siempre.
            prefijo = _icono_img_tag(nombre) or "<b>•</b> "
            marca_txt = f" — <i>{p.get('marca')}</i>" if p.get("marca") else ""
            _lineas_prod.append(f"{prefijo}{nombre}{marca_txt}")
        prods_str = "<br/>".join(_lineas_prod)
    else:
        prods_str = _f(data.get("producto"))
        if data.get("marca"):
            prods_str += f" — <i>{_f(data.get('marca'))}</i>"

    fecha_carga_str = data["fecha_carga"].strftime("%d/%m/%Y") if data.get("fecha_carga") else "—"
    datos_grid = [
        [Paragraph("<b>Fecha de carga</b>", p_label), Paragraph(fecha_carga_str, p_valor),
         Paragraph("<b>Fecha de descarga</b>", p_label), Paragraph(fecha_str, p_valor)],
        [Paragraph("<b>Hora inicio / fin</b>", p_label), Paragraph(horas_str, p_valor),
         Paragraph("<b>N° Placa Camión</b>", p_label), Paragraph(_f(data.get("placa_camion")), p_valor)],
        [Paragraph("<b>Nombre Chofer</b>", p_label), Paragraph(_f(data.get("chofer_nombre")), p_valor),
         Paragraph("<b>Cód. importador</b>", p_label), Paragraph(_f(data.get("codigo_importador_camion")), p_valor)],
        [Paragraph("<b>Producto / Marca</b>", p_label), Paragraph(prods_str, p_valor),
         Paragraph("<b>Exportador</b>", p_label), Paragraph(_f(data.get("exportador")), p_valor)],
        [Paragraph("<b>Productor</b>", p_label), Paragraph(_f(data.get("productor")), p_valor),
         Paragraph("<b>Empresa Transp.</b>", p_label), Paragraph(_f(data.get("empresa_transporte")), p_valor)],
        [Paragraph("<b>Número de Afidi</b>", p_label), Paragraph(_f(data.get("numero_afidi")), p_valor), "", ""],
        [Paragraph("<b>Camión interv. Agronomía</b>", p_label),
         Paragraph("SÍ" if data.get("intervenido_agronomia") else "NO", p_valor), "", ""],
    ]
    if data.get("intervenido_agronomia") and data.get("inspector_agronomo"):
        datos_grid.append([
            Paragraph("<b>Inspector Agrónomo</b>", p_label),
            Paragraph(_f(data.get("inspector_agronomo")), p_valor),
            "", "",
        ])
    datos_tbl = Table(datos_grid, colWidths=[3.5 * cm, 5.5 * cm, 3.5 * cm, 5.5 * cm])
    datos_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 3),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ]))
    story.append(datos_tbl)

    # ── Condiciones generales (rating 1-5 + comentario)
    story.append(Spacer(1, 8))
    cond_header = Table(
        [["", Paragraph("<para align='center'><b>CONDICIONES GENERALES</b></para>", p_normal)]],
        colWidths=[0.1 * cm, 17.9 * cm],
        style=TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), GRIS_BG),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ]),
    )
    story.append(cond_header)
    cond_grid = [
        [Paragraph("<b>Palet</b>", p_label), Paragraph(_rating_box(data.get("palet_rating")), p_rating), Paragraph("<b>Coment.</b>", p_label), Paragraph(_f(data.get("palet_comentario")), p_valor)],
        [Paragraph("<b>Cajas</b>", p_label), Paragraph(_rating_box(data.get("cajas_rating")), p_rating), Paragraph("<b>Coment.</b>", p_label), Paragraph(_f(data.get("cajas_comentario")), p_valor)],
        [Paragraph("<b>Flejes</b>", p_label), Paragraph(_rating_box(data.get("flejes_rating")), p_rating), Paragraph("<b>Coment.</b>", p_label), Paragraph(_f(data.get("flejes_comentario")), p_valor)],
    ]
    cond_tbl = Table(cond_grid, colWidths=[2 * cm, 5 * cm, 1.5 * cm, 9.5 * cm])
    cond_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    story.append(cond_tbl)

    # ── Condiciones del Banano EC (Puerta / Medio / Atrás)
    story.append(Spacer(1, 8))
    banano_header = Table(
        [["", Paragraph("<para align='center'><b>CONDICIONES DEL BANANO EC</b></para>", p_normal)]],
        colWidths=[0.1 * cm, 17.9 * cm],
        style=TableStyle([
            ("BACKGROUND", (0, 0), (-1, -1), GRIS_BG),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ]),
    )
    story.append(banano_header)

    # Header sub-columnas
    banano_grid = [
        [
            "",
            Paragraph("<para align='center'><b>Puerta</b></para>", p_normal), "",
            Paragraph("<para align='center'><b>Medio</b></para>", p_normal), "",
            Paragraph("<para align='center'><b>Atrás</b></para>", p_normal), "",
        ],
        [
            Paragraph("<b>Temp. pulpa</b>", p_label),
            _f(data.get("temp_pulpa_puerta_1")), _f(data.get("temp_pulpa_puerta_2")),
            _f(data.get("temp_pulpa_medio_1")), _f(data.get("temp_pulpa_medio_2")),
            _f(data.get("temp_pulpa_atras_1")), _f(data.get("temp_pulpa_atras_2")),
        ],
        [
            Paragraph("<b>Peso de cajas</b>", p_label),
            _f(data.get("peso_caja_puerta_1")), _f(data.get("peso_caja_puerta_2")),
            _f(data.get("peso_caja_medio_1")), _f(data.get("peso_caja_medio_2")),
            _f(data.get("peso_caja_atras_1")), _f(data.get("peso_caja_atras_2")),
        ],
    ]
    # Calibracion y longitud son un sólo valor por sector → mergeamos en 2 celdas con SPAN
    banano_grid.append([
        Paragraph("<b>Calibración</b>", p_label),
        _f(data.get("calibracion_puerta")), "",
        _f(data.get("calibracion_medio")), "",
        _f(data.get("calibracion_atras")), "",
    ])
    long_unit = data.get("longitud_unidad") or "cm"
    banano_grid.append([
        Paragraph(f"<b>Longitud banano ({long_unit})</b>", p_label),
        _f(data.get("longitud_puerta")), "",
        _f(data.get("longitud_medio")), "",
        _f(data.get("longitud_atras")), "",
    ])
    banano_tbl = Table(banano_grid, colWidths=[3 * cm, 2.5 * cm, 2.5 * cm, 2.5 * cm, 2.5 * cm, 2.5 * cm, 2.5 * cm])
    banano_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
        ("BACKGROUND", (0, 0), (-1, 0), GRIS_BG),
        ("SPAN", (1, 0), (2, 0)),  # Puerta header
        ("SPAN", (3, 0), (4, 0)),  # Medio header
        ("SPAN", (5, 0), (6, 0)),  # Atrás header
        ("SPAN", (1, 3), (2, 3)),  # Calibración Puerta
        ("SPAN", (3, 3), (4, 3)),  # Calibración Medio
        ("SPAN", (5, 3), (6, 3)),  # Calibración Atrás
        ("SPAN", (1, 4), (2, 4)),  # Longitud
        ("SPAN", (3, 4), (4, 4)),
        ("SPAN", (5, 4), (6, 4)),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("ALIGN", (1, 0), (-1, -1), "CENTER"),
        ("FONT", (1, 1), (-1, -1), "Helvetica", 10),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    story.append(banano_tbl)

    # ── Calificaciones (Corona / Quemada / Rameada)
    story.append(Spacer(1, 4))
    calif_grid = [
        [Paragraph("<b>Corona</b>", p_label), Paragraph(_calif_box(data.get("corona")), p_rating)],
        [Paragraph("<b>Quemada</b>", p_label), Paragraph(_calif_box(data.get("quemada")), p_rating)],
        [Paragraph("<b>Rameada</b>", p_label), Paragraph(_calif_box(data.get("rameada")), p_rating)],
    ]
    calif_tbl = Table(calif_grid, colWidths=[3 * cm, 15 * cm])
    calif_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]))
    story.append(calif_tbl)

    # ── Requisitos por fruta del ing. agrónomo (mig 0092). Agrupados por
    #    producto del camión; cada fila es pregunta → respuesta snapshoteada.
    if requisitos:
        story.append(Spacer(1, 8))
        req_header = Table(
            [["", Paragraph("<para align='center'><b>REQUISITOS POR FRUTA (ING. AGRÓNOMO)</b></para>", p_normal)]],
            colWidths=[0.1 * cm, 17.9 * cm],
            style=TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), GRIS_BG),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]),
        )
        story.append(req_header)
        req_rows = []
        for grupo in requisitos:
            prefijo = _icono_img_tag(grupo.get("producto", "")) or ""
            req_rows.append([
                Paragraph(f"{prefijo}<b>{grupo.get('producto', '')}</b>", p_valor), "",
            ])
            for item in grupo.get("items", []):
                req_rows.append([
                    Paragraph(item.get("etiqueta", ""), p_label),
                    Paragraph(_f(item.get("valor")), p_valor),
                ])
        req_tbl = Table(req_rows, colWidths=[8 * cm, 10 * cm])
        req_tbl.setStyle(TableStyle([
            ("GRID", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 4),
            ("RIGHTPADDING", (0, 0), (-1, -1), 4),
            ("TOPPADDING", (0, 0), (-1, -1), 3),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
        ]))
        story.append(req_tbl)

    # ── Firmas / autorizaciones
    story.append(Spacer(1, 8))
    firmas_grid = [
        [Paragraph("<b>Descarga autorizada por</b>", p_label), Paragraph(_f(data.get("descarga_autorizada_por")), p_valor)],
        [Paragraph("<b>Inspección realizada por</b>", p_label), Paragraph(_f(data.get("inspeccion_realizada_por")), p_valor)],
    ]
    firmas_tbl = Table(firmas_grid, colWidths=[5 * cm, 13 * cm])
    firmas_tbl.setStyle(TableStyle([
        ("GRID", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    story.append(firmas_tbl)

    # ── Mercadería recibida (si hay líneas)
    if lineas:
        story.append(Spacer(1, 8))
        merca_header = Table(
            [["", Paragraph("<para align='center'><b>MERCADERÍA RECIBIDA</b></para>", p_normal)]],
            colWidths=[0.1 * cm, 17.9 * cm],
            style=TableStyle([
                ("BACKGROUND", (0, 0), (-1, -1), GRIS_BG),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]),
        )
        story.append(merca_header)

        rows = [[
            Paragraph("<b>Código</b>", p_label),
            Paragraph("<b>Descripción</b>", p_label),
            Paragraph("<para align='right'><b>Cantidad</b></para>", p_label),
            Paragraph("<para align='right'><b>Defectos / reclamos</b></para>", p_label),
        ]]
        total_cant = 0.0
        total_def = 0.0
        for l in lineas:
            defectos = l.get("defectos") or []
            defectos_str = ""
            if defectos:
                bits = []
                for d in defectos:
                    bits.append(f"{d['cantidad']:.2f} {d['motivo']}")
                defectos_str = "<br/>".join(bits)
            # float() explícito: en la EDICIÓN los defectos preservados vienen de
            # la DB como Decimal y `total_def += Decimal` reventaba con TypeError
            # (500 al editar cualquier pie que tuviera defectos).
            cant_def = float(sum(float(d.get("cantidad", 0) or 0) for d in defectos))
            # Sin defectos, un "—" no decía nada: no se sabía si esa fruta vino
            # bien o si nadie la miró. Desde la mig 0072 cada línea trae su
            # respuesta, así que el informe la escribe producto por producto.
            hay_rec_linea = l.get("hay_reclamos")
            if defectos:
                celda, color = defectos_str, colors.HexColor("#DC2626")
            elif hay_rec_linea is False:
                celda, color = "sin reclamos", colors.HexColor("#047857")
            else:
                celda, color = "—", GRIS_TEXTO
            rows.append([
                Paragraph(f"<font face='Helvetica' size=8>{l['cod_art']}</font>", p_normal),
                Paragraph(f"{_icono_img_tag(l['descripcion'])}{l['descripcion']}", p_normal),
                Paragraph(f"<para align='right'>{l['cantidad']:.2f}</para>", p_normal),
                Paragraph(
                    f"<para align='right'>{celda}</para>",
                    ParagraphStyle("d", parent=p_normal, fontSize=8, textColor=color),
                ),
            ])
            total_cant += float(l["cantidad"] or 0)
            total_def += cant_def
        rows.append([
            Paragraph("<b>TOTAL</b>", p_label), "",
            Paragraph(f"<para align='right'><b>{total_cant:.2f}</b></para>", p_normal),
            Paragraph(f"<para align='right'><b><font color='#DC2626'>{total_def:.2f}</font></b></para>", p_normal) if total_def > 0 else "",
        ])
        merca_tbl = Table(rows, colWidths=[2.6 * cm, 9 * cm, 2.3 * cm, 4 * cm])
        merca_tbl.setStyle(TableStyle([
            ("GRID", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
            ("BACKGROUND", (0, 0), (-1, 0), GRIS_BG),
            ("BACKGROUND", (0, -1), (-1, -1), GRIS_BG),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 4),
            ("RIGHTPADDING", (0, 0), (-1, -1), 4),
            ("TOPPADDING", (0, 0), (-1, -1), 4),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ]))
        story.append(merca_tbl)

        # Depósito de ingreso. Dejó de ser una columna (es uno solo para todo el
        # camión) pero NO puede desaparecer del informe: quien confirma el ingreso
        # necesita ver dónde va a entrar el stock.
        deps = []
        for l in lineas:
            et = (l.get("deposito") or "").strip()
            if et and et not in deps:
                deps.append(et)
        if deps:
            desc_de = {
                (l.get("deposito") or "").strip(): (l.get("deposito_descripcion") or "").strip()
                for l in lineas
            }
            etiquetas = ", ".join(f"{d} — {desc_de.get(d)}" if desc_de.get(d) else d for d in deps)
            story.append(Spacer(1, 4))
            story.append(Paragraph(
                f"<b>Depósito de ingreso:</b> {etiquetas}",
                ParagraphStyle("dep", parent=p_normal, fontSize=8.5),
            ))

    # Declaración de reclamos (mig 0071). Antes, una planilla sin defectos era
    # ambigua: no se sabía si la fruta vino bien o si no la revisaron. Ahora el
    # informe lo dice con todas las letras. FUERA del `if lineas`: un pie sin
    # mercadería (el front no lo permite, la API sí) igual tiene que declararlo.
    hay_rec = data.get("hay_reclamos")
    if hay_rec is not None:
        story.append(Spacer(1, 4))
        txt = (
            "<b><font color='#B91C1C'>SE RECLAMA:</font></b> el operario marcó defectos en esta carga."
            if hay_rec else
            "<b><font color='#047857'>SIN RECLAMOS:</font></b> el operario revisó la fruta y declaró que vino bien."
        )
        story.append(Paragraph(txt, ParagraphStyle("hr", parent=p_normal, fontSize=8.5)))

    # ── Total + observaciones
    story.append(Spacer(1, 8))
    total_grid = [[
        Paragraph(f"<b>TOTAL DE CAJAS: </b> {_f(data.get('total_cajas'))}", p_valor),
    ]]
    total_tbl = Table(total_grid, colWidths=[18 * cm])
    total_tbl.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), GRIS_BG),
        ("BOX", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("LEFTPADDING", (0, 0), (-1, -1), 8),
    ]))
    story.append(total_tbl)

    # ── Cámara(s) de ingreso (a dónde entró la fruta)
    camaras = camaras or []
    if camaras:
        story.append(Spacer(1, 4))
        if len(camaras) == 1:
            c = camaras[0]
            camara_txt = f"<b>CÁMARA DE INGRESO: </b> {c.get('ubicacion', '')} {_f(c.get('numero'))}"
            cam_grid = [[Paragraph(camara_txt, p_valor)]]
            cam_widths = [18 * cm]  # ancho completo, como TOTAL DE CAJAS / Observaciones
        else:
            # Reparto en varias cámaras → mini-tabla ubicación · nº | producto | cajas.
            # El producto sale del desglose (cod_art de la fila → descripción de la línea).
            desc_por_cod = {
                (l.get("cod_art") or "").strip(): l.get("descripcion") or ""
                for l in (lineas or [])
            }
            cam_rows = [[
                Paragraph("<b>CÁMARAS DE INGRESO</b>", p_label),
                Paragraph("<b>Producto</b>", p_label),
                Paragraph("<para align='right'><b>Cajas</b></para>", p_label),
            ]]
            for c in camaras:
                desc = desc_por_cod.get((c.get("cod_art") or "").strip(), "")
                cam_rows.append([
                    Paragraph(f"{c.get('ubicacion', '')} <b>{_f(c.get('numero'))}</b>", p_normal),
                    Paragraph(f"{_icono_img_tag(desc)}{desc}" if desc else "—", p_normal),
                    Paragraph("<para align='right'>"
                              + (f"{_f(c.get('cantidad'))} cajas" if c.get("cantidad") is not None else "—")
                              + "</para>", p_normal),
                ])
            cam_grid = cam_rows
            cam_widths = [5 * cm, 9 * cm, 4 * cm]
        cam_style = [
            ("BACKGROUND", (0, 0), (-1, 0), GRIS_BG),
            ("BOX", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ]
        if len(camaras) > 1:
            cam_style.append(("INNERGRID", (0, 1), (-1, -1), 0.3, GRIS_BORDE))
        cam_tbl = Table(cam_grid, colWidths=cam_widths)
        cam_tbl.setStyle(TableStyle(cam_style))
        story.append(cam_tbl)

    if data.get("observaciones"):
        story.append(Spacer(1, 4))
        obs_tbl = Table([[
            Paragraph(f"<b>Observaciones:</b> {data.get('observaciones')}", p_valor),
        ]], colWidths=[18 * cm])
        obs_tbl.setStyle(TableStyle([
            ("BOX", (0, 0), (-1, -1), 0.4, GRIS_BORDE),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
            ("LEFTPADDING", (0, 0), (-1, -1), 8),
        ]))
        story.append(obs_tbl)

    # ── Pie
    story.append(Spacer(1, 12))
    story.append(Paragraph(
        f"<para align='right'><font size=8 color='#64748B'>Generado por <b>{creado_por_nombre}</b> · "
        f"Sistema Aloha</font></para>",
        p_normal,
    ))

    # Las fotos van en un PDF APARTE (generate_piedecamion_fotos_pdf) que se fusiona
    # al descargar — así el informe de datos no re-guarda las fotos (modelo del reclamo).
    doc.build(story)
    return buf.getvalue()


def generate_piedecamion_fotos_pdf(
    *,
    id_documento: int,
    fotos_grupos: list[tuple[str, list[bytes]]] | None,
    titulo: str | None = None,
) -> bytes | None:
    """PDF APARTE con las fotos del pie, agrupadas por categoría (mismo layout que
    antes iba embebido en el informe). Devuelve None si no hay fotos → señal para
    CONSERVAR el fotos-PDF anterior al editar (igual que generate_reclamo_fotos_pdf).
    Se fusiona con el datos-PDF al descargar.

    `titulo`: encabezado opcional arriba de todo. Lo usa el ANEXO de fotos (fotos
    agregadas después de enviar el pie) para que el informe diga cuándo y quién
    las sumó — si no, parecerían tomadas en la recepción."""
    grupos = [(lbl, fs) for lbl, fs in (fotos_grupos or []) if fs]
    if not grupos:
        return None
    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        leftMargin=15 * mm, rightMargin=15 * mm, topMargin=12 * mm, bottomMargin=12 * mm,
        title=f"Fotos pie de camión #{id_documento}", author="Sistema Aloha",
    )
    base = getSampleStyleSheet()
    p_label = ParagraphStyle(
        "l", parent=base["BodyText"], fontName="Helvetica-Bold",
        fontSize=8, leading=10, textColor=GRIS_TEXTO,
    )
    story: list = []
    if titulo:
        p_tit = ParagraphStyle(
            "t", parent=base["BodyText"], fontName="Helvetica-Bold",
            fontSize=10, leading=13, spaceAfter=6, textColor=GRIS_TEXTO,
        )
        story.append(Paragraph(_pdf_esc(titulo), p_tit))
    _append_fotos_grupos(story, grupos, p_label, con_pagebreak=False)
    doc.build(story)
    return buf.getvalue()


# ──────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────


def generate_documentacion_pdf(imagenes: list[bytes], *, id_documento: int) -> bytes:
    """PDF APARTE con la documentación escaneada del pie: una imagen A4 por página
    (ya vienen recortadas/enderezadas desde el celu). Se sube junto al pie y se baja
    aparte en Ingresos. Devuelve bytes vacíos si no hay imágenes válidas."""
    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        leftMargin=8 * mm, rightMargin=8 * mm, topMargin=8 * mm, bottomMargin=8 * mm,
        title=f"Documentacion pie de camion {id_documento}",
    )
    # SimpleDocTemplate rodea su frame con 6pt de padding POR LADO (default de
    # reportlab) ADEMÁS de los márgenes → el área realmente dibujable es 12pt más
    # chica por eje. Sin descontarlo, la imagen escalada al máximo se pasaba ~12pt y
    # reportlab tiraba LayoutError ("Flowable too large") → 500 al enviar el pie
    # (incidente 13/07). +1pt extra de colchón contra redondeos.
    _FRAME_PAD = 6.0  # reportlab Frame.<lado>Padding default
    avail_w = A4[0] - 16 * mm - 2 * _FRAME_PAD - 1
    avail_h = A4[1] - 16 * mm - 2 * _FRAME_PAD - 1
    styles = getSampleStyleSheet()
    story: list = []
    validas = 0
    for i, blob in enumerate(imagenes):
        if validas > 0:
            story.append(PageBreak())
        try:
            # kind="proportional" → entra en la página respetando el aspecto (A4).
            story.append(Image(BytesIO(blob), width=avail_w, height=avail_h, kind="proportional"))
            validas += 1
        except Exception:
            story.append(Paragraph("<font color='#64748B'>(documento inválido)</font>", styles["Normal"]))
            validas += 1
    if validas == 0:
        return b""
    doc.build(story)
    return buf.getvalue()


def _pdf_esc(s: str) -> str:
    """Escapa lo mínimo para el markup de Paragraph de reportlab."""
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _thumb_jpeg(blob: bytes, max_px: int = 1000, quality: int = 80) -> bytes:
    """Reduce una foto a `max_px` de lado mayor y la re-codifica JPEG.

    Las fotos se guardan hasta a 1600px, pero en el anexo se imprimen a ~85mm.
    Pasarle el original a reportlab hacía que, con muchas fotos, la RAM explotara:
    un pie de 49 fotos pegaba un pico de ~1GB y el kernel mataba uvicorn por OOM en
    el server chico (t3.small, 2GB) → 502 al armar el pie/reclamo (incidente 13/07).
    Downscalear ANTES de maquetar corta el pico ~5x. Best-effort: si algo falla,
    devuelve el blob original (nunca rompe el PDF)."""
    try:
        from PIL import Image as PILImage

        im = PILImage.open(BytesIO(blob))
        im.load()
        if im.mode not in ("RGB", "L"):
            im = im.convert("RGB")
        im.thumbnail((max_px, max_px))  # solo achica, preserva el aspecto
        out = BytesIO()
        im.save(out, format="JPEG", quality=quality, optimize=True)
        return out.getvalue()
    except Exception:
        return blob


def _append_fotos_grupos(
    story: list,
    grupos: list[tuple[str, list[bytes]]],
    p_label: ParagraphStyle,
    con_pagebreak: bool = True,
) -> None:
    """Agrega el anexo de fotos AGRUPADO por categoría. Cada grupo se rinde como una
    tabla cuya 1ª fila es una banda con el título de la categoría (ocupa las 2
    columnas) y debajo las fotos en grilla de 2. `repeatRows=1` repite el título si
    el grupo se parte entre páginas → nunca queda huérfano. `con_pagebreak` arranca
    en página nueva (para el fotos-PDF standalone va False: es el primer contenido)."""
    THUMB_W = 85 * mm
    THUMB_H = 64 * mm

    grupos = [(lbl, fs) for lbl, fs in grupos if fs]
    if not grupos:
        return

    if con_pagebreak:
        story.append(PageBreak())
    story.append(Paragraph("<para align='center'><b>FOTOS DEL CAMIÓN</b></para>", p_label))
    story.append(Spacer(1, 8))

    p_titulo = ParagraphStyle("cat", parent=p_label, fontSize=9, textColor=AZUL_OSCURO)

    for label, fotos in grupos:
        # Fila 0 = título de la categoría (span de las 2 columnas).
        rows: list[list] = [[
            Paragraph(
                f"<b>{_pdf_esc(label)}</b> <font size=8 color='#64748B'>"
                f"({len(fotos)})</font>",
                p_titulo,
            ),
            "",
        ]]
        for i in range(0, len(fotos), 2):
            row = []
            for j in (0, 1):
                idx = i + j
                if idx >= len(fotos):
                    row.append("")
                    continue
                try:
                    thumb = _thumb_jpeg(fotos[idx])
                    row.append(Image(BytesIO(thumb), width=THUMB_W, height=THUMB_H, kind="proportional"))
                except Exception:
                    row.append(Paragraph("<font color='#64748B'>(foto inválida)</font>", p_label))
            rows.append(row)

        tbl = Table(rows, colWidths=[90 * mm, 90 * mm], repeatRows=1)
        tbl.setStyle(TableStyle([
            ("SPAN", (0, 0), (1, 0)),                       # el título ocupa las 2 cols
            ("BACKGROUND", (0, 0), (1, 0), colors.HexColor("#EFF6FF")),
            ("LEFTPADDING", (0, 0), (1, 0), 6),
            ("TOPPADDING", (0, 0), (1, 0), 5),
            ("BOTTOMPADDING", (0, 0), (1, 0), 5),
            ("VALIGN", (0, 1), (-1, -1), "MIDDLE"),
            ("ALIGN", (0, 1), (-1, -1), "CENTER"),
            ("TOPPADDING", (0, 1), (-1, -1), 4),
            ("BOTTOMPADDING", (0, 1), (-1, -1), 4),
        ]))
        story.append(tbl)
        story.append(Spacer(1, 8))
