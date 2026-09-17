# Queries de Pie de Camión — TODO contra PostgreSQL (ext.* + legacy.*).
# La única parte de este módulo que sigue tocando SQL Server es el
# "confirmar → ingreso" (INSERT a Cabezal/Lineas de Macrosoft, ver router).

# Lista de columnas DATA del header de PieDeCamion (NO incluye lineas/defectos).
DATA_COLUMNS = [
    "fecha", "fecha_carga", "hora_inicio", "hora_fin",
    "chofer_nombre", "placa_camion",
    "producto", "marca",
    "exportador", "empresa_transporte", "numero_afidi",
    "productor",
    "codigo_importador_camion",
    "intervenido_agronomia", "inspector_agronomo",
    "palet_rating", "palet_comentario",
    "cajas_rating", "cajas_comentario",
    "flejes_rating", "flejes_comentario",
    "temp_pulpa_puerta_1", "temp_pulpa_puerta_2",
    "temp_pulpa_medio_1", "temp_pulpa_medio_2",
    "temp_pulpa_atras_1", "temp_pulpa_atras_2",
    "peso_caja_puerta_1", "peso_caja_puerta_2",
    "peso_caja_medio_1", "peso_caja_medio_2",
    "peso_caja_atras_1", "peso_caja_atras_2",
    "calibracion_puerta", "calibracion_medio", "calibracion_atras",
    "longitud_puerta", "longitud_medio", "longitud_atras", "longitud_unidad",
    "corona", "quemada", "rameada",
    "descarga_autorizada_por", "inspeccion_realizada_por",
    "total_cajas", "observaciones",
    "plan_carga_id",
    # Respuesta OBLIGATORIA de "¿Hay reclamos para esta fruta?" (mig 0071).
    # NULL = pie viejo, de antes de que se preguntara.
    "hay_reclamos",
]


# Update del Plan de Cargas → Descargado cuando se confirma el pie de camión.
UPDATE_PLAN_CARGA_DESCARGADO_SQL = """
UPDATE ext.plan_de_cargas
SET status = 'Descargado',
    actualizado_en = now(),
    actualizado_por_usuario_id = %s,
    -- Si no tenía fecha_descarga, le ponemos la del pie de camión.
    fecha_descarga = COALESCE(fecha_descarga, %s)
WHERE id = %s AND status NOT IN ('Descargado', 'Cancelado')
"""


# Idempotencia (mig 0058): ¿ya existe un pie con este client_ref?
PIE_POR_CLIENT_REF_SQL = """
SELECT id FROM ext.pie_de_camion WHERE client_ref = %s
"""


def build_insert_sql() -> str:
    # client_ref va aparte de DATA_COLUMNS a propósito: el UPDATE de edición
    # (build_update_data_sql) usa DATA_COLUMNS y NO debe pisar el client_ref.
    base_cols = DATA_COLUMNS + [
        "client_ref", "pdf_filename", "pdf_blob", "pdf_size_bytes", "creado_por_usuario_id",
    ]
    placeholders = ", ".join(["%s"] * len(base_cols))
    cols_str = ", ".join(base_cols)
    return f"""
INSERT INTO ext.pie_de_camion ({cols_str})
VALUES ({placeholders})
RETURNING id
"""


def build_update_data_sql() -> str:
    """UPDATE de todos los campos DATA del header (para editar el pie desde Ingresos).
    Marca editado_en/por. Params: (…DATA_COLUMNS…, editado_por_usuario_id, id)."""
    sets = ", ".join(f"{c} = %s" for c in DATA_COLUMNS)
    # WHERE incluye estado='pendiente' → race-safe: si un confirmar se coló entre el
    # chequeo y el UPDATE, afecta 0 filas y el router aborta la tx (rowcount != 1).
    return f"""
UPDATE ext.pie_de_camion
SET {sets},
    editado_en = now() AT TIME ZONE 'UTC',
    editado_por_usuario_id = %s
WHERE id = %s AND estado = 'pendiente'
"""


