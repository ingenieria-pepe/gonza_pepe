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
  plan_compras/ plan de compras BR/PY/BO, POR FUERA del dashboard: simulador.html, plan_compras.xlsx,
               generar_datos.ps1 (ver plan_compras/LEEME.txt) [20/09/2026]
  penta/       extractos de aduana Penta (detalle_UYimport_*.xlsx, todos los origenes juntos) → tirar el nuevo aca y correr el script
  fuentes/     datos VIVOS del pipeline
               - cargas 2026.xlsx (operaciones del año, vos editás)
               - plan_cargas_aloha.json (cache del Plan de Cargas leído de Aloha)
               - plan_compras.xlsx (PLAN DE COMPRAS: cargas_programadas que dicta Gonzalo por semana
                 + ventas_plan por origen; ver hoja notas) [19/09/2026]
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
  19/09/2026 -> Arranca el PLAN DE COMPRAS (banana BR/PY/BO). Nueva planilla
               fuentes/plan_compras.xlsx: hoja cargas_programadas (una fila por camion,
               semana de carga domingo-sabado, como la dicta Gonzalo; esas semanas PISAN
               al Plan de Cargas) y hoja ventas_plan (cajas/semana por origen; hoy el
               promedio de los reportes del ERP: BR 7.200, PY 5.250, BO 1.230). Modelo:
               cada camion se vende desde carga + 12 dias (5 de ruta y aduana + 2 gas +
               5 camara, lags de plan_semanal). Cargadas las semanas 14-19/09 (real:
               BR 3, PY 8) y 21-26/09 (programada: BR 9, PY 4). Todavia se corre a mano
               (scratchpad); el paso del script y la seccion en index_cargas vienen despues.
  19/09/2026 -> index_compras.html: SIMULADOR del plan de compras. Grilla de camiones por
               semana de carga (dom-sab) y por origen, editable; venta semanal, lags,
               cajas/camion, colchon inicial y minimo editables; saldo por semana de
               venta con estado (ok / justo / FALTA), fecha limite de carga, sugerencia
               de camiones a agregar, grafico y resumen de texto. Lo editado se guarda
               en localStorage (boton 'Volver a lo cargado'). Datos entre los marcadores
               /*__COMPRAS_JSON__*/ ... /*__END_COMPRAS__*/ desde fuentes/plan_compras.json
               (por ahora generado a mano con el mismo criterio del futuro paso 5j:
               Plan de Cargas + plan_compras.xlsx, dictadas pisan al Plan). Barra de
               paneles v4 con el boton 'Plan de compras' en las 11 paginas.
  19/09/2026 -> El simulador arranca del CONTEO FISICO por camara, no de una
               reconstruccion. Error corregido: el conteo del 17/09 estaba en Descargas
               (conteo-todas-2026-09-18.xlsx) y se habia ignorado; el 'Stock' del reporte
               diario del ERP es solo lo listo para vender ese dia (< 1 dia), no la
               camara. Guardado en fuentes/stock/2026-09-17_conteo_camaras.xlsx y en la
               hoja 'conteo' de plan_compras.xlsx (BR 14.475, PY 12.345, BO 2.604 cajas;
               sin palta ni mandioca 'Brasil'). Regla: saldo = conteo + camiones que
               DESCARGAN despues de la fecha del conteo (descarga real o carga + ruta +
               aduana) - venta (la semana del conteo prorrateada por los dias que
               quedan). Resultado con lo dictado: BR justo hasta la sem. del 05/10 y
               FALTA desde el 12/10 (5 camiones a cargar hasta el 30/09), PY cubierto
               hasta el 12/10, BO se termina la sem. del 28/09 y no hay nada en camino.
  19/09/2026 -> Simulador: stock FISICO semana a semana, como lo lleva Gonzalo. Regla:
               stock al sabado = stock anterior + camiones que DESCARGAN esa semana - venta.
               Descarga = carga + 3 dias (lun-mie entra en la semana, vie-sab entra lun-mar;
               Bolivia 6). Ya no se corre el camion 7 dias hasta que madura: el conteo cuenta
               toda la fruta, madura o no. En cambio hay un MINIMO en camara = 7 dias de
               venta (lo que todavia no maduro); por debajo, 'bajo minimo'; negativo, FALTA.
               Horizonte 3 semanas (pedido). Con lo dictado: total BR+PY+BO 26.824 cajas al
               19/09, 21.960 al 26/09, 15.264 al 03/10 y 1.584 al 10/10: hay que cargar la
               semana del 28/09 (BR 7, PY 5) y Bolivia ya.
  20/09/2026 -> Plan de Cargas al dia con la exportacion completa de Aloha (boton exportar
               de la pantalla Plan de cargas, sin filtro): fuentes/plan_cargas/Plan - Cargas
               (export Aloha 2026-09-20).xlsx, 2.634 cargas ene/2024-19/09/2026 con estados
               reales. Formato distinto del master: hoja 'Plan de cargas', encabezado 'Fecha
               carga', sin columna Productos, rels con Target antes que Id. Read-XlsxHoja y
               el paso 5h aceptan los dos formatos; manda el .xlsx mas nuevo de la carpeta.
               Las exportaciones con filtro 'pendientes' (chicas) van aparte en
               fuentes/plan_cargas/exportaciones_aloha/ (no sirven para 5h). Simulador: las
               cargas dictadas en plan_compras.xlsx valen solo para fechas POSTERIORES a la
               ultima carga del Plan (antes 'pisaban' semanas enteras).
  20/09/2026 -> El plan de compras pasa POR FUERA del dashboard (pedido de Gonzalo: no
               enredar el index; se integra cuando este listo). Todo en plan_compras\:
               simulador.html (era index_compras.html, sin barra), plan_compras.xlsx,
               plan_compras.json y generar_datos.ps1, que regenera el JSON y lo inyecta
               (se corre a mano; actualizar_precios.ps1 no lo toca). Fuera el boton de la
               barra y la tarjeta de la portada. Bolivia entra por fin: exportacion de Aloha
               fuente OTROS en fuentes/plan_cargas/otros/ (Pais = BO, exportadores Befrut y
               Banexfrut, 1.050 cajas, carga a descarga ~6 dias); 5h no mira esa subcarpeta.
  20/09/2026 -> Venta POR SEMANA en el plan de compras. Gonzalo: "la semana que viene
               un estimado de 15 mil y la siguiente 17 mil". Hoja ventas_plan de
               plan_compras.xlsx reescrita: 21/09 = 15.000, 28/09 = 17.000, 05/10 en
               adelante = 17.000 marcadas SUPUESTO; el total se reparte por origen con
               el mix real de los reportes del ERP de la semana 38 (BR 52,6 % / PY
               38,4 % / BO 9,0 %). El simulador toma la venta de la fila de cada
               semana (si la semana no esta, usa la ultima anterior); el minimo en
               camara (7 dias) se calcula con la venta de esa semana. Las casillas
               "Venta semanal" quedan vacias = plan; un numero fijo pisa el plan en
               todas las semanas (para probar). Clave del navegador plan_compras_sim_v4.
               Resultado con lo dictado: al sabado 03/10 BR 7.100 (5 dias, minimo
               10.430), PY 7.100 (7 dias, minimo 7.620), BO 360; la semana del 05/10
               sin cargas nuevas queda en falta.
  20/09/2026 -> Tabla "invierno" del comparativo anual (paso 5c) calculada sobre el
               cache DIARIO (funcion Get-InviernoStats, fuentes\clima_archive_cache),
               sin redondear: dos semanas de 2025 de 11,99 y 11,96 grados quedaban en
               12,0 y no contaban como frias, y 2025 empataba con 2026. Dos zonas:
               Luiz Alves y Caaguazu (PY, se baja en 5c con el mismo cache), con
               minima absoluta con fecha y dias con menos de 5 grados. Nuevo
               $dailyPorRegion en el loop de 3.6 y clima_r2 en el JSON del
               comparativo. Lo hizo la sesion del Excel de Paraguay; parser PS 5.1
               sin errores, commit desde aca.
  24/09/2026 -> Score de compra: el resumen del 23/09 dio "-4 STOP COMPRA" con Cepea -2
               (subio 16% en la semana, de R$ 0,93 a 1,08) y calendario -2 (septiembre
               historico R$ 1,68) mientras el precio real estaba 36% POR DEBAJO de ese
               promedio, y abajo el mismo mensaje decia "ventana atipica, evaluar
               compra". Gonzalo: "no estoy de acuerdo". Dos reglas nuevas, con el
               umbral que ya usaba Get-AccionZona (12%): (1) si el precio real se
               aparta del historico del mes mas de 12%, la senal calendario no cuenta;
               (2) una suba del Cepea no penaliza si el precio sigue mas de 12% bajo el
               historico del mes (rebote desde el piso, no pico). Con eso el 23/09
               daba "0 NORMAL". Mismo cambio en el JS de index_brasil (bloque
               ALERTA DE OPORTUNIDAD); el renglon del score en WhatsApp dice cuando
               una senal se anulo. Clima en el resumen: se agrega la semana PASADA
               por zona (max/min de Open-Meteo, dias >=32 y <=14; pedido de Gonzalo:
               "hizo casi 35 grados toda la semana en Tembiapora y no figura") antes
               de los prox 7 dias; paso 3.5 guarda dias_max32 y dias_min14 en
               semana_pasada. Ojo: Open-Meteo es modelo, no estacion: para Tembiapora
               dio 33 el 20-21/09 y un frente frio el 22-23 (min 9), no 35.
  24/09/2026 -> Fichas: Gonzalo pidio sacar las "Notas" de procedencia de las fichas
               (columna Notas de productores.xlsx vaciada, salvo Curuca que sigue
               diciendo COMPRADOR). Fotos de packing: carpeta fuentes\fotos_packing\
               <productor>\ (hoy paraguay_hf, 9 fotos); el paso 3 las engancha a la
               ficha por slug/nombre/alias y abrirFicha las muestra como galeria en
               index_brasil e index_paraguay_bolivia. Lo hizo la sesion del Excel de
               Paraguay; commit desde aca.
  24/09/2026 -> "Todo a Uruguay" (pedido de Gonzalo). (1) El paso 3b, ademas de la
               lista JSON, baja los exportes .xlsx del Plan de Cargas desde la API de
               Aloha (GET /plan-cargas/export.xlsx?fuente=BR y =OTROS, el mismo boton
               exportar de la pantalla) a fuentes\plan_cargas\Plan - Cargas (Aloha
               API).xlsx y fuentes\plan_cargas\otros\Plan - Cargas OTROS (Aloha
               API).xlsx: nombre fijo, se pisan en cada corrida, en .gitignore y en
               $preservar de correr_servidor.ps1. Se valida que sea un xlsx con la
               hoja Plan de cargas; si falla queda el anterior y sale en las fallas.
               Con eso 5h y el plan de compras dejan de depender de que Gonzalo
               exporte a mano a Descargas. (2) Paso 5j nuevo: corre
               plan_compras\generar_datos.ps1 al final de los paneles (sigue por
               fuera del dashboard). Probado en PS 5.1: parser OK, validador OK con
               los exportes reales, 5j en 8 s. La bajada real se ve recien en la
               corrida del viernes 25/09 19:00: el servidor ya tiene config\aloha.json
               (login probado por la sesion del servidor, 2618 cargas fuente BR) y la
               tarea programada sincroniza sola (23/09: sync OK 5ef6bef -> 5ee3f30).
               generar_datos.ps1 pasa a BOM + CRLF.
  24/09/2026 -> Primer resumen de WhatsApp con el bloque Plan de Cargas de Aloha (el
               servidor ya tiene config\aloha.json). Gonzalo: "las cargas no quiero
               detalles, tenes que decir lo que se pidio y listo". El bloque queda en
               dos renglones: "Pedido semana del dd/MM: N camiones - N cajas" para
               esta semana y la que viene; fuera productores, estados, en camino,
               deposito y ultima descarga (eso sigue en los paneles). Ademas
               "CorupÃ¡": la API responde JSON sin charset y PS 5.1 lo decodifica
               ISO-8859-1; 3b ahora lee los bytes crudos y decodifica UTF-8.
  24/09/2026 -> Alvarito (Paraguay AS, Alvaro Saldivar): Gonzalo paso la direccion de la
               finca, plus code 5875MHG3+PQ = Toro Piru, depto. San Pedro (lat -24,323
               lon -56,445, unos 35 km al norte de Santani). Cargada en la ficha
               (productores.xlsx: Region, Localidad, Lat, Lon, Direccion; respaldo en
               archivo\productores_backup_2026-09-24_alvarito.xlsx) y zona de clima
               nueva py_toro_piru en el paso 3.5: entra al resumen de WhatsApp (semana
               pasada y prox 7 dias) y a los graficos de clima de index_brasil e
               index_paraguay_bolivia (color agregado; tambien para py_paraguay_ms, que
               salia gris). Ojo: es San Pedro, no Alto Parana; la zona de Alto Parana
               sigue pendiente de que Gonzalo diga la localidad.
               El JSON embebido de las fichas (index_brasil, index_paraguay_bolivia y
               fuentes\plan_cargas.json) se actualizo a mano para que se vea ya; el
               pipeline lo regenera igual desde productores.xlsx.
  24/09/2026 -> Fotos Y VIDEOS de packing para 4 productores de Paraguay (Gonzalo dejo
               carpetas en Descargas): paraguay_ec (8 fotos + 5 videos), paraguay_as
               (8 + 2), paraguay_ms (2), paraguay_hf (+2 fotos y 1 video a las 9 que ya
               tenia). Fotos achicadas a 1280 px; videos tal cual (mp4 de WhatsApp,
               2 a 7 MB cada uno, 34 MB en total al repo). El bloque "Fotos de packing"
               del paso 3 acepta ahora mp4/webm y la ficha (index_brasil e
               index_paraguay_bolivia, abrirFicha) los muestra con reproductor en la
               misma galeria. Ubicaciones nuevas en productores.xlsx: Paraguay EC =
               Banana EC, Asent. Oga Lata, Yrybucua, San Pedro (plus code GR6G+W3 ->
               5875GR6G+W3, lat -24,48756 lon -56,12481, verificado con geocodificacion
               inversa); Paraguay GM = Guido (Servi Fel), Zapallo, Mayor Otano, Itapua,
               SIN coordenadas: el plus code MH5P+JF resuelto contra Mayor Otano cae en
               Misiones (Argentina) y corrido una celda cae fuera del distrito; se pidio
               a Gonzalo que mande el link del mapa. JSON embebido de las 5 fichas
               actualizado a mano para que se vea ya; respaldo de la planilla en
               archivo\productores_backup_2026-09-24_ec_gm.xlsx.
  24/09/2026 -> Entradas del dia (las dejo Gonzalo en Descargas, las proceso la sesion del
               Excel de Paraguay, commit desde aca): captura del stock del ERP del 24/09 y
               4 filas en fuentes\stock\stock_diario.xlsx (registro, no entra al calculo);
               exports de Aloha del 24/09 en fuentes\plan_cargas\ (BR/PY, 2.616 cargas) y
               \otros\ (OTROS, 1.046). Desde el viernes los baja el servidor solo (3b).
  24/09/2026 -> Plan de compras, regla de las cargas dictadas. Con el export del 24/09 el
               Plan ya traia cargas del viernes 25/09 (Cassio, Corupa) y la regla vieja
               ("dictadas solo despues de la ultima carga del Plan") tiraba a Stein,
               Josemar, Marconi e Ivo del mismo viernes, que Gonzalo dicto y Aloha todavia
               no tiene: Brasil quedaba con 2 dias de stock al 03/10. Ahora la comparacion
               es POR PRODUCTOR (nombre o alias de productores.xlsx) y semana de carga: la
               dictada se omite solo si el Plan ya tiene una carga de ese productor esa
               semana; si dicto 2 y el Plan tiene 1, queda 1. Resultado: 5 dictadas
               cuentan, 21 estan en el Plan; Brasil cierra el 03/10 en 7.100 (5 dias),
               igual que la cuenta a mano del 20/09. generar_datos.ps1, LEEME y la nota del
               simulador actualizados.
  25/09/2026 -> Cargas de Gonzalo (dos capturas de sus notas, dejadas en Descargas):
               (a) fuentes\cargas 2026.xlsx, hoja Setiembre: semana 38 (14-19/09: Fisher,
               Cassio, Ivo, sin precio), semana 39 (21-26/09: Fisher R$ 38 Amaro, Cassio
               36 Axt/Alianza, Agrocurupa precio ilegible, Gilson 42 Nilton) y semana 40
               (28/09-03/10: 11 camiones planificados, sin precio). Despachante Etimex
               para Amaro/Nilton como en la semana 37, Alianza para Axt, vacio para
               Chabat. Respaldo en archivo\cargas_2026_backup_2026-09-25.xlsx.
               (b) plan_compras.xlsx, cargas_programadas: lo dictado desde el 20/09 se
               reemplaza por la nota (semana 21-26: BR 4 camiones, no 9; PY Franco 3,
               Alvarito 2, Milciades 2) y se agrega la semana 28/09-03/10 (BR 11: Fisher 2,
               Agro 2, Ivo 2, Cassio, Gilson, Josemar, Stein, Marconi; PY Milciades 1,
               Diego 2, Alvarito 1, dia supuesto lunes/martes). Stein, Josemar y Marconi
               NO cargan el 25/09: pasan al viernes 02/10. Regenerado el simulador.
  26/09/2026 -> Limpieza (Gonzalo abrio una copia vieja de index_brasil y vio las notas de
               las fichas otra vez: "borra las cosas viejas y deja lo actualizado"). Fuera
               del arbol (siguen en el historial de git): la carpeta "fuentes - copia";
               las paginas viejas de archivo\ (index_backup_*, index_brasil_backup_*,
               index_paraguay_bolivia_backup_*, index_mercado_backup_*,
               index_proyeccion_backup_*); los 4 actualizar_precios_backup_*.ps1; las guias
               de corte v1/v2.5/v3/v3.1; los zips para-uruguay (locales); y en
               fuentes\plan_cargas\ los planes superados (master de OneDrive del 08/09 y
               15/09, export del 20/09, otros del 20/09, exportaciones_aloha\). Queda solo
               el export de Aloha del 24/09 en cada carpeta (el servidor baja el suyo).
               Se conservan los respaldos de datos (xlsx/csv), archivo\importaciones_uy
               (lo lee 5c), index_ecuador_legacy, bloques_fijos, la guia v3.3 e index.html
               (redireccion a index_brasil).
  26/09/2026 -> Conteo de camaras del 26/09 (fotos de las 3 tablas + listado del ERP por camara
               pegado por Gonzalo): fuentes\stock\2026-09-26_conteo_camaras.xlsx (hojas
               banana_br_py, ecuador_zac, bolivia, zac_erp_por_camara) y las 3 fotos. Para el
               plan: BR 9709 (ZAC 8701 + CR cam 5 1.008, supuesto Brasil), PY 15617 (ZAC 13673 +
               CR cam 2 1.944, supuesto Paraguay), BO 1646 (ZAC), EC 6833 (solo ZAC). Bolivia: la
               foto dice CAM 2 = 423 y el ERP 23 (la camara 2 tiene 111 en total): se tomo el ERP,
               a confirmar. Regenerado el simulador: arranca del 26/09.
  26/09/2026 -> Correccion con el listado del ERP de Coronel Raiz (pegado por Gonzalo): la
               camara 2 de CR (1.944) es BRASIL, no Paraguay, y la 5 (1.008) Brasil; Paraguay
               esta solo en ZAC. Conteo 26/09 definitivo: BR 11653, PY 13673, BO 1646, EC 21737. Hoja
               cr_erp_por_camara en el xlsx del conteo. Queda abierta la camara 2 de Bolivia
               (foto 423 / ERP 23).
  26/09/2026 -> Curuca resuelto ("soluciona curuca"): cruce de las 6 cargas "Curuca" de la
               planilla cargas 2026 contra el Plan de Cargas por semana, transportista y
               carpeta. Sem 14: Marangoni 03/04 + Wagner 04/04 (BRB035-26); sem 15:
               Marangoni 10/04 + Wagner 10/04 (BRB036-26); sem 16: "Banana Combinada" 15/04
               (BRB036-26, alternativa Furlani); sem 5: Valdemar 24/01 o Marconi 30/01 (FG),
               sin definir. Curuca fue el intermediario de Marangoni y Wagner hasta la sem 15;
               desde la 16 figuran por su nombre. Todo en la nota de la ficha de Curuca
               (productores.xlsx + JSON embebido de los paneles). Guion del cruce:
               scratchpad curuca_analisis.ps1 / curuca_nombres.ps1 (no van al repo).
  26/09/2026 -> Panel Brasil (pedidos de Gonzalo, hechos por la sesion del Excel de Paraguay,
               commit desde aca). FUERA: "Compra Almar vs Cepea - Spread y productores"
               (ya estaba roto: escribia en #almar-cargas-value, id inexistente), "Almar BR
               en aduana" y "Despachantes 2026 (planilla de cargas)", que Gonzalo habia
               pedido sacar el 18/09 y volvio con la restauracion del ranking ("ya lo
               habiamos hablado para sacar"). Items de menu #cepea-vs-almar y #historico
               fuera; queda "Concentracion operativa" de Real BR (usa A.despachantes, las
               fichas siguen con sus chips). NUEVO: seccion "Almar vs competencia - banana
               de Brasil en aduana UY" (#competencia, antes de Comparativa): "preciso
               graficos de bananas brasil, no tengo nada para comparar mi competencia".
               Mismos datos MERCADO_BR (marcadores __MERCADO_BR_JSON__ repuestos, 5c-BR los
               inyecta igual): 4 KPIs (cuota Almar 54,6 % vs 49,9 % en 2025, #1 de 8,
               9.197 t, USD/kg 0,527 vs mercado 0,529), toneladas por mes 2026 por empresa,
               barras 100 % de cuota por anio, ranking con deltas, lecturas automaticas y
               fuente con el corte (31/08/2026). Descripcion del panel actualizada en el
               script, inicio.html y portada.json. Parser PS 5.1 OK, BOM/CRLF OK, render
               headless OK (11 canvas).
  26/09/2026 -> Curuca fuera del ranking ("Ranking de productores 2026, ordenado por camiones:
               por que esta Curuca?"). Hoja nueva "reasignaciones" en productores.xlsx
               (comprador + mes + semana -> productor_real, cargas) y en el paso 3 del script
               las filas de la planilla a nombre de un comprador pasan al productor real al
               parsear (via = comprador en el registro). Las 6 cargas de Curuca: Marconi 1
               (sem 5), Marangoni 2 y Wagner 2 (sem 14-15), Furlani 1 (sem 16). Curuca
               conserva la ficha sin cargas. Corrida completa local (21:10) para regenerar.
  26/09/2026 -> Panel Brasil, dos pedidos de Gonzalo: (1) "Resumen ejecutivo dejalo mas abajo,
               abajo de BR real": la seccion #resumen paso despues de Real BR (antes de Notas
               y supuestos) y el item del menu tambien. (2) "usa la grafica que usa Penta":
               la seccion Almar vs competencia toma el formato del reporte "Ranking por
               Importador" de Penta Transaction: una DONA por anio (2024, 2025, 2026, misma
               ventana ene-ago) con los importadores medidos en U$S VNA y "Valor total: N"
               arriba, leyenda comun, recuadro "Totales y Parametros" (U$S VNA, Kgs. Netos,
               toneladas, operaciones, USD/kg, NCM 0803.90, origen, periodo) y tabla
               Importador | U$S VNA | % Inc. | Kgs. Netos | U$S VNA anio anterior | delta pp,
               encabezado celeste y filas cebra como Penta. Paleta Material de Penta por
               ranking del anio en curso, el color sigue a la empresa. Quedan los 4 KPIs y el
               grafico de toneladas por mes; fuera las barras apiladas de cuota (las
               reemplazan las donas). Mismos datos MERCADO_BR y mismos marcadores.
  26/09/2026 -> Competencia: las donas, los totales y la tabla usan el anio COMPLETO para 2024
               y 2025 (campos usd/t/ops/cuota) y el corte para 2026 ("no quiero los anios 2024
               y 2025 enero-agosto, quiero todo el anio").
  27/09/2026 -> index_brasil SIMPLE, como index_paraguay ("quiero que sea index brasil simple
               como el que es index paraguay ... dale probemos eso"). De 11 secciones a 6:
               FUERA "Alerta de oportunidad" (queda la barra del semaforo arriba; el JS sigue y
               los nodos que faltan estan guardados), "Cepea por region", "Forecast 4 semanas"
               (va en el WhatsApp y en index_proyeccion) y "Comparativa 2024-2026" (duplicaba
               index_comparativo_anual). "Real BR" se fundio en el Resumen ejecutivo: quedan
               sus 2 KPIs (mayor dependencia y precio promedio) al lado de cargas del anio,
               ritmo, Cepea y compra Almar; fuera el KPI Forecast y la tarjeta Conversion.
               Orden final: Termometro Cepea, Clima, Plan de cargas (ranking y fichas), Almar
               vs competencia, Resumen ejecutivo, Notas. Menu con esas 5 anclas. Descripcion
               del panel actualizada en el script ($panelesDef), inicio.html y portada.json.
               Render headless: 7 canvas, todos los KPIs llenos, ranking con fichas OK.
  27/09/2026 -> index_paraguay_bolivia: seccion nueva "Almar vs competencia - banana de Paraguay
               y Bolivia en aduana UY" (#competencia, antes de Notas; item de menu Competencia).
               Pedido de Gonzalo: "falta competencia en Paraguay". Mismo formato Penta que
               Brasil, un bloque por origen (Paraguay, Bolivia): 4 KPIs, dona por anio en U$S
               VNA (2024 y 2025 completos, 2026 al corte) con "Valor total", leyenda comun,
               "Totales y Parametros", tabla Importador | U$S VNA | % Inc. | Kgs. Netos | anio
               anterior | delta, lecturas, toneladas por mes. Los datos ya estaban en
               MERCADO_PYBO (origenes.Paraguay / origenes.Bolivia); el markup lo genera el JS
               en #cpb-root, script antes de </body>, sin tocar el resumen ni las fichas.
               Descripcion del panel en $panelesDef, inicio.html y portada.json. Render
               headless: 12 canvas, 3 donas por origen, Paraguay Almar #1 de 8 (45,6 % en t),
               Bolivia Almar #2 de 3 (Ciro Gentile primero).
  27/09/2026 -> Plan de compras: venta de la semana 28/09-03/10 = 16.000 ("se pide vender
               16000, 1 carga de Bolivia, el resto PY y Brasil, no importa el orden"): BO 1.050,
               BR 8.640 + PY 6.310 (el resto repartido con el mix BR/PY del ERP). Las semanas
               siguientes quedan en 17.000 como supuesto. Cargas de la semana confirmadas por
               Gonzalo, iguales a las del 25/09. Escenarios corridos (scratchpad
               escenarios_2809b.ps1): Brasil con Gilson y Josemar al martes cierra el 03/10 con
               7 dias; para el 10/10 faltan 2-3 camiones; Paraguay necesita 3 el viernes/sabado;
               Bolivia cubierta esta semana, necesita 2 para la que viene.
  27/09/2026 -> Plan de compras UNIFICADO Brasil + Paraguay ("quiero que unifiques la compra
               brasil paraguay, para mi es lo mismo una u otra, de ahi despues yo veo que
               cargar; asi me estas enredando"). El simulador proyecta por GRUPO: BRPY (Brasil
               + Paraguay: conteo sumado, venta sumada, un solo minimo de 7 dias, 1.000
               cajas/camion para los simulados) y BO (Bolivia, igual que antes). Cada camion
               conserva su origen y sale con bandera en "quien descarga". generar_datos.ps1
               agrega grupos, nombres, conteo.BRPY, ventas_plan[].BRPY, lags.BRPY,
               cajas_camion.BRPY y camiones[].grupo; el JSON sigue trayendo BR y PY por
               separado por si hace falta volver. Clave del navegador plan_compras_sim_v5.
               Resultado (conteo 26/09, venta 16.000 la semana del 28/09): Brasil+Paraguay
               cierra el 03/10 con 19.300 (7,7 dias, minimo 17.440) con lo dictado tal cual, sin
               mover cargas; la semana del 05/10 queda en 11.800 (4,6 dias): faltan ~6
               camiones de cualquiera de los dos origenes. Bolivia igual que antes.
  27/09/2026 -> Minimo en CAJAS al cierre del sabado: Gonzalo, "preciso tener en stock de una
               semana a otra unas 22/23 mil cajas cerrando el sabado". generar_datos.ps1 emite
               minimos.BRPY = 22.500 (Bolivia sigue por dias) y el simulador lo usa en vez de
               los 7 dias de venta cuando esta cargado (casilla "Minimo al sabado, cajas",
               vacio = por dias). Con eso: la semana del 28/09 cierra en 19.300 y le faltan 4
               camiones lun-mie; la del 05/10 necesita 7 mas. Bolivia 2 para la del 05/10.
  27/09/2026 -> El minimo de 22.500 es del stock TOTAL de banana, Bolivia incluida ("a esas 22500
               le estas sumando la bolivia?"). Un solo grupo TODO (BR + PY + BO): conteo 26.972,
               venta total por semana (16.000 la del 28/09), minimo 22.500 al sabado. Cada
               camion conserva su origen (bandera) y su lag propio (BO 6 dias, BR/PY 3); los
               simulados usan 1.000 cajas y 3 dias. El simulador lee grupos, nombres y minimos
               del JSON: para volver a separar se cambian solo las lineas $GRUPOS/$NOMBRES de
               generar_datos.ps1. Regla confirmada por Gonzalo: el sabado cierra la semana, lo
               que llega el lunes suma en la siguiente. Supuesto Paraguay (Gonzalo: "la PY siempre
               se carga domingo, lunes y martes, entra siempre en la semana; por lo general 5/6"):
               hoja nueva "supuestos" en plan_compras.xlsx (py_camiones_semana = 5); en las
               semanas del horizonte sin ninguna carga PY se agregan 5 camiones "Paraguay
               (supuesto)" cargados el lunes. Resultado: sabado 03/10 cierra en 20.900 con lo
               dictado (faltan 2 camiones lun-mie); sabado 10/10, con las 8 BR del viernes y
               5 PY supuestos, cierra en 18.800 contando esos 2: faltan 4 mas.
  27/09/2026 -> Bloque "Plan de compras" en el resumen de WhatsApp. Gonzalo: "lunes es tarde,
               la semana ya esta corriendo; Brasil cierra los pedidos de la semana siguiente
               los jueves y Paraguay los miercoles". Funcion nueva Get-PlanComprasLineas en el
               script: lee plan_compras\plan_compras.json (lo genera 5j en la misma corrida) y
               repite la cuenta del simulador para el sabado de esta semana y el de la siguiente:
               stock proyectado, camiones que descargan (con los supuestos PY), venta, y cuantos
               camiones faltan para el minimo (los de esta semana se arrastran a la siguiente).
               Sale en el resumen del miercoles 12:00 y del viernes 19:00, despues del Plan de
               Cargas, con la nota "Pedidos: Paraguay cierra miercoles, Brasil jueves". Probado
               en PS 5.1 con el JSON del 27/09.
  27/09/2026 -> Resumen WhatsApp, bloque Plan de Cargas: el del 25/09 dijo "Pedido semana del
               28/09: nada todavia" con 15 cargas dictadas por Gonzalo. Ahora cada renglon suma
               "N dictados que Aloha aun no tiene" (fuente plan_compras del JSON del paso 5j,
               que ya excluye lo que Aloha tiene) y el texto pasa a "nada en Aloha todavia".
  27/09/2026 -> MODO PRUEBA de WhatsApp (Gonzalo: "manda el mensaje entero a todos los celulares a
               ver como seria"). Variable de entorno PORONGA_WA_PRUEBA=1 al correr el script:
               manda SOLO el resumen, aunque no sea miercoles/viernes y aunque config tenga
               enabled=false, con encabezado "PRUEBA - asi saldria el resumen", sin banner de
               atraso y sin tocar state_whatsapp.json. Uso: $env:PORONGA_WA_PRUEBA=1 y correr
               actualizar_precios.ps1 (en la laptop no hay config\aloha.json, asi que la prueba
               sale sin el bloque Plan de Cargas; en el servidor sale completo). Corrida de
               prueba 27/09 17:1x: 3/3 entregados. Paneles regenerados en la misma corrida.
  27/09/2026 -> Resumen WhatsApp mas liviano (Gonzalo: "lo veo muy cargado"; "para que el score 1? que
               dato te da?"). Salen del resumen: Ecuador FOB (y su novedad/alerta; "va por otro canal
               de ventas", sigue en index_ecuador), Modelo 4 sem (sigue en index_proyeccion), el bloque
               Score con su descomposicion (el numero solo no dice nada; el score sigue calculandose y
               eligiendo la frase de Sugerencia y las alertas Oportunidad/STOP, y queda en consola e
               index_brasil) y el bloque Calendario, que ahora es un renglon dentro de Cepea. Clima
               compacto: solo zonas con aviso, un renglon semana pasada y otro prox 7 dias. Carape en
               una linea. Sugerencia mas corta.
               NUEVO en Cepea (pedido de Gonzalo): precio por CAJA = R$/kg x 22 kg ("1,18 x 22 es el
               valor caja y comparamos con lo que compramos nosotros"), y debajo lo que pago Almar la
               ultima semana con cargas (R$/caja, cargas): diferencia bruta en R$ y % sobre la caja
               Cepea, y neta descontando servicios (R$ 16/caja: envalado, paletizado, flete interno).
               El bloque "Almar" aparte desaparece (mismo precio en dos lugares).
               Modo prueba nuevo: PORONGA_WA_PRUEBA=dry imprime el resumen en la consola y NO manda
               nada (para revisar el texto sin molestar a los celulares). Prueba real 17:0x: 3/3
               entregados (version intermedia, todavia con bloque Almar aparte); dry 17:11 con la final.
               PENDIENTE (no tocado): la senal 3 del score (spread Almar vs Cepea) da siempre 0 porque
               las semanas Almar van con fecha sabado y las Cepea con fecha viernes: nunca cruzan.
  27/09/2026 -> Score, senal 3 (spread Almar vs Cepea+servicios) ARREGLADA (Gonzalo: "si queres que el
               spread cuente, lo arreglo" -> si). Daba siempre 0 porque las semanas Almar tienen fecha
               sabado y las Cepea viernes. Ahora busca la Cepea a +-3 dias (como el paso 5d) y toma las
               ultimas 4 semanas Almar CON precio. Mismo arreglo en el JS de index_brasil (Senal 3).
               Efecto hoy: spread -3,0 R$/caja -> senal -1, score pasa de -1 (NORMAL) a -2 (CAUTELA).
               Servicios por caja: 16 -> 18 R$ (Gonzalo: "estoy pagando 18 mas precio na roca", "solo
               en Brasil es 18"). $SERVICIOS_CAJA en el script (viaja en el sidecar como servicios_caja)
               y los 16 que estaban a mano en index_brasil (termometro, texto del ranking, plazas Cepea),
               index_paraguay_bolivia (texto del ranking) e inicio.html (equivalente por caja). Se suma
               SOLO al precio Cepea (caja equivalente Brasil); a Paraguay/Bolivia no se les suma nada.
               Revisado con PORONGA_WA_PRUEBA=dry (no se mando WhatsApp).
  27/09/2026 -> plan_compras.xlsx / cargas_programadas: carga extra Stein mie 30/09 con Nilton (Gonzalo:
               "asi cierro mejor pensando en futuro"). Sab 03/10 pasa a 21.918 cajas (falta 1 camion) y
               sab 10/10 a 18.810 (faltan 4). Resumen WhatsApp: "falta 1 camion" en singular; en modo
               prueba (1 o dry) el texto del resumen tambien queda en la consola/log. Prueba real 19:52
               pedida por Gonzalo: 3/3 entregados. Paneles regenerados en la misma corrida.
  27/09/2026 -> Resumen WhatsApp: la "Sugerencia" final pasa a "Lectura". Gonzalo ("que es eso????") vio
               que "Cautela - senales combinadas negativas. Ventana atipica: ... evaluar compra" se
               contradecia: la primera frase venia del nivel del score (hoy -2 por el spread y el frio,
               que no son razones para no comprar) y la segunda de Get-AccionZona. Ahora es una sola
               oracion con datos y sin score: precio real vs historico del mes + tendencia de 3 sem, y
               como viene pagando Almar contra Cepea+servicios (ultimas 4 sem, el mismo spread del
               score). El score sigue vivo para las alertas Oportunidad/STOP y en index_brasil.
               Revisado en dry y prueba real enviada a pedido de Gonzalo ("a ver como quedo el definitivo").
  28/09/2026 -> Resumen WhatsApp, bloque Plan de compras: "faltan N camiones" pasa a "cargar N mas hasta el
               mie dd/MM para cerrar en 22.500" (Gonzalo: "lo ideal seria que vos me informes que cargar";
               a comienzo de semana carga 3/4 de Brasil pero no se asumen: el numero que sale ES lo que hay
               que cargar ademas de lo dictado y de los 5 PY supuestos). La fecha limite es el sabado menos
               el lag (3 dias = miercoles). Al final de cada renglon, los origenes que quedan con menos de
               7 dias de venta ("justo: Brasil 5,4 dias, Bolivia 0,5 dias"), para saber de donde cargar.
               Hoy: sab 03/10 cargar 1 mas hasta el mie 30/09; sab 10/10 cargar 4 mas hasta el mie 07/10;
               Bolivia se queda sin stock la semana del 05/10 si no carga un camion antes del sab 04/10.
               Sin envio de WhatsApp (revisado con la replica de Get-PlanComprasLineas).
  28/09/2026 -> MARCHA ATRAS parcial del cambio anterior (Gonzalo: "esa parte la quiero plasmada en plan
               compras, no en el wasap"): el WhatsApp vuelve al texto aprobado ("falta 1 camion para
               22.500"; actualizar_precios.ps1 restaurado al commit c2929ba). Lo de "que cargar" pasa al
               simulador plan_compras\simulador.html: seccion nueva "Que cargar" arriba (por sabado: stock,
               camiones a cargar ademas de lo dictado/supuesto y hasta que miercoles, origenes con menos de
               7 dias de venta, y el stock por origen BR/PY/BO con sus dias), columna "Por origen" en la
               tabla de saldo y la misma info en el resumen para copiar. El stock por origen se lleva con la
               venta por origen de ventas_plan (si la venta del grupo se fija a mano, se reparte con el mix
               del plan) y el conteo por origen (escalado si se toca el conteo total). Hoy: sab 03/10 cargar
               1 mas (Brasil 6,2 dias); sab 10/10 cargar 4 mas (Brasil 5,4 dias, Bolivia 0,5: sin camion BO
               antes del sab 04/10 Bolivia se queda sin stock). Render verificado con Edge headless.
  28/09/2026 -> Simulador: venta SEMANA POR SEMANA (Gonzalo: "hacerlo dinamico para que yo vaya agregando
               semanalmente las ventas conforme a si es comienzo de mes o final de mes"). En la tabla de
               saldo, la columna "Se vende" es un campo por semana (vacio = plan de ventas_plan; la semana
               del conteo no se edita). Lo escrito pisa al plan y a la venta fija, queda en localStorage
               (plan_compras_sim_v5.ventaSem), se marca "a mano", cuenta en el estado ("N semana(s) con
               venta escrita a mano") y en el resumen de texto; el reparto por origen usa el mix del plan.
               "Volver a lo cargado" lo borra. Probado con Edge headless: 05/10 = 14.000 -> sab 10/10 cierra
               en 21.810 y pide 1 camion en vez de 4.
  28/09/2026 -> Simulador, orden de la pagina (Gonzalo: "no conviene que ese saldo este en el comienzo?"):
               ahora va KPIs, "Que cargar", 1. Saldo por semana de venta (con la venta editable), 2. Camiones
               por semana de carga + parametros, 3. Resumen. Solo cambio de orden en el HTML.
  28/09/2026 -> PLAN DE COMPRAS SIMULADO EN EXCEL: plan_compras\Plan_Compras_Simulado.xlsx (+ generar_plan_xlsx.ps1
               que la arma desde plan_compras.json y precios_cepea.json). Pedido de Gonzalo: "hables con la otra
               ventana e intercambien ideas, busquen informacion y dejen una planilla de plan compras simulado
               hecha a medida de mis necesidades y de una empresa multinacional". Trabajo a dos sesiones: la
               otra investigo S&OP de multinacionales de fruta (Dole, Fyffes, RELEX, Tridge, Produce News) y
               aporto lead times reales por origen (mediana/P90), proveedores 2024-2026, precios de aduana por
               origen y el mercado exportador PY (Penta); esta armo 14 hojas con formulas Excel: Inicio,
               Calendario S&OP, Parametros (minimo, lead times, cajas/camion, conteo, escenario, atraso
               frontera, costos por origen, estacionalidad por semana del mes, stock de seguridad z*sigma*
               raiz(LT+1), capacidad de maduracion), Demanda, Cargas (34 camiones cargados: Aloha, dictados,
               supuestos), Proyeccion (mismo resultado que el simulador web: sab 03/10 21.918 cargar 1, sab
               10/10 18.810 cargar 4), QueCargar, Semaforo, Escenarios, Capacidad, KPIs, Proveedores,
               MercadoPY, Glosario. Precios de Gonzalo (28/09, via la otra sesion): Paraguay USD 7/caja,
               Brasil promedio ponderado 4 sem de almar.semanas (R$ 36,87), Bolivia pendiente. Verificado en
               Excel (COM): 0 errores de formula, valores calculados guardados.
  28/09/2026 -> Plan_Compras_Simulado.xlsx, correcciones de la revision de la otra sesion: (1) BUG: el nombre
               definido "Hoy" lo guardaba EPPlus como referencia de columna (HOY1, HOY2...) en 389 formulas:
               Excel no marcaba error pero comparaba contra 0 (pedia cargar con el limite pasado, pipeline
               en 0, camiones por proveedor en 0). Renombrado a FechaHoy; el chequeo COM ahora busca
               HOY<n> en todas las formulas (0). (2) Proveedores: capacidad = promedio de las 2 mejores
               semanas (el maximo queda como "pico"), Corupa/Corupá unificados, faltante % por productor.
               (3) Supuestos BR: 8 camiones los viernes mas alla de lo dictado (Estado "Supuesto BR") con
               interruptor SupBR en Parametros (y SupPY para los 5 de Paraguay); con SupBR=0 la planilla
               pide toda la necesidad como el WhatsApp. (4) KPIs nuevos: faltante promedio proveedores y
               OTIF (columna en Cargas). (5) Bloque de precios unico (fila 29 remite a la 32). (6) Lead time
               PY: se deja 3 (regla de Gonzalo, coincide con simulador y WhatsApp) con nota de que la
               mediana real es 4. (7) Vida util en verde 16 dias marcada como SUPUESTO con referencia UC
               Davis. (8) Escenario sin HF = -3 camiones PY. Notas de proxy en Capacidad y de mix en Demanda.
  28/09/2026 -> LEAD TIME PARAGUAY 3 -> 4 DIAS (Gonzalo, via la otra sesion: "paraguay vamos a 4 dias dale"; es
               la mediana real de Aloha). En las tres herramientas: plan_compras\generar_datos.ps1 ($LAG_DESC
               PY = 4, y el JSON lags.PY.descarga sale de ahi), simulador web (usa el JSON; textos), bloque
               Plan de compras del WhatsApp (lee el JSON) y Plan_Compras_Simulado.xlsx (Parametros fila 14
               desde el JSON; la fecha limite general usa el lead time mas largo BR/PY y QueCargar muestra el
               limite por origen). Con las cargas de hoy no cambia nada: PY carga lunes y martes y con 4 dias
               descarga viernes y sabado, dentro de la semana. Lo que cambia: un PY del miercoles ya no entra.
  28/09/2026 -> Excel: el camion Paraguay AS cargado el 23/09 (Aloha "Solicitado" en el export del 24/09) tiene
               descarga real 27/09 confirmada por Gonzalo ("domingo 27/09 si descarga"): despues del conteo
               del sabado, suma a la semana del 28/09. Queda fijo en generar_plan_xlsx.ps1 ($descConfirmadas)
               hasta que el export de Aloha lo traiga. Sab 03/10 = 22.898 (ok), sab 10/10 = 18.790 (cargar 4).
  28/09/2026 -> Excel, hoja MercadoPY (Gonzalo: "te acordas que Paraguay los productores tienen mas de una
               empresa?"): columna Grupo con los TRES grupos que el confirmo el 19/09 (Misionero + Ecotierra;
               Hugo Franco + Agroganadera San Jose Obrero; Melgarejo + Servi-Fel) y un ranking agrupado (3
               grupos + individuales). Ningun otro grupo inferido. "San Jose Obrero" pasa a su razon social
               completa para no confundirlo con Agro Climatizadora San Jose.
  29/09/2026 -> VENTA SEMANAL REAL POR ORIGEN (Gonzalo dejo en Descargas la captura del reporte semanal del ERP,
               jul-sep 2026, 12 semanas; guardada en fuentes\ventas\). Hoja nueva plan_compras.xlsx >
               ventas_semanales (lunes, sabado, BR, PY, BO, EC, total banana); generar_datos.ps1 la lleva al
               JSON como ventas_reales. ventas_plan: sem 14/09 y 21/09 pasan a REAL (15.851 y 14.845) y los
               SUPUESTOS de 17.000 se reparten con el mix real de las ultimas 4 semanas (BR 61,7 / PY 31,2 /
               BO 7,1) en vez del mix de la sem 38. Excel: Demanda con historial de 12 semanas + promedio,
               ultimas 4, desvio estandar y mix; venta real en la fila del 21/09; SigmaVenta pasa de supuesto
               (10%) a la real (STDEV del historial, ~1.280 cajas). Notas al pie en celdas combinadas con
               ajuste de texto (se veian cortadas); MercadoPY con los 3 grupos + ranking agrupado y Diego
               Fernandez (puesto 23, ~940 cajas/sem, 61% marca PEPE); .gitignore: ~$*.xlsx (bloqueo de Excel).
  30/09/2026 -> TRAZABILIDAD DE CORTES, arranque (Gonzalo: "vamos a la trazabilidad, cortes de banana"). Gonzalo
               paso el prompt/resumen del control por corte de Aloha (IA Opus dentro del ERP, protocolo UAM v1,
               11 lecturas en 8 camiones descargados el 25 y 26/09, confirmadas por el operario). Cargado en
               fuentes\calidad_lotes.xlsx: 8 lotes nuevos en la hoja lotes (PYAS012, PYMS021, SUPREMA-2509,
               PYMS022, FH070, BONITA-278, PEPE-275, BONITA-279) con corte_color de llegada, destino y camara
               probable (cruce con el conteo del 26/09), y hoja nueva cortes_recepcion (una fila por lectura:
               pie de camion, lote/marca, pallet, chofer, placa, dedos, puntaje, veredicto, posicion adelantada,
               sospechas, accion, protocolo, confianza). Imagenes del resumen en
               fuentes\calidad_fotos\2026-09-25_cortes_aloha_recepcion\. Pipeline corrido: 11 lotes en
               index_calidad (0 con fecha_rompio: sigue faltando el dato de camara). Pendiente: mostrar la
               hoja cortes_recepcion en index_calidad (hoy el paso 5g solo lee "lotes").
  30/09/2026 -> Plan de compras: cargas dictadas por Gonzalo para la semana del 5 al 10/10 (17 filas en
               cargas_programadas): Brasil 11 (Fisher mar+vie, Agro mie+vie, Cassio mar+sab, Ivo mie+vie,
               Gilson vie, Stein mar, Marconi vie; transportista supuesto = semana anterior) y Paraguay 6
               (Milciades lun+mar, Diego lun+mar, Guido mie, Alvarito lun). Bolivia: nada dictado. Resultado:
               sab 03/10 22.898 ok; sab 10/10 24.738 ok (BR 11.450 = 6,5 dias, PY ~12.800 = 14 dias, BO 450 =
               2 dias); sab 17/10 18.614, faltan 4 (las de comienzo de esa semana). Guido carga miercoles y
               con 4 dias descarga el domingo 11: suma a la semana siguiente. Opinion dada en el chat:
               Paraguay sobra (llega en corte 2), Bolivia falta.
  30/09/2026 -> Gonzalo saca la carga de Cassio del martes 06/10 (queda la del sabado 10). Sab 10/10 cierra en 23.802, ok.
  01/10/2026 -> Semana 05-10/10, version final de Gonzalo (Uruguay pide cerrar el sabado 10 con 25.000): Brasil 11
               (Fisher mar+vie, Agro mie, Cassio mie+sab, Ivo mie+vie, Gilson vie, Josemar mar, Stein mar, Marconi
               vie) y Paraguay 5 (Milciades lun+mar, Diego lun+mar, Alvarito lun). Sale Guido. Sab 10/10 cierra
               en ~25.700. El minimo de las herramientas sigue en 22.500 hasta que Gonzalo diga si 25.000 es fijo.
  01/10/2026 -> FIX semana de descarga: una descarga de DOMINGO se sumaba a la semana que cerro el sabado anterior
               (lunesDe(domingo) = lunes previo). Con Paraguay a 4 dias (miercoles -> domingo) y Bolivia a 6
               (lunes -> domingo) eso contaba fruta en un sabado ya cerrado. Ahora el domingo pertenece a la
               semana que arranca, en los tres lados: Get-PlanComprasLineas (WhatsApp), simulador.html (lunes())
               y Plan_Compras_Simulado.xlsx (columnas Semana de venta y Semana P90 de Cargas). Correccion al
               numero del dia: sab 10/10 cierra en 24.766 (en el chat habia estimado 25.700 por error de suma).
  01/10/2026 -> MINIMO 25.000 Y BOLIVIA 1 POR SEMANA (Gonzalo: "de Bolivia vamos a descargar uno por semana
               siempre; comienza el calor en Uruguay, levanta las ventas, quieren mantener 25 mil cajas al cierre
               del sabado contando todo, PY BOL y BR"). Hoja supuestos de plan_compras.xlsx: minimo_cajas_sabado
               = 25000 y bo_camiones_semana = 1; generar_datos.ps1 los lee (minimos.TODO; un camion BO supuesto
               por semana de venta sin descarga BO, cargado 6 dias antes del lunes si esa fecha no paso). Lo toman
               el WhatsApp, el simulador y el Excel. Textos "supuestos PY" pasan a "supuestos".
  01/10/2026 -> WhatsApp, bloque Plan de compras: solo pide camiones si todavia se llega (limite = sabado menos 3
               dias). Si el limite ya paso, dice "bajo el minimo; ya paso el limite de carga" y NO arrastra
               camiones imposibles a la semana siguiente (con el minimo nuevo de 25.000, el viernes 02/10 habria
               pedido 3 camiones para el sabado 03/10). Misma regla que el simulador y el Excel.
  01/10/2026 -> ventas_plan: las semanas SUPUESTO (desde el 05/10) pasan de 17.000 a 18.000 (Gonzalo: "si sube es a 18 mil la venta, no mas que eso"), mix real ult. 4 sem.
  01/10/2026 -> Bolivia: el camion supuesto se cuenta SIEMPRE, una por semana, desde la semana en curso, aunque la fecha de carga ya haya pasado y Aloha no lo tenga (Gonzalo: "conta una carga por semana siempre de Bolivia").
  01/10/2026 -> Semana 05-10/10, version 3 de Gonzalo: Brasil 10 (Fisher mar+vie, Agro mie, Cassio mie, Ivo mie+vie, Gilson mie, Josemar mar, Stein mar, Marconi vie), Paraguay 5. Sale Cassio sabado; Gilson pasa a miercoles.
  01/10/2026 -> v4: Gilson vuelve al viernes 09 (Gonzalo: "prefiero cerrar en casi 25 mil que casi 26 mil"). Sab 10/10 24.816 (falta 1), sab 17/10 17.806.
  01/10/2026 -> Guido (Paraguay GM) dictado para el martes 13/10 (descarga sabado 17). generar_datos.ps1: cuando una semana tiene MENOS cargas PY dictadas que el ritmo habitual (5), se completa con supuestos en vez de anularlos.
  02/10/2026 -> Cargas dictadas (version final sem 05-10/10 + nueva sem 12-17/10). Sem 05/10: Brasil 8 (Fisher mar
               +vie, Agro mie, Cassio mie, Ivo lun+mie, Stein mar, Celso mie) y Paraguay 5. Sem 12/10: Brasil 11
               (Fisher mar+sab, Agro mie+vie, Cassio mar+vie, Ivo mie+vie, Celso mie, Marconi mie, Josemar vie) y
               Paraguay 6 (Alvarito lun, Diego lun+mar, Milciades lun+mar, Guido mar). CELSO es un productor
               nuevo: no esta en productores.xlsx ni en Aloha (sin transporte ni nombre completo todavia).
  02/10/2026 -> El resumen del viernes 19:00 salio con "Pedido semana del 28/09: 20 camiones · 44.036 cajas" (2.200
               cajas por camion: cajas_mic de la API trae las cajas del documento aduanero entero, que agrupa varios
               camiones) y con la Lectura "estable en 3 sem (+10%)" con el Cepea cayendo 13,6% en la semana. Se
               mando a mano un mensaje corregido a los 3 celulares (scratch wa_enviar_texto.ps1; 3/3). Arreglos en
               actualizar_precios.ps1 para el miercoles: (1) Plan de Cargas: si el promedio de cajas por camion no
               es creible (fuera de 500-1.300) se omiten las cajas y queda "N camiones en Aloha"; diagnostico por
               camion en el log ([diag plan ...]) para ver mic/desc/carpeta/factura y arreglarlo de raiz. (2) Lectura:
               primero la semana ("bajo 14% esta semana") y umbrales sobre el valor redondeado. (3) CLIMA una linea
               por zona (Gonzalo: "lo quiero por lineas, cada departamento y enter"): bandera, nombre con tilde,
               max/min de la semana pasada con 🔥/🥶/🌧️, y los proximos 7 dias SIEMPRE con numeros (max, min, mm) mas
               avisos entre parentesis (Gonzalo: "proximos sin aviso????": decir solo "sin avisos" no servia).
  02/10/2026 -> Precios y cargas reales de la semana 40 (28/09-03/10) en cargas 2026.xlsx: 12 cargas, R$ 38,33
               promedio ponderado (Fisher 36 x2, Agro 35, Ivo 43 x2, Cassio 35 x2, Gilson 40, Josemar 43, Stein 38
               x2, Marconi 38). Agro del viernes no cargo; Cassio cargo tambien el miercoles con Nilton: corregido
               en plan_compras.xlsx (sab 03/10 pasa a 23.834). Total de la semana con promedio ponderado.
  02/10/2026 -> Plan de Cargas (paso 5h y resumen): cajas POR CAMION en vez de sumar cajas_mic. Regla (otra sesion, con
               los exports de Aloha del 24/09): 1) "Cajas desc." si existe y no supera 1,3 x la tipica del origen;
               2) pallets x cajas por pallet (BR 36, PY 35, BO 48, EC/CO 54); 3) cajas MIC dividido entre las filas
               que comparten carpeta + factura; 4) la tipica (BR 1.008, PY 980, BO 1.050, EC 1.080). Y un camion con
               DOS documentos (misma placa y fecha de carga, MICs que suman un camion) se cuenta una vez. Funciones
               Get-OrigenPlanRow / Get-CajasCamionPlan / Get-CamionesPlan, con fallback a cajas_mic si fallan.
               Probado con filas sinteticas (8 filas -> 7 camiones, 7.072 cajas). El control de verosimilitud del
               WhatsApp queda como red; el [diag plan] del log muestra ademas placa y el valor usado.
  02/10/2026 -> Resumen WhatsApp, bloque Cepea reordenado (Gonzalo: "eso que es???? todo desordenado"): una idea
               por linea. "Kilo: R$ x · bajo y% en la semana · +z% en 3 semanas" / "Caja de 22 kg: R$ a · con
               servicios (R$ 18): R$ b" / "Octubre historico (2023-2026): R$ c/kg -> hoy d% mas barato". Almar
               vuelve a bloque propio: "semana dd/MM: N cargas a R$ p/caja" y "Contra la caja Cepea: +R$ ... ·
               contra Cepea con servicios: -R$ ...". Mismos numeros que antes, mejor repartidos.
  03/10/2026 -> Resumen WhatsApp, el resto de los parrafos a una idea por linea (Gonzalo: "hay que ordenar todos
               los parrafos como hicimos con las temperaturas"): Carape en 3 renglones (fuente / caja PYG con su
               variacion / USD por kg contra Brasil); Plan de compras en 2 renglones por sabado (cierre y veredicto /
               descargan y vende); Lectura con titulo propio y una oracion por renglon.
  03/10/2026 -> Resumen WhatsApp, bloque Plan de Cargas dado vuelta (Gonzalo: "Plan de Cargas es lo que yo te paso;
               Aloha no actualiza las cargas hasta el lunes, por eso no estan nunca"). Ahora muestra LO DICTADO
               (plan_compras.json, fuente plan_compras) para esta semana y la que viene, por origen ("Semana del
               05/10: 13 camiones · Brasil 8 · Paraguay 5"), y Aloha solo como control de la semana pasada ("20
               camiones en Aloha, N cajas · 17 dictados"). Sale aunque no haya Aloha (laptop). De paso se saco un
               "else" que habia quedado separado de su "if" por la linea de diagnostico.
  03/10/2026 -> generar_datos.ps1 exporta dictadas_por_semana (lo dictado completo por semana de carga y origen, antes de descontar lo que Aloha ya tiene); el bloque Plan de Cargas lo usa, asi la cuenta no baja cuando Aloha registra las cargas el lunes.
  03/10/2026 -> Resumen WhatsApp, bloque Cepea rehecho otra vez (Gonzalo: "se lee confuso"; "cuanto cerro el kilo por
               semana, cuanto pagamos nosotros na roca mas servicios, y el kilo de San Pablo"): Cepea en R$/kg al
               productor, Santa Catarina y Sao Paulo (Vale do Ribeira, region 52 del paso 2b), cada uno con su
               variacion semanal; Almar en bloque propio con caja y kilo na roca y con servicios (R$ 18). Afuera:
               la caja equivalente Cepea, el dato de 3 semanas, el historico del mes (sigue en la Lectura) y las
               comparaciones cruzadas Almar vs Cepea.
  03/10/2026 -> Ajustes de Gonzalo al resumen: Cepea solo "SC" y "SP" (leyenda en el titulo). ALMAR: el precio de la
               planilla cargas 2026.xlsx YA incluye los R$ 18 de servicios ("yo pague 20 reales y algunos 25, mas los
               18 de servicios"), asi que na roca = precio - 18 y se muestra derivado (R$ 20,33/caja = 0,92/kg) junto
               al precio con servicios (38,33 = 1,74/kg). Las comparaciones del score (precio planilla vs Cepea +
               servicios) ya eran coherentes con eso. CLIMA: bandera + sigla del lugar (LA, G, T, C, TP, Y) con
               leyenda en cursiva debajo del titulo, y "prox:" en vez de "prox 7 dias:". Plan de compras: "ya paso
               el limite de carga" pasa a "ya no llega ninguna carga mas para este sabado".
  03/10/2026 -> Resumen WhatsApp para el CELULAR (captura de Gonzalo: los renglones largos se parten): tope ~38
               caracteres por renglon. Clima: "🇧🇷 LA 30/14🥶 69mm → 26/16 60mm 🌧️" (pasada → prox 7 dias; avisos
               como emoji al final), leyenda de siglas en cursiva. Almar: "Na roca: 20,33 = 0,92/kg" y "Con
               servicios: 38,33 = 1,74/kg" (titulo dice R$/caja). Cepea: titulo corto, SC/SP. Carape sin
               "(Cepea + servicios)". Plan de Cargas: "Sem dd/MM: N camiones (BR x, PY y)". Plan de compras:
               "*Sab dd/MM:* N → ok | faltan N camiones | bajo el minimo, ya cerrado" y "descargan X (n sup.) ·
               vende Y"; titulo "cajas al cierre, min 25.000" con el conteo en cursiva debajo.
  03/10/2026 -> PENTA ECUADOR (los PDFs que faltaban desde el 03/09): Gonzalo dejo en Descargas los dos "desglose
               operadorLocal UYimport" de Ecuador, ranking por importador NCM 0803.90, ene-sep 2026 y ene-sep 2025.
               Guardados en penta\rankings_pdf\ con el decodificado (decodificar_pdf_penta.ps1). Ecuador ene-sep:
               2026 13,33 M USD / 14.460 t brutas (Almar 45,6 %, Proexur 21,5 %, Ciro 17,5 %, Lina Fresh 10,5 %,
               Henderson 5,0 %); 2025 10,91 M USD / 11.744 t (Almar 41,8 %, Proexur 27,4 %, Ciro 23,0 %, Henderson
               4,9 %, Lina Fresh 2,5 %, Marama 0,5 %). Todavia NO entra en ningun panel (index_ecuador usa el
               detalle xlsx con corte 31/08): pendiente decidir con Gonzalo si va como seccion de competencia.
  03/10/2026 -> PANEL ECUADOR, seccion "Almar vs competencia - banana de Ecuador en aduana UY" (Gonzalo dijo "si"
               a la propuesta). Fuente: los dos PDF "Ranking por Importador" de Penta (ene-set 2025 y ene-set 2026)
               pasados A MANO a un JSON embebido en index_ecuador.html entre /*__EC_RANKING_JSON__*/ y
               /*__END_EC_RANKING__*/ (actualizar_precios.ps1 NO lo toca; para sumar un periodo se agrega un
               elemento a "periodos"). Muestra 4 KPIs (cuota 45,55 %, #1 de 5, 6.535 t brutas +33 %, USD/kg 0,929),
               donas SVG por periodo (la pagina no carga Chart.js), "Totales y Parametros", tabla Penta con el periodo
               anterior y variaciones, lectura calculada y una ficha nueva en "De donde sale cada dato". Kilos BRUTOS
               como Penta. Ojo al corte: el ranking llega al 30/09 y el resto del panel usa el detalle al 31/08.
               index_ecuador.html usa LF (no CRLF): respetarlo al editar.
  03/10/2026 -> ALOHA EN LA LAPTOP. Gonzalo marco que en index_brasil "Camion por camion", "Productores - camiones,
               cajas, transito y faltantes" y el KPI "En camino ahora" estaban viejos (export del 24/09, "proxima
               carga 22/09"). Causa: desde el 25/09 el servidor baja el plan de Aloha solo, pero NUNCA sube paneles
               (correr_servidor.ps1 solo hace fetch + reset); los paneles que se ven son los que genera la laptop,
               y la laptop no tenia config\aloha.json, asi que 5h tomaba el ultimo export a mano (24/09). Arreglo:
               Gonzalo paso su acceso a Aloha y se creo config\aloha.json en la laptop (gitignore; NO va al repo).
               Ahora cada corrida local (logon, mie 12:00, vie 19:00) baja los dos exports (paso 3b) y 5h/5j usan
               el del dia. Corrida de hoy 16:49: 2639 cargas del plan, 150 camiones en el bloque (11 por venir,
               129 descargados, fuente Aloha). Las cargas del viernes siguen "Solicitado" en Aloha hasta el lunes,
               por eso el KPI dice "proxima carga 02/10". Diferencia menor pendiente: el KPI (5h) cuenta 1 camion
               en camino y el bloque camion por camion (Aloha) 0: clasifican distinto un estado intermedio.
               Plan de compras con el plan del dia: sab 03/10 22.926 (bajo el minimo, cerrado), sab 10/10 26.788 ok.
  03/10/2026 -> CONTEO DE CAMARAS 03/10 (sabado). Gonzalo mando las 3 planillas de camaras: la general BR+PY (el
               color de la celda CAM dice el origen: gris = Paraguay, naranja = Brasil), Bolivia y Carton (= Ecuador).
               Guardadas en fuentes\stock\ (3 jpeg + 2026-10-03_conteo_camaras.xlsx, una hoja por planilla: cub,
               camara, sede, cajas, dia de gas, dia de venta, obs). Conteo: BR 12.269 (ZAC 10.253 + Coronel Raiz
               cam 4 2.016), PY 9.676, BO 1.500, EC 7.993 (solo ZAC, referencia). Cierre del sabado 03/10 = 23.445
               cajas madera + Bolivia (Gonzalo: "cerramos la semana con 23445"), bajo el minimo de 25.000. Con eso
               el plan da: sab 10/10 27.307 ok (descargan 22, 1 supuesto BO); sab 17/10 23.221 -> faltan 2 camiones
               hasta el mie 14/10; sab 24/10 18.139 -> faltan 7. Resumen WhatsApp (Get-PlanComprasLineas): si el
               conteo es del mismo sabado o posterior, ese sabado sale como "cerro bajo el minimo (conteo)" sin el
               renglon "descargan 0 · vende 0".
  03/10/2026 -> Venta de la semana del 05/10 planificada en 17.000 (Gonzalo: "la venta semana que viene esta planificada
               en 17 mil cajas"): fila del 05/10 en ventas_plan = BO 1.050 (1 carga) + BR 10.593 + PY 5.357 (resto con
               el mix BR/PY del ERP, misma convencion que la fila dictada del 28/09). Las semanas siguientes siguen en
               18.000 supuesto. Resultado: sab 10/10 28.307 (sobran ~3.300 sobre el minimo), sab 17/10 24.221 -> falta
               1 camion hasta el mie 14/10, sab 24/10 18.139 (sin dictar todavia).
  03/10/2026 -> Cassio contado dos veces en la semana del 05/10: Aloha ya tenia la carga del viernes 02/10 ("Cassio
               Hauck", AXT, Solicitado) y la dictada del viernes seguia contando porque esa semana habia 2 dictadas
               (miercoles con Nilton, carga real, + viernes) y 1 en Aloha: la regla "si dicto 2 y el Plan tiene 1
               queda 1 (la ultima)" dejo la del viernes. Gonzalo: "es Cassio si, solo que Aloha lo usa con nombre y
               apellido" (el alias ya estaba en productores.xlsx). Se borro la fila dictada del viernes 02/10 de
               cargas_programadas. Numeros: sab 10/10 27.371 ok, sab 17/10 23.285 -> faltan 2 (el 7mo de PY mas 1),
               sab 24/10 16.203 -> faltan 9 (semana sin dictar). OJO con la regla: si una de las dictadas de esa
               misma semana ya descargo antes del conteo, hay que borrar la que Aloha ya tiene, no dejar "la ultima".
  04/10/2026 -> documentos\2026-10-04_HANDOFF_corte_banana_aloha.md: traspaso que escribio el Claude del servidor para
               la sesion "Corte de Banana" de Aloha (3 ramas sin mergear: matcheo corte-camion por QR, mas contexto del
               camion para la IA, mover un corte al pie correcto; abierto: cerrar el ciclo en camara vive en CloudPepeV2,
               semana de cinta necesita migracion). Gonzalo lo dejo en Descargas y pidio publicarlo. Se omitio una sola
               linea (URL de la camara en vivo sin credenciales). Nos toca: el corte de SUPREMA del 25/09 esta guardado
               en el pie #249 (del 17/09) en Aloha; en calidad_lotes.xlsx el lote SUPREMA-2509 esta bien fechado.
  05/10/2026 -> documentos\2026-10-05_PROMPT_corte_banana_aloha.md: version nueva del traspaso del Claude del servidor.
               Todo lo del 04/10 ya esta MERGEADO y DEPLOYADO en testing y main (9 PR): matcheo corte-camion por QR que
               descarta en vez de desempatar, mas contexto del camion para la IA, mover un corte al pie correcto (mig
               0228, sin DELETE a proposito), selector de pie afuera de CorteTab. Sigue abierto: cerrar el ciclo en
               camara (CloudPepeV2), semana de cinta (migracion), la camara del carrito sin login (el arreglo es en la
               app de la laptop de recepcion o el tunel, no en Aloha) y mover a mano el corte de SUPREMA del 25/09 que
               sigue en el pie #249. El handoff del 04/10 queda marcado como viejo arriba del todo.
  06/10/2026 -> Corrida con el Aloha del martes (Aloha carga las fechas reales de la semana el lunes). El plan real de la
               semana 05-10/10 quedo UN DIA MAS TARDE que lo dictado: Fischer/Ivo/Stein mie 07 (dictados mar 06 y lun/mie),
               Cassio/Celso/Corupa/Ivo JUEVES 08 (dictados mie 07), Fischer tambien sab 10; PY AS/DF/MS mar 06 y DF/MS mie 07
               (dictados lun/mar). Bolivia real: cargo vie 02, descarga jue 08. Los del viernes 02 descargaron el MARTES 06
               (7 BR, 7.056 cajas; Cassio en frontera). Resultado: hasta el sab 10 descargan 15 camiones (15.006) y cierra en
               21.451, bajo el minimo; los 4 BR del jueves y los 2 PY del miercoles pasan al domingo 11 / martes 13 (semana
               del 17, que queda en 23.285 -> faltan 2). Regla de Gonzalo (06/10): "lunes no se descarga nada: la banana que
               se carga viernes y sabado cruza recien el lunes, se descarga a partir del martes". No cambia la semana de
               ninguna descarga (lunes y martes son la misma semana), solo el dia; a tener en cuenta al listar por dia.
               Aloha trae DOS camiones de Ivo cargados el vie 02 (1.008 cada uno, descargados mar 06): a confirmar.
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
