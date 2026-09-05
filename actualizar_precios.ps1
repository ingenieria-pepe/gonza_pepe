# ==========================================================================
# actualizar_precios.ps1
# Baja la serie semanal Cepea (Nanica primeira - produtor - Norte SC)
# y la inyecta en index.html (entre /*__CEPEA_JSON__*/ y /*__END__*/).
# Ejecutar viernes (Cepea publica viernes a la tarde).
#
# Uso: doble clic, o desde PowerShell:
#   & "C:\Users\Usuario\Desktop\poronga\actualizar_precios.ps1"
# ==========================================================================

$ErrorActionPreference = "Stop"

# Evitar que Windows se suspenda durante la ejecucion del script.
# (Fix tras el 29/05/2026: el sistema entro en suspension a los ~18 min y mato el cron.)
try {
    Add-Type -Name PowerKeepAlive -Namespace Win32Helper -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern uint SetThreadExecutionState(uint esFlags);
"@ -ErrorAction SilentlyContinue
    # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x00000001)
    [Win32Helper.PowerKeepAlive]::SetThreadExecutionState(0x80000001) | Out-Null
} catch {}

$base = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($base)) { $base = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($base)) { $base = (Get-Location).Path }

# --- Lector de .xlsx SIN Excel (headless) ----------------------------------
# Este servidor NO tiene Office instalado. Excel via COM obliga a Office + una
# sesion de escritorio abierta; ImportExcel (EPPlus) lee el xlsx directo.
# Instalar una sola vez si falta:  Install-Module ImportExcel -Scope CurrentUser
try {
    Import-Module ImportExcel -ErrorAction Stop
} catch {
    Write-Host "ERROR: falta el modulo ImportExcel (necesario para leer los .xlsx)." -ForegroundColor Red
    Write-Host "       Instalalo con:  Install-Module ImportExcel -Scope CurrentUser -Force" -ForegroundColor Red
    exit 1
}
$fuentes = Join-Path $base "fuentes"
$indexHtml = Join-Path $base "index.html"
# Lista de archivos HTML a actualizar (todos los que tengan los marcadores Cepea)
$htmlTargets = @(
    (Join-Path $base "index.html"),
    (Join-Path $base "index_brasil.html"),
    (Join-Path $base "index_paraguay_bolivia.html")
)
$xlsxPath = Join-Path $fuentes "precios_banana_SC_2023-2026.xlsx"
$jsonPath = Join-Path $fuentes "precios_cepea.json"
$waConfigPath = Join-Path $base "config\whatsapp.json"
$waStatePath  = Join-Path $fuentes "state_whatsapp.json"

# Año de cobertura: actual y 3 anteriores
$anoFinal = (Get-Date).Year
$anoInicial = $anoFinal - 3

# ==========================================================================
# Helpers Excel COM
# --------------------------------------------------------------------------
# Motivo (02/09/2026): Quit() + ReleaseComObject solo sobre la Application NO
# mata el proceso EXCEL.EXE. Quedaban zombies acumulandose (uno del 19/08 vivio
# 14 dias) y cuando el script intentaba abrir Excel se colgaba esperandolos,
# hasta que el timeout de 1h de la tarea programada mataba la corrida.
# Paso el 02/09 12:00 (LastTaskResult 267014 = task terminated) y dejo el
# dashboard congelado desde el 24/07.
#
# Fix en 3 capas:
#   1. Al arrancar se matan los EXCEL huerfanos (sin ventana = instancias COM
#      abandonadas). Los que tienen ventana son del usuario y NO se tocan.
#   2. Al cerrar se sueltan hojas y workbook ANTES del Quit, con
#      FinalReleaseComObject y GC completo.
#   3. Red de seguridad: se recuerda el PID de NUESTRA instancia y si sobrevive
#      al Quit se lo mata. Surgical: nunca toca otro Excel.
# ==========================================================================

function Clear-ExcelHuerfanos {
    # Mata solo instancias COM abandonadas (MainWindowHandle = 0).
    # Un Excel abierto por el usuario SIEMPRE tiene ventana -> no se toca.
    $huerfanos = @(Get-Process EXCEL -ErrorAction SilentlyContinue |
                   Where-Object { $_.MainWindowHandle -eq 0 })
    foreach ($h in $huerfanos) {
        try {
            $edad = [int]((Get-Date) - $h.StartTime).TotalMinutes
            $h.Kill()
            Write-Host "    [excel] huerfano PID $($h.Id) eliminado (llevaba $edad min)" -ForegroundColor DarkYellow
        } catch {}
    }
    if ($huerfanos.Count -gt 0) { Start-Sleep -Milliseconds 400 }
    return $huerfanos.Count
}

function New-ExcelCOM {
    # Crea la instancia y se guarda su PID para poder matarla despues si hace falta.
    $antes = @(Get-Process EXCEL -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $app = New-Object -ComObject Excel.Application
    $app.Visible = $false
    $app.DisplayAlerts = $false
    $despues = @(Get-Process EXCEL -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $nuevoPid = @($despues | Where-Object { $antes -notcontains $_ }) | Select-Object -First 1
    return [PSCustomObject]@{ App = $app; ProcId = $nuevoPid }
}

function Close-ExcelCOM {
    param(
        $Handle,                 # lo que devolvio New-ExcelCOM
        $Workbook   = $null,
        [object[]]$Extra = @()   # hojas/rangos a soltar primero
    )
    foreach ($o in $Extra) {
        if ($null -ne $o) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch {} }
    }
    if ($null -ne $Workbook) {
        try { $Workbook.Close($false) | Out-Null } catch {}
        try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Workbook) } catch {}
    }
    if ($null -ne $Handle -and $null -ne $Handle.App) {
        try { $Handle.App.Quit() | Out-Null } catch {}
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Handle.App) } catch {}
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()

    # Red de seguridad: si NUESTRO proceso sobrevivio, matarlo.
    if ($null -ne $Handle -and $Handle.ProcId) {
        Start-Sleep -Milliseconds 400
        $p = Get-Process -Id $Handle.ProcId -ErrorAction SilentlyContinue
        if ($p) {
            try { $p.Kill(); Write-Host "    [excel] PID $($Handle.ProcId) no cerro solo, forzado" -ForegroundColor DarkYellow } catch {}
        }
    }
}

$nHuerfanos = Clear-ExcelHuerfanos
if ($nHuerfanos -gt 0) {
    Write-Host "[excel] $nHuerfanos instancia(s) huerfana(s) limpiada(s) antes de arrancar" -ForegroundColor Yellow
}

# Fingerprint de browser para sitios con proteccion anti-bot.
# hfbrasil.org.br empezo a devolver 403 al UA pelado "Mozilla/5.0" (detectado
# 03/09/2026 — hasta el 02/09 andaba). Necesita UA completo + Accept/Accept-Language.
# NO usar esto para las APIs (NASA POWER, Open-Meteo): ahi el UA simple va bien.
$UA_BROWSER = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
$HDR_BROWSER = @{
    'Accept'                    = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8'
    'Accept-Language'           = 'pt-BR,pt;q=0.9,es;q=0.8,en;q=0.7'
    'Upgrade-Insecure-Requests' = '1'
}

# --------------------------------------------------------------------------
# REGISTRO DE FALLAS DEL PIPELINE  [agregado 04/09/2026]
#
# Antes, si el paso 1 fallaba el script hacia `exit 1` y moria ANTES del paso
# de WhatsApp — o sea fallaba justo de la forma que apaga el canal por el que
# te enterarias. Paso de verdad: Cepea empezo a dar 403 y la tarea murio con
# codigo 1 durante dias sin avisar a nadie.
# Ahora cada paso que falla se anota aca y el pipeline sigue con lo que pueda;
# al final se manda un WhatsApp de fallas. Solo se aborta si de verdad no hay
# nada con que seguir.
# --------------------------------------------------------------------------
$script:fallosPipeline = @()
function Add-Falla {
    param([string]$Paso, [string]$Detalle, [switch]$Fatal)
    $script:fallosPipeline += [PSCustomObject]@{ paso=$Paso; detalle=$Detalle; fatal=[bool]$Fatal }
    $col = if ($Fatal) { 'Red' } else { 'DarkYellow' }
    Write-Host "    [falla] $Paso : $Detalle" -ForegroundColor $col
}

# 1) Descargar la planilla de Cepea
Write-Host "[1/6] Descargando Cepea ($anoInicial-$anoFinal)..." -ForegroundColor Cyan
$url = "https://www.hfbrasil.org.br/br/estatistica/preco/exportar.aspx?produto=4&regiao%5B%5D=25&periodicidade=diario&ano_inicial=$anoInicial&ano_final=$anoFinal"
$cepeaDesactualizado = $false
try {
    $hdrCepea = $HDR_BROWSER.Clone()
    $hdrCepea['Referer'] = 'https://www.hfbrasil.org.br/'
    Invoke-WebRequest -Uri $url -OutFile $xlsxPath -UserAgent $UA_BROWSER -Headers $hdrCepea -TimeoutSec 60 -ErrorAction Stop
    $tam = (Get-Item $xlsxPath).Length
    Write-Host "    OK ($tam bytes)" -ForegroundColor Green
} catch {
    $msg = $_.Exception.Message
    if (Test-Path $xlsxPath) {
        # Hay cache local: seguir con el xlsx viejo en vez de morir. Los datos
        # quedan desactualizados, y eso se avisa por WhatsApp y en el log.
        $edad = [math]::Round(((Get-Date) - (Get-Item $xlsxPath).LastWriteTime).TotalDays,1)
        Add-Falla -Paso 'Cepea (descarga)' -Detalle "$msg — sigo con el cache de hace $edad dias"
        $cepeaDesactualizado = $true
        Write-Host "    (cache de $edad dias, el pipeline continua)" -ForegroundColor DarkYellow
    } else {
        Add-Falla -Paso 'Cepea (descarga)' -Detalle "$msg — y no hay cache local" -Fatal
        Write-Host "    Sin cache: no hay nada con que seguir." -ForegroundColor Red
        exit 1
    }
}

# 2) Extraer datos del Excel a objeto PSCustom
Write-Host "[2/6] Leyendo Excel Cepea y construyendo dataset..." -ForegroundColor Cyan
$nanica = @()
$promedioMes = [ordered]@{}
$pkg = $null
try {
    $pkg = Open-ExcelPackage -Path $xlsxPath
    $ws  = $pkg.Workbook.Worksheets | Select-Object -First 1
    # La ultima fila del export de Cepea es el pie "Fonte: Hortifruti/Cepea",
    # por eso el loop llega hasta $total-1 (igual que la version con COM).
    $total = $ws.Dimension.End.Row
    for ($r = 2; $r -lt $total; $r++) {
        $prod = $ws.Cells[$r,1].Text
        if ($prod -like "Nanica*") {
            $dia = [int]$ws.Cells[$r,3].Text
            $mes = [int]$ws.Cells[$r,4].Text
            $ano = [int]$ws.Cells[$r,5].Text
            $precio = [double]($ws.Cells[$r,8].Text -replace ',','.')
            $nanica += [PSCustomObject]@{
                fecha  = ("{0:0000}-{1:00}-{2:00}" -f $ano,$mes,$dia)
                anio   = $ano
                mes    = $mes
                precio = [math]::Round($precio,2)
            }
        }
    }
}
finally {
    if ($pkg) { Close-ExcelPackage $pkg -NoSave }
}
$nanica = $nanica | Sort-Object fecha
Write-Host "    Semanas obtenidas: $($nanica.Count)" -ForegroundColor Green

# Promedios mensuales (todos los anios)
1..12 | ForEach-Object {
    $m = $_
    $vals = ($nanica | Where-Object { $_.mes -eq $m }).precio
    if ($vals.Count -gt 0) {
        $avg = ($vals | Measure-Object -Average).Average
        $promedioMes["$m"] = [math]::Round($avg, 2)
    }
}

$data = [PSCustomObject]@{
    fuente            = "Hortifruti/Cepea - hfbrasil.org.br"
    producto          = "Nanica primeira - produtor"
    region            = "Norte de Santa Catarina"
    unidad            = "R$/kg"
    actualizado       = (Get-Date -Format "yyyy-MM-dd HH:mm")
    ultima_semana     = $nanica[-1].fecha
    ultimo_precio     = $nanica[-1].precio
    promedio_mensual  = $promedioMes
    serie             = $nanica
}

# ==========================================================================
# 3) Procesar cargas Almar (compras semanales por productor)
# ==========================================================================
Write-Host "[3/6] Procesando cargas Almar 2026..." -ForegroundColor Cyan
$cargasFile = Join-Path $fuentes "cargas 2026.xlsx"
$KG_CAJA_NETO   = 22   # banana adentro de la caja
$KG_CAJA_BRUTO  = 26   # caja + banana
$SERVICIOS_CAJA = 16   # R$/caja - envalado + paletizado + flete interno (a sumar al precio Cepea del cacho)

$almarRecords = @()
if (Test-Path $cargasFile) {
    $YEAR_CARGAS = 2026
    $pkgC = $null
    try {
        $pkgC = Open-ExcelPackage -Path $cargasFile
        foreach ($wsC in $pkgC.Workbook.Worksheets) {
          try {
            if ($wsC.Name -eq 'madre') { continue }
            if ($null -eq $wsC.Dimension) { continue }   # hoja vacia
            $rowsC = $wsC.Dimension.End.Row
            $semana = $null; $fechaFin = $null
            for ($r = 1; $r -le $rowsC; $r++) {
                $colB = ([string]$wsC.Cells[$r,2].Text).Trim()
                $colC = ([string]$wsC.Cells[$r,3].Text).Trim()
                $colD = ([string]$wsC.Cells[$r,4].Text).Trim()
                $colE = ([string]$wsC.Cells[$r,5].Text).Trim()
                $colF = ([string]$wsC.Cells[$r,6].Text).Trim()
                if ($colC -match '^Semana\s+(\d+)') { $semana = [int]$Matches[1]; continue }
                if ($colC -match '(\d{1,2})/(\d{1,2})\s*al\s*(\d{1,2})/(\d{1,2})') {
                    $dia = [int]$Matches[3]; $mes = [int]$Matches[4]
                    try { $fechaFin = Get-Date -Year $YEAR_CARGAS -Month $mes -Day $dia } catch { $fechaFin = $null }
                    continue
                }
                if ($colB -eq 'Productor' -or $colB -eq '') { continue }
                if ($colB -match '^(?i)total') { continue }
                $precio = 0.0; $ok = $false
                try { $precio = [double]($colD -replace ',','.'); if ($precio -gt 0 -and $precio -lt 500) { $ok = $true } } catch {}
                if (-not $ok) { continue }
                $cargas = 1.0
                try { $cargas = [double]($colC -replace ',','.'); if ($cargas -le 0) { $cargas = 1.0 } } catch { $cargas = 1.0 }
                $almarRecords += [PSCustomObject]@{
                    fecha         = if ($fechaFin) { $fechaFin.ToString('yyyy-MM-dd') } else { $null }
                    semana        = $semana
                    productor     = $colB
                    cargas        = $cargas
                    precio        = $precio
                    transportista = $colE
                    despachante   = $colF
                }
            }
          }
          finally {
            # EPPlus no deja referencias COM sueltas: no hay nada que soltar por hoja.
          }
        }
    }
    finally {
        if ($pkgC) { Close-ExcelPackage $pkgC -NoSave }
    }
    Write-Host "    Operaciones parseadas: $($almarRecords.Count)" -ForegroundColor Green
} else {
    Write-Host "    No encontre $cargasFile - omito." -ForegroundColor Yellow
}

# Agregados semanales (avg ponderado por cargas)
$almarSemanas = @()
$almarRecords | Where-Object { $_.fecha -ne $null } | Group-Object fecha | Sort-Object Name | ForEach-Object {
    $sumCargas = ($_.Group | Measure-Object cargas -Sum).Sum
    $sumValor  = ($_.Group | ForEach-Object { $_.precio * $_.cargas } | Measure-Object -Sum).Sum
    $avgCaja   = if ($sumCargas -gt 0) { $sumValor / $sumCargas } else { 0 }
    $almarSemanas += [PSCustomObject]@{
        fecha            = $_.Name
        cargas           = [math]::Round($sumCargas, 1)
        precio_avg_caja  = [math]::Round($avgCaja, 2)
        precio_avg_kg    = [math]::Round($avgCaja / $KG_CAJA_NETO, 3)
    }
}

# Agregados por productor (avg ponderado por cargas)
$almarProductores = @()
$almarRecords | Group-Object { ($_.productor).ToLower().Trim() } | ForEach-Object {
    $sumCargas = ($_.Group | Measure-Object cargas -Sum).Sum
    $sumValor  = ($_.Group | ForEach-Object { $_.precio * $_.cargas } | Measure-Object -Sum).Sum
    $avgPrecio = if ($sumCargas -gt 0) { $sumValor / $sumCargas } else { 0 }
    $minP = ($_.Group | Measure-Object precio -Minimum).Minimum
    $maxP = ($_.Group | Measure-Object precio -Maximum).Maximum
    $orig = $_.Group[0].productor
    $nombre = $orig.Substring(0,1).ToUpper() + $orig.Substring(1).ToLower()
    $almarProductores += [PSCustomObject]@{
        productor       = $nombre
        cargas          = [math]::Round($sumCargas, 1)
        precio_avg_caja = [math]::Round($avgPrecio, 2)
        precio_avg_kg   = [math]::Round($avgPrecio / $KG_CAJA_NETO, 3)
        precio_min      = $minP
        precio_max      = $maxP
        n_operaciones   = $_.Count
    }
}
$almarProductores = $almarProductores | Sort-Object cargas -Descending

$data | Add-Member -MemberType NoteProperty -Name 'almar' -Value ([PSCustomObject]@{
    variedad        = "Nanica/Cavendish"
    kg_caja_neto    = $KG_CAJA_NETO
    kg_caja_bruto   = $KG_CAJA_BRUTO
    servicios_caja  = $SERVICIOS_CAJA
    nota_servicios  = "R$/caja adicional sobre el precio Cepea del cacho: envalado, paletizado y flete interno hasta acopio."
    total_cargas    = [math]::Round(($almarSemanas | Measure-Object cargas -Sum).Sum, 1)
    n_productores   = $almarProductores.Count
    semanas         = $almarSemanas
    productores     = $almarProductores
})

Write-Host "    Semanas con datos: $($almarSemanas.Count) | Productores: $($almarProductores.Count) | Cargas YTD: $($data.almar.total_cargas)" -ForegroundColor Green

# ==========================================================================
# 3.5) Bajar clima de zonas productoras (Open-Meteo, API gratuita sin key)
# ==========================================================================
Write-Host "[clima] Bajando clima de zonas productoras..." -ForegroundColor Cyan

$regionesClima = @(
    @{ id="br_luizalves";  pais="Brasil";   ciudad="Luiz Alves";          bandera="BR"; lat=-26.72; lon=-48.93 },
    @{ id="br_guaramirim"; pais="Brasil";   ciudad="Guaramirim";          bandera="BR"; lat=-26.47; lon=-49.00 },
    @{ id="py_tembiapora"; pais="Paraguay"; ciudad="Tembiapora";          bandera="PY"; lat=-24.92; lon=-55.98 },
    @{ id="bo_yapacani";   pais="Bolivia";  ciudad="Yapacani (default)";  bandera="BO"; lat=-17.40; lon=-63.85 }
)

