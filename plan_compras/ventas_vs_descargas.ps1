# ==========================================================================
#  plan_compras\ventas_vs_descargas.ps1  -  venta semanal de banana vs descargas BR+PY, por semana del año (12/10/2026)
# ==========================================================================
#  Cruza la venta real por semana (fuentes\aloha_ventas_historico.json, Aloha desde 30/06/2025) con las descargas de
#  camiones de Brasil y Paraguay por semana de DESCARGA (mismas fuentes y criterios que plan_compras\historico_cargas.ps1:
#  Excel historico sin choferes para cargas 2019-2023 + export de Aloha desde 01/01/2024) y deja
#
#    fuentes\ventas_vs_descargas.json  { generado, semanas: [ { semana_lunes, anio, n, BR, PY, BO, EC, otras, madera_bo,
#                                        total, venta_madera, desc_cam_BR, desc_cam_PY, desc_cam, desc_cajas_BR,
#                                        desc_cajas_PY, desc_cajas, dif, venta_supera } ],
#                                        calendario: [ { n, venta_prom, descarga_prom, dif, anios_venta, anios_descarga,
#                                        venta_prom_total, descarga_prom_cam, venta_2025, venta_2026, descarga_2025,
#                                        descarga_2026, descarga_por_anio } ], resumen, criterios }
#
#  venta_prom / descarga_prom son CAJAS de banana de madera (BR+PY): venta = present de Banana Brasil (+Fibra, +San Pablo)
#  y Banana Paraguaya; descarga = cajas descargadas (Cajas desc. si es valida, si no Cajas MIC 300-1.500, si no la mediana
#  del pais y año) de camiones Descargado/Arribado, en la semana lunes-sabado de la fecha de descarga (sin fecha: carga +
#  3 dias BR / 4 dias PY). Semana n = la n-esima del año contando desde el 1/1 (regla de historico_cargas.ps1), promedio
#  de descargas sobre 2019-2025 (ceros incluidos), promedio de venta sobre los años con datos (2025 desde la semana 27,
#  2026). Solo cajas y camiones, sin precios.
#
#  Uso:  powershell -ExecutionPolicy Bypass -File plan_compras\ventas_vs_descargas.ps1 [-Xlsx <planilla.xlsx>]
#  Con -Xlsx escribe ademas las hojas "ventas_vs_descargas" (calendario) y "ventas_semanal" en esa planilla (ImportExcel).
# ==========================================================================
param([string]$Xlsx = '', [string]$Out = '')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $Out) { $Out = Join-Path $repo 'fuentes\ventas_vs_descargas.json' }
$hoy = (Get-Date).Date; $anioHoy = $hoy.Year

# Read-XlsxHoja: la misma funcion del script principal (se toma del archivo para no duplicarla), igual que historico_cargas.ps1
$tk = $null; $er = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$repo\actualizar_precios.ps1", [ref]$tk, [ref]$er)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-XlsxHoja' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'no encuentro Read-XlsxHoja en actualizar_precios.ps1' }
Invoke-Expression $fn.Extent.Text