# Edición: borrar los hijos para re-insertarlos (los defectos se preservan aparte,
# por cod_art — ver el router). El reclamo y las fotos NO se tocan.
DELETE_PRODUCTOS_SQL = "DELETE FROM ext.pie_de_camion_producto WHERE pie_camion_id = %s"
DELETE_CAMARAS_SQL = "DELETE FROM ext.pie_de_camion_camara WHERE pie_camion_id = %s"
DELETE_LINEAS_SQL = "DELETE FROM ext.pie_de_camion_linea WHERE pie_camion_id = %s"  # CASCADE defectos

# Snapshot de defectos existentes por cod_art (para re-adjuntarlos a la línea del
# mismo cod_art tras editar → los reclamos quedan intactos aunque cambie la cantidad).
GET_DEFECTOS_POR_COD_SQL = """
SELECT BTRIM(l.cod_art) AS cod_art, d.motivo_id, d.cantidad, d.notas, d.cantidad_fotos
FROM ext.pie_de_camion_linea l
JOIN ext.pie_de_camion_defecto d ON d.pie_camion_linea_id = l.id
WHERE l.pie_camion_id = %s
ORDER BY l.orden, l.id, d.id
"""

# Fotos del pie para RE-GENERAR el informe al editar (blob + categoría + label) en
# orden — el router las agrupa igual que en el create (categorizadas + "Otras").
GET_FOTOS_PARA_PDF_SQL = """
SELECT foto_blob, foto_s3_key, categoria, caption
FROM ext.pie_de_camion_foto
WHERE pie_camion_id = %s
ORDER BY orden, id
"""


INSERT_LINEA_SQL = """
INSERT INTO ext.pie_de_camion_linea
    (pie_camion_id, cod_art, descripcion, deposito, cantidad, marca, orden, hay_reclamos)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
RETURNING id
"""

INSERT_PRODUCTO_SQL = """
INSERT INTO ext.pie_de_camion_producto
    (pie_camion_id, producto, marca, orden)
VALUES (%s, %s, %s, %s)
"""

INSERT_CAMARA_SQL = """
INSERT INTO ext.pie_de_camion_camara
    (pie_camion_id, ubicacion, numero, cantidad, cod_art, orden)
VALUES (%s, %s, %s, %s, %s, %s)
"""

GET_CAMARAS_SQL = """
SELECT BTRIM(ubicacion) AS ubicacion, numero, cantidad, BTRIM(cod_art) AS cod_art
FROM ext.pie_de_camion_camara
WHERE pie_camion_id = %s
ORDER BY orden, id
"""

GET_PRODUCTOS_SQL = """
SELECT producto, marca
FROM ext.pie_de_camion_producto
WHERE pie_camion_id = %s
ORDER BY orden, id
"""

# Datos del pie para el webhook saliente (confirmar → estado ingresado). Trae los
# campos del payload + el país de origen del plan (si estaba linkeado). Las cámaras
# y productos se traen aparte (GET_CAMARAS_SQL / GET_PRODUCTOS_SQL).
WEBHOOK_PIE_SQL = """
SELECT p.id, BTRIM(p.estado) AS estado, p.fecha, p.fecha_carga, p.hora_inicio, p.hora_fin,
       p.chofer_nombre, p.placa_camion, p.exportador, p.empresa_transporte,
       p.productor, p.codigo_importador_camion, p.numero_afidi, p.total_cajas, p.producto,
       p.temp_pulpa_puerta_1, p.temp_pulpa_puerta_2, p.temp_pulpa_medio_1, p.temp_pulpa_medio_2,
       p.temp_pulpa_atras_1, p.temp_pulpa_atras_2,
       p.peso_caja_puerta_1, p.peso_caja_puerta_2, p.peso_caja_medio_1, p.peso_caja_medio_2,
       p.peso_caja_atras_1, p.peso_caja_atras_2,
       p.calibracion_puerta, p.calibracion_medio, p.calibracion_atras,
       p.corona, p.quemada, p.rameada,
       pc.pais_origen
FROM ext.pie_de_camion p
LEFT JOIN ext.plan_de_cargas pc ON pc.id = p.plan_carga_id
WHERE p.id = %s
"""