$weatherCodeMap = @{
    0  = @{ desc="Despejado"; emoji="☀️" }
    1  = @{ desc="Mayormente despejado"; emoji="🌤️" }
    2  = @{ desc="Parcialmente nublado"; emoji="⛅" }
    3  = @{ desc="Nublado"; emoji="☁️" }
    45 = @{ desc="Niebla"; emoji="🌫️" }
    48 = @{ desc="Niebla con escarcha"; emoji="🌫️" }
    51 = @{ desc="Llovizna leve"; emoji="🌦️" }
    53 = @{ desc="Llovizna"; emoji="🌦️" }
    55 = @{ desc="Llovizna densa"; emoji="🌦️" }
    61 = @{ desc="Lluvia leve"; emoji="🌧️" }
    63 = @{ desc="Lluvia"; emoji="🌧️" }
    65 = @{ desc="Lluvia fuerte"; emoji="🌧️" }
    71 = @{ desc="Nieve leve"; emoji="❄️" }
    73 = @{ desc="Nieve"; emoji="❄️" }
    75 = @{ desc="Nieve fuerte"; emoji="❄️" }
    80 = @{ desc="Chubascos"; emoji="🌦️" }
    81 = @{ desc="Chubascos"; emoji="🌧️" }
    82 = @{ desc="Chubascos violentos"; emoji="⛈️" }
    95 = @{ desc="Tormenta"; emoji="⛈️" }
    96 = @{ desc="Tormenta con granizo"; emoji="⛈️" }
    99 = @{ desc="Tormenta violenta"; emoji="⛈️" }
}

function Get-WCode {
    param([int]$c)
    if ($weatherCodeMap.ContainsKey($c)) { return $weatherCodeMap[$c] }
    return @{ desc="Desconocido"; emoji="❓" }
}

$climaData = @()
foreach ($reg in $regionesClima) {
    $tag = "$($reg.bandera) $($reg.ciudad)"
    Write-Host "    $tag... " -NoNewline
    $url = "https://api.open-meteo.com/v1/forecast?latitude=$($reg.lat)&longitude=$($reg.lon)&current=temperature_2m,relative_humidity_2m,precipitation,wind_speed_10m,weather_code&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,weather_code&past_days=92&forecast_days=7&timezone=auto"
    try {
        $r = Invoke-RestMethod -Uri $url -ErrorAction Stop -UserAgent "Mozilla/5.0"
    } catch {
        Write-Host "FALLO ($($_.Exception.Message))" -ForegroundColor Red
        continue
    }

    $codeNow = Get-WCode -c ([int]$r.current.weather_code)
    $diarios = @(); $forecast = @(); $pastWeek = @(); $alertas = @()
    $hoy = (Get-Date).Date

    for ($i=0; $i -lt $r.daily.time.Count; $i++) {
        $fecha = $r.daily.time[$i]
        # Saltar dias sin datos (Open-Meteo a veces devuelve vacios en los mas viejos)
        $rawMin = $r.daily.temperature_2m_min[$i]
        $rawMax = $r.daily.temperature_2m_max[$i]
        if ([string]::IsNullOrWhiteSpace([string]$rawMin) -or [string]::IsNullOrWhiteSpace([string]$rawMax)) { continue }
        $tmin = [double]$rawMin
        $tmax = [double]$rawMax
        $lluvia = [double]$r.daily.precipitation_sum[$i]
        $wcode = [int]$r.daily.weather_code[$i]
        $wm = Get-WCode -c $wcode
        $entry = [PSCustomObject]@{
            fecha = $fecha
            tmin  = [math]::Round($tmin,1)
            tmax  = [math]::Round($tmax,1)
            lluvia = [math]::Round($lluvia,1)
            emoji = $wm.emoji
            desc  = $wm.desc
        }
        $diarios += $entry
        $fechaDate = [DateTime]::Parse($fecha)
        if ($fechaDate -gt $hoy) {
            $forecast += $entry
            if ($tmax -ge 32) { $alertas += "🔥 $fecha max ${tmax}°C - estres por calor" }
            if ($tmin -le 14 -and $tmin -gt 2) { $alertas += "🥶 $fecha min ${tmin}°C - frena crecimiento" }
            if ($tmin -le 2)  { $alertas += "❄️ $fecha min ${tmin}°C - RIESGO HELADA" }
            if ($lluvia -ge 50) { $alertas += "🌧️ $fecha ${lluvia}mm - riesgo Sigatoka/anegamiento" }
        } elseif ($fechaDate -lt $hoy) {
            $pastWeek += $entry
        }
    }

    $pastWeekShort = $pastWeek | Select-Object -Last 7
    $semTmin = ($pastWeekShort | Measure-Object tmin -Minimum).Minimum
    $semTmax = ($pastWeekShort | Measure-Object tmax -Maximum).Maximum
    $semLluvia = ($pastWeekShort | Measure-Object lluvia -Sum).Sum

    # Agregado semanal (anclado a viernes para matchear Cepea)
    $historicoSemanal = @()
    $daysToFriday = (([int]$hoy.DayOfWeek - 5 + 7) % 7)
    if ($daysToFriday -eq 0 -and $hoy.DayOfWeek -ne [DayOfWeek]::Friday) { $daysToFriday = 7 }
    $lastFriday = $hoy.AddDays(-$daysToFriday)
    for ($w = 0; $w -lt 13; $w++) {
        $weekEnd = $lastFriday.AddDays(-$w * 7)
        $weekStart = $weekEnd.AddDays(-6)
        $weekData = $pastWeek | Where-Object {
            $d = [DateTime]::Parse($_.fecha).Date
            $d -ge $weekStart -and $d -le $weekEnd
        }
        if ($weekData.Count -eq 0) { continue }
        $historicoSemanal += [PSCustomObject]@{
            fecha = $weekEnd.ToString('yyyy-MM-dd')
            tmin_avg = [math]::Round(($weekData | Measure-Object tmin -Average).Average, 1)
            tmax_avg = [math]::Round(($weekData | Measure-Object tmax -Average).Average, 1)
            lluvia_total = [math]::Round(($weekData | Measure-Object lluvia -Sum).Sum, 1)
            n_dias = $weekData.Count
        }
    }
    $historicoSemanal = $historicoSemanal | Sort-Object fecha

    $climaData += [PSCustomObject]@{
        id = $reg.id
        pais = $reg.pais
        ciudad = $reg.ciudad
        bandera = $reg.bandera
        lat = $reg.lat
        lon = $reg.lon
        actual = [PSCustomObject]@{
            temp_c        = [math]::Round([double]$r.current.temperature_2m,1)
            humedad       = [int]$r.current.relative_humidity_2m
            lluvia_mm     = [math]::Round([double]$r.current.precipitation,1)
            viento_kmh    = [math]::Round([double]$r.current.wind_speed_10m,0)
            weather_desc  = $codeNow.desc
            weather_emoji = $codeNow.emoji
        }
        semana_pasada = [PSCustomObject]@{
            tmin_c          = [math]::Round([double]$semTmin,1)
            tmax_c          = [math]::Round([double]$semTmax,1)
            lluvia_total_mm = [math]::Round([double]$semLluvia,1)
        }
        forecast_7d = $forecast
        historico_semanal = $historicoSemanal
        alertas = $alertas
    }
    Write-Host "OK $($r.current.temperature_2m)°C $($codeNow.emoji)" -ForegroundColor Green
}

$data | Add-Member -MemberType NoteProperty -Name 'clima' -Value ([PSCustomObject]@{
    actualizado = (Get-Date -Format "yyyy-MM-dd HH:mm")
    fuente      = "Open-Meteo API"
    regiones    = $climaData
})

Write-Host "    Regiones de clima cargadas: $($climaData.Count)" -ForegroundColor Green

# ==========================================================================
# 3.6) Analisis estadistico PRO: correlacion lag clima BR ↔ precio Cepea
# ==========================================================================
Write-Host "[pro] Bajando archivo historico de clima BR y calculando correlaciones..." -ForegroundColor Cyan

function Get-Pearson { param($x, $y)
    $n = [Math]::Min($x.Count, $y.Count)
    if ($n -lt 3) { return 0.0 }
    $sumX = 0.0; $sumY = 0.0
    for ($i=0; $i -lt $n; $i++) { $sumX += $x[$i]; $sumY += $y[$i] }
    $mX = $sumX / $n; $mY = $sumY / $n
    $sXY = 0.0; $sX2 = 0.0; $sY2 = 0.0
    for ($i=0; $i -lt $n; $i++) {
        $dx = $x[$i] - $mX; $dy = $y[$i] - $mY
        $sXY += $dx * $dy; $sX2 += $dx * $dx; $sY2 += $dy * $dy
    }
    $den = [Math]::Sqrt($sX2 * $sY2)
    if ($den -le 0) { return 0.0 }
    return [math]::Round($sXY / $den, 3)
}

function Get-LinReg { param($x, $y)
    $n = [Math]::Min($x.Count, $y.Count)
    if ($n -lt 3) { return @{ slope=0.0; intercept=0.0; r2=0.0; rmse=0.0; n=$n } }
    $sumX = 0.0; $sumY = 0.0
    for ($i=0; $i -lt $n; $i++) { $sumX += $x[$i]; $sumY += $y[$i] }
    $mX = $sumX / $n; $mY = $sumY / $n
    $sXY = 0.0; $sX2 = 0.0; $sY2 = 0.0
    for ($i=0; $i -lt $n; $i++) {
        $dx = $x[$i] - $mX; $dy = $y[$i] - $mY
        $sXY += $dx * $dy; $sX2 += $dx * $dx; $sY2 += $dy * $dy
    }
    if ($sX2 -le 0) { return @{ slope=0.0; intercept=$mY; r2=0.0; rmse=0.0; n=$n } }
    $slope = $sXY / $sX2
    $intercept = $mY - $slope * $mX
    $r2 = if ($sY2 -gt 0) { ($sXY * $sXY) / ($sX2 * $sY2) } else { 0 }
    $sumE2 = 0.0
    for ($i=0; $i -lt $n; $i++) {
        $pred = $intercept + $slope * $x[$i]
        $err = $y[$i] - $pred
        $sumE2 += $err * $err
    }
    $rmse = [Math]::Sqrt($sumE2 / $n)
    return @{
        slope     = [math]::Round($slope, 5)
        intercept = [math]::Round($intercept, 5)
        r2        = [math]::Round($r2, 4)
        rmse      = [math]::Round($rmse, 4)
        n         = $n
    }
}

$brRegiones = $regionesClima | Where-Object { $_.bandera -eq 'BR' }
$correlData = @()
$startDate = $nanica[0].fecha
$endDate = (Get-Date).Date.ToString('yyyy-MM-dd')
$cacheDir = Join-Path $fuentes "clima_archive_cache"
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }

# --------------------------------------------------------------------------
# ANCLAJE AL PRECIO ACTUAL  (agregado 03/09/2026)
#
# PROBLEMA: el forecast mezclaba prediccion climatica (peso r²) con el promedio
# historico del mes (peso 1-r²). Como r² ronda 0,12, el 88% del pronostico era el
# promedio historico — un numero que NO mira donde esta parado el mercado hoy.
# Caso real del 02/09/2026: ultimo Cepea 0,99 y pronostico 1,81 para la semana
# siguiente (+83% en 7 dias), porque el baseline de setiembre es 1,86.
#
# FIX: medir cuanto se desvia el mercado de su propia norma estacional y arrastrar
# ese desvio hacia adelante, decayendo hacia la norma con un phi estimado de los
# propios datos. No toca el modelo climatico: le aplica un factor de nivel a la
# prediccion final. Con desvio 1,0 el factor es 1 y el comportamiento es el viejo.
# --------------------------------------------------------------------------

# Serie de desvio: precio / promedio historico de SU mes. 1,0 = justo en la norma.
$devSerie = @()
$devVistas = @{}
foreach ($nD in $nanica) {
    if ($devVistas.ContainsKey($nD.fecha)) { continue }   # la serie trae fechas repetidas
    $devVistas[$nD.fecha] = $true
    $mesD = [int]([DateTime]::Parse($nD.fecha).Month)
    $blD  = if ($promedioMes.Contains("$mesD")) { [double]$promedioMes["$mesD"] } else { 0 }
    if ($blD -le 0) { continue }
    $devSerie += ([double]$nD.precio / $blD)
}

# phi = persistencia semanal del desvio, via AR(1) sobre (dev - 1).
# phi alto = los desvios duran; phi bajo = el precio vuelve rapido a la norma.
$phiDev = 0.85
$phiFuente = 'default (sin datos suficientes)'
if ($devSerie.Count -ge 30) {
    $xPrev = @(); $yNext = @()
    for ($i = 1; $i -lt $devSerie.Count; $i++) {
        $xPrev += ($devSerie[$i-1] - 1.0)
        $yNext += ($devSerie[$i]   - 1.0)
    }
    $regDev = Get-LinReg $xPrev $yNext
    $phiDev = [double]$regDev.slope
    $phiFuente = "AR(1) n=$($regDev.n) r2=$($regDev.r2)"
}
if ($phiDev -lt 0)    { $phiDev = 0 }      # sin persistencia -> vuelve directo a la norma
if ($phiDev -gt 0.98) { $phiDev = 0.98 }   # techo: nunca asumir desvio permanente

# Desvio actual: EWMA de las ultimas 3 semanas (alpha 0,6) para no colgarse de un
# solo dato ruidoso. Clampeado por si entra basura en la serie.
$devActual = 1.0
if ($devSerie.Count -ge 1) {
    $devUlt = @($devSerie[[Math]::Max(0, $devSerie.Count - 3)..($devSerie.Count - 1)])
    [array]::Reverse($devUlt)   # $devUlt[0] = el mas reciente
    $numD = 0.0; $denD = 0.0; $alphaD = 0.6
    for ($i = 0; $i -lt $devUlt.Count; $i++) {
        $pesoD = [Math]::Pow(1 - $alphaD, $i)
        $numD += $pesoD * $devUlt[$i]; $denD += $pesoD
    }
    if ($denD -gt 0) { $devActual = $numD / $denD }
}
if ($devActual -lt 0.35) { $devActual = 0.35 }
if ($devActual -gt 2.50) { $devActual = 2.50 }

Write-Host ("    Anclaje: mercado al {0:p0} de su norma estacional · phi {1:n3} [{2}]" -f $devActual, $phiDev, $phiFuente) -ForegroundColor DarkCyan

# Helper: fetch histórico diario con NASA POWER (primaria) + Open-Meteo (fallback) + cache
function Get-WeatherHistory {
    param([string]$regId, [double]$lat, [double]$lon, [string]$start, [string]$end)
    $cachePath = Join-Path $cacheDir "$regId.json"
    $startNoDash = $start.Replace('-','')
    $endNoDash   = $end.Replace('-','')

    # Intentar cache primero (si cubre el rango y es del día)
    $daily = @()
    $cacheValid = $false
    if (Test-Path $cachePath) {
        try {
            $cached = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cached.daily -and $cached.daily.Count -gt 0) {
                $lastCacheDate = ($cached.daily | Select-Object -Last 1).fecha
                # cache válido si llega hasta hace ≤7 días
                if ([DateTime]::Parse($lastCacheDate) -ge (Get-Date).AddDays(-7)) {
                    $daily = $cached.daily
                    $cacheValid = $true
                    Write-Host "(cache " -NoNewline -ForegroundColor DarkCyan
                }
            }
        } catch {}
    }

    if (-not $cacheValid) {
        # NASA POWER (primario)
        $urlN = "https://power.larc.nasa.gov/api/temporal/daily/point?parameters=T2M_MIN,T2M_MAX,PRECTOTCORR&community=AG&longitude=$lon&latitude=$lat&start=$startNoDash&end=$endNoDash&format=JSON"
        try {
            $resp = Invoke-RestMethod -Uri $urlN -ErrorAction Stop -TimeoutSec 45 -UserAgent "Mozilla/5.0"
            $tminH = $resp.properties.parameter.T2M_MIN
            $tmaxH = $resp.properties.parameter.T2M_MAX
            $pcpH  = $resp.properties.parameter.PRECTOTCORR
            foreach ($prop in $tminH.PSObject.Properties) {
                $k = $prop.Name  # YYYYMMDD
                if ($k -notmatch '^\d{8}$') { continue }
                $tmin = [double]$prop.Value
                if ($tmin -le -900) { continue }  # NASA usa -999 para missing
                $tmax = [double]$tmaxH.$k
                $llu  = [double]$pcpH.$k
                if ($llu -le -900) { $llu = 0 }
                $fechaIso = "$($k.Substring(0,4))-$($k.Substring(4,2))-$($k.Substring(6,2))"
                $daily += [PSCustomObject]@{ fecha=$fechaIso; tmin=$tmin; tmax=$tmax; lluvia=$llu }
            }
            Write-Host "(NASA " -NoNewline -ForegroundColor DarkGreen
            # Guardar cache
            @{ source='NASA POWER'; updated=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); daily=$daily } | ConvertTo-Json -Depth 5 | Out-File $cachePath -Encoding UTF8
        } catch {
            Write-Host "(NASA fallo, prueba Open-Meteo) " -NoNewline -ForegroundColor DarkYellow
            # Fallback Open-Meteo archive
            $urlA = "https://archive-api.open-meteo.com/v1/archive?latitude=$lat&longitude=$lon&start_date=$start&end_date=$end&daily=temperature_2m_max,temperature_2m_min,precipitation_sum&timezone=auto"
            try {
                $arch = Invoke-RestMethod -Uri $urlA -ErrorAction Stop -UserAgent "Mozilla/5.0" -TimeoutSec 30
                for ($i=0; $i -lt $arch.daily.time.Count; $i++) {
                    $rMax = $arch.daily.temperature_2m_max[$i]
                    if ([string]::IsNullOrWhiteSpace([string]$rMax)) { continue }
                    $daily += [PSCustomObject]@{
                        fecha  = $arch.daily.time[$i]
                        tmin   = [double]$arch.daily.temperature_2m_min[$i]
                        tmax   = [double]$arch.daily.temperature_2m_max[$i]
                        lluvia = [double]$arch.daily.precipitation_sum[$i]
                    }
                }
                Write-Host "(Open-Meteo " -NoNewline -ForegroundColor DarkCyan
                @{ source='Open-Meteo archive'; updated=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); daily=$daily } | ConvertTo-Json -Depth 5 | Out-File $cachePath -Encoding UTF8
            } catch {
                # Ambas fallaron, intentar cache aunque sea viejo
                if (Test-Path $cachePath) {
                    try {
                        $cached = Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json
                        if ($cached.daily) {
                            $daily = $cached.daily
                            Write-Host "(cache viejo " -NoNewline -ForegroundColor DarkYellow
                        }
                    } catch {}
                }
            }
        }
    }
    return ,$daily
}

