================================================================
  poronga/  —  Sistema operación banana Almar S.R.L.
  Última ordenada: 10/09/2026 (lo sacado esta en Desktop\poronga_papelera_2026-09-10, borrar despues de una semana)
================================================================

ARCHIVOS DEL PIPELINE (NO MOVER, los usa el script):
  actualizar_precios.ps1            script principal (cron viernes 19h)
  index.html                        redireccion a index_brasil.html (la "vista rapida" se unifico con Brasil el 18/09/2026)
  index_brasil.html                 dashboard Brasil
  index_paraguay_bolivia.html       dashboard Paraguay/Bolivia
  index_ecuador.html                dashboard Ecuador FOB (Tridge spot)
  alertas.log                       histórico de alertas disparadas

ARCHIVOS DE TRABAJO:
  plantilla_descarga.txt            plantilla para descargas → WhatsApp (queda en la raíz: se usa en cada descarga)
  documentos/                       documentos manuales, agrupados el 10/09/2026 (antes sueltos en la raíz):
    plantilla_envalado_bananal.html       checklist de envalado en bananal (A4, PT-BR) + _ES.html / _ES.pdf
    planilla_almar_v2.xlsx                planilla planificación semanal
    Plan Almar Brasil 2026.xlsx           planning anual
    Planilha de Inspeção de Bananal.pdf
    planilha_bananal_PT.(html|xlsx)       formulario inspección PT
    planilla_bananal.xlsx / _ES.html / _PY.(html|pdf)
    API_ERP_lo_que_necesito.md            pedido de integración al ERP (Aloha)
CARPETAS:
  config/      whatsapp.json (Whapi token + números)
               cepea_regiones.json (regiones Cepea a comparar + fletes por camión a MVD; los fletes los cargás vos)
               aloha.json (usuario/clave de Aloha para leer el Plan de Cargas;
               plantilla en aloha.example.json)
  penta/       extractos de aduana Penta (detalle_UYimport_*.xlsx, todos los origenes juntos) → tirar el nuevo aca y correr el script
  fuentes/     datos VIVOS del pipeline
               - cargas 2026.xlsx (operaciones del año, vos editás)
               - plan_cargas_aloha.json (cache del Plan de Cargas leído de Aloha)
               - precios_banana_SC_2023-2026.xlsx (cache Cepea Norte SC)
               - precios_banana_VRibeira/NMinas/BJLapa.xlsx (cache Cepea otras regiones, paso 2b)
               - precios_cepea.json (sidecar inyectado en HTMLs)
               - precios_py_cache.json (Carape PY)
               - precios_ecuador.json (sidecar Ecuador FOB, scraping Tridge)
               - state_whatsapp.json / state_alertas.json
               - clima_archive_cache/ (NASA POWER por región)
               - mercado_uy.json / mercado_br.json / mercado_pybo.json (sidecars aduana Penta: index_mercado, index_brasil, index_paraguay_bolivia)
               - plan_cargas/ (planilla maestra bajada a mano) + plan_cargas.json
               - stock/ (stock_diario.xlsx: Stock kg del ERP por origen y día + capturas) — NO lo usa el pipeline
               - plan_semanal/ (plan_semanal.xlsx: hojas parametros, camaras [foto diaria del plan de maduración, una fila por cubículo], en_camino [llegados sin gas, en ruta, pedidos] y notas; fotos WhatsApp fechadas) + plan_semanal.json → lo lee el paso 5i y arma index_cargas.html (saldo por día de venta, camiones a cargar y fecha de carga). OJO: no meter planillas propias en plan_cargas/, el paso 5h toma el xlsx más nuevo de ahí como master
               - productores.xlsx (fichas de productores; se edita en Excel O desde el botón "Editar datos de la ficha" del panel)
               - productores_ediciones.json (lo escribe el panel al guardar una ficha; el script lo vuelca a productores.xlsx y lo archiva) + state_ediciones.json
  archivo/     histórico. OJO: archivo/importaciones_uy/ SÍ lo usa el paso 5c (extractos Penta 2024-2025);
               los backups quedan acá (primero y último de cada familia; los intermedios van a la papelera)
               ├── cargas_historicas/      cargas viejas (2024/25, brasil, etc.)
               ├── fotos/                  WhatsApp y ventas jpegs de referencia
               ├── importaciones_uy/       PDFs/xlsx UYimport (2026-04)
               ├── Cargas_tidy.csv/xlsx    versiones tidy históricas
               └── precios_banana_SC_2026.xlsx   cache viejo single-year
  guia_corte/  control de calidad del DEDO (corte transversal) — NO lo usa el pipeline
               - guia_corte_transversal_banana.html  guía 5 hojas A4 (v2 set 2026: muestreo, mediciones, enfermedades,
                                                     desórdenes y decisión, casos Almar con fotos propias en fotos/almar/)
               - calculadora_punto_optimo.html       veredicto por lote (verde-duro / lleno / poca azúcar)
               - atlas_cortes.html                   galería propia: foto del corte + 6 mediciones + veredicto (localStorage)
               - fuentes_y_notas.txt                 trazabilidad: confirmado / orientativo / pendiente MGAP
               - fotos/                              imágenes de referencia (Wikimedia CC) + fotos/almar/ (propias, set 2026)