INSERT_DEFECTO_SQL = """
INSERT INTO ext.pie_de_camion_defecto
    (pie_camion_linea_id, motivo_id, cantidad, notas, cantidad_fotos)
VALUES (%s, %s, %s, %s, %s)
"""

UPDATE_PDF_SQL = """
UPDATE ext.pie_de_camion
SET pdf_blob = %s, pdf_size_bytes = %s, pdf_filename = %s, pdf_s3_key = NULL
WHERE id = %s
"""

# PDF de FOTOS del pie (aparte del informe de datos; se fusiona al descargar).
# Re-subir reemplaza el blob y resetea el s3_key (el offload lo re-sube).
UPDATE_FOTOS_PDF_SQL = """
UPDATE ext.pie_de_camion
SET fotos_pdf_blob = %s, fotos_pdf_size_bytes = %s, fotos_pdf_s3_key = NULL
WHERE id = %s
"""

# Anexar fotos a un pie ya enviado (mig 0069): mismo reemplazo del blob que
# UPDATE_FOTOS_PDF_SQL (el PDF nuevo = el viejo + las páginas nuevas) pero
# dejando la auditoría del anexo.
ANEXAR_FOTOS_PDF_SQL = """
UPDATE ext.pie_de_camion
SET fotos_pdf_blob = %s, fotos_pdf_size_bytes = %s, fotos_pdf_s3_key = NULL,
    fotos_anexos_n = COALESCE(fotos_anexos_n, 0) + 1,
    fotos_anexo_en = now(), fotos_anexo_por = %s
WHERE id = %s
"""

# Estado actual del fotos-PDF de un pie (para decidir si anexar o crear).
GET_FOTOS_PDF_SQL = """
SELECT fotos_pdf_blob, fotos_pdf_s3_key, COALESCE(fotos_anexos_n, 0) AS anexos_n
FROM ext.pie_de_camion WHERE id = %s
"""

# PDF de documentación escaneada (aparte de la planilla).
UPDATE_DOC_PDF_SQL = """
UPDATE ext.pie_de_camion
SET doc_pdf_blob = %s, doc_pdf_size_bytes = %s, doc_pdf_filename = %s
WHERE id = %s
"""

GET_DOC_PDF_SQL = """
SELECT doc_pdf_filename, doc_pdf_blob, doc_pdf_s3_key FROM ext.pie_de_camion WHERE id = %s
"""

# PDF del termógrafo (cadena de frío). Se guarda aparte; el download de la planilla
# lo fusiona al final. Re-subir reemplaza el blob y resetea el s3_key (el nuevo blob
# todavía no está en S3 → el offload lo re-sube con la misma key).
UPDATE_TERMOGRAFO_PDF_SQL = """
UPDATE ext.pie_de_camion
SET termografo_pdf_blob = %s, termografo_pdf_size_bytes = %s,
    termografo_pdf_filename = %s, termografo_pdf_s3_key = NULL
WHERE id = %s
"""

GET_TERMOGRAFO_PDF_SQL = """
SELECT termografo_pdf_filename, termografo_pdf_blob, termografo_pdf_s3_key
FROM ext.pie_de_camion WHERE id = %s
"""

# Borra el termógrafo adjunto (si lo subieron mal). Limpia las 4 columnas; la
# planilla base no se toca (el /pdf deja de fusionar y sirve la planilla sola).
CLEAR_TERMOGRAFO_PDF_SQL = """
UPDATE ext.pie_de_camion
SET termografo_pdf_blob = NULL, termografo_pdf_size_bytes = NULL,
    termografo_pdf_filename = NULL, termografo_pdf_s3_key = NULL
WHERE id = %s
"""

