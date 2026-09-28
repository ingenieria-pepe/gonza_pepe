# Genera plan_compras\Plan_Compras_Simulado.xlsx (plan de compras simulado con formulas). Correr con pwsh 7 o PowerShell 5.1 con ImportExcel instalado.
# Se armo el 28/09/2026 a pedido de Gonzalo, entre dos sesiones de Claude. Ver plan_compras\LEEME.txt.
# Genera plan_compras\Plan_Compras_Simulado.xlsx: plan de compras con formulas (a medida de Almar + practica S&OP)
$ErrorActionPreference = 'Stop'
try { Import-Module ImportExcel -ErrorAction Stop } catch { Import-Module 'C:\Users\Usuario\Documents\WindowsPowerShell\Modules\ImportExcel' -ErrorAction Stop }   # EPPlus via ImportExcel
Add-Type -AssemblyName System.Drawing
$repo = Split-Path -Parent $PSScriptRoot   # el script vive en plan_compras\
$out  = "$repo\plan_compras\Plan_Compras_Simulado.xlsx"
$PCJ  = Get-Content "$repo\plan_compras\plan_compras.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$CEP  = Get-Content "$repo\fuentes\precios_cepea.json" -Raw -Encoding UTF8 | ConvertFrom-Json
if (Test-Path $out) { Remove-Item $out -Force }
$pkg = New-Object OfficeOpenXml.ExcelPackage

# ---------- estilos ----------
$AZUL  = [System.Drawing.Color]::FromArgb(255, 31, 56, 100)
$INP   = [System.Drawing.Color]::FromArgb(255, 255, 242, 204)   # amarillo claro = celda de entrada
$GRIS  = [System.Drawing.Color]::FromArgb(255, 242, 242, 242)
$VERDE = [System.Drawing.Color]::FromArgb(255, 226, 239, 218)
$ROJO  = [System.Drawing.Color]::FromArgb(255, 255, 199, 206)
$AMAR  = [System.Drawing.Color]::FromArgb(255, 255, 235, 156)
function Solid($cells, $color) { $cells.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid; $cells.Style.Fill.BackgroundColor.SetColor($color) }
function Hdr($ws, $r, $c1, $c2) { $rg = $ws.Cells[$r, $c1, $r, $c2]; Solid $rg $AZUL; $rg.Style.Font.Bold = $true; $rg.Style.Font.Color.SetColor([System.Drawing.Color]::White); $rg.Style.WrapText = $true; $rg.Style.VerticalAlignment = 'Center' }
function Titulo($ws, $texto, $sub) { $ws.Cells[1, 1].Value = $texto; $ws.Cells[1, 1].Style.Font.Size = 16; $ws.Cells[1, 1].Style.Font.Bold = $true; if ($sub) { $ws.Cells[2, 1].Value = $sub; $ws.Cells[2, 1].Style.Font.Italic = $true; $ws.Cells[2, 1].Style.Font.Color.SetColor([System.Drawing.Color]::DimGray) } }
function Inp($cells) { Solid $cells $INP }
function Fmt($cells, $f) { $cells.Style.Numberformat.Format = $f }
function CF($ws, $addr, $formula, $fill, $bold) { $cf = $ws.ConditionalFormatting.AddExpression((New-Object OfficeOpenXml.ExcelAddress($addr))); $cf.Formula = $formula; $cf.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid; $cf.Style.Fill.BackgroundColor.Color = $fill; if ($bold) { $cf.Style.Font.Bold = $true } }
function Lista($ws, $addr, $valores) { $dv = $ws.DataValidations.AddListValidation($addr); foreach ($v in $valores) { [void]$dv.Formula.Values.Add($v) }; $dv.ShowErrorMessage = $true; $dv.ErrorTitle = 'Valor no valido'; $dv.Error = 'Elegi un valor de la lista' }
function Nombre($n, $cells) { [void]$pkg.Workbook.Names.Add($n, $cells) }

# ---------- datos base ----------
$fCon = [DateTime]$PCJ.conteo.fecha
$lunesDe = { param($d) $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)) }
$W0 = 6; $NW = 13                                   # filas de semanas: 6..18 (misma fila en Demanda, Proyeccion, Escenarios, QueCargar)
$WL = $W0 + $NW - 1
$semanas = @(); $lun0 = & $lunesDe $fCon
for ($i = 0; $i -lt $NW; $i++) { $semanas += $lun0.AddDays(7 * $i) }
$plan = @($PCJ.ventas_plan | Sort-Object semana_lunes)
function PlanDe($lun) { $k = $lun.ToString('yyyy-MM-dd'); $f = $null; foreach ($p in $plan) { if ($p.semana_lunes -eq $k) { return $p }; if ($p.semana_lunes -lt $k) { $f = $p } }; if (-not $f) { $f = $plan[-1] }; return $f }

# =====================================================================
# 1) INICIO
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Inicio')
Titulo $ws 'PLAN DE COMPRAS SIMULADO - Almar S.R.L. (banana Brasil + Paraguay + Bolivia)' ("Generado el " + (Get-Date).ToString('dd/MM/yyyy HH:mm') + " a partir de plan_compras.json (conteo del " + $fCon.ToString('dd/MM/yyyy') + "). Planilla de trabajo: se edita a mano, no la pisa el script.")
$ini = @(
    @('PARA QUE SIRVE', ''),
    @('', 'Proyectar el stock de banana al cierre de cada sabado, saber cuantos camiones cargar y hasta que dia, y probar escenarios (venta distinta a comienzo/fin de mes, atraso en frontera, camiones de mas o de menos).'),
    @('', 'Sigue las reglas de Almar: el sabado cierra la semana; lo que descarga el lunes suma a la semana siguiente; Paraguay carga domingo-lunes-martes y entra en la semana; los pedidos a Paraguay cierran el miercoles y a Brasil el jueves; minimo 22.500 cajas al cierre del sabado (Bolivia incluida).'),
    @('', 'Y la practica de las multinacionales de fruta (S&OP semanal): un solo plan de demanda, proyeccion de inventario por semana con dias de cobertura, stock minimo explicito, recomendacion de pedido con fecha limite por lead time, escenarios, KPIs y tablero de proveedores.'),
    @('COMO SE USA', ''),
    @('1', 'Parametros: fecha del conteo, conteo por origen, minimo, lead times, cajas por camion, escenario. Las celdas AMARILLAS son las que se tocan; las blancas son formulas.'),
    @('2', 'Demanda: venta plan por semana (viene de la hoja ventas_plan), factor por semana del mes (1a, 2a, 3a, 4a/5a) y una columna "Venta manual" que pisa todo. Anota la venta real del ERP cuando cierre la semana: la planilla calcula el desvio.'),
    @('3', 'Cargas: una fila por camion (Aloha, dictado, supuesto). Para simular, agrega filas: fecha de carga, origen, productor, cajas. La descarga, la semana a la que suma y el costo salen solos.'),
    @('4', 'Proyeccion: stock al sabado semana por semana, total y por origen, dias de cobertura, camiones a cargar y fecha limite. Los faltantes se arrastran a la semana siguiente (como el simulador web).'),
    @('5', 'Que cargar: la recomendacion en limpio, con el origen que queda mas justo y el dia en que cierra el pedido.'),
    @('6', 'Escenarios: la misma proyeccion con venta -10% / base / +10% lado a lado. El atraso en frontera se prueba desde Parametros.'),
    @('7', 'KPIs: cobertura, semanas bajo minimo, camiones por semana, mix por origen, costo estimado, exactitud del pronostico, y una tabla de referencia de como lo miden las multinacionales.'),
    @('8', 'Proveedores: capacidad y comportamiento real de cada productor (camiones por semana, lead time real, transportista, dias de carga, precio 2026).'),
    @('9', 'Glosario: terminos y buenas practicas, con las fuentes consultadas.'),
    @('10', 'Calendario: la rutina S&OP de la semana (que se mira cada dia, quien decide, con que hoja). Semaforo: una pantalla con el estado por origen para esta semana, la proxima y la siguiente, mas los riesgos abiertos.'),
    @('11', 'Capacidad: cajas a madurar por semana contra lo que las camaras pueden madurar, y stock contra la capacidad fisica (hay que completar camaras y cajas en Parametros). MercadoPY: exportadores de Paraguay con volumen, como alternativas si falla un proveedor habitual.'),
    @('CONVENCION', 'Amarillo = entrada. Blanco = formula (no tocar). Rojo = falta / bajo minimo. Verde = ok. Las fechas van en dd/mm/aaaa.'),
    @('ORIGEN DE LOS DATOS', 'plan_compras.json (paso 5j de actualizar_precios.ps1): Plan de Cargas de Aloha, cargas dictadas por Gonzalo (plan_compras.xlsx), supuestos PY, ventas_plan, conteo por camara. Precios: precios_cepea.json (Cepea + cargas 2026).'),
    @('', 'Para refrescar los datos: volver a correr el script que arma esta planilla (plan_compras\generar_plan_xlsx.ps1) o pegar a mano las cargas nuevas en la hoja Cargas.'),
    @('QUIEN LA ARMO', 'Pedido de Gonzalo del 28/09/2026 ("una planilla de plan de compras simulado a medida de mis necesidades y de una empresa multinacional"). La armaron dos sesiones de Claude: una investigo la practica S&OP de las multinacionales de fruta y aporto lead times reales, proveedores, precios de aduana y el mercado exportador de Paraguay; la otra armo las hojas y las formulas sobre los datos del pipeline.')
)
$r = 4
foreach ($f in $ini) { $ws.Cells[$r, 1].Value = $f[0]; $ws.Cells[$r, 2].Value = $f[1]; if ($f[0] -and -not ($f[0] -match '^\d$')) { $ws.Cells[$r, 1].Style.Font.Bold = $true }; $ws.Cells[$r, 2].Style.WrapText = $true; $r++ }
$ws.Column(1).Width = 22; $ws.Column(2).Width = 120

