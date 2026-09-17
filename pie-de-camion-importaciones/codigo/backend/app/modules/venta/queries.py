# Módulo VENTA — pedidos del vendedor (reemplazo del "Tomador de pedidos").
#
# Escrituras: SQL Server de Macrosoft vía app.db.get_venta_cursor (dev: GestionPepe
# de testing; prod: Macrosoft REAL. Acceso por permiso `venta`).
# Lecturas: espejo legacy.* + metadata ext.* en Postgres (app.pg).
#
# El contrato del pedido '30' está relevado y VERIFICADO campo a campo contra el
# legacy (14/07/2026) — ver memoria reference_tomador_pedidos_macrosoft. Resumen:
#  - Cola de caja = FACTURADO=0 AND ANULADA=0 (ESTADO nace vacío).
#  - Numeración DOBLE: NROFACT=MAX+1 de Cabezal2, NRODOC=Documentos.NroDocumento+1
#    (con UPDATE del contador), en la MISMA transacción.
#  - Precio unitario CON IVA incluido; IVA por línea (Articulos.Iva es CÓDIGO,
#    mapear por tabla Ivas: 1→0.22, 2→0.10, 3→0).
#  - El pedido NO descuenta stock (lo descuenta la factura de caja).

# ── SQL Server (Macrosoft) ───────────────────────────────────────────────

# Próximo NROFACT: secuencia densa global de Cabezal2 (índice UNIQUE en NROFACT
# lo fuerza). UPDLOCK+HOLDLOCK serializa contra otro pedido concurrente.
NEXT_NROFACT_MSSQL = """
SELECT ISNULL(MAX(NROFACT), 0) + 1 AS next_fact FROM Cabezal2 WITH (UPDLOCK, HOLDLOCK)
"""

# Contador oficial de NRODOC del documento '30' (guarda el ÚLTIMO usado).
GET_NRODOC_MSSQL = """
SELECT NroDocumento FROM Documentos WITH (UPDLOCK, HOLDLOCK) WHERE RTRIM(Documento) = '30'
"""
UPDATE_NRODOC_MSSQL = """
UPDATE Documentos SET NroDocumento = %s WHERE RTRIM(Documento) = '30'
"""

# Plantilla del cabezal, calcada del tomador real (0 desvíos en 5.606 pedidos de
# mayo/2026). Fijos: TIPDOC='RD', TIPO='C', USUARIO='Restapi' (así escribe la app
# original — es su API REST; imitarlo = indistinguible para caja), FORMULARIO='P',
# AOB='A', IVAINCLUIDO=1, ESTADO='' (nace vacío), FACTURADO=0, ANULADA=0.
INSERT_CABEZAL2_MSSQL = """
INSERT INTO Cabezal2 (
    TIPDOC, FECHA, CONSUMOFINAL, ORDEN, NOMBRE, DIRECCION, RUC,
    DOCUMENTO, NROFACT, NRODOC, CODVENDEDOR, CODCLIENTE, LISTADEPRECIO,
    MONEDA, TIPOCAMBIO, UNIDADES, SUBTOTALDEBE, IVADEBE, COFISDEBE, TOTALDEBE,
    SUBTOTALHABER, IVAHABER, COFISHABER, TOTALHABER, REDONDEO,
    ENCUOTAS, [PLAN], VENCIMIENTO, SALDO, DESCUENTO, HORA, ANULADA,
    OBSERVACIONES, TIPO, USUARIO, FORMULARIO, REPARTO, NROREPARTO,
    CONTABILIZADO, CERTIFICAIVA, FACTURADO, IVAINCLUIDO, AOB, ESTADO,
    REFERENCIA, COMISION, Retencion, Validado, PLAZO
) VALUES (
    'RD', %s, %s, '', %s, %s, %s,
    '30  ', %s, %s, %s, %s, %s,
    %s, 0, %s, %s, %s, 0, %s,
    0, 0, 0, 0, 0,
    %s, 0, NULL, %s, 0, %s, 0,
    %s, 'C', 'Restapi', 'P', 0, 0,
    0, 0, 0, 1, 'A', '',
    '', 0, 0, 0, NULL
)
"""