UPDATE_RECLAMO_ID_SQL = """
UPDATE ext.pie_de_camion
SET reclamo_id = %s
WHERE id = %s
"""


_LIST_SELECT = """
SELECT
    p.id, p.fecha, p.hora_inicio, p.hora_fin,
    p.chofer_nombre, p.placa_camion,
    p.producto, p.exportador, p.empresa_transporte, p.numero_afidi,
    p.codigo_importador_camion,
    p.total_cajas, p.pdf_filename, p.pdf_size_bytes, p.doc_pdf_size_bytes,
    p.termografo_pdf_size_bytes, p.termografo_pdf_filename,
    p.creado_en, p.estado, p.ingreso_documento, p.ingreso_nro_fact, p.confirmando_en,
    p.confirmado_en, p.reclamo_id, p.descargado_en, p.hay_reclamos,
    -- Fotos agregadas DESPUÉS de enviar el pie (mig 0069): la lista lo muestra
    -- para que se note que el informe tiene un anexo.
    COALESCE(p.fotos_anexos_n, 0) AS fotos_anexos_n, p.fotos_anexo_en,
    u.nombre AS creado_por_nombre, u.username AS creado_por_username,
    uc.nombre AS confirmado_por_nombre, uc.username AS confirmado_por_username,
    (SELECT COUNT(*) FROM ext.pie_de_camion_linea l WHERE l.pie_camion_id = p.id) AS n_lineas,
    COALESCE((SELECT SUM(l.cantidad) FROM ext.pie_de_camion_linea l WHERE l.pie_camion_id = p.id), 0) AS cantidad_total,
    COALESCE((
        SELECT SUM(d.cantidad)
        FROM ext.pie_de_camion_defecto d
        JOIN ext.pie_de_camion_linea l ON l.id = d.pie_camion_linea_id
        WHERE l.pie_camion_id = p.id
    ), 0) AS cantidad_defectuosa_total,
    -- Descripción + cantidad de cada línea (para derivar los íconos de fruta en
    -- el router). json_agg = NULL si el pie no tiene líneas.
    (SELECT json_agg(json_build_object('d', l.descripcion, 'c', l.cantidad))
     FROM ext.pie_de_camion_linea l WHERE l.pie_camion_id = p.id) AS lineas_iconos
FROM ext.pie_de_camion p
LEFT JOIN ext.usuarios u ON u.id = p.creado_por_usuario_id
LEFT JOIN ext.usuarios uc ON uc.id = p.confirmado_por_usuario_id
"""

LIST_SQL = _LIST_SELECT + """
ORDER BY
    -- Pendientes primero (es la cola de trabajo a confirmar).
    CASE p.estado WHEN 'pendiente' THEN 0 ELSE 1 END,
    -- Pendientes: lo ÚLTIMO CARGADO arriba (por id = orden de creación), así un
    -- pie nuevo con fecha de descarga vieja no queda enterrado al fondo.
    CASE WHEN p.estado = 'pendiente' THEN p.id END DESC,
    -- Historial (confirmados/anulados): por fecha de descarga, más nueva primero.
    p.fecha DESC, p.id DESC
LIMIT 200
"""

# Una sola fila, misma forma que LIST_SQL (para el response post-create/confirm).
GET_ONE_ITEM_SQL = _LIST_SELECT + " WHERE p.id = %s"

# Buscar el pie por CÓDIGO de importador (para el escaneo QR desde Aloha). El más
# reciente no anulado. Con códigos a mano puede repetirse → toma el último; con la
# autogeneración (única, pendiente) queda 1:1.
GET_ONE_BY_CODIGO_SQL = (
    _LIST_SELECT
    + " WHERE BTRIM(UPPER(p.codigo_importador_camion)) = BTRIM(UPPER(%s))"
      " AND p.estado <> 'anulado' ORDER BY p.id DESC LIMIT 1"
)

