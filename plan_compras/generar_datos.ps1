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
#    - Las cargas dictadas valen solo para fechas POSTERIORES a la ultima carga
#      que trae el plan de su origen; cuando Aloha se pone al dia, manda Aloha.
#    - Descarga = fecha real si ya descargo; si no, carga + 3 dias (BR, PY) o + 6 (BO).
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
$LAG_DESC = @{ BR = 3; PY = 3; BO = 6 }

# ---- plan_compras.xlsx
$pcx = Join-Path $aqui 'plan_compras.xlsx'
$prog = @(Tabla $pcx 'cargas_programadas' | ForEach-Object { $d = Fecha $_.fecha; [PSCustomObject]@{ origen = $_.origen; productor = $_.productor; carga = (Ymd $d); semana_carga = (Ymd $d.AddDays(-[int]$d.DayOfWeek)); cajas = [int]$_.cajas; transportista = $_.transportista; nota = $_.nota } })
$ventas = @(Tabla $pcx 'ventas_plan' | ForEach-Object { [PSCustomObject]@{ semana_lunes = (Ymd (Fecha $_.semana_lunes)); BR = [int]$_.br; PY = [int]$_.py; BO = [int]$_.bo; fuente = $_.fuente } })
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

# ---- dictadas: solo fechas posteriores a la ultima carga del plan de ese origen
$maxPlan = @{}
foreach ($o in 'BR', 'PY', 'BO') { $maxPlan[$o] = ($camiones | Where-Object { $_.origen -eq $o } | ForEach-Object { [DateTime]$_.carga } | Sort-Object | Select-Object -Last 1) }
$omitidas = 0; $usadas = 0
foreach ($p in $prog) {
    $mp = $maxPlan[$p.origen]
    if ($mp -and ([DateTime]$p.carga -le $mp)) { $omitidas++; continue }
    $camiones += [PSCustomObject]@{ origen = $p.origen; productor = $p.productor; carga = $p.carga; semana_carga = $p.semana_carga; cajas = $p.cajas; status = 'programado'; descarga = $null; transportista = $p.transportista; fuente = 'plan_compras'; nota = $p.nota }
    $usadas++
}

$out = [ordered]@{
    generado = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    hoy = (Get-Date).ToString('yyyy-MM-dd')
    plan_cargas = [ordered]@{ archivo = $pc.Name; fecha = $pc.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); camiones = $nBRPY; ultima_carga = [ordered]@{ BR = $(if ($maxPlan.BR) { Ymd $maxPlan.BR }); PY = $(if ($maxPlan.PY) { Ymd $maxPlan.PY }) } }
    plan_cargas_otros = [ordered]@{ archivo = $(if ($pcO) { $pcO.Name } else { $null }); fecha = $(if ($pcO) { $pcO.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }); camiones_bo = $nBO; ultima_carga_bo = $(if ($maxPlan.BO) { Ymd $maxPlan.BO }) }
    plan_compras = [ordered]@{ archivo = 'plan_compras\plan_compras.xlsx'; fecha = (Get-Item $pcx).LastWriteTime.ToString('yyyy-MM-dd HH:mm'); dictadas_usadas = $usadas; dictadas_omitidas_por_estar_en_el_plan = $omitidas }
    lags = [ordered]@{ BR = [ordered]@{ descarga = 3; madurar = 7 }; PY = [ordered]@{ descarga = 3; madurar = 7 }; BO = [ordered]@{ descarga = 6; madurar = 7 } }
    cajas_camion = [ordered]@{ BR = 1008; PY = 980; BO = 1050 }
    conteo = $conteo
    ventas_plan = $ventas
    camiones = @($camiones | Sort-Object carga, origen)
}
$json = $out | ConvertTo-Json -Depth 6 -Compress
[IO.File]::WriteAllText((Join-Path $aqui 'plan_compras.json'), $json, (New-Object Text.UTF8Encoding $false))
Write-Host "plan_compras.json: $($camiones.Count) camiones (BR/PY $nBRPY, BO $nBO, dictadas $usadas; $omitidas dictadas ya estan en el plan) · conteo $($conteo.fecha)"

# ---- inyectar en simulador.html
$html = Join-Path $aqui 'simulador.html'
$t = [IO.File]::ReadAllText($html, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
$pat = '/\*__COMPRAS_JSON__\*/.*?/\*__END_COMPRAS__\*/'
if (([regex]::Matches($t, $pat, 'Singleline')).Count -ne 1) { throw 'simulador.html: marcadores COMPRAS_JSON' }
$rep = '/*__COMPRAS_JSON__*/' + $json + '/*__END_COMPRAS__*/'
$t = [regex]::Replace($t, $pat, { param($m) $rep }, 'Singleline')
[IO.File]::WriteAllText($html, $t, (New-Object Text.UTF8Encoding $true))
Write-Host "simulador.html: datos inyectados. Abrir plan_compras\simulador.html en el navegador."