# Línea: Precio IVA incluido, TotalSinIva/IvaLinea calculados POR LÍNEA (el junk
# DEV de junio los clonaba de la 1ª línea — bug conocido a NO repetir), NroDoc =
# NRODOC del cabezal (¡no el NROFACT!), Fecha = FECHA del cabezal. ID es IDENTITY.
INSERT_LINEA2_MSSQL = """
INSERT INTO Lineas2 (
    Fecha, Documento, NroFact, NroDoc, DocRef, Referencia, EsPorDto,
    Deposito, CodArt, Descripcion, Ubicacion,
    CantidadDebe, CantidadHaber, Iva, Moneda,
    Precio, PrecioSugerido, Descuento, Descuento1, Cofis,
    IvaLinea, TotalSinIva, TotalSinDto, TotalLinea,
    Oculto, PagoACuenta, CertificaIva, NoStock, IvaIncluido, AoB, Serie,
    BultosDebe, BultosHaber
) VALUES (
    %s, '30  ', %s, %s, NULL, NULL, NULL,
    %s, %s, %s, '',
    0, %s, %s, %s,
    %s, NULL, 0, NULL, NULL,
    %s, %s, %s, %s,
    NULL, NULL, 0, NULL, 1, 'A', '',
    NULL, NULL
)
"""

# Anular: mismo efecto que la app original para la cola de caja (ANULADA=1 +
# FACTURADO=1 → sale por ambos flags), pero SIN borrar las líneas ni pisar el
# NOMBRE (decisión 14/07: no destruir datos; caja lo ve igual de anulado).
# El WHERE con FACTURADO=0 es el guard optimista: si caja lo facturó en el medio,
# rowcount=0 → 409.
ANULAR_PEDIDO_MSSQL = """
UPDATE Cabezal2 SET ANULADA = 1, FACTURADO = 1
WHERE DOCUMENTO = '30  ' AND NROFACT = %s AND FACTURADO = 0 AND ANULADA = 0
"""

# Readback post-commit para el dual-write al espejo (mismo patrón que ingresos):
# copiamos lo que REALMENTE quedó en Macrosoft, no lo que creemos haber escrito.
READBACK_CABEZAL2_MSSQL = """
SELECT DOCUMENTO, NROFACT, NRODOC, FECHA, HORA, NOMBRE, CODCLIENTE, CODVENDEDOR,
       ESTADO, OBSERVACIONES, FACTURADO, TOTALHABER, ANULADA, DIRECCION,
       TOTALDEBE, ENCUOTAS, CONSUMOFINAL
FROM Cabezal2 WHERE DOCUMENTO = '30  ' AND NROFACT = %s
"""
READBACK_LINEAS2_MSSQL = """
SELECT ID, Fecha, Documento, NroFact, NroDoc, Deposito, CodArt, Descripcion,
       CantidadHaber, Precio, TotalLinea
FROM Lineas2 WHERE Documento = '30  ' AND NroFact = %s
"""

# ── Postgres: espejo legacy.* ────────────────────────────────────────────

# Dual-write al espejo para ver el pedido al instante (el mirror lo pisa con lo
# mismo en <=15s). Best-effort.
INSERT_LEGACY_CABEZAL2_SQL = """
INSERT INTO legacy.cabezal2
    (documento, nrofact, nrodoc, fecha, hora, nombre, codcliente, codvendedor,
     estado, observaciones, facturado, totalhaber, anulada, direccion,
     totaldebe, encuotas, consumofinal)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (documento, nrofact) DO NOTHING
"""
INSERT_LEGACY_LINEA2_SQL = """
INSERT INTO legacy.lineas2
    (id, fecha, documento, nrofact, nrodoc, deposito, codart, descripcion,
     cantidadhaber, precio, totallinea)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
ON CONFLICT (id) DO NOTHING
"""
ANULAR_LEGACY_CABEZAL2_SQL = """
UPDATE legacy.cabezal2 SET anulada = 1, facturado = 1
WHERE documento = '30  ' AND nrofact = %s
"""

# Datos del cliente que el pedido copia (contrato: NOMBRE=Nombre,
# DIRECCION=DireccionTrabajo, RUC=CioRuc, LISTADEPRECIO=TiposPrecios,
# MONEDA=Moneda). El espejo de clientes se refresca cada 2 min.
GET_CLIENTE_SQL = """
SELECT codcliente,
       BTRIM(COALESCE(nombre, '')) AS nombre,
       BTRIM(COALESCE(direcciontrabajo, '')) AS direccion,
       BTRIM(COALESCE(cioruc, '')) AS ruc,
       COALESCE(tiposprecios, 2) AS lista_precio,
       COALESCE(moneda, 1) AS moneda
FROM legacy.clientes
WHERE codcliente = %s
"""