# ---- helpers y lectura de cargas: copia de plan_compras\historico_cargas.ps1 (mantener iguales)
function Fecha($s) { if ($null -eq $s) { return $null }; $t = ([string]$s).Trim(); if (-not $t) { return $null }; $o = 0.0; if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$o)) { if ($o -gt 40000 -and $o -lt 60000) { return [DateTime]::FromOADate($o).Date }; return $null }; try { return ([DateTime]::Parse($t)).Date } catch { return $null } }
function Num($s) { $o = 0.0; if ([double]::TryParse((([string]$s) -replace '[^\d\.\-]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$o)) { return $o }; return $null }
function Cel($f, $c) { if ($c -ge 0 -and $c -lt $f.Count) { return ([regex]::Replace([string]$f[$c], '\s+', ' ')).Trim() } else { return '' } }
function Ymd($d) { return $d.ToString('yyyy-MM-dd') }
function LunesDe($d) { if ($d.DayOfWeek -eq [DayOfWeek]::Sunday) { return $d.AddDays(1) }; return $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)) }
function SemanaN($lunes) { return [int][math]::Floor(($lunes.DayOfYear - 1) / 7) + 1 }   # 1..53, misma regla todos los años
function Mediana($a) { $s = @($a | Sort-Object); if (-not $s.Count) { return $null }; return $s[[int][math]::Floor($s.Count / 2)] }
$noBanana = '(?i)^(Papa|Boniato|Cebolla|Abacaxi|Varios|Registro|Zanahoria|Ajo|Calabac|Zapallo|Pi[nñ]a|Mango|Lim[oó]n|Naranja|Uva|Manzana|Pera|Mel[oó]n|Sand[ií]a|Tomate|Morr[oó]n|Pomelo|Kiwi|Palta|Ar[aá]ndano|Exotic|Mix|Bahia \+|xx$)'

function Leer-Cargas($path, $fuente, $desde, $hasta) {
    $rows = @()
    foreach ($h in @('Cargas', 'Plan de cargas')) { $rows = Read-XlsxHoja -Path $path -Hoja $h; if ($rows.Count -ge 2) { break } }
    if ($rows.Count -lt 2) { throw "sin filas en $path" }
    $hdrIdx = -1; for ($i = 0; $i -lt [math]::Min(15, $rows.Count); $i++) { $j = (@($rows[$i]) -join '|'); if ($j -match 'Status' -and $j -match 'Productor') { $hdrIdx = $i; break } }
    if ($hdrIdx -lt 0) { throw "sin encabezado Status/Productor en $path" }
    $hdr = @($rows[$hdrIdx] | ForEach-Object { [regex]::Replace([string]$_, '\s+', ' ').Trim() })
    function Col($rx) { for ($k = 0; $k -lt $hdr.Count; $k++) { if ($hdr[$k] -match $rx) { return $k } }; return -1 }
    $cSt = Col '^Status'; $cPr = Col '^Productor'; $cPa = Col '^Pa[ií]s'; $cFc = Col '^Fecha (de )?[Cc]arga'; $cFf = Col '^Fecha [Ff]rontera'; $cFr = Col '^Frontera$'; $cFd = Col '^Fecha [Dd]esc'; $cTr = Col '^Transportista'; $cMic = Col '^Cajas MIC'; $cDesc = Col '^Cajas [Dd]esc'
    $out = New-Object System.Collections.Generic.List[object]
    for ($r = $hdrIdx + 1; $r -lt $rows.Count; $r++) {
        $f = @($rows[$r]); $st = Cel $f $cSt; $pr = Cel $f $cPr; if (-not $st -or -not $pr) { continue }
        if ($pr -match $noBanana) { continue }
        $fc = Fecha $f[$cFc]; if (-not $fc) { continue }
        if ($fc -lt $desde -or $fc -gt $hasta) { continue }
        $pais = $(if ($cPa -ge 0) { Cel $f $cPa } else { '' })
        if (-not $pais) { $pais = $(if ($pr -match '(?i)^paraguay|\sPY$') { 'PY' } elseif ($pr -match '(?i)^bolivia') { 'BO' } else { 'BR' }) }
        if ($pais -notin 'BR', 'PY') { continue }
        $mic = Num (Cel $f $cMic); if ($mic -and ($mic -lt 300 -or $mic -gt 1500)) { $mic = $null }
        $cd = $(if ($cDesc -ge 0) { Num (Cel $f $cDesc) } else { $null }); if ($cd -and ($cd -lt 100 -or ($mic -and $cd -gt 1.5 * $mic))) { $cd = $null }
        $fd = $(if ($cFd -ge 0) { Fecha $f[$cFd] } else { $null }); if ($fd -and ($fd -lt $fc -or ($fd - $fc).TotalDays -gt 30)) { $fd = $null }
        $ff = $(if ($cFf -ge 0) { Fecha $f[$cFf] } else { $null }); if ($ff -and ($ff -lt $fc -or ($ff - $fc).TotalDays -gt 30)) { $ff = $null }
        $tr = Cel $f $cTr; if ($tr -match '^(0|#N/A|-|xx)$') { $tr = '' }
        $out.Add([PSCustomObject]@{ fuente = $fuente; status = $st; productor = $pr; pais = $pais; carga = $fc; frontera = (Cel $f $cFr); fecha_frontera = $ff; descarga = $fd; transportista = $tr; cajas_mic = $mic; cajas_desc = $cd })
    }
    return $out
}

# ---- 1) descargas por semana de descarga (BR y PY)
$corteAPI = [DateTime]'2024-01-01'
$histFile = Get-ChildItem (Join-Path $repo 'fuentes\plan_cargas\historico\*.xlsx') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' -and $_.Name -match '(?i)sin choferes' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $histFile) { $histFile = Get-ChildItem (Join-Path $repo 'fuentes\plan_cargas\historico\*.xlsx') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
$apiFile = Get-ChildItem (Join-Path $repo 'fuentes\plan_cargas\*.xlsx') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $apiFile) { throw 'sin export de Aloha en fuentes\plan_cargas\' }
$todo = New-Object System.Collections.Generic.List[object]
if ($histFile) { foreach ($x in (Leer-Cargas $histFile.FullName 'historico' ([DateTime]'2019-01-01') $corteAPI.AddDays(-1))) { $todo.Add($x) }; Write-Host "  historico: $($histFile.Name) -> $($todo.Count) filas 2019-2023" }
else { Write-Host "  (aviso) sin Excel historico: la serie de descargas arranca en 2024" -ForegroundColor DarkYellow }
$nH = $todo.Count
foreach ($x in (Leer-Cargas $apiFile.FullName 'aloha' $corteAPI ([DateTime]'2099-01-01'))) { $todo.Add($x) }
Write-Host "  Aloha: $($apiFile.Name) -> $($todo.Count - $nH) filas desde 2024"
$ok = @($todo | Where-Object { $_.status -match '^(Descargado|Arribado)' })
$LAG = @{ BR = 3; PY = 4 }
foreach ($x in $ok) { $d = $(if ($x.descarga) { $x.descarga } else { $x.carga.AddDays($LAG[$x.pais]) }); $x | Add-Member -NotePropertyName semana_desc -NotePropertyValue (LunesDe $d) -Force }
# cajas por camion: Cajas desc. valida, si no MIC valido, si no la mediana del pais y año (se informa cuantos)
$medPY = @{}; $sinCajas = 0
foreach ($g in ($ok | Group-Object { "$($_.pais)|$($_.carga.Year)" })) { $v = @($g.Group | ForEach-Object { if ($_.cajas_desc) { $_.cajas_desc } elseif ($_.cajas_mic) { $_.cajas_mic } }); $medPY[$g.Name] = $(if ($v.Count) { Mediana $v } else { 0 }) }
foreach ($x in $ok) {
    $c = $(if ($x.cajas_desc) { $x.cajas_desc } elseif ($x.cajas_mic) { $x.cajas_mic } else { $sinCajas++; $medPY["$($x.pais)|$($x.carga.Year)"] })
    $x | Add-Member -NotePropertyName cajas -NotePropertyValue ([double]$c) -Force
}
Write-Host "  descargados: $($ok.Count) camiones ($sinCajas sin cajas validas, rellenados con la mediana del pais y año)"
$desc = @{}   # "lunes" -> acumulado
foreach ($x in $ok) {
    $k = Ymd $x.semana_desc
    if (-not $desc.ContainsKey($k)) { $desc[$k] = @{ cam_BR = 0; cam_PY = 0; cajas_BR = 0.0; cajas_PY = 0.0 } }
    $desc[$k]["cam_$($x.pais)"]++; $desc[$k]["cajas_$($x.pais)"] += $x.cajas
}
function DescDe($lunes) { $k = Ymd $lunes; if ($desc.ContainsKey($k)) { return $desc[$k] }; return @{ cam_BR = 0; cam_PY = 0; cajas_BR = 0.0; cajas_PY = 0.0 } }

# control contra la referencia de historico_cargas.json (camiones por semana n y año)
$refPath = Join-Path $repo 'fuentes\historico_cargas.json'
if (Test-Path $refPath) {
    try {
        $ref = Get-Content $refPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $dif = 0; $cmp = 0
        foreach ($r in @($ref.semanas_ref)) { foreach ($p in $r.por_anio.PSObject.Properties) { $y = [int]$p.Name; $mio = 0; foreach ($k in $desc.Keys) { $l = [DateTime]::ParseExact($k, 'yyyy-MM-dd', $null); if ($l.Year -eq $y -and (SemanaN $l) -eq [int]$r.n) { $mio += $desc[$k].cam_BR + $desc[$k].cam_PY } }; $cmp++; if ($mio -ne [int]$p.Value) { $dif++ } } }
        Write-Host "  control vs historico_cargas.json ($($ref.generado)): $cmp celdas año/semana comparadas, $dif distintas" -ForegroundColor $(if ($dif) { 'DarkYellow' } else { 'Green' })
    } catch { Write-Host "  (aviso) no pude comparar con historico_cargas.json: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}

# ---- 2) ventas por semana (JSON de Aloha)
$vPath = Join-Path $repo 'fuentes\aloha_ventas_historico.json'
$ventas = Get-Content $vPath -Raw -Encoding UTF8 | ConvertFrom-Json
$semanas = @()
foreach ($s in @($ventas.semanas | Sort-Object semana_lunes)) {
    $lunes = [DateTime]::ParseExact([string]$s.semana_lunes, 'yyyy-MM-dd', $null)
    $dd = DescDe $lunes
    $vm = [int]$s.BR + [int]$s.PY
    $dc = [int][math]::Round($dd.cajas_BR + $dd.cajas_PY)
    $semanas += [ordered]@{ semana_lunes = (Ymd $lunes); anio = $lunes.Year; n = (SemanaN $lunes)
        BR = [int]$s.BR; PY = [int]$s.PY; BO = [int]$s.BO; EC = [int]$s.EC; otras = [int]$s.otras; madera_bo = [int]$s.madera_bo; total = [int]$s.total
        venta_madera = $vm; desc_cam_BR = [int]$dd.cam_BR; desc_cam_PY = [int]$dd.cam_PY; desc_cam = [int]($dd.cam_BR + $dd.cam_PY)
        desc_cajas_BR = [int][math]::Round($dd.cajas_BR); desc_cajas_PY = [int][math]::Round($dd.cajas_PY); desc_cajas = $dc
        dif = ($vm - $dc); venta_supera = ($vm -gt $dc) }
}
Write-Host "  ventas: $($semanas.Count) semanas ($($semanas[0].semana_lunes) a $($semanas[-1].semana_lunes))"

# ---- 3) calendario por semana del año
$aniosDesc = @(2019..($anioHoy - 1))
$ventaPorYN = @{}; foreach ($s in $semanas) { $ventaPorYN["$($s.anio)|$($s.n)"] = $s }
$calendario = @()
for ($n = 1; $n -le 53; $n++) {
    $cajasY = [ordered]@{}; $camY = [ordered]@{}; $vals = @(); $valsCam = @()
    foreach ($y in (2019..$anioHoy)) {
        $c = 0.0; $cm = 0
        foreach ($k in $desc.Keys) { $l = [DateTime]::ParseExact($k, 'yyyy-MM-dd', $null); if ($l.Year -eq $y -and (SemanaN $l) -eq $n) { $c += $desc[$k].cajas_BR + $desc[$k].cajas_PY; $cm += $desc[$k].cam_BR + $desc[$k].cam_PY } }
        $cajasY["$y"] = [int][math]::Round($c); $camY["$y"] = $cm
        if ($y -lt $anioHoy) { $vals += $c; $valsCam += $cm }
    }
    $vv = @(); $vvTot = @(); $aniosV = @()
    foreach ($y in (2025..$anioHoy)) { $k = "$y|$n"; if ($ventaPorYN.ContainsKey($k)) { $vv += $ventaPorYN[$k].venta_madera; $vvTot += $ventaPorYN[$k].total; $aniosV += $y } }
    $vp = $(if ($vv.Count) { [int][math]::Round(($vv | Measure-Object -Average).Average) } else { $null })
    $dp = [int][math]::Round(($vals | Measure-Object -Average).Average)
    $calendario += [ordered]@{ n = $n
        venta_prom = $vp; descarga_prom = $dp; dif = $(if ($null -ne $vp) { $vp - $dp } else { $null })
        anios_venta = ($aniosV -join ','); anios_descarga = "$($aniosDesc[0])-$($aniosDesc[-1])"
        venta_prom_total = $(if ($vvTot.Count) { [int][math]::Round(($vvTot | Measure-Object -Average).Average) } else { $null })
        descarga_prom_cam = [math]::Round(($valsCam | Measure-Object -Average).Average, 1)
        venta_2025 = $(if ($ventaPorYN.ContainsKey("2025|$n")) { $ventaPorYN["2025|$n"].venta_madera } else { $null })
        venta_2026 = $(if ($ventaPorYN.ContainsKey("2026|$n")) { $ventaPorYN["2026|$n"].venta_madera } else { $null })
        descarga_2025 = $cajasY['2025']; descarga_2026 = $(if ([DateTime]::new($anioHoy, 1, 1).AddDays(($n - 1) * 7) -le $hoy) { $cajasY["$anioHoy"] } else { $null })
        descarga_por_anio = $cajasY; camiones_por_anio = $camY }
}

# ---- 4) resumen
$conDesc = @($semanas | Where-Object { $_.desc_cam -gt 0 })
$sup = @($semanas | Where-Object { $_.venta_supera })
$s26 = @($semanas | Where-Object { $_.anio -eq 2026 }); $s25 = @($semanas | Where-Object { $_.anio -eq 2025 })
function Prom($a, $p) { if (-not $a.Count) { return $null }; return [int][math]::Round((($a | ForEach-Object { $_[$p] }) | Measure-Object -Average).Average) }
$resumen = [ordered]@{
    semanas = $semanas.Count; semanas_venta_supera_descarga = $sup.Count
    venta_madera_prom_2025 = (Prom $s25 'venta_madera'); descarga_prom_2025 = (Prom $s25 'desc_cajas'); venta_total_prom_2025 = (Prom $s25 'total')
    venta_madera_prom_2026 = (Prom $s26 'venta_madera'); descarga_prom_2026 = (Prom $s26 'desc_cajas'); venta_total_prom_2026 = (Prom $s26 'total')
    venta_madera_acum_2026 = (($s26 | ForEach-Object { $_.venta_madera }) | Measure-Object -Sum).Sum
    descarga_acum_2026 = (($s26 | ForEach-Object { $_.desc_cajas }) | Measure-Object -Sum).Sum
    camiones_acum_2026 = (($s26 | ForEach-Object { $_.desc_cam }) | Measure-Object -Sum).Sum
    cajas_por_camion_2026 = $(if ($s26.Count) { [int][math]::Round((($s26 | ForEach-Object { $_.desc_cajas }) | Measure-Object -Sum).Sum / [math]::Max(1, (($s26 | ForEach-Object { $_.desc_cam }) | Measure-Object -Sum).Sum)) } else { $null })
    semana_mayor_venta = (($semanas | Sort-Object { $_.venta_madera } -Descending | Select-Object -First 1).semana_lunes)
    semana_menor_venta = (($semanas | Sort-Object { $_.venta_madera } | Select-Object -First 1).semana_lunes)
}

$doc = [ordered]@{
    generado = (Get-Date).ToString('yyyy-MM-dd HH:mm'); hoy = (Ymd $hoy)
    fuente = 'ventas: fuentes\aloha_ventas_historico.json (Aloha, semanas completas lun-sab desde 30/06/2025); descargas: ' + $(if ($histFile) { $histFile.Name + ' (2019-2023) + ' } else { '' }) + $apiFile.Name + ' (desde 2024)'
    criterios = @(
        'venta_madera = cajas vendidas de Banana Brasil (+Fibra, +San Pablo) + Banana Paraguaya; total = BR+PY+BO+EC; otras (Banana Colombia) fuera de total.',
        'descarga = cajas de camiones Descargado/Arribado de BR y PY en la semana lunes-sabado de la fecha de descarga (sin fecha: carga + 3 dias BR / 4 dias PY); cajas = Cajas desc. valida, si no MIC 300-1.500, si no la mediana del pais y año.',
        'Semana n = la n-esima del año contando desde el 1/1 (misma regla que historico_cargas.ps1). descarga_prom = promedio 2019-' + ($anioHoy - 1) + ' (ceros incluidos); venta_prom = promedio de los años con venta en esa semana (2025 desde la semana 27, 2026).',
        'dif = venta_madera - desc_cajas (positivo: se vendio mas de lo que se descargo esa semana, se consumio stock). Solo cajas y camiones, sin precios.'
    )
    resumen = $resumen; semanas = $semanas; calendario = $calendario
}
$json = $doc | ConvertTo-Json -Depth 8 -Compress
Set-Content -Path $Out -Value $json -Encoding UTF8
Write-Host "  OK $Out ($([int]($json.Length / 1KB)) KB): $($semanas.Count) semanas, calendario 53 filas; venta supera descarga en $($sup.Count) semanas" -ForegroundColor Green

if ($Xlsx) {
    Import-Module ImportExcel -ErrorAction Stop
    $hojaCal = @(); foreach ($c in $calendario) {
        $f = [ordered]@{ semana = $c.n; 'venta prom BR+PY' = $c.venta_prom; 'descarga prom BR+PY' = $c.descarga_prom; dif = $c.dif; 'descarga prom camiones' = $c.descarga_prom_cam; 'venta prom total' = $c.venta_prom_total
                         'venta 2025' = $c.venta_2025; 'venta 2026' = $c.venta_2026; 'descarga 2025' = $c.descarga_2025; 'descarga 2026' = $c.descarga_2026; 'años venta' = $c.anios_venta; 'años descarga' = $c.anios_descarga }
        foreach ($p in $c.descarga_por_anio.Keys) { $f["desc $p"] = $c.descarga_por_anio[$p] }
        foreach ($p in $c.camiones_por_anio.Keys) { $f["cam $p"] = $c.camiones_por_anio[$p] }
        $hojaCal += [pscustomobject]$f
    }
    $hojaSem = @(); foreach ($s in $semanas) {
        $hojaSem += [pscustomobject]([ordered]@{ semana_lunes = $s.semana_lunes; anio = $s.anio; semana = $s.n; 'venta BR' = $s.BR; 'venta PY' = $s.PY; 'venta BO' = $s.BO; 'venta EC' = $s.EC; 'venta otras' = $s.otras; 'venta madera BR+PY' = $s.venta_madera; 'venta madera+BO' = $s.madera_bo; 'venta total' = $s.total
                                                 'camiones BR' = $s.desc_cam_BR; 'camiones PY' = $s.desc_cam_PY; 'camiones' = $s.desc_cam; 'descarga cajas BR' = $s.desc_cajas_BR; 'descarga cajas PY' = $s.desc_cajas_PY; 'descarga cajas' = $s.desc_cajas; 'dif venta-descarga' = $s.dif; 'venta supera' = $(if ($s.venta_supera) { 'si' } else { 'no' }) })
    }
    $hojaCal | Export-Excel -Path $Xlsx -WorksheetName 'ventas_vs_descargas' -ClearSheet -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter
    $hojaSem | Export-Excel -Path $Xlsx -WorksheetName 'ventas_semanal' -ClearSheet -AutoSize -FreezeTopRow -BoldTopRow -AutoFilter
    Write-Host "  OK hojas ventas_vs_descargas y ventas_semanal en $Xlsx" -ForegroundColor Green
}