# Lookup del QR de la etiqueta: matchea por código + placa (la placa filtra sólo si
# viene no vacía). Devuelve TODOS los candidatos no anulados (el router prefiere la
# fecha exacta y, si queda >1, el front muestra una lista). %s = (codigo, placa, placa).
LIST_BY_CODIGO_SQL = (
    _LIST_SELECT
    + " WHERE BTRIM(UPPER(p.codigo_importador_camion)) = BTRIM(UPPER(%s))"
      " AND (BTRIM(%s) = '' OR BTRIM(UPPER(p.placa_camion)) = BTRIM(UPPER(%s)))"
      " AND p.estado <> 'anulado' ORDER BY p.id DESC"
)

# Plan B del QR: la etiqueta pudo imprimirse con un código DISTINTO al que después
# le cargaron al pie (pasó de verdad: etiqueta "EXOTICO", pie "MK017 / EXOTICO").
# La PLACA del QR identifica el camión igual (el router prefiere la fecha exacta).
LIST_BY_PLACA_SQL = (
    _LIST_SELECT
    + " WHERE BTRIM(UPPER(p.placa_camion)) = BTRIM(UPPER(%s))"
      " AND p.estado <> 'anulado' ORDER BY p.id DESC LIMIT 10"
)

# Plan C: código PARCIAL — contención en cualquier dirección ("EXOTICO" matchea un
# pie "MK017 / EXOTICO" y viceversa). POSITION en vez de LIKE para no tener que
# escapar %/_ del input. El código vacío del pie queda afuera (matchearía todo).
LIST_BY_CODIGO_PARCIAL_SQL = (
    _LIST_SELECT
    + """ WHERE COALESCE(BTRIM(p.codigo_importador_camion), '') <> ''
      AND (
           POSITION(BTRIM(UPPER(%s)) IN BTRIM(UPPER(p.codigo_importador_camion))) > 0
        OR POSITION(BTRIM(UPPER(p.codigo_importador_camion)) IN BTRIM(UPPER(%s))) > 0
      )
      AND (BTRIM(%s) = '' OR BTRIM(UPPER(p.placa_camion)) = BTRIM(UPPER(%s)))
      AND p.estado <> 'anulado' ORDER BY p.id DESC LIMIT 10"""
)

# Marca el pie de camión como "descargado/revisado" (lo llama Ingresos al bajar la
# planilla). Compartido: los celus son un pool común, así todos ven cuáles se
# revisaron. Idempotente: re-descargar sólo actualiza la fecha/usuario.
MARCAR_DESCARGADO_SQL = """
UPDATE ext.pie_de_camion
SET descargado_en = now(), descargado_por_usuario_id = %s
WHERE id = %s
"""


GET_DETAIL_SQL_TPL = """
SELECT p.id, p.creado_en, p.pdf_filename, p.pdf_size_bytes,
       p.estado, p.ingreso_documento, p.ingreso_nro_fact, p.confirmando_en,
       p.confirmado_en, p.reclamo_id,
       -- Observaciones del RECLAMO (no del pie): el editar-reclamo las pre-carga
       -- para que no se pierdan al re-hacerlo.
       (SELECT r.observaciones FROM ext.reclamo r WHERE r.id = p.reclamo_id) AS reclamo_observaciones,
       -- ¿El reclamo tiene doc de fotos aparte (post-0047)? El front elige el
       -- aviso al editar: conservadas (doc aparte) vs. perdidas (PDF único viejo).
       (SELECT r.fotos_pdf_blob IS NOT NULL OR r.fotos_pdf_s3_key IS NOT NULL
          FROM ext.reclamo r WHERE r.id = p.reclamo_id) AS reclamo_tiene_fotos_pdf,
       u.nombre AS creado_por_nombre, u.username AS creado_por_username,
       uc.nombre AS confirmado_por_nombre, uc.username AS confirmado_por_username,
       -- Anexos de fotos (mig 0069): Ingresos muestra "+N" al lado del botón.
       COALESCE(p.fotos_anexos_n, 0) AS fotos_anexos_n, p.fotos_anexo_en,
       {data_cols}
FROM ext.pie_de_camion p
LEFT JOIN ext.usuarios u ON u.id = p.creado_por_usuario_id
LEFT JOIN ext.usuarios uc ON uc.id = p.confirmado_por_usuario_id
WHERE p.id = %s
"""