SEARCH_CLIENTES_SQL = """
SELECT c.codcliente,
       BTRIM(c.nombre) AS nombre,
       BTRIM(COALESCE(c.cioruc, '')) AS ruc,
       BTRIM(COALESCE(c.direcciontrabajo, '')) AS direccion,
       COALESCE(c.moneda, 1) AS moneda,
       BTRIM(COALESCE(c.localidad, '')) AS estado_cliente,
       COALESCE(act.n, 0) AS pedidos_recientes
FROM legacy.clientes c
LEFT JOIN LATERAL (
    SELECT COUNT(*) AS n FROM legacy.cabezal2 c2
    WHERE c2.codcliente = c.codcliente AND c2.fecha >= now() - interval '90 days'
) act ON true
WHERE (translate(lower(c.nombre), 'áéíóúü', 'aeiouu') LIKE
           '%%' || translate(lower(%s), 'áéíóúü', 'aeiouu') || '%%'
       OR BTRIM(c.cioruc) LIKE %s || '%%'
       OR CAST(c.codcliente AS TEXT) LIKE %s || '%%')
ORDER BY act.n DESC, BTRIM(c.nombre)
LIMIT %s
"""

# Artículo para armar la línea: descripción + tasa de IVA real (Articulos.Iva es
# un CÓDIGO → join al catálogo Ivas del espejo; sin match cae a 0.22 tasa básica).
GET_ARTICULO_SQL = """
SELECT BTRIM(a.codarticulo) AS cod,
       BTRIM(a.descripcion) AS descripcion,
       COALESCE(CAST(iv.porcentaje AS FLOAT), 0.22) AS iva_tasa
FROM legacy.articulos a
LEFT JOIN legacy.ivas iv ON iv.iva = a.iva
WHERE BTRIM(a.codarticulo) = %s
"""

# Último precio vendido de cada artículo (batch). Semántica POR CLIENTE (el mismo
# día un artículo se vende a precios distintos según el cliente — verificado) +
# fallback global como referencia. Solo pedidos no anulados.
ULTIMOS_PRECIOS_CLIENTE_SQL = """
SELECT DISTINCT ON (BTRIM(l.codart))
       BTRIM(l.codart) AS cod, l.precio, l.fecha
FROM legacy.lineas2 l
JOIN legacy.cabezal2 c ON c.documento = l.documento AND c.nrofact = l.nrofact
WHERE l.documento = '30  ' AND c.codcliente = %s
  AND BTRIM(l.codart) = ANY(%s) AND COALESCE(c.anulada, 0) = 0
ORDER BY BTRIM(l.codart), l.fecha DESC, l.id DESC
"""
# El "global" solo mira clientes en PESOS (moneda 1): pre-llenar un precio en
# pesos dentro de un pedido USD/R$/EUR sería un desastre silencioso.
ULTIMOS_PRECIOS_GLOBAL_SQL = """
SELECT DISTINCT ON (BTRIM(l.codart))
       BTRIM(l.codart) AS cod, l.precio, l.fecha
FROM legacy.lineas2 l
JOIN legacy.cabezal2 c ON c.documento = l.documento AND c.nrofact = l.nrofact
JOIN legacy.clientes cl ON cl.codcliente = c.codcliente
WHERE l.documento = '30  '
  AND BTRIM(l.codart) = ANY(%s) AND COALESCE(c.anulada, 0) = 0
  AND COALESCE(cl.moneda, 1) = 1
ORDER BY BTRIM(l.codart), l.fecha DESC, l.id DESC
"""