# =====================================================================
# 2) PARAMETROS
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Parametros')
Titulo $ws 'Parametros' 'Celdas amarillas: se editan. Todo lo demas de la planilla depende de estas.'
$ws.Cells[3, 1].Value = 'Fecha del conteo por camara';                 $ws.Cells[3, 2].Value = $fCon; Fmt $ws.Cells[3, 2] 'dd/mm/yyyy'; Inp $ws.Cells[3, 2]; Nombre 'FechaConteo' $ws.Cells[3, 2]
$ws.Cells[3, 3].Value = 'El stock arranca de aca. Solo cuentan los camiones que descargan DESPUES de esta fecha.'
$ws.Cells[4, 1].Value = 'Hoy';                                         $ws.Cells[4, 2].Formula = 'TODAY()'; Fmt $ws.Cells[4, 2] 'dd/mm/yyyy'; Nombre 'Hoy' $ws.Cells[4, 2]
$ws.Cells[4, 3].Value = 'Se puede pisar con una fecha fija para revisar un plan viejo.'
$ws.Cells[5, 1].Value = 'Minimo al cierre del sabado (cajas)';          $ws.Cells[5, 2].Value = [int]$PCJ.minimos.TODO; Fmt $ws.Cells[5, 2] '#,##0'; Inp $ws.Cells[5, 2]; Nombre 'MinimoSabado' $ws.Cells[5, 2]
$ws.Cells[5, 3].Value = 'Gonzalo 27/09/2026: "de una semana a otra unas 22/23 mil cajas cerrando el sabado", Bolivia incluida. Equivale a ~7-8 dias de venta (fruta que todavia no maduro: gas + camara).'
$ws.Cells[6, 1].Value = 'Cobertura objetivo (dias de venta)';           $ws.Cells[6, 2].Value = 7; Inp $ws.Cells[6, 2]; Nombre 'CoberturaObjetivo' $ws.Cells[6, 2]
$ws.Cells[6, 3].Value = 'Referencia para pintar la cobertura: menos que esto = amarillo, menos de 2 = rojo.'
$ws.Cells[7, 1].Value = 'Dias de venta por semana';                     $ws.Cells[7, 2].Value = 6; Inp $ws.Cells[7, 2]; Nombre 'DiasVenta' $ws.Cells[7, 2]
$ws.Cells[7, 3].Value = 'Lunes a sabado.'
$ws.Cells[8, 1].Value = 'Escenario de venta';                           $ws.Cells[8, 2].Value = 'Base'; Inp $ws.Cells[8, 2]; Lista $ws 'B8' @('Base', 'Venta +10%', 'Venta -10%', 'Venta +20%', 'Venta -20%')
$ws.Cells[8, 3].Value = 'Multiplica la venta de todas las semanas (salvo las que tengan venta manual). La hoja Escenarios muestra -10% / base / +10% juntos.'
$ws.Cells[9, 1].Value = 'Factor de venta del escenario';                $ws.Cells[9, 2].Formula = 'IF(B8="Venta +10%",1.1,IF(B8="Venta -10%",0.9,IF(B8="Venta +20%",1.2,IF(B8="Venta -20%",0.8,1))))'; Fmt $ws.Cells[9, 2] '0.00'; Nombre 'FactorEscenario' $ws.Cells[9, 2]
$ws.Cells[10, 1].Value = 'Atraso extra en frontera (dias)';             $ws.Cells[10, 2].Value = 0; Inp $ws.Cells[10, 2]; Nombre 'AtrasoDias' $ws.Cells[10, 2]
$ws.Cells[10, 3].Value = 'Se suma al lead time de todos los camiones sin descarga real. Probar 1 o 2 para ver que pasa si la frontera se traba.'
$ws.Cells[11, 1].Value = 'Cajas por camion para los que FALTAN';        $ws.Cells[11, 2].Value = [int]$PCJ.cajas_camion.TODO; Fmt $ws.Cells[11, 2] '#,##0'; Inp $ws.Cells[11, 2]; Nombre 'CajasProm' $ws.Cells[11, 2]
$ws.Cells[11, 3].Value = 'Los camiones reales llevan sus cajas; este promedio se usa para calcular cuantos faltan.'
$ws.Cells[13, 1].Value = 'POR ORIGEN'; $ws.Cells[13, 2].Value = 'BR'; $ws.Cells[13, 3].Value = 'PY'; $ws.Cells[13, 4].Value = 'BO'; $ws.Cells[13, 5].Value = 'Nota'; Hdr $ws 13 1 5
$ws.Cells[14, 1].Value = 'Dias de carga a descarga (lead time)';        $ws.Cells[14, 2].Value = [int]$PCJ.lags.BR.descarga; $ws.Cells[14, 3].Value = [int]$PCJ.lags.PY.descarga; $ws.Cells[14, 4].Value = [int]$PCJ.lags.BO.descarga; Inp $ws.Cells[14, 2, 14, 4]
$ws.Cells[14, 5].Value = 'Regla de Gonzalo: lo que carga lunes a miercoles entra en la semana; viernes y sabado entra lunes o martes. Bolivia 6 dias. El lead time REAL por productor esta en Proveedores.'
Nombre 'LagBR' $ws.Cells[14, 2]; Nombre 'LagPY' $ws.Cells[14, 3]; Nombre 'LagBO' $ws.Cells[14, 4]; Nombre 'Lags' $ws.Cells[14, 2, 14, 4]; Nombre 'Origenes' $ws.Cells[13, 2, 13, 4]
$ws.Cells[15, 1].Value = 'Cajas por camion (tipico)';                   $ws.Cells[15, 2].Value = [int]$PCJ.cajas_camion.BR; $ws.Cells[15, 3].Value = [int]$PCJ.cajas_camion.PY; $ws.Cells[15, 4].Value = [int]$PCJ.cajas_camion.BO; Inp $ws.Cells[15, 2, 15, 4]; Fmt $ws.Cells[15, 2, 15, 4] '#,##0'
$ws.Cells[15, 5].Value = 'Se usa cuando una fila de Cargas no tiene cajas. 936 los chicos de AXT.'
Nombre 'CajasOrigen' $ws.Cells[15, 2, 15, 4]; Nombre 'CajasBR' $ws.Cells[15, 2]; Nombre 'CajasPY' $ws.Cells[15, 3]; Nombre 'CajasBO' $ws.Cells[15, 4]
$ws.Cells[16, 1].Value = 'Conteo por camara a la fecha del conteo';     $ws.Cells[16, 2].Value = [int]$PCJ.conteo.BR; $ws.Cells[16, 3].Value = [int]$PCJ.conteo.PY; $ws.Cells[16, 4].Value = [int]$PCJ.conteo.BO; Inp $ws.Cells[16, 2, 16, 4]; Fmt $ws.Cells[16, 2, 16, 5] '#,##0'
$ws.Cells[16, 5].Formula = 'SUM(B16:D16)'; $ws.Cells[16, 5].Style.Font.Bold = $true
Nombre 'ConteoBR' $ws.Cells[16, 2]; Nombre 'ConteoPY' $ws.Cells[16, 3]; Nombre 'ConteoBO' $ws.Cells[16, 4]; Nombre 'ConteoTotal' $ws.Cells[16, 5]
$ws.Cells[17, 1].Value = 'Cierre de pedidos (dia de la semana anterior)'; $ws.Cells[17, 2].Value = 'jueves'; $ws.Cells[17, 3].Value = 'miercoles'; $ws.Cells[17, 4].Value = 'segun disponibilidad'; Inp $ws.Cells[17, 2, 17, 4]
$ws.Cells[17, 5].Value = 'Gonzalo 27/09: "Brasil cierra los pedidos de la semana siguiente los jueves, Paraguay los miercoles". Por eso el numero tiene que estar el miercoles.'
$ws.Cells[18, 1].Value = 'Ultima carga en Aloha';                       $ws.Cells[18, 2].Value = $PCJ.plan_cargas.ultima_carga.BR; $ws.Cells[18, 3].Value = $PCJ.plan_cargas.ultima_carga.PY; $ws.Cells[18, 4].Value = $PCJ.plan_cargas_otros.ultima_carga_bo
$ws.Cells[18, 5].Value = "Export de Aloha: $($PCJ.plan_cargas.archivo) ($($PCJ.plan_cargas.fecha)). En el servidor se baja solo en cada corrida."
$ws.Cells[20, 1].Value = 'COSTOS DE REFERENCIA (para el KPI de costo)'; Hdr $ws 20 1 5
$ws.Cells[21, 1].Value = 'Cepea Nanica 1a SC (R$/kg)';                  $ws.Cells[21, 2].Value = [double]$CEP.ultimo_precio; Fmt $ws.Cells[21, 2] '0.00'; Inp $ws.Cells[21, 2]; Nombre 'CepeaKg' $ws.Cells[21, 2]; $ws.Cells[21, 3].Value = "semana $($CEP.ultima_semana)"
$ws.Cells[22, 1].Value = 'Kg netos por caja';                           $ws.Cells[22, 2].Value = [int]$CEP.almar.kg_caja_neto; Inp $ws.Cells[22, 2]; Nombre 'KgCaja' $ws.Cells[22, 2]
$ws.Cells[23, 1].Value = 'Servicios por caja Brasil (R$: envalado, paletizado, flete interno)'; $ws.Cells[23, 2].Value = [double]$CEP.almar.servicios_caja; Inp $ws.Cells[23, 2]; Nombre 'ServiciosCaja' $ws.Cells[23, 2]; $ws.Cells[23, 3].Value = 'Gonzalo 27/09: "estoy pagando 18 mas precio na roca". Solo Brasil.'
$ws.Cells[24, 1].Value = 'Caja equivalente Cepea (R$) = kg x 22 + servicios'; $ws.Cells[24, 2].Formula = 'CepeaKg*KgCaja+ServiciosCaja'; Fmt $ws.Cells[24, 2] '0.00'
$alSem = @($CEP.almar.semanas | Where-Object { [double]$_.cargas -gt 0 -and [double]$_.precio_avg_caja -gt 0 } | Select-Object -Last 4)
$alPond = [math]::Round((($alSem | ForEach-Object { [double]$_.precio_avg_caja * [double]$_.cargas } | Measure-Object -Sum).Sum) / (($alSem | Measure-Object cargas -Sum).Sum), 2)
$ws.Cells[25, 1].Value = 'Precio promedio pagado Almar Brasil (R$/caja, ponderado 4 semanas)'; $ws.Cells[25, 2].Value = $alPond; Fmt $ws.Cells[25, 2] '0.00'; Inp $ws.Cells[25, 2]; Nombre 'PrecioBR_BRL' $ws.Cells[25, 2]
$ws.Cells[25, 3].Value = "Gonzalo 28/09: 'Brasil tenes el promedio de la compra semanal que sale en el WhatsApp'. Semanas $(($alSem | ForEach-Object { (Get-Date $_.fecha).ToString('dd/MM') + ' R$ ' + $_.precio_avg_caja + ' (' + $_.cargas + ')' }) -join ' · '). Lo regenera el pipeline en precios_cepea.json > almar.semanas."
$ws.Cells[26, 1].Value = 'Tipo de cambio BRL por USD';                  $ws.Cells[26, 2].Value = 5.2; Fmt $ws.Cells[26, 2] '0.00'; Inp $ws.Cells[26, 2]; Nombre 'TC_BRL' $ws.Cells[26, 2]
$ws.Cells[27, 1].Value = 'Paraguay: precio por caja (PYG, Carape SIMA)'; $ws.Cells[27, 2].Value = 60000; Fmt $ws.Cells[27, 2] '#,##0'; Inp $ws.Cells[27, 2]; Nombre 'PYG_Caja' $ws.Cells[27, 2]; $ws.Cells[27, 3].Value = 'Referencia de mercado, no lo que paga Almar: cambiar por el precio real de compra si se conoce.'
$ws.Cells[28, 1].Value = 'Tipo de cambio PYG por USD';                  $ws.Cells[28, 2].Value = 7500; Fmt $ws.Cells[28, 2] '#,##0'; Inp $ws.Cells[28, 2]; Nombre 'TC_PYG' $ws.Cells[28, 2]
$ws.Cells[29, 1].Value = 'Bolivia: precio por caja (USD)';              $ws.Cells[29, 2].Value = 0; Fmt $ws.Cells[29, 2] '0.00'; Inp $ws.Cells[29, 2]; Nombre 'PrecioBO_USD' $ws.Cells[29, 2]; $ws.Cells[29, 3].Value = 'Sin dato: completar.'
$ws.Cells[30, 1].Value = 'COSTO POR CAJA EN USD (lo usan Cargas, KPIs y el valor del stock)'; $ws.Cells[30, 2].Value = 'BR'; $ws.Cells[30, 3].Value = 'PY'; $ws.Cells[30, 4].Value = 'BO'; $ws.Cells[30, 5].Value = 'Nota'; Hdr $ws 30 1 5
$ws.Cells[31, 1].Value = 'Referencia: valor declarado en aduana 2026 (VNA, USD/caja)'; $ws.Cells[31, 2].Value = 11.6; $ws.Cells[31, 3].Value = 11.5; $ws.Cells[31, 4].Value = 10.8; Fmt $ws.Cells[31, 2, 31, 4] '0.00'
$ws.Cells[31, 5].Value = 'Penta (aduana UY, ene-ago 2026), USD/kg neto x kg por caja: BR 0,527 x 22 · PY 0,522 x 22 · BO 0,539 x 20. Es CIF-aduana, no precio productor. 2025: 12,7 / 14,9 / 13,8.'
$ws.Cells[32, 1].Value = 'Precio de compra real (USD/caja; vacio = referencia)'; Inp $ws.Cells[32, 2, 32, 4]; Fmt $ws.Cells[32, 2, 32, 4] '0.00'
$ws.Cells[32, 2].Formula = 'ROUND(PrecioBR_BRL/TC_BRL,2)'; $ws.Cells[32, 3].Value = 7
$ws.Cells[32, 5].Formula = '"Gonzalo 28/09/2026: Paraguay USD 7 por caja; Brasil = promedio ponderado pagado ("&FIXED(PrecioBR_BRL,2)&" R$) / TC "&FIXED(TC_BRL,2)&" (sin los R$ "&ServiciosCaja&" de servicios: puesto en Uruguay serian "&FIXED((PrecioBR_BRL+ServiciosCaja)/TC_BRL,2)&" USD); Bolivia pendiente (queda la referencia de aduana). Carape "&FIXED(PYG_Caja/TC_PYG,2)&" USD es mercado local, no compra."'
$ws.Cells[33, 1].Value = 'USD/caja usado';                              $ws.Cells[33, 2].Formula = 'IF(B32<>"",B32,B31)'; $ws.Cells[33, 3].Formula = 'IF(C32<>"",C32,C31)'; $ws.Cells[33, 4].Formula = 'IF(D32<>"",D32,D31)'; Fmt $ws.Cells[33, 2, 33, 4] '0.00'; $ws.Cells[33, 2, 33, 4].Style.Font.Bold = $true
Nombre 'CostoOrigen' $ws.Cells[33, 2, 33, 4]; Nombre 'CostoBR' $ws.Cells[33, 2]; Nombre 'CostoPY' $ws.Cells[33, 3]; Nombre 'CostoBO' $ws.Cells[33, 4]
$ws.Cells[34, 1].Value = 'ESTACIONALIDAD DENTRO DEL MES (factor sobre la venta plan)'; Hdr $ws 34 1 3
$ws.Cells[35, 1].Value = 'Semana del mes'; $ws.Cells[35, 2].Value = 'Factor'; $ws.Cells[35, 3].Value = 'Nota'; $ws.Cells[35, 1, 35, 3].Style.Font.Bold = $true
$est = @(@(1, 1.00, '1a semana (arranque de mes: sueldos, mas venta)'), @(2, 1.00, '2a semana'), @(3, 1.00, '3a semana'), @(4, 1.00, '4a semana (fin de mes: menos venta)'), @(5, 1.00, '5a semana (cuando el mes tiene 5 lunes)'))
$r = 36; foreach ($e in $est) { $ws.Cells[$r, 1].Value = $e[0]; $ws.Cells[$r, 2].Value = $e[1]; Fmt $ws.Cells[$r, 2] '0.00'; Inp $ws.Cells[$r, 2]; $ws.Cells[$r, 3].Value = $e[2]; $r++ }
Nombre 'EstacTabla' $ws.Cells[36, 1, 40, 2]
$ws.Cells[41, 1].Value = 'Todos en 1,00 hasta que Gonzalo los ajuste con su experiencia (28/09/2026: "las ventas conforme a si es comienzo de mes o final de mes"). Ej: 1,05 / 1,00 / 0,98 / 0,95.'
# --- aportes de la otra sesion (28/09/2026): lead time real y riesgo, stock de seguridad adaptativo, capacidad de maduracion
$ws.Cells[43, 1].Value = 'LEAD TIME REAL Y RIESGO (Plan de Cargas Aloha 2024-2026)'; $ws.Cells[43, 2].Value = 'BR'; $ws.Cells[43, 3].Value = 'PY'; $ws.Cells[43, 4].Value = 'BO'; $ws.Cells[43, 5].Value = 'Nota'; Hdr $ws 43 1 5
$ws.Cells[44, 1].Value = 'TT mediana carga a descarga (dias)';        $ws.Cells[44, 2].Value = 3; $ws.Cells[44, 3].Value = 4; $ws.Cells[44, 4].Value = 6; Inp $ws.Cells[44, 2, 44, 4]
$ws.Cells[44, 5].Value = 'Mediana observada en Aloha. Para planificar se usa la regla de Gonzalo (fila 14); esta es la referencia real.'
$ws.Cells[45, 1].Value = 'TT P90: frontera lenta (dias)';              $ws.Cells[45, 2].Value = 6; $ws.Cells[45, 3].Value = 5; $ws.Cells[45, 4].Value = 8; Inp $ws.Cells[45, 2, 45, 4]; Nombre 'LagsP90' $ws.Cells[45, 2, 45, 4]
$ws.Cells[45, 5].Value = '9 de cada 10 camiones descargan antes de esto. Cargas usa esta fila para la "descarga pesimista" y Escenarios para "frontera a P90".'
$ws.Cells[46, 1].Value = 'Dias de maduracion (gas + camara) antes de vender'; $ws.Cells[46, 2].Value = 7; Inp $ws.Cells[46, 2]; Nombre 'DiasMadurar' $ws.Cells[46, 2]
$ws.Cells[46, 5].Value = 'Lead time total carga a venta: BR ~10 dias, PY ~11, BO ~13.'
$ws.Cells[47, 1].Value = 'Vida util maxima en verde (dias) = alerta de EXCESO'; $ws.Cells[47, 2].Value = 16; Inp $ws.Cells[47, 2]; Nombre 'VidaVerde' $ws.Cells[47, 2]
$ws.Cells[47, 5].Value = 'La banana verde aguanta ~2 semanas en camara a 13-14 C; mas cobertura que esto es merma, no seguridad (RELEX: el safety stock de perecederos tiene tope).'
$ws.Cells[48, 1].Value = 'Nivel de servicio objetivo';                  $ws.Cells[48, 2].Value = 0.95; Fmt $ws.Cells[48, 2] '0%'; Inp $ws.Cells[48, 2]
$ws.Cells[49, 1].Value = 'z (factor del nivel de servicio)';             $ws.Cells[49, 2].Formula = 'NORMSINV(B48)'; Fmt $ws.Cells[49, 2] '0.00'; Nombre 'Zserv' $ws.Cells[49, 2]
$ws.Cells[50, 1].Value = 'Desvio estandar de la venta semanal (cajas)'; $ws.Cells[50, 2].Value = [int][math]::Round(0.1 * [int](PlanDe $semanas[1]).TODO, 0); Fmt $ws.Cells[50, 2] '#,##0'; Inp $ws.Cells[50, 2]; Nombre 'SigmaVenta' $ws.Cells[50, 2]
$ws.Cells[50, 5].Value = 'SUPUESTO = 10% de la venta semanal. Reemplazar por el desvio real cuando haya 8 semanas de venta ERP en Demanda (columna "Venta real").'
$ws.Cells[51, 1].Value = 'Stock de seguridad sugerido (cajas)';         $ws.Cells[51, 2].Formula = 'ROUND(Zserv*SigmaVenta*SQRT((LagBR+DiasMadurar)/7+1),0)'; Fmt $ws.Cells[51, 2] '#,##0'; Nombre 'SSsugerido' $ws.Cells[51, 2]
$ws.Cells[51, 5].Value = 'z x sigma x raiz(lead time en semanas + 1 semana de revision). Cubre la variabilidad de la venta durante el tiempo en que no se puede reaccionar.'
$ws.Cells[52, 1].Value = 'Minimo sugerido = seguridad + dias de maduracion de venta'; $ws.Cells[52, 2].Formula = 'SSsugerido+ROUND(INDEX(DemVenta,MATCH(Hoy-WEEKDAY(Hoy,2)+1+7,DemSemana,0))/DiasVenta*DiasMadurar,0)'; Fmt $ws.Cells[52, 2] '#,##0'; Nombre 'MinSugerido' $ws.Cells[52, 2]
$ws.Cells[52, 5].Formula = '"Contra el minimo de Gonzalo ("&FIXED(MinimoSabado,0)&"): "&IF(MinSugerido>MinimoSabado,"la formula pide "&FIXED(MinSugerido-MinimoSabado,0)&" cajas mas","la formula pide "&FIXED(MinimoSabado-MinSugerido,0)&" cajas menos")&". El que manda en la planilla es el de la fila 5."'
$ws.Cells[54, 1].Value = 'CAPACIDAD DE MADURACION Y CAMARAS (completar: no lo tenemos)'; Hdr $ws 54 1 5
$ws.Cells[55, 1].Value = 'Camaras de gas (cantidad)';                   Inp $ws.Cells[55, 2]; $ws.Cells[55, 5].Value = 'Multinacionales: minimo 4 camaras para escalonar entrada, gaseo y despacho sin cuellos de botella.'
$ws.Cells[56, 1].Value = 'Cajas por camara';                            Inp $ws.Cells[56, 2]; Fmt $ws.Cells[56, 2] '#,##0'
$ws.Cells[57, 1].Value = 'Ciclo de maduracion (dias)';                  $ws.Cells[57, 2].Value = 5; Inp $ws.Cells[57, 2]; $ws.Cells[57, 5].Value = 'Ciclo de 4 a 6 dias; el de 5 es el mas usado, el de 6 da mejor sabor y vida (Produce News). Etileno 100-150 ppm las primeras 24 h.'
$ws.Cells[58, 1].Value = 'Cajas maximas a madurar por semana';          $ws.Cells[58, 2].Formula = 'IF(OR(B55="",B56=""),"",B55*B56/B57*7)'; Fmt $ws.Cells[58, 2] '#,##0'; Nombre 'CapMadurar' $ws.Cells[58, 2]
$ws.Cells[58, 5].Value = 'camaras x cajas / ciclo x 7. La hoja Capacidad compara la venta de cada semana contra esto.'
$ws.Cells[59, 1].Value = 'Capacidad fisica total en camaras (cajas)';   Inp $ws.Cells[59, 2]; Fmt $ws.Cells[59, 2] '#,##0'; Nombre 'CapFisica' $ws.Cells[59, 2]
$ws.Cells[59, 5].Value = 'ZAC + Coronel Raiz, banana. La hoja Capacidad muestra la ocupacion al sabado.'
$ws.Column(1).Width = 58; $ws.Column(2).Width = 14; $ws.Column(3).Width = 14; $ws.Column(4).Width = 18; $ws.Column(5).Width = 90