foreach ($br in $brRegiones) {
    Write-Host "    archive $($br.ciudad)... " -NoNewline
    $dailyData = Get-WeatherHistory -regId $br.id -lat $br.lat -lon $br.lon -start $startDate -end $endDate
    if (-not $dailyData -or $dailyData.Count -eq 0) {
        Write-Host "sin datos)" -ForegroundColor Red
        continue
    }

    # Agrupar daily en bucket semanal Friday-anchored
    $weekBucket = @{}
    foreach ($row in $dailyData) {
        $d = [DateTime]::Parse($row.fecha)
        $daysToFri = (5 - [int]$d.DayOfWeek + 7) % 7
        $weekEnd = $d.AddDays($daysToFri).ToString('yyyy-MM-dd')
        if (-not $weekBucket.ContainsKey($weekEnd)) {
            $weekBucket[$weekEnd] = @{ tmax=@(); tmin=@(); lluvia=@() }
        }
        $weekBucket[$weekEnd].tmax += [double]$row.tmax
        $weekBucket[$weekEnd].tmin += [double]$row.tmin
        $weekBucket[$weekEnd].lluvia += [double]$row.lluvia
    }

    # Alinear con fechas de Cepea (mapeando cada fecha a su Viernes anchor)
    $alignTmax   = New-Object System.Collections.ArrayList
    $alignTmin   = New-Object System.Collections.ArrayList
    $alignLlu    = New-Object System.Collections.ArrayList
    $alignPrec   = New-Object System.Collections.ArrayList
    $alignFechas = New-Object System.Collections.ArrayList
    foreach ($n in $nanica) {
        $nDate = [DateTime]::Parse($n.fecha)
        $daysToFri = (5 - [int]$nDate.DayOfWeek + 7) % 7
        $weekKey = $nDate.AddDays($daysToFri).ToString('yyyy-MM-dd')
        if ($weekBucket.ContainsKey($weekKey)) {
            $b = $weekBucket[$weekKey]
            [void]$alignTmax.Add( (($b.tmax  | Measure-Object -Average).Average) )
            [void]$alignTmin.Add( (($b.tmin  | Measure-Object -Average).Average) )
            [void]$alignLlu.Add(  (($b.lluvia| Measure-Object -Sum).Sum) )
            [void]$alignPrec.Add( $n.precio )
            [void]$alignFechas.Add($n.fecha)
        }
    }
    $nAlign = $alignTmax.Count

    # Pearson en lags 0..4 (weather[t-lag] vs price[t])
    $corrTmax = @(); $corrTmin = @(); $corrLlu = @()
    for ($lag = 0; $lag -le 4; $lag++) {
        if ($nAlign -le ($lag + 3)) { $corrTmax += 0; $corrTmin += 0; $corrLlu += 0; continue }
        $wSliceMax = @($alignTmax[0..($nAlign - 1 - $lag)])
        $wSliceMin = @($alignTmin[0..($nAlign - 1 - $lag)])
        $wSliceLlu = @($alignLlu[0..($nAlign  - 1 - $lag)])
        $pSlice    = @($alignPrec[$lag..($nAlign - 1)])
        $corrTmax += (Get-Pearson $wSliceMax $pSlice)
        $corrTmin += (Get-Pearson $wSliceMin $pSlice)
        $corrLlu  += (Get-Pearson $wSliceLlu $pSlice)
    }

    # Mejor lag (mayor |r|)
    function Get-MejorLag { param($corrs)
        $bestLag = 0; $bestAbs = 0.0
        for ($i=0; $i -lt $corrs.Count; $i++) {
            if ([Math]::Abs($corrs[$i]) -gt $bestAbs) { $bestAbs = [Math]::Abs($corrs[$i]); $bestLag = $i }
        }
        return @{ lag = $bestLag; r = $corrs[$bestLag] }
    }
    $mejorTmax = Get-MejorLag $corrTmax
    $mejorTmin = Get-MejorLag $corrTmin
    $mejorLlu  = Get-MejorLag $corrLlu

    # Regresion lineal lag 4 (para forecast)
    $reg4 = @{ slope=0.0; intercept=0.0; r2=0.0; rmse=0.0; n=0 }
    if ($nAlign -gt 7) {
        $xLag4 = @($alignTmax[0..($nAlign - 1 - 4)])
        $yLag4 = @($alignPrec[4..($nAlign - 1)])
        $reg4 = Get-LinReg $xLag4 $yLag4
    }

    # Forecast: 4 semanas hacia adelante usando tmax observado los ultimos 4 alineados
    # Modelo combinado: prediccion climatica (r² weight) + baseline estacional (1-r² weight)
    $forecast4w = @()
    $lastCepeaDate = [DateTime]::Parse($nanica[-1].fecha)
    $w = [double]$reg4.r2
    if ($w -lt 0) { $w = 0 } elseif ($w -gt 1) { $w = 1 }
    for ($k = 1; $k -le 4; $k++) {
        $idx = $nAlign - 5 + $k
        if ($idx -lt 0 -or $idx -ge $nAlign) { continue }
        $tmaxIn   = [double]$alignTmax[$idx]
        $predClim = [double]$reg4.intercept + [double]$reg4.slope * $tmaxIn
        $fecForecast = $lastCepeaDate.AddDays($k * 7)
        $mesObj = $fecForecast.Month
        $baseline = if ($promedioMes.Contains("$mesObj")) { [double]$promedioMes["$mesObj"] } else { 1.36 }
        $predSinAncla = $predClim * $w + $baseline * (1 - $w)

        # Anclaje al nivel actual: arrastra el desvio de hoy respecto de la norma,
        # decayendo phi^k hacia esa norma a medida que se aleja el horizonte.
        # k=1 pega casi el desvio entero; k=4 ya volvio bastante a lo estacional.
        $factorAncla = 1 + ($devActual - 1) * [Math]::Pow($phiDev, $k)
        $predComb = $predSinAncla * $factorAncla

        $forecast4w += [PSCustomObject]@{
            semanas_adelante = $k
            fecha            = $fecForecast.ToString('yyyy-MM-dd')
            precio_pred      = [math]::Round([Math]::Max(0.1, $predComb), 3)
            precio_clim_puro = [math]::Round([Math]::Max(0.1, $predClim), 3)
            baseline_mes     = [math]::Round($baseline, 3)
            peso_clim        = [math]::Round($w, 3)
            pred_sin_ancla   = [math]::Round([Math]::Max(0.1, $predSinAncla), 3)
            factor_ancla     = [math]::Round($factorAncla, 3)
            desvio_actual    = [math]::Round($devActual, 3)
            phi_desvio       = [math]::Round($phiDev, 3)
            tmax_input       = [math]::Round($tmaxIn, 1)
            tmax_input_fecha = [string]$alignFechas[$idx]
            ci_low           = [math]::Round([Math]::Max(0.1, $predComb - [double]$reg4.rmse), 3)
            ci_high          = [math]::Round($predComb + [double]$reg4.rmse, 3)
        }
    }

    # Serie semanal alineada (para charts: precio vs fecha vs tmin/tmax)
    $serieSemanal = @()
    for ($i = 0; $i -lt $nAlign; $i++) {
        $serieSemanal += [PSCustomObject]@{
            fecha = [string]$alignFechas[$i]
            tmin  = [math]::Round([double]$alignTmin[$i], 1)
            tmax  = [math]::Round([double]$alignTmax[$i], 1)
            lluvia = [math]::Round([double]$alignLlu[$i], 1)
        }
    }

    $correlData += [PSCustomObject]@{
        id = $br.id
        ciudad = $br.ciudad
        n_semanas = $nAlign
        tmax = $corrTmax
        tmin = $corrTmin
        lluvia = $corrLlu
        mejor_tmax = $mejorTmax
        mejor_tmin = $mejorTmin
        mejor_lluvia = $mejorLlu
        regresion_lag4 = $reg4
        forecast_4w = $forecast4w
        serie_semanal = $serieSemanal
    }
    Write-Host "OK ($nAlign sem · mejor tmax: lag $($mejorTmax.lag) r=$($mejorTmax.r) · reg r²=$($reg4.r2) rmse=$($reg4.rmse))" -ForegroundColor Green
}

$data.clima | Add-Member -MemberType NoteProperty -Name 'correlacion' -Value ([PSCustomObject]@{
    metodologia = "Pearson semanal Friday-anchored, weather[t-lag] vs precio Cepea Nanica primeira[t]"
    nota        = "Solo regiones BR (Cepea es referencia BR). Lags 0-4 semanas. r >0,3 = correlacion debil; >0,5 = moderada; >0,7 = fuerte"
    regiones    = $correlData
}) -Force