# Precio de LISTA (el que fija Valeria en Macrosoft) por artículo, para la
# lista de precios del CLIENTE (Clientes.TiposPrecios). El último
# CambiosDePrecios (fecha <= hoy, por artículo+lista, empate por id) manda; si
# nunca hubo cambios, el precio base de la tabla Precios (moneda pesos).
#
# ESTO NO ES DOYPRECIOAFECHASI, aunque el comentario lo dijo hasta el 2/09.
# Leído el fuente de las dos funciones de Macrosoft, con precio guardado P y
# tasa i:
#
#            lista INCLUYE IVA (2,3,5,10)   lista SIN IVA (1,4)
#   DOYPRECIOAFECHA          P                      P
#   DOYPRECIOAFECHASI     P / (1+i)                 P        ← SI = Sin Impuestos
#   esta query               P                   P * (1+i)
#
# O sea: el tomador devuelve SIEMPRE con IVA y DOYPRECIOAFECHASI SIEMPRE sin.
# Son convenciones opuestas. "Siempre con IVA" es lo que el tomador necesita
# —Macrosoft factura IVA incluido— pero no es la función de Macrosoft, y
# tomarla como especificación lleva a la conclusión equivocada.
#
# Segunda diferencia: las dos funciones de Macrosoft hacen INNER JOIN contra
# Precios, así que un artículo con cambios pero SIN fila base devuelve 0 allá y
# el precio del cambio acá (121 casos de la lista 4, 117 de la 5, medido el
# 2/09). El módulo Productos crea esa fila cuando falta.
# Tablas espejadas desde el 27/07 (pg_mirror_sync) — el router tolera que
# todavía no existan (ventana del deploy hasta que el mirror nuevo corra).
# Params: (lista, cods[], lista, lista)
PRECIOS_LISTA_SQL = """
WITH tp AS (
    SELECT COALESCE(noincluyeimpuestos, 0) AS sin_iva
    FROM legacy.tiposprecios WHERE tipo = %s
)
SELECT c.cod,
       CASE
         WHEN COALESCE(cp.precioactual, pr.precio) IS NULL THEN NULL
         WHEN COALESCE((SELECT sin_iva FROM tp), 0) <> 0
           -- Ivas.Porcentaje viene como FRACCIÓN (0.22) en el legacy; por las
           -- dudas se toleran ambas representaciones (0.22 o 22).
           THEN ROUND(COALESCE(cp.precioactual, pr.precio)
                      * (1 + CASE WHEN COALESCE(iv.porcentaje, 0) > 1
                                  THEN iv.porcentaje / 100.0
                                  ELSE COALESCE(iv.porcentaje, 0) END))
         ELSE COALESCE(cp.precioactual, pr.precio)
       END AS precio
FROM (SELECT UNNEST(%s::text[]) AS cod) c
LEFT JOIN LATERAL (
    SELECT cd.precioactual
    FROM legacy.cambiosdeprecios cd
    WHERE BTRIM(cd.codarticulo) = c.cod AND cd.tiposprecios = %s
      AND cd.fecha <= CURRENT_DATE
    ORDER BY cd.fecha DESC, cd.id DESC
    LIMIT 1
) cp ON true
LEFT JOIN LATERAL (
    SELECT p.precio
    FROM legacy.precios p
    WHERE BTRIM(p.codarticulo) = c.cod AND p.tiposprecios = %s
      AND COALESCE(p.moneda, 1) = 1
    LIMIT 1
) pr ON true
LEFT JOIN legacy.articulos ar ON BTRIM(ar.codarticulo) = c.cod
LEFT JOIN legacy.ivas iv ON iv.iva = ar.iva
"""

# ── Postgres: listados de pedidos ────────────────────────────────────────

# Listado con estado derivado para el chip del front:
#   anulado > en_caja (FACTURADO=0) > estado operativo (ENTREGADO/…) > facturado.
# meta = pedidos creados desde Aloha (da "mío" + anulable + quién lo creó).
LIST_PEDIDOS_SQL_TPL = """
SELECT c.nrofact, BTRIM(c.nrodoc) AS nrodoc, c.fecha, c.hora,
       BTRIM(c.nombre) AS cliente_nombre, c.codcliente,
       c.codvendedor, BTRIM(COALESCE(v.nombre, '')) AS vendedor_nombre,
       c.totaldebe AS total, COALESCE(c.encuotas, 0) AS encuotas,
       BTRIM(COALESCE(c.estado, '')) AS estado,
       COALESCE(c.facturado, 0) AS facturado, COALESCE(c.anulada, 0) AS anulada,
       BTRIM(COALESCE(c.observaciones, '')) AS observaciones,
       m.usuario_id AS creado_por_usuario_id,
       u.nombre AS creado_por_nombre, u.username AS creado_por_username,
       (pri.nro_fact IS NOT NULL) AS prioritario
FROM legacy.cabezal2 c
LEFT JOIN legacy.vendedores v ON v.vendedor = c.codvendedor
LEFT JOIN ext.venta_pedido_meta m ON m.nro_fact = c.nrofact
LEFT JOIN ext.usuarios u ON u.id = m.usuario_id
LEFT JOIN ext.pedido_prioridad pri
    ON pri.documento = c.documento AND pri.nro_fact = c.nrofact AND pri.activo
WHERE c.documento = '30  ' {extra_where}
ORDER BY c.fecha DESC, c.nrofact DESC
LIMIT %(limit)s
"""

