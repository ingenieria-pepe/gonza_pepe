# ==========================================================================
#  plan_compras\generar_datos.ps1  -  datos del simulador del plan de compras
# ==========================================================================
#  El plan de compras se trabaja por fuera del dashboard hasta que este listo
#  (Gonzalo, 20/09/2026): sin boton ni tarjeta. Desde el 24/09/2026 lo corre
#  actualizar_precios.ps1 al final de los paneles (paso 5j) para que en el
#  servidor quede al dia solo; a mano sigue sirviendo:
#
#    powershell -ExecutionPolicy Bypass -File plan_compras\generar_datos.ps1
#
#  Lee:
#    - fuentes\plan_cargas\*.xlsx (el mas nuevo): plan Brasil/Paraguay (export de
#      Aloha o master de OneDrive), camiones con fecha de carga y de descarga. En
#      el servidor lo baja el paso 3b desde la API de Aloha en cada corrida.
#    - fuentes\plan_cargas\otros\*.xlsx (el mas nuevo): export de Aloha fuente
#      OTROS, de donde salen los camiones de BOLIVIA (Pais = BO). Idem, 3b.
#    - plan_compras\plan_compras.xlsx: hojas cargas_programadas (lo que dicta
#      Gonzalo), ventas_plan, conteo.
#  Escribe:
#    - plan_compras\plan_compras.json
#    - plan_compras\simulador.html (inyecta el JSON entre los marcadores)
#
#  Reglas:
#    - Las cargas dictadas se cuentan salvo que el Plan ya tenga una carga de ese
#      productor (nombre o alias) en esa semana: cuando Aloha se pone al dia, manda
#      Aloha, y lo que Aloha todavia no tiene sigue contando. [24/09/2026]
#    - Descarga = fecha real si ya descargo; si no, carga + 3 dias (BR), + 4 (PY, desde el 28/09/2026) o + 6 (BO).
# ==========================================================================
$ErrorActionPreference = 'Stop'
$aqui = $PSScriptRoot
$repo = Split-Path $aqui -Parent
# Read-XlsxHoja: la misma funcion del script principal (se toma del archivo para no duplicarla)
$tk = $null; $er = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$repo\actualizar_precios.ps1", [ref]$tk, [ref]$er)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-XlsxHoja' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'no encuentro Read-XlsxHoja en actualizar_precios.ps1' }
Invoke-Expression $fn.Extent.Text
function Fecha($s) { if ($null -eq $s) { return $null }; $o = 0.0; if ([double]::TryParse([string]$s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$o) -and $o -gt 40000 -and $o -lt 60000) { return [DateTime]::FromOADate($o) }; try { return [DateTime]::Parse([string]$s) } catch { return $null } }
function Tabla($path, $hoja) { $r = Read-XlsxHoja -Path $path -Hoja $hoja; if ($r.Count -lt 1) { return @() }; $h = @($r[0] | ForEach-Object { ([string]$_).Trim().ToLower() }); $out = @(); for ($i = 1; $i -lt $r.Count; $i++) { $f = @($r[$i]); if (-not ($f -join '').Trim()) { continue }; $o = [ordered]@{}; for ($k = 0; $k -lt $h.Count; $k++) { if ($h[$k]) { $o[$h[$k]] = $(if ($k -lt $f.Count) { [string]$f[$k] } else { '' }) } }; $out += [PSCustomObject]$o }; return $out }
function Ymd($d) { return $d.ToString('yyyy-MM-dd') }
$LAG_DESC = @{ BR = 3; PY = 4; BO = 6 }   # PY 3 -> 4 el 28/09/2026 (Gonzalo: "paraguay vamos a 4 dias dale"; mediana real en Aloha)