# =====================================================================
# 3) DEMANDA (una fila por semana, filas 6..18)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Demanda')
Titulo $ws 'Demanda: venta por semana (cajas)' 'Venta usada = venta manual si hay; si no, venta plan x factor de la semana del mes x factor del escenario. Mix por origen editable. Anota la venta real del ERP cuando cierre la semana.'
$hd = @('Semana (lunes)', 'Sabado (cierre)', 'Mes', 'Semana del mes', 'Venta plan (cajas)', 'Factor semana del mes', 'Venta manual (pisa todo)', 'VENTA USADA', 'Mix BR %', 'Mix PY %', 'Mix BO %', 'Venta BR', 'Venta PY', 'Venta BO', 'Venta real ERP (cajas)', 'Desvio real vs usada', 'Fuente / nota')
for ($c = 1; $c -le $hd.Count; $c++) { $ws.Cells[5, $c].Value = $hd[$c - 1] }; Hdr $ws 5 1 $hd.Count
for ($i = 0; $i -lt $NW; $i++) {
    $r = $W0 + $i; $lun = $semanas[$i]; $p = PlanDe $lun
    $ws.Cells[$r, 1].Value = $lun; Fmt $ws.Cells[$r, 1] 'dd/mm/yyyy'
    $ws.Cells[$r, 2].Formula = "A$r+5"; Fmt $ws.Cells[$r, 2] 'dd/mm/yyyy'
    $ws.Cells[$r, 3].Formula = "TEXT(A$r,`"mmm`")"
    $ws.Cells[$r, 4].Formula = "INT((DAY(A$r)-1)/7)+1"
    $ws.Cells[$r, 5].Value = [int]$p.TODO; Fmt $ws.Cells[$r, 5] '#,##0'; Inp $ws.Cells[$r, 5]
    $ws.Cells[$r, 6].Formula = "IFERROR(VLOOKUP(D$r,EstacTabla,2,FALSE),1)"; Fmt $ws.Cells[$r, 6] '0.00'
    Inp $ws.Cells[$r, 7]; Fmt $ws.Cells[$r, 7] '#,##0'
    $ws.Cells[$r, 8].Formula = "IF(G$r<>`"`",G$r,ROUND(E$r*F$r*FactorEscenario,0))"; Fmt $ws.Cells[$r, 8] '#,##0'; $ws.Cells[$r, 8].Style.Font.Bold = $true
    $tot = [double]$p.BR + [double]$p.PY + [double]$p.BO
    $ws.Cells[$r, 9].Value = [math]::Round([double]$p.BR / $tot, 3); $ws.Cells[$r, 10].Value = [math]::Round([double]$p.PY / $tot, 3); $ws.Cells[$r, 11].Formula = "1-I$r-J$r"
    Fmt $ws.Cells[$r, 9, $r, 11] '0.0%'; Inp $ws.Cells[$r, 9, $r, 10]
    $ws.Cells[$r, 12].Formula = "ROUND(H$r*I$r,0)"; $ws.Cells[$r, 13].Formula = "ROUND(H$r*J$r,0)"; $ws.Cells[$r, 14].Formula = "H$r-L$r-M$r"; Fmt $ws.Cells[$r, 12, $r, 14] '#,##0'
    Inp $ws.Cells[$r, 15]; Fmt $ws.Cells[$r, 15] '#,##0'
    $ws.Cells[$r, 16].Formula = "IF(O$r=`"`",`"`",O$r/H$r-1)"; Fmt $ws.Cells[$r, 16] '+0.0%;-0.0%'
    $ws.Cells[$r, 17].Value = $(if ($p.semana_lunes -eq $lun.ToString('yyyy-MM-dd')) { [string]$p.fuente } else { "sin fila en ventas_plan: copia de la semana del $(([DateTime]$p.semana_lunes).ToString('dd/MM')) (SUPUESTO)" })
}
CF $ws "P$W0`:P$WL" "ABS(P$W0)>0.1" $AMAR $false
$ws.View.FreezePanes(6, 2)
$anchos = @(14, 14, 7, 9, 12, 10, 14, 13, 9, 9, 9, 10, 10, 10, 13, 11, 70); for ($c = 1; $c -le $anchos.Count; $c++) { $ws.Column($c).Width = $anchos[$c - 1] }
Nombre 'DemSemana' $ws.Cells[$W0, 1, $WL, 1]; Nombre 'DemVenta' $ws.Cells[$W0, 8, $WL, 8]

# =====================================================================
# 4) CARGAS (una fila por camion)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Cargas')
Titulo $ws 'Cargas: un camion por fila' 'Amarillo = se carga a mano. Descarga = fecha real si la hay; si no, carga + lead time del origen + atraso del escenario. Solo suman los que descargan despues del conteo (Cuenta = 1). Para simular: agregar filas abajo con Estado = Simulado.'
$hc = @('N', 'Fecha carga', 'Dia', 'Origen', 'Productor', 'Transportista', 'Cajas (vacio = tipico)', 'Cajas usadas', 'Estado', 'Descarga real', 'Lead time (dias)', 'Fecha descarga', 'Semana de venta (lunes)', 'Cuenta', 'USD/caja', 'Costo USD', 'Nota', 'Descarga pesimista (P90)', 'Semana de venta P90', 'Pipeline (cargado, sin descargar)')
for ($c = 1; $c -le $hc.Count; $c++) { $ws.Cells[4, $c].Value = $hc[$c - 1] }; Hdr $ws 4 1 $hc.Count
$C0 = 5; $CL = 300
$cam = @()
foreach ($c in $PCJ.camiones) {
    $lag = 3; if ($PCJ.lags.($c.origen) -and $null -ne $PCJ.lags.($c.origen).descarga) { $lag = [int]$PCJ.lags.($c.origen).descarga }
    $desc = if ($c.descarga) { [DateTime]$c.descarga } else { ([DateTime]$c.carga).AddDays($lag) }
    if ($desc -le $fCon) { continue }
    $estado = switch ([string]$c.fuente) { 'plan_compras' { 'Dictado' } 'supuesto' { 'Supuesto' } default { 'Aloha' } }
    $cam += [PSCustomObject]@{ carga = [DateTime]$c.carga; origen = [string]$c.origen; prod = [string]$c.productor; transp = [string]$c.transportista; cajas = [int]$c.cajas; estado = $estado; descReal = $(if ($c.descarga) { [DateTime]$c.descarga } else { $null }); nota = [string]$c.nota; status = [string]$c.status }
}
$cam = @($cam | Sort-Object carga, origen, prod)
$r = $C0
foreach ($x in $cam) {
    $ws.Cells[$r, 2].Value = $x.carga; $ws.Cells[$r, 4].Value = $x.origen; $ws.Cells[$r, 5].Value = $x.prod; $ws.Cells[$r, 6].Value = $x.transp; $ws.Cells[$r, 7].Value = $x.cajas; $ws.Cells[$r, 9].Value = $x.estado
    if ($x.descReal) { $ws.Cells[$r, 10].Value = $x.descReal }
    $ws.Cells[$r, 17].Value = $(if ($x.nota) { $x.nota } elseif ($x.status) { "Aloha: $($x.status)" } else { '' })
    $r++
}
for ($r = $C0; $r -le $CL; $r++) {
    $ws.Cells[$r, 1].Formula = "IF(B$r=`"`",`"`",ROW()-$($C0 - 1))"
    Fmt $ws.Cells[$r, 2] 'dd/mm/yyyy'; Inp $ws.Cells[$r, 2]; Inp $ws.Cells[$r, 4, $r, 7]; Inp $ws.Cells[$r, 9, $r, 10]; Inp $ws.Cells[$r, 17]
    $ws.Cells[$r, 3].Formula = "IF(B$r=`"`",`"`",TEXT(B$r,`"ddd`"))"
    Fmt $ws.Cells[$r, 7] '#,##0'
    $ws.Cells[$r, 8].Formula = "IF(B$r=`"`",`"`",IF(G$r<>`"`",G$r,IFERROR(INDEX(CajasOrigen,MATCH(D$r,Origenes,0)),CajasProm)))"; Fmt $ws.Cells[$r, 8] '#,##0'
    Fmt $ws.Cells[$r, 10] 'dd/mm/yyyy'
    $ws.Cells[$r, 11].Formula = "IF(B$r=`"`",`"`",IFERROR(INDEX(Lags,MATCH(D$r,Origenes,0)),LagBR)+IF(J$r<>`"`",0,AtrasoDias))"
    $ws.Cells[$r, 12].Formula = "IF(B$r=`"`",`"`",IF(J$r<>`"`",J$r,B$r+K$r))"; Fmt $ws.Cells[$r, 12] 'dd/mm/yyyy'
    $ws.Cells[$r, 13].Formula = "IF(L$r=`"`",`"`",L$r-WEEKDAY(L$r,2)+1)"; Fmt $ws.Cells[$r, 13] 'dd/mm/yyyy'
    $ws.Cells[$r, 14].Formula = "IF(L$r=`"`",`"`",IF(L$r>FechaConteo,1,0))"
    $ws.Cells[$r, 15].Formula = "IF(D$r=`"`",`"`",IFERROR(INDEX(CostoOrigen,MATCH(D$r,Origenes,0)),0))"; Fmt $ws.Cells[$r, 15] '0.00'
    $ws.Cells[$r, 16].Formula = "IF(H$r=`"`",`"`",H$r*O$r)"; Fmt $ws.Cells[$r, 16] '#,##0'
    $ws.Cells[$r, 18].Formula = "IF(B$r=`"`",`"`",IF(J$r<>`"`",J$r,B$r+IFERROR(INDEX(LagsP90,MATCH(D$r,Origenes,0)),K$r)))"; Fmt $ws.Cells[$r, 18] 'dd/mm/yyyy'
    $ws.Cells[$r, 19].Formula = "IF(R$r=`"`",`"`",R$r-WEEKDAY(R$r,2)+1)"; Fmt $ws.Cells[$r, 19] 'dd/mm/yyyy'
    $ws.Cells[$r, 20].Formula = "IF(B$r=`"`",`"`",IF(AND(B$r<=Hoy,J$r=`"`",I$r<>`"Supuesto`",I$r<>`"Simulado`"),H$r,0))"; Fmt $ws.Cells[$r, 20] '#,##0'
}
Lista $ws "D$C0`:D$CL" @('BR', 'PY', 'BO')
Lista $ws "I$C0`:I$CL" @('Aloha', 'Dictado', 'Supuesto', 'Simulado')
CF $ws "A$C0`:Q$CL" "`$I$C0=`"Supuesto`"" $GRIS $false
CF $ws "A$C0`:Q$CL" "`$I$C0=`"Simulado`"" $AMAR $false
CF $ws "N$C0`:N$CL" "N$C0=0" $ROJO $false
$ws.View.FreezePanes(5, 3)
$anchos = @(5, 12, 6, 8, 22, 22, 12, 11, 10, 12, 10, 13, 14, 8, 9, 11, 60, 13, 13, 12); for ($c = 1; $c -le $anchos.Count; $c++) { $ws.Column($c).Width = $anchos[$c - 1] }
Nombre 'CgOrigen' $ws.Cells[$C0, 4, $CL, 4]; Nombre 'CgProductor' $ws.Cells[$C0, 5, $CL, 5]; Nombre 'CgCajas' $ws.Cells[$C0, 8, $CL, 8]; Nombre 'CgEstado' $ws.Cells[$C0, 9, $CL, 9]
Nombre 'CgSemana' $ws.Cells[$C0, 13, $CL, 13]; Nombre 'CgCuenta' $ws.Cells[$C0, 14, $CL, 14]; Nombre 'CgCosto' $ws.Cells[$C0, 16, $CL, 16]
Nombre 'CgSemanaP90' $ws.Cells[$C0, 19, $CL, 19]; Nombre 'CgPipeline' $ws.Cells[$C0, 20, $CL, 20]; Nombre 'CgCarga' $ws.Cells[$C0, 2, $CL, 2]
$nCam = $cam.Count

