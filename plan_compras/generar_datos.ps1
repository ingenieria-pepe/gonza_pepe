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
$prog = @(Tabla $pcx 'cargas_programadas' | ForEach-Object { $d = Fecha $_.fecha; [PSCustomObject]@{ origen = $_.origen; productor = $_.productor; carga = (Ymd $d); semana_carga = (Ymd $d.AddDays(-[int]$d.DayOfWeek)); cajas = [int]$_.cajas; transportista = $_.transportista; nota = $_.nota; parcial = ([int]$_.cajas -lt 600) } })   # [08/10/2026] < 600 cajas = carga parcial (p. ej. 12 pallets en camion mixto): suma cajas, no cuenta como camion
$ventas = @(Tabla $pcx 'ventas_plan' | ForEach-Object { [PSCustomObject]@{ semana_lunes = (Ymd (Fecha $_.semana_lunes)); BR = [int]$_.br; PY = [int]$_.py; BO = [int]$_.bo; fuente = $_.fuente } })
# venta REAL por semana y origen (hoja ventas_semanales, transcrita del reporte semanal del ERP; 29/09/2026). Opcional.
$ventasReales = @()
try { $ventasReales = @(Tabla $pcx 'ventas_semanales' | Where-Object { $_.semana_lunes -and (Fecha $_.semana_lunes) } | ForEach-Object { [PSCustomObject]@{ semana_lunes = (Ymd (Fecha $_.semana_lunes)); BR = [int]$_.br; PY = [int]$_.py; BO = [int]$_.bo; EC = [int]$_.ec; TODO = ([int]$_.br + [int]$_.py + [int]$_.bo); fuente = $_.fuente } }) } catch { Write-Host "    (sin hoja ventas_semanales: $($_.Exception.Message))" -ForegroundColor DarkYellow }
$conteoRows = @(Tabla $pcx 'conteo' | ForEach-Object { [PSCustomObject]@{ fecha = (Ymd (Fecha $_.fecha)); origen = $_.origen; cajas = [int]$_.cajas; fuente = $_.fuente } })
$fechaConteo = ($conteoRows | ForEach-Object { $_.fecha } | Sort-Object | Select-Object -Last 1)
$conteo = [ordered]@{ fecha = $fechaConteo }; foreach ($c in ($conteoRows | Where-Object { $_.fecha -eq $fechaConteo })) { $conteo[$c.origen] = $c.cajas }
$conteo.fuente = ($conteoRows | Where-Object { $_.fecha -eq $fechaConteo } | Select-Object -First 1).fuente

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
$quitar = @{}; $descartadas = 0
for ($i = 0; $i -lt $camiones.Count; $i++) { $c = $camiones[$i]; if ($dictOW.ContainsKey(([string]$c.origen) + '|' + $c.semana_carga)) { $quitar[$i] = $true; $descartadas++ } }
$usadas = 0; $omitidas = 0; $reemplazadas = 0
foreach ($p in ($prog | Sort-Object carga)) {
    $camiones += [PSCustomObject]@{ origen = $p.origen; productor = $p.productor; carga = $p.carga; semana_carga = $p.semana_carga; cajas = $p.cajas; status = 'programado'; descarga = $null; transportista = $p.transportista; fuente = 'plan_compras'; nota = [string]$p.nota; parcial = [bool]$p.parcial }
    $usadas++
}if ($quitar.Count -gt 0) { $camiones = @(for ($i = 0; $i -lt $camiones.Count; $i++) { if (-not $quitar.ContainsKey($i)) { $camiones[$i] } }) }

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
foreach ($k in $GRUPOS.Keys) {
    $conteo[$k] = 0; foreach ($o in $GRUPOS[$k]) { $conteo[$k] += [int]$conteo[$o] }
    foreach ($v in $ventas) { $s = 0; foreach ($o in $GRUPOS[$k]) { $s += [int]$v.$o }; $v | Add-Member -NotePropertyName $k -NotePropertyValue $s -Force }
}
$out = [ordered]@{
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