# ==========================================================================
# 3.7) Precio Paraguay - Banana Carape Mercado Central Asuncion (SIMA)
#      Fuente: preciosdelagro.com (datos oficiales SIMA-MAG, frecuencia ~2-3 dias)
# ==========================================================================
Write-Host "[py] Bajando precio banana Carape PY (Mercado Asuncion)... " -NoNewline
$cachePyPath = Join-Path $fuentes "precios_py_cache.json"
$pyData = $null
try {
    # -UseBasicParsing: obligatorio en equipos sin Internet Explorer (Win11 moderno).
    # Sin el flag, Invoke-WebRequest intenta parsear con el motor de IE y tira
    # NullReferenceException, y el precio PY quedaba pegado al cache viejo.
    $htmlPy = (Invoke-WebRequest -Uri 'https://preciosdelagro.com/producto/39-banana-carape' -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content

    # Precio actual (PYG)
    $precioPyActual = $null
    if ($htmlPy -match 'aria-label="Precio">([\d.,]+)\s*Gs') {
        $precioPyActual = [double](($matches[1] -replace '\.','').Trim())
    }
    # Fecha actualizado (dd/mm/yyyy -> yyyy-mm-dd)
    $fechaUpd = $null
    if ($htmlPy -match 'Actualizado el (\d{2})/(\d{2})/(\d{4})') {
        $fechaUpd = "$($matches[3])-$($matches[2])-$($matches[1])"
    }
    # Serie historica desde el chart ApexCharts
    $seriePy = @()
    if ($htmlPy -match '(?s)series\s*:\s*\[\s*\{[^}]*data\s*:\s*(\[[^\]]+\])') {
        try {
            $arr = $matches[1] | ConvertFrom-Json
            # Deduplicar por fecha (la web a veces repite la misma fecha)
            $byFecha = @{}
            foreach ($p in $arr) { $byFecha[$p.x] = [double]$p.y }
            foreach ($k in ($byFecha.Keys | Sort-Object)) {
                $seriePy += [PSCustomObject]@{ fecha = $k; precio_caja_pyg = $byFecha[$k] }
            }
        } catch {}
    }

    $pyData = [PSCustomObject]@{
        fuente            = 'SIMA / preciosdelagro.com'
        producto          = 'Banana Carape'
        mercado           = 'Mercado Central Abasto Asuncion (DAMA)'
        unidad            = 'PYG/caja 23-25 kg'
        kg_caja_aprox     = 24
        precio_caja_pyg   = $precioPyActual
        fecha_actualizado = $fechaUpd
        actualizado       = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        serie             = $seriePy
    }

    # Guardar cache
    $pyData | ConvertTo-Json -Depth 5 | Out-File $cachePyPath -Encoding UTF8
    Write-Host "OK PYG $precioPyActual/caja (fecha $fechaUpd, $($seriePy.Count) puntos)" -ForegroundColor Green
} catch {
    Write-Host "FALLO ($($_.Exception.Message))" -ForegroundColor Red
    # Fallback cache
    $usoCache = $false
    if (Test-Path $cachePyPath) {
        try {
            $pyData = Get-Content $cachePyPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "    (usando cache local: $($pyData.fecha_actualizado))" -ForegroundColor DarkYellow
            $usoCache = $true
        } catch {}
    }
    $detPy = if ($usoCache) { "$($_.Exception.Message) — sigo con cache del $($pyData.fecha_actualizado)" } else { $_.Exception.Message }
    Add-Falla -Paso 'Paraguay (SIMA)' -Detalle $detPy
}
if ($null -ne $pyData) {
    $data | Add-Member -MemberType NoteProperty -Name 'paraguay' -Value $pyData -Force
}

# ==========================================================================
# 4) Guardar JSON sidecar (por si necesitas verlo)
# ==========================================================================
$json = $data | ConvertTo-Json -Depth 10 -Compress
# Reemplazar \$ por $ para JSON limpio en el sidecar
$jsonSidecar = $json -replace '\\\$','$'
$jsonSidecar | Out-File $jsonPath -Encoding UTF8 -NoNewline
Write-Host "[4/6] JSON sidecar guardado en $jsonPath" -ForegroundColor Cyan

# 5) Inyectar JSON en los HTMLs que tengan los marcadores Cepea
Write-Host "[5/6] Inyectando datos en archivos HTML..." -ForegroundColor Cyan

# Para el HTML embebido, usar JSON con keys string (los meses ya estan como string)
$jsonInline = $data | ConvertTo-Json -Depth 10 -Compress
$jsonInline = $jsonInline -replace '\\\$','$'

# Patron: /*__CEPEA_JSON__*/<lo-que-sea>/*__END__*/
$pattern = '/\*__CEPEA_JSON__\*/.*?/\*__END__\*/'
$replacement = "/*__CEPEA_JSON__*/$jsonInline/*__END__*/"

foreach ($targetHtml in $htmlTargets) {
    if (-not (Test-Path $targetHtml)) {
        Write-Host "    (skip) no existe: $targetHtml" -ForegroundColor DarkYellow
        continue
    }
    $html = Get-Content $targetHtml -Raw -Encoding UTF8
    if ($html -notmatch $pattern) {
        Write-Host "    (skip) sin marcadores Cepea: $(Split-Path $targetHtml -Leaf)" -ForegroundColor DarkYellow
        continue
    }
    $newHtml = [regex]::Replace($html, $pattern, { param($m) $replacement }, 'Singleline')
    Set-Content -Path $targetHtml -Value $newHtml -Encoding UTF8 -NoNewline
    Write-Host "    OK $(Split-Path $targetHtml -Leaf)" -ForegroundColor Green
}

# ==========================================================================
# 5c) Mercado UY multi-origen desde Penta  (index_mercado.html)
#     [agregado 04/09/2026]
#
# Lee TODOS los `penta\detalle_UYimport_*.xlsx` (extractos de aduana con
# Importador y Fecha por fila), los fusiona deduplicando, y arma el sidecar
# `fuentes\mercado_uy.json` que alimenta index_mercado.html.
#
# Por que existe: las secciones de mercado de index/brasil/PY-BO estan
# hardcodeadas a mano con datos ene-11may/2026 y quedaron falsas (decian
# "Paraguay se contrajo a 1/4" cuando Paraguay se multiplico por 7 desde mayo).
# Esta pagina se regenera sola y no se puede desactualizar.
#
# ⚠️ Trampas conocidas de Penta, ya contempladas aca:
#   - TRAMPA 1: extractos que se solapan -> se deduplica por
#     fecha|origen|importador|kg|fob antes de agregar.
#   - TRAMPA 2 (Ecuador kgNeto == fob): REFUTADA el 04/09/2026. Es un falso
#     positivo — Ecuador se declara a 1,00 USD/kg, asi que el FOB coincide
#     numericamente con los kilos. NO corregir. Validar con kgNeto/kgBruto (~0,92).
#   - TRAMPA 3: el periodo de la hoja Parametros miente -> se usa el max(Fecha) real.
#   - El XML de xlsx SIEMPRE trae punto decimal: parsear con InvariantCulture.
#     NO pasar por CSV (la cultura es-UY escribe coma y al releer infla x100).
# ==========================================================================
Write-Host "[5c] Mercado UY multi-origen (Penta)..." -ForegroundColor Cyan

function Read-PentaDetalle {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    $ent = @{}
    foreach ($e in $zip.Entries) {
        $sr = New-Object System.IO.StreamReader($e.Open())
        $ent[$e.FullName] = $sr.ReadToEnd(); $sr.Close()
    }
    $zip.Dispose()
    $sst = @()
    if ($ent.ContainsKey('xl/sharedStrings.xml')) {
        foreach ($m in [regex]::Matches($ent['xl/sharedStrings.xml'],'(?s)<si>(.*?)</si>')) {
            $sst += [System.Net.WebUtility]::HtmlDecode((-join ([regex]::Matches($m.Groups[1].Value,'(?s)<t[^>]*>(.*?)</t>') | ForEach-Object { $_.Groups[1].Value })))
        }
    }
    $tgt = $null
    foreach ($m in [regex]::Matches($ent['xl/workbook.xml'],'<sheet[^>]*name="([^"]+)"[^>]*r:id="(rId\d+)"')) {
        if ($m.Groups[1].Value -eq 'Detalle') {
            $rm = [regex]::Match($ent['xl/_rels/workbook.xml.rels'],'Id="'+$m.Groups[2].Value+'"[^>]*Target="([^"]+)"')
            $tgt = ($rm.Groups[1].Value -replace '^/?(xl/)?','')
        }
    }
    if (-not $tgt -or -not $ent.ContainsKey("xl/$tgt")) { return @() }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $filas = @(); $primera = $true
    foreach ($fm in [regex]::Matches($ent["xl/$tgt"],'(?s)<row[^>]*>(.*?)</row>')) {
        $cel = @{}
        foreach ($cm in [regex]::Matches($fm.Groups[1].Value,'(?s)<c r="([A-Z]+)\d+"([^>]*)>(.*?)</c>')) {
            $ref = $cm.Groups[1].Value -replace '\d',''
            $ci = 0; foreach ($ch in $ref.ToCharArray()) { $ci = $ci*26 + ([int][char]$ch - 64) }
            $at = $cm.Groups[2].Value; $inn = $cm.Groups[3].Value
            $vm = [regex]::Match($inn,'(?s)<v>(.*?)</v>')
            $val = if ($vm.Success) { $vm.Groups[1].Value } else { -join ([regex]::Matches($inn,'(?s)<t[^>]*>(.*?)</t>') | ForEach-Object { $_.Groups[1].Value }) }
            if ($at -match 't="s"' -and $val -match '^\d+$') { $val = $sst[[int]$val] }
            $cel[$ci] = [System.Net.WebUtility]::HtmlDecode($val)
        }
        if ($primera) { $primera = $false; continue }
        if (-not $cel.ContainsKey(1) -or [string]::IsNullOrWhiteSpace($cel[1])) { continue }
        try {
            $fecha = [DateTime]::FromOADate([double]::Parse($cel[1],$inv))
            $filas += [PSCustomObject]@{
                fecha      = $fecha.ToString('yyyy-MM-dd')
                anio       = $fecha.Year
                mes        = $fecha.Month
                origen     = $cel[2]
                kg         = [double]::Parse($cel[3],$inv)
                kgBruto    = [double]::Parse($cel[4],$inv)
                importador = $cel[6]
                fob        = [double]::Parse($cel[7],$inv)
            }
        } catch { }
    }
    return $filas
}

$mercadoHtml = Join-Path $base "index_mercado.html"
$pentaDir    = Join-Path $base "penta"
$xlsxPenta   = @()
if (Test-Path $pentaDir) { $xlsxPenta = @(Get-ChildItem $pentaDir -Filter "detalle_UYimport_*.xlsx" -ErrorAction SilentlyContinue) }

if ($xlsxPenta.Count -eq 0) {
    Write-Host "    (skip) no hay detalle_UYimport_*.xlsx en penta\" -ForegroundColor DarkYellow
} else {
    # TRAMPA 1 (extractos que se solapan): deduplicar por CONTEO, no por presencia.
    # Una operacion puede repetirse LEGITIMAMENTE dentro de un mismo extracto — dos
    # contenedores iguales el mismo dia, mismo importador, mismo peso y valor (pasa:
    # 5 casos en los extractos de ene-ago 2026). Deduplicar por presencia se los come.
    # Solucion: para cada clave se toma el MAXIMO de veces que aparece en UN archivo.
    # Asi un extracto solapado no suma de mas, y los repetidos genuinos se conservan.
    $archivos = @(); $porClave = @{}
    foreach ($x in $xlsxPenta) {
        $f = Read-PentaDetalle $x.FullName
        $cnt = @{}
        foreach ($r in $f) {
            $k = "$($r.fecha)|$($r.origen)|$($r.importador)|$($r.kg)|$($r.fob)"
            if (-not $cnt.ContainsKey($k)) { $cnt[$k] = @{ n = 0; row = $r } }
            $cnt[$k].n++
        }
        foreach ($k in $cnt.Keys) {
            if (-not $porClave.ContainsKey($k) -or $porClave[$k].n -lt $cnt[$k].n) { $porClave[$k] = $cnt[$k] }
        }
        $archivos += "$($x.Name) ($($f.Count) filas)"
    }
    $todo = @()
    foreach ($k in $porClave.Keys) {
        for ($i = 0; $i -lt $porClave[$k].n; $i++) { $todo += $porClave[$k].row }
    }
    if ($todo.Count -eq 0) {
        Write-Host "    (skip) los xlsx no tienen filas legibles" -ForegroundColor DarkYellow
    } else {
        $anioP  = ($todo | Measure-Object anio -Maximum).Maximum
        $delAnio = @($todo | Where-Object { $_.anio -eq $anioP })
        $corte  = ($delAnio | Sort-Object fecha | Select-Object -Last 1).fecha   # TRAMPA 3
        $ORIG   = @($delAnio | Group-Object origen | Sort-Object { -(($_.Group|Measure-Object kg -Sum).Sum) } | ForEach-Object { $_.Name })
        $mesMax = ($delAnio | Measure-Object mes -Maximum).Maximum
        $corteV = [int][Math]::Floor($mesMax / 2)          # mitad del periodo cubierto
        $V1 = 1..$corteV; $V2 = ($corteV+1)..$mesMax

        function T { param($sel) [math]::Round(((($sel | Measure-Object kg -Sum).Sum) / 1000), 1) }

        $mensual = [ordered]@{}
        foreach ($o in $ORIG) {
            $mensual[$o] = @(1..$mesMax | ForEach-Object { $m=$_; T (@($delAnio | Where-Object { $_.origen -eq $o -and $_.mes -eq $m })) })
        }

        $porOrigen = @()
        foreach ($o in $ORIG) {
            $a = (T (@($delAnio | Where-Object { $_.origen -eq $o -and $V1 -contains $_.mes }))) / $V1.Count
            $b = (T (@($delAnio | Where-Object { $_.origen -eq $o -and $V2 -contains $_.mes }))) / $V2.Count
            $fa = @($delAnio | Where-Object { $_.origen -eq $o -and $V1 -contains $_.mes })
            $fb = @($delAnio | Where-Object { $_.origen -eq $o -and $V2 -contains $_.mes })
            $porOrigen += [PSCustomObject]@{
                origen = $o
                v1 = [math]::Round($a,0); v2 = [math]::Round($b,0)
                fobV1 = if (($fa|Measure-Object kg -Sum).Sum) { [math]::Round((($fa|Measure-Object fob -Sum).Sum)/(($fa|Measure-Object kg -Sum).Sum),3) } else { 0 }
                fobV2 = if (($fb|Measure-Object kg -Sum).Sum) { [math]::Round((($fb|Measure-Object fob -Sum).Sum)/(($fb|Measure-Object kg -Sum).Sum),3) } else { 0 }
            }
        }

        $impNombres = @($delAnio | Group-Object importador | Sort-Object { -(($_.Group|Measure-Object kg -Sum).Sum) } | ForEach-Object { $_.Name })
        $importadores = @()
        foreach ($i in $impNombres) {
            $po = [ordered]@{}
            foreach ($o in $ORIG) {
                $po[$o] = @(
                    [math]::Round((T (@($delAnio | Where-Object { $_.importador -eq $i -and $_.origen -eq $o -and $V1 -contains $_.mes }))) / $V1.Count, 0),
                    [math]::Round((T (@($delAnio | Where-Object { $_.importador -eq $i -and $_.origen -eq $o -and $V2 -contains $_.mes }))) / $V2.Count, 0)
                )
            }
            $importadores += [PSCustomObject]@{
                nombre = $i
                v1 = [math]::Round((T (@($delAnio | Where-Object { $_.importador -eq $i -and $V1 -contains $_.mes }))) / $V1.Count, 0)
                v2 = [math]::Round((T (@($delAnio | Where-Object { $_.importador -eq $i -and $V2 -contains $_.mes }))) / $V2.Count, 0)
                porOrigen = $po
            }
        }

        # Interanual y estacional desde el agregado historico (uy_import_agg.json)
        $interanual = [ordered]@{}; $estacional = @()
        $aggPath = Join-Path $fuentes "uy_import_agg.json"
        if (Test-Path $aggPath) {
            try {
                $agg = Get-Content $aggPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $aniosH = @($agg | Select-Object -ExpandProperty anio -Unique | Sort-Object | Where-Object { $_ -lt $anioP })
                foreach ($o in $ORIG) {
                    $serie = [ordered]@{}
                    foreach ($ah in $aniosH) {
                        $s = @($agg | Where-Object { $_.anio -eq $ah -and $_.origen -eq $o -and $V2 -contains $_.mes })
                        $serie["$ah"] = [math]::Round(((($s|Measure-Object kg -Sum).Sum)/1000)/$V2.Count, 0)
                    }
                    $serie["$anioP"] = ($porOrigen | Where-Object { $_.origen -eq $o }).v2
                    $interanual[$o] = $serie
                }
                foreach ($ah in $aniosH) {
                    $e1 = @($agg | Where-Object { $_.anio -eq $ah -and $V1 -contains $_.mes })
                    $e2 = @($agg | Where-Object { $_.anio -eq $ah -and $V2 -contains $_.mes })
                    $estacional += [PSCustomObject]@{ anio=$ah
                        v1=[math]::Round(((($e1|Measure-Object kg -Sum).Sum)/1000)/$V1.Count,0)
                        v2=[math]::Round(((($e2|Measure-Object kg -Sum).Sum)/1000)/$V2.Count,0) }
                }
                $estacional += [PSCustomObject]@{ anio=$anioP
                    v1=[math]::Round((($porOrigen|Measure-Object v1 -Sum).Sum),0)
                    v2=[math]::Round((($porOrigen|Measure-Object v2 -Sum).Sum),0) }
            } catch { }
        }

        $mercado = [ordered]@{
            generado   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            fuente     = 'Penta Transaction · NCM 0803.90 · importaciones Uruguay'
            archivos   = $archivos
            anio       = $anioP
            corte      = $corte
            registros  = $delAnio.Count
            meses      = $mesMax
            corteVentana = $corteV
            origenes   = $ORIG
            mensual    = $mensual
            porOrigen  = $porOrigen
            importadores = $importadores
            interanual = $interanual
            estacional = $estacional
        }
        $mercadoJson = $mercado | ConvertTo-Json -Depth 10 -Compress
        Set-Content -Path (Join-Path $fuentes "mercado_uy.json") -Value $mercadoJson -Encoding UTF8
        Write-Host "    sidecar: fuentes\mercado_uy.json ($($delAnio.Count) reg, $($ORIG.Count) origenes, corte $corte)" -ForegroundColor Green

        if (Test-Path $mercadoHtml) {
            $mTxt = Get-Content $mercadoHtml -Raw -Encoding UTF8
            $patM = '/\*__MERCADO_JSON__\*/.*?/\*__END_MERCADO__\*/'
            $nM = ([regex]::Matches($mTxt, $patM, 'Singleline')).Count
            if ($nM -ne 1) {
                Write-Host "    (skip) index_mercado.html: esperaba 1 par de marcadores, hay $nM" -ForegroundColor Red
            } else {
                $repM = '/*__MERCADO_JSON__*/' + $mercadoJson + '/*__END_MERCADO__*/'
                $mNuevo = [regex]::Replace($mTxt, $patM, { param($m) $repM }, 'Singleline')
                Set-Content -Path $mercadoHtml -Value $mNuevo -Encoding UTF8 -NoNewline
                Write-Host "    OK index_mercado.html" -ForegroundColor Green
            }
        } else {
            Write-Host "    (aviso) falta index_mercado.html — el sidecar quedo generado igual" -ForegroundColor DarkYellow
        }
    }
}

# ==========================================================================
# 5b) Comparativo anual (index_comparativo_anual.html)   [agregado 03/09/2026]
#
# Este HTML tenia los datos incrustados a mano y NINGUN paso del script lo
# actualizaba: mientras los otros tres se refrescaban cada viernes, este se
# quedaba viejo en silencio. Ademas venia corrupto — la inyeccion anterior uso
# un regex no-greedy que cruzo desde el marcador del tag de datos hasta el
# __END__ del segundo .replace() del JS, metiendo el payload dentro del propio
# codigo y rompiendo el JSON.parse. Por eso ahora:
#   - marcadores propios __COMPARATIVO_JSON__ / __END_COMPARATIVO__
#   - en el JS los marcadores estan escritos como regex escapados, asi que el
#     texto literal no aparece en el codigo y no se puede volver a matchear
#   - guardia de "exactamente 1 par" antes de tocar el archivo
# ==========================================================================
Write-Host "[5b] Generando comparativo anual..." -ForegroundColor Cyan

function Get-PromMesComp { param($serie, $anio, $mes)
    $v = @($serie | Where-Object { $_.anio -eq $anio -and $_.mes -eq $mes } | ForEach-Object { $_.precio })
    if ($v.Count -eq 0) { return $null }
    return [math]::Round((($v | Measure-Object -Average).Average), 2)
}

$compHtml = Join-Path $base "index_comparativo_anual.html"
if (-not (Test-Path $compHtml)) {
    Write-Host "    (skip) no existe index_comparativo_anual.html" -ForegroundColor DarkYellow
} else {
    # Serie deduplicada por fecha: la cruda trae fechas repetidas (2024-01-05,
    # 2026-06-26) y contarlas dos veces inflaba los conteos del invierno.
    $compSerie = @()
    foreach ($g in ($nanica | Group-Object fecha | Sort-Object Name)) {
        $d = [DateTime]::Parse($g.Name)
        $compSerie += [PSCustomObject]@{
            fecha  = $g.Name
            anio   = $d.Year
            mes    = $d.Month
            doy    = $d.DayOfYear
            precio = [math]::Round((($g.Group | Measure-Object precio -Average).Average), 3)
        }
    }
    $aniosComp = @($compSerie | Select-Object -ExpandProperty anio -Unique | Sort-Object)

    $porAnio = [ordered]@{}
    foreach ($a in $aniosComp) {
        $porAnio["$a"] = @($compSerie | Where-Object { $_.anio -eq $a } |
            ForEach-Object { [PSCustomObject]@{ doy=$_.doy; fecha=$_.fecha; precio=$_.precio } })
    }

    $mensual = @()
    foreach ($m in 1..12) {
        $row = [ordered]@{ mes = $m }
        foreach ($a in $aniosComp) { $row["$a"] = (Get-PromMesComp $compSerie $a $m) }
        $mensual += [PSCustomObject]$row
    }

    $salto = @()
    foreach ($a in $aniosComp) {
        $jul = Get-PromMesComp $compSerie $a 7
        $ago = Get-PromMesComp $compSerie $a 8
        if ($null -eq $jul -or $null -eq $ago -or $jul -le 0) { continue }
        $salto += [PSCustomObject]@{ anio=$a; jul=$jul; ago=$ago; pct=[math]::Round((($ago/$jul)-1)*100,1) }
    }

    $agosto = [ordered]@{}
    foreach ($a in $aniosComp) {
        $v = @($compSerie | Where-Object { $_.anio -eq $a -and $_.mes -eq 8 } | Sort-Object fecha | ForEach-Object { $_.precio })
        if ($v.Count) { $agosto["$a"] = $v }
    }

    $eneAgo = @(); $anual = @()
    foreach ($a in $aniosComp) {
        $v = @($compSerie | Where-Object { $_.anio -eq $a -and $_.mes -le 8 } | ForEach-Object { $_.precio })
        if ($v.Count) {
            $st = $v | Measure-Object -Average -Minimum -Maximum
            $eneAgo += [PSCustomObject]@{ anio=$a; prom=[math]::Round($st.Average,2); min=$st.Minimum; max=$st.Maximum; n=$v.Count }
        }
        # 'anual' solo para anios completos (los que llegaron a diciembre)
        $tieneDic = @($compSerie | Where-Object { $_.anio -eq $a -and $_.mes -eq 12 }).Count -gt 0
        $vf = @($compSerie | Where-Object { $_.anio -eq $a } | ForEach-Object { $_.precio })
        if ($tieneDic -and $vf.Count) {
            $sf = $vf | Measure-Object -Average -Minimum -Maximum
            $amp = if ($sf.Minimum -gt 0) { [math]::Round($sf.Maximum/$sf.Minimum,2) } else { 0 }
            $anual += [PSCustomObject]@{ anio=$a; prom=[math]::Round($sf.Average,2); min=$sf.Minimum; max=$sf.Maximum; amp=$amp }
        }
    }

    # Invierno = 1/jun a 31/ago. 'frias' = semanas con tmin < 12 grados.
    $invierno = @()
    $regClima = $correlData | Where-Object { $_.id -eq 'br_luizalves' } | Select-Object -First 1
    $ciudadClima = if ($regClima) { $regClima.ciudad } else { 'Luiz Alves' }
    if ($regClima) {
        $climaDedup = @(); $vistasC = @{}
        foreach ($s in $regClima.serie_semanal) {
            if ($vistasC.ContainsKey($s.fecha)) { continue }
            $vistasC[$s.fecha] = $true
            $climaDedup += $s
        }
        foreach ($a in $aniosComp) {
            $w = @($climaDedup | Where-Object {
                $dc = [DateTime]::Parse($_.fecha)
                $dc.Year -eq $a -and $dc.Month -ge 6 -and $dc.Month -le 8
            })
            if ($w.Count -eq 0) { continue }
            $invierno += [PSCustomObject]@{
                anio  = $a
                tmin  = [math]::Round((($w | Measure-Object tmin -Average).Average),1)
                tmax  = [math]::Round((($w | Measure-Object tmax -Average).Average),1)
                frias = @($w | Where-Object { [double]$_.tmin -lt 12 }).Count
                n     = $w.Count
            }
        }
    }

    $comparativo = [ordered]@{
        generado      = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        fuente        = $data.fuente
        producto      = $data.producto
        region        = $data.region
        ultima_semana = $data.ultima_semana
        ultimo_precio = $data.ultimo_precio
        porAnio       = $porAnio
        mensual       = $mensual
        salto         = $salto
        agosto        = $agosto
        eneAgo        = $eneAgo
        anual         = $anual
        invierno      = $invierno
        ciudad_clima  = $ciudadClima
    }
    $compJson = $comparativo | ConvertTo-Json -Depth 10 -Compress

    $compTxt = Get-Content $compHtml -Raw -Encoding UTF8
    $patComp = '/\*__COMPARATIVO_JSON__\*/.*?/\*__END_COMPARATIVO__\*/'
    $nComp = ([regex]::Matches($compTxt, $patComp, 'Singleline')).Count
    if ($nComp -ne 1) {
        Write-Host "    (skip) esperaba 1 par de marcadores, hay $nComp - NO se inyecta" -ForegroundColor Red
    } else {
        $repComp = '/*__COMPARATIVO_JSON__*/' + $compJson + '/*__END_COMPARATIVO__*/'
        $compNuevo = [regex]::Replace($compTxt, $patComp, { param($m) $repComp }, 'Singleline')
        Set-Content -Path $compHtml -Value $compNuevo -Encoding UTF8 -NoNewline
        Write-Host "    OK index_comparativo_anual.html ($($aniosComp.Count) anios, $($compSerie.Count) semanas)" -ForegroundColor Green
    }
}

# ==========================================================================
# 5d) Proyeccion hasta fin de anio (index_proyeccion.html)  [04/09/2026]
#
# Precio: mismo modelo de anclaje del forecast (baseline estacional del mes x
#   factor 1+(desvio-1)*phi^k). Se recalcula en CADA corrida, asi que a medida
#   que Cepea publica, el desvio se re-estima y la proyeccion se corrige sola.
#   ⚠️ El ancla decae: a >8 semanas el factor tiende a 1 y la proyeccion es
#   basicamente el promedio estacional. Eso se muestra explicito en la pagina.
# Volumen: nivel de la ventana v2 de cada origen (del sidecar de mercado) x el
#   factor estacional set-dic/may-ago observado en los anios previos. Rango =
#   min/max de esos factores, no un intervalo estadistico.
# ==========================================================================
Write-Host "[5d] Proyeccion hasta fin de anio..." -ForegroundColor Cyan

$proyHtml = Join-Path $base "index_proyeccion.html"
$merPath  = Join-Path $fuentes "mercado_uy.json"
$aggPath2 = Join-Path $fuentes "uy_import_agg.json"

if (-not (Test-Path $merPath) -or -not (Test-Path $aggPath2)) {
    Write-Host "    (skip) faltan mercado_uy.json o uy_import_agg.json" -ForegroundColor DarkYellow
} else {
  try {
    $merJ = Get-Content $merPath  -Raw -Encoding UTF8 | ConvertFrom-Json
    $aggJ = Get-Content $aggPath2 -Raw -Encoding UTF8 | ConvertFrom-Json

    $TC_USD = 5.20; $KG_CAJA = 22; $SERV_CAJA = 16
    $ultFecha = [DateTime]::Parse($data.ultima_semana)
    $anioP2   = $ultFecha.Year
    $mesUlt   = $ultFecha.Month

    # ---------- PRECIO ----------
    $precioProy = @()
    foreach ($m in $mesUlt..12) {
        $reales = @($nanica | Where-Object { ([DateTime]::Parse($_.fecha)).Year -eq $anioP2 -and ([DateTime]::Parse($_.fecha)).Month -eq $m } |
                    Group-Object fecha | ForEach-Object { [double]$_.Group[0].precio })
        $bl = if ($promedioMes.Contains("$m")) { [double]$promedioMes["$m"] } else { 1.36 }
        $hist = [ordered]@{}
        foreach ($ah in @($nanica | ForEach-Object { ([DateTime]::Parse($_.fecha)).Year } | Sort-Object -Unique)) {
            if ($ah -ge $anioP2) { continue }
            $hx = @($nanica | Where-Object { ([DateTime]::Parse($_.fecha)).Year -eq $ah -and ([DateTime]::Parse($_.fecha)).Month -eq $m } |
                    Group-Object fecha | ForEach-Object { [double]$_.Group[0].precio })
            if ($hx.Count) { $hist["$ah"] = [math]::Round((($hx | Measure-Object -Average).Average),2) }
        }
        # 'real' solo si el mes ya tiene >=3 semanas cargadas
        if ($reales.Count -ge 3) {
            $val = ($reales | Measure-Object -Average).Average
            $precioProy += [PSCustomObject]@{ mes=$m; estado='real'; baseline=[math]::Round($bl,2)
                factor=$null; semanas=$reales.Count
                valor=[math]::Round($val,2); caja=[math]::Round($val*$KG_CAJA+$SERV_CAJA,0)
                usdCaja=[math]::Round(($val*$KG_CAJA+$SERV_CAJA)/$TC_USD,2); hist=$hist }
        } else {
            $medio = [DateTime]::new($anioP2,$m,15)
            $k = [math]::Max(1, [int][math]::Round(($medio - $ultFecha).TotalDays/7,0))
            $f = 1 + ($devActual - 1) * [Math]::Pow($phiDev, $k)
            $val = $bl * $f
            $precioProy += [PSCustomObject]@{ mes=$m; estado='proyectado'; baseline=[math]::Round($bl,2)
                factor=[math]::Round($f,3); semanas=$k
                valor=[math]::Round($val,2); caja=[math]::Round($val*$KG_CAJA+$SERV_CAJA,0)
                usdCaja=[math]::Round(($val*$KG_CAJA+$SERV_CAJA)/$TC_USD,2); hist=$hist }
        }
    }

    # ---------- VOLUMEN ----------
    $mesTope   = [int]$merJ.meses
    $mesesProy = @()
    if ($mesTope -lt 12) { $mesesProy = ($mesTope+1)..12 }
    $V2m = ($mesTope - [int]$merJ.corteVentana)
    $volProy = @(); $totC=0.0; $totL=0.0; $totH=0.0
    if ($mesesProy.Count -gt 0) {
        $aniosPrev = @($aggJ | Select-Object -ExpandProperty anio -Unique | Sort-Object | Where-Object { $_ -lt $anioP2 })
        foreach ($o in $merJ.origenes) {
            $b = ($merJ.porOrigen | Where-Object { $_.origen -eq $o }).v2
            $fs = @()
            foreach ($ah in $aniosPrev) {
                $sd = ((@($aggJ | Where-Object { $_.anio -eq $ah -and $_.origen -eq $o -and $mesesProy -contains $_.mes }) | Measure-Object kg -Sum).Sum)/1000/$mesesProy.Count
                $ma = ((@($aggJ | Where-Object { $_.anio -eq $ah -and $_.origen -eq $o -and (($merJ.corteVentana+1)..$mesTope) -contains $_.mes }) | Measure-Object kg -Sum).Sum)/1000/$V2m
                if ($ma -gt 0) { $fs += ($sd/$ma) }
            }
            if ($fs.Count -gt 0) {
                $c = $b * (($fs|Measure-Object -Average).Average)
                $lo = $b * ($fs|Measure-Object -Minimum).Minimum
                $hi = $b * ($fs|Measure-Object -Maximum).Maximum
                $nota = 'factor estacional de ' + (($aniosPrev | Where-Object { $true }) -join '/')
            } else {
                # sin ventana v2 previa (origen nuevo): usar su propio nivel del mismo
                # periodo del anio pasado, con banda amplia declarada
                $ref = @($aggJ | Where-Object { $_.anio -eq ($anioP2-1) -and $_.origen -eq $o -and $mesesProy -contains $_.mes })
                $c = if ($ref.Count) { ((($ref|Measure-Object kg -Sum).Sum)/1000)/$mesesProy.Count } else { $b }
                $lo = $c*0.6; $hi = $c*1.4
                $nota = 'sin historia comparable — banda +-40% declarada'
            }
            $totC+=$c; $totL+=$lo; $totH+=$hi
            $fob = ($merJ.porOrigen | Where-Object { $_.origen -eq $o }).fobV2
            $volProy += [PSCustomObject]@{ origen=$o; actual=$b
                factores=@($fs | ForEach-Object { [math]::Round($_,3) })
                central=[math]::Round($c,0); lo=[math]::Round($lo,0); hi=[math]::Round($hi,0)
                fobKg=$fob; usdMes=[math]::Round($c*1000*$fob,0); nota=$nota }
        }
    }
    $histTot = @()
    foreach ($ah in @($aggJ | Select-Object -ExpandProperty anio -Unique | Sort-Object | Where-Object { $_ -lt $anioP2 })) {
        if ($mesesProy.Count -eq 0) { continue }
        $histTot += [PSCustomObject]@{ anio=$ah
            t=[math]::Round((((@($aggJ | Where-Object { $_.anio -eq $ah -and $mesesProy -contains $_.mes })|Measure-Object kg -Sum).Sum)/1000)/$mesesProy.Count,0) }
    }

    # ---------- ALMAR ----------
    $alm = $merJ.importadores | Where-Object { $_.nombre -match 'ALMAR' } | Select-Object -First 1
    $totV2m = ($merJ.porOrigen | Measure-Object v2 -Sum).Sum
    $shareA = if ($totV2m -gt 0 -and $alm) { $alm.v2/$totV2m } else { 0 }
    $brasilProy = ($volProy | Where-Object { $_.origen -match 'Brasil' }).central
    $almarCosto = @()
    foreach ($p in $precioProy) {
        if ($p.estado -ne 'proyectado') { continue }
        $cajasBR = if ($brasilProy) { ($brasilProy*$shareA*1000)/$KG_CAJA } else { 0 }
        $almarCosto += [PSCustomObject]@{ mes=$p.mes; caja=$p.caja; cajas=[math]::Round($cajasBR,0)
            brl=[math]::Round($p.caja*$cajasBR,0); usd=[math]::Round(($p.caja*$cajasBR)/$TC_USD,0) }
    }

    $proyeccion = [ordered]@{
        generado    = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        anio        = $anioP2
        base        = [ordered]@{ ultima_semana=$data.ultima_semana; ultimo_precio=$data.ultimo_precio
                                  desvio=[math]::Round($devActual,3); phi=[math]::Round($phiDev,3) }
        supuestos   = [ordered]@{ tc=$TC_USD; kgCaja=$KG_CAJA; servCaja=$SERV_CAJA }
        mesesVolumen= $mesesProy
        precio      = $precioProy
        volumen     = $volProy
        volTotal    = [ordered]@{ central=[math]::Round($totC,0); lo=[math]::Round($totL,0); hi=[math]::Round($totH,0)
                                  usdMes=[math]::Round((($volProy|Measure-Object usdMes -Sum).Sum),0); hist=$histTot }
        almar       = [ordered]@{ share=[math]::Round($shareA,4)
                                  tMes=[math]::Round($totC*$shareA,0)
                                  tPeriodo=[math]::Round($totC*$shareA*$mesesProy.Count,0)
                                  cajasMes=[math]::Round(($totC*$shareA*1000)/$KG_CAJA,0)
                                  costo=$almarCosto }
    }
    $proyJson = $proyeccion | ConvertTo-Json -Depth 10 -Compress
    Set-Content -Path (Join-Path $fuentes "proyeccion.json") -Value $proyJson -Encoding UTF8
    Write-Host "    sidecar: fuentes\proyeccion.json (precio $($precioProy.Count) meses, volumen $($mesesProy.Count) meses)" -ForegroundColor Green

    if (Test-Path $proyHtml) {
        $pTxt = Get-Content $proyHtml -Raw -Encoding UTF8
        $patP = '/\*__PROYECCION_JSON__\*/.*?/\*__END_PROYECCION__\*/'
        $nP = ([regex]::Matches($pTxt, $patP, 'Singleline')).Count
        if ($nP -ne 1) {
            Write-Host "    (skip) index_proyeccion.html: esperaba 1 par de marcadores, hay $nP" -ForegroundColor Red
        } else {
            $repP = '/*__PROYECCION_JSON__*/' + $proyJson + '/*__END_PROYECCION__*/'
            Set-Content -Path $proyHtml -Value ([regex]::Replace($pTxt, $patP, { param($m) $repP }, 'Singleline')) -Encoding UTF8 -NoNewline
            Write-Host "    OK index_proyeccion.html" -ForegroundColor Green
        }
    } else {
        Write-Host "    (aviso) falta index_proyeccion.html — sidecar generado igual" -ForegroundColor DarkYellow
    }
  } catch {
    Write-Host "    ERROR en la proyeccion: $($_.Exception.Message)" -ForegroundColor Red
  }
}

# ==========================================================================
# 5f) Ecuador — reconstruido sobre fuentes que funcionan  [04/09/2026]
#
# Tridge (la fuente original) esta bloqueada por Cloudflare desde ~24/07/2026 y
# no lo arreglan los headers. Revisadas el 04/09: MAG no responde, SIPA y AEBE
# no publican precio parseable, IndexMundi si pero con ~6 meses de atraso.
# Conclusion: NO hay reemplazo con la frescura de Tridge. Entonces se cambia el
# enfoque del panel:
#   - PRIMARIA: Penta (aduana). Es el USD/kg que Uruguay REALMENTE paga por
#     banana ecuatoriana. Mas relevante para Almar que el spot FOB de origen.
#   - REFERENCIA: IndexMundi (serie Banco Mundial, banana Centroamerica/Ecuador
#     FOB, USD/kg). Atrasada pero sirve para ver si Ecuador esta caro vs mundo.
#   - OPORTUNISTA: Tridge, si algun dia se destraba.
# ==========================================================================
Write-Host "[5f] Ecuador (Penta + referencia mundial)..." -ForegroundColor Cyan
$ecoPath = Join-Path $fuentes "ecuador.json"
$eco = [ordered]@{
    generado = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    penta = $null; mundial = $null; tridge = $null
}

# --- primaria: Penta ---
$merP = Join-Path $fuentes "mercado_uy.json"
if (Test-Path $merP) {
    try {
        $mj = Get-Content $merP -Raw -Encoding UTF8 | ConvertFrom-Json
        $oEc = $mj.porOrigen | Where-Object { $_.origen -match 'Ecuador' }
        if ($oEc) {
            $otros = @($mj.porOrigen | Where-Object { $_.origen -notmatch 'Ecuador' } |
                       ForEach-Object { [PSCustomObject]@{ origen=$_.origen; usdKg=$_.fobV2; tMes=$_.v2 } })
            $eco.penta = [ordered]@{
                fuente='Penta Transaction · valor en aduana Uruguay'
                corte=$mj.corte; anio=$mj.anio
                usdKg=$oEc.fobV2; tMesV1=$oEc.v1; tMesV2=$oEc.v2
                mensual=$mj.mensual.Ecuador; meses=$mj.meses
                interanual=$mj.interanual.Ecuador
                comparativa=$otros
            }
        }
    } catch { Add-Falla -Paso 'Ecuador (Penta)' -Detalle $_.Exception.Message }
}

# --- referencia: IndexMundi (Banco Mundial) ---
$cacheIM = Join-Path $fuentes "indexmundi_cache.json"
try {
    # -UseBasicParsing: ver nota en el scraping de Paraguay (esta PC no tiene IE).
    $rIM = Invoke-WebRequest -Uri 'https://www.indexmundi.com/commodities/?commodity=bananas&months=60' `
             -UserAgent $UA_BROWSER -Headers $HDR_BROWSER -UseBasicParsing -TimeoutSec 40 -ErrorAction Stop
    $serieIM = @()
    $mesesEn = @{Jan=1;Feb=2;Mar=3;Apr=4;May=5;Jun=6;Jul=7;Aug=8;Sep=9;Oct=10;Nov=11;Dec=12}
    foreach ($mm in [regex]::Matches($rIM.Content,'<td[^>]*>\s*([A-Z][a-z]{2})\s+(\d{4})\s*</td>\s*<td[^>]*>\s*([\d.,]+)\s*</td>')) {
        $mn = $mesesEn[$mm.Groups[1].Value]
        if (-not $mn) { continue }
        $serieIM += [PSCustomObject]@{
            fecha = ('{0}-{1:d2}' -f $mm.Groups[2].Value, $mn)
            usdKg = [double]::Parse(($mm.Groups[3].Value -replace ',',''), [System.Globalization.CultureInfo]::InvariantCulture)
        }
    }
    if ($serieIM.Count -gt 0) {
        $serieIM = @($serieIM | Sort-Object fecha)
        $eco.mundial = [ordered]@{
            fuente='IndexMundi / Banco Mundial · banana Centroamerica y Ecuador, FOB puertos EEUU'
            unidad='USD/kg'; puntos=$serieIM.Count
            ultimo=$serieIM[-1].fecha; ultimoValor=$serieIM[-1].usdKg
            serie=$serieIM
        }
        $eco | ConvertTo-Json -Depth 8 -Compress | Out-File $cacheIM -Encoding UTF8
        $lagIM = [math]::Round(((Get-Date) - [DateTime]::Parse($serieIM[-1].fecha + '-01')).TotalDays/30,0)
        Write-Host "    mundial: $($serieIM.Count) meses, ultimo $($serieIM[-1].fecha) = $($serieIM[-1].usdKg) USD/kg (atraso ~$lagIM meses)" -ForegroundColor Green
    }
} catch {
    Add-Falla -Paso 'Ecuador (IndexMundi)' -Detalle $_.Exception.Message
    if (Test-Path $cacheIM) {
        try { $eco.mundial = (Get-Content $cacheIM -Raw -Encoding UTF8 | ConvertFrom-Json).mundial } catch {}
    }
}

# --- oportunista: Tridge, si el sidecar viejo tiene algo ---
$ecOld = Join-Path $fuentes "precios_ecuador.json"
if (Test-Path $ecOld) {
    try {
        $eo = Get-Content $ecOld -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($eo.export -and (@($eo.export)).Count -gt 0) {
            $ue = @($eo.export)[-1]
            $eco.tridge = [ordered]@{
                fuente='Tridge (bloqueado desde ~24/07/2026)'
                ultimo=$ue.date; usdKg=$ue.usd_kg
                dias=[math]::Round(((Get-Date)-[DateTime]::Parse($ue.date)).TotalDays,0)
                puntos=(@($eo.export)).Count
            }
        }
    } catch {}
}

$ecoJson = $eco | ConvertTo-Json -Depth 8 -Compress
Set-Content -Path $ecoPath -Value $ecoJson -Encoding UTF8
Write-Host "    sidecar: fuentes\ecuador.json" -ForegroundColor Green

$ecHtml2 = Join-Path $base "index_ecuador.html"
if (Test-Path $ecHtml2) {
    $eTxt = Get-Content $ecHtml2 -Raw -Encoding UTF8
    $patE2 = '/\*__ECUADOR2_JSON__\*/.*?/\*__END_ECUADOR2__\*/'
    $nE2 = ([regex]::Matches($eTxt, $patE2, 'Singleline')).Count
    if ($nE2 -eq 1) {
        $repE2 = '/*__ECUADOR2_JSON__*/' + $ecoJson + '/*__END_ECUADOR2__*/'
        Set-Content -Path $ecHtml2 -Value ([regex]::Replace($eTxt, $patE2, { param($m) $repE2 }, 'Singleline')) -Encoding UTF8 -NoNewline
        Write-Host "    OK index_ecuador.html" -ForegroundColor Green
    } else {
        Write-Host "    (index_ecuador.html todavia usa el formato viejo de Tridge)" -ForegroundColor DarkYellow
    }
}

# ==========================================================================
# 5g) Calidad y vida verde por lote (index_calidad.html)  [04/09/2026]
#
# EL PUNTO DE TODO ESTO: el analisis de aduana mostro que Brasil perdio un
# tercio de su volumen por CALIDAD (el FOB no se movio). Pero Almar no podia
# medir calidad: las mediciones quedaban en FOTOS dentro de PDFs de descarga.
#
# La planilla `fuentes\calidad_lotes.xlsx` recibe esos mismos numeros escritos
# como numeros. La columna clave es `fecha_rompio`: sin el resultado observado
# no se puede ajustar ningun modelo, por muchos inputs que se junten.
#
# Este paso NO inventa un modelo de vida verde. Muestra lo que hay y dice
# cuantos casos faltan para que valga la pena regresionar. Cuando haya >=15
# lotes con fecha_rompio, recien ahi tiene sentido estimar coeficientes.
# ==========================================================================
# Lector generico de xlsx SIN Excel COM (parsea el XML del zip). Se usa para
# planillas que llena una persona. Ojo: devuelve los valores CRUDOS como los
# guarda Excel — las fechas vienen como serial numerico, no como texto.
function Read-XlsxHoja {
    param([string]$Path, [string]$Hoja)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    $ent = @{}
    foreach ($e in $zip.Entries) {
        $sr = New-Object System.IO.StreamReader($e.Open()); $ent[$e.FullName] = $sr.ReadToEnd(); $sr.Close()
    }
    $zip.Dispose()
    $sst = @()
    if ($ent.ContainsKey('xl/sharedStrings.xml')) {
        foreach ($m in [regex]::Matches($ent['xl/sharedStrings.xml'],'(?s)<si>(.*?)</si>')) {
            $sst += [System.Net.WebUtility]::HtmlDecode((-join ([regex]::Matches($m.Groups[1].Value,'(?s)<t[^>]*>(.*?)</t>') | ForEach-Object { $_.Groups[1].Value })))
        }
    }
    $tgt = $null
    foreach ($m in [regex]::Matches($ent['xl/workbook.xml'],'<sheet[^>]*name="([^"]+)"[^>]*r:id="(rId\d+)"')) {
        if (-not $Hoja -or $m.Groups[1].Value -eq $Hoja) {
            $rm = [regex]::Match($ent['xl/_rels/workbook.xml.rels'],'Id="'+$m.Groups[2].Value+'"[^>]*Target="([^"]+)"')
            $tgt = ($rm.Groups[1].Value -replace '^/?(xl/)?',''); if ($Hoja) { break }
        }
    }
    if (-not $tgt -or -not $ent.ContainsKey("xl/$tgt")) { return @() }
    $out = @()
    foreach ($fm in [regex]::Matches($ent["xl/$tgt"],'(?s)<row[^>]*>(.*?)</row>')) {
        $cel = @{}; $maxc = 0
        foreach ($cm in [regex]::Matches($fm.Groups[1].Value,'(?s)<c r="([A-Z]+)\d+"([^>]*)>(.*?)</c>')) {
            $ref = $cm.Groups[1].Value -replace '\d',''
            $ci = 0; foreach ($ch in $ref.ToCharArray()) { $ci = $ci*26 + ([int][char]$ch - 64) }
            $at = $cm.Groups[2].Value; $inn = $cm.Groups[3].Value
            $vm = [regex]::Match($inn,'(?s)<v>(.*?)</v>')
            $val = if ($vm.Success) { $vm.Groups[1].Value } else { -join ([regex]::Matches($inn,'(?s)<t[^>]*>(.*?)</t>') | ForEach-Object { $_.Groups[1].Value }) }
            if ($at -match 't="s"' -and $val -match '^\d+$') { $val = $sst[[int]$val] }
            $cel[$ci] = [System.Net.WebUtility]::HtmlDecode($val)
            if ($ci -gt $maxc) { $maxc = $ci }
        }
        $fila = @(); for ($i=1; $i -le $maxc; $i++) { $fila += $(if ($cel.ContainsKey($i)) { $cel[$i] } else { '' }) }
        $out += ,$fila
    }
    # `return ,$out` con la coma: sin ella, si la hoja tiene UNA sola fila
    # PowerShell desenrolla el array externo y devuelve las celdas sueltas.
    # Pasaba: con la planilla vacia (solo encabezado) contaba "15 lotes".
    return ,$out
}

Write-Host "[5g] Calidad y vida verde..." -ForegroundColor Cyan
$calXlsx = Join-Path $fuentes "calidad_lotes.xlsx"
$calHtml = Join-Path $base "index_calidad.html"
$MIN_LOTES_MODELO = 15

$cal = [ordered]@{
    generado = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    minLotes = $MIN_LOTES_MODELO
    planilla = 'fuentes\calidad_lotes.xlsx'
    lotes = @(); n = 0; nConResultado = 0
    resumen = $null; porOrigen = @(); porProductor = @(); correl = @()
}

if (-not (Test-Path $calXlsx)) {
    Write-Host "    (skip) falta fuentes\calidad_lotes.xlsx" -ForegroundColor DarkYellow
} else {
  try {
    $filasCal = Read-XlsxHoja -Path $calXlsx -Hoja 'lotes'
    if ($filasCal.Count -lt 2) {
        Write-Host "    planilla vacia todavia — el panel va a explicar como llenarla" -ForegroundColor DarkYellow
    }
    $hdr = @($filasCal[0])
    $idx = @{}
    for ($i=0; $i -lt $hdr.Count; $i++) { if ($hdr[$i]) { $idx[[string]$hdr[$i]] = $i } }
    function Celda { param($fila,$col) if ($idx.ContainsKey($col) -and $idx[$col] -lt $fila.Count) { [string]$fila[$idx[$col]] } else { '' } }
    function NumCel { param($fila,$col)
        $v = Celda $fila $col
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        $v = $v -replace '\s',''
        # la planilla la llena una persona: puede venir con coma decimal
        $v = $v -replace ',','.'
        $o = 0.0
        if ([double]::TryParse($v, [ref]$o)) { return $o }
        return $null
    }
    function FechaCel { param($fila,$col)
        $v = Celda $fila $col
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        $o = 0.0
        if ([double]::TryParse($v, [ref]$o) -and $o -gt 20000 -and $o -lt 80000) { return [DateTime]::FromOADate($o) }
        foreach ($f in 'dd/MM/yyyy','d/M/yyyy','yyyy-MM-dd') {
            $d = [datetime]::MinValue
            if ([DateTime]::TryParseExact($v,$f,$null,[System.Globalization.DateTimeStyles]::None,[ref]$d)) { return $d }
        }
        $d2 = [datetime]::MinValue
        if ([DateTime]::TryParse($v,[ref]$d2)) { return $d2 }
        return $null
    }

    $lotes = @()
    for ($r=1; $r -lt $filasCal.Count; $r++) {
        $f = @($filasCal[$r])
        $cod = Celda $f 'codigo'
        if ([string]::IsNullOrWhiteSpace($cod)) { continue }
        $fRec = FechaCel $f 'fecha_recepcion'
        $fRom = FechaCel $f 'fecha_rompio'
        $fCor = FechaCel $f 'fecha_corte'
        $vidaVerde = $null
        if ($fRec -and $fRom) { $vidaVerde = [math]::Round(($fRom - $fRec).TotalDays,1) }
        $edadCorte = $null
        if ($fCor -and $fRec) { $edadCorte = [math]::Round(($fRec - $fCor).TotalDays,1) }
        $lotes += [PSCustomObject]@{
            codigo=$cod; origen=(Celda $f 'origen'); productor=(Celda $f 'productor')
            fechaRecepcion = if ($fRec) { $fRec.ToString('yyyy-MM-dd') } else { $null }
            cajas=(NumCel $f 'cajas'); tempPulpa=(NumCel $f 'temp_pulpa')
            calibre=(NumCel $f 'calibre_mm'); largo=(NumCel $f 'largo_cm')
            tempCorte=(NumCel $f 'temp_corte'); lluvia=(NumCel $f 'lluvia_sem_mm')
            transito=$edadCorte
            fechaRompio = if ($fRom) { $fRom.ToString('yyyy-MM-dd') } else { $null }
            vidaVerde=$vidaVerde; destino=(Celda $f 'destino'); merma=(NumCel $f 'merma_pct')
            obs=(Celda $f 'obs')
        }
    }
    $cal.lotes = $lotes
    $cal.n = $lotes.Count
    $conRes = @($lotes | Where-Object { $null -ne $_.vidaVerde })
    $cal.nConResultado = $conRes.Count

    if ($conRes.Count -gt 0) {
        $st = $conRes | Measure-Object vidaVerde -Average -Minimum -Maximum
        $cal.resumen = [ordered]@{ prom=[math]::Round($st.Average,1); min=$st.Minimum; max=$st.Maximum }
        foreach ($g in ($conRes | Group-Object origen)) {
            $s2 = $g.Group | Measure-Object vidaVerde -Average -Minimum -Maximum
            $cal.porOrigen += [PSCustomObject]@{ origen=$g.Name; n=$g.Count
                prom=[math]::Round($s2.Average,1); min=$s2.Minimum; max=$s2.Maximum }
        }
        foreach ($g in ($conRes | Group-Object productor | Where-Object { $_.Count -ge 2 })) {
            $s3 = $g.Group | Measure-Object vidaVerde -Average
            $cal.porProductor += [PSCustomObject]@{ productor=$g.Name; n=$g.Count; prom=[math]::Round($s3.Average,1) }
        }
        # correlaciones simples input -> vida verde (solo si hay masa critica)
        if ($conRes.Count -ge $MIN_LOTES_MODELO) {
            foreach ($v in @('tempPulpa','calibre','largo','tempCorte','lluvia','transito')) {
                $pares = @($conRes | Where-Object { $null -ne $_.$v })
                if ($pares.Count -lt $MIN_LOTES_MODELO) { continue }
                $xs = @($pares | ForEach-Object { [double]$_.$v })
                $ys = @($pares | ForEach-Object { [double]$_.vidaVerde })
                $mx2=($xs|Measure-Object -Average).Average; $my2=($ys|Measure-Object -Average).Average
                $sxy2=0.0;$sx22=0.0;$sy22=0.0
                for($i=0;$i -lt $xs.Count;$i++){ $dx=$xs[$i]-$mx2; $dy=$ys[$i]-$my2
                    $sxy2+=$dx*$dy; $sx22+=$dx*$dx; $sy22+=$dy*$dy }
                if ($sx22 -le 0 -or $sy22 -le 0) { continue }
                $cal.correl += [PSCustomObject]@{ variable=$v; n=$pares.Count
                    r=[math]::Round($sxy2/[math]::Sqrt($sx22*$sy22),3) }
            }
        }
    }
    $calJson = $cal | ConvertTo-Json -Depth 8 -Compress
    Set-Content -Path (Join-Path $fuentes "calidad.json") -Value $calJson -Encoding UTF8
    Write-Host "    $($cal.n) lotes cargados, $($cal.nConResultado) con fecha_rompio (hacen falta $MIN_LOTES_MODELO para modelar)" -ForegroundColor Green

    if (Test-Path $calHtml) {
        $cTxt = Get-Content $calHtml -Raw -Encoding UTF8
        $patC = '/\*__CALIDAD_JSON__\*/.*?/\*__END_CALIDAD__\*/'
        if (([regex]::Matches($cTxt,$patC,'Singleline')).Count -eq 1) {
            $repC = '/*__CALIDAD_JSON__*/' + $calJson + '/*__END_CALIDAD__*/'
            Set-Content -Path $calHtml -Value ([regex]::Replace($cTxt,$patC,{ param($m) $repC },'Singleline')) -Encoding UTF8 -NoNewline
            Write-Host "    OK index_calidad.html" -ForegroundColor Green
        }
    }
  } catch {
    Add-Falla -Paso 'Calidad (planilla)' -Detalle $_.Exception.Message
  }
}

# ==========================================================================
# 5e) Portada (inicio.html)  [04/09/2026]
#     Indice de todos los paneles con su estado de actualizacion. Las paginas
#     eran archivos sueltos que habia que abrir por nombre; esto las junta y
#     ademas marca en rojo la que quedo vieja (hoy: Ecuador, Tridge bloqueado).
# ==========================================================================
Write-Host "[5e] Portada..." -ForegroundColor Cyan
$inicioHtml = Join-Path $base "inicio.html"

$panelesDef = @(
    @{ f='index.html';                  t='Plan de compras Brasil';      d='Termometro Cepea, clima, spread vs productores, plan mensual y fechas criticas.'; ico='🍌' },
    @{ f='index_brasil.html';           t='Brasil — detalle';            d='Forecast Cepea, correlacion clima-precio y auditoria del ano.'; ico='🇧🇷' },
    @{ f='index_paraguay_bolivia.html'; t='Paraguay y Bolivia';          d='Precio mayorista Carape y plan multi-origen.'; ico='🇵🇾' },
    @{ f='index_ecuador.html';          t='Ecuador FOB';                 d='Precio FOB de exportacion de Ecuador.'; ico='🇪🇨' },
    @{ f='index_mercado.html';          t='Mercado UY multi-origen';     d='Quien importa que, de donde y cuanto. Datos de aduana.'; ico='🌎' },
    @{ f='index_proyeccion.html';       t='Proyeccion a fin de ano';     d='Precio y volumen proyectados hasta diciembre.'; ico='🔭' },
    @{ f='index_comparativo_anual.html';t='Comparativo anual';           d='Ano contra ano: curvas, salto julio-agosto e invierno.'; ico='📊' },
    @{ f='index_calidad.html';          t='Calidad y vida verde';       d='Cuanto aguanta cada lote y que lo explica. Se llena a mano en fuentes\calidad_lotes.xlsx.'; ico='🌱' },
    @{ f='guia_corte\guia_corte_transversal_banana.html'; t='Guia de corte transversal'; d='Control de calidad del dedo al recibir. Imprimible.'; ico='🔪' },
    @{ f='guia_corte\calculadora_punto_optimo.html';      t='Punto optimo de recepcion'; d='Calculadora: llenado, azucar y si aguanta el flete.'; ico='🧮' },
    @{ f='guia_corte\atlas_cortes.html';                  t='Atlas de cortes';           d='Fotos de referencia de cortes sanos y con problemas.'; ico='🖼️' }
)
$paneles = @()
foreach ($pd in $panelesDef) {
    $fp = Join-Path $base $pd.f
    if (-not (Test-Path $fp)) { continue }
    $fi = Get-Item $fp
    $dias = [math]::Round(((Get-Date) - $fi.LastWriteTime).TotalDays, 1)
    # generada = el script LA DEBERIA tocar en cada corrida. index_ecuador va aca
    # aunque hoy falle (Tridge da 403): justamente por eso tiene que salir marcada
    # en rojo como atrasada, y no disfrazada de pagina estatica.
    $auto = $pd.f -in @('index.html','index_brasil.html','index_paraguay_bolivia.html',
                        'index_ecuador.html','index_mercado.html','index_proyeccion.html',
                        'index_comparativo_anual.html','index_calidad.html')
    $estado = if (-not $auto) { 'estatica' } elseif ($dias -le 8) { 'al dia' } else { 'atrasada' }
    $paneles += [PSCustomObject]@{
        archivo = ($pd.f -replace '\\','/'); titulo = $pd.t; desc = $pd.d; icono = $pd.ico
        actualizado = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); dias = $dias
        auto = $auto; estado = $estado
    }
}
$portada = [ordered]@{
    generado = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    cepea    = [ordered]@{ ultima_semana=$data.ultima_semana; ultimo_precio=$data.ultimo_precio }
    paneles  = $paneles
}
$portadaJson = $portada | ConvertTo-Json -Depth 8 -Compress
Set-Content -Path (Join-Path $fuentes "portada.json") -Value $portadaJson -Encoding UTF8

if (Test-Path $inicioHtml) {
    $iTxt = Get-Content $inicioHtml -Raw -Encoding UTF8
    $patI = '/\*__PORTADA_JSON__\*/.*?/\*__END_PORTADA__\*/'
    $nI = ([regex]::Matches($iTxt, $patI, 'Singleline')).Count
    if ($nI -ne 1) {
        Write-Host "    (skip) inicio.html: esperaba 1 par de marcadores, hay $nI" -ForegroundColor Red
    } else {
        $repI = '/*__PORTADA_JSON__*/' + $portadaJson + '/*__END_PORTADA__*/'
        Set-Content -Path $inicioHtml -Value ([regex]::Replace($iTxt, $patI, { param($m) $repI }, 'Singleline')) -Encoding UTF8 -NoNewline
        Write-Host "    OK inicio.html ($($paneles.Count) paneles)" -ForegroundColor Green
    }
} else {
    Write-Host "    (aviso) falta inicio.html — sidecar generado igual" -ForegroundColor DarkYellow
}

# ==========================================================================
# [ec] Banana Ecuador FOB via Tridge (publico, sin login)
# ==========================================================================
Write-Host "[ec] Bajando precio FOB banana Ecuador (Tridge)... " -NoNewline -ForegroundColor Cyan

$ecJsonPath = Join-Path $fuentes "precios_ecuador.json"
$ecHtmlPath = Join-Path $base "index_ecuador.html"
$ecUrl      = "https://www.tridge.com/intelligences/cavendish-banana/EC/price"
$ecUA       = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
$ECU_KG_PER_BOX = 19.5
$ECU_PMS_2026   = 7.50

function Get-EcuadorFromTridge {
    param($url, $ua)
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = $ua } -UseBasicParsing -TimeoutSec 30
    } catch {
        return @{ error = "fetch failed: $($_.Exception.Message)" }
    }
    $h = $resp.Content
    $blocks = [regex]::Matches($h, '([A-Za-z ]+) unit prices by date in Ecuador: ([^<]{20,3000})')
    $res = @{}
    foreach ($mm in $blocks) {
        $tipoRaw = $mm.Groups[1].Value.Trim()
        $body = $mm.Groups[2].Value
        $key = if ($tipoRaw -match "import") { "import" }
               elseif ($tipoRaw -match "transaction") { "export" }
               else { ($tipoRaw -replace '\s+','_').ToLower() }
        $pairs = [regex]::Matches($body, '(\d{4}-\d{2}-\d{2}):\s*(\d+\.\d+)\s*USD')
        $list = @()
        foreach ($p in $pairs) {
            $list += [ordered]@{ date = $p.Groups[1].Value; usd_kg = [double]$p.Groups[2].Value }
        }
        if ($list.Count -gt 0) { $res[$key] = $list }
    }
    $lu = [regex]::Match($h, 'Last updated:\s*(\d{4}-\d{2}-\d{2})')
    $res["last_updated_tridge"] = if ($lu.Success) { $lu.Groups[1].Value } else { $null }
    return $res
}

function Merge-EcSeries {
    param($existingArr, $newArr, $kgBox)
    if (-not $existingArr) { $existingArr = @() }
    $keys = @{}
    foreach ($p in $existingArr) { $keys["$($p.date)|$($p.usd_kg)"] = $true }
    $added = 0
    $merged = @($existingArr)
    foreach ($nn in $newArr) {
        $k = "$($nn.date)|$($nn.usd_kg)"
        if (-not $keys.ContainsKey($k)) {
            $merged += [pscustomobject]@{
                date    = $nn.date
                usd_kg  = $nn.usd_kg
                usd_box = [math]::Round($nn.usd_kg * $kgBox, 2)
            }
            $keys[$k] = $true
            $added++
        }
    }
    return @{ merged = ($merged | Sort-Object date); added = $added }
}

# Cargar JSON existente o init
$ecData = $null
if (Test-Path $ecJsonPath) {
    try { $ecData = Get-Content $ecJsonPath -Raw | ConvertFrom-Json } catch { $ecData = $null }
}
if (-not $ecData) {
    $ecData = [pscustomobject]@{
        meta = [pscustomobject]@{
            source       = "Tridge (publico, sin login)"
            url          = $ecUrl
            kg_per_box   = $ECU_KG_PER_BOX
            pms_year     = 2026
            pms_usd_box  = $ECU_PMS_2026
            pms_usd_kg   = [math]::Round($ECU_PMS_2026 / $ECU_KG_PER_BOX, 4)
            notas        = "Spot FOB Ecuador. Conversion caja 43 lb = 19.5 kg."
        }
        fetched_at = $null
        last_updated_tridge = $null
        export = @()
        import = @()
    }
}

# Flags para alertas WhatsApp
$script:ecHasNewExport = $false
$script:ecLastPoint    = $null
$script:ecPrevLastPoint = $null

$ecParsed = Get-EcuadorFromTridge -url $ecUrl -ua $ecUA
if ($ecParsed.error) {
    Write-Host "FAIL ($($ecParsed.error))" -ForegroundColor Red
    $edadEc = if (Test-Path $ecJsonPath) { [math]::Round(((Get-Date)-(Get-Item $ecJsonPath).LastWriteTime).TotalDays,0) } else { -1 }
    $detEc = if ($edadEc -ge 0) { "$($ecParsed.error) — datos de hace $edadEc dias" } else { $ecParsed.error }
    Add-Falla -Paso 'Ecuador (Tridge)' -Detalle $detEc
} else {
    # snapshot del ultimo punto anterior para alertas
    if ($ecData.export -and (@($ecData.export)).Count -gt 0) {
        $script:ecPrevLastPoint = ($ecData.export | Sort-Object date | Select-Object -Last 1)
    }
    $ecData.fetched_at          = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $ecData.last_updated_tridge = $ecParsed.last_updated_tridge
    $ecAddedExp = 0; $ecAddedImp = 0
    if ($ecParsed.export) {
        $m1 = Merge-EcSeries -existingArr $ecData.export -newArr $ecParsed.export -kgBox $ECU_KG_PER_BOX
        $ecData.export = $m1.merged
        $ecAddedExp = $m1.added
    }
    if ($ecParsed.import) {
        $m2 = Merge-EcSeries -existingArr $ecData.import -newArr $ecParsed.import -kgBox $ECU_KG_PER_BOX
        $ecData.import = $m2.merged
        $ecAddedImp = $m2.added
    }
    $ecData | ConvertTo-Json -Depth 8 | Out-File $ecJsonPath -Encoding utf8

    # Inyectar en HTML
    if (Test-Path $ecHtmlPath) {
        $htmlEC = Get-Content $ecHtmlPath -Raw -Encoding UTF8
        $jsonEC = $ecData | ConvertTo-Json -Depth 8
        $patEC = '/\*__ECUADOR_JSON__\*/.*?/\*__END__\*/'
        $repEC = '/*__ECUADOR_JSON__*/' + $jsonEC.Trim() + '/*__END__*/'
        $newH = [regex]::Replace($htmlEC, $patEC, { param($mm) $repEC }, 'Singleline')
        if ($newH -ne $htmlEC) { Set-Content -Path $ecHtmlPath -Value $newH -Encoding UTF8 -NoNewline }
    }

    if ($ecData.export -and (@($ecData.export)).Count -gt 0) {
        $script:ecLastPoint = ($ecData.export | Sort-Object date | Select-Object -Last 1)
    }
    $script:ecHasNewExport = ($ecAddedExp -gt 0)

    if ($script:ecLastPoint) {
        Write-Host ("OK (+{0} exp, +{1} imp, last {2}: USD {3:N2}/caja)" -f $ecAddedExp, $ecAddedImp, $script:ecLastPoint.date, $script:ecLastPoint.usd_box) -ForegroundColor Green
    } else {
        Write-Host "OK (sin datos)" -ForegroundColor Yellow
    }
}

# ==========================================================================
# 5) Sistema de alertas - zona estacional + movimientos fuertes
# ==========================================================================
Write-Host "[6/6] Evaluando alertas..." -ForegroundColor Cyan

$statePath = Join-Path $fuentes "state_alertas.json"
$logPath   = Join-Path $base "alertas.log"

function Get-Zone {
    param([double]$promMes)
    if     ($promMes -le 1.10) { return "BAJA" }
    elseif ($promMes -le 1.60) { return "MEDIA" }
    else                        { return "ALTA" }
}

# --------------------------------------------------------------------------
# Get-AccionZona (agregado 02/09/2026)
#
# PROBLEMA QUE RESUELVE: la zona sale del promedio historico del mes cruzando
# TODOS los anios (ver "Promedios mensuales (todos los anios)"). O sea es un
# calendario, no el mercado de hoy. La zona puede cambiar sola solo porque el
# ultimo dato paso de un mes al siguiente, sin que el precio haya hecho nada.
#
# Paso el 02/09/2026: salto MEDIA -> ALTA (agosto historico = R$ 1,72) y
# recomendo "reducir compras spot" mientras el precio real venia de 4 semanas
# en caida y estaba en R$ 0,99 — el mas bajo desde junio. Consejo al reves.
#
# FIX: la recomendacion ahora cruza el calendario con la posicion real del
# precio contra ese mismo promedio historico. Si divergen mas de 12%, avisa
# de la divergencia en lugar de repetir la accion del calendario.
# --------------------------------------------------------------------------
function Get-AccionZona {
    param(
        [string]$zona,
        [double]$vsHistPct   # % del precio real vs el promedio historico del mes (+ arriba / - abajo)
    )
    $DIVERGE = 12.0
    $abs = [math]::Abs([math]::Round($vsHistPct))

    if ($zona -eq "ALTA") {
        if ($vsHistPct -le -$DIVERGE) {
            return "Mes caro por calendario, PERO el precio real esta $abs% por debajo del historico. Ventana atipica: no reducir por calendario, evaluar compra."
        }
        return "Reducir compras spot."
    }
    elseif ($zona -eq "BAJA") {
        if ($vsHistPct -ge $DIVERGE) {
            return "Mes barato por calendario, PERO el precio real esta $abs% por encima del historico. Cautela: no comprar fuerte a ciegas."
        }
        return "Comprar fuerte."
    }
    else {
        if ($vsHistPct -le -$DIVERGE) { return "Compras normales, con sesgo a comprar: precio $abs% bajo el historico del mes." }
        if ($vsHistPct -ge  $DIVERGE) { return "Compras normales, con cautela: precio $abs% sobre el historico del mes." }
        return "Compras normales."
    }
}

function Show-Toast {
    param([string]$title, [string]$message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $balloon = New-Object System.Windows.Forms.NotifyIcon
        $balloon.Icon = [System.Drawing.SystemIcons]::Information
        $balloon.BalloonTipIcon  = [System.Windows.Forms.ToolTipIcon]::Info
        $balloon.BalloonTipTitle = $title
        $balloon.BalloonTipText  = $message
        $balloon.Visible = $true
        $balloon.ShowBalloonTip(15000)
        Start-Sleep -Milliseconds 1200
        $balloon.Dispose()
    } catch {
        Write-Host "    (no pude mostrar toast: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function Write-Alert {
    param([string]$titulo, [string]$mensaje, [string]$nivel="info")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
    $line = "[$ts] [$nivel] $titulo :: $mensaje"
    Add-Content -Path $logPath -Value $line -Encoding UTF8
    Write-Host "    >>> $line" -ForegroundColor Yellow
    Show-Toast -title "Cepea Alerta - $titulo" -message $mensaje
}

# Estado actual
$ultimoMes   = $nanica[-1].mes
$ultimoPrec  = $nanica[-1].precio
$ultimaFecha = $nanica[-1].fecha
$promMesAct  = $promedioMes["$ultimoMes"]
$zonaActual  = Get-Zone -promMes $promMesAct

# Contexto real del mes en curso (para no confundirlo con el promedio historico)
$MESES_NOM = @('','enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre')
$nombreMes  = $MESES_NOM[[int]$ultimoMes]
$mesUmbral6m = $MESES_NOM[[int](Get-Date).AddMonths(-6).Month]
$anioUlt    = $nanica[-1].anio
$valsMesAct = @($nanica | Where-Object { $_.mes -eq $ultimoMes -and $_.anio -eq $anioUlt } | ForEach-Object { $_.precio })
$promMesReal = if ($valsMesAct.Count -gt 0) { [math]::Round((($valsMesAct | Measure-Object -Average).Average), 2) } else { $ultimoPrec }
$vsHistPct  = if ($promMesAct -gt 0) { (($ultimoPrec - $promMesAct) / $promMesAct) * 100 } else { 0 }

# Variacion semanal
$deltaSem = 0.0
if ($nanica.Count -ge 2) {
    $prev = $nanica[-2].precio
    $deltaSem = (($ultimoPrec - $prev) / $prev) * 100
}

# Minimo/maximo ultimos 6 meses
$umbralFecha = (Get-Date).AddMonths(-6).ToString("yyyy-MM-dd")
$ult6m = $nanica | Where-Object { $_.fecha -ge $umbralFecha }
$minimo6m = if ($ult6m) { ($ult6m | Measure-Object -Property precio -Minimum).Minimum } else { $null }
$maximo6m = if ($ult6m) { ($ult6m | Measure-Object -Property precio -Maximum).Maximum } else { $null }

# Cargar estado previo
$prevState = $null
if (Test-Path $statePath) {
    try { $prevState = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $prevState = $null }
}

$nuevasAlertas = 0
$msgs = @()

if ($prevState -and $prevState.ultima_fecha -eq $ultimaFecha) {
    Write-Host "    Sin datos nuevos (misma semana $ultimaFecha) - no evaluo alertas." -ForegroundColor Gray
}
else {
    # 1) Cambio de zona
    if ($prevState -and $prevState.ultima_zona -and $prevState.ultima_zona -ne $zonaActual) {
        $emojiNueva = if ($zonaActual -eq "BAJA") {"GREEN"} elseif ($zonaActual -eq "MEDIA") {"AMBAR"} else {"RED"}
        $titulo = "Cambio de zona: $($prevState.ultima_zona) -> $zonaActual"
        $sgnVs  = if ($vsHistPct -ge 0) { "+" } else { "" }
        $msg  = "Precio R$ $ultimoPrec/kg ($ultimaFecha). "
        $msg += "Promedio HISTORICO de $nombreMes (todos los anios): R$ $promMesAct. "
        $msg += "Real $nombreMes/$($anioUlt): R$ $promMesReal. "
        $msg += "Precio vs historico: $sgnVs$([math]::Round($vsHistPct))%. "
        $msg += "ACCION: " + (Get-AccionZona -zona $zonaActual -vsHistPct $vsHistPct)
        Write-Alert -titulo $titulo -mensaje $msg -nivel "ZONA"
        $nuevasAlertas++
        $msgs += $titulo
    }
    # 2) Movimiento semanal fuerte (>=15%)
    if ([Math]::Abs($deltaSem) -ge 15) {
        $direccion = if ($deltaSem -lt 0) {"BAJA"} else {"SUBE"}
        $titulo = "Movimiento fuerte semanal $direccion"
        $msg = ("{0:F1}% en una semana: R$ {1} -> R$ {2} ({3})." -f $deltaSem, $nanica[-2].precio, $ultimoPrec, $ultimaFecha)
        Write-Alert -titulo $titulo -mensaje $msg -nivel "MOVIMIENTO"
        $nuevasAlertas++
        $msgs += $titulo
    }
    # 3) Nuevo minimo / maximo 6 meses
    if ($minimo6m -ne $null -and $ultimoPrec -le $minimo6m -and ($ult6m | Where-Object { $_.precio -eq $minimo6m } | Measure-Object).Count -eq 1) {
        $titulo = "Nuevo MINIMO de 6 meses"
        $msg = "Precio R$ $ultimoPrec/kg es el mas bajo desde $mesUmbral6m."
        Write-Alert -titulo $titulo -mensaje $msg -nivel "EXTREMO"
        $nuevasAlertas++
    }
    if ($maximo6m -ne $null -and $ultimoPrec -ge $maximo6m -and ($ult6m | Where-Object { $_.precio -eq $maximo6m } | Measure-Object).Count -eq 1) {
        $titulo = "Nuevo MAXIMO de 6 meses"
        $msg = "Precio R$ $ultimoPrec/kg es el mas alto desde $mesUmbral6m."
        Write-Alert -titulo $titulo -mensaje $msg -nivel "EXTREMO"
        $nuevasAlertas++
    }
    if ($nuevasAlertas -eq 0) {
        Write-Host "    Sin alertas. Zona estable: $zonaActual, variacion semanal $($deltaSem.ToString('F1'))%" -ForegroundColor Green
    }
}

# Guardar nuevo estado
$nuevoEstado = [PSCustomObject]@{
    ultima_fecha          = $ultimaFecha
    ultimo_precio         = $ultimoPrec
    ultima_zona           = $zonaActual
    promedio_mes_actual   = $promMesAct
    delta_semanal_pct     = [math]::Round($deltaSem, 2)
    actualizado           = (Get-Date -Format "yyyy-MM-dd HH:mm")
}
$nuevoEstado | ConvertTo-Json -Depth 5 | Out-File $statePath -Encoding UTF8

# ==========================================================================
# 7) Alertas WhatsApp via Whapi.cloud
# ==========================================================================
Write-Host "[WA] Evaluando alertas WhatsApp..." -ForegroundColor Cyan

$waConfig = $null
if (Test-Path $waConfigPath) {
    try { $waConfig = Get-Content $waConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}

$waPhones = @()
if ($null -ne $waConfig) {
    if ($waConfig.PSObject.Properties.Name -contains 'phones' -and $waConfig.phones) {
        $waPhones = @($waConfig.phones)
    } elseif ($waConfig.PSObject.Properties.Name -contains 'phone' -and -not [string]::IsNullOrWhiteSpace($waConfig.phone)) {
        $waPhones = @($waConfig.phone)
    }
}

if ($null -eq $waConfig -or -not $waConfig.enabled) {
    Write-Host "    WhatsApp deshabilitado (config/whatsapp.json)" -ForegroundColor DarkYellow
} elseif ($waPhones.Count -eq 0 -or [string]::IsNullOrWhiteSpace($waConfig.token)) {
    Write-Host "    Falta phones o token en config/whatsapp.json - completar para activar" -ForegroundColor DarkYellow
} else {

    # Cargar state
    $waState = @{}
    if (Test-Path $waStatePath) {
        try {
            $obj = Get-Content $waStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $obj.PSObject.Properties | ForEach-Object { $waState[$_.Name] = $_.Value }
        } catch {}
    }

    # Acumulador de numeros que fallaron en toda la corrida. Se persiste al final
    # en el state, porque la tarea corre desatendida y nadie lee la consola.
    $script:waFallos = @()

    function Send-WA { param([string]$msg)
        $headers = @{
            'Authorization' = "Bearer $($waConfig.token)"
        }
        $okList = @(); $failList = @()
        foreach ($p in $waPhones) {
            $phoneClean = ([string]$p) -replace '[^\d]',''
            if ([string]::IsNullOrWhiteSpace($phoneClean)) { continue }
            $body = @{ to = $phoneClean; body = $msg } | ConvertTo-Json -Compress
            # FIX encoding: PowerShell por defecto manda en Windows-1252 → mojibake
            # Forzamos UTF-8 bytes para que pasen emojis y acentos
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $sent = $false; $ultimoError = ''
            for ($intento = 1; $intento -le 3 -and -not $sent; $intento++) {
                try {
                    $r = Invoke-RestMethod -Uri 'https://gate.whapi.cloud/messages/text' -Method Post -Headers $headers -Body $bodyBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
                    $sent = $true
                    $msgId = if ($r.message.id) { [string]$r.message.id } else { '(sin id)' }
                    Write-Host ("      OK    {0,-14} {1}" -f $phoneClean, $msgId) -ForegroundColor Green
                } catch {
                    $ultimoError = $_.Exception.Message
                    Write-Host ("      retry {0,-14} {1}/3: {2}" -f $phoneClean, $intento, $ultimoError) -ForegroundColor DarkYellow
                    if ($intento -lt 3) { Start-Sleep -Seconds 3 }
                }
            }
            if ($sent) {
                $okList += $phoneClean
            } else {
                $failList += $phoneClean
                $script:waFallos += $phoneClean
                Write-Host ("      FALLO {0,-14} sin envio tras 3 intentos: {1}" -f $phoneClean, $ultimoError) -ForegroundColor Red
            }
        }
        # 'ok' = al menos uno entregado. A proposito NO exigimos que entren todos:
        # si un numero queda muerto permanentemente, exigir 100% haria que la alerta
        # no marque ts_<tipo> y se re-dispare en cada corrida, spameando a los que si andan.
        # El detalle de quien fallo queda en 'fallidos' y en $script:waFallos.
        return [pscustomobject]@{
            ok       = ($okList.Count -gt 0)
            todos    = ($failList.Count -eq 0)
            enviados = $okList
            fallidos = $failList
            total    = ($okList.Count + $failList.Count)
        }
    }

    function Can-Send { param([string]$tipo)
        if (-not $waState.ContainsKey("ts_$tipo")) { return $true }
        try {
            $last = [DateTime]::Parse($waState["ts_$tipo"])
            return ((Get-Date) - $last).TotalHours -ge [double]$waConfig.min_silence_hours
        } catch { return $true }
    }

    # ---- Calcular Opportunity Score (SYNC con JS de index_brasil.html) ----
    $oppCepeaSig = 0; $oppZonaSig = 0; $oppSpreadSig = 0; $oppClimaSig = 0
    $pctChg1w = 0; $pctChg3w = 0; $pctChgEf = 0; $spreadAvg = 0
    $zonaAct = "MEDIA"
    $oppLast = if ($nanica.Count -ge 1) { [double]$nanica[-1].precio } else { 0 }

    # SEÑAL 1: Cepea - considera el peor entre 1-sem y 3-sem (capta rebotes recientes)
    if ($nanica.Count -ge 2) {
        $oppRef1 = [double]$nanica[-2].precio
        $pctChg1w = (($oppLast - $oppRef1) / $oppRef1) * 100
    }
    if ($nanica.Count -ge 4) {
        $oppRef3 = [double]$nanica[-4].precio
        $pctChg3w = (($oppLast - $oppRef3) / $oppRef3) * 100
    }
    # Tomar la lectura de mayor magnitud (la que más penaliza al comprador)
    $pctChgEf = if ([Math]::Abs($pctChg1w) -gt [Math]::Abs($pctChg3w)) { $pctChg1w } else { $pctChg3w }
    if ($pctChgEf -lt -15) { $oppCepeaSig = 2 }
    elseif ($pctChgEf -lt -5) { $oppCepeaSig = 1 }
    elseif ($pctChgEf -gt 15) { $oppCepeaSig = -2 }
    elseif ($pctChgEf -gt 5) { $oppCepeaSig = -1 }

    # SEÑAL 2: Zona estacional
    $oppMes = [int]([DateTime]::Parse($nanica[-1].fecha).Month)
    $oppPM = if ($promedioMes.Contains("$oppMes")) { [double]$promedioMes["$oppMes"] } else { 1.36 }
    if ($oppPM -le 1.10) { $oppZonaSig = 2; $zonaAct = "BAJA" }
    elseif ($oppPM -le 1.60) { $oppZonaSig = 0; $zonaAct = "MEDIA" }
    else { $oppZonaSig = -2; $zonaAct = "ALTA" }

    # SEÑAL 3: Spread Almar vs Cepea
    if ($almarSemanas.Count -ge 3) {
        $ult4 = $almarSemanas | Select-Object -Last 4
        $diffs = @()
        foreach ($w in $ult4) {
            $c = $nanica | Where-Object { $_.fecha -eq $w.fecha } | Select-Object -First 1
            if ($c) {
                $cepeaCaja = ([double]$c.precio) * $KG_CAJA_NETO + $SERVICIOS_CAJA
                $diffs += ([double]$w.precio_avg_caja - $cepeaCaja)
            }
        }
        if ($diffs.Count -gt 0) {
            $spreadAvg = ($diffs | Measure-Object -Average).Average
            if ($spreadAvg -gt 5) { $oppSpreadSig = 2 }
            elseif ($spreadAvg -gt 2) { $oppSpreadSig = 1 }
            elseif ($spreadAvg -lt -2) { $oppSpreadSig = -1 }
        }
    }

    # SEÑAL 4: Clima - frío reciente (tmin últimas 2 sem) tiene prioridad sobre tmax lag 4
    $brTmax4 = @(); $brTminReciente = @()
    foreach ($r in $climaData) {
        if ($r.bandera -ne 'BR') { continue }
        if ($r.historico_semanal.Count -ge 5) {
            $brTmax4 += [double]$r.historico_semanal[$r.historico_semanal.Count - 5].tmax_avg
        }
        $r.historico_semanal | Select-Object -Last 2 | ForEach-Object {
            if ($_.tmin_avg -ne $null) { $brTminReciente += [double]$_.tmin_avg }
        }
    }
    $tminAvgReciente = if ($brTminReciente.Count -gt 0) { ($brTminReciente | Measure-Object -Average).Average } else { $null }
    $tmaxAvg4 = if ($brTmax4.Count -gt 0) { ($brTmax4 | Measure-Object -Average).Average } else { $null }

    # Prioridad: frío reciente fuerte > frío moderado > tmax lag 4
    if ($null -ne $tminAvgReciente -and $tminAvgReciente -lt 13) {
        $oppClimaSig = -2
    } elseif ($null -ne $tminAvgReciente -and $tminAvgReciente -lt 15) {
        $oppClimaSig = -1
    } elseif ($null -ne $tmaxAvg4 -and $tmaxAvg4 -gt 28) {
        $oppClimaSig = 1
    } elseif ($null -ne $tmaxAvg4 -and $tmaxAvg4 -lt 20) {
        $oppClimaSig = -1
    }

    $oppScore = $oppCepeaSig + $oppZonaSig + $oppSpreadSig + $oppClimaSig

    $oppLevel = if ($oppScore -ge 4) { "🟢🟢 OPORTUNIDAD CLARA" }
                elseif ($oppScore -ge 2) { "🟢 BUENA VENTANA" }
                elseif ($oppScore -ge -1) { "🟡 NORMAL" }
                elseif ($oppScore -ge -3) { "🟠 CAUTELA" }
                else { "🔴 STOP COMPRA" }

    $tminTxt = if ($null -ne $tminAvgReciente) { $tminAvgReciente.ToString('F1') + '°C' } else { 'n/a' }
    Write-Host "    Score: $oppScore ($oppLevel) | Cepea[1w:$($pctChg1w.ToString('F1'))%/3w:$($pctChg3w.ToString('F1'))%→ef:$($pctChgEf.ToString('F1'))% sig=$oppCepeaSig] | Zona:$zonaAct(sig=$oppZonaSig) | Spread:$($spreadAvg.ToString('F1'))(sig=$oppSpreadSig) | Clima[tmin2w:$tminTxt sig=$oppClimaSig]" -ForegroundColor Cyan

    # Cargar score/zona previos
    $prevScore = if ($waState.ContainsKey('ultimo_score')) { [int]$waState['ultimo_score'] } else { 0 }
    $prevZona  = if ($waState.ContainsKey('ultima_zona')) { [string]$waState['ultima_zona'] } else { "" }

    $alertasFire = @()

    # ===== ALERTAS CRITICAS DE COMPRA =====
    if ($waConfig.alerts.criticas_compra) {
        # Score crossing thresholds (+4 or -4)
        $wasGood = $prevScore -ge 4
        $isGood  = $oppScore  -ge 4
        $wasBad  = $prevScore -le -4
        $isBad   = $oppScore  -le -4
        if (($isGood -and -not $wasGood)) {
            $msg = "🍌 *ALMAR — Oportunidad*`n$oppLevel (score +$oppScore)`n`n"
            $msg += "Cepea: R$ $($oppLast.ToString('F2'))/kg ($($pctChg3w.ToString('F1'))% 3sem)`n"
            $msg += "Zona: $zonaAct (prom mes R$ $($oppPM.ToString('F2')))`n"
            if ($spreadAvg -ne 0) { $sgnSpr = if ($spreadAvg -ge 0) {"+"} else {""}; $msg += "Spread Almar: $sgnSpr$($spreadAvg.ToString('F1'))/caja`n" }
            $msg += "`n👉 Cerrá contratos largos esta semana"
            $alertasFire += @{ tipo='criticas'; msg=$msg }
        }
        if ($isBad -and -not $wasBad) {
            $msg = "🍌 *ALMAR — STOP*`n$oppLevel (score $oppScore)`n`n"
            $msg += "Cepea: R$ $($oppLast.ToString('F2'))/kg ($($pctChg3w.ToString('F1'))% 3sem)`n"
            $msg += "Zona: $zonaAct`n`n"
            $msg += "👉 Activá contratos previos / freno compras spot"
            $alertasFire += @{ tipo='criticas'; msg=$msg }
        }
        # Cambio de zona
        if ($prevZona -ne "" -and $prevZona -ne $zonaAct) {
            $emoji = if ($zonaAct -eq "BAJA") {"🟢"} elseif ($zonaAct -eq "MEDIA") {"🟡"} else {"🔴"}
            $msg = "🍌 *ALMAR — Cambio de zona*`n$emoji $zonaAct activada (era $prevZona)`n`n"
            $vsHistWA = if ($oppPM -gt 0) { (($oppLast - $oppPM) / $oppPM) * 100 } else { 0 }
            $sgnWA    = if ($vsHistWA -ge 0) { "+" } else { "" }
            $msg += "Precio hoy: R$ $($oppLast.ToString('F2'))/kg`n"
            $msg += "Histórico de $nombreMes (todos los años): R$ $($oppPM.ToString('F2'))/kg`n"
            $msg += "Real $nombreMes/$($anioUlt): R$ $($promMesReal.ToString('F2'))/kg`n"
            $msg += "Precio vs histórico: *$sgnWA$([math]::Round($vsHistWA))%*`n`n"
            if ([math]::Abs($vsHistWA) -ge 12) {
                $msg += "⚠️ _La zona es calendario, no mercado. Este mes están divergiendo._`n`n"
            }
            $msg += "👉 " + (Get-AccionZona -zona $zonaAct -vsHistPct $vsHistWA)
            $alertasFire += @{ tipo='zona'; msg=$msg }
        }
    }

    # ===== MOVIMIENTOS DE PRECIO =====
    if ($waConfig.alerts.movimientos_precio) {
        # Cepea ±15% sem
        if ($nanica.Count -ge 2) {
            $deltaSem = (([double]$nanica[-1].precio - [double]$nanica[-2].precio) / [double]$nanica[-2].precio) * 100
            if ([Math]::Abs($deltaSem) -ge 15) {
                $dir = if ($deltaSem -lt 0) {"⚡ Cepea CAYÓ"} else {"⚡ Cepea SUBIÓ"}
                $msg = "🍌 *ALMAR — Movimiento*`n$dir $($deltaSem.ToString('F1'))% en una semana`n"
                $msg += "R$ $($nanica[-2].precio.ToString('F2')) → R$ $($nanica[-1].precio.ToString('F2'))/kg"
                $alertasFire += @{ tipo='mov'; msg=$msg }
            }
        }
        # Forecast cambio >20%
        if ($correlData -and $correlData.Count -gt 0) {
            $fc4Vals = @()
            foreach ($cd in $correlData) {
                if ($cd.forecast_4w -and $cd.forecast_4w.Count -ge 4) {
                    $fc4Vals += [double]$cd.forecast_4w[-1].precio_pred
                }
            }
            if ($fc4Vals.Count -gt 0) {
                $fc4Avg = ($fc4Vals | Measure-Object -Average).Average
                $hoyPrec = [double]$nanica[-1].precio
                $fcPct = (($fc4Avg - $hoyPrec) / $hoyPrec) * 100
                if ([Math]::Abs($fcPct) -ge 20) {
                    $tendencia = if ($fcPct -gt 0) {"📈 AL ALZA"} else {"📉 A LA BAJA"}
                    $fc4Date = $correlData[0].forecast_4w[-1].fecha
                    $msg = "🍌 *ALMAR — Forecast 4 sem*`n🔮 Tendencia: $tendencia ($($fcPct.ToString('F1'))%)`n`n"
                    $msg += "Hoy: R$ $($hoyPrec.ToString('F2'))/kg`n"
                    $msg += "$fc4Date proyectado: R$ $($fc4Avg.ToString('F2'))/kg`n`n"
                    $accion = if ($fcPct -gt 0) { "Cerrá precio antes del repunte" } else { "Esperá la baja antes de cerrar" }
                    $msg += "👉 $accion"
                    $alertasFire += @{ tipo='forecast'; msg=$msg }
                }
            }
        }
    }

    # ===== CLIMA SEVERO (compactado por zona) =====
    if ($waConfig.alerts.clima_severo) {
        $climaPorZona = @()
        $totalAlertas = 0
        foreach ($r in $climaData) {
            if ($r.alertas -and $r.alertas.Count -gt 0) {
                $bandFlag = if ($r.bandera -eq 'BR') {"🇧🇷"} elseif ($r.bandera -eq 'PY') {"🇵🇾"} elseif ($r.bandera -eq 'BO') {"🇧🇴"} else {""}
                $totalAlertas += $r.alertas.Count
                # Extraer fechas (dd/mm) y temperaturas mínimas de los strings de alerta
                $fechas = @()
                $tempMin = $null
                foreach ($a in $r.alertas) {
                    if ($a -match '(\d{4}-\d{2}-(\d{2}))') {
                        $fechas += "$($Matches[2])/$([int]$a.Substring($a.IndexOf($Matches[1])+5, 2))"
                    }
                    if ($a -match 'min ([\d.]+)') {
                        $t = [double]$Matches[1]
                        if ($null -eq $tempMin -or $t -lt $tempMin) { $tempMin = $t }
                    }
                }
                $fechasStr = ($fechas | Select-Object -Unique) -join ', '
                $tempStr = if ($null -ne $tempMin) { " · mín $($tempMin)°C" } else { "" }
                $climaPorZona += "$bandFlag *$($r.ciudad)*: $($r.alertas.Count) día(s) de frío ($fechasStr)$tempStr"
            }
        }
        if ($climaPorZona.Count -gt 0) {
            $msg = "🍌 *ALMAR · Clima severo*`n⚠️ $totalAlertas alerta(s) en $($climaPorZona.Count) zona(s) próx 7 días:`n`n"
            $msg += $climaPorZona -join "`n"
            $msg += "`n`n_Frío bajo 15°C frena crecimiento de banana — esperar menor oferta en 4-6 semanas, presión al alza._"
            $alertasFire += @{ tipo='clima'; msg=$msg }
        }
    }

    # ===== PRECIO PARAGUAY (movimiento ≥10% vs medición anterior) =====
    if ($waConfig.alerts.precio_py -and $null -ne $pyData -and $pyData.serie -and $pyData.serie.Count -ge 2) {
        $pySerieOrd = $pyData.serie | Sort-Object fecha
        $pyUlt = [double]$pySerieOrd[-1].precio_caja_pyg
        $pyAnt = [double]$pySerieOrd[-2].precio_caja_pyg
        if ($pyAnt -gt 0) {
            $pyDelta = (($pyUlt - $pyAnt) / $pyAnt) * 100
            $pyLastTs = $waState['py_last_precio']
            $cambioDesdeUltimaAlerta = $true
            if ($null -ne $pyLastTs) {
                try {
                    $pyAlertado = [double]$pyLastTs
                    if ([Math]::Abs($pyUlt - $pyAlertado) -lt 1) { $cambioDesdeUltimaAlerta = $false }
                } catch {}
            }
            if ([Math]::Abs($pyDelta) -ge 10 -and $cambioDesdeUltimaAlerta) {
                $dirPy = if ($pyDelta -gt 0) {'⚡ PY SUBIÓ'} else {'⬇️ PY BAJÓ'}
                $sgnPy = if ($pyDelta -gt 0) {'+'} else {''}
                $msg = "🍌 *ALMAR · 🇵🇾 Movimiento Paraguay*`n"
                $msg += "$dirPy $sgnPy$($pyDelta.ToString('F1'))% (mayorista Asunción)`n"
                $msg += "PYG $($pyAnt.ToString('N0')) → *PYG $($pyUlt.ToString('N0'))/caja*`n"
                # Comparativa con BR
                $kg = if ($pyData.kg_caja_aprox) { [double]$pyData.kg_caja_aprox } else { 24 }
                $pyUsdKg = ($pyUlt / 7500.0) / $kg
                $brUsdKg = ($oppLast + 0.73) / 5.2
                $diffPct = if ($brUsdKg -gt 0) { (($pyUsdKg - $brUsdKg) / $brUsdKg) * 100 } else { 0 }
                $sgnVs = if ($diffPct -ge 0) {'+'} else {''}
                $msg += "≈ USD $($pyUsdKg.ToString('F2'))/kg · $sgnVs$($diffPct.ToString('F0'))% vs BR`n`n"
                if ($pyDelta -gt 0 -and $diffPct -gt 30) {
                    $msg += "_PY se aleja de BR — sustitución por calidad se vuelve más cara_"
                } elseif ($pyDelta -lt 0 -and $diffPct -lt 0) {
                    $msg += "_PY más barato que BR — oportunidad de sustitución si la calidad acompaña_"
                } else {
                    $msg += "_Monitorear evolución_"
                }
                $alertasFire += @{ tipo='py'; msg=$msg }
                $waState['py_last_precio'] = $pyUlt.ToString()
            }
        }
    }

    # ===== ECUADOR (Tridge FOB) =====
    if ($waConfig.alerts.movimientos_precio -and $script:ecHasNewExport -and $script:ecLastPoint) {
        $ecP = [double]$script:ecLastPoint.usd_box
        $ecD = $script:ecLastPoint.date
        $ecPmsBox = 7.50
        $spread = (($ecP - $ecPmsBox) / $ecPmsBox) * 100
        $sgnEc = if ($spread -ge 0) {"+"} else {""}
        $msgEc = "🍌 *ALMAR · 🇪🇨 Ecuador spot FOB*`n"
        $msgEc += "Nuevo punto $ecD : *USD $($ecP.ToString('F2'))/caja*`n"
        if ($script:ecPrevLastPoint) {
            $prevP = [double]$script:ecPrevLastPoint.usd_box
            $prevD = $script:ecPrevLastPoint.date
            if ($prevP -ne 0) { $delta = (($ecP - $prevP) / $prevP) * 100 } else { $delta = 0 }
            $sgnPrev = if ($delta -ge 0) {"+"} else {""}
            $msgEc += "vs $prevD : USD $($prevP.ToString('F2')) ($sgnPrev$($delta.ToString('F1'))%)`n"
        }
        $msgEc += "vs PMS USD $($ecPmsBox.ToString('F2')) : *$sgnEc$($spread.ToString('F0'))%*`n`n"
        if ($spread -gt 50) {
            $msgEc += "_Demanda externa fuerte — productor cobra muy arriba del piso_"
        } elseif ($spread -lt -10) {
            $msgEc += "_Spot BAJO el PMS — sobreoferta o rechazo_"
        } else {
            $msgEc += "_Spot cerca del PMS — mercado equilibrado_"
        }
        $alertasFire += @{ tipo='ecuador'; msg=$msgEc }
    }

    # ===== RESUMEN SEMANAL =====
    # Dispara: Miércoles (mid-week check) o Viernes (post-Cepea publish) o >=3 días sin resumen
    if ($waConfig.alerts.resumen_semanal) {
        $sendResumen = $false
        $hoyDow = (Get-Date).DayOfWeek
        if ($hoyDow -eq [DayOfWeek]::Friday -or $hoyDow -eq [DayOfWeek]::Wednesday) { $sendResumen = $true }
        elseif ($waState.ContainsKey('ts_resumen')) {
            try {
                $diasUltimoResumen = ((Get-Date) - [DateTime]::Parse($waState['ts_resumen'])).TotalDays
                if ($diasUltimoResumen -ge 3) { $sendResumen = $true }
            } catch { $sendResumen = $true }
        } else { $sendResumen = $true }

        if ($sendResumen) {
            # Delta semanal para contexto
            $deltaSemPct = $null
            $precioSemAnt = $null
            if ($nanica.Count -ge 2) {
                $precioSemAnt = [double]$nanica[-2].precio
                $deltaSemPct = (($oppLast - $precioSemAnt) / $precioSemAnt) * 100
            }
            $zonaEmoji = if ($zonaAct -eq "BAJA") {"🟢"} elseif ($zonaAct -eq "MEDIA") {"🟡"} else {"🔴"}
            # vs promedio del mes
            $vsProm = (($oppLast - $oppPM) / $oppPM) * 100

            $msg = "🍌 *ALMAR · Resumen semanal $((Get-Date).ToString('dd/MM'))*`n`n"
            $msg += "*💰 Cepea:* R$ $($oppLast.ToString('F2'))/kg"
            if ($null -ne $deltaSemPct) {
                $sgnD = if ($deltaSemPct -ge 0) {"+"} else {""}
                $msg += " ($sgnD$($deltaSemPct.ToString('F1'))% vs R$ $($precioSemAnt.ToString('F2')) sem ant)"
            }
            $msg += "`n"
            $sgnP = if ($vsProm -ge 0) {"+"} else {""}
            $msg += "*📅 Zona:* $zonaEmoji $zonaAct (prom $nombreMes R$ $($oppPM.ToString('F2')) → $sgnP$($vsProm.ToString('F0'))%)`n"
            $msg += "*🎯 Score:* $oppScore · $oppLevel`n"
            if ($spreadAvg -ne 0) {
                $sgn = if ($spreadAvg -ge 0) {"+"} else {""}
                $msg += "*💵 Spread Almar:* $sgn$($spreadAvg.ToString('F1'))/caja vs Cepea`n"
            }
            if ($correlData -and $correlData.Count -gt 0 -and $correlData[0].forecast_4w -and $correlData[0].forecast_4w.Count -ge 4) {
                $fc4 = ($correlData | ForEach-Object { [double]$_.forecast_4w[-1].precio_pred } | Measure-Object -Average).Average
                $fcPct2 = (($fc4 - $oppLast) / $oppLast) * 100
                $sgnF = if ($fcPct2 -ge 0) {"+"} else {""}
                $msg += "*🔮 Forecast 4 sem:* R$ $($fc4.ToString('F2')) ($sgnF$($fcPct2.ToString('F0'))%)`n"
            }
            $climaTotal = 0
            foreach ($r in $climaData) { if ($r.alertas) { $climaTotal += $r.alertas.Count } }
            if ($climaTotal -gt 0) {
                $msg += "*🌤️ Clima:* $climaTotal alerta(s) próx 7d`n"
            } else {
                $msg += "*🌤️ Clima:* estable`n"
            }

            # Comparativa Paraguay si hay data
            if ($null -ne $pyData -and $pyData.precio_caja_pyg -gt 0) {
                $pyKg = $pyData.kg_caja_aprox
                if (-not $pyKg) { $pyKg = 24 }
                $pyUsdKg = ($pyData.precio_caja_pyg / 7500.0) / $pyKg   # TC aprox 7500 PYG/USD
                $brUsdKg = ($oppLast + 0.73) / 5.2                       # +R$0,73 servicios, TC 5.2
                $diffPct = (($pyUsdKg - $brUsdKg) / $brUsdKg) * 100
                $sgnPY = if ($diffPct -ge 0) {"+"} else {""}
                $msg += "*🇵🇾 PY Carape:* PYG $($pyData.precio_caja_pyg.ToString('N0'))/caja (≈USD $($pyUsdKg.ToString('F2'))/kg) · $sgnPY$($diffPct.ToString('F0'))% vs BR`n"
            }

            # Recomendación accionable según score + zona
            $msg += "`n*👉 Sugerencia:* "
            if ($oppScore -ge 4) {
                $msg += "Comprar fuerte — ventana óptima."
            } elseif ($oppScore -ge 2) {
                $msg += "Buena ventana de compra. "
                if ($null -ne $deltaSemPct -and $deltaSemPct -gt 5) { $msg += "Precio recuperando desde mínimo." }
                elseif ($zonaAct -eq "BAJA") { $msg += "Aprovechar zafra alta." }
            } elseif ($oppScore -ge 0) {
                $msg += "Compras normales, sin urgencia."
            } elseif ($oppScore -ge -3) {
                $msg += "Cautela — precio en zona alta. Activar contratos previos."
            } else {
                $msg += "STOP compras spot — momento de descarga."
            }
            # ---- Salud del sistema (agregado 04/09/2026) ----
            # Ecuador estuvo 42 dias sin actualizar y nadie se entero. Ahora el
            # resumen dice siempre en que estado esta el pipeline.
            $lineasSalud = @()
            if ($script:fallosPipeline.Count -gt 0) {
                foreach ($f in $script:fallosPipeline) { $lineasSalud += "⚠️ $($f.paso): $($f.detalle)" }
            }
            $portPath = Join-Path $fuentes "portada.json"
            if (Test-Path $portPath) {
                try {
                    $portJ = Get-Content $portPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($pan in ($portJ.paneles | Where-Object { $_.estado -eq 'atrasada' })) {
                        $lineasSalud += "⚠️ $($pan.titulo): $([math]::Round($pan.dias,0)) días sin actualizar"
                    }
                } catch {}
            }
            if ($lineasSalud.Count -gt 0) {
                $msg += "`n`n*🩺 Salud del sistema*`n" + (($lineasSalud | Select-Object -Unique) -join "`n")
            } else {
                $msg += "`n`n*🩺 Salud:* todo al día ✅"
            }

            $msg += "`n`n_Abrí inicio.html para ver todos los paneles_"
            $alertasFire += @{ tipo='resumen'; msg=$msg }
        }
    }

    # ===== FALLAS DEL PIPELINE (alerta propia, no espera al resumen) =====
    # Antes una falla en el paso 1 mataba el script ANTES de WhatsApp: fallaba
    # justo de la forma que apaga el aviso. Esta alerta existe para que eso no
    # vuelva a pasar en silencio.
    if ($script:fallosPipeline.Count -gt 0 -and $waConfig.alerts.fallas_pipeline -ne $false) {
        $ultFalla = $null
        if ($waState.ContainsKey('ts_fallas')) {
            try { $ultFalla = [DateTime]::Parse($waState['ts_fallas']) } catch {}
        }
        # firma de las fallas actuales: si es la misma de la ultima vez, no repetir
        # antes de 24h (sino spamea todas las corridas mientras el sitio este caido)
        $firma = (($script:fallosPipeline | ForEach-Object { $_.paso }) | Sort-Object) -join '|'
        $firmaPrev = if ($waState.ContainsKey('firma_fallas')) { [string]$waState['firma_fallas'] } else { '' }
        $mandar = $true
        if ($firma -eq $firmaPrev -and $null -ne $ultFalla -and ((Get-Date) - $ultFalla).TotalHours -lt 24) { $mandar = $false }
        if ($mandar) {
            $mf = "🚨 *ALMAR · Falla del pipeline*`n`n"
            foreach ($f in $script:fallosPipeline) {
                $mf += "*$($f.paso)*`n$($f.detalle)`n`n"
            }
            $mf += "_El resto del dashboard se actualizó igual con lo que había._"
            $alertasFire += @{ tipo='fallas'; msg=$mf }
            $waState['firma_fallas'] = $firma
        }
    }

    # ---- Deteccion de corrida atrasada ----
    # Slots del Task Scheduler: viernes 19:00 y miercoles 12:00. Si la PC estuvo
    # apagada el trigger de logon dispara la corrida horas (o dias) despues, y el
    # mensaje llega fuera de hora sin que se note. Lo marcamos en el propio mensaje.
    $slotsProgramados = @(
        @{ dow = [DayOfWeek]::Friday;    hora = 19; min = 0 },
        @{ dow = [DayOfWeek]::Wednesday; hora = 12; min = 0 }
    )
    $ahora = Get-Date
    $slotPrevisto = $null
    foreach ($s in $slotsProgramados) {
        $d = $ahora.Date
        while ($d.DayOfWeek -ne $s.dow) { $d = $d.AddDays(-1) }
        $cand = $d.AddHours($s.hora).AddMinutes($s.min)
        if ($cand -gt $ahora) { $cand = $cand.AddDays(-7) }   # el slot de hoy todavia no llego
        if ($null -eq $slotPrevisto -or $cand -gt $slotPrevisto) { $slotPrevisto = $cand }
    }

    # Si una corrida previa ya cubrio este slot, no hay atraso: es una corrida extra
    # (logon o manual). Solo avisamos cuando el slot quedo sin servir.
    $slotYaServido = $false
    if ($waState.ContainsKey('ts_corrida')) {
        try { $slotYaServido = [DateTime]::Parse($waState['ts_corrida']) -ge $slotPrevisto } catch {}
    }

    $bannerAtraso = ''
    $horasAtraso = ($ahora - $slotPrevisto).TotalHours
    if ($horasAtraso -ge 2 -and -not $slotYaServido) {
        $etiqueta = if ($horasAtraso -ge 48) { "{0:N0} dias" -f ($horasAtraso / 24) }
                    elseif ($horasAtraso -ge 24) { "1 dia {0:N0}h" -f ($horasAtraso - 24) }
                    else { "{0:N0}h" -f $horasAtraso }
        $slotTxt = $slotPrevisto.ToString('dddd HH:mm')
        $bannerAtraso = "⚠️ *ATRASADO $etiqueta* — programado para $slotTxt, la PC estuvo apagada. Los datos son de este envio.`n`n"
        Write-Host "    ATRASO: $etiqueta respecto del slot $($slotPrevisto.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Yellow
    }

    # Enviar respetando silencio
    foreach ($a in $alertasFire) {
        if (Can-Send $a.tipo) {
            Write-Host "    WA -> $($a.tipo):"
            $envio = Send-WA ($bannerAtraso + $a.msg)
            if ($envio.ok) {
                $col = if ($envio.todos) { 'Green' } else { 'Yellow' }
                $det = if ($envio.todos) { '' } else { " - NO le llego a: $($envio.fallidos -join ', ')" }
                Write-Host ("      => {0}/{1} entregados{2}" -f $envio.enviados.Count, $envio.total, $det) -ForegroundColor $col
                $waState["ts_$($a.tipo)"] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                Start-Sleep -Milliseconds 500  # Whapi acepta ~10 msg/s, margen amplio
            } else {
                Write-Host ("      => 0/{0} entregados - alerta '{1}' PERDIDA" -f $envio.total, $a.tipo) -ForegroundColor Red
            }
        } else {
            Write-Host "    (silenciada $($a.tipo) - dentro de ventana)" -ForegroundColor DarkYellow
        }
    }
    if ($alertasFire.Count -eq 0) {
        Write-Host "    Sin alertas para disparar" -ForegroundColor Gray
    }

    # Resumen de fallos de la corrida (lo que antes tapaba el $okAny)
    $waFallosUnicos = @($script:waFallos | Select-Object -Unique)
    if ($waFallosUnicos.Count -gt 0) {
        Write-Host ""
        Write-Host "    !! NUMEROS QUE FALLARON: $($waFallosUnicos -join ', ')" -ForegroundColor Red
        Write-Host "       Chequear que el numero exista en WhatsApp y el formato Whapi" -ForegroundColor Red
        Write-Host "       (Brasil: sin el 9 extra). Queda registrado en state_whatsapp.json." -ForegroundColor Red
    }

    # Actualizar score y zona en state
    $waState['ultimo_score'] = $oppScore
    $waState['ultima_zona']  = $zonaAct
    # Marca que este slot ya fue servido (aunque no haya salido ninguna alerta),
    # asi una corrida posterior por logon no se anuncia como atrasada.
    $waState['ts_corrida']   = $ahora.ToString('yyyy-MM-dd HH:mm:ss')
    # Numeros que fallaron en esta corrida ('' si entraron todos). Sin esto un numero
    # muerto es invisible: la consola no la lee nadie y $okAny lo tapaba.
    $waState['envio_fallidos'] = ($waFallosUnicos -join ',')
    $waState | ConvertTo-Json | Out-File $waStatePath -Encoding UTF8
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "OK actualizado." -ForegroundColor Green
Write-Host "Ultima semana: $($nanica[-1].fecha)" -ForegroundColor Green
Write-Host "Ultimo precio: R$ $($nanica[-1].precio)/kg" -ForegroundColor Green
Write-Host "Zona actual:   $zonaActual" -ForegroundColor Green
Write-Host "Variacion sem: $($deltaSem.ToString('F1'))%" -ForegroundColor Green
Write-Host "Alertas nuevas: $nuevasAlertas" -ForegroundColor Green
Write-Host "Semanas totales: $($nanica.Count)" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Abri index.html en el navegador para ver los cambios." -ForegroundColor Yellow
Write-Host "Log de alertas: $logPath" -ForegroundColor Yellow
