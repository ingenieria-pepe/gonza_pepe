# ==========================================================================
#  plan_compras\historico_cargas.ps1  -  serie de cargas 2019-hoy (Brasil y Paraguay) y semaforo de productores
# ==========================================================================
#  [12/10/2026] Gonzalo dejo su Excel de cargas de antes de Aloha (2018-ago/2024) y pidio "sacar datos y estadisticas"
#  y despues "vamos por todas": semaforo de productores, referencia historica por semana, techo por productor,
#  tiempos y cancelaciones por productor para el plan. Este script arma la serie larga y la deja en un JSON que leen
#  actualizar_precios.ps1 (paso 5h2: seccion "Productores 2019-2026" de index_brasil.html y renglones de los mensajes)
#  y generar_datos.ps1 (lag y tasa de cancelacion por productor).
#
#    powershell -ExecutionPolicy Bypass -File plan_compras\historico_cargas.ps1
#
#  Lee:
#    - fuentes\plan_cargas\historico\*(sin choferes).xlsx (hoja Cargas): el Excel historico de Gonzalo, cargas hasta
#      ago/2024; se usan las anteriores al 01/01/2024.
#    - fuentes\plan_cargas\*.xlsx (el mas nuevo, igual que generar_datos): export de Aloha, cargas desde ene/2024.
#  Escribe:
#    - fuentes\historico_cargas.json
#  Criterios (los mismos de documentos\estadisticas_plan_cargas): año = año de la fecha de carga; "descargado" = status
#  Descargado o Arribado; se excluyen filas que no son banana (Varios, Papa, Boniato, Cebolla, Abacaxi, Registro, xx,
#  Bahia + Exoticos); cajas MIC fuera de 300-1.500 no cuentan en cajas; lead time = descarga - carga, descartando <0 o
#  >30. Pais = columna Pais del export o, si esta vacia, el nombre del productor ("Paraguay ..." / "... PY" = PY).
#  Solo cajas y camiones, sin precios.
# ==========================================================================
param([string]$Out = '')
$ErrorActionPreference = 'Stop'
$aqui = $PSScriptRoot
$repo = Split-Path $aqui -Parent
if (-not $Out) { $Out = Join-Path $repo 'fuentes\historico_cargas.json' }
# Read-XlsxHoja: la misma funcion del script principal (se toma del archivo para no duplicarla)
$tk = $null; $er = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$repo\actualizar_precios.ps1", [ref]$tk, [ref]$er)
$fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-XlsxHoja' }, $true) | Select-Object -First 1
if (-not $fn) { throw 'no encuentro Read-XlsxHoja en actualizar_precios.ps1' }
Invoke-Expression $fn.Extent.Text