def build_get_detail_sql() -> str:
    return GET_DETAIL_SQL_TPL.format(
        data_cols=", ".join(f"p.{c}" for c in DATA_COLUMNS),
    )


GET_PDF_SQL = """
SELECT pdf_filename, pdf_blob, pdf_s3_key,
       fotos_pdf_blob, fotos_pdf_s3_key,
       termografo_pdf_blob, termografo_pdf_s3_key
FROM ext.pie_de_camion WHERE id = %s
"""


GET_LINEAS_SQL = """
SELECT l.id, BTRIM(l.cod_art) AS cod_art, BTRIM(l.descripcion) AS descripcion,
       BTRIM(l.deposito) AS deposito,
       BTRIM(d.Descripcion) AS deposito_descripcion,
       CAST(l.cantidad AS FLOAT) AS cantidad,
       BTRIM(l.marca) AS marca,
       l.hay_reclamos,
       COALESCE((SELECT SUM(df.cantidad) FROM ext.pie_de_camion_defecto df WHERE df.pie_camion_linea_id = l.id), 0) AS cantidad_defectuosa
FROM ext.pie_de_camion_linea l
LEFT JOIN legacy.deposito d ON BTRIM(d.Deposito) = BTRIM(l.deposito)
WHERE l.pie_camion_id = %s
ORDER BY l.orden, l.id
"""

GET_LINEA_DEFECTOS_SQL = """
SELECT df.motivo_id, dm.nombre AS motivo, CAST(df.cantidad AS FLOAT) AS cantidad,
       df.notas, df.cantidad_fotos
FROM ext.pie_de_camion_defecto df
JOIN ext.defecto_motivo dm ON dm.id = df.motivo_id
WHERE df.pie_camion_linea_id = %s
ORDER BY df.id
"""

# Borra TODOS los defectos de las líneas de un pie (para re-hacer el reclamo:
# los defectos nuevos del PUT reemplazan a los anteriores).
DELETE_DEFECTOS_DEL_PIE_SQL = """
DELETE FROM ext.pie_de_camion_defecto
WHERE pie_camion_linea_id IN (
    SELECT id FROM ext.pie_de_camion_linea WHERE pie_camion_id = %s
)
"""

# Re-generar el reclamo (editar): pisa el INFORME + observaciones. Conserva
# generado_en y generado_por (la fecha real del reclamo — re-fecharlo lo hacía
# "reaparecer" como nuevo en los listados). pdf_s3_key=NULL → el offload re-sube
# el nuevo. Las fotos (fotos_pdf_*) NO se tocan acá: se conservan salvo que la
# edición traiga fotos nuevas (UPDATE_RECLAMO_FOTOS_SQL).
UPDATE_RECLAMO_SQL = """
UPDATE ext.reclamo
SET observaciones = %s, pdf_filename = %s, pdf_blob = %s, pdf_size_bytes = %s,
    pdf_s3_key = NULL
WHERE id = %s
"""

# La edición trajo fotos nuevas → por defecto se ANEXAN a las que ya había (el
# router hace el merge); sólo reemplazan si lo piden explícito.
UPDATE_RECLAMO_FOTOS_SQL = """
UPDATE ext.reclamo
SET fotos_pdf_blob = %s, fotos_pdf_size_bytes = %s, fotos_pdf_s3_key = NULL
WHERE id = %s
"""

DELETE_RECLAMO_LINEAS_SQL = "DELETE FROM ext.reclamo_linea WHERE reclamo_id = %s"