# ---- plan_compras.xlsx
$pcx = Join-Path $aqui 'plan_compras.xlsx'
$prog = @(Tabla $pcx 'cargas_programadas' | ForEach-Object { $d = Fecha $_.fecha; [PSCustomObject]@{ origen = $_.origen; productor = $_.productor; carga = (Ymd $d); semana_carga = (Ymd $d.AddDays(-[int]$d.DayOfWeek)); cajas = [int]$_.cajas; descarga = $(if ($_.PSObject.Properties.Name -contains 'descarga' -and ([string]$_.descarga).Trim()) { Ymd (Fecha $_.descarga) } else { $null }); transportista = $_.transportista; nota = $_.nota; parcial = ([int]$_.cajas -lt 600) } })   # [08/10/2026] < 600 cajas = carga parcial (p. ej. 12 pallets en camion mixto): suma cajas, no cuenta como camion
$ventas = @(Tabla $pcx 'ventas_plan' | ForEach-Object { [PSCustomObject]@{ semana_lunes = (Ymd (Fecha $_.semana_lunes)); BR = [int]$_.br; PY = [int]$_.py; BO = [int]$_.bo; fuente = $_.fuente } })
# venta REAL por semana y origen (hoja ventas_semanales, transcrita del reporte semanal del ERP; 29/09/2026). Opcional.
$ventasReales = @()
try { $ventasReales = @(Tabla $pcx 'ventas_semanales' | Where-Object { $_.semana_lunes -and (Fecha $_.semana_lunes) } | ForEach-Object { [PSCustomObject]@{ semana_lunes = (Ymd (Fecha $_.semana_lunes)); BR = [int]$_.br; PY = [int]$_.py; BO = [int]$_.bo; EC = [int]$_.ec; TODO = ([int]$_.br + [int]$_.py + [int]$_.bo); fuente = $_.fuente } }) } catch { Write-Host "    (sin hoja ventas_semanales: $($_.Exception.Message))" -ForegroundColor DarkYellow }
$conteoRows = @(Tabla $pcx 'conteo' | ForEach-Object { [PSCustomObject]@{ fecha = (Ymd (Fecha $_.fecha)); origen = $_.origen; cajas = [int]$_.cajas; fuente = $_.fuente } })
$fechaConteo = ($conteoRows | ForEach-Object { $_.fecha } | Sort-Object | Select-Object -Last 1)
$conteo = [ordered]@{ fecha = $fechaConteo }; foreach ($c in ($conteoRows | Where-Object { $_.fecha -eq $fechaConteo })) { $conteo[$c.origen] = $c.cajas }
$conteo.fuente = ($conteoRows | Where-Object { $_.fecha -eq $fechaConteo } | Select-Object -First 1).fuente
# [11/10/2026] CONTEO AUTOMATICO desde Aloha (fuentes\aloha_camaras.json, lector plan_compras\aloha_datos.ps1, paso 5j0):
#     si el mapa de camaras de Aloha es mas nuevo que la hoja conteo, manda. fecha = dia del ultimo conteo (contado_hasta
#     de ZAC/CR). La hoja conteo queda como respaldo manual (fotos de las planillas de camaras).
$alohaCam = Join-Path $repo 'fuentes\aloha_camaras.json'
if (Test-Path $alohaCam) {
    try {
        $ac = Get-Content $alohaCam -Raw -Encoding UTF8 | ConvertFrom-Json
        $fechasC = @(); foreach ($s in $ac.sedes.PSObject.Properties) { if ($s.Value.contado_hasta) { $fechasC += [DateTime]$s.Value.contado_hasta } }
        if ($fechasC.Count -gt 0 -and $ac.porOrigen) {
            $fAc = ($fechasC | Sort-Object | Select-Object -Last 1)
            if ((Ymd $fAc) -gt $fechaConteo) {
                $conteo = [ordered]@{ fecha = (Ymd $fAc) }
                foreach ($o in 'BR', 'PY', 'BO', 'EC') { $conteo[$o] = [int]$ac.porOrigen.$o }
                $conteo.fuente = "Aloha mapa-camaras (contado hasta $($fAc.ToString('dd/MM HH:mm')))"
                $conteo.contado_hasta = $fAc.ToString('yyyy-MM-dd HH:mm')
                # [12/10/2026] tipo de conteo: 'cierre' = sabado, domingo o lunes antes de las 08:00 (semana cerrada, sin venta
                # encima); 'parcial' = tomado con la semana ya vendiendo (el plan prorratea la venta de esa semana). Los mensajes
                # dicen cual se uso. Gonzalo: "dale hacemos todo eso" (cambio 2 de la lista conjunta).
                $conteo.tipo = $(if ($fAc.DayOfWeek -eq [DayOfWeek]::Saturday -or $fAc.DayOfWeek -eq [DayOfWeek]::Sunday -or ($fAc.DayOfWeek -eq [DayOfWeek]::Monday -and $fAc.Hour -lt 8)) { 'cierre' } else { 'parcial' })
                # [12/10/2026] CONTEO DE REFERENCIA FIJO (cambio 2): si el conteo fisico es parcial (lunes/martes con la semana ya
                # vendiendo) y hay un cierre del sabado anterior (aloha_camaras.json > ultimo_cierre = stock ERP al sabado 23:59,
                # que coincide con el conteo fisico del sabado: 27.462 vs 27.488 el 10/10), se arranca de ese cierre: la semana se
                # cuenta entera (venta completa, descargas desde el domingo) y no depende de a que hora corrio el pipeline. Mas de
                # 2 dias despues del sabado (miercoles, viernes) vale el conteo fisico del dia, que ya trae la realidad de la semana.
                if ($conteo.tipo -eq 'parcial' -and $ac.PSObject.Properties.Name -contains 'ultimo_cierre' -and $ac.ultimo_cierre -and $ac.ultimo_cierre.sabado -and $ac.ultimo_cierre.porOrigen) {
                    $fSab = ([DateTime]$ac.ultimo_cierre.sabado).Date
                    if (($fAc.Date - $fSab).TotalDays -le 2 -and ($fAc.Date - $fSab).TotalDays -ge 0) {
                        $conteo = [ordered]@{ fecha = (Ymd $fSab) }
                        foreach ($o in 'BR', 'PY', 'BO', 'EC') { $conteo[$o] = [int]$ac.ultimo_cierre.porOrigen.$o }
                        $conteo.fuente = "Aloha stock ERP al cierre del sab $($fSab.ToString('dd/MM')) 23:59 (ultimo_cierre; el conteo fisico del $($fAc.ToString('dd/MM HH:mm')) era parcial)"
                        $conteo.contado_hasta = $fSab.ToString('yyyy-MM-dd') + ' 23:59'
                        $conteo.tipo = 'cierre'
                        $fechaConteo = $conteo.fecha
                    }
                }
                $fechaConteo = $conteo.fecha
            }
        }
    } catch { Write-Host "  (aviso) aloha_camaras.json ilegible: $($_.Exception.Message)" }
}
# [22/10/2026] BASE FIJA DEL ERP (Gonzalo: "que tenemos que corregir para que no vuelva a pasar" -> "dale hacemos esas dos").
#     El conteo de camaras a mitad de semana es parcial y se mueve cada dia (el 15/10 y el 16/10 salieron dos mensajes con
#     arranques distintos). Con la semana ya vendiendo, la base es el ERP de Aloha: cierre del sabado anterior + ingresos reales
#     - venta real - descartes = stock ERP de ahora (aloha_ventas.json, semana parcial). Lo que falta = camiones dictados que
#     Aloha todavia no dio por descargados (cruce mas abajo) y la venta que falta = venta de la semana - venta real.
#     Sin semana parcial (sabado tarde, domingo, lunes antes de vender) queda el conteo de arriba.
$alohaVenE = Join-Path $repo 'fuentes\aloha_ventas.json'
try {
    if ((Test-Path $alohaVenE) -and $ac -and $ac.ultimo_cierre -and $ac.ultimo_cierre.sabado) {
        $avE = Get-Content $alohaVenE -Raw -Encoding UTF8 | ConvertFrom-Json
        $sabE = ([DateTime]$ac.ultimo_cierre.sabado).Date; $lunE = $sabE.AddDays(2)
        $parE = @($avE.semanas | Where-Object { $_.parcial -and [string]$_.semana_lunes -eq (Ymd $lunE) }) | Select-Object -First 1
        if ($parE -and ((Get-Date).Date - $sabE).TotalDays -le 7) {
            $hastaE = ([DateTime]$parE.hasta).Date
            $conteoAntes = $conteo; $fechaAntes = $fechaConteo
            $conteo = [ordered]@{ fecha = (Ymd $hastaE); modo = 'erp' }
            foreach ($o in 'BR', 'PY', 'BO', 'EC') { $conteo[$o] = [int]$parE.$o.stock }
            $conteo.base_sabado = (Ymd $sabE); $conteo.base_cajas = [int]$ac.ultimo_cierre.madera_bo
            $conteo.ingresos_semana = 0; $conteo.venta_real_semana = 0; $conteo.descartes_semana = 0
            $conteo.venta_real = [ordered]@{}
            foreach ($o in 'BR', 'PY', 'BO') { $conteo.ingresos_semana += [int]$parE.$o.ingresos; $conteo.venta_real_semana += [int]$parE.$o.present; $conteo.descartes_semana += [int]$parE.$o.descartes; $conteo.venta_real[$o] = [int]$parE.$o.present }
            $conteo.contado_hasta = $(if ($avE.generado) { ([DateTime]$avE.generado).ToString('yyyy-MM-dd HH:mm') } else { (Ymd $hastaE) })
            $conteo.tipo = 'erp'
            $conteo.fuente = "Aloha ERP: cierre sab $($sabE.ToString('dd/MM')) $($conteo.base_cajas) + ingresos $($conteo.ingresos_semana) - venta $($conteo.venta_real_semana) - descartes $(-$conteo.descartes_semana) (lun a $($hastaE.ToString('dd/MM')))"
            $fechaConteo = $conteo.fecha
        }
    }
} catch { Write-Host "  (aviso) base ERP no disponible: $($_.Exception.Message)" -ForegroundColor DarkYellow }
# [22/10/2026] cuando se leyo Aloha por ultima vez (aloha_datos.ps1): los mensajes no salen si tiene mas de 24 horas
$alohaLeido = $null
try { if (Test-Path $alohaVenE) { $gL = (Get-Content $alohaVenE -Raw -Encoding UTF8 | ConvertFrom-Json).generado; if ($gL) { $alohaLeido = ([DateTime]$gL).ToString('yyyy-MM-dd HH:mm') } } } catch {}
# [11/10/2026] VENTA REAL desde Aloha (fuentes\aloha_ventas.json, /stock/ventas-presentacion por semana lun-sab):
#     reemplaza a la hoja ventas_semanales (transcripcion de fotos) cuando existe. Semanas parciales no cuentan.
$alohaVen = Join-Path $repo 'fuentes\aloha_ventas.json'
if (Test-Path $alohaVen) {
    try {
        $av = Get-Content $alohaVen -Raw -Encoding UTF8 | ConvertFrom-Json
        $vr = @($av.semanas | Where-Object { -not $_.parcial } | ForEach-Object { [PSCustomObject]@{ semana_lunes = [string]$_.semana_lunes; BR = [int]$_.venta_cajas.BR; PY = [int]$_.venta_cajas.PY; BO = [int]$_.venta_cajas.BO; EC = [int]$_.venta_cajas.EC; TODO = ([int]$_.venta_cajas.BR + [int]$_.venta_cajas.PY + [int]$_.venta_cajas.BO); fuente = 'Aloha ventas-presentacion' } })
        if ($vr.Count -gt 0) { $ventasReales = $vr }
    } catch { Write-Host "  (aviso) aloha_ventas.json ilegible: $($_.Exception.Message)" }
}
# [11/10/2026] VENTA PREVISTA AUTOMATICA (Gonzalo: "vamos por el 1"): para las semanas de ventas_plan con fuente AUTO o
#     SUPUESTO (y para las semanas futuras sin fila) la venta = promedio real de las ultimas 10 semanas completas de Aloha
#     (BR+PY+BO, redondeado a 100), repartido con el mix real de esas semanas. Las filas con fuente "Gonzalo ..." o "REAL ..."
#     no se tocan: si Gonzalo dicta una semana, manda la suya.
$ultV = @($ventasReales | Where-Object { $_.TODO -gt 0 } | Sort-Object semana_lunes | Select-Object -Last 10)
if ($ultV.Count -ge 4) {
    $sBR = ($ultV | Measure-Object BR -Sum).Sum; $sPY = ($ultV | Measure-Object PY -Sum).Sum; $sBO = ($ultV | Measure-Object BO -Sum).Sum; $sT = $sBR + $sPY + $sBO
    $promV = [int]([math]::Round(($sT / $ultV.Count) / 100) * 100)
    $notaV = "AUTO: promedio real de las ultimas $($ultV.Count) semanas (Aloha, $($ultV[0].semana_lunes) a $($ultV[-1].semana_lunes)) = $promV"
    $aBR = [int][math]::Round($promV * $sBR / $sT); $aPY = [int][math]::Round($promV * $sPY / $sT); $aBO = $promV - $aBR - $aPY
    foreach ($v in $ventas) { if ([string]$v.fuente -match '^(AUTO|SUPUESTO)') { $v.BR = $aBR; $v.PY = $aPY; $v.BO = $aBO; $v.fuente = $notaV } }
    $lunV0 = (Get-Date).Date; $lunV0 = $(if ($lunV0.DayOfWeek -eq [DayOfWeek]::Sunday) { $lunV0.AddDays(1) } else { $lunV0.AddDays(-((([int]$lunV0.DayOfWeek) + 6) % 7)) })
    for ($w = 0; $w -le 9; $w++) {
        $k = Ymd $lunV0.AddDays(7 * $w)
        if (-not @($ventas | Where-Object { $_.semana_lunes -eq $k }).Count) { $ventas += [PSCustomObject]@{ semana_lunes = $k; BR = $aBR; PY = $aPY; BO = $aBO; fuente = $notaV } }
    }
    $ventas = @($ventas | Sort-Object semana_lunes)
    # [12/10/2026] ESTACIONALIDAD (cambio 4 de la lista conjunta; Gonzalo: "dale hacemos todo eso"): fuentes\ventas_vs_descargas.json
    #     (otra ventana) trae por semana del año factor_madera_bo = venta suavizada de esa semana / promedio de todas (1,00 = semana
    #     promedio; maximos ~1,25 en enero, minimos ~0,78 en junio-julio). La venta AUTO deja de ser el promedio plano de 10 semanas:
    #     base = promedio de esas 10 semanas desestacionalizado (cada una dividida por su factor) y venta(n) = base x factor(n).
    #     Si el archivo no esta o no trae factores, queda el promedio plano.
    $vdF = Join-Path $repo 'fuentes\ventas_vs_descargas.json'; $factores = @{}
    try { if (Test-Path $vdF) { $vd = Get-Content $vdF -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($cc in @($vd.calendario)) { if ($null -ne $cc.factor_madera_bo -and [double]$cc.factor_madera_bo -gt 0) { $factores[[int]$cc.n] = [double]$cc.factor_madera_bo } } } } catch { Write-Host "  (aviso) ventas_vs_descargas.json ilegible: $($_.Exception.Message)" }
    function SemanaNDe($k) { $d = [DateTime]$k; return [int][math]::Floor(($d.DayOfYear - 1) / 7) + 1 }
    if ($factores.Count -ge 40) {
        $des = @(); foreach ($u in $ultV) { $nU = SemanaNDe $u.semana_lunes; if ($factores.ContainsKey($nU)) { $des += ([double]$u.TODO / $factores[$nU]) } }
        if ($des.Count -ge 4) {
            $baseDes = [int]([math]::Round((($des | Measure-Object -Average).Average) / 100) * 100)
            $nEst = 0
            foreach ($v in $ventas) {
                if ([string]$v.fuente -ne $notaV) { continue }
                $nV = SemanaNDe $v.semana_lunes; if (-not $factores.ContainsKey($nV)) { continue }
                $fV = $factores[$nV]; $estV = [int]([math]::Round(($baseDes * $fV) / 100) * 100)
                # [18/10/2026] Gonzalo: "18 mil es el promedio semanal minimo": piso de la venta automatica (supuestos > venta_minima_semana)
                if ($null -eq $pisoV) { $pisoV = 0; try { foreach ($sx in @(Tabla $pcx 'supuestos')) { if ([string]$sx.clave -eq 'venta_minima_semana') { $pisoV = [int]$sx.valor } } } catch {} }; if ($estV -lt $pisoV) { $estV = $pisoV }
                $v.BR = [int][math]::Round($estV * $sBR / $sT); $v.PY = [int][math]::Round($estV * $sPY / $sT); $v.BO = $estV - $v.BR - $v.PY
                $v.fuente = "AUTO: estacional = $baseDes (promedio 10 sem desestacionalizado) x $($fV.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) (factor sem $nV) = $estV; Aloha $($ultV[0].semana_lunes) a $($ultV[-1].semana_lunes)"
                $nEst++
            }
            Write-Host "  venta prevista estacional: base $baseDes x factor de la semana ($nEst semanas AUTO)"
        }
    }
    Write-Host "  venta prevista automatica: $promV/sem (mix BR $aBR / PY $aPY / BO $aBO) para las semanas AUTO"
}
# [11/10/2026] VENTA DE LA SEMANA EN CURSO con los dias reales (regla del miercoles de Gonzalo: "lunes, martes y miercoles,
#     se suma la venta de esos 3 dias y se multiplica por dos"; verificada en 16 semanas: jue-sab vende 0,99 x lun-mie,
#     error medio 5,5 %). Con los "dias" de aloha_ventas.json (semana en curso, madera+BO): si los dias vendidos son
#     justo lun-mar-mie, venta estimada = x2 (la regla de Gonzalo); si no, suma / participacion de esos dias (reparto
#     promedio de 16 semanas, 15/06-28/09/2026). Redondeada a 100. Un dia pasado con menos del 20 % de lo esperado
#     (feriado/cerrado) no cuenta; el dia de hoy cuenta solo si ya tiene la mitad de lo esperado (la corrida del
#     miercoles es a las 12:00). Hace falta por lo menos 2 dias (o sea, desde el miercoles). Pisa la fila de la semana en
#     curso (AUTO o dictada; la venta dictada es un pronostico y esto es la venta real) y guarda lo previsto en 'base',
#     para que el aviso de compras diga "se vendio N camiones mas/menos en 3 dias".
$sharesDia = @{ 1 = 0.239; 2 = 0.112; 3 = 0.155; 4 = 0.189; 5 = 0.215; 6 = 0.089 }
$nomDia = @('lun', 'mar', 'mié', 'jue', 'vie', 'sáb')
if ($av -and $av.semanas) {
    $hoyV = (Get-Date).Date
    $lunHoyV = $(if ($hoyV.DayOfWeek -eq [DayOfWeek]::Sunday) { $hoyV.AddDays(1) } else { $hoyV.AddDays(-((([int]$hoyV.DayOfWeek) + 6) % 7)) })
    $kHoyV = Ymd $lunHoyV
    $semAct = @($av.semanas | Where-Object { [string]$_.semana_lunes -eq $kHoyV }) | Select-Object -First 1
    if ($semAct -and ($semAct.PSObject.Properties.Name -contains 'dias') -and $semAct.dias) {
        $filaV = @($ventas | Where-Object { $_.semana_lunes -eq $kHoyV }) | Select-Object -First 1
        $baseV = 0; if ($filaV) { $baseV = [int]$filaV.BR + [int]$filaV.PY + [int]$filaV.BO }
        $sumV = 0.0; $sumS = 0.0; $usados = @(); $saltados = @()
        foreach ($dd in @($semAct.dias)) {
            $fd = ([DateTime]$dd.fecha).Date; $dow = [int]$dd.dow
            if ($fd -gt $hoyV -or -not $sharesDia.ContainsKey($dow)) { continue }
            $vd = [double]$dd.BR + [double]$dd.PY + [double]$dd.BO
            $umbral = $(if ($fd -eq $hoyV) { 0.5 } else { 0.2 })
            if ($baseV -gt 0 -and $vd -lt $umbral * $sharesDia[$dow] * $baseV) { $saltados += $nomDia[$dow - 1]; continue }
            $sumV += $vd; $sumS += $sharesDia[$dow]; $usados += $nomDia[$dow - 1]
        }
        if ($filaV -and $usados.Count -ge 2 -and $sumS -gt 0) {
            $regla = (($usados -join '-') -eq 'lun-mar-mié')
            $estV = $(if ($regla) { [int]([math]::Round((2 * $sumV) / 100) * 100) } else { [int]([math]::Round(($sumV / $sumS) / 100) * 100) })
            $prevDias = [int][math]::Round($baseV * $sumS)
            $mBR = [int]$filaV.BR; $mPY = [int]$filaV.PY; $mBO = [int]$filaV.BO; $mT = $mBR + $mPY + $mBO
            if ($mT -le 0) { $mBR = 6; $mPY = 3; $mBO = 1; $mT = 10 }
            $fuenteBase = [string]$filaV.fuente
            # [15/10/2026] Gonzalo: "esta semana se va a vender 18 mil... calcula eso": si la venta de la semana la dicto el (fuente
            # "Gonzalo ..."), vale la suya; la estimacion con los dias reales queda solo como comparacion para el aviso del miercoles.
            $dictadaG = ([string]$filaV.fuente -match '^Gonzalo')
            if (-not $dictadaG) {
                $filaV.BR = [int][math]::Round($estV * $mBR / $mT); $filaV.PY = [int][math]::Round($estV * $mPY / $mT); $filaV.BO = $estV - $filaV.BR - $filaV.PY
                $filaV.fuente = "AUTO-dia: estimada con $($usados.Count) dias reales ($($usados -join '-')$(if ($regla) { ' x2' } else { ', reparto por dia' })) = $estV; prevista $baseV"
            }
            foreach ($kv in @(@('base', $baseV), @('base_fuente', $fuenteBase), @('dias_usados', ($usados -join '-')), @('dias_saltados', ($saltados -join '-')), @('real_dias', [int][math]::Round($sumV)), @('prevista_dias', $prevDias), @('regla_x2', $regla))) {
                Add-Member -InputObject $filaV -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force
            }
            Write-Host "  venta semana en curso ($kHoyV) estimada con $($usados.Count) dias reales ($($usados -join '-')): $estV (prevista $baseV; dias $([int][math]::Round($sumV)) vs $prevDias)$(if ($saltados.Count) { "; sin contar: $($saltados -join '-')" })$(if ($dictadaG) { ' - la venta dictada por Gonzalo se mantiene' })"
        }
    }
}
# ---- plan Brasil/Paraguay (master o export Aloha)
function Leer-Plan($path, $hojas) { foreach ($h in $hojas) { $r = Read-XlsxHoja -Path $path -Hoja $h; if ($r.Count -ge 2) { return $r } }; return @() }
$camiones = @()
$pc = Get-ChildItem "$repo\fuentes\plan_cargas\*.xlsx" | Where-Object { $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$rows = Leer-Plan $pc.FullName @('Cargas', 'Plan de cargas')
$hdrIdx = -1; for ($i = 0; $i -lt [math]::Min(15, $rows.Count); $i++) { $j = (@($rows[$i]) -join '|'); if ($j -match 'Status' -and $j -match 'Productor') { $hdrIdx = $i; break } }
if ($hdrIdx -lt 0) { throw "sin encabezado Status/Productor en $($pc.Name)" }
$hdr = @($rows[$hdrIdx])
function Col($rx) { for ($k = 0; $k -lt $hdr.Count; $k++) { if (([string]$hdr[$k]) -match $rx) { return $k } }; return -1 }
function Cel($f, $c) { if ($c -ge 0 -and $c -lt $f.Count) { return ([regex]::Replace([string]$f[$c], '\s+', ' ')).Trim() } else { return '' } }
$cSt = Col '^\s*Status'; $cPr = Col '^\s*Productor'; $cFc = Col 'Fecha\s*(de\s*)?Carga'; $cMic = Col 'Cajas\s*MIC'; $cFd = Col 'Fecha\s*Desc'; $cTr = Col 'Transportista'
for ($r = $hdrIdx + 1; $r -lt $rows.Count; $r++) {
    $f = @($rows[$r]); $st = Cel $f $cSt; $pr = Cel $f $cPr; if (-not $st -or -not $pr) { continue }
    if ($st -match '^Cancelado|^Destruida') { continue }
    if ($pr -match '(?i)varios|exotic|bahia \+') { continue }
    $fc = Fecha $f[$cFc]; if (-not $fc -or $fc -lt (Get-Date '2026-08-01')) { continue }
    $orig = if ($pr -match '(?i)^paraguay|\spy$') { 'PY' } elseif ($pr -match '(?i)^bolivia') { 'BO' } else { 'BR' }
    $mic = 0; [void][int]::TryParse(((Cel $f $cMic) -replace '[^\d]', ''), [ref]$mic); if ($mic -le 0) { $mic = $(if ($orig -eq 'PY') { 980 } else { 1008 }) }
    $fd = Fecha $f[$cFd]; $real = ($st -match '^(Descargado|Arribado)')
    $camiones += [PSCustomObject]@{ origen = $orig; productor = $pr; carga = (Ymd $fc); semana_carga = (Ymd $fc.Date.AddDays(-[int]$fc.DayOfWeek)); cajas = $mic; status = $st; descarga = $(if ($real -and $fd) { Ymd $fd } else { $null }); transportista = (Cel $f $cTr); fuente = 'plan_cargas' }
}
$nBRPY = $camiones.Count

# ---- Bolivia: export de Aloha fuente OTROS (Pais = BO)
$pcO = Get-ChildItem "$repo\fuentes\plan_cargas\otros\*.xlsx" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$nBO = 0
if ($pcO) {
    $rowsO = Leer-Plan $pcO.FullName @('Plan de cargas', 'Cargas')
    $hdr = @($rowsO[0])
    $oSt = Col '^\s*Status'; $oPais = Col '^\s*Pa'; $oFc = Col 'Fecha\s*(de\s*)?Carga'; $oMic = Col 'Cajas\s*MIC'; $oFd = Col 'Fecha\s*Desc'; $oTr = Col 'Transportista'; $oEx = Col '^\s*Exportador'
    for ($r = 1; $r -lt $rowsO.Count; $r++) {
        $f = @($rowsO[$r]); $st = Cel $f $oSt; if (-not $st) { continue }
        if ((Cel $f $oPais) -ne 'BO') { continue }
        if ($st -match '^Cancelado|^Destruida') { continue }
        $fc = Fecha $f[$oFc]; if (-not $fc -or $fc -lt (Get-Date '2026-08-01')) { continue }
        # [27/10/2026] Gonzalo: "a partir de esta semana no descargamos mas boliviana"; el Banexfrut cargado el sab 24/10 (descarga sab 31) es el ultimo
        if ($fc.Date -gt (Get-Date '2026-10-24')) { continue }
        $mic = 0; [void][int]::TryParse(((Cel $f $oMic) -replace '[^\d]', ''), [ref]$mic); if ($mic -le 0) { $mic = 1050 }
        $fd = Fecha $f[$oFd]; $real = ($st -match '^(Descargado|Arribado)')
        $ex = Cel $f $oEx; if (-not $ex) { $ex = 'Bolivia' }
        $camiones += [PSCustomObject]@{ origen = 'BO'; productor = $ex; carga = (Ymd $fc); semana_carga = (Ymd $fc.Date.AddDays(-[int]$fc.DayOfWeek)); cajas = $mic; status = $st; descarga = $(if ($real -and $fd) { Ymd $fd } else { $null }); transportista = (Cel $f $oTr); fuente = 'plan_cargas_otros' }
        $nBO++
    }
}

# ---- dictadas: MANDA EL DICTADO de Gonzalo  [regla 06/10/2026; reemplaza a la del 24/09]
# 24/09: una dictada se omitia si Aloha ya tenia una carga de ese productor (nombre o alias de
# fuentes\productores.xlsx) en esa misma semana de carga: "lo que Aloha tiene manda". El 06/10 Aloha
# trajo las cargas de la semana un dia mas tarde que lo dictado (jueves en vez de miercoles) y 6
# camiones se corrieron al sabado siguiente. Gonzalo: "manda mi dictado, siempre es asi". Ahora:
#   - Aloha 'Solicitado' (todavia no cargo) del mismo productor y semana: la fila de Aloha se REEMPLAZA
#     por la dictada (fecha, cajas y transportista del dictado). Se emparejan por orden de fecha.
#   - Aloha ya cargado o descargado (Frontera, Puerto, Arribado, Descargado...): es un hecho, queda como
#     esta y la dictada correspondiente se omite para no contar dos veces.
#   - Lo que Aloha ya tiene CARGADO y no fue dictado (por ejemplo un segundo camion) se suma igual. Una 'Solicitado'
#     sin dictada, en una semana/origen que si fue dictada, se descarta: el dictado es el plan de esa semana.
$maxPlan = @{}
foreach ($o in 'BR', 'PY', 'BO') { $maxPlan[$o] = ($camiones | Where-Object { $_.origen -eq $o } | ForEach-Object { [DateTime]$_.carga } | Sort-Object | Select-Object -Last 1) }
function Norm($s) { $t = ([string]$s).ToLower().Trim().Normalize([Text.NormalizationForm]::FormD); $sb = New-Object Text.StringBuilder; foreach ($ch in $t.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) } }; return [regex]::Replace($sb.ToString(), '\s+', ' ') }
$canonMap = @{}
$prodX = Join-Path $repo 'fuentes\productores.xlsx'
if (Test-Path $prodX) {
    foreach ($pr in @(Tabla $prodX 'productores')) {
        if (-not $pr.productor) { continue }
        $canonMap[(Norm $pr.productor)] = $pr.productor
        foreach ($a in ([string]$pr.alias -split ';')) { if ($a.Trim()) { $canonMap[(Norm $a)] = $pr.productor } }
    }
}
function Canon($name) {
    $n = Norm $name
    if ($canonMap.ContainsKey($n)) { return $canonMap[$n] }
    foreach ($k in $canonMap.Keys) { if ($k.Length -ge 4 -and ($n.Contains($k) -or $k.Contains($n))) { return $canonMap[$k] } }
    return $n
}
# [09/10/2026] SOLO EL DICTADO. Gonzalo: "con Aloha nada, las cargas son las que te doy yo, ya lo hablamos". Regla:
#   - En cada (origen, semana de carga) con al menos una carga dictada, se descartan TODAS las filas de Aloha de ese
#     origen y esa semana (Solicitado, Cargado, Frontera, Descargado...) y valen las dictadas, con sus fechas.
#   - Aloha queda solo para lo que no se dicta: Bolivia (fuente OTROS) y semanas sin ninguna carga dictada del origen.
#   (El 06/10 se habia dejado que lo ya cargado/descargado en Aloha mandara sobre el dictado; eso se saco.)
$dictOW = @{}; foreach ($p in $prog) { $dictOW[([string]$p.origen) + '|' + $p.semana_carga] = $true }
# [22/10/2026] REPETIDOS EN EL DICTADO (Gonzalo: "dale"; el 15/10 Gilson salio dos veces el sabado 24): mismo productor y misma fecha de
#     carga mas de una vez. No se borra nada (puede haber dos camiones de verdad): se avisa y queda en duplicados_dictado para preguntar.
$duplicados = @($prog | Where-Object { -not $_.parcial -and [DateTime]$_.carga -ge (Get-Date).Date.AddDays(-7) } | Group-Object { "$(Canon $_.productor)|$($_.carga)" } | Where-Object { $_.Count -gt 1 } | ForEach-Object { [ordered]@{ productor = $_.Group[0].productor; carga = $_.Group[0].carga; veces = $_.Count } })
foreach ($dp in $duplicados) { Write-Host "  (REVISAR) $($dp.productor) aparece $($dp.veces) veces cargando el $($dp.carga): ¿son $($dp.veces) camiones?" -ForegroundColor Yellow }
$quitar = @{}; $descartadas = 0
for ($i = 0; $i -lt $camiones.Count; $i++) { $c = $camiones[$i]; if ($dictOW.ContainsKey(([string]$c.origen) + '|' + $c.semana_carga)) { $quitar[$i] = $true; $descartadas++ } }
$usadas = 0; $omitidas = 0; $reemplazadas = 0
foreach ($p in ($prog | Sort-Object carga)) {
    $camiones += [PSCustomObject]@{ origen = $p.origen; productor = $p.productor; carga = $p.carga; semana_carga = $p.semana_carga; cajas = $p.cajas; status = $(if ($p.descarga) { 'Descargado' } else { 'programado' }); descarga = $p.descarga; transportista = $p.transportista; fuente = 'plan_compras'; nota = [string]$p.nota; parcial = [bool]$p.parcial }
    $usadas++
}
# [12/10/2026] PLAN VS REAL (cambio 3 de la lista conjunta; Gonzalo: "dale hacemos todo eso"): las filas de Aloha que se
# descartan por "solo el dictado" se guardan aparte ($sombraAloha) para comparar, semana a semana, lo dictado con lo que
# Aloha registro (llego esa semana / otra semana / no aparecio / cancelado). No cambia el plan: solo mide el acierto.
$sombraAloha = @(for ($i = 0; $i -lt $camiones.Count; $i++) { if ($quitar.ContainsKey($i)) { $camiones[$i] } })
if ($quitar.Count -gt 0) { $camiones = @(for ($i = 0; $i -lt $camiones.Count; $i++) { if (-not $quitar.ContainsKey($i)) { $camiones[$i] } }) }