# =====================================================================
# 5) PROYECCION
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Proyeccion')
Titulo $ws 'Proyeccion de stock al cierre de cada sabado' 'Stock final = stock inicial + cajas que descargan en la semana - venta. Los camiones a cargar se arrastran: "Stock proyectado" ya incluye los pedidos de las semanas anteriores. La primera semana (la del conteo) va prorrateada por los dias que quedan.'
$hp = @('Semana (lunes)', 'Sabado', 'Stock inicial', 'Camiones que descargan', 'Cajas que descargan', 'Venta', 'Stock final (sin pedidos)', 'Pedidos anteriores (cajas)', 'STOCK PROYECTADO', 'Fecha limite de carga', 'CAMIONES A CARGAR', 'Stock con pedido', 'Dias de cobertura', 'Estado', 'BR stock', 'BR dias', 'PY stock', 'PY dias', 'BO stock', 'BO dias', 'Origen mas justo')
for ($c = 1; $c -le $hp.Count; $c++) { $ws.Cells[5, $c].Value = $hp[$c - 1] }; Hdr $ws 5 1 $hp.Count
for ($i = 0; $i -lt $NW; $i++) {
    $r = $W0 + $i; $first = ($i -eq 0); $rn = $r + 1; if ($i -eq $NW - 1) { $rn = $r }
    $ws.Cells[$r, 1].Formula = "Demanda!A$r"; Fmt $ws.Cells[$r, 1] 'dd/mm/yyyy'
    $ws.Cells[$r, 2].Formula = "A$r+5"; Fmt $ws.Cells[$r, 2] 'dd/mm/yyyy'
    $ws.Cells[$r, 3].Formula = $(if ($first) { 'ConteoTotal' } else { "G$($r - 1)" })
    $ws.Cells[$r, 4].Formula = "COUNTIFS(CgSemana,A$r,CgCuenta,1)"
    $ws.Cells[$r, 5].Formula = "SUMIFS(CgCajas,CgSemana,A$r,CgCuenta,1)"
    $pro = $(if ($first) { "*MAX(0,MIN(DiasVenta,B$r-FechaConteo))/DiasVenta" } else { '' })
    $ws.Cells[$r, 6].Formula = "ROUND(Demanda!H$r$pro,0)"
    $ws.Cells[$r, 7].Formula = "C$r+E$r-F$r"
    $ws.Cells[$r, 8].Formula = $(if ($first) { '0' } else { "SUM(`$K`$$W0`:K$($r - 1))*CajasProm" })
    $ws.Cells[$r, 9].Formula = "G$r+H$r"; $ws.Cells[$r, 9].Style.Font.Bold = $true
    $ws.Cells[$r, 10].Formula = "B$r-LagBR-AtrasoDias"; Fmt $ws.Cells[$r, 10] 'ddd dd/mm'
    $ws.Cells[$r, 11].Formula = "IF(AND(I$r<MinimoSabado,J$r>=Hoy),ROUNDUP((MinimoSabado-I$r)/CajasProm,0),0)"; $ws.Cells[$r, 11].Style.Font.Bold = $true
    $ws.Cells[$r, 12].Formula = "I$r+K$r*CajasProm"
    $ws.Cells[$r, 13].Formula = "IF(Demanda!H$rn=0,`"`",L$r/(Demanda!H$rn/DiasVenta))"; Fmt $ws.Cells[$r, 13] '0.0'
    # estado de 4 niveles (aporte de la otra sesion): FALTA / CARGAR N (bajo minimo con limite abierto) / BAJO MINIMO (limite pasado) / EXCESO (mas dias que la vida util en verde) / OK
    $ws.Cells[$r, 14].Formula = "IF(I$r<0,`"FALTA`",IF(K$r>0,`"CARGAR `"&K$r,IF(I$r<MinimoSabado,`"BAJO MINIMO (limite pasado)`",IF(AND(M$r<>`"`",M$r>VidaVerde),`"EXCESO (merma)`",`"OK`"))))"
    # por origen (sin los camiones que faltan: esos todavia no tienen origen)
    $col = 15
    foreach ($o in 'BR', 'PY', 'BO') {
        $c1 = $col; $c2 = $col + 1; $L1 = [string][char](64 + $c1)
        $ini = $(if ($first) { "Conteo$o" } else { "$L1$($r - 1)" })
        $dem = @{ BR = 'L'; PY = 'M'; BO = 'N' }[$o]
        $ws.Cells[$r, $c1].Formula = "$ini+SUMIFS(CgCajas,CgSemana,A$r,CgCuenta,1,CgOrigen,`"$o`")-ROUND(Demanda!$dem$r$pro,0)"
        $ws.Cells[$r, $c2].Formula = "IF(Demanda!$dem$rn=0,`"`",$L1$r/(Demanda!$dem$rn/DiasVenta))"; Fmt $ws.Cells[$r, $c2] '0.0'
        $col = $col + 2
    }
    $ws.Cells[$r, 21].Formula = "IF(P$r=MIN(P$r,R$r,T$r),`"Brasil`",IF(R$r=MIN(P$r,R$r,T$r),`"Paraguay`",`"Bolivia`"))"
    Fmt $ws.Cells[$r, 3, $r, 9] '#,##0'; Fmt $ws.Cells[$r, 12] '#,##0'; Fmt $ws.Cells[$r, 15] '#,##0'; Fmt $ws.Cells[$r, 17] '#,##0'; Fmt $ws.Cells[$r, 19] '#,##0'
}
CF $ws "N$W0`:N$WL" "LEFT(N$W0,5)=`"FALTA`"" $ROJO $true
CF $ws "N$W0`:N$WL" "LEFT(N$W0,4)=`"BAJO`"" $ROJO $true
CF $ws "N$W0`:N$WL" "LEFT(N$W0,6)=`"CARGAR`"" $AMAR $true
CF $ws "N$W0`:N$WL" "LEFT(N$W0,6)=`"EXCESO`"" ([System.Drawing.Color]::FromArgb(255, 252, 228, 214)) $true
CF $ws "N$W0`:N$WL" "N$W0=`"OK`"" $VERDE $false
CF $ws "K$W0`:K$WL" "K$W0>0" $ROJO $true
CF $ws "M$W0`:M$WL" "AND(M$W0<>`"`",M$W0<2)" $ROJO $false
CF $ws "M$W0`:M$WL" "AND(M$W0<>`"`",M$W0>=2,M$W0<CoberturaObjetivo)" $AMAR $false
foreach ($cc in 'P', 'R', 'T') { CF $ws "$cc$W0`:$cc$WL" "AND($cc$W0<>`"`",$cc$W0<2)" $ROJO $false; CF $ws "$cc$W0`:$cc$WL" "AND($cc$W0<>`"`",$cc$W0>=2,$cc$W0<CoberturaObjetivo)" $AMAR $false }
CF $ws "A$W0`:U$WL" "AND(`$A$W0<=Hoy,`$B$W0>=Hoy)" ([System.Drawing.Color]::FromArgb(255, 255, 251, 235)) $false
$ws.View.FreezePanes(6, 3)
$anchos = @(12, 11, 11, 10, 11, 10, 12, 12, 13, 12, 11, 12, 10, 22, 10, 7, 10, 7, 10, 7, 12); for ($c = 1; $c -le $anchos.Count; $c++) { $ws.Column($c).Width = $anchos[$c - 1] }
Nombre 'PrSemana' $ws.Cells[$W0, 1, $WL, 1]; Nombre 'PrCamiones' $ws.Cells[$W0, 4, $WL, 4]; Nombre 'PrACargar' $ws.Cells[$W0, 11, $WL, 11]; Nombre 'PrCobertura' $ws.Cells[$W0, 13, $WL, 13]; Nombre 'PrEstado' $ws.Cells[$W0, 14, $WL, 14]; Nombre 'PrStock' $ws.Cells[$W0, 12, $WL, 12]
Nombre 'PrProy' $ws.Cells[$W0, 9, $WL, 9]; Nombre 'PrLimite' $ws.Cells[$W0, 10, $WL, 10]; Nombre 'PrSab' $ws.Cells[$W0, 2, $WL, 2]; Nombre 'PrVenta' $ws.Cells[$W0, 6, $WL, 6]
Nombre 'PrBR' $ws.Cells[$W0, 15, $WL, 15]; Nombre 'PrBRd' $ws.Cells[$W0, 16, $WL, 16]; Nombre 'PrPY' $ws.Cells[$W0, 17, $WL, 17]; Nombre 'PrPYd' $ws.Cells[$W0, 18, $WL, 18]; Nombre 'PrBO' $ws.Cells[$W0, 19, $WL, 19]; Nombre 'PrBOd' $ws.Cells[$W0, 20, $WL, 20]

# =====================================================================
# 6) QUE CARGAR (recomendacion en limpio)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('QueCargar')
Titulo $ws 'Que cargar' 'Solo las semanas cuyo limite de carga todavia no paso. Camiones ADEMAS de lo dictado y de los supuestos. El origen sugerido es el que queda con menos dias de venta al cierre (Proyeccion).'
$hq = @('Sabado de cierre', 'Stock proyectado (con pedidos anteriores)', 'Camiones a cargar', 'Cargar hasta', 'Origen sugerido', 'Pedido cierra (PY mie / BR jue)', 'Cobertura al cierre (dias)', 'Estado', 'Renglon para WhatsApp')
for ($c = 1; $c -le $hq.Count; $c++) { $ws.Cells[5, $c].Value = $hq[$c - 1] }; Hdr $ws 5 1 $hq.Count
for ($i = 0; $i -lt $NW; $i++) {
    $r = $W0 + $i
    $ws.Cells[$r, 1].Formula = "IF(Proyeccion!J$r<Hoy,`"`",Proyeccion!B$r)"; Fmt $ws.Cells[$r, 1] 'ddd dd/mm/yyyy'
    $ws.Cells[$r, 2].Formula = "IF(A$r=`"`",`"`",Proyeccion!I$r)"; Fmt $ws.Cells[$r, 2] '#,##0'
    $ws.Cells[$r, 3].Formula = "IF(A$r=`"`",`"`",Proyeccion!K$r)"; $ws.Cells[$r, 3].Style.Font.Bold = $true
    $ws.Cells[$r, 4].Formula = "IF(A$r=`"`",`"`",Proyeccion!J$r)"; Fmt $ws.Cells[$r, 4] 'ddd dd/mm'
    $ws.Cells[$r, 5].Formula = "IF(A$r=`"`",`"`",IF(C$r>0,Proyeccion!U$r,`"-`"))"
    $ws.Cells[$r, 6].Formula = "IF(A$r=`"`",`"`",`"PY mie `"&TEXT(Proyeccion!A$r-5,`"dd/mm`")&`" / BR jue `"&TEXT(Proyeccion!A$r-4,`"dd/mm`"))"
    $ws.Cells[$r, 7].Formula = "IF(A$r=`"`",`"`",Proyeccion!M$r)"; Fmt $ws.Cells[$r, 7] '0.0'
    $ws.Cells[$r, 8].Formula = "IF(A$r=`"`",`"`",Proyeccion!N$r)"
    $ws.Cells[$r, 9].Formula = "IF(A$r=`"`",`"`",`"Sab `"&TEXT(A$r,`"dd/mm`")&`": `"&FIXED(B$r,0)&`" cajas - descargan `"&Proyeccion!D$r&`" - vende `"&FIXED(Proyeccion!F$r,0)&IF(C$r>0,`" -> cargar `"&C$r&`" mas hasta el `"&TEXT(D$r,`"dd/mm`")&`" (`"&E$r&`")`",`" -> ok`"))"
}
CF $ws "H$W0`:H$WL" "LEFT(H$W0,5)=`"FALTA`"" $ROJO $true
CF $ws "H$W0`:H$WL" "LEFT(H$W0,4)=`"BAJO`"" $AMAR $true
CF $ws "H$W0`:H$WL" "H$W0=`"OK`"" $VERDE $false
CF $ws "C$W0`:C$WL" "AND(C$W0<>`"`",C$W0>0)" $ROJO $true
$anchos = @(16, 18, 11, 12, 13, 26, 12, 22, 110); for ($c = 1; $c -le $anchos.Count; $c++) { $ws.Column($c).Width = $anchos[$c - 1] }
$ws.Cells[($WL + 2), 1].Value = 'Como leerlo: "cargar N mas hasta el mie" = camiones que hay que agregar a lo ya dictado para cerrar ese sabado en el minimo; lo que cargue despues del limite descarga la semana siguiente. Los faltantes de una semana se arrastran a la siguiente (Proyeccion, columna "Pedidos anteriores").'
$ws.Cells[($WL + 3), 1].Value = 'Los 5 camiones de Paraguay por semana son SUPUESTOS (hoja Cargas, Estado = Supuesto): cuando se dictan los reales, reemplazarlos.'

# =====================================================================
# 7) ESCENARIOS (venta -10% / base / +10%, cadena propia cada uno)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Escenarios')
Titulo $ws 'Escenarios de venta lado a lado' 'Misma proyeccion con la venta usada x 0,9 / x 1,0 / x 1,1 (ademas del escenario elegido en Parametros). Cada escenario arrastra sus propios camiones a cargar. Para atraso en frontera: Parametros > Atraso extra.'
$he = @('Semana (lunes)', 'Sabado', 'Cajas que descargan', 'Venta base', 'Stock -10%', 'A cargar -10%', 'Stock base', 'A cargar base', 'Stock +10%', 'A cargar +10%', 'Cajas si frontera a P90', 'Stock frontera P90', 'A cargar P90', 'Stock sin HF 1 semana (-2 PY)', 'Stock 1 camion rechazado (-1.000)', 'Stock sin Bolivia 2 sem')
for ($c = 1; $c -le $he.Count; $c++) { $ws.Cells[5, $c].Value = $he[$c - 1] }; Hdr $ws 5 1 $he.Count
$facts = @(@(0.9, 5), @(1.0, 7), @(1.1, 9))
for ($i = 0; $i -lt $NW; $i++) {
    $r = $W0 + $i; $first = ($i -eq 0)
    $ws.Cells[$r, 1].Formula = "Proyeccion!A$r"; Fmt $ws.Cells[$r, 1] 'dd/mm/yyyy'
    $ws.Cells[$r, 2].Formula = "Proyeccion!B$r"; Fmt $ws.Cells[$r, 2] 'dd/mm/yyyy'
    $ws.Cells[$r, 3].Formula = "Proyeccion!E$r"; Fmt $ws.Cells[$r, 3] '#,##0'
    $ws.Cells[$r, 4].Formula = "Proyeccion!F$r"; Fmt $ws.Cells[$r, 4] '#,##0'
    foreach ($f in $facts) {
        $k = $f[0]; $cs = $f[1]; $ca = $cs + 1; $L = [char](64 + $cs); $LA = [char](64 + $ca)
        # stock proyectado del escenario = stock anterior (con pedido) + descargas - venta*k ; pedidos anteriores ya estan dentro del "stock con pedido" de la fila previa
        $prev = $(if ($first) { 'ConteoTotal' } else { "($L$($r - 1)+$LA$($r - 1)*CajasProm)" })
        $ws.Cells[$r, $cs].Formula = "$prev+C$r-ROUND(D$r*$k,0)"; Fmt $ws.Cells[$r, $cs] '#,##0'
        $ws.Cells[$r, $ca].Formula = "IF(AND($L$r<MinimoSabado,Proyeccion!J$r>=Hoy),ROUNDUP((MinimoSabado-$L$r)/CajasProm,0),0)"
        CF $ws "$L$W0`:$L$WL" "$L$W0<MinimoSabado" $AMAR $false
        CF $ws "$L$W0`:$L$WL" "$L$W0<0" $ROJO $true
        CF $ws "$LA$W0`:$LA$WL" "$LA$W0>0" $ROJO $true
    }
    # frontera a P90: los camiones descargan segun la semana pesimista (Cargas col S); misma cadena con arrastre
    $ws.Cells[$r, 11].Formula = "SUMIFS(CgCajas,CgSemanaP90,A$r,CgCuenta,1)"; Fmt $ws.Cells[$r, 11] '#,##0'
    $prevP = $(if ($first) { 'ConteoTotal' } else { "(L$($r - 1)+M$($r - 1)*CajasProm)" })
    $ws.Cells[$r, 12].Formula = "$prevP+K$r-D$r"; Fmt $ws.Cells[$r, 12] '#,##0'
    $ws.Cells[$r, 13].Formula = "IF(AND(L$r<MinimoSabado,Proyeccion!J$r>=Hoy),ROUNDUP((MinimoSabado-L$r)/CajasProm,0),0)"
    # shocks puntuales desde la semana proxima (el stock se arrastra, por eso el impacto queda): sin HF una semana = -2 camiones PY; camion rechazado = -1.000; Bolivia sin cargas 2 semanas = lo que tenga BO esas semanas
    $ws.Cells[$r, 14].Formula = "G$r-IF(A$r>=Hoy-WEEKDAY(Hoy,2)+8,2*CajasPY,0)"; Fmt $ws.Cells[$r, 14] '#,##0'
    $ws.Cells[$r, 15].Formula = "G$r-IF(A$r>=Hoy-WEEKDAY(Hoy,2)+8,1000,0)"; Fmt $ws.Cells[$r, 15] '#,##0'
    $ws.Cells[$r, 16].Formula = "G$r-SUMIFS(CgCajas,CgOrigen,`"BO`",CgCuenta,1,CgSemana,`">=`"&(Hoy-WEEKDAY(Hoy,2)+8),CgSemana,`"<=`"&MIN(A$r,Hoy-WEEKDAY(Hoy,2)+15))"; Fmt $ws.Cells[$r, 16] '#,##0'
}
foreach ($cc in 'L', 'N', 'O', 'P') { CF $ws "$cc$W0`:$cc$WL" "$cc$W0<MinimoSabado" $AMAR $false; CF $ws "$cc$W0`:$cc$WL" "$cc$W0<0" $ROJO $true }
CF $ws "M$W0`:M$WL" "M$W0>0" $ROJO $true
$ws.Cells[($WL + 2), 1].Value = 'Lectura: si con -10% igual hay que cargar, el pedido es firme; si solo hace falta con +10%, es un pedido "por las dudas" que conviene decidir el miercoles con la venta real de la semana. "Frontera a P90": todos los camiones sin descarga real tardan lo que tarda el peor 10% (Parametros fila 45). Los shocks (sin HF, camion rechazado, sin Bolivia) se aplican desde la semana proxima sobre el stock base.'
$anchos = @(13, 11, 12, 11, 12, 11, 12, 11, 12, 11, 12, 12, 11, 14, 14, 14); for ($c = 1; $c -le $anchos.Count; $c++) { $ws.Column($c).Width = $anchos[$c - 1] }
$ws.View.FreezePanes(6, 3)