# Para el confirmar-ingreso (mig 0112): RESERVAR antes de tocar Macrosoft.
# Devuelve fila sólo si el pie estaba pendiente Y libre; el segundo click no
# saca fila y el router corta con 409 SIN haber escrito nada en Macrosoft.
RESERVAR_CONFIRMACION_SQL = """
UPDATE ext.pie_de_camion
SET confirmando_en = now(), confirmando_por_usuario_id = %s
WHERE id = %s AND estado = 'pendiente' AND confirmando_en IS NULL
RETURNING id
"""

# Se libera SÓLO si Macrosoft no llegó a commitear (mismo criterio que el
# tomador con LIBERAR_ENVIO_SQL). Si Macrosoft escribió, la reserva QUEDA: es la
# marca de que hay un documento dando vueltas y que el pie no se puede reintentar
# a ciegas.
LIBERAR_CONFIRMACION_SQL = """
UPDATE ext.pie_de_camion
SET confirmando_en = NULL, confirmando_por_usuario_id = NULL
WHERE id = %s AND estado = 'pendiente'
"""

# Para el confirmar-ingreso:
CONFIRMAR_INGRESO_SQL = """
UPDATE ext.pie_de_camion
SET estado = 'ingresado',
    confirmando_en = NULL,
    confirmando_por_usuario_id = NULL,
    ingreso_documento = %s,
    ingreso_nro_fact = %s,
    confirmado_por_usuario_id = %s,
    confirmado_en = now()
WHERE id = %s AND estado = 'pendiente'
"""

# Backfill del link reclamo→movimiento al confirmar. Por pie_camion_id (no por un
# reclamo_id leído antes): un reclamo post-hoc pudo commitear DESPUÉS de que el
# confirmar leyó el pie — con el id stale quedaba huérfano para siempre.
UPDATE_RECLAMO_INGRESO_SQL = """
UPDATE ext.reclamo
SET documento = %s, nro_fact = %s
WHERE pie_camion_id = %s AND documento IS NULL
"""

# Metadata Aloha del ingreso creado en Macrosoft (la tabla vive en PG).
INSERT_META_SQL = """
INSERT INTO ext.movimiento_stock_meta (documento, nro_fact, usuario_id)
VALUES (%s, %s, %s)
"""

# Validaciones contra el mirror legacy (catálogo Macrosoft en PG).
ARTICULO_EXISTS_SQL = """
SELECT 1 AS x FROM legacy.articulos WHERE BTRIM(CodArticulo) = %s
"""

ARTICULO_DESCRIPCION_SQL = """
SELECT BTRIM(Descripcion) AS descripcion FROM legacy.articulos WHERE BTRIM(CodArticulo) = %s
"""

DEPOSITO_DESCRIPCION_SQL = """
SELECT BTRIM(Descripcion) AS descripcion FROM legacy.deposito WHERE BTRIM(Deposito) = %s
"""

PROVEEDOR_DE_ARTICULO_SQL = """
SELECT BTRIM(c.Nombre) AS nombre
FROM legacy.articulosproveedor ap
JOIN legacy.clientes c ON c.CodCliente = ap.CodCliente
WHERE BTRIM(ap.CodArticulo) = %s
ORDER BY ap.CodCliente
LIMIT 1
"""

PLAN_CARGA_STATUS_SQL = """
SELECT id, status FROM ext.plan_de_cargas WHERE id = %s
"""


# ── Etiquetas Zebra: código de importador asociado al camión (mig 0073) ──
# Upsert por (placa, fecha): la última impresión pisa a la anterior — vale el
# papel que quedó pegado en los pallets.
UPSERT_ETIQUETA_SQL = """
INSERT INTO ext.etiqueta_camion (placa, fecha, codigo, cantidad, plan_carga_id, usuario_id)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (placa, fecha) DO UPDATE
   SET codigo        = EXCLUDED.codigo,
       cantidad      = EXCLUDED.cantidad,
       plan_carga_id = COALESCE(EXCLUDED.plan_carga_id, ext.etiqueta_camion.plan_carga_id),
       usuario_id    = EXCLUDED.usuario_id,
       impreso_en    = now()
RETURNING placa, fecha, codigo, cantidad, impreso_en,
          (SELECT COALESCE(u.nombre, u.username) FROM ext.usuarios u
            WHERE u.id = ext.etiqueta_camion.usuario_id) AS impreso_por
"""