# [22/10/2026] CRUCE CON ALOHA (Gonzalo: "dale hacemos esas dos"): cada camion se busca en fuentes\aloha_plan_cargas.json
#     (GET /plan-cargas, lo baja aloha_datos.ps1) por origen, productor y fecha de carga (+-3 dias). estado_aloha:
#     descargado / en_camino (cargado, liberado, frontera...) / solicitado / cancelado / no_figura. No cambia las fechas del
#     dictado: solo marca. Lo descargado queda en_stock (ya esta en el ERP: la cuenta no lo vuelve a sumar). Si el archivo
#     tiene mas de 36 horas no se marca nada y la cuenta queda como antes.
$cruceAloha = [ordered]@{ ok = $false }
$apcF = Join-Path $repo 'fuentes\aloha_plan_cargas.json'
try {
    if (Test-Path $apcF) {
        $apc = Get-Content $apcF -Raw -Encoding UTF8 | ConvertFrom-Json
        $apcGen = [DateTime]$apc.generado
        $cruceAloha.generado = $apc.generado
        if (((Get-Date) - $apcGen).TotalHours -le 36) {
            $alR = @(foreach ($a in @($apc.cargas)) {
                $pa = [string]$a.pais; $pr = [string]$a.productor
                if ($pr -match '(?i)^varios|exotic') { continue }
                $o = $(if ($pa -eq 'BO') { 'BO' } elseif ($pa -in '', 'BR', 'PY') { $(if ($pr -match '(?i)^paraguay') { 'PY' } else { 'BR' }) } else { $null })
                if (-not $o -or -not $a.carga) { continue }
                [PSCustomObject]@{ o = $o; k = $(if ($o -eq 'BO') { 'bolivia' } else { Canon $pr }); carga = [DateTime]$a.carga; st = [string]$a.status; desc = $a.descarga; usado = $false }
            })
            $hoyX = (Get-Date).Date; $nX = @{}
            # misma persona con nombre corto o largo ("Muller" en Aloha, "Muller Fabricio" dictado): se compara tambien la primera palabra
            $k1 = { param($s) $w = @((Norm $s) -split ' ')[0]; if ($w.Length -ge 4) { $w } else { Norm $s } }
            foreach ($r in $alR) { $r | Add-Member -NotePropertyName k1 -NotePropertyValue $(if ($r.o -ne 'BR') { $r.k } else { & $k1 $r.k }) -Force }
            # [30/10/2026] letras de mas en el Excel ("Arysteu Mittelman" = Aryste Mittelman): primera palabra que empieza igual (5+ letras)
            $mismoNombre = { param($a, $b) $a = [string]$a; $b = [string]$b; ($a -eq $b) -or ($a.Length -ge 5 -and $b.Length -ge 5 -and ($a.StartsWith($b) -or $b.StartsWith($a))) }
            $camX = @($camiones | Where-Object { $_.fuente -ne 'supuesto' -and $_.origen -in 'BR', 'PY', 'BO' -and ([DateTime]$_.carga) -ge $hoyX.AddDays(-30) -and -not ($_.PSObject.Properties.Name -contains 'parcial' -and [bool]$_.parcial) } | Sort-Object carga)
            $parX = @{}
            # emparejar primero las fechas exactas, despues +-1, +-2, +-3 dias: un camion no le roba la fila a otro del mismo productor
            foreach ($tol in 0, 1, 2, 3) {
                for ($ix = 0; $ix -lt $camX.Count; $ix++) { $c = $camX[$ix]
                    if ($parX.ContainsKey($ix)) { continue }
                    $kc = $(if ($c.origen -eq 'BO') { 'bolivia' } else { Canon $c.productor }); $kc1 = $(if ($c.origen -ne 'BR') { $kc } else { & $k1 $kc }); $fc = [DateTime]$c.carga   # PY: "Paraguay AS/MS/GM" no se mezclan por la primera palabra
                    $m = @($alR | Where-Object { -not $_.usado -and $_.o -eq $c.origen -and ($_.k -eq $kc -or $_.k1 -eq $kc1 -or ($c.origen -eq 'BR' -and (& $mismoNombre $_.k1 $kc1))) -and [math]::Abs(($_.carga - $fc).TotalDays) -le $tol } | Sort-Object { [int]($_.st -match '^Cancel') }) | Select-Object -First 1
                    if ($m) { $m.usado = $true; $parX[$ix] = $m }
                }
            }
            for ($ix = 0; $ix -lt $camX.Count; $ix++) { $c = $camX[$ix]
                $m = $parX[$ix]
                # sin fila en Aloha: si la carga es futura es normal (Aloha la crea unos dias antes); si ya paso, no figura
                $est = $(if ([DateTime]$c.carga -gt $hoyX) { 'pendiente' } else { 'no_figura' })
                if ($m) {
                    $est = $(if ($m.st -match '^Descargado') { 'descargado' } elseif ($m.st -match '^(Cancel|Destru)') { 'cancelado' } elseif ($m.st -match '^Solicitado') { 'solicitado' } else { 'en_camino' })
                }
                $c | Add-Member -NotePropertyName estado_aloha -NotePropertyValue $est -Force
                if ($m) { $c | Add-Member -NotePropertyName aloha -NotePropertyValue ([ordered]@{ status = $m.st; carga = (Ymd $m.carga); descarga = $m.desc }) -Force }
                if ($est -eq 'descargado') {
                    $c | Add-Member -NotePropertyName en_stock -NotePropertyValue $true -Force
                    if (-not $c.descarga -and $m.desc) { $c.descarga = [string]$m.desc }
                    if ($m.desc -and [string]$c.descarga -ne [string]$m.desc -and [string]$c.fuente -eq 'plan_compras') { $c.descarga = [string]$m.desc }   # el hecho de Aloha manda sobre la fecha estimada a mano
                    $c.status = 'Descargado'
                }
                $nX[$est] = 1 + [int]$nX[$est]
            }
            # [30/10/2026] SEGUNDA VERIFICACION CON LA CAMARA (Gonzalo: "si"): un camion que no figura en el Excel pero cuyo productor ya
            # tiene lote(s) ingresado(s) en el pizarron desde su fecha de carga (700+ cajas) se toma como descargado: ya esta en el stock del
            # ERP y no se cuenta dos veces (el 30/10 el Aryste del 28 salio como pendiente y estaba ingresado: "Arysteu" en el Excel).
            $pzF = Join-Path $repo 'fuentes\aloha_pizarron.json'
            if (Test-Path $pzF) {
                $pz = Get-Content $pzF -Raw -Encoding UTF8 | ConvertFrom-Json
                $lotesPz = @(@($pz.lotes) | Where-Object { $_.productor -and $_.fecha_ingreso } | ForEach-Object { [PSCustomObject]@{ k1 = (& $k1 (Canon ([string]$_.productor))); ing = ([DateTime]$_.fecha_ingreso).Date; cajas = [double]$_.cantidad; usado = $false } })
                foreach ($c in @($camX | Where-Object { $_.estado_aloha -eq 'no_figura' -and $_.origen -eq 'BR' } | Sort-Object carga)) {
                    $kc1 = & $k1 (Canon $c.productor); $fc = ([DateTime]$c.carga).Date
                    $ls = @($lotesPz | Where-Object { -not $_.usado -and $_.ing -ge $fc -and (& $mismoNombre $_.k1 $kc1) } | Sort-Object ing)
                    if (($ls | Measure-Object cajas -Sum).Sum -ge 700) {
                        $acum = 0; foreach ($l in $ls) { if ($acum -ge 700) { break }; $l.usado = $true; $acum += $l.cajas }
                        $c.estado_aloha = 'descargado'; $c | Add-Member -NotePropertyName en_stock -NotePropertyValue $true -Force
                        $c | Add-Member -NotePropertyName verificado_camara -NotePropertyValue $true -Force
                        if (-not $c.descarga) { $c.descarga = Ymd (@($ls | Select-Object -First 1).ing) }
                        $c.status = 'Descargado'; $nX['no_figura'] = [int]$nX['no_figura'] - 1; $nX['descargado'] = 1 + [int]$nX['descargado']
                        Write-Host "  (camara) $($c.productor) cargado $(Ymd $fc): no figura en el Excel pero ingreso en camara ($([int]$acum) cajas) -> descargado" -ForegroundColor DarkYellow
                    }
                }
            }
            # descargados en Aloha esta semana que no se emparejaron con nada (nombre distinto?): avisar, la cuenta del ERP ya los tiene
            $lunX = $hoyX.AddDays(-((([int]$hoyX.DayOfWeek) + 6) % 7))
            $sueltos = @($alR | Where-Object { -not $_.usado -and $_.st -match '^Descargado' -and $_.desc -and ([DateTime]$_.desc) -ge $lunX } | ForEach-Object { "$($_.o) $($_.k) $($_.carga.ToString('dd/MM'))" })
            $cruceAloha.ok = $true; $cruceAloha.estados = $nX; $cruceAloha.descargados_sin_dictado = $sueltos
            Write-Host ("  cruce Aloha ({0}): {1}" -f $apc.generado, (($nX.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · ')) -ForegroundColor Green
            if ($sueltos.Count) { Write-Host "  (aviso) descargados en Aloha esta semana sin dictado que los empareje: $($sueltos -join ', ')" -ForegroundColor DarkYellow }
        } else { Write-Host "  (aviso) aloha_plan_cargas.json tiene mas de 36 horas ($($apc.generado)): sin cruce" -ForegroundColor DarkYellow }
    }
} catch { Write-Host "  (aviso) cruce con Aloha fallo: $($_.Exception.Message)" -ForegroundColor DarkYellow }
if ($conteo.modo -eq 'erp' -and -not $cruceAloha.ok) { $conteo = $conteoAntes; $fechaConteo = $fechaAntes; Write-Host '  (aviso) sin cruce con Aloha: la base vuelve al conteo de camaras' -ForegroundColor DarkYellow }

# ---- grupos [27/09/2026]: Gonzalo pidio unificar la compra Brasil + Paraguay ("para mi es lo mismo una u otra,
#      de ahi despues yo veo que cargar"); Bolivia sigue aparte. El simulador proyecta por grupo; cada camion
#      conserva su origen (bandera en la grilla) y el conteo y la venta se suman.
# ---- supuesto Paraguay [27/09/2026]: "la PY siempre se carga domingo, lunes y martes, o sea que va a entrar en la
#      semana siempre; por lo general estoy cargando 5/6 siempre, tene esto en cuenta". Hoja 'supuestos' de
#      plan_compras.xlsx (clave py_camiones_semana). En las semanas del horizonte que no tengan NINGUNA carga PY
#      (ni del Plan ni dictada) se agregan esos camiones cargados el lunes (llegan el jueves), marcados 'supuesto'.
$supuestos = @{}
try { foreach ($s in @(Tabla $pcx 'supuestos')) { if ($s.clave) { $supuestos[[string]$s.clave] = $s.valor } } } catch {}
$pyPorSemana = 0; if ($supuestos.ContainsKey('py_camiones_semana')) { $pyPorSemana = [int]$supuestos['py_camiones_semana'] }
$nSup = 0
if ($pyPorSemana -gt 0) {
    $dom0 = (Get-Date).Date.AddDays(-[int](Get-Date).DayOfWeek)   # domingo de esta semana
    for ($w = 1; $w -le 3; $w++) {
        $dom = $dom0.AddDays(7 * $w); $kSem = Ymd $dom
        $hayPY = @($camiones | Where-Object { $_.origen -eq 'PY' -and $_.semana_carga -eq $kSem }).Count
        # [01/10/2026] si ya habia cargas PY dictadas pero menos que el ritmo habitual, se completaban con supuestos
        # (Gonzalo dicto solo a Guido para el martes 13 y los otros 4 se dictaban despues).
        # [08/10/2026] YA NO: manda el dictado. Si la semana tiene al menos una carga PY dictada, ese numero es el plan
        # (Gonzalo bajo Paraguay a 3 porque piden USD 8/caja y la regla vieja le sumaba 2 supuestos). Los supuestos
        # quedan solo para semanas sin NINGUNA carga PY dictada ni en el Plan de Aloha.
        $hayPYdict = @($camiones | Where-Object { $_.origen -eq 'PY' -and $_.semana_carga -eq $kSem -and $_.fuente -eq 'plan_compras' }).Count
        if ($hayPYdict -gt 0) { continue }
        $faltanPY = $pyPorSemana - $hayPY
        if ($faltanPY -le 0) { continue }
        $lun = $dom.AddDays(1)
        for ($i = 0; $i -lt $faltanPY; $i++) {
            $camiones += [PSCustomObject]@{ origen = 'PY'; productor = 'Paraguay (supuesto)'; carga = (Ymd $lun); semana_carga = $kSem; cajas = 980; status = 'supuesto'; descarga = $null; transportista = ''; fuente = 'supuesto'; nota = "supuesto: $pyPorSemana camiones PY por semana, cargan dom-lun-mar (Gonzalo 27/09)" }
            $nSup++
        }
    }
}
# ---- supuesto Bolivia [01/10/2026]: "de Bolivia vamos a descargar uno por semana siempre". Clave bo_camiones_semana
#      de la hoja supuestos. Para cada semana de VENTA del horizonte (lunes a sabado) sin ningun camion BO que
#      descargue (ni del Plan OTROS ni dictado), se agrega uno cargado 6 dias antes del lunes (descarga el lunes).
#      01/10 (mas tarde), Gonzalo: "conta una carga por semana siempre de Bolivia": se cuenta aunque la fecha de carga
#      ya haya pasado y Aloha no la tenga todavia (desde la semana en curso).
function LunesDeVenta($d) { if ($d.DayOfWeek -eq [DayOfWeek]::Sunday) { return $d.AddDays(1) }; return $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)) }
$boPorSemana = 0; if ($supuestos.ContainsKey('bo_camiones_semana')) { $boPorSemana = [int]$supuestos['bo_camiones_semana'] }
$nSupBO = 0
if ($boPorSemana -gt 0) {
    $hoyD = (Get-Date).Date
    $lun0 = LunesDeVenta $hoyD
    for ($w = 0; $w -le 4; $w++) {
        $lunV = $lun0.AddDays(7 * $w)
        $hayBO = 0
        foreach ($c in $camiones) {
            if ($c.origen -ne 'BO') { continue }
            $desc = $(if ($c.descarga) { [DateTime]$c.descarga } else { ([DateTime]$c.carga).AddDays($LAG_DESC.BO) })
            if ((LunesDeVenta $desc) -eq $lunV) { $hayBO++ }
        }
        if ($hayBO -gt 0) { continue }
        $cargaS = $lunV.AddDays(-$LAG_DESC.BO)
        $domS = $cargaS.AddDays(-[int]$cargaS.DayOfWeek)
        for ($i = 0; $i -lt $boPorSemana; $i++) {
            $camiones += [PSCustomObject]@{ origen = 'BO'; productor = 'Bolivia (supuesto)'; carga = (Ymd $cargaS); semana_carga = (Ymd $domS); cajas = 1050; status = 'supuesto'; descarga = $null; transportista = ''; fuente = 'supuesto'; nota = "supuesto: $boPorSemana camion BO por semana, descarga el lunes (Gonzalo 01/10)" }
            $nSupBO++
        }
    }
}
$minimoSab = 22500; if ($supuestos.ContainsKey('minimo_cajas_sabado')) { $minimoSab = [int]$supuestos['minimo_cajas_sabado'] }
#      27/09 (mas tarde): "a esas 22.500 le estas sumando Bolivia?": si, el minimo es del stock TOTAL de banana
#      (Brasil + Paraguay + Bolivia). Un solo grupo TODO; el simulador lee grupos/nombres/minimos del JSON, asi
#      que para volver a separar alcanza con cambiar estas lineas.
$GRUPOS = [ordered]@{ TODO = @('BR', 'PY', 'BO') }
$NOMBRES = [ordered]@{ TODO = 'Banana Brasil + Paraguay + Bolivia' }
function GrupoDe($o) { foreach ($k in $GRUPOS.Keys) { if ($GRUPOS[$k] -contains $o) { return $k } }; return $null }
foreach ($c in $camiones) { $c | Add-Member -NotePropertyName grupo -NotePropertyValue (GrupoDe $c.origen) -Force }
# [06/10/2026] 'nombre' para los mensajes de WhatsApp (descargas por dia). Gonzalo: "pone los nombres que usa Aloha":
# el productor tal como lo escribe Aloha para ese canonico de productores.xlsx (el mas frecuente entre las filas del Plan:
# "Fisher" dictado -> "Fischer", "Stein" -> "Osnildo Stein", "Agrocurupa" -> "Corupá"); si Aloha nunca lo tuvo (Celso,
# supuestos) queda el nombre dictado.
$alohaNom = @{}
foreach ($c in $camiones) {
    if ([string]$c.fuente -notlike 'plan_cargas*') { continue }
    $k = Canon $c.productor; $pn = [string]$c.productor
    if (-not $alohaNom.ContainsKey($k)) { $alohaNom[$k] = @{} }
    if (-not $alohaNom[$k].ContainsKey($pn)) { $alohaNom[$k][$pn] = 0 }
    $alohaNom[$k][$pn]++
}
foreach ($c in $camiones) {
    $k = Canon $c.productor; $nm = [string]$c.productor
    if ($alohaNom.ContainsKey($k)) { $nm = ($alohaNom[$k].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
    $c | Add-Member -NotePropertyName nombre -NotePropertyValue $nm -Force
}
# [12/10/2026] HISTORICO 2019-2026 (fuentes\historico_cargas.json, lo arma plan_compras\historico_cargas.ps1 en el paso 5h2):
#     lag y tasa de cancelacion por productor (nombre como lo escribe Aloha) y referencia de camiones por semana de
#     descarga (promedio de los años anteriores). Gonzalo 12/10: "vamos por todas". El lag por productor pisa al del
#     origen solo si el historico tiene 10+ viajes de ese productor con fecha de descarga (BR casi todos 3; BAHIA 7).
$histJ = $null; $histF = Join-Path $repo 'fuentes\historico_cargas.json'
try { if (Test-Path $histF) { $histJ = Get-Content $histF -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { Write-Host "  (aviso) historico_cargas.json ilegible: $($_.Exception.Message)" }
$nLagP = 0
# llave lag_por_productor de la hoja supuestos (1 = usar la mediana historica del productor, 0 = siempre el lag del origen);
# sin la llave, 1. Ojo: con 1, Paraguay GM (mediana 5 dias) cargado un martes llega el domingo y cuenta para la semana siguiente.
$usarLagProd = 1; if ($supuestos.ContainsKey('lag_por_productor')) { $usarLagProd = [int]$supuestos['lag_por_productor'] }
foreach ($c in $camiones) {
    $lagC = $(if ($LAG_DESC.ContainsKey([string]$c.origen)) { [int]$LAG_DESC[[string]$c.origen] } else { 3 })
    $tasaC = $null
    if ($histJ) {
        $nmH = [string]$c.nombre
        # [12/10/2026] Gonzalo: Paraguay "como todo PY" (4 dias para todos; GM a 5 lo movia a la semana siguiente): el lag por
        # productor queda solo para Brasil.
        if ($usarLagProd -and [string]$c.origen -eq 'BR' -and $histJ.lags_productor -and ($histJ.lags_productor.PSObject.Properties.Name -contains $nmH)) { $lagC = [int]$histJ.lags_productor.$nmH; $nLagP++ }
        if ($histJ.cancel_tasa_productor -and ($histJ.cancel_tasa_productor.PSObject.Properties.Name -contains $nmH)) { $tasaC = [double]$histJ.cancel_tasa_productor.$nmH }
    }
    $c | Add-Member -NotePropertyName lag -NotePropertyValue $lagC -Force
    $c | Add-Member -NotePropertyName cancel_tasa -NotePropertyValue $tasaC -Force
}
$refSem = [ordered]@{}
if ($histJ -and $histJ.semanas_ref) {
    $lunR = (Get-Date).Date; $lunR = $(if ($lunR.DayOfWeek -eq [DayOfWeek]::Sunday) { $lunR.AddDays(1) } else { $lunR.AddDays(-((([int]$lunR.DayOfWeek) + 6) % 7)) })
    for ($w = -1; $w -le 9; $w++) {
        $l = $lunR.AddDays(7 * $w); $n = [int][math]::Floor(($l.DayOfYear - 1) / 7) + 1
        $sr = @($histJ.semanas_ref | Where-Object { [int]$_.n -eq $n }) | Select-Object -First 1
        if ($sr) { $refSem[(Ymd $l)] = [ordered]@{ n = $n; prom = [double]$sr.prom; prom_BR = [double]$sr.prom_BR; prom_PY = [double]$sr.prom_PY; min = $sr.min; max = $sr.max; anios = [string]$sr.anios } }
    }
}
if ($histJ) { Write-Host "  historico 2019-2026: lag por productor en $nLagP camiones; referencia semanal para $($refSem.Count) semanas" }foreach ($k in $GRUPOS.Keys) {
    $conteo[$k] = 0; foreach ($o in $GRUPOS[$k]) { $conteo[$k] += [int]$conteo[$o] }
    foreach ($v in $ventas) { $s = 0; foreach ($o in $GRUPOS[$k]) { $s += [int]$v.$o }; $v | Add-Member -NotePropertyName $k -NotePropertyValue $s -Force }
}
# ---- plan vs real por semana de carga (clave = domingo de la semana de carga, como semana_carga), solo semanas cerradas
$hoyP = (Get-Date).Date
$pvrSem = [ordered]@{}
$grupos = @{}
foreach ($p in @($prog | Where-Object { -not $_.parcial })) { $k = [string]$p.semana_carga + '|' + [string]$p.origen + '|' + (Canon $p.productor); if (-not $grupos.ContainsKey($k)) { $grupos[$k] = 0 }; $grupos[$k]++ }
$paso = '^(Descargado|Arribado|Frontera|Puerto|Cargado|Liberado)'
function CntSombra($sem, $orig, $cn, $rx) { return @($sombraAloha | Where-Object { [string]$_.semana_carga -eq $sem -and [string]$_.origen -eq $orig -and (Canon $_.productor) -eq $cn -and ([string]$_.status) -match $rx }).Count }
foreach ($k in ($grupos.Keys | Sort-Object)) {
    $parts = $k -split '\|'; $sem = $parts[0]; $orig = $parts[1]; $cn = $parts[2]; $nd = $grupos[$k]
    try { $dom = [DateTime]$sem } catch { continue }
    if ($dom.AddDays(7) -gt $hoyP) { continue }   # semana de carga todavia abierta
    $kM = Ymd $dom.AddDays(1)
    if (-not $pvrSem.Contains($kM)) { $pvrSem[$kM] = [ordered]@{ dictados = 0; llegaron = 0; otra_semana = 0; no_aparecieron = 0; cancelados_aloha = 0; no_dictados_llegaron = 0; detalle = @() } }
    $na = CntSombra $sem $orig $cn $paso
    $lleg = [math]::Min($nd, $na); $resto = $nd - $lleg
    $otra = 0
    if ($resto -gt 0) {
        foreach ($dd in -7, 7) {
            $semA = Ymd $dom.AddDays($dd); $kA = $semA + '|' + $orig + '|' + $cn
            $libres = (CntSombra $semA $orig $cn $paso) - $(if ($grupos.ContainsKey($kA)) { $grupos[$kA] } else { 0 })
            if ($libres -gt 0) { $u = [math]::Min($resto - $otra, $libres); $otra += $u }
            if ($otra -ge $resto) { break }
        }
    }
    $noAp = $resto - $otra
    $canc = CntSombra $sem $orig $cn '^(Cancelado|Destruida)'
    $extra = [math]::Max(0, $na - $nd)
    $x = $pvrSem[$kM]; $x.dictados += $nd; $x.llegaron += $lleg; $x.otra_semana += $otra; $x.no_aparecieron += $noAp; $x.cancelados_aloha += $canc; $x.no_dictados_llegaron += $extra
    $x.detalle += [ordered]@{ origen = $orig; productor = $cn; dictados = $nd; aloha = $na; llegaron = $lleg; otra_semana = $otra; no_aparecieron = $noAp; cancelados = $canc }
}
$pvrTot = [ordered]@{ semanas = $pvrSem.Count; dictados = 0; llegaron = 0; otra_semana = 0; no_aparecieron = 0; cancelados_aloha = 0; no_dictados_llegaron = 0 }
foreach ($kM in $pvrSem.Keys) { foreach ($f in 'dictados', 'llegaron', 'otra_semana', 'no_aparecieron', 'cancelados_aloha', 'no_dictados_llegaron') { $pvrTot[$f] += $pvrSem[$kM][$f] } }
$pvrTot.acierto_pct = $(if ($pvrTot.dictados) { [math]::Round($pvrTot.llegaron * 100 / $pvrTot.dictados) } else { $null })
$pvrTot.nota = 'Se compara lo dictado (cargas_programadas) con las filas de Aloha de la misma semana de carga, productor y origen, que el plan descarta por "solo el dictado". Llego = Aloha lo tiene cargado/descargado esa semana; otra semana = aparece la semana anterior o siguiente sin dictado propio; no aparecio = Aloha no lo registro; cancelado = Aloha lo marco Cancelado. Solo semanas de carga ya cerradas. Vale a partir de 4-6 semanas de dictado (rige desde el 09/10/2026).'
if ($pvrSem.Count) { Write-Host "  plan vs real: $($pvrSem.Count) semanas cerradas, $($pvrTot.llegaron)/$($pvrTot.dictados) dictados llegaron ($($pvrTot.acierto_pct) %)" }
# ---- (1) descargas por dia de la semana: lun-mie vs jue-sab, por semana de descarga (misma regla de la cuenta: fecha real
#      o carga + lag; lo que cae domingo cuenta para la semana que arranca y se muestra lunes)
$dpd = [ordered]@{}
foreach ($c in $camiones) {
    if ($c.parcial) { continue }
    try { $d = $(if ($c.descarga) { [DateTime]$c.descarga } else { ([DateTime]$c.carga).AddDays([int]$c.lag) }) } catch { continue }
    $lun = LunesDeVenta $d; if ($lun -lt $hoyP.AddDays(-14)) { continue }
    $k = Ymd $lun; if (-not $dpd.Contains($k)) { $dpd[$k] = [ordered]@{ lun_mie = [ordered]@{ camiones = 0; cajas = 0 }; jue_sab = [ordered]@{ camiones = 0; cajas = 0 } } }
    $dia = $(if ($d.DayOfWeek -eq [DayOfWeek]::Sunday) { 1 } else { [int]$d.DayOfWeek })
    $slot = $(if ($dia -le 3) { 'lun_mie' } else { 'jue_sab' })
    $dpd[$k][$slot].camiones++; $dpd[$k][$slot].cajas += [int]$c.cajas
}$out = [ordered]@{
    generado = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    hoy = (Get-Date).ToString('yyyy-MM-dd')
    grupos = $GRUPOS
    nombres = $NOMBRES
    # minimo en CAJAS al cierre del sabado (Gonzalo 27/09/2026: "preciso tener en stock de una semana a otra unas
    # 22/23 mil cajas cerrando el sabado", y Bolivia incluida). Si esta, pisa al minimo por dias de venta.
    # [01/10/2026] 25.000 (Gonzalo: "comienza el calor en Uruguay, levanta las ventas, quieren mantener 25 mil cajas al
    # cierre del sabado contando todo"); clave minimo_cajas_sabado de la hoja supuestos.
    minimos = [ordered]@{ TODO = $minimoSab }
    plan_cargas = [ordered]@{ archivo = $pc.Name; fecha = $pc.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); camiones = $nBRPY; ultima_carga = [ordered]@{ BR = $(if ($maxPlan.BR) { Ymd $maxPlan.BR }); PY = $(if ($maxPlan.PY) { Ymd $maxPlan.PY }) } }
    plan_cargas_otros = [ordered]@{ archivo = $(if ($pcO) { $pcO.Name } else { $null }); fecha = $(if ($pcO) { $pcO.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }); camiones_bo = $nBO; ultima_carga_bo = $(if ($maxPlan.BO) { Ymd $maxPlan.BO }) }
    plan_compras = [ordered]@{ archivo = 'plan_compras\plan_compras.xlsx'; fecha = (Get-Item $pcx).LastWriteTime.ToString('yyyy-MM-dd HH:mm'); dictadas_usadas = $usadas; dictadas_omitidas_por_estar_en_el_plan = $omitidas }
    lags = [ordered]@{ BR = [ordered]@{ descarga = $LAG_DESC.BR; madurar = 7 }; PY = [ordered]@{ descarga = $LAG_DESC.PY; madurar = 7 }; BO = [ordered]@{ descarga = $LAG_DESC.BO; madurar = 7 }; TODO = [ordered]@{ descarga = 3; madurar = 7 } }
    cajas_camion = [ordered]@{ BR = 1008; PY = 980; BO = 1050; TODO = 1000 }
    conteo = $conteo
    cruce_aloha = $cruceAloha
    aloha_leido = $alohaLeido
    duplicados_dictado = $duplicados
    ventas_plan = $ventas
    ventas_reales = $ventasReales
    # [03/10/2026] lo dictado por semana de carga (lunes como clave; domingo = semana que arranca) ANTES de descontar lo que
    # Aloha ya tiene, para el bloque Plan de Cargas del WhatsApp ("Semana del dd/MM: N camiones · Brasil x · Paraguay y")
    dictadas_por_semana = $(
        $h = [ordered]@{}
        foreach ($p in $prog) {
            try { $d = [DateTime]$p.carga } catch { continue }
            $lun = $(if ($d.DayOfWeek -eq [DayOfWeek]::Sunday) { $d.AddDays(1) } else { $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)) })
            $k = Ymd $lun
            if (-not $h.Contains($k)) { $h[$k] = [ordered]@{ BR = 0; PY = 0; BO = 0; n = 0; parciales = 0 } }
            if ($p.parcial) { $h[$k].parciales++; continue }   # [08/10/2026] la parcial no es un camion
            $o = [string]$p.origen; if ($h[$k].Contains($o)) { $h[$k][$o]++ }; $h[$k].n++
        }
        $h
    )
    # [12/10/2026] cancelaciones esperadas por semana de DESCARGA (suma de la tasa historica de cada productor sobre los
    # camiones que todavia no descargaron) y referencia historica de camiones por semana. Para los mensajes ("Margen por
    # cancelaciones: ~1 camion", "Historico sem N: X camiones"). Son estadisticas, no camiones supuestos.
    cancel_esperadas_por_semana = $(
        $h2 = [ordered]@{}
        foreach ($c in $camiones) {
            if ($c.descarga -or ([string]$c.status) -match '^(Descargado|Arribado)' -or $null -eq $c.cancel_tasa) { continue }
            try { $d = ([DateTime]$c.carga).AddDays([int]$c.lag) } catch { continue }
            $lun = $(if ($d.DayOfWeek -eq [DayOfWeek]::Sunday) { $d.AddDays(1) } else { $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)) })
            $k = Ymd $lun; if (-not $h2.Contains($k)) { $h2[$k] = 0.0 }; $h2[$k] = [math]::Round($h2[$k] + [double]$c.cancel_tasa, 2)
        }
        $h2
    )
    referencia_semanal = $refSem
    plan_vs_real = [ordered]@{ semanas = $pvrSem; acumulado = $pvrTot }
    descargas_por_dia = $dpd
    camiones = @($camiones | Sort-Object carga, origen)
}
$json = $out | ConvertTo-Json -Depth 6 -Compress
[IO.File]::WriteAllText((Join-Path $aqui 'plan_compras.json'), $json, (New-Object Text.UTF8Encoding $false))
Write-Host "plan_compras.json: $($camiones.Count) camiones (BR/PY $nBRPY, BO $nBO, dictadas $usadas, supuestos PY $nSup, supuestos BO $nSupBO; $descartadas filas de Aloha descartadas por haber dictado ese origen y semana) · minimo $minimoSab · conteo $($conteo.fecha)"

# ---- inyectar en simulador.html
$html = Join-Path $aqui 'simulador.html'
$t = [IO.File]::ReadAllText($html, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$pat = '/\*__COMPRAS_JSON__\*/.*?/\*__END_COMPRAS__\*/'
if (([regex]::Matches($t, $pat, 'Singleline')).Count -ne 1) { throw 'simulador.html: marcadores COMPRAS_JSON' }
$rep = '/*__COMPRAS_JSON__*/' + $json + '/*__END_COMPRAS__*/'
$t = [regex]::Replace($t, $pat, { param($m) $rep }, 'Singleline')
[IO.File]::WriteAllText($html, $t, (New-Object Text.UTF8Encoding $true))
Write-Host "simulador.html: datos inyectados. Abrir plan_compras\simulador.html en el navegador."