# =====================================================================
# 8) KPIs
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('KPIs')
Titulo $ws 'KPIs del plan' 'Los de arriba salen de la planilla. Abajo, la referencia de como lo miden las multinacionales de fruta y que equivale en Almar.'
$ws.Cells[4, 1].Value = 'Indicador'; $ws.Cells[4, 2].Value = 'Valor'; $ws.Cells[4, 3].Value = 'Como se calcula / lectura'; Hdr $ws 4 1 3
$semHoy = 'Hoy-WEEKDAY(Hoy,2)+1'
$kp = @(
    @('Stock al conteo (cajas)', 'ConteoTotal', '#,##0', 'Parametros: conteo por camara, BR + PY + BO. Ecuador no entra (va por otro canal).'),
    @('Dias de cobertura al conteo', "ConteoTotal/(INDEX(DemVenta,MATCH(FechaConteo-WEEKDAY(FechaConteo,2)+1+7,DemSemana,0))/DiasVenta)", '0.0', 'Stock / venta diaria de la semana siguiente al conteo. Multinacionales: "days on hand" o DOS.'),
    @('Semana actual: stock proyectado al sabado', "IFERROR(INDEX(PrStock,MATCH($semHoy,PrSemana,0)),`"`")", '#,##0', 'Proyeccion, fila de la semana de hoy, con los pedidos ya contados.'),
    @('Semana actual: camiones a cargar', "IFERROR(INDEX(PrACargar,MATCH($semHoy,PrSemana,0)),`"`")", '0', 'Lo que falta cargar antes del limite de esta semana.'),
    @('Semana proxima: camiones a cargar', "IFERROR(INDEX(PrACargar,MATCH($semHoy+7,PrSemana,0)),`"`")", '0', 'El numero que hay que tener el miercoles (PY) y el jueves (BR).'),
    @('Cobertura promedio proximas 4 semanas (dias)', "AVERAGEIFS(PrCobertura,PrSemana,`">=`"&($semHoy),PrSemana,`"<`"&($semHoy+28))", '0.0', 'Promedio de "Dias de cobertura" de Proyeccion. Objetivo: Parametros > cobertura objetivo.'),
    @('Semanas que piden cargar (prox. 4 sem)', "COUNTIFS(PrACargar,`">0`",PrSemana,`">=`"&($semHoy),PrSemana,`"<`"&($semHoy+28))", '0', 'Semanas de las proximas 4 que cierran abajo del minimo sin camiones extra. Mas alla de 2-3 semanas es normal que pidan, porque todavia no hay cargas dictadas.'),
    @('Camiones a cargar prox. 4 sem (ademas de lo dictado)', "SUMIFS(PrACargar,PrSemana,`">=`"&($semHoy),PrSemana,`"<`"&($semHoy+28))", '0', 'Suma de "Camiones a cargar" de Proyeccion en las proximas 4 semanas.'),
    @('Rotacion: semanas de stock al conteo', "ConteoTotal/INDEX(DemVenta,MATCH(FechaConteo-WEEKDAY(FechaConteo,2)+1+7,DemSemana,0))", '0.0', 'Stock / venta semanal. Referencia en fresco: 1 a 2 semanas de stock (26-52 vueltas al ano). Almar al 26/09: 1,6 semanas, dentro del rango pero en el borde alto.'),
    @('Valor del stock al conteo (USD)', 'ConteoBR*CostoBR+ConteoPY*CostoPY+ConteoBO*CostoBO', '#,##0', 'Cajas por origen x USD/caja usado (Parametros). Capital de trabajo inmovilizado en camara.'),
    @('Verde en transito (cajas cargadas y no descargadas, Aloha)', 'SUM(CgPipeline)', '#,##0', 'Pipeline: camiones ya cargados que todavia no descargaron (Cargas, columna "Pipeline"). Con el export de Aloha al dia es lo que viene en camino.'),
    @('Brasil: precio pagado vs Cepea + servicios (R$/caja)', 'PrecioBR_BRL-(CepeaKg*KgCaja+ServiciosCaja)', '+0.00;-0.00', 'Negativo = Almar paga por debajo de la referencia Cepea x 22 kg + R$ 18 de servicios.'),
    @('Concentracion Paraguay: % camiones del mayor productor (8 sem)', "IFERROR(SUMPRODUCT(MAX((Proveedores!A5:A60=`"PY`")*Proveedores!D5:D60))/SUMIF(Proveedores!A5:A60,`"PY`",Proveedores!D5:D60),`"`")", '0%', 'Riesgo de dependencia: HF sola fue el 54% de los camiones PY de 2026. Multinacionales: 20-30% del programa en proveedores de contingencia precalificados (hoja MercadoPY).'),
    @('Concentracion Brasil: % camiones del mayor productor (8 sem)', "IFERROR(SUMPRODUCT(MAX((Proveedores!A5:A60=`"BR`")*Proveedores!D5:D60))/SUMIF(Proveedores!A5:A60,`"BR`",Proveedores!D5:D60),`"`")", '0%', ''),
    @('Camiones que descargan por semana, prox. 4 sem (promedio)', "AVERAGEIFS(PrCamiones,PrSemana,`">=`"&($semHoy),PrSemana,`"<`"&($semHoy+28))", '0.0', 'Aloha + dictados + supuestos.'),
    @('Mix descargas prox. 4 sem: Brasil', "IFERROR(SUMIFS(CgCajas,CgOrigen,`"BR`",CgCuenta,1,CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+28))/SUMIFS(CgCajas,CgCuenta,1,CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+28)),0)", '0%', 'Cajas por origen sobre el total de las proximas 4 semanas. Diversificacion de origen = menos riesgo (frontera, clima, TR4).'),
    @('Mix descargas prox. 4 sem: Paraguay', "IFERROR(SUMIFS(CgCajas,CgOrigen,`"PY`",CgCuenta,1,CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+28))/SUMIFS(CgCajas,CgCuenta,1,CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+28)),0)", '0%', ''),
    @('Mix descargas prox. 4 sem: Bolivia', "IFERROR(SUMIFS(CgCajas,CgOrigen,`"BO`",CgCuenta,1,CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+28))/SUMIFS(CgCajas,CgCuenta,1,CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+28)),0)", '0%', ''),
    @('Costo estimado de compra prox. 4 sem (USD)', "SUMIFS(CgCosto,CgCuenta,1,CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+28))", '#,##0', 'Cajas que descargan x USD/caja usado (Parametros: precio de compra real si esta cargado, si no la referencia de aduana 2026).'),
    @('Camiones supuestos en el horizonte', "COUNTIFS(CgEstado,`"Supuesto`",CgCuenta,1)", '0', 'Cuantos de los camiones contados todavia son supuestos (5 PY por semana). Cuanto mas bajo, mas firme el plan.'),
    @('Camiones dictados que Aloha aun no tiene', "COUNTIFS(CgEstado,`"Dictado`",CgCuenta,1)", '0', 'Pasan a Aloha cuando se cargan en el sistema.'),
    @('Exactitud del pronostico (MAPE, semanas con venta real)', "IFERROR(SUMPRODUCT((Demanda!O$W0`:O$WL<>`"`")*ABS(Demanda!P$W0`:P$WL))/COUNTIF(Demanda!O$W0`:O$WL,`"<>`"),`"sin venta real cargada`")", '0.0%', 'Promedio del desvio absoluto entre venta real (ERP) y venta usada. Multinacionales: forecast accuracy semanal; <10% es bueno para fruta.')
)
$r = 5
foreach ($k in $kp) { $ws.Cells[$r, 1].Value = $k[0]; $ws.Cells[$r, 2].Formula = $k[1]; Fmt $ws.Cells[$r, 2] $k[2]; $ws.Cells[$r, 2].Style.Font.Bold = $true; $ws.Cells[$r, 3].Value = $k[3]; $ws.Cells[$r, 3].Style.WrapText = $true; $r++ }
$r += 1
$ws.Cells[$r, 1].Value = 'REFERENCIA MULTINACIONAL (S&OP de fruta fresca)'; $ws.Cells[$r, 2].Value = 'Practica'; $ws.Cells[$r, 3].Value = 'Equivalente en Almar / esta planilla'; Hdr $ws $r 1 3; $r++
$ref = @(
    @('Cadencia S&OP', 'Reunion semanal (15-30 min) de demanda, abastecimiento y riesgos, con KPIs de merma y exactitud del pronostico.', 'El WhatsApp del miercoles 12:00 (pedidos) y del viernes 19:00 (cierre): Cepea, clima, stock proyectado y camiones que faltan. Esta planilla es el soporte para probar antes de dictar.'),
    @('Un solo plan de demanda', 'Un numero de venta por semana acordado entre ventas y compras, con estacionalidad (dia de la semana, semana del mes) y venta real para medir el desvio.', 'Hoja Demanda: venta plan + factor por semana del mes + venta manual + venta real ERP + desvio.'),
    @('Proyeccion de inventario', 'Stock inicial + recepciones - demanda = stock final, por semana, contra un stock de seguridad explicito; recomendacion de pedido con fecha limite por lead time.', 'Hoja Proyeccion: cierre del sabado, minimo 22.500, camiones a cargar y fecha limite (sabado - lead time).'),
    @('Stock de seguridad dinamico (perecederos)', 'Sube y baja con la venta (mas antes del fin de semana / comienzo de mes), acotado por la vida util: mas stock = mas merma.', 'Minimo en cajas (22.500) o por dias de venta (7): Parametros. La cobertura objetivo pinta la proyeccion.'),
    @('Dias de cobertura (DOS / days on hand)', 'Indicador central: stock / venta diaria. Objetivo por categoria; fruta fresca 5-10 dias segun madurez.', 'Columnas "Dias de cobertura" (total y por origen). Almar: 7 dias = fruta que todavia no maduro (gas + camara).'),
    @('Lead time y ciclo de pedido por dia de la semana', 'Cada origen con su lead time y su dia de corte; el sistema avisa antes del corte si la cobertura no llega.', 'Lead time por origen (3/3/6), lead time real por productor (Proveedores), corte PY miercoles / BR jueves, "Cargar hasta" por semana.'),
    @('Capacidad de maduracion', 'Camaras de maduracion planificadas por volumen semanal (regla: una camara de 20 pallets por cada 20 pallets extra por semana, hasta ~140 pallets/sem).', 'Pendiente: cargar capacidad de camaras (ZAC / Coronel Raiz) como tope de recepcion semanal. Hoy el limite es el minimo, no el maximo.'),
    @('Costo total puesto en destino', 'Precio en origen + empaque + flete + aduana + maduracion + merma esperada por carril/proveedor.', 'Parametros: Cepea x 22 + servicios, precio pagado Almar, TC; KPI de costo de las proximas 4 semanas. Falta: flete internacional, aduana y merma por productor (calidad).'),
    @('Diversificacion de origen y proveedores', '20-30% del programa en proveedores de contingencia precalificados; varios origenes, puertos y transportistas.', 'Tres origenes (BR / PY / BO), 17 productores BR, 4 PY, 2 BO; el mix por origen esta en KPIs. Proveedores: capacidad semanal por productor.'),
    @('Scorecard de proveedores', 'OTIF por carril, reclamos, dias en verde / color de llegada, tiempo de correccion.', 'Proveedores: lead time real, regularidad (camiones por semana), precio. Calidad y vida verde: index_calidad (necesita 15 lotes con fecha de rompio).'),
    @('Merma / shrink', '2-10% del costo puesto en destino segun cadena de frio y madurez; se mide y se descuenta del plan.', 'Sin dato en el plan. Sugerencia: registrar cajas descartadas por semana en la hoja Demanda (columna nueva) y restarlas del stock.')
)
foreach ($k in $ref) { $ws.Cells[$r, 1].Value = $k[0]; $ws.Cells[$r, 1].Style.Font.Bold = $true; $ws.Cells[$r, 2].Value = $k[1]; $ws.Cells[$r, 3].Value = $k[2]; $ws.Cells[$r, 2, $r, 3].Style.WrapText = $true; $ws.Cells[$r, 1, $r, 3].Style.VerticalAlignment = 'Top'; $r++ }
$ws.Column(1).Width = 46; $ws.Column(2).Width = 60; $ws.Column(3).Width = 80