GET_PEDIDO_LINEAS_SQL = """
SELECT l.id, BTRIM(l.codart) AS cod_art, BTRIM(l.descripcion) AS descripcion,
       BTRIM(COALESCE(l.deposito, '')) AS deposito,
       l.cantidadhaber AS cantidad, l.precio, l.totallinea
FROM legacy.lineas2 l
WHERE l.documento = '30  ' AND l.nrofact = %s
ORDER BY l.id
"""

# Resumen de líneas de VARIOS pedidos a la vez (para íconos + bultos del listado).
LIST_LINEAS_RESUMEN_SQL = """
SELECT l.nrofact, BTRIM(l.codart) AS cod_art,
       BTRIM(l.descripcion) AS descripcion, l.cantidadhaber AS cantidad
FROM legacy.lineas2 l
WHERE l.documento = '30  ' AND l.nrofact = ANY(%s)
"""

# Historial del cliente: sus últimos N pedidos '30' (no anulados) con las líneas
# (producto + precio que le hicimos + bultos = CantidadHaber). Fuente = espejo
# (ventana de 30 días → cubre a los clientes que compran seguido, que es la norma).
HISTORIAL_PEDIDOS_SQL = """
SELECT c.nrofact, BTRIM(c.nrodoc) AS nrodoc, c.fecha,
       BTRIM(COALESCE(v.nombre, '')) AS vendedor_nombre
FROM legacy.cabezal2 c
LEFT JOIN legacy.vendedores v ON v.vendedor = c.codvendedor
WHERE c.documento = '30  ' AND c.codcliente = %s AND COALESCE(c.anulada, 0) = 0
ORDER BY c.fecha DESC, c.nrofact DESC
LIMIT %s
"""
HISTORIAL_LINEAS_SQL = """
SELECT l.nrofact, BTRIM(l.codart) AS cod_art, BTRIM(l.descripcion) AS descripcion,
       l.cantidadhaber AS cantidad, l.precio, l.totallinea
FROM legacy.lineas2 l
WHERE l.documento = '30  ' AND l.nrofact = ANY(%s)
ORDER BY l.id
"""

# ── Postgres: metadata ext.* ─────────────────────────────────────────────

INSERT_PEDIDO_META_SQL = """
INSERT INTO ext.venta_pedido_meta (nro_fact, nro_doc, usuario_id, vendedor, cliente_cod, total)
VALUES (%s, %s, %s, %s, %s, %s)
ON CONFLICT (nro_fact) DO NOTHING
"""
GET_PEDIDO_META_SQL = "SELECT * FROM ext.venta_pedido_meta WHERE nro_fact = %s"
ANULAR_PEDIDO_META_SQL = """
UPDATE ext.venta_pedido_meta SET anulado_en = now(), anulado_por_usuario_id = %s
WHERE nro_fact = %s
"""

# ── Idempotencia del envío (ext.venta_envio) ─────────────────────────────
# Reserva ANTES de escribir en Macrosoft; rowcount=0 → el ref ya existe
# (reintento tras timeout) → mirar si tiene nro_fact (pedido ya creado).
RESERVAR_ENVIO_SQL = """
INSERT INTO ext.venta_envio (ref, usuario_id) VALUES (%s, %s)
ON CONFLICT (ref) DO NOTHING
"""
GET_ENVIO_SQL = "SELECT ref, usuario_id, nro_fact, nro_doc, total FROM ext.venta_envio WHERE ref = %s"
COMPLETAR_ENVIO_SQL = """
UPDATE ext.venta_envio SET nro_fact = %s, nro_doc = %s, total = %s WHERE ref = %s
"""
LIBERAR_ENVIO_SQL = "DELETE FROM ext.venta_envio WHERE ref = %s AND nro_fact IS NULL"