GET_ETIQUETA_SQL = """
SELECT e.placa, e.fecha, BTRIM(e.codigo) AS codigo, e.cantidad, e.impreso_en,
       COALESCE(u.nombre, u.username) AS impreso_por
FROM ext.etiqueta_camion e
LEFT JOIN ext.usuarios u ON u.id = e.usuario_id
WHERE e.placa = %s AND e.fecha = %s
"""


# Fotos ya cargadas por defecto (cod_art + motivo), para que re-hacer el reclamo
# sin volver a subirlas no las deje en 0: la foto sigue en el PDF, y el contador
# tiene que decir la verdad.
FOTOS_PREVIAS_POR_DEFECTO_SQL = """
SELECT BTRIM(l.cod_art) AS cod_art, d.motivo_id, MAX(d.cantidad_fotos) AS cantidad_fotos
FROM ext.pie_de_camion_defecto d
JOIN ext.pie_de_camion_linea l ON l.id = d.pie_camion_linea_id
WHERE l.pie_camion_id = %s AND COALESCE(d.cantidad_fotos, 0) > 0
GROUP BY 1, 2
"""

# El doc de fotos que ya tiene el reclamo (para anexarle las nuevas).
GET_RECLAMO_FOTOS_SQL = """
SELECT fotos_pdf_blob, fotos_pdf_s3_key FROM ext.reclamo WHERE id = %s
"""


# ── Requisitos por fruta (mig 0092): config del ing. agrónomo ──────────────

LIST_REQUISITOS_SQL = """
SELECT id, BTRIM(categoria) AS categoria, BTRIM(tipo) AS tipo,
       BTRIM(etiqueta) AS etiqueta, BTRIM(unidad) AS unidad, opciones,
       obligatorio, orden, activo
FROM ext.pie_requisito
WHERE (%s OR activo)
ORDER BY categoria, orden, id
"""

INSERT_REQUISITO_SQL = """
INSERT INTO ext.pie_requisito
    (categoria, tipo, etiqueta, unidad, opciones, obligatorio, orden,
     activo, creado_por_usuario_id)
VALUES (%s, %s, %s, %s, %s, %s, %s, true, %s)
RETURNING id
"""

UPDATE_REQUISITO_SQL = """
UPDATE ext.pie_requisito
SET tipo = %s, etiqueta = %s, unidad = %s, opciones = %s, obligatorio = %s,
    orden = %s, activo = true, actualizado_en = now()
WHERE id = %s AND categoria = %s
RETURNING id
"""

DESACTIVAR_REQUISITOS_SQL = """
UPDATE ext.pie_requisito
SET activo = false, actualizado_en = now()
WHERE categoria = %s AND activo AND NOT (id = ANY(%s))
"""

INSERT_REQUISITO_RESPUESTA_SQL = """
INSERT INTO ext.pie_requisito_respuesta
    (pie_camion_id, requisito_id, producto, categoria, tipo, etiqueta,
     unidad, valor_numero, valor_texto, fotos_n, orden)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
"""

GET_RESPUESTAS_SQL = """
SELECT requisito_id, BTRIM(producto) AS producto, BTRIM(categoria) AS categoria,
       BTRIM(tipo) AS tipo, BTRIM(etiqueta) AS etiqueta, BTRIM(unidad) AS unidad,
       valor_numero, valor_texto, fotos_n, orden
FROM ext.pie_requisito_respuesta
WHERE pie_camion_id = %s
ORDER BY orden, id
"""

DELETE_RESPUESTAS_SQL = "DELETE FROM ext.pie_requisito_respuesta WHERE pie_camion_id = %s"