# =====================================================================
# 9) PROVEEDORES (comportamiento real desde Aloha, ago-sep 2026)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Proveedores')
Titulo $ws 'Proveedores: capacidad y comportamiento real' 'Camiones desde el 02/08/2026 segun el Plan de Cargas de Aloha (8 semanas). Capacidad semanal = maximo observado (editable). Precio 2026 = promedio pagado por caja (cargas 2026.xlsx).'
$hv = @('Origen', 'Productor (Aloha)', 'Nombre en cargas dictadas', 'Camiones (8 sem)', 'Semanas con carga', 'Prom camiones/sem', 'Max camiones/sem', 'CAPACIDAD semanal (camiones)', 'Lead time real (dias)', 'Cajas/camion', 'Transportista habitual', 'Dias de carga habituales', 'Precio prom 2026 (R$/caja)', 'Camiones esta semana (Cargas)', 'Camiones semana proxima (Cargas)', 'Nota', 'Camiones 2024/2025/2026 (Aloha)', 'Faltante % (MIC - descargado)', 'Ultima carga (Aloha 24/09)', 'Cupo aprox/sem 2026', 'Situacion')
# datos por productor de la otra sesion (Plan de Cargas Aloha completo 2024-2026, al 24/09/2026)
$extra = @{
    'Paraguay HF' = @('39/16/76', -0.001, '21/09/2026', 2.0, '54% de los camiones PY de 2026: dependencia alta');
    'Paraguay MS' = @('84/16/22', 0.0, '15/09/2026', 0.6, '');
    'Paraguay DF' = @('40/13/20', -0.002, '14/09/2026', 0.5, 'transportista historico Compass');
    'Paraguay AS' = @('0/0/11', -0.004, '21/09/2026', 1.8, 'nuevo desde 11/08/2026 (Alvarito)');
    'Cassio Hauck' = @('13/88/96', $null, '18/09/2026', 2.5, 'el mas regular de Brasil');
    'Fischer' = @('17/164/61', $null, '19/09/2026', 1.6, '');
    'Corupá' = @('47/76/46', $null, '11/09/2026', 1.2, '');
    'Corupa' = @('47/76/46', $null, '11/09/2026', 1.2, '');
    'Gilson' = @('39/70/37', $null, '10/09/2026', 1.0, '');
    'Osnildo Stein' = @('0/0/22', $null, '11/09/2026', 0.6, 'nuevo 2026');
    'Ivo Zimerman' = @('0/0/16', $null, '18/09/2026', 0.4, '');
    'Marconi Kons' = @('0/0/14', $null, '11/09/2026', 0.4, 'camion chico (834 cajas promedio historico)');
    'Wagner Schveitzer' = @('0/0/11', $null, '14/08/2026', 0.3, '');
    'Josemar Provesi' = @('', $null, '', $null, '');
    'Banexfrut' = @('', $null, '', $null, 'Bolivia: 1 camion por semana aprox, 6-9 dias de viaje');
    'Befrut' = @('', $null, '', $null, 'Bolivia');
    'Bolivia' = @('', $null, '', $null, 'Bolivia (sin productor en Aloha)')
}
# productores que no aparecen en las ultimas 8 semanas pero existen en el Plan (inactivos o esporadicos): van al final como alternativas
$inactivos = @(
    @('BR', 'Valdemar', 'Valdemar', '81/133/33', 982, 'FG', 45.03, '25/04/2026', 'inactivo desde abril 2026; fue el 2do de 2025'),
    @('BR', 'Jhony Viera', 'Jony', '64/120/26', 976, 'FG', 40.58, '23/03/2026', 'inactivo desde marzo 2026'),
    @('BR', 'Jorge Marangoni', 'Marangoni', '0/0/21', 1008, 'Chabat', 39.24, '24/07/2026', 'sin cargas desde julio; TT 4 dias'),
    @('BR', 'Banana Combinada', 'Banana Combinada', '0/10/14', 996, 'FG', $null, '26/06/2026', 'sin cargas desde junio; TT 4 dias'),
    @('PY', 'Paraguay GM', 'Guido / Servi Fel', '25/6/11', 972, 'Surcentral', $null, '28/07/2026', 'sin cargar desde julio; TT 5 dias'),
    @('PY', 'Paraguay EC', 'Banana EC', '78/10/0', 936, '', $null, '10/2025', 'inactivo desde octubre 2025'),
    @('PY', 'Paraguay SF', 'Paraguay SF', '1/0/0', 980, '', $null, '2024', 'un camion en 2024')
)
for ($c = 1; $c -le $hv.Count; $c++) { $ws.Cells[4, $c].Value = $hv[$c - 1] }; Hdr $ws 4 1 $hv.Count
$alias = @{ 'Fischer' = 'Fisher'; 'Corupá' = 'Agrocurupa'; 'Corupa' = 'Agrocurupa'; 'Cassio Hauck' = 'Cassio'; 'Osnildo Stein' = 'Stein'; 'Ivo Zimerman' = 'Ivo zimer'; 'Josemar Provesi' = 'Josemar'; 'Marconi Kons' = 'Marconi'; 'Wagner Schveitzer' = 'Wagner'; 'Gilson' = 'Gilson'; 'Furlani' = 'Furlani'; 'Shapo' = 'Shapo'; 'Paraguay HF' = 'Paraguay HF'; 'Paraguay AS' = 'Paraguay AS'; 'Paraguay MS' = 'Paraguay MS'; 'Paraguay DF' = 'Paraguay DF'; 'Banexfrut' = 'Bolivia'; 'Befrut' = 'Bolivia'; 'Bolivia' = 'Bolivia' }
$precioProd = @{}; foreach ($pp in $CEP.almar.productores) { $precioProd[[string]$pp.productor] = [double]$pp.precio_avg_caja }
$dias = @('dom', 'lun', 'mar', 'mie', 'jue', 'vie', 'sab')
$desde = [DateTime]'2026-08-02'
$al = $PCJ.camiones | Where-Object { $_.fuente -in 'plan_cargas', 'plan_cargas_otros' -and ([DateTime]$_.carga) -ge $desde }
$grupos = $al | Group-Object origen, productor | Sort-Object { @{ BR = 1; PY = 2; BO = 3 }[[string]$_.Group[0].origen] }, { -$_.Count }
$r = 5
foreach ($g in $grupos) {
    $gg = $g.Group; $o = [string]$gg[0].origen; $nom = [string]$gg[0].productor
    $sem = $gg | Group-Object semana_carga; $maxS = ($sem | Measure-Object Count -Maximum).Maximum
    $tr = ($gg | Group-Object transportista | Sort-Object Count -Descending | Where-Object { $_.Name -and $_.Name -ne '0' } | Select-Object -First 2 | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ' / '
    $dd = ($gg | Group-Object { $dias[[int]([DateTime]$_.carga).DayOfWeek] } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    $lagReal = @($gg | Where-Object { $_.descarga } | ForEach-Object { (([DateTime]$_.descarga) - ([DateTime]$_.carga)).TotalDays })
    $ali = $(if ($alias.ContainsKey($nom)) { $alias[$nom] } else { $nom })
    $ws.Cells[$r, 1].Value = $o; $ws.Cells[$r, 2].Value = $nom; $ws.Cells[$r, 3].Value = $ali; Inp $ws.Cells[$r, 3]
    $ws.Cells[$r, 4].Value = $gg.Count; $ws.Cells[$r, 5].Value = $sem.Count; $ws.Cells[$r, 6].Value = [math]::Round($gg.Count / 8, 1); Fmt $ws.Cells[$r, 6] '0.0'; $ws.Cells[$r, 7].Value = $maxS
    $ws.Cells[$r, 8].Value = $maxS; Inp $ws.Cells[$r, 8]
    if ($lagReal.Count) { $ws.Cells[$r, 9].Value = [math]::Round(($lagReal | Measure-Object -Average).Average, 1); Fmt $ws.Cells[$r, 9] '0.0' }
    $ws.Cells[$r, 10].Value = [int]$gg[0].cajas; $ws.Cells[$r, 11].Value = $tr; $ws.Cells[$r, 12].Value = $dd
    if ($precioProd.ContainsKey($ali)) { $ws.Cells[$r, 13].Value = $precioProd[$ali]; Fmt $ws.Cells[$r, 13] '0.00' }
    $ws.Cells[$r, 14].Formula = "COUNTIFS(CgProductor,B$r,CgSemana,$semHoy)+IF(C$r<>B$r,COUNTIFS(CgProductor,C$r,CgSemana,$semHoy),0)"
    $ws.Cells[$r, 15].Formula = "COUNTIFS(CgProductor,B$r,CgSemana,$semHoy+7)+IF(C$r<>B$r,COUNTIFS(CgProductor,C$r,CgSemana,$semHoy+7),0)"
    $ws.Cells[$r, 16].Value = $(if ($o -eq 'BO') { 'Bolivia: 6-9 dias reales de carga a descarga; 1 camion por semana en promedio.' } elseif ($o -eq 'PY') { 'Paraguay carga domingo-lunes-martes y entra en la semana.' } else { '' })
    if ($extra.ContainsKey($nom)) { $ex = $extra[$nom]; $ws.Cells[$r, 17].Value = $ex[0]; if ($null -ne $ex[1]) { $ws.Cells[$r, 18].Value = $ex[1]; Fmt $ws.Cells[$r, 18] '0.0%' }; $ws.Cells[$r, 19].Value = $ex[2]; if ($null -ne $ex[3]) { $ws.Cells[$r, 20].Value = $ex[3]; Fmt $ws.Cells[$r, 20] '0.0' }; $ws.Cells[$r, 21].Value = $ex[4] }
    if ([string]::IsNullOrEmpty($ws.Cells[$r, 21].Text)) { $ws.Cells[$r, 21].Value = 'activo' }
    $r++
}
foreach ($x in $inactivos) {
    $ws.Cells[$r, 1].Value = $x[0]; $ws.Cells[$r, 2].Value = $x[1]; $ws.Cells[$r, 3].Value = $x[2]; Inp $ws.Cells[$r, 3]; $ws.Cells[$r, 4].Value = 0; $ws.Cells[$r, 5].Value = 0
    Inp $ws.Cells[$r, 8]; $ws.Cells[$r, 10].Value = $x[4]; $ws.Cells[$r, 11].Value = $x[5]; if ($null -ne $x[6]) { $ws.Cells[$r, 13].Value = $x[6]; Fmt $ws.Cells[$r, 13] '0.00' }
    $ws.Cells[$r, 14].Formula = "COUNTIFS(CgProductor,B$r,CgSemana,$semHoy)+IF(C$r<>B$r,COUNTIFS(CgProductor,C$r,CgSemana,$semHoy),0)"
    $ws.Cells[$r, 15].Formula = "COUNTIFS(CgProductor,B$r,CgSemana,$semHoy+7)+IF(C$r<>B$r,COUNTIFS(CgProductor,C$r,CgSemana,$semHoy+7),0)"
    $ws.Cells[$r, 16].Value = 'Sin cargas en las ultimas 8 semanas: alternativa si falla un habitual.'; $ws.Cells[$r, 17].Value = $x[3]; $ws.Cells[$r, 19].Value = $x[7]; $ws.Cells[$r, 21].Value = $x[8]
    $ws.Cells[$r, 1, $r, 21].Style.Font.Color.SetColor([System.Drawing.Color]::DimGray)
    $r++
}
$rl = $r - 1
CF $ws "N5:N$rl" "AND(H5<>`"`",N5>H5)" $ROJO $true
CF $ws "O5:O$rl" "AND(H5<>`"`",O5>H5)" $ROJO $true
$ws.Cells[($r + 1), 1].Value = 'Rojo en "Camiones esta semana / proxima": se pidio mas de la capacidad semanal observada. La capacidad es editable (columna amarilla). Los nombres de la columna "Nombre en cargas dictadas" tienen que coincidir con los que se usan en la hoja Cargas.'
$ws.View.FreezePanes(5, 3)
$anchos = @(7, 20, 20, 10, 10, 10, 10, 12, 10, 9, 30, 20, 12, 12, 12, 60, 14, 12, 14, 10, 50); for ($c = 1; $c -le $anchos.Count; $c++) { $ws.Column($c).Width = $anchos[$c - 1] }

# =====================================================================
# 9b) CALENDARIO S&OP (aporte de la otra sesion: "la planilla tiene que decir quien decide que dia")
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Calendario')
Titulo $ws 'Calendario S&OP semanal de Almar' 'Rutina fija: que se mira, quien decide y con que hoja, cada dia. Es lo que hacen las multinacionales de fruta (Dole: metricas diarias y semanales de volumen, precio, flete, merma, servicio y capital de trabajo), a escala de 16-17 mil cajas por semana.'
$ws.Cells[4, 1].Value = 'Dia'; $ws.Cells[4, 2].Value = 'Momento'; $ws.Cells[4, 3].Value = 'Que se hace'; $ws.Cells[4, 4].Value = 'Decide / carga'; $ws.Cells[4, 5].Value = 'Hoja / herramienta'; Hdr $ws 4 1 5
$cal = @(
    @('Lunes', 'manana', 'Venta real de la semana pasada (ERP) y desvio contra el plan. Si hubo conteo por camara el sabado, actualizar el conteo. Revisar que descargo el fin de semana y el lunes (Aloha).', 'Gonzalo / administracion', 'Demanda (col. Venta real ERP), Parametros (conteo), Cargas (descarga real)'),
    @('Martes', 'manana', 'Abastecimiento: bajar el Plan de Cargas de Aloha, marcar camiones en frontera o atrasados, cargar en Cargas lo nuevo, mirar la calidad de lo que llego.', 'Gonzalo / recepcion', 'Cargas, Proveedores (lead time real), index_calidad'),
    @('Miercoles', '12:00', 'Llega el WhatsApp del servidor (Cepea, clima, plan de compras). Decision de la semana: cuantos camiones faltan para el sabado siguiente y de que origen. CIERRE DE PEDIDOS PARAGUAY.', 'Gonzalo', 'QueCargar, Semaforo, Proveedores (cupos PY)'),
    @('Jueves', 'manana', 'CIERRE DE PEDIDOS BRASIL: confirmar productores, transportistas y dias de carga; dictar las cargas (plan_compras.xlsx) para que entren al plan.', 'Gonzalo', 'QueCargar, Proveedores (cupos BR), plan_compras.xlsx hoja cargas_programadas'),
    @('Viernes', '19:00', 'WhatsApp de cierre. Riesgos de la semana que viene: frontera lenta (escenario P90), calidad, Bolivia sin carga, venta distinta a la esperada. Ajustar venta manual si cambio.', 'Gonzalo', 'Escenarios, Semaforo, Demanda (venta manual)'),
    @('Sabado', 'cierre', 'Cierre semanal: el stock del sabado es la referencia. Comparar stock real contra el proyectado y anotar la diferencia (merma, conteo, camiones que no llegaron).', 'Deposito', 'Parametros (conteo), KPIs'),
    @('Mensual', 'primer lunes', 'Revisar factores de estacionalidad por semana del mes, desvio estandar de la venta, precios de compra por origen, capacidad de camaras, concentracion de proveedores.', 'Gonzalo', 'Parametros, Demanda, KPIs, MercadoPY')
)
$r = 5; foreach ($c in $cal) { for ($k = 0; $k -lt 5; $k++) { $ws.Cells[$r, ($k + 1)].Value = $c[$k]; $ws.Cells[$r, ($k + 1)].Style.WrapText = $true; $ws.Cells[$r, ($k + 1)].Style.VerticalAlignment = 'Top' }; $ws.Cells[$r, 1].Style.Font.Bold = $true; $r++ }
$ws.Cells[($r + 1), 1].Value = 'Reglas fijas: el sabado cierra la semana; lo que descarga el lunes suma a la siguiente; Paraguay carga domingo-lunes-martes (entra en la semana); Brasil cierra pedidos jueves y Paraguay miercoles; minimo 22.500 cajas al sabado, Bolivia incluida.'
$ws.Column(1).Width = 12; $ws.Column(2).Width = 12; $ws.Column(3).Width = 80; $ws.Column(4).Width = 24; $ws.Column(5).Width = 50

# =====================================================================
# 9c) SEMAFORO SEMANAL (una pantalla: por origen, esta semana y la proxima)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Semaforo')
Titulo $ws 'Semaforo semanal' 'Una pantalla: stock al sabado y dias de cobertura por origen para esta semana y la proxima, con el estado y la accion. Los camiones que faltan todavia no tienen origen: van al que este mas justo.'
$semHoy = 'Hoy-WEEKDAY(Hoy,2)+1'
function BloqueSem($ws, $r0, $titulo, $off) {
    $k = "($semHoy+$off)"
    $ws.Cells[$r0, 1].Formula = "`"$titulo (sabado `"&TEXT(INDEX(PrSab,MATCH($k,PrSemana,0)),`"dd/mm`")&`")`""; Hdr $ws $r0 1 5
    $ws.Cells[($r0 + 1), 1].Value = 'Origen'; $ws.Cells[($r0 + 1), 2].Value = 'Stock al sabado'; $ws.Cells[($r0 + 1), 3].Value = 'Dias de cobertura'; $ws.Cells[($r0 + 1), 4].Value = 'Estado'; $ws.Cells[($r0 + 1), 5].Value = 'Accion'; $ws.Cells[($r0 + 1), 1, ($r0 + 1), 5].Style.Font.Bold = $true; Solid $ws.Cells[($r0 + 1), 1, ($r0 + 1), 5] $GRIS
    $rr = $r0 + 2
    foreach ($o in @(@('Brasil', 'PrBR', 'PrBRd'), @('Paraguay', 'PrPY', 'PrPYd'), @('Bolivia', 'PrBO', 'PrBOd'))) {
        $ws.Cells[$rr, 1].Value = $o[0]; $ws.Cells[$rr, 1].Style.Font.Bold = $true
        $ws.Cells[$rr, 2].Formula = "IFERROR(INDEX($($o[1]),MATCH($k,PrSemana,0)),`"`")"; Fmt $ws.Cells[$rr, 2] '#,##0'
        $ws.Cells[$rr, 3].Formula = "IFERROR(INDEX($($o[2]),MATCH($k,PrSemana,0)),`"`")"; Fmt $ws.Cells[$rr, 3] '0.0'
        $ws.Cells[$rr, 4].Formula = "IF(B$rr=`"`",`"`",IF(B$rr<0,`"FALTA`",IF(C$rr<2,`"CRITICO`",IF(C$rr<CoberturaObjetivo,`"JUSTO`",IF(C$rr>VidaVerde,`"EXCESO`",`"OK`")))))"
        $ws.Cells[$rr, 5].Formula = "IF(D$rr=`"FALTA`",`"se queda sin fruta: cargar ya`",IF(D$rr=`"CRITICO`",`"cargar esta semana, sin falta`",IF(D$rr=`"JUSTO`",`"priorizar este origen en los pedidos`",IF(D$rr=`"EXCESO`",`"frenar cargas: riesgo de merma`",`"`"))))"
        $rr++
    }
    $ws.Cells[$rr, 1].Value = 'TOTAL'; $ws.Cells[$rr, 1].Style.Font.Bold = $true
    $ws.Cells[$rr, 2].Formula = "IFERROR(INDEX(PrProy,MATCH($k,PrSemana,0)),`"`")"; Fmt $ws.Cells[$rr, 2] '#,##0'; $ws.Cells[$rr, 2].Style.Font.Bold = $true
    $ws.Cells[$rr, 3].Formula = "IFERROR(INDEX(PrCobertura,MATCH($k,PrSemana,0)),`"`")"; Fmt $ws.Cells[$rr, 3] '0.0'
    $ws.Cells[$rr, 4].Formula = "IFERROR(INDEX(PrEstado,MATCH($k,PrSemana,0)),`"`")"
    $ws.Cells[$rr, 5].Formula = "IFERROR(IF(INDEX(PrACargar,MATCH($k,PrSemana,0))>0,`"cargar `"&INDEX(PrACargar,MATCH($k,PrSemana,0))&`" camion(es) mas hasta el `"&TEXT(INDEX(PrLimite,MATCH($k,PrSemana,0)),`"ddd dd/mm`")&`" para cerrar en `"&FIXED(MinimoSabado,0),`"ok, cierra sobre `"&FIXED(MinimoSabado,0)),`"`")"
    $ws.Cells[$rr, 1, $rr, 5].Style.Border.Top.Style = 'Thin'
    foreach ($cc in 'D') {
        CF $ws "$cc$($r0 + 2):$cc$rr" "OR(LEFT($cc$($r0 + 2),5)=`"FALTA`",LEFT($cc$($r0 + 2),7)=`"CRITICO`",LEFT($cc$($r0 + 2),4)=`"BAJO`")" $ROJO $true
        CF $ws "$cc$($r0 + 2):$cc$rr" "OR(LEFT($cc$($r0 + 2),5)=`"JUSTO`",LEFT($cc$($r0 + 2),6)=`"CARGAR`")" $AMAR $true
        CF $ws "$cc$($r0 + 2):$cc$rr" "LEFT($cc$($r0 + 2),6)=`"EXCESO`"" ([System.Drawing.Color]::FromArgb(255, 252, 228, 214)) $true
        CF $ws "$cc$($r0 + 2):$cc$rr" "$cc$($r0 + 2)=`"OK`"" $VERDE $false
    }
    return $rr
}
$rf = BloqueSem $ws 4 'ESTA SEMANA' 0
$rf = BloqueSem $ws ($rf + 2) 'SEMANA PROXIMA' 7
$rf = BloqueSem $ws ($rf + 2) 'EN DOS SEMANAS' 14
$r = $rf + 2
$ws.Cells[$r, 1].Value = 'RIESGOS ABIERTOS'; Hdr $ws $r 1 5; $r++
$riesgos = @(
    "IF(COUNTIFS(CgOrigen,`"BO`",CgCuenta,1,CgSemana,`">=`"&($semHoy))=0,`"Bolivia: no hay ningun camion en camino ni dictado. Tarda 6 dias: para que entre el sabado que viene tiene que cargar antes del `"&TEXT($semHoy+12-LagBO,`"ddd dd/mm`"),`"Bolivia: `"&COUNTIFS(CgOrigen,`"BO`",CgCuenta,1,CgSemana,`">=`"&($semHoy))&`" camion(es) en el plan`")",
    "`"Paraguay: `"&COUNTIFS(CgEstado,`"Supuesto`",CgSemana,`">=`"&($semHoy),CgSemana,`"<`"&($semHoy+14))&`" camiones SUPUESTOS en las proximas 2 semanas (todavia no dictados). El plan es firme cuando se dictan.`"",
    "`"Dictados que Aloha aun no tiene: `"&COUNTIFS(CgEstado,`"Dictado`",CgCuenta,1)&`" camiones. Pasan a Aloha cuando se cargan en el sistema.`"",
    "IFERROR(`"Frontera lenta (P90): el sabado `"&TEXT(INDEX(PrSab,MATCH($semHoy,PrSemana,0)),`"dd/mm`")&`" cerraria en `"&FIXED(INDEX(Escenarios!L$W0`:L$WL,MATCH($semHoy,PrSemana,0)),0)&`" cajas (`"&IF(INDEX(Escenarios!G$W0`:G$WL,MATCH($semHoy,PrSemana,0))>INDEX(Escenarios!L$W0`:L$WL,MATCH($semHoy,PrSemana,0)),FIXED(INDEX(Escenarios!G$W0`:G$WL,MATCH($semHoy,PrSemana,0))-INDEX(Escenarios!L$W0`:L$WL,MATCH($semHoy,PrSemana,0)),0)&`" menos que el plan`",`"igual o mas que el plan`")&`") y el `"&TEXT(INDEX(PrSab,MATCH($semHoy+7,PrSemana,0)),`"dd/mm`")&`" en `"&FIXED(INDEX(Escenarios!L$W0`:L$WL,MATCH($semHoy+7,PrSemana,0)),0)&`" (plan: `"&FIXED(INDEX(Escenarios!G$W0`:G$WL,MATCH($semHoy+7,PrSemana,0)),0)&`").`",`"`")",
    "`"Escenario de venta activo: `"&Parametros!B8&`" (factor `"&FIXED(FactorEscenario,2)&`"). Atraso extra en frontera: `"&AtrasoDias&`" dia(s).`"",
    "IF(CapMadurar=`"`",`"Capacidad de maduracion: sin cargar en Parametros (camaras, cajas por camara, ciclo). Hasta entonces no se controla el cuello de botella.`",`"Capacidad de maduracion: `"&FIXED(CapMadurar,0)&`" cajas/semana.`")",
    "`"Verde en transito (cargado y sin descargar): `"&FIXED(SUM(CgPipeline),0)&`" cajas.`""
)
foreach ($f in $riesgos) { $ws.Cells[$r, 1].Formula = $f; $ws.Cells[$r, 1, $r, 5].Merge = $true; $ws.Cells[$r, 1].Style.WrapText = $true; $r++ }
$ws.Column(1).Width = 12; $ws.Column(2).Width = 16; $ws.Column(3).Width = 16; $ws.Column(4).Width = 26; $ws.Column(5).Width = 70