# ── Agregados (feature 28/07: "el cliente agrega productos") ─────────────

# Pedidos '30' de HOY (día UY) del cliente, con su situación operativa — para
# que el tomador ofrezca "agregar al pedido de hoy" al elegir el cliente.
# total = SUM(TotalLinea) y NO Cabezal2.TOTALDEBE: al agregar líneas en caja el
# cabezal NO se actualiza (contrato nativo) → el total real vive en las líneas.
PEDIDOS_HOY_CLIENTE_SQL = """
SELECT c.nrofact, BTRIM(c.nrodoc) AS nro_doc,
       to_char(c.hora, 'HH24:MI') AS hora,
       (COALESCE(c.encuotas, 0) <> 0) AS credito,
       (COALESCE(c.facturado, 0) = 0) AS en_caja,
       CASE WHEN BTRIM(COALESCE(c.estado, '')) = '' AND COALESCE(c.facturado, 0) <> 0
            THEN 'PENDIENTE' ELSE BTRIM(COALESCE(c.estado, '')) END AS estado,
       lin.deposito,
       CAST(COALESCE(lin.total_lineas, 0) AS FLOAT) AS total,
       COALESCE(lin.items_count, 0) AS items_count,
       COALESCE(lin.solo_dto, false) AS solo_descuentos,
       BTRIM(COALESCE(u.nombre, '')) AS armador_nombre,
       (pa.armado_en IS NOT NULL) AS armado,
       COALESCE(seg.entregado_fiable, false) AS entregado_registrado,
       ag.nro_fact_original AS agregado_de
FROM legacy.cabezal2 c
LEFT JOIN LATERAL (
    SELECT CASE WHEN COUNT(DISTINCT BTRIM(Deposito)) > 1 THEN NULL
                ELSE MAX(BTRIM(Deposito)) END AS deposito,
           SUM(TotalLinea) AS total_lineas,
           COUNT(*) AS items_count,
           (SUM(CASE WHEN UPPER(BTRIM(CodArt)) LIKE 'D%%' THEN 1 ELSE 0 END) = COUNT(*)) AS solo_dto
    FROM legacy.lineas2 WHERE Documento = c.documento AND NroFact = c.nrofact
) lin ON true
LEFT JOIN ext.pedido_asignacion pa
    ON pa.documento = c.documento AND pa.nro_fact = c.nrofact
LEFT JOIN ext.usuarios u ON u.id = pa.usuario_id
LEFT JOIN ext.pedido_seguimiento seg
    ON seg.documento = c.documento AND seg.nro_fact = c.nrofact
LEFT JOIN ext.pedido_agregado ag
    ON ag.documento = c.documento AND ag.nro_fact = c.nrofact
WHERE c.documento = '30  ' AND c.codcliente = %s
  AND COALESCE(c.anulada, 0) = 0
  AND c.fecha >= (now() AT TIME ZONE 'America/Montevideo')::date
ORDER BY c.nrofact
"""

# ── Caso A: agregar líneas a un pedido que SIGUE en la cola de caja ──────
# El SELECT con UPDLOCK+HOLDLOCK y el filtro FACTURADO=0 AND ANULADA=0 es el
# corazón anti-carrera: bloquea la fila del cabezal hasta el commit → si caja
# está facturando el pedido EN ESTE INSTANTE, su UPDATE espera; y si YA lo
# facturó, no devuelve fila → 409 y el front ofrece el camino B (encadenar).
LOCK_PEDIDO_EN_CAJA_MSSQL = """
SELECT NROFACT, NRODOC, FECHA, MONEDA, CODCLIENTE, RTRIM(NOMBRE) AS NOMBRE
FROM Cabezal2 WITH (UPDLOCK, HOLDLOCK)
WHERE DOCUMENTO = '30  ' AND NROFACT = %s AND FACTURADO = 0 AND ANULADA = 0
"""

# Si caja tiene el cabezal lockeado (está facturando ESE pedido), no colgarse
# indefinido: 5s y error legible. 1222 = lock request time out.
SET_LOCK_TIMEOUT_MSSQL = "SET LOCK_TIMEOUT 5000"