EJECUCIÓN DEL CRON:
  Tarea Windows: "Cepea_ActualizarPrecios_Almar"
    - viernes 19:00 (Cepea publica viernes tarde)
    - miércoles 12:00 (control mid-week)
  Settings activos: WakeToRun + StartWhenAvailable + no detener con
  batería, timeout 1h, requiere internet.

FUENTES DE PRECIO (resumen):
  🇧🇷 Brasil   → Cepea Norte SC (Nanica primeira, productor) — SEMANAL,
                 xlsx exporter público (hfbrasil.org.br). Fresh viernes.
  🇵🇾 Paraguay → Mercado Carape Asunción — SEMANAL, scraping HTML.
  🇪🇨 Ecuador  → Tridge FOB (publico, sin login) — sampled export
                 transactions, USD/kg → USD/caja 43 lb (19,5 kg).
                 PMS oficial MAG 2026 hardcoded: USD 7,50/caja.
                 Rezago real: ~2 semanas. SIPA descartado por 6m de lag.

LOG DE CAMBIOS:
  17/09/2026 -> WhatsApp: un solo mensaje por corrida. El 16/09 llegaron 4 (Forecast,
               Clima severo, Ecuador y Resumen) y los 3 primeros ya estaban dentro del
               Resumen, que sale siempre (miercoles y viernes). Ahora $sendResumen se
               decide ANTES de las alertas de evento: si sale el resumen, forecast y
               clima no se mandan aparte, y Cepea +-15%, PY +-10% y punto nuevo de
               Ecuador van en una linea "Novedades" arriba del resumen. Sin resumen
               (corrida extra fuera de dia) todo sigue igual que antes. Criticas de
               compra y fallas del pipeline no cambian. Fechas ISO de los mensajes
               sueltos pasadas a dd/MM. Probado en seco en PS 5.1, los dos caminos.
  17/09/2026 -> Plan de Cargas desde Aloha (paso [3b] del script). Gonzalo pidio
               anexar el plan de cargas al resumen semanal: la planilla cargas
               2026.xlsx quedo vieja ("hace 6 sem sin cargas nuevas"). Ahora el
               script entra a la API del ERP (aloha.somospepe.com) con un usuario
               de solo lectura (configloha.json) y lee GET /plan-cargas: camiones
               por semana, en camino (frontera/liberado), por venir, arribados y
               ultima descarga. Bloque nuevo "Plan de Cargas" en el WhatsApp
               semanal y $data.plan_cargas en el JSON. Aloha NO se toca. Cache en
               fuentes\plan_cargas_aloha.json (si la API falla, se usa y se avisa).
               El bloque Almar (precio R$/caja) sigue saliendo de la planilla: el
               plan de Aloha no tiene precio.
  17/09/2026 -> sync laptop -> GitHub -> servidor (merge con el paso [3b] de
               Aloha). Entraron los cambios hechos en la laptop del 05/09 al
               16/09: Cepea por region (2b), fichas editables (3a), Plan de
               Cargas desde xlsx (5h) e index_cargas / index_recepcion, guia de
               corte v3.4, documentos/, pie-de-camion-importaciones/.
               La copia de la laptop venia SIN BOM, SIN la reescritura del
               resumen del 04/09 y con los lectores de xlsx otra vez en Excel
               COM. Se restauro todo antes del merge; los lectores de Cepea,
               cargas 2026 y fichas (lectura y volcado de ediciones) pasaron a
               ImportExcel/EPPlus y se verificaron contra la salida COM del
               16/09 (192 semanas Cepea, 451 operaciones, 25 fichas, mismos
               agregados por productor/transportista). Tambien: -UseBasicParsing
               en la descarga Cepea, fix del '"..." + (if' en la alerta
               Oportunidad y "desde noviembre" -> mes real.
  17/09/2026 -> Barra de navegacion comun (NAV_PANELES) arriba de inicio.html y
               de los 10 index_*.html: botones con el nombre de cada panel, el
               actual resaltado. Es el mismo bloque en todas las paginas: si se
               cambia, cambiarlo en todas (index_cargas tenia una nav.top propia,
               reemplazada). Y tabla "Plan de Cargas - camion por camion" en el
               Resumen ejecutivo de index_brasil.html (status, productor,
               carpeta, factura, carga, frontera, descarga, cajas, transportista,
               placa): sale de Aloha si el paso [3b] esta configurado
               (CEPEA_DATA.plan_cargas.cargas: pendientes + ultimos 60 dias) y,
               si no, de la planilla del paso 5h (CARGAS_DATA.porOrigen.BR.lista,
               que ahora tambien lee las columnas Factura y Placa).
  17/09/2026 -> Cabezal compacto en las 11 paginas (pedido: se repetia lo mismo al
               entrar a cada panel). La barra NAV_PANELES deja de ser fija y
               pierde el rotulo "Almar"; el <header> de cada pagina pasa a una
               sola linea (titulo + subtitulo) por CSS del mismo bloque;
               index.html pierde el segmento "OTRAS PAGINAS" de su nav de anclas
               (duplicaba la barra); index_brasil.html pierde el banner fijo
               "HOY estas en FASE 1 ... cierra 11/07/2026" (texto estatico
               vencido, ningun JS lo actualizaba).
  18/09/2026 -> Limpieza de paneles (pedido: informacion vieja y duplicada al entrar a cada
               uno). 1) index.html (Plan de compras) era un subconjunto de index_brasil:
               ahora redirige a Brasil y salio de la barra, de $htmlTargets y de la
               portada. 2) index_brasil: el Calendario de fases (foto 12/06) y el HHI 2025
               (foto mayo) pasaron a archivo/index_brasil_bloques_fijos_2026-06.html; el
               bloque de aduana quedo en sus 4 KPI + link a Mercado UY (fuera tabla por
               ano, posicion en el mercado e inteligencia competitiva) y el titulo dice el
               corte; un solo ranking de productores (el del Plan de cargas, que ya traia
               precio y vs Cepea) con la ficha abierta desde el nombre; fuera el ranking de
               cargas 2026. 3) Clima: ya filtraba por pais; en Paraguay-Bolivia se saco la
               linea Cepea del grafico. 4) Aduana por origen solo en Mercado UY:
               Paraguay-Bolivia perdio Indicadores y los bloques PY/BO en aduana (queda el
               resumen + link); Ecuador oculta volumen y comparativa (queda KPI + link).
               5) Comparativo anual: salto y semana a semana siguen el mes de la ultima
               semana Cepea (JSON: mes_actual, mes_prev, mesSem, eneHasta; antes fijo
               julio-agosto), ciudad del clima con fallback y la etiqueta "$1" arreglada.
               6) Ecuador: Referencia mundial marcada con los meses de atraso (IndexMundi).
               7) Cargas y saldo: la cola "en camino / programado" sale del Plan de Cargas
               (el paso 5i toma $ops del 5h); la hoja en_camino solo aporta lo llegado sin
               gas; plan_semanal.json trae colaFuente. 8) Recepcion: lista de productores
               inyectada desde productores.xlsx (marcadores __PRODUCTORES_JSON__, paso 5e).
               9) Portada: Calidad sale como "sin datos todavia (n de 15 lotes)" hasta
               juntar los lotes del modelo.
  18/09/2026 -> La tabla "camion por camion" del Plan de Cargas se movio del Resumen
               ejecutivo de index_brasil al final de la seccion "Plan de cargas Brasil"
               (misma fuente que los KPI y las tablas de ahi). En el Resumen queda una
               linea con los totales (en camino / en deposito / por venir) y un link.
  18/09/2026 -> Segunda pasada de duplicados DENTRO de cada pagina (la primera solo
               cruzo entre paginas). index_brasil: fuera "Cargas YTD" de Almar vs Cepea
               y "Camiones BR" + "Ritmo anualizado" de Real BR (los tres repetian el
               Resumen ejecutivo, mismo numero y misma cuenta); fuera "Top
               transportistas" de Real BR (ya esta en Plan de cargas), queda
               Despachantes solo; arreglado el link "el ranking esta mas arriba" que
               apuntaba al ranking borrado el 18/09. index_paraguay_bolivia: las dos
               tablas de productores salian de la misma lista (porOrigen.PY.productores):
               queda el ranking (ficha, estado, % del ano) con la columna Faltantes de la
               tabla que se saco.
  18/09/2026 -> Vuelve el ranking de productores de index_brasil (el de cargas 2026.xlsx,
               sacado ese mismo dia por "duplicado"). Error: era el que abria las fichas
               de los 18 productores de Brasil; la tabla del Plan de cargas solo encuentra
               4 (Valdemar, Gilson, Sergio, Furlani) porque los nombres del Plan ("Cassio
               Hauck", "Fischer", "Ivo Zimerman") no coinciden con los de las fichas.
               Quedan las dos tablas: son fuentes distintas (planilla de cargas con precio
               y ficha; Plan de Cargas con transito y faltantes). Para que la del Plan
               tambien abra fichas hay que cargar esos nombres en la columna Alias de
               productores.xlsx.
  18/09/2026 -> Alias del Plan de Cargas en productores.xlsx (columna Alias, hoja
               productores; respaldo en archivo/productores_backup_2026-09-18_alias.xlsx).
               El Plan escribe nombre y apellido y las fichas nombre corto, asi que la
               tabla del Plan solo encontraba 4 fichas de 18. Confirmado con Gonzalo:
               Fischer=Fisher, Jhony Viera=Jony, Cassio Hauck=Cassio, Jorge Marangoni,
               Osnildo Stein, Ivo Zimerman, Marconi Kons, Wagner Schveitzer, Josemar
               Provesi, Joao Claudio Winter=Joao vinter, Zapellini=Zapelini y
               Corupa=Agrocurupa. Valdemar Ita es OTRO productor (no es Valdemar).
               Ahora 16 de 33 productores del Plan BR abren ficha (todos los activos
               en 2026 con ficha). Sin ficha: Banana Combinada, Aldo Corupa y los de
               2024-2025 que ya no cargan.
  09/09/2026 → paso 2b: Cepea por región (Vale do Ribeira, Norte de Minas,
               Bom Jesus da Lapa) con config/cepea_regiones.json y sección
               'Cepea por región' en index_brasil. Filtro Cepea corregido
               (sólo 'Nanica primeira - produtor', antes duplicaba 2 semanas).
               Sacado el bloque 'Correlación clima-precio' entero (10/09).
  10/09/2026 → fichas editables desde el panel: botón "Editar datos de la ficha"
               (contacto, pies, ha, variedad, municipio, localidad, dirección,
               ubicación por Plus code o lat/lon, nota). Guarda en el navegador y en
               fuentes/productores_ediciones.json; el paso 3a del script lo pasa a
               productores.xlsx. Km por ruta a UAM y frigorífico CR en las fichas.
  04/09/2026 -> se integro el paquete poronga_2026-09-04.zip (paneles nuevos:
               inicio/mercado/proyeccion/comparativo/calidad, salud del pipeline,
               alerta WhatsApp de fallas, Get-AccionZona, penta/).
               El paquete venia armado en una PC CON Excel y SIN los fixes de
               servidor del 04/08, asi que hubo que re-aplicarlos uno por uno:
               * xlsx: volvia a Excel COM. Re-migrado a ImportExcel (EPPlus) en
                 los dos lectores (Cepea y cargas 2026). Esta PC no tiene Office.
               * $base: venia hardcodeado a C:\Users\Usuario\Desktop\poronga
                 (ruta inexistente aca). Vuelto a $PSScriptRoot.
               * BOM: el .ps1 venia UTF-8 SIN BOM -> PS 5.1 lo leia como ANSI y
                 daba 48 errores de sintaxis. Reguardado UTF-8 CON BOM.
               * -UseBasicParsing: se habia perdido en el scraping de Paraguay
                 (y faltaba en el de IndexMundi, que es codigo nuevo).
               * config\whatsapp.json: NO se piso, el zip lo trae sin token a
                 proposito. Solo se le agrego la clave alerts.fallas_pipeline.
               * Bug propio del paquete: "..." + (if ...) + "..." no es una
                 expresion valida en PowerShell (revienta en runtime, no al
                 parsear). Estaba en la alerta de Oportunidad. Pasado a variable.
               * Cosmetico: el resumen semanal decia "prom mayo" y las alertas de
                 extremo "desde noviembre", ambos fijos. Ahora salen del mes real.

  ATENCION PARA LA PROXIMA ACTUALIZACION: esta PC-servidor no tiene Excel, no
  tiene Internet Explorer y corre la tarea con powershell.exe (PS 5.1). Los
  cuatro fixes de arriba hay que conservarlos en cualquier paquete que llegue.
  14/06/2026 → nueva carpeta guia_corte/ : control de calidad por corte
               transversal del dedo en verde. Guía A4 (enfermedades + mediciones,
               con investigación deep-research verificada), calculadora del
               "punto óptimo" de recepción (verde-duro/lleno/poca azúcar, distingue
               INMADURA vs YA MADURANDO) y atlas de cortes (galería propia:
               foto + 6 mediciones + veredicto, con backup JSON).
  05/06/2026 → suma Ecuador al pipeline. Fetch Tridge FOB en el cron,
               sidecar precios_ecuador.json, dashboard index_ecuador.html
               nuevo (Chart.js, KPIs, spread vs PMS), alerta WA "movimiento
               Ecuador" cuando aparece punto nuevo. SIPA investigado y
               descartado por 6 meses de rezago (último disponible: dic/25).
               El index_ecuador viejo se archivó como
               archivo/index_ecuador_legacy.html.
  02/06/2026 → ordenada inicial de la carpeta. Plantilla de descarga
               creada. README escrito. Script con escudo "no dormir"
               (SetThreadExecutionState) tras el corte del cron del 29/05
               (la PC se suspendió a los 18 min y mató el script).
================================================================