# =====================================================================
# 9d) CAPACIDAD (maduracion y camaras)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Capacidad')
Titulo $ws 'Capacidad de maduracion y camaras' 'Cajas a madurar por semana (= la venta de la semana siguiente) contra lo que las camaras de gas pueden madurar, y stock al sabado contra la capacidad fisica. Completar Parametros (camaras, cajas por camara, ciclo, capacidad fisica).'
$hk = @('Semana (lunes)', 'Sabado', 'Cajas que descargan', 'Cajas a madurar (venta sem. siguiente)', 'Capacidad de maduracion (cajas/sem)', 'Utilizacion', 'Cuello de botella', 'Stock al sabado', 'Capacidad fisica (cajas)', 'Ocupacion camaras', 'Estado')
for ($c = 1; $c -le $hk.Count; $c++) { $ws.Cells[5, $c].Value = $hk[$c - 1] }; Hdr $ws 5 1 $hk.Count
for ($i = 0; $i -lt $NW; $i++) {
    $r = $W0 + $i; $rn = $r + 1; if ($i -eq $NW - 1) { $rn = $r }
    $ws.Cells[$r, 1].Formula = "Proyeccion!A$r"; Fmt $ws.Cells[$r, 1] 'dd/mm/yyyy'
    $ws.Cells[$r, 2].Formula = "Proyeccion!B$r"; Fmt $ws.Cells[$r, 2] 'dd/mm/yyyy'
    $ws.Cells[$r, 3].Formula = "Proyeccion!E$r"; Fmt $ws.Cells[$r, 3] '#,##0'
    $ws.Cells[$r, 4].Formula = "Demanda!H$rn"; Fmt $ws.Cells[$r, 4] '#,##0'
    $ws.Cells[$r, 5].Formula = "IF(CapMadurar=`"`",`"`",CapMadurar)"; Fmt $ws.Cells[$r, 5] '#,##0'
    $ws.Cells[$r, 6].Formula = "IF(E$r=`"`",`"`",D$r/E$r)"; Fmt $ws.Cells[$r, 6] '0%'
    $ws.Cells[$r, 7].Formula = "IF(E$r=`"`",`"completar Parametros`",IF(D$r>E$r,`"SI: `"&FIXED(D$r-E$r,0)&`" cajas de mas`",`"no`"))"
    $ws.Cells[$r, 8].Formula = "Proyeccion!L$r"; Fmt $ws.Cells[$r, 8] '#,##0'
    $ws.Cells[$r, 9].Formula = "IF(CapFisica=`"`",`"`",CapFisica)"; Fmt $ws.Cells[$r, 9] '#,##0'
    $ws.Cells[$r, 10].Formula = "IF(I$r=`"`",`"`",H$r/I$r)"; Fmt $ws.Cells[$r, 10] '0%'
    $ws.Cells[$r, 11].Formula = "IF(I$r=`"`",`"`",IF(H$r>I$r,`"NO ENTRA`",IF(H$r>0.9*I$r,`"al limite`",`"ok`")))"
}
CF $ws "G$W0`:G$WL" "LEFT(G$W0,2)=`"SI`"" $ROJO $true
CF $ws "K$W0`:K$WL" "K$W0=`"NO ENTRA`"" $ROJO $true
CF $ws "K$W0`:K$WL" "K$W0=`"al limite`"" $AMAR $false
$ws.Cells[($WL + 2), 1].Value = 'Referencias (multinacionales): ciclo de maduracion de 4 a 6 dias (5 el mas usado); etileno 100-150 ppm las primeras 24 h; minimo 4 camaras para escalonar entrada, gaseo y despacho; una camara de 20 pallets por cada 20 pallets extra por semana hasta ~140 pallets/semana. Un pallet = 48 cajas de 22 kg aprox.'
$anchos = @(13, 11, 12, 16, 16, 10, 22, 12, 14, 12, 12); for ($c = 1; $c -le $anchos.Count; $c++) { $ws.Column($c).Width = $anchos[$c - 1] }

# =====================================================================
# 9e) MERCADO PY (exportadores Penta 2026, alternativas de abastecimiento)
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('MercadoPY')
Titulo $ws 'Mercado exportador de Paraguay (Penta, ene-ago 2026)' 'Quien mas tiene volumen si falla un proveedor habitual. Cupo semanal aprox = kg brutos / 34 semanas / 22 kg. OJO: 47% del valor 2026 figura como "No disponible" en Penta, asi que los cupos estan subestimados. USD CIF entre identificados.'
$hm = @('Exportador', '% del valor 2026', 'Millones de kg', 'Cajas/semana aprox', 'Relacion con Almar / nota'); for ($c = 1; $c -le $hm.Count; $c++) { $ws.Cells[4, $c].Value = $hm[$c - 1] }; Hdr $ws 4 1 5
$mpy = @(
    @('Misionero SRL', 0.180, 6.42, 8600, 'marcas TROPICAL y CIRO'),
    @('Hugo Alberto Franco', 0.095, 3.15, 4200, 'Tembiapora, Menicob: proveedor HF de Almar (54% de los camiones PY 2026)'),
    @('Ruben Dario Aguero', 0.069, 2.97, 4000, ''),
    @('Emprendimientos Karen', 0.063, 2.19, 2900, ''),
    @('Saldivar & Hijos', 0.052, 1.86, 2500, ''),
    @('Agro Climatizadora San Jose', 0.047, 1.68, 2250, ''),
    @('Melgarejo Lopez', 0.042, 1.57, 2100, 'proveedor de Nalia'),
    @('Ecotierra SRL', 0.040, 1.31, 1750, 'principal proveedor de Almar, marca PEPE'),
    @('Elvio Valdez', 0.037, 1.57, 2100, ''),
    @('Velazquez Gimenez', 0.035, 1.24, 1660, ''),
    @('Frutas Carolina', 0.034, 1.29, 1720, ''),
    @('Samuel Riveros', 0.031, 1.26, 1680, ''),
    @('Grupo Campo Flor', 0.030, 1.34, 1790, ''),
    @('Servi-Fel', 0.029, $null, $null, 'Guido (GM): proveedor de Almar sin cargas desde julio 2026'),
    @('San Jose Obrero', 0.026, $null, $null, ''),
    @('Silvia Castillo', 0.024, $null, $null, 'proveedora de Nalia'),
    @('Graciela Nunez', 0.023, $null, $null, ''),
    @('Gaspar Saldivar & Nietos', 0.021, $null, $null, ''),
    @('El Productor', 0.018, $null, $null, '')
)
$r = 5; foreach ($m in $mpy) { $ws.Cells[$r, 1].Value = $m[0]; $ws.Cells[$r, 2].Value = $m[1]; Fmt $ws.Cells[$r, 2] '0.0%'; if ($null -ne $m[2]) { $ws.Cells[$r, 3].Value = $m[2]; Fmt $ws.Cells[$r, 3] '0.00' }; if ($null -ne $m[3]) { $ws.Cells[$r, 4].Value = $m[3]; Fmt $ws.Cells[$r, 4] '#,##0' }; $ws.Cells[$r, 5].Value = $m[4]; $r++ }
$ws.Cells[($r + 1), 1].Value = 'Uso: si HF (Franco) o MS no pueden cargar, los cupos de Misionero, Aguero, Karen o Saldivar cubren 2-8 camiones por semana cada uno. Fuente: extractos Penta (aduana UY) trabajados en el Excel de exportadores de Paraguay (otra sesion, 28/09/2026).'
$ws.Column(1).Width = 30; $ws.Column(2).Width = 14; $ws.Column(3).Width = 14; $ws.Column(4).Width = 16; $ws.Column(5).Width = 80

# =====================================================================
# 10) GLOSARIO
# =====================================================================
$ws = $pkg.Workbook.Worksheets.Add('Glosario')
Titulo $ws 'Glosario y fuentes' ''
$ws.Cells[3, 1].Value = 'Termino'; $ws.Cells[3, 2].Value = 'Que es'; Hdr $ws 3 1 2
$gl = @(
    @('S&OP (Sales & Operations Planning)', 'Proceso semanal/mensual donde ventas, compras y logistica acuerdan UN plan de demanda y de abastecimiento y revisan riesgos con KPIs.'),
    @('Dias de cobertura (DOS, days on hand)', 'Stock dividido la venta diaria. Cuantos dias aguanta el stock sin que entre nada.'),
    @('Stock de seguridad / minimo', 'Stock que se quiere tener al cierre para absorber atrasos y picos de venta. Aca: 22.500 cajas al sabado (o 7 dias de venta).'),
    @('Lead time', 'Dias entre cargar el camion y descargarlo en Almar. BR/PY 3, BO 6 (reales por productor en Proveedores).'),
    @('Punto de pedido / fecha limite', 'Ultimo dia para cargar de modo que el camion sume a esa semana: sabado menos el lead time (miercoles para BR/PY).'),
    @('Corte de pedido', 'Dia en que el proveedor cierra los pedidos de la semana siguiente: Paraguay miercoles, Brasil jueves.'),
    @('Prorrateo de la semana del conteo', 'La venta de la semana en que se hizo el conteo se cuenta solo por los dias que quedan hasta el sabado.'),
    @('Arrastre de pedidos', 'Los camiones que faltan en una semana se suman al stock de las siguientes (se supone que se cargan).'),
    @('Supuesto', 'Camion que todavia no se dicto pero que se asume por costumbre (5 PY por semana).'),
    @('Forecast accuracy / MAPE', 'Promedio del desvio absoluto entre venta real y venta planificada, en %.'),
    @('OTIF', 'On time in full: % de cargas que llegan el dia previsto y completas. Se puede medir con el lead time real por productor.'),
    @('Shrink / merma', 'Cajas que se pierden por calidad, madurez o frio. En multinacionales 2-10% del costo puesto en destino.'),
    @('Total landed cost', 'Costo total puesto en destino: origen + empaque + flete + aduana + maduracion + merma.'),
    @('TT mediana / P90', 'Tiempo de transito carga a descarga: la mediana es lo normal, el P90 es lo que tarda el peor 10% (frontera lenta). Se usa en la descarga pesimista y en el escenario "frontera a P90".'),
    @('EXCESO', 'Mas dias de cobertura que la vida util en verde (16): la fruta va a madurar antes de venderse. Senal de frenar cargas, no de seguridad.'),
    @('Pipeline / verde en transito', 'Cajas ya cargadas que todavia no descargaron. Es lo que viene en camino sin depender de un pedido nuevo.'),
    @('Concentracion de proveedores', '% de los camiones que aporta el mayor productor de un origen. Alta = si falla, no hay reemplazo rapido (HF fue 54% de Paraguay en 2026).'),
    @('Fill rate proveedor / faltante', 'Cajas descargadas sobre cajas declaradas (MIC). En el Plan de Cargas de Aloha esta como faltante %.')
)
$r = 4; foreach ($g in $gl) { $ws.Cells[$r, 1].Value = $g[0]; $ws.Cells[$r, 1].Style.Font.Bold = $true; $ws.Cells[$r, 2].Value = $g[1]; $ws.Cells[$r, 2].Style.WrapText = $true; $r++ }
$r += 1; $ws.Cells[$r, 1].Value = 'FUENTES CONSULTADAS (28/09/2026)'; $ws.Cells[$r, 2].Value = ''; Hdr $ws $r 1 2; $r++
$fu = @(
    @('Blue Ridge: 11-point checklist for perishable inventory management', 'https://blueridgeglobal.com/blog/11-point-checklist-for-perishable-inventory-management/'),
    @('RELEX: fresh food inventory management (safety stock dinamico, perfiles diarios de demanda)', 'https://www.relexsolutions.com/resources/fresh-food-inventory-management/'),
    @('RELEX: 4 strategies for managing fresh produce in grocery retail', 'https://www.relexsolutions.com/resources/4-strategies-for-managing-fresh-fruits-and-vegetables-in-grocery-retail/'),
    @('SmartSense: S&OP decisions and food waste (cadencia semanal, KPIs de merma y forecast accuracy)', 'https://blog.smartsense.co/sop-food-waste-supply-chain'),
    @('Tridge: banana sourcing intelligence, total landed cost and risk', 'https://blog.tridge.com/blog-posts/banana-sourcing-intelligence-us-import-programs-where-total-landed-cost-and-risk-really-sit'),
    @('Thermal Technologies: ripening room FAQs (capacidad de camaras por volumen semanal)', 'https://thermaltechnologies.com/ripening-room-faqs/'),
    @('MIT Sloan: what bananas can tell us about supply chains', 'https://mitsloan.mit.edu/ideas-made-to-matter/what-bananas-can-tell-us-about-supply-chains'),
    @('LIDD: a deep dive into the banana supply chain', 'https://lidd.com/banana-supply-chain/'),
    @('Vena: inventory forecasting template (safety stock = Z x desvio x raiz del lead time; punto de pedido)', 'https://www.venasolutions.com/templates/plan-budget-forecast/inventory-forecasting'),
    @('Umbrex: perfil de Dole plc (metricas diarias y semanales: volumen, precio, flete, merma, servicio, capital de trabajo)', 'https://umbrex.com/resources/company-profiles/dole-plc/'),
    @('Umbrex: service level optimization in fresh categories (KPIs encadenados: disponibilidad, fill rate/OTIF, frescura, merma, forecast accuracy)', 'https://umbrex.com/resources/umbrex-explainers/agriculture-food-explainers/service-level-optimization-in-fresh-categories/'),
    @('Fyffes: red de 40+ centros de maduracion/distribucion', 'https://en.wikipedia.org/wiki/Fyffes'),
    @('RELEX: fresh produce, maximizing freshness, availability and margins (safety stock con tope por vida util)', 'https://www.relexsolutions.com/resources/fresh-produce-maximizing-freshness-availability-and-margins/'),
    @('The Produce News: choosing the right banana ripening cycle (4-6 dias)', 'https://theproducenews.com/choosing-right-banana-ripening-cycle'),
    @('Catalytic Generators: banana ripening (etileno 100-150 ppm, 24 h)', 'https://www.catalyticgenerators.com/banana-ripening'),
    @('fmax: banana ripening chamber FAQ (minimo 4 camaras para escalonar)', 'https://www.fmax.in/banana-ripening-chamber-faq-setup-ethylene-control/'),
    @('Cloud Creations: KPI guide for grocery (rotacion en fresco 26-52 vueltas/ano)', 'https://www.cloudcreations.com/resource/kpi-guide-for-grocery-supermarkets/')
)
foreach ($f in $fu) { $ws.Cells[$r, 1].Value = $f[0]; $ws.Cells[$r, 2].Value = $f[1]; $ws.Cells[$r, 2].Hyperlink = [uri]$f[1]; $ws.Cells[$r, 2].Style.Font.UnderLine = $true; $ws.Cells[$r, 2].Style.Font.Color.SetColor([System.Drawing.Color]::Navy); $r++ }
$ws.Column(1).Width = 60; $ws.Column(2).Width = 120

# ---------- orden de hojas y cierre ----------
foreach ($n in 'Inicio', 'Calendario', 'Parametros', 'Demanda', 'Cargas', 'Proyeccion', 'QueCargar', 'Semaforo', 'Escenarios', 'Capacidad', 'KPIs', 'Proveedores', 'MercadoPY', 'Glosario') { $pkg.Workbook.Worksheets.MoveToEnd($n) }
$pkg.Workbook.Worksheets['Inicio'].View.TabSelected = $true
$pkg.Workbook.CalcMode = [OfficeOpenXml.ExcelCalcMode]::Automatic
$pkg.Workbook.FullCalcOnLoad = $true
try { $pkg.Workbook.Calculate() } catch { Write-Host "Calculate(): $($_.Exception.Message)" -ForegroundColor Yellow }
$pkg.SaveAs([IO.FileInfo]$out)
$pkg.Dispose()
"OK $out · camiones en Cargas: $nCam · semanas: $NW ($($semanas[0].ToString('dd/MM')) a $($semanas[-1].ToString('dd/MM')))"