# Depósito y mezcla D% de las líneas existentes (para copiar el depósito como
# hace el tomador nativo, y para mantener la regla "descuentos van aparte").
LINEAS_INFO_MSSQL = """
SELECT COUNT(*) AS n,
       SUM(CASE WHEN UPPER(LTRIM(RTRIM(CodArt))) LIKE 'D%%' THEN 1 ELSE 0 END) AS n_dto,
       MAX(ID) AS max_id
FROM Lineas2 WHERE Documento = '30  ' AND NroFact = %s
"""
ULTIMO_DEPOSITO_LINEA_MSSQL = """
SELECT TOP 1 RTRIM(Deposito) AS deposito FROM Lineas2
WHERE Documento = '30  ' AND NroFact = %s ORDER BY ID DESC
"""

# Readback de SOLO las líneas nuevas (ID > max previo) para el dual-write.
READBACK_LINEAS_DESDE_MSSQL = """
SELECT ID, Fecha, Documento, NroFact, NroDoc, Deposito, CodArt, Descripcion,
       CantidadHaber, Precio, TotalLinea
FROM Lineas2 WHERE Documento = '30  ' AND NroFact = %s AND ID > %s
"""

# Re-sincroniza los totales del CABEZAL con las líneas.
#
# BUG DE PRODUCCIÓN (31/07): agregar-líneas insertaba en Lineas2 y NO tocaba el
# cabezal, porque el análisis original concluyó que "el tomador viejo tampoco lo
# toca y caja recalcula desde las líneas". Esa premisa era FALSA: se midieron 20
# pedidos reales seguidos y en los 20 el TOTALDEBE del cabezal coincide con la
# suma de las líneas. Caja factura por el TOTALDEBE, así que lo agregado por el
# vendedor NO se cobraba (pedido 93049: cabezal 750, líneas 3.250).
#
# Se RECALCULA desde las líneas en vez de sumar los deltas: es idempotente, y si
# algún pedido quedó desincronizado antes, el próximo agregado lo corrige.
# SALDO acompaña a TOTALDEBE (así está en todos los pedidos del tomador nativo).
SYNC_TOTALES_CABEZAL_MSSQL = """
UPDATE c
SET UNIDADES     = x.u,
    SUBTOTALDEBE = x.s,
    IVADEBE      = x.i,
    TOTALDEBE    = x.t,
    SALDO        = x.t
FROM Cabezal2 c
CROSS APPLY (
    SELECT COALESCE(SUM(l.CantidadHaber), 0) AS u,
           COALESCE(SUM(l.TotalSinIva), 0)   AS s,
           COALESCE(SUM(l.IvaLinea), 0)      AS i,
           COALESCE(SUM(l.TotalLinea), 0)    AS t
    FROM Lineas2 l
    WHERE l.Documento = c.DOCUMENTO AND l.NroFact = c.NROFACT
) x
WHERE c.DOCUMENTO = '30  ' AND c.NROFACT = %s AND c.FACTURADO = 0 AND c.ANULADA = 0
"""

# Auditoría PG del agregado en caja (Macrosoft no registra quién editó).
INSERT_LINEA_AGREGADA_SQL = """
INSERT INTO ext.venta_linea_agregada (documento, nro_fact, usuario_id, detalle, total)
VALUES ('30  ', %s, %s, %s, %s)
"""

# ── Caso B: pedido nuevo ENCADENADO al original (ya salió de caja) ───────

GET_CABEZAL_ESPEJO_SQL = """
SELECT c.codcliente, COALESCE(c.anulada, 0) AS anulada, COALESCE(c.facturado, 0) AS facturado,
       (c.fecha >= (now() AT TIME ZONE 'America/Montevideo')::date) AS es_de_hoy
FROM legacy.cabezal2 c WHERE c.documento = '30  ' AND c.nrofact = %s
"""

# Total real del pedido (suma de líneas) desde el espejo — para el replay
# idempotente de agregar-líneas (no volvemos a tocar Macrosoft para responder).
TOTAL_LINEAS_ESPEJO_SQL = """
SELECT CAST(COALESCE(SUM(l.totallinea), 0) AS FLOAT) AS total
FROM legacy.lineas2 l WHERE l.documento = '30  ' AND l.nrofact = %s
"""

# Si el "original" elegido ya es un agregado, encadenar a SU raíz (grupo único).
GET_RAIZ_AGREGADO_SQL = """
SELECT nro_fact_original FROM ext.pedido_agregado
WHERE documento = '30  ' AND nro_fact = %s
"""