function Fecha($s) { if ($null -eq $s) { return $null }; $t = ([string]$s).Trim(); if (-not $t) { return $null }; $o = 0.0; if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$o)) { if ($o -gt 40000 -and $o -lt 60000) { return [DateTime]::FromOADate($o).Date }; return $null }; try { return ([DateTime]::Parse($t)).Date } catch { return $null } }
function Num($s) { $o = 0.0; if ([double]::TryParse((([string]$s) -replace '[^\d\.\-]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$o)) { return $o }; return $null }
function Cel($f, $c) { if ($c -ge 0 -and $c -lt $f.Count) { return ([regex]::Replace([string]$f[$c], '\s+', ' ')).Trim() } else { return '' } }
function Ymd($d) { return $d.ToString('yyyy-MM-dd') }
function LunesDe($d) { if ($d.DayOfWeek -eq [DayOfWeek]::Sunday) { return $d.AddDays(1) }; return $d.AddDays(-((([int]$d.DayOfWeek) + 6) % 7)) }
function SemanaN($lunes) { return [int][math]::Floor(($lunes.DayOfYear - 1) / 7) + 1 }   # 1..53, misma regla todos los años
function Mediana($a) { $s = @($a | Sort-Object); if (-not $s.Count) { return $null }; return $s[[int][math]::Floor($s.Count / 2)] }
function P90($a) { $s = @($a | Sort-Object); if (-not $s.Count) { return $null }; return $s[[int][math]::Min($s.Count - 1, [math]::Floor($s.Count * 0.9))] }
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

$hoy = (Get-Date).Date
$corteAPI = [DateTime]'2024-01-01'
$histFile = Get-ChildItem (Join-Path $repo 'fuentes\plan_cargas\historico\*.xlsx') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' -and $_.Name -match '(?i)sin choferes' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $histFile) { $histFile = Get-ChildItem (Join-Path $repo 'fuentes\plan_cargas\historico\*.xlsx') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
$apiFile = Get-ChildItem (Join-Path $repo 'fuentes\plan_cargas\*.xlsx') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$todo = New-Object System.Collections.Generic.List[object]
if ($histFile) { foreach ($x in (Leer-Cargas $histFile.FullName 'historico' ([DateTime]'2019-01-01') $corteAPI.AddDays(-1))) { $todo.Add($x) }; Write-Host "  historico: $($histFile.Name) -> $($todo.Count) filas 2019-2023" }
else { Write-Host "  (aviso) sin Excel historico en fuentes\plan_cargas\historico\: la serie arranca en 2024" -ForegroundColor DarkYellow }
$nH = $todo.Count
if ($apiFile) { foreach ($x in (Leer-Cargas $apiFile.FullName 'aloha' $corteAPI ([DateTime]'2099-01-01'))) { $todo.Add($x) }; Write-Host "  Aloha: $($apiFile.Name) -> $($todo.Count - $nH) filas desde 2024" }
else { throw 'sin export de Aloha en fuentes\plan_cargas\' }
# nombres: unificar variantes de escritura (Corupa/Corupá, mayusculas, espacios dobles): vale la forma mas frecuente
function Norm($s) { $t = ([string]$s).ToLower().Trim().Normalize([Text.NormalizationForm]::FormD); $sb = New-Object Text.StringBuilder; foreach ($ch in $t.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) } }; return [regex]::Replace($sb.ToString(), '\s+', ' ') }
$formas = @{}; foreach ($x in $todo) { $k = Norm $x.productor; if (-not $formas.ContainsKey($k)) { $formas[$k] = @{} }; if (-not $formas[$k].ContainsKey($x.productor)) { $formas[$k][$x.productor] = 0 }; $formas[$k][$x.productor]++ }
$mejor = @{}; foreach ($k in $formas.Keys) { $mejor[$k] = ($formas[$k].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
foreach ($x in $todo) { $x.productor = $mejor[(Norm $x.productor)] }
$ok = @($todo | Where-Object { $_.status -match '^(Descargado|Arribado)' })
$canc = @($todo | Where-Object { $_.status -match '^(Cancelado|Destruida)' })
$pend = @($todo | Where-Object { $_.status -notmatch '^(Descargado|Arribado|Cancelado|Destruida)' -and $_.carga -le $hoy })   # cargado/en camino, cuenta como actividad
$anioIni = 2019; $anioHoy = $hoy.Year
$anios = $anioIni..$anioHoy
$LAG = @{ BR = 3; PY = 4 }
foreach ($x in $ok) { $d = $(if ($x.descarga) { $x.descarga } else { $x.carga.AddDays($LAG[$x.pais]) }); $x | Add-Member -NotePropertyName semana_desc -NotePropertyValue (LunesDe $d) -Force }

# ---- 1) por año
$porAnio = [ordered]@{}
foreach ($y in $anios) {
    $fila = [ordered]@{}
    foreach ($p in 'BR', 'PY', 'TODO') {
        $g = @($ok | Where-Object { $_.carga.Year -eq $y -and ($p -eq 'TODO' -or $_.pais -eq $p) })
        $gc = @($canc | Where-Object { $_.carga.Year -eq $y -and ($p -eq 'TODO' -or $_.pais -eq $p) })
        $mic = ($g | Measure-Object cajas_mic -Sum).Sum
        $sem = $(if ($y -eq $anioHoy) { [math]::Max(1, $hoy.DayOfYear / 7) } else { 52.14 })
        $fila[$p] = [ordered]@{ camiones = $g.Count; cajas = [int][math]::Round($mic); cam_sem = [math]::Round($g.Count / $sem, 1); cancelados = $gc.Count; mismo_tramo = @($g | Where-Object { $_.carga.DayOfYear -le $hoy.DayOfYear }).Count; productores = @($g | Group-Object productor).Count }
    }
    $porAnio["$y"] = $fila
}

# ---- 2) referencia por semana del año (semana de DESCARGA, lunes a sabado; lo que llega domingo cuenta para la que arranca)
$aniosRef = @($anios | Where-Object { $_ -lt $anioHoy })
$byYN = @{}   # "año|n|pais" -> camiones (una sola pasada)
foreach ($x in $ok) { $k = "$($x.semana_desc.Year)|$(SemanaN $x.semana_desc)|$($x.pais)"; if (-not $byYN.ContainsKey($k)) { $byYN[$k] = 0 }; $byYN[$k]++ }
function CntYN($y, $n, $p) { $s = 0; foreach ($pp in @($(if ($p -eq 'TODO') { 'BR', 'PY' } else { $p }))) { $k = "$y|$n|$pp"; if ($byYN.ContainsKey($k)) { $s += $byYN[$k] } }; return $s }
$semRef = @()
for ($n = 1; $n -le 53; $n++) {
    $porY = [ordered]@{}; $vals = @(); $valsBR = @(); $valsPY = @()
    foreach ($y in $anios) {
        $porY["$y"] = (CntYN $y $n 'TODO')
        if ($y -lt $anioHoy) { $vals += (CntYN $y $n 'TODO'); $valsBR += (CntYN $y $n 'BR'); $valsPY += (CntYN $y $n 'PY') }
    }
    $lunHoyY = [DateTime]::new($anioHoy, 1, 1).AddDays(($n - 1) * 7); $lunHoyY = LunesDe $lunHoyY   # lunes de esa semana en el año en curso (aprox.)
    $actual = $porY["$anioHoy"]; if ($lunHoyY -gt $hoy) { $actual = $null }
    $semRef += [ordered]@{ n = $n; prom = [math]::Round(($vals | Measure-Object -Average).Average, 1); prom_BR = [math]::Round(($valsBR | Measure-Object -Average).Average, 1); prom_PY = [math]::Round(($valsPY | Measure-Object -Average).Average, 1); min = ($vals | Measure-Object -Minimum).Minimum; max = ($vals | Measure-Object -Maximum).Maximum; anios = "$($aniosRef[0])-$($aniosRef[-1])"; por_anio = $porY; actual = $actual }
}

# ---- 3) productores: trayectoria + semaforo
$d28 = $hoy.AddDays(-28); $d56 = $hoy.AddDays(-56); $d364 = $hoy.AddDays(-364); $d90 = $hoy.AddDays(-90)
$prods = @()
foreach ($pais in 'BR', 'PY') {
    foreach ($g in @($todo | Where-Object { $_.pais -eq $pais } | Group-Object productor)) {
        $desc = @($g.Group | Where-Object { $_.status -match '^(Descargado|Arribado)' } | Sort-Object carga)
        $cn = @($g.Group | Where-Object { $_.status -match '^(Cancelado|Destruida)' })
        $act = @($g.Group | Where-Object { $_.status -notmatch '^(Cancelado|Destruida)' -and $_.carga -le $hoy } | Sort-Object carga)   # descargados + en camino
        if ($desc.Count -lt 10 -and -not @($act | Where-Object { $_.carga.Year -eq $anioHoy }).Count) { continue }
        if (-not $act.Count) { continue }
        $porY = [ordered]@{}; $cajY = [ordered]@{}; $pico = 0; $picoY = $null
        foreach ($y in $anios) { $gy = @($desc | Where-Object { $_.carga.Year -eq $y }); $porY["$y"] = $gy.Count; $cajY["$y"] = [int][math]::Round(($gy | Measure-Object cajas_mic -Sum).Sum); if ($gy.Count -gt $pico) { $pico = $gy.Count; $picoY = $y } }
        $techoMes = 0; foreach ($gm in @($desc | Group-Object { $_.carga.ToString('yyyy-MM') })) { if ($gm.Count -gt $techoMes) { $techoMes = $gm.Count } }
        # techo de 4 semanas corridas: conteo por semana de carga, maximo de 4 consecutivas
        $porSem = @{}; foreach ($x in $desc) { $k = (LunesDe $x.carga); if (-not $porSem.ContainsKey($k)) { $porSem[$k] = 0 }; $porSem[$k]++ }
        $techo4 = 0; foreach ($k in $porSem.Keys) { $s = 0; for ($w = 0; $w -lt 4; $w++) { $kk = $k.AddDays(7 * $w); if ($porSem.ContainsKey($kk)) { $s += $porSem[$kk] } }; if ($s -gt $techo4) { $techo4 = $s } }
        $ult28 = @($act | Where-Object { $_.carga -gt $d28 }).Count
        $prev = @($act | Where-Object { $_.carga -gt $d364 -and $_.carga -le $d28 }).Count; $prom4 = [math]::Round($prev / 12, 1)
        $canc8 = @($cn | Where-Object { $_.carga -gt $d56 -and $_.carga -le $hoy.AddDays(14) }).Count
        $rec = @($g.Group | Where-Object { $_.carga -ge $corteAPI }); $recD = @($rec | Where-Object { $_.status -match '^(Descargado|Arribado)' }); $recC = @($rec | Where-Object { $_.status -match '^(Cancelado|Destruida)' })
        $base = $(if ($recD.Count -ge 10) { $recD } else { $desc })
        $lt = @($base | Where-Object { $_.descarga } | ForEach-Object { ($_.descarga - $_.carga).TotalDays })
        $micV = @($base | Where-Object { $_.cajas_mic })
        $tasa = $(if (($recD.Count + $recC.Count) -ge 10) { [math]::Round($recC.Count / ($recD.Count + $recC.Count), 3) } elseif (($desc.Count + $cn.Count) -ge 10) { [math]::Round($cn.Count / ($desc.Count + $cn.Count), 3) } else { $null })
        $ultima = $act[-1].carga
        $diasSin = [int]($hoy - $ultima).TotalDays
        $estado = $(if ($diasSin -gt 90) { 'inactivo' } elseif ($diasSin -gt 28) { 'sin cargar' } elseif (($prom4 -ge 2 -and $ult28 -lt 0.5 * $prom4) -or $canc8 -ge 3) { 'en baja' } else { 'activo' })
        $dia = @($desc | Group-Object { [int]$_.carga.DayOfWeek } | Sort-Object Count -Descending | Select-Object -First 1 | ForEach-Object { @('dom', 'lun', 'mar', 'mié', 'jue', 'vie', 'sáb')[[int]$_.Name] + ' ' + [math]::Round($_.Count * 100 / [math]::Max(1, $desc.Count)) + ' %' })
        $tr = @($base | Where-Object { $_.transportista } | Group-Object transportista | Sort-Object Count -Descending | Select-Object -First 1 | ForEach-Object { "$($_.Name) $([math]::Round($_.Count * 100 / [math]::Max(1, $base.Count))) %" })
        $prods += [ordered]@{ nombre = $g.Name; pais = $pais; estado = $estado; total = $desc.Count; cancelados = $cn.Count; por_anio = $porY; cajas_anio = $cajY; primera = (Ymd $desc[0].carga); ultima = (Ymd $ultima); dias_sin_cargar = $diasSin; pico = $pico; pico_anio = $picoY; techo_mes = $techoMes; techo_4sem = $techo4; ult_4sem = $ult28; prom_4sem_12m = $prom4; cancel_8sem = $canc8; cancel_tasa = $tasa; lt_mediana = (Mediana $lt); lt_p90 = (P90 $lt); lt_n = $lt.Count; caj_cam = $(if ($micV.Count) { [int][math]::Round(($micV | Measure-Object cajas_mic -Average).Average) } else { $null }); dia_carga = $(if ($dia.Count) { $dia[0] } else { '' }); transportista = $(if ($tr.Count) { $tr[0] } else { '' }); anio_actual = $porY["$anioHoy"] }
    }
}
$prods = @($prods | Sort-Object @{ e = { $_.pais } }, @{ e = { $_.total }; Descending = $true })
$lagsProd = [ordered]@{}; $cancelProd = [ordered]@{}
# lag por productor solo con 20+ viajes con fecha de descarga (con 10 la mediana baila: Josemar 4 con 10 viajes movia su carga del
# miercoles a la semana siguiente). Con menos, vale el lag del origen (BR 3, PY 4).
foreach ($p in $prods) { if ($p.lt_n -ge 20 -and $null -ne $p.lt_mediana) { $lagsProd[$p.nombre] = [int]$p.lt_mediana }; if ($null -ne $p.cancel_tasa) { $cancelProd[$p.nombre] = $p.cancel_tasa } }

# ---- 4) concentracion por año
$conc = [ordered]@{}
foreach ($y in $anios) { $gy = @($ok | Where-Object { $_.pais -eq 'BR' -and $_.carga.Year -eq $y } | Group-Object productor | Sort-Object Count -Descending); if (-not $gy.Count) { continue }; $n = ($gy | Measure-Object Count -Sum).Sum; $conc["$y"] = [ordered]@{ productores = $gy.Count; top1 = $gy[0].Name; top1_pct = [math]::Round($gy[0].Count * 100 / $n); top3_pct = [math]::Round((($gy | Select-Object -First 3 | Measure-Object Count -Sum).Sum) * 100 / $n); con_20 = @($gy | Where-Object { $_.Count -ge 20 }).Count } }

$ultCarga = ($ok | Sort-Object carga | Select-Object -Last 1).carga
$res = [ordered]@{
    generado = (Get-Date).ToString('yyyy-MM-dd HH:mm'); hoy = (Ymd $hoy); corte = (Ymd $ultCarga)
    fuentes = [ordered]@{ historico = $(if ($histFile) { $histFile.Name } else { $null }); historico_hasta = (Ymd $corteAPI.AddDays(-1)); aloha = $apiFile.Name; aloha_desde = (Ymd $corteAPI); filas = $todo.Count; descargados = $ok.Count; cancelados = $canc.Count }
    criterios = @('Año = año de la fecha de carga. Descargado = status Descargado o Arribado.', 'Se excluyen filas que no son banana (Varios, Papa, Boniato, Cebolla, Abacaxi, Registro, xx, Bahia + Exoticos).', 'Cajas MIC fuera de 300-1.500 no cuentan en cajas. Lead time = descarga - carga, descartando <0 o >30 dias.', 'Pais = columna Pais del export o, si esta vacia, el nombre del productor (Paraguay... / ... PY = PY).', 'Referencia semanal = camiones por semana de DESCARGA (lunes a sabado; lo que llega domingo cuenta para la semana que arranca), semana n = la n-esima del año; promedio de los años anteriores al actual.', 'Semaforo: activo = cargo en los ultimos 28 dias; en baja = cargo pero menos de la mitad de su promedio de 4 semanas de los ultimos 12 meses, o 3+ cancelaciones en 8 semanas; sin cargar = 29 a 90 dias; inactivo = mas de 90 dias.', 'Solo cajas y camiones, sin precios.')
    anios = @($anios | ForEach-Object { "$_" })
    por_anio = $porAnio
    semanas_ref = $semRef
    semana_actual_n = (SemanaN (LunesDe $hoy))
    concentracion_BR = $conc
    productores = $prods
    lags_productor = $lagsProd
    cancel_tasa_productor = $cancelProd
}
$json = $res | ConvertTo-Json -Depth 10 -Compress
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding $false))
$act = @($prods | Where-Object { $_.estado -ne 'inactivo' })
Write-Host ("  historico_cargas.json: {0} filas ({1} descargados, {2} cancelados) · {3} productores con ficha ({4} activos/recientes) · semana {5} del año: referencia {6} camiones/sem · {7} KB" -f $todo.Count, $ok.Count, $canc.Count, $prods.Count, $act.Count, $res.semana_actual_n, $semRef[$res.semana_actual_n - 1].prom, [math]::Round((Get-Item $Out).Length / 1KB))