INSERT_PEDIDO_AGREGADO_SQL = """
INSERT INTO ext.pedido_agregado (documento, nro_fact, nro_fact_original, creado_por)
VALUES ('30  ', %s, %s, %s)
ON CONFLICT (documento, nro_fact) DO NOTHING
"""

GET_VENDEDOR_DE_USUARIO_SQL = "SELECT vendedor FROM ext.venta_vendedor WHERE usuario_id = %s"
LIST_VENTA_VENDEDORES_SQL = """
SELECT vv.usuario_id, vv.vendedor, vv.actualizado_en
FROM ext.venta_vendedor vv
"""
UPSERT_VENTA_VENDEDOR_SQL = """
INSERT INTO ext.venta_vendedor (usuario_id, vendedor, actualizado_por_usuario_id, actualizado_en)
VALUES (%s, %s, %s, now())
ON CONFLICT (usuario_id) DO UPDATE
SET vendedor = EXCLUDED.vendedor,
    actualizado_por_usuario_id = EXCLUDED.actualizado_por_usuario_id,
    actualizado_en = now()
"""
DELETE_VENTA_VENDEDOR_SQL = "DELETE FROM ext.venta_vendedor WHERE usuario_id = %s"

# Existencia (y estado de anulación) de un pedido '30' — para marcar prioridad.
# ¿Todas las líneas del pedido son descuentos (artículos D*)? Un pedido así no
# se arma ni se entrega: no se puede marcar prioritario (dueño 31/08).
# OJO psycopg2: el LIKE lleva % doble o se lo come como placeholder.
ES_SOLO_DESCUENTOS_SQL = """
SELECT SUM(CASE WHEN UPPER(BTRIM(l.codart)) LIKE 'D%%' THEN 1 ELSE 0 END) AS dtos,
       COUNT(*) AS lineas
FROM legacy.lineas2 l
WHERE l.documento = '30  ' AND l.nrofact = %s
"""

GET_PEDIDO_30_SQL = """
SELECT c.nrofact, COALESCE(c.anulada, 0) AS anulada
FROM legacy.cabezal2 c
WHERE c.documento = '30  ' AND c.nrofact = %s
"""


# ── Crear cliente (26/08): el mínimo REAL de Macrosoft ───────────────────────
#
# De 40 columnas solo CodCliente es NOT NULL; el resto es convención medida en
# las 3.834 altas reales: CodCliente = referencia*100+1 (el 95% termina en 01,
# mismo truco que los artículos color), referencia = MAX+2 (cadencia observada
# de las últimas altas). Tipo C / FliaCli 1 / TiposPrecios 2 = cliente común
# con lista de venta; Moneda 1 (UYU); AoB 'A'; y el QUIRK heredado: el ESTADO
# del cliente vive en el campo Localidad ('Activo' / 'De Baja').
CLIENTE_MAX_SQL = """
SELECT MAX(CodCliente) AS max_cod FROM Clientes WITH (UPDLOCK, HOLDLOCK)
"""

CLIENTE_EXISTS_SQL = "SELECT 1 AS x FROM Clientes WHERE CodCliente = %s"

CLIENTE_INSERT_SQL = """
INSERT INTO Clientes (
    CodCliente, CodReferencia, Nombre, NombreFantasia, CioRuc,
    DireccionTrabajo, TelefonoTrabajo, Localidad,
    Moneda, Tipo, FliaCli, TiposPrecios, AoB
) VALUES (%s, %s, %s, %s, %s, %s, %s, 'Activo', 1, 'C', 1, 2, 'A')
"""

# Dual-write al espejo: el picker lo ve al instante (el sync FULL de 120s lo
# pisa después con la verdad de Macrosoft — mismas columnas, inocuo).
CLIENTE_ESPEJO_SQL = """
INSERT INTO legacy.clientes
    (codcliente, codreferencia, nombre, nombrefantasia, cioruc,
     direcciontrabajo, telefonotrabajo, localidad, moneda, tipo,
     fliacli, tiposprecios, aob)
VALUES (%s, %s, %s, %s, %s, %s, %s, 'Activo', 1, 'C', 1, 2, 'A')
ON CONFLICT (codcliente) DO NOTHING
"""
