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

$base = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

# --- Lector de .xlsx SIN Excel (headless) ----------------------------------
# El servidor NO tiene Office instalado. Excel via COM obliga a Office + una
# sesion de escritorio abierta; ImportExcel (EPPlus) lee y escribe el xlsx directo.
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
# (17/09/2026: los lectores de xlsx pasaron a ImportExcel/EPPlus, ver mas arriba. Esto
#  queda solo para limpiar instancias huerfanas de Excel en la laptop; en el servidor no hay Excel.)
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
    Invoke-WebRequest -Uri $url -OutFile $xlsxPath -UserAgent $UA_BROWSER -Headers $hdrCepea -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
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
    # Sin Excel COM: ImportExcel (EPPlus). La ultima fila del export de Cepea es el
    # pie "Fonte: Hortifruti/Cepea", por eso el loop llega hasta $total-1.
    $pkg = Open-ExcelPackage -Path $xlsxPath
    $ws  = $pkg.Workbook.Worksheets | Select-Object -First 1
    $total = $ws.Dimension.End.Row
    for ($r = 2; $r -lt $total; $r++) {
        $prod = $ws.Cells[$r,1].Text
        if ($prod -like "Nanica primeira - produtor*") {   # antes "Nanica*": entraba tambien "Nanica primeira - atacado" y duplicaba semanas (09/09/2026)
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
    $ws = $null; $pkg = $null
}
$nanica = @($nanica | Sort-Object fecha -Unique)   # -Unique: una sola fila por semana (09/09/2026)
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
# 2b) Cepea en otras regiones productoras de Nanica  [agregado 09/09/2026]
#     Misma planilla del paso 1 con otro regiao[]. Sirve para ver donde esta
#     mas barata la banana cada semana y planificar cobertura anual.
#     Codigos Cepea (produto=4): 25 Norte SC (paso 1) - 52 Vale do Ribeira (SP)
#     - 24 Norte de Minas (MG) - 6 Bom Jesus da Lapa (BA). Las demas (53 Vale
#     do Sao Francisco, 107 Delfinopolis, 182 Linhares) solo publican Prata y
#     41 es Sao Paulo atacado: no sirven para comparar.
#     Fletes por caja hasta Montevideo: config\cepea_regiones.json (los carga
#     Gonzalo; si faltan, el dashboard compara solo precio en origen; si solo
#     esta el de SC, el resto se estima proporcional a los km).
#     Lee el xlsx directo del zip, sin Excel COM: es chico y el formato es fijo.
#     Nunca corta el pipeline: cada region que falla se anota con Add-Falla.
# ==========================================================================
Write-Host "[2b] Cepea otras regiones (Vale do Ribeira, Norte de Minas, Bom Jesus da Lapa)..." -ForegroundColor Cyan
function Read-CepeaXlsx {
    param([string]$Path, [string]$Producto = 'Nanica primeira - produtor')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $ss = New-Object System.Collections.Generic.List[string]
        $e = $z.GetEntry('xl/sharedStrings.xml')
        if ($e) {
            $sr = New-Object IO.StreamReader($e.Open()); $x = $sr.ReadToEnd(); $sr.Close()
            foreach ($m in [regex]::Matches($x, '<si>(.*?)</si>', 'Singleline')) {
                $ss.Add((@([regex]::Matches($m.Groups[1].Value, '<t[^>]*>(.*?)</t>', 'Singleline') | ForEach-Object { $_.Groups[1].Value }) -join ''))
            }
        }
        $e = $z.GetEntry('xl/worksheets/sheet1.xml')
        if (-not $e) { throw 'el xlsx no tiene sheet1.xml' }
        $sr = New-Object IO.StreamReader($e.Open()); $x = $sr.ReadToEnd(); $sr.Close()
        $x = [regex]::Replace($x, '<row[^>]*/>', '')
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($rm in [regex]::Matches($x, '<row[^>]*>(.*?)</row>', 'Singleline')) {
            $c = @{}
            foreach ($cm in [regex]::Matches($rm.Groups[1].Value, '<c ([^>]*?)(/>|>(.*?)</c>)', 'Singleline')) {
                $attrs = $cm.Groups[1].Value; $inner = $cm.Groups[3].Value
                $col = [regex]::Match($attrs, 'r="([A-Z]+)\d+"').Groups[1].Value
                $t = [regex]::Match($attrs, 't="([^"]+)"').Groups[1].Value
                $v = [regex]::Match($inner, '<v>(.*?)</v>').Groups[1].Value
                if ($t -eq 's' -and $v -ne '') { $v = $ss[[int]$v] }
                elseif ($t -eq 'inlineStr') { $v = [regex]::Match($inner, '<t[^>]*>(.*?)</t>').Groups[1].Value }
                $c[$col] = $v
            }
            if ("$($c['A'])".Trim() -ne $Producto) { continue }
            $p = 0.0
            if (-not [double]::TryParse("$($c['H'])", [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$p)) { continue }
            try { $f = "{0:0000}-{1:00}-{2:00}" -f [int]$c['E'], [int]$c['D'], [int]$c['C'] } catch { continue }
            $out.Add([PSCustomObject]@{ fecha = $f; precio = [math]::Round($p, 2) })
        }
        return @($out | Sort-Object fecha -Unique)
    } finally { $z.Dispose() }
}
try {
    $regCfgPath = Join-Path $base "config\cepea_regiones.json"
    $regDefault = @(
        [ordered]@{ id = 25; nombre = 'Norte de Santa Catarina'; corto = 'Norte SC';          uf = 'SC'; ciudad_ref = 'Corupa / Luiz Alves';    km_ruta_mvd = 1500; flete_camion_brl = $null; flete_caja_brl = $null; base = $true },
        [ordered]@{ id = 52; nombre = 'Vale do Ribeira';         corto = 'Vale do Ribeira';   uf = 'SP'; ciudad_ref = 'Registro / Sete Barras'; km_ruta_mvd = 1800; flete_camion_brl = $null; flete_caja_brl = $null; base = $false },
        [ordered]@{ id = 24; nombre = 'Norte de Minas Gerais';   corto = 'Norte de Minas';    uf = 'MG'; ciudad_ref = 'Janauba / Jaiba';        km_ruta_mvd = 3150; flete_camion_brl = $null; flete_caja_brl = $null; base = $false },
        [ordered]@{ id = 6;  nombre = 'Bom Jesus da Lapa';       corto = 'Bom Jesus da Lapa'; uf = 'BA'; ciudad_ref = 'Bom Jesus da Lapa';      km_ruta_mvd = 3600; flete_camion_brl = $null; flete_caja_brl = $null; base = $false }
    )
    $regCfg = $regDefault; $cfgObj = $null
    if (Test-Path $regCfgPath) {
        try {
            $cfgObj = Get-Content $regCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfgObj.regiones) { $regCfg = @($cfgObj.regiones) }
        } catch { Add-Falla -Paso 'Cepea regiones (config)' -Detalle "config\cepea_regiones.json ilegible: $($_.Exception.Message) - uso los defaults sin fletes" }
    } else {
        try {
            $cfgOut = [ordered]@{
                _nota = 'Fletes de camion completo hasta Montevideo, en reales. Carga flete_camion_brl (o flete_caja_brl) en la region que sepas; si solo cargas Norte SC, el script estima el resto proporcional a km_ruta_mvd (aproximado por ruta, corregilo si tenes el dato). Despues de editar, corre actualizar_precios.ps1.'
                cajas_por_camion = 1008
                regiones = $regDefault
            }
            ($cfgOut | ConvertTo-Json -Depth 5) | Out-File $regCfgPath -Encoding UTF8
            Write-Host "    config\cepea_regiones.json creado con fletes vacios: cargalos vos" -ForegroundColor DarkYellow
        } catch {}
    }
    $cajasCamion = 1008
    if ($cfgObj -and $cfgObj.cajas_por_camion) { $cajasCamion = [int]$cfgObj.cajas_por_camion }

    $regiones = New-Object System.Collections.Generic.List[object]
    foreach ($r in $regCfg) {
        $id = [int]$r.id
        $slug = switch ($id) { 25 { 'SC' } 52 { 'VRibeira' } 24 { 'NMinas' } 6 { 'BJLapa' } default { "R$id" } }
        $serieR = $null; $desact = $false; $edadR = 0
        if ($id -eq 25) {
            $serieR = @($nanica | ForEach-Object { [PSCustomObject]@{ fecha = $_.fecha; precio = $_.precio } })
            $desact = [bool]$cepeaDesactualizado
        } else {
            $xr = Join-Path $fuentes "precios_banana_$slug.xlsx"
            $tmpR = "$xr.tmp"
            $urlR = "https://www.hfbrasil.org.br/br/estatistica/preco/exportar.aspx?produto=4&regiao%5B%5D=$id&periodicidade=diario&ano_inicial=$anoInicial&ano_final=$anoFinal"
            try {
                $hdrR = $HDR_BROWSER.Clone(); $hdrR['Referer'] = 'https://www.hfbrasil.org.br/'
                Invoke-WebRequest -Uri $urlR -OutFile $tmpR -UserAgent $UA_BROWSER -Headers $hdrR -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
                $b2 = [IO.File]::ReadAllBytes($tmpR)
                if ($b2.Length -lt 4 -or $b2[0] -ne 0x50 -or $b2[1] -ne 0x4B) { throw "la respuesta no es un xlsx ($($b2.Length) bytes)" }
                Move-Item -LiteralPath $tmpR -Destination $xr -Force
            } catch {
                if (Test-Path $tmpR) { Remove-Item -LiteralPath $tmpR -Force -ErrorAction SilentlyContinue }
                if (Test-Path $xr) {
                    $edadR = [math]::Round(((Get-Date) - (Get-Item $xr).LastWriteTime).TotalDays, 1)
                    $desact = $true
                    Add-Falla -Paso "Cepea region $($r.corto)" -Detalle "$($_.Exception.Message) - sigo con el cache de hace $edadR dias"
                } else {
                    Add-Falla -Paso "Cepea region $($r.corto)" -Detalle "$($_.Exception.Message) - sin cache, la region queda afuera esta vez"
                    continue
                }
            }
            try { $serieR = Read-CepeaXlsx -Path $xr } catch { Add-Falla -Paso "Cepea region $($r.corto)" -Detalle "no pude leer el xlsx: $($_.Exception.Message)"; continue }
            if (-not $serieR -or $serieR.Count -eq 0) { Add-Falla -Paso "Cepea region $($r.corto)" -Detalle "el xlsx no trae 'Nanica primeira - produtor'"; continue }
        }
        $fleteCaja = $null
        if ($null -ne $r.flete_caja_brl -and "$($r.flete_caja_brl)" -ne '') { $fleteCaja = [math]::Round([double]$r.flete_caja_brl, 2) }
        elseif ($null -ne $r.flete_camion_brl -and "$($r.flete_camion_brl)" -ne '') { $fleteCaja = [math]::Round([double]$r.flete_camion_brl / $cajasCamion, 2) }
        $pmR = [ordered]@{}
        foreach ($mm in 1..12) {
            $vals = @($serieR | Where-Object { [int]$_.fecha.Substring(5, 2) -eq $mm } | ForEach-Object { $_.precio })
            if ($vals.Count -gt 0) { $pmR["$mm"] = [math]::Round(($vals | Measure-Object -Average).Average, 2) }
        }
        $ultR = $serieR[-1]
        $regiones.Add([PSCustomObject]@{
            id = $id; nombre = "$($r.nombre)"; corto = "$($r.corto)"; uf = "$($r.uf)"; ciudad_ref = "$($r.ciudad_ref)"
            km_ruta_mvd = $(if ($r.km_ruta_mvd) { [int]$r.km_ruta_mvd } else { $null })
            base = [bool]$r.base
            producto = 'Nanica primeira - produtor'; unidad = 'R$/kg'
            n = $serieR.Count; desde = $serieR[0].fecha; ultima_semana = $ultR.fecha; ultimo_precio = $ultR.precio
            desactualizado = $desact; cache_dias = $edadR
            flete_caja_brl = $fleteCaja; flete_estimado = $false; flete_nota = "$($r.nota)"
            promedio_mensual = $pmR
            serie = $serieR
        })
    }
    # Fletes estimados por km a partir del de la region base (si esta cargado)
    $bR = @($regiones | Where-Object { $_.base }) | Select-Object -First 1
    if ($bR -and $null -ne $bR.flete_caja_brl -and $bR.km_ruta_mvd) {
        foreach ($rg in $regiones) {
            if ($null -eq $rg.flete_caja_brl -and $rg.km_ruta_mvd) {
                $rg.flete_caja_brl = [math]::Round($bR.flete_caja_brl * $rg.km_ruta_mvd / $bR.km_ruta_mvd, 2)
                $rg.flete_estimado = $true
            }
        }
    }
    $data | Add-Member -MemberType NoteProperty -Name 'regiones' -Value @($regiones.ToArray()) -Force
    $data | Add-Member -MemberType NoteProperty -Name 'regiones_cajas_camion' -Value $cajasCamion -Force
    Write-Host ("    " + (@($regiones | ForEach-Object { "$($_.corto) R$ $($_.ultimo_precio) ($($_.ultima_semana))" }) -join ' | ')) -ForegroundColor Green
} catch {
    Add-Falla -Paso 'Cepea regiones' -Detalle "$($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber)) - sigo sin el bloque de regiones"
}

# ==========================================================================
# 3) Procesar cargas Almar (compras semanales por productor)
# ==========================================================================
Write-Host "[3/6] Procesando cargas Almar 2026..." -ForegroundColor Cyan
$cargasFile = Join-Path $fuentes "cargas 2026.xlsx"
$fichasFile = Join-Path $fuentes "productores.xlsx"   # fichas de productores (hoja 'productores'), la llena el user
$almarFichas  = @{}   # productor canonico en minusculas -> ficha (ordered)
$almarAliases = @{}   # alias / nombre en minusculas -> productor canonico (columna Alias, separada por ;)
$KG_CAJA_NETO   = 22   # banana adentro de la caja
$KG_CAJA_BRUTO  = 26   # caja + banana
$SERVICIOS_CAJA = 16   # R$/caja - envalado + paletizado + flete interno (a sumar al precio Cepea del cacho)

# Alias de transportistas. La planilla de cargas dice "Nilton" y el Plan de Cargas dice "FG":
# es la MISMA empresa (confirmado por Gonzalo el 08/09/2026). Se unifica en el paso 3 (cargas 2026,
# fichas y agregados) y en el 5h (Plan de Cargas) con este unico mapa. Agregar aca otros apodos.
$TRANSP_ALIAS = @{ 'nilton' = 'FG (Nilton)'; 'fg' = 'FG (Nilton)'; 'f.g.' = 'FG (Nilton)'; 'f g' = 'FG (Nilton)' }
function Get-TransportistaCanon { param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    $lim = ([regex]::Replace($s, '\s+', ' ')).Trim()
    $k = $lim.ToLower()
    if ($TRANSP_ALIAS.ContainsKey($k)) { return $TRANSP_ALIAS[$k] }
    return $lim
}

$almarRecords = @()
if (Test-Path $cargasFile) {
    $YEAR_CARGAS = 2026
    $pkgC = $null
    $edAplicadasHasta = ''
    try {
        # ---- 3a) Ediciones hechas desde la ficha del dashboard: fuentes\productores_ediciones.json  [10/09/2026] ----
        #      El boton "Editar datos de la ficha" (index_brasil / index) escribe ese JSON via File System Access API.
        #      Aca se vuelca a productores.xlsx (misma fila del productor; columnas por encabezado) y el JSON se
        #      archiva en archivo\. Si el xlsx esta abierto en Excel, queda para la proxima corrida.
        #      state_ediciones.json guarda hasta que timestamp se aplico: el dashboard descarta lo anterior.
        $edPath = Join-Path $fuentes 'productores_ediciones.json'
        $edStatePath = Join-Path $fuentes 'state_ediciones.json'
        try { if (Test-Path $edStatePath) { $edAplicadasHasta = [string](Get-Content $edStatePath -Raw -Encoding UTF8 | ConvertFrom-Json).aplicadas_hasta } } catch {}
        if (Test-Path $edPath) {
            $pkgE = $null
            try {
                $edObj = Get-Content $edPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $edItems = @($edObj.psobject.properties | ForEach-Object { $_.Value } | Where-Object { $_ -and $_.campos -and $_.productor })
                if ($edItems.Count -eq 0) { throw 'el archivo no trae ediciones' }
                if (Test-Path (Join-Path $fuentes '~$productores.xlsx')) { throw 'productores.xlsx esta abierto en Excel' }
                $pkgE = Open-ExcelPackage -Path $fichasFile
                $wsE = $pkgE.Workbook.Worksheets['productores']
                if ($null -eq $wsE -or $null -eq $wsE.Dimension) { throw 'productores.xlsx no tiene la hoja productores (o esta vacia)' }
                $ncE = $wsE.Dimension.End.Column; $nrE = $wsE.Dimension.End.Row
                $hdrE = @{}; for ($c = 1; $c -le $ncE; $c++) { $h = [string]$wsE.Cells[1, $c].Value; if ($h) { $hdrE[$h.Trim().ToLower()] = $c } }
                if (-not $hdrE.ContainsKey('productor')) { throw 'la hoja productores no tiene columna Productor' }
                $rowE = @{}; for ($r = 2; $r -le $nrE; $r++) { $n = ([string]$wsE.Cells[$r, $hdrE['productor']].Value).Trim().ToLower(); if ($n) { $rowE[$n] = $r } }
                $nAp = 0; $maxTs = $edAplicadasHasta; $detalle = @()
                foreach ($it in $edItems) {
                    $nom = ([string]$it.productor).Trim(); $key = $nom.ToLower()
                    if (-not $rowE.ContainsKey($key)) {
                        $nrE++; $wsE.Cells[$nrE, $hdrE['productor']].Value = $nom; $rowE[$key] = $nrE
                        Write-Host "    (ficha nueva) $nom agregado a productores.xlsx" -ForegroundColor DarkYellow
                    }
                    $r = $rowE[$key]; $cambios = @()
                    foreach ($prop in $it.campos.psobject.properties) {
                        $k = $prop.Name.ToLower(); $v = $prop.Value
                        if ($k -eq 'productor' -or $k -eq '_pendiente') { continue }
                        if (-not $hdrE.ContainsKey($k)) { $ncE++; $wsE.Cells[1, $ncE].Value = $prop.Name; $hdrE[$k] = $ncE }
                        $cel = $wsE.Cells[$r, $hdrE[$k]]
                        if ($k -eq 'notas') {
                            $prev = [string]$cel.Value; $sv = [string]$v
                            if ($sv -and $prev.IndexOf($sv) -lt 0) { $cel.Value = $(if ($prev) { "$prev | $sv" } else { $sv }); $cambios += 'notas' }
                        } elseif ($v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [single]) {
                            $cel.Value = [double]$v; $cambios += $k
                        } else {
                            if ($k -eq 'contacto') { $cel.Style.Numberformat.Format = '@' }
                            $cel.Value = [string]$v; $cambios += $k
                        }
                    }
                    if ([string]$it.ts -gt $maxTs) { $maxTs = [string]$it.ts }
                    $nAp++; $detalle += "$nom ($($cambios -join ', '))"
                }
                Close-ExcelPackage $pkgE; $pkgE = $null   # Close-ExcelPackage sin -NoSave = guardar
                $edAplicadasHasta = $maxTs
                $arch = Join-Path $base ("archivo\productores_ediciones_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".json")
                Move-Item -LiteralPath $edPath -Destination $arch -Force
                (@{ aplicadas_hasta = $edAplicadasHasta; ultima = (Get-Date -Format 'yyyy-MM-dd HH:mm'); n = $nAp } | ConvertTo-Json -Compress) | Out-File $edStatePath -Encoding UTF8
                Write-Host "    Ediciones desde el dashboard volcadas a productores.xlsx: $($detalle -join ' | ')" -ForegroundColor Green
            } catch {
                if ($pkgE) { try { Close-ExcelPackage $pkgE -NoSave } catch {}; $pkgE = $null }
                Add-Falla -Paso 'Fichas (ediciones desde el dashboard)' -Detalle "$($_.Exception.Message) - quedan en productores_ediciones.json para la proxima corrida"
            }
        }
        # ---- Fichas de productores: fuentes\productores.xlsx, hoja 'productores' (encabezados = claves) ----
        if (Test-Path $fichasFile) {
            $pkgF = $null
            try {
                $pkgF = Open-ExcelPackage -Path $fichasFile
                $wsF = $pkgF.Workbook.Worksheets['productores']
                if ($null -ne $wsF -and $null -ne $wsF.Dimension) {
                    $nR = $wsF.Dimension.End.Row; $nC = $wsF.Dimension.End.Column
                    $hdrF = @(); for ($c = 1; $c -le $nC; $c++) { $hdrF += (([string]$wsF.Cells[1,$c].Value).Trim().ToLower()) }
                    for ($r = 2; $r -le $nR; $r++) {
                        $ficha = [ordered]@{}
                        for ($c = 1; $c -le $nC; $c++) {
                            if (-not $hdrF[$c-1]) { continue }
                            $v = $wsF.Cells[$r,$c].Value
                            $ficha[$hdrF[$c-1]] = if ($null -eq $v) { '' } elseif ($v -is [double]) { $v } elseif ($v -is [DateTime]) { $v.ToString('yyyy-MM-dd') } else { ([string]$v).Trim() }
                        }
                        $canon = ([string]$ficha['productor']).Trim()
                        if (-not $canon) { continue }
                        $ficha.Remove('cargas_2026_ref')   # solo referencia visual, no es dato
                        $almarFichas[$canon.ToLower()] = $ficha
                        $almarAliases[$canon.ToLower()] = $canon
                        foreach ($al in (([string]$ficha['alias']) -split ';')) { $al = $al.Trim().ToLower(); if ($al) { $almarAliases[$al] = $canon } }
                    }
                }
                Write-Host "    Fichas de productores: $($almarFichas.Count) | alias reconocidos: $($almarAliases.Count)" -ForegroundColor Green
            } catch {
                Write-Host "    (aviso) no pude leer productores.xlsx: $($_.Exception.Message)" -ForegroundColor DarkYellow
            } finally {
                if ($pkgF) { try { Close-ExcelPackage $pkgF -NoSave } catch {} }; $pkgF = $null
            }
        } else {
            Write-Host "    (sin fichas) falta fuentes\productores.xlsx" -ForegroundColor DarkYellow
        }

        $pkgC = Open-ExcelPackage -Path $cargasFile
        $hojaIdx = 0
        foreach ($wsC in $pkgC.Workbook.Worksheets) {
          try {
            if ($wsC.Name -eq 'madre') { continue }
            $hojaIdx++
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
                # alias de productores.xlsx -> nombre canonico (typos, variantes)
                $kB = $colB.ToLower().Trim()
                if ($almarAliases.ContainsKey($kB)) { $colB = $almarAliases[$kB] }
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
                    transportista = (Get-TransportistaCanon $colE)
                    despachante   = $colF
                    mes           = $wsC.Name
                    mes_orden     = $hojaIdx
                }
            }
          }
          finally {
            # EPPlus: no hay referencias COM que soltar por hoja.
          }
        }
    }
    finally {
        if ($pkgC) { Close-ExcelPackage $pkgC -NoSave }
        $pkgC = $null
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

# Ultima fecha global y corte de 4 semanas (para marcar "activo" por productor)
$ultimaFechaAlmar = ($almarRecords | Where-Object { $_.fecha } | ForEach-Object { $_.fecha } | Sort-Object | Select-Object -Last 1)
$corte4sem = if ($ultimaFechaAlmar) { ([DateTime]::ParseExact($ultimaFechaAlmar, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).AddDays(-27).ToString('yyyy-MM-dd') } else { $null }

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
    $fechasP = @($_.Group | Where-Object { $_.fecha } | ForEach-Object { $_.fecha } | Sort-Object)
    $ult4 = 0
    if ($corte4sem) { $ult4 = ($_.Group | Where-Object { $_.fecha -and $_.fecha -ge $corte4sem } | Measure-Object cargas -Sum).Sum; if (-not $ult4) { $ult4 = 0 } }
    # detalle para la ficha: camiones por mes, transportistas y despachantes usados
    $porMesP = @($_.Group | Where-Object { $_.mes } | Group-Object mes_orden | Sort-Object { [int]$_.Name } | ForEach-Object {
        $sc = ($_.Group | Measure-Object cargas -Sum).Sum
        $sv = ($_.Group | ForEach-Object { $_.precio * $_.cargas } | Measure-Object -Sum).Sum
        [PSCustomObject]@{ mes = $_.Group[0].mes; cargas = [math]::Round($sc, 1); precio_avg_caja = [math]::Round($(if ($sc -gt 0) { $sv / $sc } else { 0 }), 2) }
    })
    $transP = @($_.Group | Where-Object { $_.transportista } | Group-Object { ($_.transportista).ToLower().Trim() } | Sort-Object Count -Descending | ForEach-Object {
        [PSCustomObject]@{ nombre = $_.Group[0].transportista; cargas = [math]::Round(($_.Group | Measure-Object cargas -Sum).Sum, 1) }
    })
    $despP = @($_.Group | Where-Object { $_.despachante } | Group-Object { ($_.despachante).ToLower().Trim() } | Sort-Object Count -Descending | ForEach-Object {
        [PSCustomObject]@{ nombre = $_.Group[0].despachante; cargas = [math]::Round(($_.Group | Measure-Object cargas -Sum).Sum, 1) }
    })
    $fichaP = if ($almarFichas.ContainsKey($_.Name)) { $almarFichas[$_.Name] } else { $null }
    $almarProductores += [PSCustomObject]@{
        productor       = $nombre
        cargas          = [math]::Round($sumCargas, 1)
        precio_avg_caja = [math]::Round($avgPrecio, 2)
        precio_avg_kg   = [math]::Round($avgPrecio / $KG_CAJA_NETO, 3)
        precio_min      = $minP
        precio_max      = $maxP
        n_operaciones   = $_.Count
        primera_fecha   = if ($fechasP.Count) { $fechasP[0] } else { $null }
        ultima_fecha    = if ($fechasP.Count) { $fechasP[-1] } else { $null }
        cargas_ult4sem  = [math]::Round($ult4, 1)
        por_mes         = $porMesP
        transportistas  = $transP
        despachantes    = $despP
        ficha           = $fichaP
    }
}
$almarProductores = $almarProductores | Sort-Object cargas -Descending

# Agregados por mes (una hoja de la planilla = un mes; avg ponderado por cargas)
$almarMeses = @()
$almarRecords | Where-Object { $_.mes } | Group-Object mes_orden | Sort-Object { [int]$_.Name } | ForEach-Object {
    $sumCargas = ($_.Group | Measure-Object cargas -Sum).Sum
    $sumValor  = ($_.Group | ForEach-Object { $_.precio * $_.cargas } | Measure-Object -Sum).Sum
    $avgCaja   = if ($sumCargas -gt 0) { $sumValor / $sumCargas } else { 0 }
    $fechasM   = @($_.Group | Where-Object { $_.fecha } | ForEach-Object { $_.fecha } | Sort-Object)
    $almarMeses += [PSCustomObject]@{
        mes             = $_.Group[0].mes
        orden           = [int]$_.Name
        cargas          = [math]::Round($sumCargas, 1)
        precio_avg_caja = [math]::Round($avgCaja, 2)
        precio_avg_kg   = [math]::Round($avgCaja / $KG_CAJA_NETO, 3)
        n_operaciones   = $_.Count
        n_productores   = @($_.Group | ForEach-Object { ($_.productor).ToLower().Trim() } | Select-Object -Unique).Count
        primera_semana  = if ($fechasM.Count) { $fechasM[0] } else { $null }
        ultima_semana   = if ($fechasM.Count) { $fechasM[-1] } else { $null }
    }
}

# Agregados por despachante y transportista (columnas F y E de la planilla): cargas y participacion.
# Alimentan las tablas "Despachantes y transportistas" de index_brasil (antes estaban escritas a mano, foto de mayo/2026).
function Get-AlmarAgg { param([string]$prop)
    $out = @()
    $almarRecords | Where-Object { $_.$prop -and (([string]$_.$prop) -replace '\s','') -ne '' -and ([string]$_.$prop) -notmatch '^(0|xx|-)$' } |
        Group-Object { (([string]$_.$prop) -replace '\s+',' ').Trim().ToLower() } | ForEach-Object {
            $n = (([string]$_.Group[0].$prop) -replace '\s+',' ').Trim()
            if ($n.Length -gt 1 -and $n -ceq $n.ToUpper()) { $n = $n.Substring(0,1) + $n.Substring(1).ToLower() }
            $s = ($_.Group | Measure-Object cargas -Sum).Sum; if (-not $s) { $s = 0 }
            $out += [PSCustomObject]@{ nombre = $n; cargas = [math]::Round($s, 1); n_operaciones = $_.Count }
        }
    return @($out | Sort-Object cargas -Descending)
}
$almarDespachantes   = Get-AlmarAgg 'despachante'
$almarTransportistas = Get-AlmarAgg 'transportista'

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
    meses           = $almarMeses
    ultima_fecha    = $ultimaFechaAlmar
    n_operaciones   = @($almarRecords).Count
    despachantes    = $almarDespachantes
    transportistas  = $almarTransportistas
    n_fichas        = $almarFichas.Count
    fichas_archivo  = 'fuentes\productores.xlsx'
    ediciones_aplicadas_hasta = $edAplicadasHasta   # el dashboard descarta ediciones locales anteriores a esto (10/09/2026)
})

Write-Host "    Semanas con datos: $($almarSemanas.Count) | Productores: $($almarProductores.Count) | Cargas YTD: $($data.almar.total_cargas)" -ForegroundColor Green

# ==========================================================================
# 3b) Plan de Cargas desde Aloha (API del ERP)  [agregado 17/09/2026]
# --------------------------------------------------------------------------
# La planilla cargas 2026.xlsx tiene el PRECIO por carga pero se carga a mano
# y quedo vieja (el resumen del 16/09 decia "hace 6 sem sin cargas nuevas").
# El plan de cargas REAL (que camion viene, cuando, cuantas cajas, en que
# estado) vive en Aloha, asi que se lee de ahi: login con un usuario de solo
# lectura (config\aloha.json, NO va al repo) + GET /plan-cargas. Aloha no se
# toca: solo se le piden datos. La respuesta se cachea en
# fuentes\plan_cargas_aloha.json para que una caida de la API no deje el
# resumen sin el bloque. SIN precio: eso sigue saliendo de la planilla (3).
# ==========================================================================
Write-Host "[3b] Plan de Cargas (Aloha)..." -ForegroundColor Cyan
$alohaCfgPath  = Join-Path $base "config\aloha.json"
$planCachePath = Join-Path $fuentes "plan_cargas_aloha.json"
$planCargas    = $null     # { generado_en; origen='aloha'|'cache'; fuente; cargas=@() }
$alohaCfg      = $null
if (Test-Path $alohaCfgPath) {
    try { $alohaCfg = Get-Content $alohaCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Add-Falla -Paso 'Plan de Cargas (config)' -Detalle "config\aloha.json ilegible: $($_.Exception.Message)" }
}

function Get-PlanCargasAloha {
    # Login -> token JWT -> lista del plan -> logout. Tira si algo falla; el que
    # llama decide si cae al cache.
    param($cfg)
    $apiBase = ([string]$cfg.url).TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($apiBase)) { throw "falta 'url' en config\aloha.json" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $loginJson  = @{ username = [string]$cfg.username; password = [string]$cfg.password } | ConvertTo-Json -Compress
    $loginBytes = [System.Text.Encoding]::UTF8.GetBytes($loginJson)
    $login = Invoke-RestMethod -Uri "$apiBase/auth/login" -Method Post -Body $loginBytes -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 -UserAgent "poronga/1.0"
    if ($login.debe_cambiar_password) {
        throw "el usuario '$($cfg.username)' todavia tiene la clave inicial del admin: entrar una vez a Aloha con ese usuario y cambiarla"
    }
    if ([string]::IsNullOrWhiteSpace([string]$login.token)) { throw "login sin token (usuario/clave incorrectos?)" }
    $hdr = @{ Authorization = "Bearer $($login.token)" }
    $qs = @('limit=5000')
    if (-not [string]::IsNullOrWhiteSpace([string]$cfg.fuente)) { $qs += "fuente=$([uri]::EscapeDataString([string]$cfg.fuente))" }
    try {
        $rows = Invoke-RestMethod -Uri "$apiBase/plan-cargas?$($qs -join '&')" -Headers $hdr -TimeoutSec 60 -UserAgent "poronga/1.0"
    } finally {
        try { Invoke-RestMethod -Uri "$apiBase/auth/logout" -Method Post -Headers $hdr -TimeoutSec 15 -UserAgent "poronga/1.0" | Out-Null } catch {}
    }
    return @($rows)
}

if ($null -eq $alohaCfg -or -not $alohaCfg.enabled) {
    Write-Host "    Plan de Cargas deshabilitado (config/aloha.json)" -ForegroundColor DarkYellow
} elseif ([string]::IsNullOrWhiteSpace([string]$alohaCfg.username) -or [string]::IsNullOrWhiteSpace([string]$alohaCfg.password)) {
    Write-Host "    Falta username/password en config/aloha.json - completar para activar" -ForegroundColor DarkYellow
} else {
    try {
        $filasPlan = Get-PlanCargasAloha -cfg $alohaCfg
        $planCargas = [PSCustomObject]@{
            generado_en = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            origen      = 'aloha'
            fuente      = [string]$alohaCfg.fuente
            cargas      = $filasPlan
        }
        $planCargas | ConvertTo-Json -Depth 6 -Compress | Out-File -FilePath $planCachePath -Encoding UTF8
        Write-Host "    OK: $($filasPlan.Count) cargas del plan (fuente '$($alohaCfg.fuente)')" -ForegroundColor Green
    } catch {
        $detPlan = $_.Exception.Message
        if (Test-Path $planCachePath) {
            try {
                $planCargas = Get-Content $planCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $planCargas.origen = 'cache'
                $edadPlan = [math]::Round(((Get-Date) - [DateTime]::Parse($planCargas.generado_en)).TotalDays, 1)
                Add-Falla -Paso 'Plan de Cargas (Aloha)' -Detalle "$detPlan - sigo con el cache de hace $edadPlan dias"
                Write-Host "    FALLO ($detPlan) - uso cache de hace $edadPlan dias" -ForegroundColor Yellow
            } catch {
                $planCargas = $null
                Add-Falla -Paso 'Plan de Cargas (Aloha)' -Detalle "$detPlan - y el cache no se pudo leer"
            }
        } else {
            Add-Falla -Paso 'Plan de Cargas (Aloha)' -Detalle "$detPlan - y no hay cache local"
            Write-Host "    FALLO ($detPlan) - sin cache" -ForegroundColor Red
        }
    }
}

# Agregados del plan. Estados de Aloha:
#   Solicitado, Confirmado, Cargado, Mar, Puerto  -> todavia no llego a frontera
#   Frontera, Liberado                             -> en camino (llega en dias)
#   Arribado                                       -> en el deposito sin descargar
#   Descargado, Cancelado, Destruida               -> terminados
$PLAN_PENDIENTES = @('Solicitado','Confirmado','Cargado','Mar','Puerto','Frontera','Liberado','Arribado')
$PLAN_EN_CAMINO  = @('Frontera','Liberado')
$PLAN_POR_VENIR  = @('Solicitado','Confirmado','Cargado','Mar','Puerto')
function Get-CajasPlan { param($rows) [int](($rows | ForEach-Object { if ($_.cajas_mic) { [int]$_.cajas_mic } else { 0 } } | Measure-Object -Sum).Sum) }
function Get-ProductoresPlan { param($rows) @($rows | ForEach-Object { ([string]$_.productor).Trim() } | Where-Object { $_ } | Sort-Object -Unique) }
function Get-ConteoStatus { param($rows) $h = [ordered]@{}; foreach ($r in $rows) { $s = [string]$r.status; if (-not $h.Contains($s)) { $h[$s] = 0 }; $h[$s]++ }; $h }

$planSemanas = @(); $planResumen = $null
if ($null -ne $planCargas -and @($planCargas.cargas).Count -gt 0) {
    $cargasPlan = @($planCargas.cargas)
    # Por semana de la FECHA DE CARGA (lunes como clave). carga_semana es texto
    # libre de la planilla y no sirve para ordenar. Las canceladas/destruidas
    # no cuentan: nunca fueron ni van a ser un camion.
    $PLAN_ANULADAS = @('Cancelado','Destruida')
    $porSemana = @{}
    foreach ($c in $cargasPlan) {
        if ($PLAN_ANULADAS -contains [string]$c.status) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$c.fecha_carga)) { continue }
        try { $fc = [DateTime]::Parse([string]$c.fecha_carga) } catch { continue }
        $lunes = $fc.Date.AddDays(-((([int]$fc.DayOfWeek) + 6) % 7))
        $k = $lunes.ToString('yyyy-MM-dd')
        if (-not $porSemana.ContainsKey($k)) { $porSemana[$k] = @() }
        $porSemana[$k] += $c
    }
    foreach ($k in ($porSemana.Keys | Sort-Object)) {
        $g = @($porSemana[$k])
        $planSemanas += [PSCustomObject]@{
            semana_lunes = $k
            camiones     = $g.Count
            cajas        = Get-CajasPlan $g
            cajas_desc   = [int](($g | ForEach-Object { if ($_.cajas_desc) { [int]$_.cajas_desc } else { 0 } } | Measure-Object -Sum).Sum)
            pallets      = [int](($g | ForEach-Object { if ($_.cant_pallet) { [int]$_.cant_pallet } else { 0 } } | Measure-Object -Sum).Sum)
            productores  = Get-ProductoresPlan $g
            por_status   = Get-ConteoStatus $g
            pendientes   = @($g | Where-Object { $PLAN_PENDIENTES -contains [string]$_.status }).Count
        }
    }
    $hoyPlan   = (Get-Date).Date
    $lunesHoy  = $hoyPlan.AddDays(-((([int]$hoyPlan.DayOfWeek) + 6) % 7)).ToString('yyyy-MM-dd')
    $enCamino  = @($cargasPlan | Where-Object { $PLAN_EN_CAMINO -contains [string]$_.status })
    $porVenir  = @($cargasPlan | Where-Object { $PLAN_POR_VENIR -contains [string]$_.status })
    $arribados = @($cargasPlan | Where-Object { [string]$_.status -eq 'Arribado' })
    $descargadas = @($cargasPlan | Where-Object { [string]$_.status -eq 'Descargado' -and -not [string]::IsNullOrWhiteSpace([string]$_.fecha_descarga) })
    $ultimaDesc = $null
    if ($descargadas.Count -gt 0) { $ultimaDesc = $descargadas | Sort-Object { [DateTime]::Parse([string]$_.fecha_descarga) } | Select-Object -Last 1 }
    $ultimaDescObj = $null
    if ($ultimaDesc) {
        $udCajas = 0
        if ($ultimaDesc.cajas_desc) { $udCajas = [int]$ultimaDesc.cajas_desc } elseif ($ultimaDesc.cajas_mic) { $udCajas = [int]$ultimaDesc.cajas_mic }
        $ultimaDescObj = [PSCustomObject]@{ fecha = [string]$ultimaDesc.fecha_descarga; productor = ([string]$ultimaDesc.productor).Trim(); cajas = $udCajas }
    }
    $semActual = $planSemanas | Where-Object { $_.semana_lunes -eq $lunesHoy } | Select-Object -First 1
    $planResumen = [PSCustomObject]@{
        origen          = $planCargas.origen
        generado_en     = $planCargas.generado_en
        fuente          = $planCargas.fuente
        total           = $cargasPlan.Count
        por_status      = Get-ConteoStatus $cargasPlan
        semana_actual   = $semActual
        en_camino       = [PSCustomObject]@{ camiones = $enCamino.Count;  cajas = (Get-CajasPlan $enCamino);  por_status = (Get-ConteoStatus $enCamino);  productores = (Get-ProductoresPlan $enCamino) }
        por_venir       = [PSCustomObject]@{ camiones = $porVenir.Count;  cajas = (Get-CajasPlan $porVenir);  por_status = (Get-ConteoStatus $porVenir);  productores = (Get-ProductoresPlan $porVenir) }
        arribados       = [PSCustomObject]@{ camiones = $arribados.Count; cajas = (Get-CajasPlan $arribados) }
        ultima_descarga = $ultimaDescObj
        semanas         = $planSemanas
    }
    $data | Add-Member -MemberType NoteProperty -Name 'plan_cargas' -Value $planResumen
    Write-Host "    Plan: $($cargasPlan.Count) cargas | en camino $($enCamino.Count) | por venir $($porVenir.Count) | arribados $($arribados.Count) | semanas $($planSemanas.Count)" -ForegroundColor Green
}

# ==========================================================================
# 3.5) Bajar clima de zonas productoras (Open-Meteo, API gratuita sin key)
# ==========================================================================
Write-Host "[clima] Bajando clima de zonas productoras..." -ForegroundColor Cyan

$regionesClima = @(
    @{ id="br_luizalves";  pais="Brasil";   ciudad="Luiz Alves";          bandera="BR"; lat=-26.72; lon=-48.93 },
    @{ id="br_guaramirim"; pais="Brasil";   ciudad="Guaramirim";          bandera="BR"; lat=-26.47; lon=-49.00 },
    @{ id="py_tembiapora"; pais="Paraguay"; ciudad="Tembiapora";          bandera="PY"; lat=-24.92; lon=-55.98 },
    @{ id="py_paraguay_ms"; pais="Paraguay"; ciudad="Paraguay MS (Caaguazu)"; bandera="PY"; lat=-25.345; lon=-55.480 },   # bananal visitado el 11/09/2026, plus code 5866MG49+3V, 69 km de Tembiapora
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
    $htmlPy = (Invoke-WebRequest -UseBasicParsing -Uri 'https://preciosdelagro.com/producto/39-banana-carape' -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' -TimeoutSec 30 -ErrorAction Stop).Content

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
# Lee TODOS los `detalle_UYimport_*.xlsx` de `penta\` y de
# `archivo\importaciones_uy\` (extractos de aduana con Importador y Fecha por
# fila; 2024, 2025 y 2026), los fusiona deduplicando, y arma:
#   - `fuentes\mercado_uy.json` -> index_mercado.html (multi-origen, ano en curso)
#   - `fuentes\mercado_br.json` -> index_brasil.html (Brasil solo, ano contra ano;
#     bloque 5c-BR mas abajo, agregado 08/09/2026)
#
# Por que existe: las secciones de mercado de index/brasil/PY-BO estaban
# hardcodeadas a mano con datos ene-11may/2026 y quedaron falsas (decian
# "Paraguay se contrajo a 1/4" cuando Paraguay se multiplico por 7 desde mayo).
# Estas paginas se regeneran solas y no se pueden desactualizar.
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
    # Lee la hoja "Detalle" de un extracto Penta sin Excel COM.
    # Las columnas se ubican POR NOMBRE DE ENCABEZADO porque Penta exporta dos
    # layouts distintos (verificado 08/09/2026):
    #   - largo, 35 col. (archivo\importaciones_uy\, extractos de may/2026):
    #     DUA | Fecha | ... | U$S FOB | U$S VNA | ... | Kgs. Netos | Kgs. Brutos | Importador | ...
    #   - corto, 7 col. (penta\, extractos de sep/2026):
    #     Fecha | Pais de Origen | Kgs. Netos | Kgs. Brutos | Descripcion | Importador | U$S VNA
    # El valor es U$S VNA en los dos (en el largo FOB y VNA coinciden fila a fila).
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    $ent = @{}
    foreach ($e in $zip.Entries) {
        $sr = New-Object System.IO.StreamReader($e.Open())
        $ent[$e.FullName] = $sr.ReadToEnd(); $sr.Close()
    }
    $zip.Dispose()
    $sst = New-Object System.Collections.Generic.List[string]
    if ($ent.ContainsKey('xl/sharedStrings.xml')) {
        foreach ($m in [regex]::Matches($ent['xl/sharedStrings.xml'],'(?s)<si>(.*?)</si>')) {
            $sst.Add([System.Net.WebUtility]::HtmlDecode((-join ([regex]::Matches($m.Groups[1].Value,'(?s)<t[^>]*>(.*?)</t>') | ForEach-Object { $_.Groups[1].Value }))))
        }
    }
    $tgt = $null
    foreach ($m in [regex]::Matches($ent['xl/workbook.xml'],'<sheet[^>]*name="([^"]+)"[^>]*r:id="(rId\d+)"')) {
        if ($m.Groups[1].Value -eq 'Detalle') {
            $rm = [regex]::Match($ent['xl/_rels/workbook.xml.rels'],'Id="'+$m.Groups[2].Value+'"[^>]*Target="([^"]+)"')
            $tgt = ($rm.Groups[1].Value -replace '^/?(xl/)?','')
        }
    }
    if (-not $tgt -or -not $ent.ContainsKey("xl/$tgt")) { return ,@() }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $filas = New-Object System.Collections.Generic.List[object]
    $col = $null      # encabezado -> indice de columna; se arma con la primera fila
    $ixF = $null; $ixO = $null; $ixK = $null; $ixB = $null; $ixI = $null; $ixV = $null
    foreach ($fm in [regex]::Matches($ent["xl/$tgt"],'(?s)<row[^>]*>(.*?)</row>')) {
        $cel = @{}
        # (?:/>|>(.*?)</c>) : una celda vacia viene auto-cerrada (<c r="Q5" s="1"/>) y sin esto se tragaba la celda siguiente
        foreach ($cm in [regex]::Matches($fm.Groups[1].Value,'(?s)<c r="([A-Z]+)\d+"([^>]*?)(?:/>|>(.*?)</c>)')) {
            $ci = 0; foreach ($ch in $cm.Groups[1].Value.ToCharArray()) { $ci = $ci*26 + ([int][char]$ch - 64) }
            $at = $cm.Groups[2].Value; $inn = $cm.Groups[3].Value
            $vm = [regex]::Match($inn,'(?s)<v>(.*?)</v>')
            $val = if ($vm.Success) { $vm.Groups[1].Value } else { -join ([regex]::Matches($inn,'(?s)<t[^>]*>(.*?)</t>') | ForEach-Object { $_.Groups[1].Value }) }
            if ($at -match 't="s"' -and $val -match '^\d+$') { $val = $sst[[int]$val] }
            $cel[$ci] = [System.Net.WebUtility]::HtmlDecode($val)
        }
        if ($null -eq $col) {
            $col = @{}
            foreach ($k in $cel.Keys) { $col[(($cel[$k] -replace '\s+',' ').Trim())] = $k }
            $buscar = { param($rx) foreach ($h in $col.Keys) { if ($h -match $rx) { return $col[$h] } } return $null }
            $ixF = & $buscar '^Fecha$';        $ixO = & $buscar '^Pa.s de Origen$'
            $ixK = & $buscar '^Kgs\. Netos$';  $ixB = & $buscar '^Kgs\. Brutos$'
            $ixI = & $buscar '^Importador$';   $ixV = & $buscar '^U\$S VNA$'
            if ($null -eq $ixV) { $ixV = & $buscar '^U\$S FOB$' }
            if ($null -eq $ixF -or $null -eq $ixO -or $null -eq $ixK -or $null -eq $ixI -or $null -eq $ixV) {
                Write-Host "    (aviso) $(Split-Path $Path -Leaf): no reconozco las columnas (Fecha / Pais de Origen / Kgs. Netos / Importador / U`$S VNA). Encabezados: $($col.Keys -join ' | ')" -ForegroundColor DarkYellow
                return ,@()
            }
            continue
        }
        if (-not $cel.ContainsKey($ixF) -or [string]::IsNullOrWhiteSpace($cel[$ixF])) { continue }
        try {
            $fecha = [DateTime]::FromOADate([double]::Parse($cel[$ixF],$inv))
            $kgB = 0.0
            if ($null -ne $ixB -and $cel.ContainsKey($ixB)) { $kgB = [double]::Parse($cel[$ixB],$inv) }
            $filas.Add([PSCustomObject]@{
                fecha      = $fecha.ToString('yyyy-MM-dd')
                anio       = $fecha.Year
                mes        = $fecha.Month
                dia        = $fecha.Day
                origen     = (($cel[$ixO] -replace '\s+',' ').Trim())
                kg         = [double]::Parse($cel[$ixK],$inv)
                kgBruto    = $kgB
                importador = (($cel[$ixI] -replace '\s+',' ').Trim())
                fob        = [double]::Parse($cel[$ixV],$inv)
            })
        } catch { }
    }
    return ,$filas.ToArray()
}

$mercadoHtml = Join-Path $base "index_mercado.html"
# Los extractos viven en dos carpetas: penta\ (los nuevos, ene-ago/2026) y
# archivo\importaciones_uy\ (2024, 2025 y ene-11may/2026, todos con importador).
# Se leen TODOS y se deduplican por clave, asi que los solapados (mismo periodo
# bajado dos veces, o "solo Brasil" adentro de "PY+BR+BO") no suman de mas.
$pentaDirs = @((Join-Path $base "penta"), (Join-Path $base "archivo\importaciones_uy"))
$xlsxPenta = @()
foreach ($pDir in $pentaDirs) {
    if (Test-Path $pDir) { $xlsxPenta += @(Get-ChildItem $pDir -Filter "detalle_UYimport_*.xlsx" -ErrorAction SilentlyContinue) }
}

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

        # ------------------------------------------------------------------
        # Build-MercadoOrigen: UN origen, ano contra ano  [08/09/2026]
        #
        # Toma el pool deduplicado de extractos, filtra a un origen y arma, por
        # ano, el total del mercado y cada importador, comparando cada ano en la
        # MISMA VENTANA que cubre el ano en curso (1/1 al dia de corte) — nunca
        # un ano entero contra 8 meses (TRAMPA 3). Cuota = toneladas netas sobre
        # el total del origen (no USD: el valor declarado es menos confiable que
        # el peso). Devuelve $null si el origen no tiene filas.
        # Lo usan 5c-BR (index_brasil.html) y 5c-PYBO (index_paraguay_bolivia.html).
        # ------------------------------------------------------------------
        function Build-MercadoOrigen {
            param($Filas, [string]$Origen, [string]$Corte, [int]$AnioP)
            $rows = @($Filas | Where-Object { $_.origen -eq $Origen })
            if ($rows.Count -eq 0) { return $null }
            $corteD = [DateTime]::ParseExact($Corte, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            $cM = $corteD.Month; $cD = $corteD.Day
            $mesCompleto = ($cD -eq [DateTime]::DaysInMonth($corteD.Year, $cM))
            $anios = @($rows | ForEach-Object { $_.anio } | Sort-Object -Unique)

            # Un solo paso por las filas: acumuladores por "importador|anio" y "*|anio" (= total mercado del origen)
            $acc = @{}
            foreach ($r in $rows) {
                $enV = (($r.mes -lt $cM) -or ($r.mes -eq $cM -and $r.dia -le $cD))
                foreach ($key in @("$($r.importador)|$($r.anio)", "*|$($r.anio)")) {
                    if (-not $acc.ContainsKey($key)) {
                        $acc[$key] = @{ tKg=0.0; tUsd=0.0; tN=0; vKg=0.0; vUsd=0.0; vN=0; mKg=(New-Object double[] 13); mN=(New-Object int[] 13); ultimo='' }
                    }
                    $s = $acc[$key]
                    $s.tKg += $r.kg; $s.tUsd += $r.fob; $s.tN++
                    $s.mKg[$r.mes] += $r.kg; $s.mN[$r.mes]++
                    if ($enV) { $s.vKg += $r.kg; $s.vUsd += $r.fob; $s.vN++ }
                    if ($r.fecha -gt $s.ultimo) { $s.ultimo = $r.fecha }
                }
            }
            $pack = {
                # $s = acumulador del importador (o del mercado); $tot = acumulador del mercado del mismo ano (para la cuota)
                # Campos sin sufijo = todo lo que hay del ano; sufijo V = solo la ventana comparable.
                param($s, $tot)
                if ($null -eq $s) { $s = @{ tKg=0.0; tUsd=0.0; tN=0; vKg=0.0; vUsd=0.0; vN=0; mKg=(New-Object double[] 13); mN=(New-Object int[] 13); ultimo='' } }
                $o = [ordered]@{
                    t = [math]::Round($s.tKg/1000, 1); usd = [math]::Round($s.tUsd, 0); ops = $s.tN
                    usdKg = $null; kgOp = $null; cuota = $null
                    tV = [math]::Round($s.vKg/1000, 1); usdV = [math]::Round($s.vUsd, 0); opsV = $s.vN
                    usdKgV = $null; kgOpV = $null; cuotaV = $null
                    mensualT   = @(1..12 | ForEach-Object { [math]::Round($s.mKg[$_]/1000, 1) })
                    mensualOps = @(1..12 | ForEach-Object { $s.mN[$_] })
                }
                if ($s.tKg -gt 0) { $o.usdKg  = [math]::Round($s.tUsd/$s.tKg, 3) }
                if ($s.tN  -gt 0) { $o.kgOp   = [math]::Round($s.tKg/$s.tN, 0) }
                if ($s.vKg -gt 0) { $o.usdKgV = [math]::Round($s.vUsd/$s.vKg, 3) }
                if ($s.vN  -gt 0) { $o.kgOpV  = [math]::Round($s.vKg/$s.vN, 0) }
                if ($null -ne $tot) {
                    if ($tot.tKg -gt 0) { $o.cuota  = [math]::Round($s.tKg/$tot.tKg*100, 2) }
                    if ($tot.vKg -gt 0) { $o.cuotaV = [math]::Round($s.vKg/$tot.vKg*100, 2) }
                }
                return $o
            }
            $porAnio = [ordered]@{}
            foreach ($a in $anios) {
                $tot = $acc["*|$a"]
                $porAnio["$a"] = [ordered]@{
                    ultimoDato   = $tot.ultimo
                    completo     = (($a -lt $AnioP) -and ($tot.ultimo.Substring(5,2) -eq '12'))
                    cubreVentana = ($tot.ultimo.Substring(5) -ge $corteD.ToString('MM-dd'))
                    mercado      = (& $pack $tot $tot)
                }
            }
            $imps = @()
            foreach ($i in @($rows | ForEach-Object { $_.importador } | Sort-Object -Unique)) {
                $pa = [ordered]@{}
                foreach ($a in $anios) { $pa["$a"] = (& $pack $acc["$i|$a"] $acc["*|$a"]) }
                $imps += [PSCustomObject]@{ nombre = $i; porAnio = $pa }
            }
            # Ranking: toneladas de la ventana del ano en curso; desempate por el ano anterior
            $aPrev = $AnioP
            if ($anios.Count -ge 2) { $aPrev = $anios[$anios.Count-2] }
            $imps = @($imps | Sort-Object -Property @{ Expression = { -($_.porAnio["$AnioP"].tV) } }, @{ Expression = { -($_.porAnio["$aPrev"].tV) } })
            $almar = ($imps | Where-Object { $_.nombre -match 'ALMAR' } | Select-Object -First 1)
            $almarNombre = $null
            if ($almar) { $almarNombre = $almar.nombre }
            return [ordered]@{
                origen       = $Origen
                registros    = $rows.Count
                ventana      = [ordered]@{ mesHasta = $cM; diaHasta = $cD; mesCompleto = $mesCompleto }
                anios        = @($anios)
                almar        = $almarNombre
                porAnio      = $porAnio
                importadores = @($imps)
            }
        }

        # ------------------------------------------------------------------
        # 5c-BR) Brasil solo, ano contra ano, para index_brasil.html  [08/09/2026]
        #
        # Las secciones "Historico Almar BR", "Posicion en el mercado UY" y
        # "Competidores BR" de index_brasil.html estaban escritas a mano con
        # datos ene-11may/2026 y quedaron falsas. Ahora salen de aca, via
        # Build-MercadoOrigen. Sidecar fuentes\mercado_br.json, marcadores
        # propios /*__MERCADO_BR_JSON__*/ ... /*__END_MERCADO_BR__*/.
        # ------------------------------------------------------------------
        try {
            $brHtml    = Join-Path $base "index_brasil.html"
            $ORIGEN_BR = 'Brasil'
            $moBR = Build-MercadoOrigen -Filas $todo -Origen $ORIGEN_BR -Corte $corte -AnioP $anioP
            if ($null -eq $moBR) { throw "no hay filas de origen $ORIGEN_BR en los extractos" }
            $mercadoBR = [ordered]@{
                generado     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                fuente       = 'Penta Transaction · NCM 0803.90 · importaciones Uruguay · origen Brasil'
                origen       = $ORIGEN_BR
                archivos     = $archivos
                registros    = $moBR.registros
                anio         = $anioP
                corte        = $corte
                ventana      = $moBR.ventana
                anios        = $moBR.anios
                almar        = $moBR.almar
                porAnio      = $moBR.porAnio
                importadores = $moBR.importadores
            }
            $brJson = $mercadoBR | ConvertTo-Json -Depth 8 -Compress
            Set-Content -Path (Join-Path $fuentes "mercado_br.json") -Value $brJson -Encoding UTF8
            $almarTxt = 'sin Almar'
            if ($moBR.almar) {
                $almarBR = ($moBR.importadores | Where-Object { $_.nombre -eq $moBR.almar } | Select-Object -First 1)
                if ($almarBR) { $almarTxt = "Almar $($almarBR.porAnio["$anioP"].cuotaV)% de cuota $anioP" }
            }
            Write-Host "    sidecar: fuentes\mercado_br.json (Brasil: $($moBR.registros) reg, anios $($moBR.anios -join '/'), $($moBR.importadores.Count) importadores, $almarTxt)" -ForegroundColor Green
            if (Test-Path $brHtml) {
                $bTxt = Get-Content $brHtml -Raw -Encoding UTF8
                $patB = '/\*__MERCADO_BR_JSON__\*/.*?/\*__END_MERCADO_BR__\*/'
                $nB = ([regex]::Matches($bTxt, $patB, 'Singleline')).Count
                if ($nB -ne 1) {
                    Write-Host "    (skip) index_brasil.html: esperaba 1 par de marcadores MERCADO_BR, hay $nB" -ForegroundColor Red
                } else {
                    $repB = '/*__MERCADO_BR_JSON__*/' + $brJson + '/*__END_MERCADO_BR__*/'
                    Set-Content -Path $brHtml -Value ([regex]::Replace($bTxt, $patB, { param($m) $repB }, 'Singleline')) -Encoding UTF8 -NoNewline
                    Write-Host "    OK index_brasil.html (bloque mercado BR)" -ForegroundColor Green
                }
            } else {
                Write-Host "    (aviso) falta index_brasil.html — el sidecar quedo generado igual" -ForegroundColor DarkYellow
            }
        } catch {
            Add-Falla -Paso 'Mercado BR (Penta, index_brasil)' -Detalle $_.Exception.Message
        }

        # ------------------------------------------------------------------
        # 5c-PYBO) Paraguay y Bolivia (y el resto de los origenes para los
        # indicadores comparados), para index_paraguay_bolivia.html  [08/09/2026]
        #
        # La pagina tenia "Mercado UY multi-origen", "Indicadores estrategicos"
        # (scorecard, performance vs mercado, HHI) y el resumen escritos a mano
        # con datos ene-11may/2026: Paraguay figuraba "contraido a 1/4" cuando
        # se multiplico por 7 desde mayo, y el resumen traia los KPIs del plan
        # de Brasil. Ahora todo sale de aca: la misma agregacion por origen que
        # usa Brasil, para TODOS los origenes del pool (Paraguay y Bolivia son
        # los principales de la pagina; Brasil y Ecuador van al scorecard, la
        # performance vs mercado y el HHI comparado). Sidecar
        # fuentes\mercado_pybo.json, marcadores propios
        # /*__MERCADO_PYBO_JSON__*/ ... /*__END_MERCADO_PYBO__*/.
        # ------------------------------------------------------------------
        try {
            $pyboHtml    = Join-Path $base "index_paraguay_bolivia.html"
            $PRINCIPALES = @('Paraguay', 'Bolivia')
            $todosOrig   = @($todo | ForEach-Object { $_.origen } | Sort-Object -Unique)
            $ordenOrig   = @($PRINCIPALES | Where-Object { $todosOrig -contains $_ }) + @($todosOrig | Where-Object { $PRINCIPALES -notcontains $_ })
            $origenesMO  = [ordered]@{}
            $aniosU      = @()
            foreach ($o in $ordenOrig) {
                $moX = Build-MercadoOrigen -Filas $todo -Origen $o -Corte $corte -AnioP $anioP
                if ($null -eq $moX) { continue }
                $origenesMO[$o] = [ordered]@{
                    registros    = $moX.registros
                    anios        = $moX.anios
                    almar        = $moX.almar
                    porAnio      = $moX.porAnio
                    importadores = $moX.importadores
                }
                $aniosU += $moX.anios
            }
            $hayPrincipal = @($PRINCIPALES | Where-Object { $origenesMO.Contains($_) })
            if ($hayPrincipal.Count -eq 0) { throw "no hay filas de origen $($PRINCIPALES -join ' ni ') en los extractos" }
            $corteD2 = [DateTime]::ParseExact($corte, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            $almarPYBO = $null
            foreach ($o in $ordenOrig) { if ($origenesMO.Contains($o) -and $origenesMO[$o].almar) { $almarPYBO = $origenesMO[$o].almar; break } }
            $mercadoPYBO = [ordered]@{
                generado    = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                fuente      = 'Penta Transaction · NCM 0803.90 · importaciones Uruguay · por origen'
                archivos    = $archivos
                registros   = $todo.Count
                anio        = $anioP
                corte       = $corte
                ventana     = [ordered]@{ mesHasta = $corteD2.Month; diaHasta = $corteD2.Day; mesCompleto = ($corteD2.Day -eq [DateTime]::DaysInMonth($corteD2.Year, $corteD2.Month)) }
                anios       = @($aniosU | Sort-Object -Unique)
                almar       = $almarPYBO
                principales = @($hayPrincipal)
                origenes    = $origenesMO
            }
            $pyboJson = $mercadoPYBO | ConvertTo-Json -Depth 10 -Compress
            Set-Content -Path (Join-Path $fuentes "mercado_pybo.json") -Value $pyboJson -Encoding UTF8
            $pyboResumen = @()
            foreach ($o in $hayPrincipal) {
                $moX = $origenesMO[$o]; $txtX = "$o $($moX.registros) reg"
                if ($moX.almar) {
                    $impX = ($moX.importadores | Where-Object { $_.nombre -eq $moX.almar } | Select-Object -First 1)
                    if ($impX) { $txtX += ", Almar $($impX.porAnio["$anioP"].cuotaV)% de cuota $anioP" }
                }
                $pyboResumen += $txtX
            }
            Write-Host "    sidecar: fuentes\mercado_pybo.json (origenes $($origenesMO.Keys -join '/'); $($pyboResumen -join ' · '))" -ForegroundColor Green
            if (Test-Path $pyboHtml) {
                $pTxt2 = Get-Content $pyboHtml -Raw -Encoding UTF8
                $patPB = '/\*__MERCADO_PYBO_JSON__\*/.*?/\*__END_MERCADO_PYBO__\*/'
                $nPB = ([regex]::Matches($pTxt2, $patPB, 'Singleline')).Count
                if ($nPB -ne 1) {
                    Write-Host "    (skip) index_paraguay_bolivia.html: esperaba 1 par de marcadores MERCADO_PYBO, hay $nPB" -ForegroundColor Red
                } else {
                    $repPB = '/*__MERCADO_PYBO_JSON__*/' + $pyboJson + '/*__END_MERCADO_PYBO__*/'
                    Set-Content -Path $pyboHtml -Value ([regex]::Replace($pTxt2, $patPB, { param($m) $repPB }, 'Singleline')) -Encoding UTF8 -NoNewline
                    Write-Host "    OK index_paraguay_bolivia.html (resumen + mercado PY/BO + indicadores)" -ForegroundColor Green
                }
            } else {
                Write-Host "    (aviso) falta index_paraguay_bolivia.html — el sidecar quedo generado igual" -ForegroundColor DarkYellow
            }
        } catch {
            Add-Falla -Paso 'Mercado PY/BO (Penta, index_paraguay_bolivia)' -Detalle $_.Exception.Message
        }

        # ------------------------------------------------------------------
        # 5c-UY) Ano contra ano, misma ventana, TODOS los origenes, para
        # index_mercado.html  [08/09/2026]
        #
        # index_mercado.html comparaba solo ene-abr contra may-ago del ano en
        # curso (mas el interanual de esos 4 meses via uy_import_agg.json). Los
        # extractos de archivo\importaciones_uy\ traen 2024 y 2025 enteros con
        # importador, asi que la pagina recibe ademas la misma agregacion que
        # usan Brasil y PY/BO (Build-MercadoOrigen): por origen y para el total
        # del mercado, cada ano en la MISMA VENTANA (1/1 al dia de corte).
        # Va como clave `anual` dentro de mercado_uy.json (un solo sidecar, un
        # solo par de marcadores) y se vuelve a inyectar la pagina. Si algo
        # falla, la pagina queda con lo que ya tenia (sin bloque anual).
        # ------------------------------------------------------------------
        try {
            $todoStar = @($todo | ForEach-Object { $cs = $_.PSObject.Copy(); $cs.origen = '*'; $cs })
            $moTot = Build-MercadoOrigen -Filas $todoStar -Origen '*' -Corte $corte -AnioP $anioP
            if ($null -eq $moTot) { throw "sin filas para el total del mercado" }
            # Origenes del ano en curso (orden por volumen) + los que solo aparecen en anos previos
            $origAnualLista = @($ORIG) + @($todo | ForEach-Object { $_.origen } | Sort-Object -Unique | Where-Object { $ORIG -notcontains $_ })
            $origAnual = [ordered]@{}
            foreach ($oa in $origAnualLista) {
                $moO = Build-MercadoOrigen -Filas $todo -Origen $oa -Corte $corte -AnioP $anioP
                if ($null -eq $moO) { continue }
                $origAnual[$oa] = [ordered]@{
                    registros    = $moO.registros
                    anios        = $moO.anios
                    almar        = $moO.almar
                    porAnio      = $moO.porAnio
                    importadores = $moO.importadores
                }
            }
            $mercado['anual'] = [ordered]@{
                ventana   = $moTot.ventana
                anios     = $moTot.anios
                almar     = $moTot.almar
                registros = $moTot.registros
                total     = [ordered]@{ porAnio = $moTot.porAnio; importadores = $moTot.importadores }
                origenes  = $origAnual
            }
            $mercadoJson = $mercado | ConvertTo-Json -Depth 12 -Compress
            Set-Content -Path (Join-Path $fuentes "mercado_uy.json") -Value $mercadoJson -Encoding UTF8
            $almarTxtU = 'sin Almar'
            if ($moTot.almar) {
                $almarU = ($moTot.importadores | Where-Object { $_.nombre -eq $moTot.almar } | Select-Object -First 1)
                if ($almarU) { $almarTxtU = "Almar $($almarU.porAnio["$anioP"].cuotaV)% del mercado $anioP" }
            }
            Write-Host "    sidecar: fuentes\mercado_uy.json + anual (anios $($moTot.anios -join '/'); origenes $($origAnual.Keys -join '/'); $almarTxtU)" -ForegroundColor Green
            if (Test-Path $mercadoHtml) {
                $mTxtU = Get-Content $mercadoHtml -Raw -Encoding UTF8
                $patMU = '/\*__MERCADO_JSON__\*/.*?/\*__END_MERCADO__\*/'
                $nMU = ([regex]::Matches($mTxtU, $patMU, 'Singleline')).Count
                if ($nMU -ne 1) {
                    Write-Host "    (skip) index_mercado.html: esperaba 1 par de marcadores, hay $nMU" -ForegroundColor Red
                } else {
                    $repMU = '/*__MERCADO_JSON__*/' + $mercadoJson + '/*__END_MERCADO__*/'
                    Set-Content -Path $mercadoHtml -Value ([regex]::Replace($mTxtU, $patMU, { param($m) $repMU }, 'Singleline')) -Encoding UTF8 -NoNewline
                    Write-Host "    OK index_mercado.html (bloque anual)" -ForegroundColor Green
                }
            }
        } catch {
            Add-Falla -Paso 'Mercado UY anual (Penta, index_mercado)' -Detalle $_.Exception.Message
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
# 5d) Proyeccion hasta fin de anio (index_proyeccion.html)  [04/09/2026, reescrito 08/09/2026]
#
# Precio: mismo modelo de anclaje del forecast (baseline estacional del mes x
#   factor 1+(desvio-1)*phi^k), pero proyectado VIERNES a VIERNES hasta el 31/12
#   y promediado por mes. Los meses cerrados salen como 'real' (promedio de sus
#   semanas Cepea), el mes en curso como 'parcial' (semanas reales + proyectadas)
#   y el resto 'proyectado'. Se recalcula en CADA corrida: cuando Cepea publica,
#   el desvio se re-estima y la proyeccion se corrige sola.
#   ⚠️ El ancla decae: a >8 semanas el factor tiende a 1 y la proyeccion es
#   basicamente el promedio estacional. La pagina lo declara.
# Volumen: nivel de la ventana v2 (may-ago) de cada origen (mercado_uy.json) x el
#   factor estacional MES A MES de los anios previos (t del mes / promedio may-ago
#   del mismo anio), con la serie Penta fusionada 2024-2026 de mercado_pybo.json
#   (5c-PYBO). Rango = min/max de esos factores, no un intervalo estadistico.
#   Antes usaba uy_import_agg.json (agregado del 02/09 con 500 registros
#   'derivados' y 2026 cortado en abril): ya no.
# Almar: dos escenarios por origen. (a) mantiene la cuota que tiene hoy en cada
#   origen (Penta, ventana v2); (b) repite su PROPIA estacionalidad (sus t mes a
#   mes de anios previos como importador en Penta). Mas: el mes en curso ya
#   comprometido segun el Plan de Cargas (cargado + programado, sidecar del 5h),
#   y el spread real que Almar paga vs el equivalente Cepea (cargas 2026 vs serie
#   Cepea, ponderado por camion), que se aplica al costo proyectado.
# ==========================================================================
Write-Host "[5d] Proyeccion hasta fin de anio..." -ForegroundColor Cyan

$proyHtml = Join-Path $base "index_proyeccion.html"
$merPath  = Join-Path $fuentes "mercado_uy.json"
$pyboPath = Join-Path $fuentes "mercado_pybo.json"
$planPath = Join-Path $fuentes "plan_cargas.json"
$calPath  = Join-Path $fuentes "calidad.json"

if (-not (Test-Path $merPath) -or -not (Test-Path $pyboPath)) {
    Write-Host "    (skip) faltan mercado_uy.json o mercado_pybo.json (los genera el 5c)" -ForegroundColor DarkYellow
} else {
  try {
    $merJ  = Get-Content $merPath  -Raw -Encoding UTF8 | ConvertFrom-Json
    $pyboJ = Get-Content $pyboPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $planJ = $null; if (Test-Path $planPath) { try { $planJ = Get-Content $planPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $planJ = $null } }
    $calJ  = $null; if (Test-Path $calPath)  { try { $calJ  = Get-Content $calPath  -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $calJ  = $null } }

    $TC_USD    = 5.20
    $KG_CAJA   = $(if ($KG_CAJA_NETO)   { [double]$KG_CAJA_NETO }   else { 22.0 })
    $SERV_CAJA = $(if ($SERVICIOS_CAJA) { [double]$SERVICIOS_CAJA } else { 16.0 })
    $pjInv = [System.Globalization.CultureInfo]::InvariantCulture
    function PJ-Fecha { param([string]$s) return [DateTime]::ParseExact($s.Substring(0,10), 'yyyy-MM-dd', $pjInv) }
    function PJ-Prom  { param($arr) $a2 = @($arr | Where-Object { $null -ne $_ }); if ($a2.Count -eq 0) { return $null }; return ($a2 | Measure-Object -Average).Average }

    $ultFecha = PJ-Fecha ([string]$data.ultima_semana)
    $anioP2   = $ultFecha.Year
    $hoyP     = Get-Date
    $mesCur   = $(if ($hoyP.Year -eq $anioP2) { $hoyP.Month } elseif ($hoyP.Year -gt $anioP2) { 12 } else { 1 })

    # ---------- Cepea: semanas por anio|mes (dedup por fecha: la serie repite 2024-01-05 y 2026-06-26) ----------
    $pjSem = @{}; $pjVistas = @{}; $pjCepeaFecha = @{}
    foreach ($w in @($nanica)) {
        $fk = [string]$w.fecha
        $pjCepeaFecha[$fk] = [double]$w.precio
        if ($pjVistas.ContainsKey($fk)) { continue }
        $pjVistas[$fk] = $true
        $key = "$([int]$w.anio)|$([int]$w.mes)"
        if (-not $pjSem.ContainsKey($key)) { $pjSem[$key] = New-Object System.Collections.Generic.List[double] }
        $pjSem[$key].Add([double]$w.precio)
    }
    $pjAniosHist = @($nanica | ForEach-Object { [int]$_.anio } | Sort-Object -Unique | Where-Object { $_ -lt $anioP2 })

    # ---------- Almar: precio real por mes (cargas 2026) y spread vs equivalente Cepea ----------
    $pjAlmarMes = @{}
    if ($data.almar -and $data.almar.meses) {
        foreach ($am in @($data.almar.meses)) {
            if ($am.orden -and [double]$am.cargas -gt 0) {
                $pjAlmarMes[[int]$am.orden] = @{ cargas=[double]$am.cargas; caja=[double]$am.precio_avg_caja; n=[int]$am.n_operaciones }
            }
        }
    }
    $spSumR = 0.0; $spSumBase = 0.0; $spSumCargas = 0.0; $spSemanas = 0
    if ($data.almar -and $data.almar.semanas) {
        foreach ($sa in @($data.almar.semanas)) {
            if (-not $sa.fecha -or -not ([double]$sa.cargas -gt 0) -or -not ([double]$sa.precio_avg_caja -gt 0)) { continue }
            $fSab = PJ-Fecha ([string]$sa.fecha)
            $cep = $null
            foreach ($dd in 0,-1,1,-2,2,-3,3) {   # la semana de cargas cierra sabado; Cepea es viernes
                $fk2 = $fSab.AddDays($dd).ToString('yyyy-MM-dd')
                if ($pjCepeaFecha.ContainsKey($fk2)) { $cep = $pjCepeaFecha[$fk2]; break }
            }
            if ($null -eq $cep) { continue }
            $eqCaja = $cep * $KG_CAJA + $SERV_CAJA
            $spSumR += ([double]$sa.precio_avg_caja - $eqCaja) * [double]$sa.cargas
            $spSumBase += $eqCaja * [double]$sa.cargas
            $spSumCargas += [double]$sa.cargas; $spSemanas++
        }
    }
    $spreadCaja = $(if ($spSumCargas -gt 0) { $spSumR / $spSumCargas } else { 0.0 })
    $spreadPct  = $(if ($spSumBase -gt 0)   { $spSumR / $spSumBase * 100 } else { 0.0 })

    # ---------- PRECIO: viernes a viernes hasta el 31/12, promediado por mes ----------
    $pjProySem = @{}
    $fv = $ultFecha.AddDays(7); $kk = 1
    while ($fv.Year -eq $anioP2) {
        $mmP = $fv.Month
        $blP = $(if ($promedioMes.Contains("$mmP")) { [double]$promedioMes["$mmP"] } else { 1.36 })
        $ffP = 1 + ($devActual - 1) * [Math]::Pow($phiDev, $kk)
        if (-not $pjProySem.ContainsKey($mmP)) { $pjProySem[$mmP] = New-Object System.Collections.Generic.List[object] }
        $pjProySem[$mmP].Add(@{ k=$kk; f=$ffP; val=$blP*$ffP })
        $fv = $fv.AddDays(7); $kk++
    }
    $precioProy = @()
    foreach ($m in 1..12) {
        $reales = @(); if ($pjSem.ContainsKey("$anioP2|$m")) { $reales = @($pjSem["$anioP2|$m"].ToArray()) }
        $bl = $(if ($promedioMes.Contains("$m")) { [double]$promedioMes["$m"] } else { 1.36 })
        $hist = [ordered]@{}
        foreach ($ah in $pjAniosHist) {
            if ($pjSem.ContainsKey("$ah|$m")) { $hist["$ah"] = [math]::Round((($pjSem["$ah|$m"] | Measure-Object -Average).Average), 2) }
        }
        # .ToArray(): en PS 5.1, @(List[object] de hashtables) tira "los tipos de argumentos no coinciden"
        $proyS = @(); if ($pjProySem.ContainsKey($m)) { $proyS = @($pjProySem[$m].ToArray()) }
        $almR = $null
        if ($pjAlmarMes.ContainsKey($m)) { $almR = [ordered]@{ cargas=$pjAlmarMes[$m].cargas; caja=[math]::Round($pjAlmarMes[$m].caja,2); n=$pjAlmarMes[$m].n } }
        $fac = $null; $kmed = 0
        if ($reales.Count -gt 0 -and $proyS.Count -eq 0) {
            $val = ($reales | Measure-Object -Average).Average; $estado = 'real'
        } elseif ($proyS.Count -gt 0) {
            $todos = @($reales) + @($proyS | ForEach-Object { $_.val })
            $val = ($todos | Measure-Object -Average).Average
            $estado = $(if ($reales.Count -gt 0) { 'parcial' } else { 'proyectado' })
            $fac = ($proyS | ForEach-Object { $_.f } | Measure-Object -Average).Average
            $kmed = [int][math]::Round((($proyS | ForEach-Object { $_.k } | Measure-Object -Average).Average), 0)
        } else {
            $val = $bl; $estado = 'proyectado'; $fac = 1.0
        }
        $caja = $val * $KG_CAJA + $SERV_CAJA
        $precioProy += [PSCustomObject]([ordered]@{
            mes=$m; estado=$estado; semReales=$reales.Count; semProy=$proyS.Count
            baseline=[math]::Round($bl,2); factor=$(if ($null -eq $fac) { $null } else { [math]::Round($fac,3) }); k=$kmed
            valor=[math]::Round($val,2); caja=[math]::Round($caja,0); usdCaja=[math]::Round($caja/$TC_USD,2)
            hist=$hist; almar=$almR
            almarProy=$(if ($estado -eq 'real') { $null } else { [ordered]@{ caja=[math]::Round($caja+$spreadCaja,0); usdCaja=[math]::Round(($caja+$spreadCaja)/$TC_USD,2) } })
        })
    }

    # ---------- VOLUMEN: mercado por origen, mes a mes, desde Penta fusionado (mercado_pybo.json) ----------
    $mesTope   = [int]$merJ.meses            # ultimo mes cerrado del anio en curso en Penta
    $corteV    = [int]$merJ.corteVentana
    $V2m = @(); if ($mesTope -gt $corteV) { $V2m = @(($corteV+1)..$mesTope) }
    $mesesProy = @(); if ($mesTope -lt 12) { $mesesProy = @(($mesTope+1)..12) }
    $ORIGP = @($merJ.origenes)
    $aniosPrev = @($pyboJ.anios | ForEach-Object { [int]$_ } | Where-Object { $_ -lt $anioP2 } | Sort-Object)
    $almarNombre = [string]$pyboJ.almar
    $almUY = $merJ.importadores | Where-Object { $_.nombre -match 'ALMAR' } | Select-Object -First 1

    function PJ-Mensual { param($o, $anio, [switch]$Almar)
        # 12 t mensuales del mercado (o de Almar como importador) para origen/anio, o $null
        if (-not $pyboJ.origenes) { return $null }
        $mo = $pyboJ.origenes.$o
        if ($null -eq $mo) { return $null }
        if ($Almar) {
            if (-not $almarNombre) { return $null }
            $imp = @($mo.importadores | Where-Object { $_.nombre -eq $almarNombre }) | Select-Object -First 1
            if ($null -eq $imp) { return $null }
            $pa = $imp.porAnio."$anio"
            if ($null -eq $pa -or $null -eq $pa.mensualT) { return $null }
            return @($pa.mensualT | ForEach-Object { [double]$_ })
        }
        $pa = $mo.porAnio."$anio"
        if ($null -eq $pa -or $null -eq $pa.mercado -or $null -eq $pa.mercado.mensualT) { return $null }
        return @($pa.mercado.mensualT | ForEach-Object { [double]$_ })
    }
    function PJ-Proyectar { param($o, [double]$actual, [switch]$Almar)
        # t/mes para cada mes de $mesesProy = $actual x factor estacional (t del mes / promedio V2 del mismo anio previo)
        $pjBases = @{}; $histP = [ordered]@{}
        foreach ($ah in $aniosPrev) {
            $arr = $(if ($Almar) { PJ-Mensual $o $ah -Almar } else { PJ-Mensual $o $ah })
            if ($null -eq $arr -or @($arr).Count -lt 12) { continue }
            if ($mesesProy.Count) { $histP["$ah"] = [math]::Round((PJ-Prom @($mesesProy | ForEach-Object { $arr[$_-1] })), 0) }
            $baseY = PJ-Prom @($V2m | ForEach-Object { $arr[$_-1] })
            if ($null -ne $baseY -and $baseY -gt 0) { $pjBases[$ah] = @{ arr=$arr; base=$baseY } }
        }
        $mesesR = @(); $sumC=0.0; $sumL=0.0; $sumH=0.0
        $aniosOk = @($pjBases.Keys | Sort-Object)
        if ($aniosOk.Count -gt 0 -and $actual -gt 0) {
            foreach ($m in $mesesProy) {
                $fsM = @($aniosOk | ForEach-Object { $pjBases[$_].arr[$m-1] / $pjBases[$_].base })
                $cM = $actual * (PJ-Prom $fsM)
                $lM = $actual * (($fsM | Measure-Object -Minimum).Minimum)
                $hM = $actual * (($fsM | Measure-Object -Maximum).Maximum)
                $mesesR += [ordered]@{ mes=$m; factores=@($fsM | ForEach-Object { [math]::Round($_,3) }); central=[math]::Round($cM,0); lo=[math]::Round($lM,0); hi=[math]::Round($hM,0) }
                $sumC += $cM; $sumL += $lM; $sumH += $hM
            }
            $modo = 'estacional'
            $nota = "nivel may-ago $anioP2 x factor estacional mes a mes de " + ($aniosOk -join '/')
        } else {
            # sin volumen may-ago en anios previos (origen nuevo en esa ventana): nivel de los mismos meses del anio pasado,
            # banda desde el nivel actual hasta +40 % de ese nivel
            $prev = $(if ($Almar) { PJ-Mensual $o ($anioP2-1) -Almar } else { PJ-Mensual $o ($anioP2-1) })
            foreach ($m in $mesesProy) {
                $cM = $(if ($prev -and @($prev).Count -ge 12) { [double]$prev[$m-1] } else { $actual })
                $lM = [math]::Min($cM*0.6, $actual); $hM = [math]::Max($cM*1.4, $actual)
                $mesesR += [ordered]@{ mes=$m; factores=@(); central=[math]::Round($cM,0); lo=[math]::Round($lM,0); hi=[math]::Round($hM,0) }
                $sumC += $cM; $sumL += $lM; $sumH += $hM
            }
            $modo = 'nivel_anio_pasado'
            $nota = "sin volumen may-ago en años previos: nivel de los mismos meses de $($anioP2-1), banda desde el nivel actual hasta +40 %"
        }
        $nmP = [math]::Max(1, $mesesProy.Count)
        return [ordered]@{ meses=$mesesR; central=[math]::Round($sumC/$nmP,0); lo=[math]::Round($sumL/$nmP,0); hi=[math]::Round($sumH/$nmP,0)
                           anios=@($aniosOk); hist=$histP; nota=$nota; modo=$modo }
    }

    $volOrig = @(); $totMesV = @{}; foreach ($m in $mesesProy) { $totMesV[$m] = @{ c=0.0; l=0.0; h=0.0 } }
    $totC=0.0; $totL=0.0; $totH=0.0; $totUsd=0.0; $totActual=0.0
    foreach ($o in $ORIGP) {
        $poV = $merJ.porOrigen | Where-Object { $_.origen -eq $o } | Select-Object -First 1
        $actual = $(if ($poV) { [double]$poV.v2 } else { 0.0 })
        $fob = $(if ($poV -and $poV.fobV2) { [double]$poV.fobV2 } else { 0.0 })
        $pjR = PJ-Proyectar $o $actual
        $realArr = PJ-Mensual $o $anioP2
        $realL = New-Object System.Collections.Generic.List[object]
        foreach ($m in 1..12) { if ($realArr -and $m -le $mesTope) { $realL.Add([math]::Round([double]$realArr[$m-1],0)) } else { $realL.Add($null) } }
        $shareO = 0.0
        if ($almUY -and $almUY.porOrigen -and $almUY.porOrigen.$o -and $actual -gt 0) { $shareO = [double](@($almUY.porOrigen.$o))[1] / $actual }
        foreach ($mm in $pjR.meses) { $totMesV[$mm.mes].c += $mm.central; $totMesV[$mm.mes].l += $mm.lo; $totMesV[$mm.mes].h += $mm.hi }
        $totC += $pjR.central; $totL += $pjR.lo; $totH += $pjR.hi; $totActual += $actual
        $usdMes = $pjR.central*1000*$fob; $totUsd += $usdMes
        $volOrig += [PSCustomObject]([ordered]@{ origen=$o; actual=[math]::Round($actual,0); fobKg=$fob; share=[math]::Round($shareO,4)
            real=@($realL.ToArray()); meses=$pjR.meses; central=$pjR.central; lo=$pjR.lo; hi=$pjR.hi; usdMes=[math]::Round($usdMes,0)
            anios=$pjR.anios; hist=$pjR.hist; nota=$pjR.nota; modo=$pjR.modo })
    }
    $volMeses = @(); foreach ($m in $mesesProy) { $volMeses += [ordered]@{ mes=$m; central=[math]::Round($totMesV[$m].c,0); lo=[math]::Round($totMesV[$m].l,0); hi=[math]::Round($totMesV[$m].h,0) } }
    $histTot = @()
    foreach ($ah in $aniosPrev) {
        $sumHT = 0.0; $okHT = $false
        foreach ($vo in $volOrig) { if ($vo.hist -and $vo.hist.Contains("$ah")) { $sumHT += [double]$vo.hist["$ah"]; $okHT = $true } }
        if ($okHT) { $histTot += [PSCustomObject]@{ anio=$ah; t=[math]::Round($sumHT,0) } }
    }
    $realTotL = New-Object System.Collections.Generic.List[object]
    foreach ($m in 1..12) { $sRT = 0.0; $anyRT = $false; foreach ($vo in $volOrig) { if ($null -ne $vo.real[$m-1]) { $sRT += $vo.real[$m-1]; $anyRT = $true } }; if ($anyRT) { $realTotL.Add([math]::Round($sRT,0)) } else { $realTotL.Add($null) } }

    # ---------- PLAN DE CARGAS: mes en curso ya comprometido por origen ----------
    # El mensual del 5h cuenta solo camiones DESCARGADOS (status Descargado); los en camino
    # (Cargado/Frontera/Puerto/...) y los programados (Solicitado) van aparte. Todo por fecha de carga.
    $comprom = @(); $cpcMap = @{}
    if ($planJ -and $planJ.porOrigen) {
        $mapOrig = @{ BR='Brasil'; PY='Paraguay'; BO='Bolivia'; EC='Ecuador' }
        foreach ($cod in @($planJ.porOrigen.PSObject.Properties.Name)) {
            $pox = $planJ.porOrigen.$cod
            $oN = $(if ($mapOrig.ContainsKey($cod)) { $mapOrig[$cod] } else { $cod })
            $paP = $pox.porAnio."$anioP2"
            $camMes = 0; $cajMes = 0.0; $cpc = 1000.0; $camReal = @()
            if ($paP) {
                if ($paP.mensualCamiones) { $camMes = [int]$paP.mensualCamiones[$mesCur-1]; $camReal = @($paP.mensualCamiones | ForEach-Object { [int]$_ }) }
                if ($paP.mensualCajas)    { $cajMes = [double]$paP.mensualCajas[$mesCur-1] }
                if ($paP.cajasPorCamion)  { $cpc = [double]$paP.cajasPorCamion }
            }
            $cpcMap[$oN] = $cpc
            $enC = @($pox.enCamino | Where-Object { $_.fecha -and (PJ-Fecha ([string]$_.fecha)).Year -eq $anioP2 -and (PJ-Fecha ([string]$_.fecha)).Month -eq $mesCur })
            $prog = @($pox.programados | Where-Object { $_.fecha -and (PJ-Fecha ([string]$_.fecha)).Year -eq $anioP2 -and (PJ-Fecha ([string]$_.fecha)).Month -eq $mesCur })
            $progCaj = 0.0; foreach ($pg in $prog) { $progCaj += [double]$pg.cajas }
            $enCCaj = 0.0;  foreach ($ec in $enC)  { $enCCaj  += [double]$ec.cajas }
            $comprom += [PSCustomObject]([ordered]@{ origen=$oN; codigo=$cod; mes=$mesCur
                descargados=$camMes; descargadosCajas=[math]::Round($cajMes,0)
                enCamino=$enC.Count; enCaminoCajas=[math]::Round($enCCaj,0)
                programados=$prog.Count; programadosCajas=[math]::Round($progCaj,0)
                total=($camMes + $enC.Count + $prog.Count); totalCajas=[math]::Round($cajMes+$enCCaj+$progCaj,0); totalT=[math]::Round(($cajMes+$enCCaj+$progCaj)*$KG_CAJA/1000,0)
                cajasPorCamion=[math]::Round($cpc,0); ultimaCarga=[string]$pox.ultima; camionesMes=$camReal })
        }
    }

    # ---------- ALMAR: cuota constante vs propia estacionalidad, por origen ----------
    $almOrig = @()
    $aCuota = @{ c=0.0; l=0.0; h=0.0 }; $aPropia = @{ c=0.0; l=0.0; h=0.0 }; $aActual = 0.0
    $aCuotaMes = @{}; $aPropiaMes = @{}
    foreach ($m in $mesesProy) { $aCuotaMes[$m] = @{ c=0.0; l=0.0; h=0.0 }; $aPropiaMes[$m] = @{ c=0.0; l=0.0; h=0.0 } }
    $propiaFallback = @()
    foreach ($vo in $volOrig) {
        $o = $vo.origen
        $actA = 0.0; if ($almUY -and $almUY.porOrigen -and $almUY.porOrigen.$o) { $actA = [double](@($almUY.porOrigen.$o))[1] }
        $aActual += $actA
        $cuotaM = @()
        foreach ($mm in $vo.meses) {
            $cc = $mm.central*$vo.share; $ll = $mm.lo*$vo.share; $hh = $mm.hi*$vo.share
            $cuotaM += [ordered]@{ mes=$mm.mes; central=[math]::Round($cc,0); lo=[math]::Round($ll,0); hi=[math]::Round($hh,0) }
            $aCuotaMes[$mm.mes].c += $cc; $aCuotaMes[$mm.mes].l += $ll; $aCuotaMes[$mm.mes].h += $hh
        }
        $cuota = [ordered]@{ central=[math]::Round($vo.central*$vo.share,0); lo=[math]::Round($vo.lo*$vo.share,0); hi=[math]::Round($vo.hi*$vo.share,0); meses=$cuotaM }
        $aCuota.c += $vo.central*$vo.share; $aCuota.l += $vo.lo*$vo.share; $aCuota.h += $vo.hi*$vo.share
        $propia = $null
        if ($actA -gt 0 -and $mesesProy.Count -gt 0) {
            $pp = PJ-Proyectar $o $actA -Almar
            if ($pp.modo -eq 'estacional') {
                $propia = [ordered]@{ central=$pp.central; lo=$pp.lo; hi=$pp.hi; meses=$pp.meses; anios=$pp.anios; hist=$pp.hist; nota=$pp.nota }
                foreach ($mm in $pp.meses) { $aPropiaMes[$mm.mes].c += $mm.central; $aPropiaMes[$mm.mes].l += $mm.lo; $aPropiaMes[$mm.mes].h += $mm.hi }
                $aPropia.c += $pp.central; $aPropia.l += $pp.lo; $aPropia.h += $pp.hi
            }
        }
        if ($null -eq $propia) {
            # sin historia propia en la ventana: el total 'propia' toma la cuota para este origen (declarado)
            $propiaFallback += $o
            foreach ($cm in $cuotaM) { $aPropiaMes[$cm.mes].c += $cm.central; $aPropiaMes[$cm.mes].l += $cm.lo; $aPropiaMes[$cm.mes].h += $cm.hi }
            $aPropia.c += $cuota.central; $aPropia.l += $cuota.lo; $aPropia.h += $cuota.hi
        }
        $realAArr = PJ-Mensual $o $anioP2 -Almar
        $realAL = New-Object System.Collections.Generic.List[object]
        foreach ($m in 1..12) { if ($realAArr -and $m -le $mesTope) { $realAL.Add([math]::Round([double]$realAArr[$m-1],0)) } else { $realAL.Add($null) } }
        $cpcO = $(if ($cpcMap.ContainsKey($o)) { [double]$cpcMap[$o] } else { $null })
        $camEq = $null
        if ($cpcO -and $cpcO -gt 0) {
            $camEq = [ordered]@{ cuota=[math]::Round($cuota.central*1000/$KG_CAJA/$cpcO,0)
                                 propia=$(if ($propia) { [math]::Round($propia.central*1000/$KG_CAJA/$cpcO,0) } else { $null })
                                 cajasPorCamion=[math]::Round($cpcO,0) }
        }
        $compO = $comprom | Where-Object { $_.origen -eq $o } | Select-Object -First 1
        $almOrig += [PSCustomObject]([ordered]@{ origen=$o; actual=[math]::Round($actA,0); share=$vo.share
            real=@($realAL.ToArray()); cuota=$cuota; propia=$propia; camionesEquiv=$camEq; comprometido=$compO })
    }
    $aCuotaMeses = @(); $aPropiaMeses = @()
    foreach ($m in $mesesProy) {
        $aCuotaMeses  += [ordered]@{ mes=$m; central=[math]::Round($aCuotaMes[$m].c,0);  lo=[math]::Round($aCuotaMes[$m].l,0);  hi=[math]::Round($aCuotaMes[$m].h,0) }
        $aPropiaMeses += [ordered]@{ mes=$m; central=[math]::Round($aPropiaMes[$m].c,0); lo=[math]::Round($aPropiaMes[$m].l,0); hi=[math]::Round($aPropiaMes[$m].h,0) }
    }
    $shareTot = $(if ($totActual -gt 0) { $aActual / $totActual } else { 0.0 })

    # ---------- COSTO BRASIL: cajas de cada escenario x (Cepea proyectado a caja + spread real de Almar) ----------
    $brAl = $almOrig | Where-Object { $_.origen -match 'Brasil' } | Select-Object -First 1
    $costo = @(); $cBrlLo = 0.0; $cBrlHi = 0.0
    if ($brAl) {
        foreach ($m in $mesesProy) {
            $pRow = $precioProy[$m-1]
            $mC = $brAl.cuota.meses | Where-Object { $_.mes -eq $m } | Select-Object -First 1
            if (-not $mC) { continue }
            $tC = [double]$mC.central; $tP = $tC
            if ($brAl.propia) { $mP = $brAl.propia.meses | Where-Object { $_.mes -eq $m } | Select-Object -First 1; if ($mP) { $tP = [double]$mP.central } }
            $cajasC = $tC*1000/$KG_CAJA; $cajasP = $tP*1000/$KG_CAJA
            $cajaA = [double]$pRow.caja + $spreadCaja
            $loC = $cajaA*[math]::Min($cajasC,$cajasP); $hiC = $cajaA*[math]::Max($cajasC,$cajasP)
            $costo += [PSCustomObject]([ordered]@{ mes=$m; estado=$pRow.estado; cajaCepea=$pRow.caja; cajaAlmar=[math]::Round($cajaA,0)
                cajasCuota=[math]::Round($cajasC,0); cajasPropia=[math]::Round($cajasP,0)
                brlLo=[math]::Round($loC,0); brlHi=[math]::Round($hiC,0); usdLo=[math]::Round($loC/$TC_USD,0); usdHi=[math]::Round($hiC/$TC_USD,0) })
            $cBrlLo += $loC; $cBrlHi += $hiC
        }
    }

    $fuentesInfo = [ordered]@{
        cepea   = "Cepea Norte SC (Nanica primeira), ultima semana $($data.ultima_semana)"
        penta   = "Penta Transaction, $([int]$pyboJ.registros) registros $(($pyboJ.anios | Sort-Object)[0])-$anioP2, corte $($pyboJ.corte), $(@($merJ.archivos).Count) extractos"
        plan    = $(if ($planJ) { "Plan de Cargas ($($planJ.archivo), bajado $($planJ.archivoFecha)), ultima carga BR $($planJ.porOrigen.BR.ultima)" } else { $null })
        cargas  = $(if ($data.almar) { "cargas 2026.xlsx, $([int]$data.almar.n_operaciones) camiones, ultima semana $($data.almar.ultima_fecha)" } else { $null })
        calidad = $(if ($calJ) { "calidad_lotes.xlsx: $([int]$calJ.n) lotes cargados, $([int]$calJ.nConResultado) con resultado" } else { $null })
    }

    $proyeccion = [ordered]@{
        generado    = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        anio        = $anioP2
        base        = [ordered]@{ ultima_semana=$data.ultima_semana; ultimo_precio=$data.ultimo_precio
                                  desvio=[math]::Round($devActual,3); phi=[math]::Round($phiDev,3); mesCur=$mesCur; mesPenta=$mesTope; ventanaV2=@($V2m) }
        supuestos   = [ordered]@{ tc=$TC_USD; kgCaja=$KG_CAJA; servCaja=$SERV_CAJA
                                  spreadCaja=[math]::Round($spreadCaja,2); spreadPct=[math]::Round($spreadPct,1); spreadSemanas=$spSemanas; spreadCargas=[math]::Round($spSumCargas,0) }
        fuentes     = $fuentesInfo
        mesesVolumen= @($mesesProy)
        precio      = $precioProy
        volumen     = [ordered]@{ origenes=$volOrig; meses=$volMeses; realTotal=@($realTotL.ToArray())
                                  central=[math]::Round($totC,0); lo=[math]::Round($totL,0); hi=[math]::Round($totH,0); actual=[math]::Round($totActual,0)
                                  usdMes=[math]::Round($totUsd,0); hist=$histTot }
        almar       = [ordered]@{ nombre=$almarNombre; shareTotal=[math]::Round($shareTot,4); actual=[math]::Round($aActual,0)
                                  origenes=$almOrig
                                  cuota=[ordered]@{ central=[math]::Round($aCuota.c,0); lo=[math]::Round($aCuota.l,0); hi=[math]::Round($aCuota.h,0); meses=$aCuotaMeses }
                                  propia=[ordered]@{ central=[math]::Round($aPropia.c,0); lo=[math]::Round($aPropia.l,0); hi=[math]::Round($aPropia.h,0); meses=$aPropiaMeses; fallback=@($propiaFallback) }
                                  comprometido=$comprom
                                  costoBR=$costo
                                  costoTotal=[ordered]@{ brlLo=[math]::Round($cBrlLo,0); brlHi=[math]::Round($cBrlHi,0); usdLo=[math]::Round($cBrlLo/$TC_USD,0); usdHi=[math]::Round($cBrlHi/$TC_USD,0) } }
    }
    $proyJson = $proyeccion | ConvertTo-Json -Depth 12 -Compress
    Set-Content -Path (Join-Path $fuentes "proyeccion.json") -Value $proyJson -Encoding UTF8
    $nReal = @($precioProy | Where-Object { $_.estado -eq 'real' }).Count
    Write-Host "    sidecar: fuentes\proyeccion.json (precio: $nReal meses reales + $(12-$nReal) proyectados; volumen: $($mesesProy.Count) meses, $($ORIGP.Count) origenes; spread Almar $([math]::Round($spreadCaja,1)) R`$/caja en $spSemanas semanas)" -ForegroundColor Green

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
    Write-Host "    ERROR en la proyeccion: $($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber))" -ForegroundColor Red
    if (Get-Command Add-Falla -ErrorAction SilentlyContinue) { Add-Falla -Paso 'Proyeccion (5d)' -Detalle $_.Exception.Message }
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
    $rIM = Invoke-WebRequest -UseBasicParsing -Uri 'https://www.indexmundi.com/commodities/?commodity=bananas&months=60' `
             -UserAgent $UA_BROWSER -Headers $HDR_BROWSER -TimeoutSec 40 -ErrorAction Stop
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
            corte=(NumCel $f 'corte_color')
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
            foreach ($v in @('tempPulpa','calibre','largo','tempCorte','lluvia','transito','corte')) {
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
# 5h) Plan de cargas: camiones, transito y faltantes por origen  [08/09/2026]
#
# Fuente: la planilla maestra del Plan de Cargas (OneDrive, la que el ERP
# espeja), bajada A MANO a `fuentes\plan_cargas\*.xlsx`. Se toma la mas nueva.
# Un camion por fila desde ene/2024. Alimenta el bloque "Plan de cargas" de
# index_brasil.html (origen BR) e index_paraguay_bolivia.html (origen PY) via
# marcadores propios /*__CARGAS_JSON__*/ ... /*__END_CARGAS__*/.
# Sin Excel COM: usa Read-XlsxHoja (definida en 5g).
#
# Trampas de la planilla, ya contempladas aca (verificadas 08/09/2026):
#   - NO es solo banana. "Varios", "Bahia + Exoticos" y "Exoticos PY" son
#     sandia, uva, melon, mango, papaya. Sus "Cajas MIC" (24.000-25.000) son
#     KILOS y "Cajas Desc" trae otra cosa. Metidos en la cuenta daban una
#     "merma" de 87.000 cajas que NO existe. Se excluyen por PRODUCTOR.
#   - La carpeta (BRB/BRE/PYB/BRA/BRC) NO sirve para filtrar producto: BRA y
#     BRC son banana (Nordeste, Vitor) y hay banana en carpetas BRE.
#   - "Cajas Desc" a veces trae un numero de secuencia (3686, 6708...) en vez
#     de las cajas. Se acepta solo si esta entre 50% y 115% del MIC.
#   - "CANT. DE PALLET", "Exportador" y "Productos" traen seriales de fecha o
#     secuencias en 2024-2025. No se usan.
#   - Fecha Descarga solo esta desde may/2025; el eje de tiempo es Fecha de
#     Carga (99,9% llena). TT = dias carga->descarga; se descartan <1 o >30.
#   - Paraguay no registra transportista (todo "0").
#   - Origen: productor "Paraguay *" o "* PY" = PY; "Bolivia *" = BO; frontera
#     Salto = PY si el productor no lo dice; el resto = BR (Bahia incluida).
# ==========================================================================
Write-Host "[5h] Plan de cargas (camiones, transito, faltantes)..." -ForegroundColor Cyan
$pcDir    = Join-Path $fuentes "plan_cargas"
$pcHtmlBR = Join-Path $base "index_brasil.html"
$pcHtmlPY = Join-Path $base "index_paraguay_bolivia.html"
$PC_EXOTICOS     = @('varios','bahia + exoticos','exoticos py')   # claves normalizadas (sin acento, minuscula)
$PC_MAX_CAJAS    = 2500     # mas que esto no es un camion de banana
$PC_TT_MIN       = 1; $PC_TT_MAX = 30
$PC_DESC_MIN     = 0.5; $PC_DESC_MAX = 1.15
$PC_FALTANTE_MIN = 5        # cajas de menos para contar como "evento"

function PC-Norm { param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $t = ([regex]::Replace($s, '\s+', ' ')).Trim()
    $d = $t.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    return $sb.ToString().ToLower()
}
function PC-Mediana { param($xs)
    $a = @($xs | Sort-Object); if ($a.Count -eq 0) { return $null }
    $m = [int][math]::Floor($a.Count / 2)
    if ($a.Count % 2 -eq 1) { return [double]$a[$m] } else { return [math]::Round(([double]$a[$m-1] + [double]$a[$m]) / 2, 1) }
}
function PC-P90 { param($xs)
    $a = @($xs | Sort-Object); if ($a.Count -eq 0) { return $null }
    $i = [int][math]::Ceiling(0.9 * $a.Count) - 1; if ($i -lt 0) { $i = 0 }
    return [double]$a[$i]
}
function PC-Sum { param($xs, [string]$p)
    $s = 0.0; foreach ($x in @($xs)) { $v = $x.$p; if ($null -ne $v) { $s += [double]$v } }; return $s
}
function PC-Viernes { param([datetime]$d)
    $lunes = $d.Date.AddDays(-((([int]$d.DayOfWeek + 6) % 7))); return $lunes.AddDays(4)
}

$pcXlsx = @()
if (Test-Path $pcDir) {
    $pcXlsx = @(Get-ChildItem $pcDir -Filter "*.xlsx" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '~$*' } | Sort-Object LastWriteTime -Descending)
}
if ($pcXlsx.Count -eq 0) {
    Write-Host "    (skip) no hay xlsx en fuentes\plan_cargas\ - tirar ahi la planilla del Plan de Cargas" -ForegroundColor DarkYellow
} else {
  try {
    $pcFile  = $pcXlsx[0]
    $pcFilas = Read-XlsxHoja -Path $pcFile.FullName -Hoja 'Cargas'
    if ($pcFilas.Count -lt 2) { throw "la hoja 'Cargas' de $($pcFile.Name) esta vacia o no existe" }
    $hdrIdx = -1
    for ($i = 0; $i -lt [math]::Min(15, $pcFilas.Count); $i++) {
        $j = (@($pcFilas[$i]) -join '|'); if ($j -match 'Status' -and $j -match 'Productor') { $hdrIdx = $i; break }
    }
    if ($hdrIdx -lt 0) { throw "no encontre la fila de encabezados (Status/Productor) en la hoja Cargas" }
    $hdr = @($pcFilas[$hdrIdx])
    function PC-Col { param($rx) for ($k = 0; $k -lt $hdr.Count; $k++) { if (([string]$hdr[$k]) -match $rx) { return $k } }; return -1 }
    $cSt = PC-Col '^\s*Status';        $cPr  = PC-Col '^\s*Productor';   $cFc  = PC-Col 'Fecha\s*de\s*Carga'
    $cCa = PC-Col 'Carpeta';           $cTr  = PC-Col 'Transportista';   $cFr  = PC-Col '^\s*Frontera'
    $cFd = PC-Col 'Fecha\s*Desc';      $cTT  = PC-Col '^\s*TT';          $cMic = PC-Col 'Cajas\s*MIC'
    $cDes = PC-Col 'Cajas\s*Desc';     $cOb  = PC-Col 'Observ';          $cProd = PC-Col '^\s*Productos'
    foreach ($need in @(@('Status',$cSt),@('Productor',$cPr),@('Fecha de Carga',$cFc),@('Cajas MIC',$cMic),@('Cajas Desc',$cDes),@('TT',$cTT))) {
        if ($need[1] -lt 0) { throw "falta la columna '$($need[0])' en la hoja Cargas" }
    }
    function PC-Cel { param($f, $c) if ($c -ge 0 -and $c -lt $f.Count) { return ([regex]::Replace([string]$f[$c], '\s+', ' ')).Trim() } else { return '' } }
    function PC-Num { param($s)
        $o = 0.0
        if ([double]::TryParse(([string]$s), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$o)) { return $o }
        return $null
    }
    function PC-Fecha { param($s) $o = PC-Num $s; if ($null -ne $o -and $o -gt 40000 -and $o -lt 60000) { return [DateTime]::FromOADate($o) }; return $null }
    $PC_SIN = @('', '0', 'xx', '#n/a', '#ref!', '-')

    $ops = @()
    $exc = [ordered]@{ cancelados = 0; otrasFrutas = 0; sinFecha = 0; sinStatus = 0; noCamion = 0 }
    $nombreVariantes = @{}
    for ($r = $hdrIdx + 1; $r -lt $pcFilas.Count; $r++) {
        $f = @($pcFilas[$r])
        $st = PC-Cel $f $cSt; $prRaw = PC-Cel $f $cPr
        if (-not $st -and -not $prRaw) { continue }
        if (-not $st) { $exc.sinStatus++; continue }
        if ($st -match '^Cancelado') { $exc.cancelados++; continue }
        $key = PC-Norm $prRaw
        if (-not $key) { $exc.sinStatus++; continue }
        if ($PC_EXOTICOS -contains $key -or $key -match 'exotic') { $exc.otrasFrutas++; continue }
        $prodCol = PC-Cel $f $cProd
        if ($prodCol -match '(?i)palta|sand|uva|mel[oó]n|mango|papaya|morr|^mix') { $exc.otrasFrutas++; continue }
        $fc = PC-Fecha (PC-Cel $f $cFc)
        if (-not $fc) { $exc.sinFecha++; continue }
        $mic = PC-Num (PC-Cel $f $cMic)
        if ($null -ne $mic -and $mic -gt $PC_MAX_CAJAS) { $exc.noCamion++; continue }
        $des = PC-Num (PC-Cel $f $cDes)
        $descValido = ($null -ne $mic -and $mic -gt 0 -and $null -ne $des -and $des -ge $PC_DESC_MIN * $mic -and $des -le $PC_DESC_MAX * $mic)
        $tt = PC-Num (PC-Cel $f $cTT)
        $ttOk = ($st -match '^Descargado' -and $null -ne $tt -and $tt -ge $PC_TT_MIN -and $tt -le $PC_TT_MAX)
        $fr = PC-Cel $f $cFr; if ($PC_SIN -contains $fr.ToLower()) { $fr = 'sin dato' }; if ($fr -match '^Chui') { $fr = 'Chuy' }
        $tr = PC-Cel $f $cTr; if ($PC_SIN -contains $tr.ToLower()) { $tr = 'sin dato' } else { $tr = Get-TransportistaCanon $tr }
        $orig = 'BR'
        if ($key -match '^paraguay|\spy$') { $orig = 'PY' } elseif ($key -match '^bolivia') { $orig = 'BO' } elseif ($fr -eq 'Salto') { $orig = 'PY' }
        if (-not $nombreVariantes.ContainsKey($key)) { $nombreVariantes[$key] = @{} }
        if (-not $nombreVariantes[$key].ContainsKey($prRaw)) { $nombreVariantes[$key][$prRaw] = 0 }
        $nombreVariantes[$key][$prRaw]++
        $fd = PC-Fecha (PC-Cel $f $cFd)
        $ops += [PSCustomObject]@{
            status = $st; key = $key; origen = $orig
            fecha = $fc; anio = $fc.Year; mes = $fc.Month; doy = $fc.DayOfYear
            viernes = (PC-Viernes $fc).ToString('yyyy-MM-dd')
            carpeta = (PC-Cel $f $cCa); frontera = $fr; transportista = $tr
            fechaDesc = $fd
            tt = $(if ($ttOk) { $tt } else { $null })
            mic = $mic
            desc = $(if ($descValido) { $des } else { $null })
            descInvalido = (-not $descValido -and $null -ne $des)
            faltante = $(if ($descValido) { $mic - $des } else { $null })
        }
    }
    # Nombre para mostrar: la variante mas frecuente; si venia todo en MAYUSCULAS, a Titulo.
    $nombre = @{}
    $ti = [Globalization.CultureInfo]::GetCultureInfo('es-UY').TextInfo
    foreach ($k in $nombreVariantes.Keys) {
        $best = ($nombreVariantes[$k].GetEnumerator() | Sort-Object @{Expression='Value';Descending=$true}, @{Expression='Key'} | Select-Object -First 1).Key
        if ($best.Length -gt 3 -and $best -ceq $best.ToUpper()) { $best = $ti.ToTitleCase($best.ToLower()) }
        $nombre[$k] = $best
    }

    # ---- Precio por camion desde cargas 2026.xlsx (paso 3, $almarRecords: productor + semana + R$/caja).
    #      Los nombres de esa planilla son apodos con typos ("Fisher", "Jony", "Agrocurupa"); se
    #      resuelven con alias explicitos + reglas genericas (token igual, prefijo, 1 letra de
    #      diferencia) y SOLO si el candidato es unico. Lo que no cruza se informa en el panel.
    #      OJO: no usar $matches como variable propia — es la automatica de -match y se pisa.
    $PC_ALIAS = @{
        'fisher'='fischer'; 'agrocurupa'='corupa'; 'agro curupa'='corupa'; 'curupa'='corupa'
        'jony'='jhony viera'; 'jhony'='jhony viera'; 'jony viera'='jhony viera'
        'ivo zimer'='ivo zimerman'; 'ivo'='ivo zimerman'
        'joao vinter'='joao claudio winter'; 'joao winter'='joao claudio winter'; 'winter'='joao claudio winter'; 'vinter'='joao claudio winter'
        'zapelini'='zapellini'; 'waguiner'='wagner schveitzer'; 'wagner'='wagner schveitzer'; 'furkani'='furlani'
        'stein'='osnildo stein'; 'marconi'='marconi kons'; 'marangoni'='jorge marangoni'; 'josemar'='josemar provesi'; 'cassio'='cassio hauck'
    }
    $PC_PRECIO_MAX = 150   # R$/caja: arriba de esto es un typo (hubo un 299 en Agrocurupa)
    function PC-Lev { param([string]$a, [string]$b)
        if ($a -eq $b) { return 0 }
        $la = $a.Length; $lb = $b.Length
        if ($la -eq 0) { return $lb }; if ($lb -eq 0) { return $la }
        $prev = @(0..$lb)
        for ($i = 1; $i -le $la; $i++) {
            $cur = @($i) + @(@(0) * $lb)
            for ($j = 1; $j -le $lb; $j++) {
                $cost = if ($a[$i-1] -eq $b[$j-1]) { 0 } else { 1 }
                $cur[$j] = [math]::Min([math]::Min($cur[$j-1] + 1, $prev[$j] + 1), $prev[$j-1] + $cost)
            }
            $prev = $cur
        }
        return $prev[$lb]
    }
    $planKeys = @($nombreVariantes.Keys)
    function PC-ResolverNombre { param([string]$raw)
        $k = PC-Norm $raw
        if (-not $k) { return $null }
        if ($planKeys -contains $k) { return @{ key = $k; regla = 'exacto' } }
        if ($PC_ALIAS.ContainsKey($k) -and ($planKeys -contains $PC_ALIAS[$k])) { return @{ key = $PC_ALIAS[$k]; regla = 'alias' } }
        $toks = @(($k -split ' ') | Where-Object { $_.Length -ge 4 })
        $cands = @()
        foreach ($pk in $planKeys) {
            $hit = $false
            foreach ($t in $toks) {
                foreach ($pt in @($pk -split ' ')) {
                    if ($pt -eq $t -or ($pt.StartsWith($t) -and $t.Length -ge 4) -or ($t.Length -ge 5 -and $pt.Length -ge 5 -and (PC-Lev $t $pt) -le 1)) { $hit = $true }
                }
            }
            if ($hit) { $cands += $pk }
        }
        $cands = @($cands | Select-Object -Unique)
        if ($cands.Count -eq 1) { return @{ key = $cands[0]; regla = 'parecido' } }
        if ($cands.Count -gt 1) { return @{ key = $null; regla = ('ambiguo entre ' + (($cands | ForEach-Object { $nombre[$_] }) -join ' / ')) } }
        return $null
    }
    $cepeaCaja = @{}   # viernes -> R$/caja equivalente (Cepea cacho x kg neto + servicios)
    if ($data.serie) { foreach ($s in $data.serie) { $cepeaCaja[[string]$s.fecha] = [double]$s.precio * $KG_CAJA_NETO + $SERVICIOS_CAJA } }
    $precioLookup = @{}   # "key|viernes" -> @{ suma; n }
    $pcMatches = [ordered]@{}; $pcSinMatch = [ordered]@{}; $pcPreciosRaros = 0
    foreach ($ar in @($almarRecords)) {
        if (-not $ar.fecha) { continue }
        if ($ar.precio -le 0 -or $ar.precio -gt $PC_PRECIO_MAX) { $pcPreciosRaros++; continue }
        $rawN = ([regex]::Replace([string]$ar.productor, '\s+', ' ')).Trim()
        $res = PC-ResolverNombre $rawN
        if (-not $res -or -not $res.key) {
            if (-not $pcSinMatch.Contains($rawN)) { $pcSinMatch[$rawN] = [ordered]@{ nombre = $rawN; cargas = 0.0; motivo = $(if ($res) { $res.regla } else { 'no figura en el Plan de Cargas' }) } }
            $pcSinMatch[$rawN].cargas += [double]$ar.cargas
            continue
        }
        if (-not $pcMatches.Contains($rawN)) { $pcMatches[$rawN] = [ordered]@{ cargas = $rawN; plan = $nombre[$res.key]; regla = $res.regla } }
        $v = PC-Viernes ([datetime]::ParseExact([string]$ar.fecha, 'yyyy-MM-dd', $null))
        $lk = $res.key + '|' + $v.ToString('yyyy-MM-dd')
        if (-not $precioLookup.ContainsKey($lk)) { $precioLookup[$lk] = @{ suma = 0.0; n = 0.0 } }
        $precioLookup[$lk].suma += [double]$ar.precio * [double]$ar.cargas
        $precioLookup[$lk].n += [double]$ar.cargas
    }
    # cada camion toma el precio de su productor en su semana de carga (o la vecina, +-1 semana)
    foreach ($op in $ops) {
        $p = $null
        $v0 = [datetime]::ParseExact($op.viernes, 'yyyy-MM-dd', $null)
        foreach ($dd in 0, -7, 7) {
            $lk = $op.key + '|' + $v0.AddDays($dd).ToString('yyyy-MM-dd')
            if ($precioLookup.ContainsKey($lk) -and $precioLookup[$lk].n -gt 0) { $p = [math]::Round($precioLookup[$lk].suma / $precioLookup[$lk].n, 2); break }
        }
        $cc = $null; if ($cepeaCaja.ContainsKey($op.viernes)) { $cc = [math]::Round($cepeaCaja[$op.viernes], 2) }
        $op | Add-Member -NotePropertyName precio -NotePropertyValue $p -Force
        $op | Add-Member -NotePropertyName cepeaCaja -NotePropertyValue $cc -Force
    }
    function PC-PrecioInfo { param($lista)
        $cp = @($lista | Where-Object { $null -ne $_.precio })
        if ($cp.Count -eq 0) { return $null }
        $sum = 0.0; $gasto = 0.0; $mn = [double]::MaxValue; $mx = 0.0; $spS = 0.0; $spN = 0
        foreach ($x in $cp) {
            $sum += $x.precio; if ($x.precio -lt $mn) { $mn = $x.precio }; if ($x.precio -gt $mx) { $mx = $x.precio }
            if ($x.mic) { $gasto += $x.precio * $x.mic }
            if ($null -ne $x.cepeaCaja -and $x.cepeaCaja -gt 0) { $spS += ($x.precio - $x.cepeaCaja) / $x.cepeaCaja * 100; $spN++ }
        }
        return [ordered]@{
            n = $cp.Count; anio = ((@($cp | ForEach-Object { $_.anio } | Sort-Object -Unique)) -join '/')
            prom = [math]::Round($sum / $cp.Count, 2); min = $mn; max = $mx
            spread = $(if ($spN) { [math]::Round($spS / $spN, 1) } else { $null })
            gasto = [math]::Round($gasto, 0)
        }
    }
    function PC-Resumen { param($lista)
        $desc = @($lista | Where-Object { $_.status -match '^Descargado' })
        $ttv  = @($desc | Where-Object { $null -ne $_.tt } | ForEach-Object { $_.tt })
        $conDesc = @($desc | Where-Object { $null -ne $_.faltante })
        $micV = PC-Sum $conDesc 'mic'; $desV = PC-Sum $conDesc 'desc'
        $anios = @($desc | Select-Object -ExpandProperty anio -Unique | Sort-Object)
        $porAnio = [ordered]@{}
        foreach ($a in $anios) {
            $da = @($desc | Where-Object { $_.anio -eq $a }); $cd = @($da | Where-Object { $null -ne $_.faltante })
            $m = PC-Sum $cd 'mic'; $d = PC-Sum $cd 'desc'; $cajas = PC-Sum $da 'mic'
            $porAnio["$a"] = [ordered]@{
                camiones = $da.Count; cajas = [math]::Round($cajas, 0)
                cajasPorCamion = $(if ($da.Count) { [math]::Round($cajas / $da.Count, 0) } else { 0 })
                ttMediana = (PC-Mediana @($da | Where-Object { $null -ne $_.tt } | ForEach-Object { $_.tt }))
                faltante = [math]::Round($m - $d, 0); faltantePct = $(if ($m) { [math]::Round(($m - $d) / $m * 100, 2) } else { 0 })
                eventos = @($cd | Where-Object { $_.faltante -ge $PC_FALTANTE_MIN }).Count
                mensualCajas = @(1..12 | ForEach-Object { $mm = $_; [math]::Round((PC-Sum @($da | Where-Object { $_.mes -eq $mm }) 'mic'), 0) })
                mensualCamiones = @(1..12 | ForEach-Object { $mm = $_; @($da | Where-Object { $_.mes -eq $mm }).Count })
            }
        }
        $ytd = $null
        if ($anios.Count -ge 1) {
            $aMax = $anios[-1]
            $ult = ($desc | Where-Object { $_.anio -eq $aMax } | Sort-Object fecha | Select-Object -Last 1)
            $cur = @($desc | Where-Object { $_.anio -eq $aMax }); $prev = @($desc | Where-Object { $_.anio -eq ($aMax - 1) -and $_.doy -le $ult.doy })
            $ytd = [ordered]@{ anio = $aMax; corte = $ult.fecha.ToString('yyyy-MM-dd'); camiones = $cur.Count; cajas = [math]::Round((PC-Sum $cur 'mic'), 0)
                               anioPrev = ($aMax - 1); camionesPrev = $prev.Count; cajasPrev = [math]::Round((PC-Sum $prev 'mic'), 0) }
        }
        $semanal = @($desc | Group-Object viernes | Sort-Object Name | ForEach-Object {
            [ordered]@{ fecha = $_.Name; camiones = $_.Count; cajas = [math]::Round((PC-Sum $_.Group 'mic'), 0) } })
        # Ficha del productor (fuentes\productores.xlsx, hoja 'productores', leida en el paso 3 en $almarFichas /
        # $almarAliases): se cuelga de cada productor del Plan por nombre canonico o alias, para abrirla desde la
        # tabla de productores de index_paraguay_bolivia.html (los de Brasil ya la tienen en el ranking de cargas 2026). [15/09/2026]
        function PC-Ficha { param([string]$n)
            if (-not $n -or $null -eq $almarFichas) { return $null }
            $k = $n.ToLower().Trim()
            if ($null -ne $almarAliases -and $almarAliases.ContainsKey($k)) { $k = ([string]$almarAliases[$k]).ToLower().Trim() }
            if ($almarFichas.ContainsKey($k)) { return $almarFichas[$k] }
            return $null
        }
        $productores = @()
        foreach ($g in ($desc | Group-Object key)) {
            $cd = @($g.Group | Where-Object { $null -ne $_.faltante })
            $m = PC-Sum $cd 'mic'; $d = PC-Sum $cd 'desc'; $cajas = PC-Sum $g.Group 'mic'
            $pa = [ordered]@{}; foreach ($a in $anios) { $pa["$a"] = @($g.Group | Where-Object { $_.anio -eq $a }).Count }
            $pm = [ordered]@{}; foreach ($a in $anios) { $pm["$a"] = @(1..12 | ForEach-Object { $mm = $_; @($g.Group | Where-Object { $_.anio -eq $a -and $_.mes -eq $mm }).Count }) }   # camiones por mes (09/09/2026, tabla productor x mes)
            $ordF = @($g.Group | Sort-Object fecha)
            $frP = ($g.Group | Group-Object frontera | Sort-Object Count -Descending | Select-Object -First 1).Name
            $trP = ($g.Group | Where-Object { $_.transportista -ne 'sin dato' } | Group-Object transportista | Sort-Object Count -Descending | Select-Object -First 1).Name
            $productores += [ordered]@{
                nombre = $nombre[$g.Name]; camiones = $g.Count; cajas = [math]::Round($cajas, 0)
                cajasPorCamion = [math]::Round($cajas / $g.Count, 0); porAnio = $pa; porMes = $pm
                ttMediana = (PC-Mediana @($g.Group | Where-Object { $null -ne $_.tt } | ForEach-Object { $_.tt }))
                faltante = [math]::Round($m - $d, 0); faltantePct = $(if ($m) { [math]::Round(($m - $d) / $m * 100, 2) } else { $null })
                eventos = @($cd | Where-Object { $_.faltante -ge $PC_FALTANTE_MIN }).Count; conDesc = $cd.Count
                primera = $ordF[0].fecha.ToString('yyyy-MM-dd'); ultima = $ordF[-1].fecha.ToString('yyyy-MM-dd')
                frontera = $frP; transportista = $(if ($trP) { $trP } else { 'sin dato' })
                precio = (PC-PrecioInfo $g.Group)
                ficha = (PC-Ficha $nombre[$g.Name])
                ult4sem = $(if ($ult) { @($g.Group | Where-Object { $_.fecha -ge $ult.fecha.AddDays(-28) }).Count } else { $null })   # camiones en las ultimas 4 semanas del Plan (estado del ranking) [15/09/2026]
            }
        }
        $productores = @($productores | Sort-Object @{Expression={ $_.camiones };Descending=$true}, @{Expression={ $_.nombre }})
        $fronteras = @()
        foreach ($g in ($desc | Group-Object frontera | Sort-Object Count -Descending)) {
            $t = @($g.Group | Where-Object { $null -ne $_.tt } | ForEach-Object { $_.tt })
            $pa = [ordered]@{}; foreach ($a in $anios) { $pa["$a"] = @($g.Group | Where-Object { $_.anio -eq $a }).Count }
            $fronteras += [ordered]@{ nombre = $g.Name; camiones = $g.Count; ttMediana = (PC-Mediana $t); ttP90 = (PC-P90 $t)
                                      ttProm = $(if ($t.Count) { [math]::Round(($t | Measure-Object -Average).Average, 1) } else { $null }); porAnio = $pa }
        }
        $transportistas = @()
        foreach ($g in ($desc | Group-Object transportista | Sort-Object Count -Descending)) {
            $cd = @($g.Group | Where-Object { $null -ne $_.faltante })
            $m = PC-Sum $cd 'mic'; $d = PC-Sum $cd 'desc'
            $t = @($g.Group | Where-Object { $null -ne $_.tt } | ForEach-Object { $_.tt })
            $transportistas += [ordered]@{ nombre = $g.Name; camiones = $g.Count; ttMediana = (PC-Mediana $t); ttP90 = (PC-P90 $t)
                faltante = [math]::Round($m - $d, 0); faltantePct = $(if ($m) { [math]::Round(($m - $d) / $m * 100, 2) } else { $null })
                eventos = @($cd | Where-Object { $_.faltante -ge $PC_FALTANTE_MIN }).Count
                ultima = (@($g.Group | Sort-Object fecha)[-1]).fecha.ToString('yyyy-MM-dd') }
        }
        $enCamino = @($lista | Where-Object { $_.status -match '^(Cargado|Frontera|Puerto|Liberado|Arribado|Confirmado)' } | Sort-Object fecha | ForEach-Object {
            [ordered]@{ status = $_.status; productor = $nombre[$_.key]; fecha = $_.fecha.ToString('yyyy-MM-dd'); cajas = $_.mic
                        transportista = $_.transportista; frontera = $_.frontera
                        descPrevista = $(if ($_.fechaDesc) { $_.fechaDesc.ToString('yyyy-MM-dd') } else { $null }) } })
        $programados = @($lista | Where-Object { $_.status -match '^Solicitado' } | Sort-Object fecha | ForEach-Object {
            [ordered]@{ productor = $nombre[$_.key]; fecha = $_.fecha.ToString('yyyy-MM-dd'); cajas = $_.mic } })
        $conP = @($desc | Where-Object { $null -ne $_.precio })
        $anioP = $null; if ($conP.Count) { $anioP = ($conP | Measure-Object anio -Maximum).Maximum }
        $precioResumen = PC-PrecioInfo $desc
        if ($precioResumen) {
            $precioResumen['anioMax'] = $anioP
            $precioResumen['camionesAnio'] = @($desc | Where-Object { $_.anio -eq $anioP }).Count
            $precioResumen['conPrecio'] = $conP.Count
        }
        $ordD = @($desc | Sort-Object fecha)
        return [ordered]@{
            camiones = $desc.Count; cajas = [math]::Round((PC-Sum $desc 'mic'), 0)
            primera = $(if ($desc.Count) { $ordD[0].fecha.ToString('yyyy-MM-dd') } else { $null })
            ultima  = $(if ($desc.Count) { $ordD[-1].fecha.ToString('yyyy-MM-dd') } else { $null })
            ttMediana = (PC-Mediana $ttv); ttP90 = (PC-P90 $ttv); ttValidos = $ttv.Count
            faltante = [math]::Round($micV - $desV, 0); faltantePct = $(if ($micV) { [math]::Round(($micV - $desV) / $micV * 100, 2) } else { 0 })
            eventos = @($conDesc | Where-Object { $_.faltante -ge $PC_FALTANTE_MIN }).Count; conDesc = $conDesc.Count
            descInvalidos = @($desc | Where-Object { $_.descInvalido }).Count
            ttDescartados = @($desc | Where-Object { $null -eq $_.tt }).Count
            anios = @($anios | ForEach-Object { "$_" }); porAnio = $porAnio; ytd = $ytd; semanal = $semanal
            productores = $productores; fronteras = $fronteras; transportistas = $transportistas
            enCamino = $enCamino; programados = $programados; precioResumen = $precioResumen
        }
    }

    $origenes  = @($ops | Select-Object -ExpandProperty origen -Unique | Sort-Object)
    $porOrigen = [ordered]@{}
    foreach ($o in $origenes) { $porOrigen[$o] = PC-Resumen @($ops | Where-Object { $_.origen -eq $o }) }
    $descTot = @($ops | Where-Object { $_.status -match '^Descargado' })
    $planCargas = [ordered]@{
        generado     = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        archivo      = $pcFile.Name
        archivoFecha = $pcFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        archivoDias  = [int][math]::Round(((Get-Date) - $pcFile.LastWriteTime).TotalDays, 0)
        filas        = ($pcFilas.Count - $hdrIdx - 1)
        camionesBanana = $ops.Count; descargados = $descTot.Count
        fichasArchivo = 'fuentes\productores.xlsx'; nFichas = $(if ($almarFichas) { $almarFichas.Count } else { 0 })   # fichas colgadas por productor (PC-Ficha) [15/09/2026]
        excluidos    = $exc
        reglas       = @(
            'Un camion por fila. Solo banana: se excluyen por productor "Varios", "Bahia + Exoticos" y "Exoticos PY" (sandia, uva, melon, mango, papaya).',
            'Eje de tiempo = Fecha de Carga (la de descarga solo existe desde may/2025).',
            "Transito (TT) = dias de carga a descarga; se descartan valores fuera de $PC_TT_MIN-$PC_TT_MAX.",
            "Cajas descargadas validas solo entre $([int]($PC_DESC_MIN*100))% y $([int]($PC_DESC_MAX*100))% del MIC (la columna a veces trae un numero de secuencia).",
            "Faltante = MIC - descargadas. Un evento es un camion con $PC_FALTANTE_MIN o mas cajas de menos.",
            'Origen: productor "Paraguay *" o "* PY" = Paraguay; "Bolivia *" = Bolivia; frontera Salto = Paraguay; el resto Brasil (Bahia y Nordeste incluidos).'
        )
        origenes  = $origenes
        porOrigen = $porOrigen
        precios   = [ordered]@{ fuente = 'fuentes\cargas 2026.xlsx (paso 3)'; registros = @($almarRecords).Count; descartados = $pcPreciosRaros; maxValido = $PC_PRECIO_MAX; cruzados = @($pcMatches.Values); sinCruzar = @($pcSinMatch.Values) }
    }
    $pcJson = $planCargas | ConvertTo-Json -Depth 12 -Compress
    Set-Content -Path (Join-Path $fuentes "plan_cargas.json") -Value $pcJson -Encoding UTF8
    $resumenOr = ($origenes | ForEach-Object { "$_=$($porOrigen[$_].camiones)" }) -join ' '
    Write-Host "    sidecar: fuentes\plan_cargas.json ($($descTot.Count) camiones banana descargados: $resumenOr | excluidos: $($exc.cancelados) cancelados, $($exc.otrasFrutas) otras frutas, $($exc.noCamion) no-camion, $($exc.sinFecha) sin fecha)" -ForegroundColor Green
    Write-Host "    precios: $($pcMatches.Count) nombres cruzados con el Plan, $($pcSinMatch.Count) sin cruzar ($((@($pcSinMatch.Values) | ForEach-Object { $_.nombre }) -join ', ')), $pcPreciosRaros precios descartados (> R$ $PC_PRECIO_MAX)" -ForegroundColor Green
    foreach ($tgt in @($pcHtmlBR, $pcHtmlPY)) {
        if (-not (Test-Path $tgt)) { Write-Host "    (aviso) falta $(Split-Path $tgt -Leaf)" -ForegroundColor DarkYellow; continue }
        $hTxt = Get-Content $tgt -Raw -Encoding UTF8
        $patC = '/\*__CARGAS_JSON__\*/.*?/\*__END_CARGAS__\*/'
        $nC = ([regex]::Matches($hTxt, $patC, 'Singleline')).Count
        if ($nC -ne 1) { Write-Host "    (skip) $(Split-Path $tgt -Leaf): esperaba 1 par de marcadores CARGAS, hay $nC" -ForegroundColor Red; continue }
        $repC = '/*__CARGAS_JSON__*/' + $pcJson + '/*__END_CARGAS__*/'
        Set-Content -Path $tgt -Value ([regex]::Replace($hTxt, $patC, { param($m) $repC }, 'Singleline')) -Encoding UTF8 -NoNewline
        Write-Host "    OK $(Split-Path $tgt -Leaf)" -ForegroundColor Green
    }
  } catch {
    Add-Falla -Paso 'Plan de cargas (planilla)' -Detalle $_.Exception.Message
  }
}

# ==========================================================================
# 5i) Saldo por dia y plan de cargas semanal (index_cargas.html)  [15/09/2026]
#
# Fuente: fuentes\plan_semanal\plan_semanal.xlsx, llenada A MANO con la foto
# diaria del plan de camaras de maduracion y el master del Plan de Cargas:
#   - parametros : ventas_semana (plan de ventas BR+PY+BO, lun-sab), cajas por
#                  camion, transitos por origen, dias descarga->gas, dias de
#                  camara (gas->venta), cubiculos gasificados por dia.
#   - camaras    : una fila por cubiculo de la foto (foto, cub, cam, origen,
#                  cantidad, dia_gas, dia_venta). Se usa SOLO la foto mas nueva.
#   - en_camino  : camiones llegados sin gas, en ruta, programados o
#                  solicitados (origen, cajas, estado, fecha_carga,
#                  fecha_llegada, confirmado). confirmado=0 se muestra aparte.
# + fuentes\stock\stock_diario.xlsx (Stock kg del ERP por origen y dia).
# Sin Excel COM: Read-XlsxHoja (definida en 5g).
#
# Calculo, por dia de venta (lunes a sabado, desde el dia de la foto):
#   venta plan = ventas_semana / dias_venta (el dia de la foto se descuenta la
#   parte ya vendida); oferta = gasificado (foto, por DIA SEM) + llegado sin
#   gas + en camino (cola de gasificacion a gas_por_dia cubiculos por dia,
#   venta = gas + camara); saldo acumulado; camiones a cargar = lo que falta
#   dividido cajas_camion; fecha de carga = venta - camara - desc_gas -
#   transito - aduana, por origen.
# Sidecar fuentes\plan_semanal.json; marcadores /*__PLAN_JSON__*/ ... /*__END_PLAN__*/.
# ==========================================================================
Write-Host "[5i] Saldo por dia y plan de cargas..." -ForegroundColor Cyan
$psXlsx  = Join-Path $fuentes "plan_semanal\plan_semanal.xlsx"
$psStock = Join-Path $fuentes "stock\stock_diario.xlsx"
$psHtml  = Join-Path $base "index_cargas.html"

if (-not (Test-Path $psXlsx)) {
    Write-Host "    (skip) falta fuentes\plan_semanal\plan_semanal.xlsx" -ForegroundColor DarkYellow
} else {
  try {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    function PsFecha { param($v)
        if ($null -eq $v) { return $null }
        $s = ([string]$v).Trim(); if (-not $s) { return $null }
        $d = 0.0
        if ($s -match '^\d+(\.\d+)?$' -and [double]::TryParse($s, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return [DateTime]::FromOADate($d).Date }
        foreach ($f in @('yyyy-MM-dd','dd/MM/yyyy','d/M/yyyy','dd-MM-yy','dd-MM-yyyy','yyyy-MM-dd HH:mm')) {
            $o = [DateTime]::MinValue
            if ([DateTime]::TryParseExact($s, $f, $inv, [Globalization.DateTimeStyles]::None, [ref]$o)) { return $o.Date }
        }
        return $null
    }
    function PsNum { param($v)
        $s = ([string]$v).Trim() -replace ',', '.'
        $d = 0.0
        if ($s -and [double]::TryParse($s, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d }
        return $null
    }
    function PsTabla { param($filas)
        # filas crudas de Read-XlsxHoja -> hashtables por nombre de columna (encabezado en la fila 1)
        $out = @(); if (-not $filas -or $filas.Count -lt 2) { return $out }
        $h = @(@($filas[0]) | ForEach-Object { ([string]$_).Trim() })
        for ($i = 1; $i -lt $filas.Count; $i++) {
            $f = @($filas[$i]); $o = @{}; $vacia = $true
            for ($j = 0; $j -lt $h.Count; $j++) {
                if (-not $h[$j]) { continue }
                $v = if ($j -lt $f.Count) { [string]$f[$j] } else { '' }
                $o[$h[$j]] = $v; if ($v.Trim()) { $vacia = $false }
            }
            if (-not $vacia) { $out += ,$o }
        }
        return $out
    }
    function PsYmd { param($d) if ($d) { $d.ToString('yyyy-MM-dd') } else { $null } }
    function PsLlegada { param($v)
        # Excel convierte '05/09' en fecha: si viene serial, mostrar dd/MM; si es texto ('04/09 y 05/09'), dejarlo
        $s = ([string]$v).Trim(); if ($s -match '^\d+(\.\d+)?$') { $f = PsFecha $s; if ($f) { return $f.ToString('dd/MM') } }; return $s
    }

    # ---- parametros (con defaults por si falta alguno) ----
    $P = @{ ventas_semana=16000; dias_venta=6; cajas_camion=1250; tr_BR=3; tr_PY=4; tr_BO=6; ad_BR=2; ad_PY=1; ad_BO=1
            desc_gas=2; camara=5; gas_por_dia=2; foto_fraccion_vendida=0.5; horizonte_dias=21; mix_BR=0.65; mix_PY=0.30; mix_BO=0.05 }
    foreach ($row in @(PsTabla (Read-XlsxHoja -Path $psXlsx -Hoja 'parametros'))) {
        $k = ([string]$row['parametro']).Trim(); $v = PsNum $row['valor']
        if ($k -and $null -ne $v) { $P[$k] = $v }
    }
    if ($P.dias_venta -le 0) { $P.dias_venta = 6 }
    if ($P.gas_por_dia -lt 1) { $P.gas_por_dia = 1 }
    $ventaDia = $P.ventas_semana / $P.dias_venta

    # ---- camaras: solo la foto mas nueva ----
    $cam = @()
    foreach ($r in @(PsTabla (Read-XlsxHoja -Path $psXlsx -Hoja 'camaras'))) {
        $fo = PsFecha $r['foto']; $q = PsNum $r['cantidad']
        if (-not $fo -or $null -eq $q) { continue }
        $cam += [PSCustomObject]@{ foto=$fo; cub=([string]$r['cub']).Trim(); cam=([string]$r['cam']).Trim(); origen=([string]$r['origen']).Trim().ToUpper()
            cantidad=[int][math]::Round($q); gas=(PsFecha $r['dia_gas']); venta=(PsFecha $r['dia_venta']); llegada=(PsLlegada $r['llegada']); nota=([string]$r['nota']).Trim() }
    }
    if ($cam.Count -eq 0) { throw "la hoja 'camaras' no tiene filas con foto y cantidad" }
    $fotoFecha = ($cam | Sort-Object foto -Descending | Select-Object -First 1).foto
    $camHoy = @($cam | Where-Object { $_.foto -eq $fotoFecha })
    $fotosHist = @($cam | ForEach-Object { PsYmd $_.foto } | Sort-Object -Unique)

    # ---- cola de gasificacion: lo de la foto sin dia de venta + en_camino ----
    $cola = @()
    foreach ($c in $camHoy) {
        if ($c.venta) { continue }
        $cola += [PSCustomObject]@{ origen=$c.origen; cajas=$c.cantidad; estado='llegado'; disp=$fotoFecha.AddDays(1); carga=$null; llegada=$null; confirmado=1
            desc=("CUB " + $c.cub + " camion " + $c.cam + " (foto, sin gas)") }
    }
    foreach ($r in @(PsTabla (Read-XlsxHoja -Path $psXlsx -Hoja 'en_camino'))) {
        $q = PsNum $r['cajas']; if ($null -eq $q -or $q -le 0) { continue }
        $orig = ([string]$r['origen']).Trim().ToUpper()
        $est = ([string]$r['estado']).Trim().ToLower(); if (-not $est) { $est = 'en_camino' }
        $carga = PsFecha $r['fecha_carga']; $lleg = PsFecha $r['fecha_llegada']
        if (-not $lleg) {
            if ($carga) {
                $tr = $P["tr_$orig"]; $ad = $P["ad_$orig"]
                if ($null -eq $tr) { $tr = 3 }; if ($null -eq $ad) { $ad = 1 }
                $lleg = $carga.AddDays($tr + $ad)
            } else { $lleg = $fotoFecha }
        }
        $conf = PsNum $r['confirmado']; $conf = if ($null -eq $conf) { 1 } else { [int]$conf }
        $disp = $lleg.AddDays($P.desc_gas); if ($disp -lt $fotoFecha.AddDays(1)) { $disp = $fotoFecha.AddDays(1) }
        $cola += [PSCustomObject]@{ origen=$orig; cajas=[int][math]::Round($q); estado=$est; disp=$disp; carga=$carga; llegada=$lleg; confirmado=$conf; desc=([string]$r['nota']).Trim() }
    }
    function PsAsignar { param($items)
        # reparte los cubiculos en dias de gas (gas_por_dia por dia) en orden de disponibilidad; venta = gas + camara (domingo -> lunes)
        $cap = @{}; $out = @()
        foreach ($it in @($items | Sort-Object disp, origen)) {
            $d = $it.disp
            while ($true) {
                $k = $d.ToString('yyyy-MM-dd'); if (-not $cap.ContainsKey($k)) { $cap[$k] = 0 }
                if ($cap[$k] -lt $P.gas_por_dia) { $cap[$k]++; break }
                $d = $d.AddDays(1)
            }
            $v = $d.AddDays($P.camara); if ($v.DayOfWeek -eq 'Sunday') { $v = $v.AddDays(1) }
            $it | Add-Member -NotePropertyName gas -NotePropertyValue $d -Force
            $it | Add-Member -NotePropertyName venta -NotePropertyValue $v -Force
            $out += $it
        }
        return $out
    }
    $colaOk = @(PsAsignar @($cola | Where-Object { $_.confirmado -eq 1 }))
    $colaNo = @(PsAsignar @($cola | Where-Object { $_.confirmado -ne 1 }))

    # ---- saldo por dia ----
    # Regla: lo que sobra un dia pasa al siguiente (la fruta espera en camara);
    # lo que falta NO se acumula (venta perdida). Si todavia se llega a cargar
    # (fecha de carga >= hoy) se "cargan" camiones virtuales hasta cubrir el dia
    # y su sobra sigue; si la fecha ya paso, el dia queda descubierto.
    $dias = @(); $ofAcum = 0.0; $veAcum = 0.0; $carry = 0.0
    $hoyD = (Get-Date).Date
    $lagBR = $P.camara + $P.desc_gas + $P.tr_BR + $P.ad_BR
    $lagPY = $P.camara + $P.desc_gas + $P.tr_PY + $P.ad_PY
    $lagBO = $P.camara + $P.desc_gas + $P.tr_BO + $P.ad_BO
    $lagMin = [math]::Min($lagBR, $lagPY)
    $d = $fotoFecha; $fin = $fotoFecha.AddDays($P.horizonte_dias)
    while ($d -le $fin) {
        if ($d.DayOfWeek -eq 'Sunday') { $d = $d.AddDays(1); continue }
        $vp = $ventaDia; if ($d -eq $fotoFecha) { $vp = $ventaDia * (1 - $P.foto_fraccion_vendida) }
        $gasif = 0; $det = @()
        foreach ($c in $camHoy) {
            if (-not $c.venta) { continue }
            $vv = $c.venta; if ($vv.DayOfWeek -eq 'Sunday') { $vv = $vv.AddDays(1) }; if ($vv -lt $fotoFecha) { $vv = $fotoFecha }
            if ($vv -eq $d) { $gasif += $c.cantidad; $det += ("CUB " + $c.cub + " " + $c.origen + " " + $c.cantidad) }
        }
        $lleg = 0; $enc = 0; $noc = 0
        foreach ($it in $colaOk) {
            if ($it.venta -ne $d) { continue }
            if ($it.estado -eq 'llegado') { $lleg += $it.cajas } else { $enc += $it.cajas }
            $det += ($it.origen + " " + $it.cajas + " " + $it.estado + ", gas " + $it.gas.ToString('dd/MM'))
        }
        foreach ($it in $colaNo) { if ($it.venta -eq $d) { $noc += $it.cajas } }
        $of = $gasif + $lleg + $enc
        $ofAcum += $of; $veAcum += $vp
        $saldoAntes = $carry + $of - $vp
        $aCargar = 0; $planCajas = 0; $descub = 0; $saldo = $saldoAntes
        if ($saldoAntes -lt 0) {
            if ($d.AddDays(-$lagMin) -ge $hoyD) {
                $aCargar = [int][math]::Ceiling(-$saldoAntes / $P.cajas_camion)
                $planCajas = $aCargar * $P.cajas_camion
                $saldo = $saldoAntes + $planCajas
            } else {
                $descub = [int][math]::Round(-$saldoAntes); $saldo = 0
            }
        }
        $carry = $saldo
        $lun = $d.AddDays(-(([int]$d.DayOfWeek + 6) % 7))
        $dias += [PSCustomObject]@{ fecha=(PsYmd $d); dow=[int]$d.DayOfWeek; semana=(PsYmd $lun); ventaPlan=[int][math]::Round($vp)
            gasificado=$gasif; llegado=$lleg; enCamino=$enc; sinConfirmar=$noc; oferta=$of
            ofertaAcum=[int][math]::Round($ofAcum); ventaAcum=[int][math]::Round($veAcum)
            saldoAntes=[int][math]::Round($saldoAntes); saldo=[int][math]::Round($saldo)
            aCargar=$aCargar; planCajas=[int]$planCajas; descubierto=$descub
            cargaBR=(PsYmd $d.AddDays(-$lagBR)); cargaPY=(PsYmd $d.AddDays(-$lagPY)); cargaBO=(PsYmd $d.AddDays(-$lagBO))
            detalle=($det -join ' | ') }
        $d = $d.AddDays(1)
    }

    # ---- por semana de venta ----
    $semanas = @()
    foreach ($g in @($dias | Group-Object semana)) {
        $lunD = [DateTime]::ParseExact($g.Name, 'yyyy-MM-dd', $inv)
        $grp = @($g.Group); $ult = $grp[$grp.Count - 1]
        $semanas += [PSCustomObject]@{ lunes=$g.Name; etiqueta=($lunD.ToString('dd/MM') + ' al ' + $lunD.AddDays(5).ToString('dd/MM'))
            dias=$grp.Count; necesita=[int](($grp | Measure-Object ventaPlan -Sum).Sum)
            gasificado=[int](($grp | Measure-Object gasificado -Sum).Sum); llegado=[int](($grp | Measure-Object llegado -Sum).Sum)
            enCamino=[int](($grp | Measure-Object enCamino -Sum).Sum); sinConfirmar=[int](($grp | Measure-Object sinConfirmar -Sum).Sum)
            saldoFin=$ult.saldo; aCargar=[int](($grp | Measure-Object aCargar -Sum).Sum); descubierto=[int](($grp | Measure-Object descubierto -Sum).Sum) }
    }

    # ---- stock ERP (ultimo dia) ----
    $stock = $null
    if (Test-Path $psStock) {
        $stRows = @()
        foreach ($r in @(PsTabla (Read-XlsxHoja -Path $psStock -Hoja 'stock'))) {
            $f = PsFecha $r['fecha']; if (-not $f) { continue }
            $cj = PsNum $r['stock_cajas']
            if ($null -eq $cj) { $kg = PsNum $r['stock_kg']; $kc = PsNum $r['kg_caja']; if ($kg -and $kc) { $cj = $kg / $kc } }
            if ($null -eq $cj) { continue }
            $stRows += [PSCustomObject]@{ fecha=$f; origen=([string]$r['origen']).Trim(); kg=(PsNum $r['stock_kg']); cajas=[int][math]::Round($cj) }
        }
        if ($stRows.Count) {
            $fmax = ($stRows | Sort-Object fecha -Descending | Select-Object -First 1).fecha
            $ult = @($stRows | Where-Object { $_.fecha -eq $fmax })
            $tot = ($ult | Where-Object { $_.origen -notmatch '^Ecu' } | Measure-Object cajas -Sum).Sum
            if ($null -eq $tot) { $tot = 0 }
            $stock = [ordered]@{ fecha=(PsYmd $fmax); filas=@($ult | ForEach-Object { [ordered]@{ origen=$_.origen; kg=$_.kg; cajas=$_.cajas } })
                totalCamion=[int]$tot; dias=[math]::Round($tot / $ventaDia, 1) }
        }
    } else { Write-Host "    (aviso) falta fuentes\stock\stock_diario.xlsx" -ForegroundColor DarkYellow }

    # ---- ritmo de regimen ----
    $camSem = $P.ventas_semana / $P.cajas_camion
    $ritmo = [ordered]@{ camionesSemana=[math]::Round($camSem, 1); BR=[int][math]::Round($camSem * $P.mix_BR); PY=[int][math]::Round($camSem * $P.mix_PY)
        BOcajasSemana=[int][math]::Round($P.ventas_semana * $P.mix_BO); lagBR=$lagBR; lagPY=$lagPY; lagBO=$lagBO }

    function PsColaOut { param($lst)
        $o = @(); foreach ($x in @($lst)) { $o += [ordered]@{ origen=$x.origen; cajas=$x.cajas; estado=$x.estado; carga=(PsYmd $x.carga); llegada=(PsYmd $x.llegada); gas=(PsYmd $x.gas); venta=(PsYmd $x.venta); desc=$x.desc } }
        return $o
    }
    $camOut = @(); foreach ($x in @($camHoy | Sort-Object { if ($_.venta) { $_.venta } else { [DateTime]::MaxValue } }, cub)) { $camOut += [ordered]@{ cub=$x.cub; cam=$x.cam; origen=$x.origen; cantidad=$x.cantidad; gas=(PsYmd $x.gas); venta=(PsYmd $x.venta); llegada=$x.llegada; nota=$x.nota } }
    $plan = [ordered]@{
        generado   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        hoy        = (PsYmd $hoyD)
        planilla   = 'fuentes\plan_semanal\plan_semanal.xlsx'
        foto       = (PsYmd $fotoFecha)
        fotosHist  = @($fotosHist)
        params     = $P
        ventaDia   = [int][math]::Round($ventaDia)
        camaras    = @($camOut)
        cola       = @(PsColaOut $colaOk)
        sinConfirmar = @(PsColaOut $colaNo)
        dias       = @($dias)
        semanas    = @($semanas)
        stock      = $stock
        ritmo      = $ritmo
    }
    $psJson = $plan | ConvertTo-Json -Depth 8 -Compress
    # ConvertTo-Json (PS 5.1) escribe null donde hay un array vacio: la pagina espera listas
    foreach ($k in @('cola','sinConfirmar','fotosHist','camaras')) { $psJson = $psJson.Replace('"' + $k + '":null', '"' + $k + '":[]') }
    Set-Content -Path (Join-Path $fuentes "plan_semanal.json") -Value $psJson -Encoding UTF8
    $faltan = ($dias | Measure-Object aCargar -Sum).Sum
    $descT = ($dias | Measure-Object descubierto -Sum).Sum
    Write-Host ("    foto " + (PsYmd $fotoFecha) + ": " + $camHoy.Count + " filas de camaras (" + (($camHoy | Measure-Object cantidad -Sum).Sum) + " cajas), cola " + $colaOk.Count + " confirmados + " + $colaNo.Count + " sin confirmar; " + $dias.Count + " dias; a cargar " + $faltan + " camiones, descubierto " + $descT + " cajas") -ForegroundColor Green
    if (Test-Path $psHtml) {
        $hTxt = Get-Content $psHtml -Raw -Encoding UTF8
        $patP = '/\*__PLAN_JSON__\*/.*?/\*__END_PLAN__\*/'
        $nP = ([regex]::Matches($hTxt, $patP, 'Singleline')).Count
        if ($nP -ne 1) { Write-Host "    (skip) index_cargas.html: esperaba 1 par de marcadores PLAN, hay $nP" -ForegroundColor Red }
        else {
            $repP = '/*__PLAN_JSON__*/' + $psJson + '/*__END_PLAN__*/'
            Set-Content -Path $psHtml -Value ([regex]::Replace($hTxt, $patP, { param($m) $repP }, 'Singleline')) -Encoding UTF8 -NoNewline
            Write-Host "    OK index_cargas.html" -ForegroundColor Green
        }
    } else { Write-Host "    (aviso) falta index_cargas.html" -ForegroundColor DarkYellow }
  } catch {
    Add-Falla -Paso 'Plan semanal (saldo por dia)' -Detalle "$($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber))"
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
    @{ f='index.html';                  t='Plan de compras Brasil';      d='Vista rapida: termometro Cepea, clima, compra Almar vs Cepea y ranking de productores con fichas.'; ico='🍌' },
    @{ f='index_brasil.html';           t='Brasil — detalle';            d='Oportunidad, forecast, correlacion clima-precio, plan de cargas con ranking y fichas, mercado BR en aduana y seguimiento del ano.'; ico='🇧🇷' },
    @{ f='index_paraguay_bolivia.html'; t='Paraguay y Bolivia';          d='Precio mayorista Carape, plan de cargas Paraguay y aduana Penta: Almar, mercado y competidores en Paraguay y Bolivia, mas indicadores de los 4 origenes.'; ico='🇵🇾' },
    @{ f='index_ecuador.html';          t='Ecuador FOB';                 d='Precio FOB de exportacion de Ecuador.'; ico='🇪🇨' },
    @{ f='index_mercado.html';          t='Mercado UY multi-origen';     d='Quien importa que, de donde y cuanto. Datos de aduana.'; ico='🌎' },
    @{ f='index_proyeccion.html';       t='Proyeccion a fin de ano';     d='Precio y volumen proyectados hasta diciembre.'; ico='🔭' },
    @{ f='index_comparativo_anual.html';t='Comparativo anual';           d='Ano contra ano: curvas, salto julio-agosto e invierno.'; ico='📊' },
    @{ f='index_recepcion.html';        t='Ficha de recepcion';         d='Cargar un camion parado al lado: corte, mediciones. Arma el WhatsApp y la fila del Excel.'; ico='📝' },
    @{ f='index_calidad.html';          t='Calidad y vida verde';       d='Cuanto aguanta cada lote y que lo explica. Se llena a mano en fuentes\calidad_lotes.xlsx.'; ico='🌱' },
    @{ f='index_cargas.html';           t='Saldo por dia y cargas';      d='Cuanta fruta hay por dia de venta, que falta y cuando cargarla. Se llena con la foto del plan de camaras en fuentes\plan_semanal\plan_semanal.xlsx.'; ico='🚚' },
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
                        'index_comparativo_anual.html','index_calidad.html','index_cargas.html')
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
# Umbral de divergencia calendario-vs-precio real. Vive afuera de la funcion
# porque el resumen semanal tambien necesita saber si la zona sola alcanza o
# si esta mintiendo, y los dos tienen que cortar en el mismo numero.
$script:ZONA_DIVERGE_PCT = 12.0
# Precio minimo de sustentacion Ecuador (USD/caja). Lo usan la alerta EC y el resumen.
$script:EC_PMS_USD_CAJA = 7.50

function Get-AccionZona {
    param(
        [string]$zona,
        [double]$vsHistPct   # % del precio real vs el promedio historico del mes (+ arriba / - abajo)
    )
    $DIVERGE = $script:ZONA_DIVERGE_PCT
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
$mesUmbral6m = $MESES_NOM[[int](Get-Date).AddMonths(-6).Month]   # mes de hace 6 meses, para las alertas de extremo (antes decia "noviembre" fijo)
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
        $ecPmsBox = $script:EC_PMS_USD_CAJA
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
            # ------------------------------------------------------------------
            # Resumen semanal - reescrito 04/09/2026.
            #
            # Regla: cada linea lleva la FECHA del dato que muestra y ninguna
            # afirma algo que no salga de un numero calculado mas arriba. Si una
            # fuente quedo vieja, se nota por su propia fecha (Ecuador estuvo 42
            # dias sin actualizar y nadie se entero: esta es la proteccion, en vez
            # del bloque "Salud" que se saco). Las fallas del pipeline ya tienen su
            # propia alerta ('fallas'), asi que no se repiten aca. Sin footer.
            # ------------------------------------------------------------------
            function Get-FechaCorta { param([string]$iso) try { ([DateTime]::Parse($iso)).ToString('dd/MM') } catch { $iso } }
            function Get-PctTxt { param([double]$v, [int]$dec = 0) $s = if ($v -ge 0) {'+'} else {''}; "$s$($v.ToString('F' + $dec))%" }
            function Get-SigTxt { param([int]$s) if ($s -gt 0) { "+$s" } else { "$s" } }
            function Get-DiasTxt { param([int]$n) if ($n -eq 1) { "1 día" } else { "$n días" } }

            # Delta semanal para contexto
            $deltaSemPct = $null
            $precioSemAnt = $null
            if ($nanica.Count -ge 2) {
                $precioSemAnt = [double]$nanica[-2].precio
                $deltaSemPct = (($oppLast - $precioSemAnt) / $precioSemAnt) * 100
            }
            # vs promedio historico del mes (calendario)
            $vsProm = (($oppLast - $oppPM) / $oppPM) * 100

            $msg = "🍌 *ALMAR · Resumen semanal $((Get-Date).ToString('dd/MM'))*`n`n"

            # --- Cepea: precio, variacion semanal y de 3 semanas (la que mueve el score)
            $msg += "*💰 Cepea Nanica 1ª (SC)* — semana $(Get-FechaCorta $nanica[-1].fecha)`n"
            $msg += "R$ $($oppLast.ToString('F2'))/kg"
            if ($null -ne $deltaSemPct) { $msg += " · $(Get-PctTxt $deltaSemPct 1) vs sem ant (R$ $($precioSemAnt.ToString('F2')))" }
            if ($nanica.Count -ge 4) {
                $p3 = [double]$nanica[-4].precio
                $msg += " · $(Get-PctTxt $pctChg3w 1) en 3 sem (R$ $($p3.ToString('F2')))"
            }
            $msg += "`n`n"

            # --- Calendario vs precio real. La "zona" es el promedio historico del
            #     mes, no el mercado de hoy: se dice tal cual, sin semaforo rojo.
            $lado = if ($vsProm -lt 0) { "por debajo" } else { "por encima" }
            $mesCap = $nombreMes.Substring(0,1).ToUpper() + $nombreMes.Substring(1)
            $msg += "*📅 Calendario vs precio*`n"
            $msg += "$mesCap promedia R$ $($oppPM.ToString('F2'))/kg (hist. $($nanica[0].anio)-$($nanica[-1].anio)) → hoy $([math]::Abs([math]::Round($vsProm)))% $lado`n`n"

            # --- Score con su descomposicion, asi se ve POR QUE da lo que da
            $msg += "*🎯 Score: $oppScore · $oppLevel*`n"
            $msg += "Cepea $(Get-SigTxt $oppCepeaSig) · calendario $(Get-SigTxt $oppZonaSig) · spread $(Get-SigTxt $oppSpreadSig) · clima $(Get-SigTxt $oppClimaSig)`n`n"

            # --- Clima prox 7 dias por zona, con los mismos umbrales que usan las
            #     alertas del script (frio <=14, helada <=2, calor >=32, lluvia >=50mm)
            $climaLineas = @()
            foreach ($r in $climaData) {
                $fc = @($r.forecast_7d)
                if ($fc.Count -eq 0) { continue }
                $frios  = @($fc | Where-Object { $null -ne $_.tmin -and [double]$_.tmin -le 14 })
                $helada = @($fc | Where-Object { $null -ne $_.tmin -and [double]$_.tmin -le 2 })
                $calor  = @($fc | Where-Object { $null -ne $_.tmax -and [double]$_.tmax -ge 32 })
                $lluvia = @($fc | Where-Object { $null -ne $_.lluvia -and [double]$_.lluvia -ge 50 })
                $partes = @()
                if ($helada.Count -gt 0) { $partes += "❄️ RIESGO HELADA ($(Get-DiasTxt $helada.Count))" }
                if ($frios.Count -gt 0) {
                    $piso = $frios | Sort-Object { [double]$_.tmin } | Select-Object -First 1
                    $partes += "$(Get-DiasTxt $frios.Count) con mín ≤14°C (piso $(([double]$piso.tmin).ToString('F1'))°C el $(Get-FechaCorta $piso.fecha))"
                }
                if ($calor.Count -gt 0)  { $partes += "$(Get-DiasTxt $calor.Count) máx ≥32°C" }
                if ($lluvia.Count -gt 0) { $partes += "$(Get-DiasTxt $lluvia.Count) lluvia ≥50mm" }
                if ($partes.Count -gt 0) { $climaLineas += "$($r.bandera) $($r.ciudad): $($partes -join ' · ')" }
            }
            $msg += "*🌡️ Clima próx 7d*`n"
            if ($climaLineas.Count -gt 0) { $msg += ($climaLineas -join "`n") + "`n`n" }
            else { $msg += "sin frío, calor ni lluvia fuerte en las zonas productoras`n`n" }

            # --- Modelo 4 semanas. Se dice de que esta hecho: r² del clima (peso_clim)
            #     y el resto es el promedio historico del mes destino. Sin eso, un
            #     "+75%" parece pronostico y es casi todo calendario.
            if ($correlData -and $correlData.Count -gt 0 -and $correlData[0].forecast_4w -and @($correlData[0].forecast_4w).Count -ge 4) {
                $f4 = $correlData[0].forecast_4w[-1]
                $fc4 = ($correlData | ForEach-Object { [double]$_.forecast_4w[-1].precio_pred } | Measure-Object -Average).Average
                $fcPct = (($fc4 - $oppLast) / $oppLast) * 100
                $wClim = [math]::Round(100 * [double]$f4.peso_clim)
                $msg += "*🔮 Modelo 4 sem* (al $(Get-FechaCorta $f4.fecha))`n"
                $msg += "R$ $($fc4.ToString('F2')) ($(Get-PctTxt $fcPct)) · rango R$ $(([double]$f4.ci_low).ToString('F2'))–$(([double]$f4.ci_high).ToString('F2'))`n"
                $msg += "_El clima pesa $wClim%; el resto es el histórico del mes destino (R$ $(([double]$f4.baseline_mes).ToString('F2')))._`n`n"
            }

            # --- Paraguay: fecha del dato SIMA, variacion vs medicion anterior y el
            #     tipo de cambio que se usa (fijo en el script) declarado en el texto.
            if ($null -ne $pyData -and $pyData.precio_caja_pyg -gt 0) {
                $pyKg = if ($pyData.kg_caja_aprox) { [double]$pyData.kg_caja_aprox } else { 24 }
                $PYG_USD = 7500.0
                $pyUsdKg = ([double]$pyData.precio_caja_pyg / $PYG_USD) / $pyKg
                $brUsdKg = ($oppLast + 0.73) / 5.2   # +R$0,73/kg servicios, TC 5,2
                $diffPct = (($pyUsdKg - $brUsdKg) / $brUsdKg) * 100
                $pyFecha = ''; $pyVar = ''
                if ($pyData.serie -and @($pyData.serie).Count -ge 1) {
                    $pyOrd = @($pyData.serie | Sort-Object fecha)
                    $pyFecha = " (SIMA $(Get-FechaCorta $pyOrd[-1].fecha))"
                    if ($pyOrd.Count -ge 2 -and [double]$pyOrd[-2].precio_caja_pyg -gt 0) {
                        $pyD = (([double]$pyOrd[-1].precio_caja_pyg - [double]$pyOrd[-2].precio_caja_pyg) / [double]$pyOrd[-2].precio_caja_pyg) * 100
                        $pyVar = " · $(Get-PctTxt $pyD) vs $(Get-FechaCorta $pyOrd[-2].fecha)"
                    }
                }
                $msg += "*🇵🇾 PY Carape*$pyFecha`n"
                $msg += "PYG $(([double]$pyData.precio_caja_pyg).ToString('N0'))/caja$pyVar · ≈USD $($pyUsdKg.ToString('F2'))/kg a $($PYG_USD.ToString('N0')) PYG/USD · $(Get-PctTxt $diffPct) vs BR`n`n"
            }

            # --- Ecuador: siempre con la fecha del ultimo punto Tridge (rezago ~2 sem)
            if ($script:ecLastPoint) {
                $ecP = [double]$script:ecLastPoint.usd_box
                $ecSpread = (($ecP - $script:EC_PMS_USD_CAJA) / $script:EC_PMS_USD_CAJA) * 100
                $msg += "*🇪🇨 Ecuador FOB* (Tridge, dato $(Get-FechaCorta $script:ecLastPoint.date))`n"
                $msg += "USD $($ecP.ToString('F2'))/caja · $(Get-PctTxt $ecSpread) vs PMS USD $($script:EC_PMS_USD_CAJA.ToString('F2'))`n`n"
            }

            # --- Plan de Cargas (Aloha): lo que VIENE, no lo que se pago. Se lee
            #     de la API del ERP en el paso 3b; si fallo, se dice que es cache y
            #     de cuando. Solo aparecen las lineas con algo que contar.
            if ($null -ne $planResumen) {
                $pcTag = if ($planResumen.origen -eq 'cache') { "cache del $(Get-FechaCorta $planResumen.generado_en)" } else { "Aloha $(Get-FechaCorta $planResumen.generado_en)" }
                function Get-ProdTxt { param($lista, [int]$max = 4)
                    $l = @($lista); if ($l.Count -eq 0) { return '' }
                    if ($l.Count -le $max) { return ' · ' + ($l -join ', ') }
                    return ' · ' + (($l | Select-Object -First $max) -join ', ') + " +$($l.Count - $max)"
                }
                function Get-CamTxt { param([int]$n) if ($n -eq 1) { "1 camión" } else { "$n camiones" } }
                function Get-StatusTxt { param($h)
                    if ($null -eq $h -or $h.Count -eq 0) { return '' }
                    $partes = @(); foreach ($k in $h.Keys) { $partes += "$(([string]$k).ToLower()) $($h[$k])" }
                    return ' (' + ($partes -join ' · ') + ')'
                }
                $msg += "*🚛 Plan de Cargas* ($pcTag)`n"
                if ($planResumen.semana_actual) {
                    $sa = $planResumen.semana_actual
                    $msg += "Semana del $(Get-FechaCorta $sa.semana_lunes): $(Get-CamTxt $sa.camiones) · $(([int]$sa.cajas).ToString('N0')) cajas$(Get-ProdTxt $sa.productores)`n"
                } else {
                    $msg += "Esta semana: sin cargas en el plan`n"
                }
                if ($planResumen.en_camino.camiones -gt 0) {
                    $msg += "En camino: $(Get-CamTxt $planResumen.en_camino.camiones) · $(([int]$planResumen.en_camino.cajas).ToString('N0')) cajas$(Get-StatusTxt $planResumen.en_camino.por_status)`n"
                }
                if ($planResumen.por_venir.camiones -gt 0) {
                    $msg += "Por venir: $(Get-CamTxt $planResumen.por_venir.camiones) · $(([int]$planResumen.por_venir.cajas).ToString('N0')) cajas$(Get-StatusTxt $planResumen.por_venir.por_status)`n"
                }
                if ($planResumen.arribados.camiones -gt 0) {
                    $msg += "En depósito sin descargar: $(Get-CamTxt $planResumen.arribados.camiones)`n"
                }
                if ($planResumen.ultima_descarga) {
                    $ud = $planResumen.ultima_descarga
                    $msg += "Última descarga $(Get-FechaCorta $ud.fecha)"
                    if ($ud.productor) { $msg += " · $($ud.productor)" }
                    if ($ud.cajas -gt 0) { $msg += " · $(([int]$ud.cajas).ToString('N0')) cajas" }
                    $msg += "`n"
                }
                $msg += "`n"
            }

            # --- Almar: ultima semana con cargas en la planilla. Si la planilla no se
            #     carga, se ve aca (y explica por que el spread da 0).
            if ($almarSemanas.Count -gt 0) {
                $alU = $almarSemanas[-1]
                $semSin = [math]::Floor(((Get-Date) - [DateTime]::Parse($alU.fecha)).TotalDays / 7)
                $msg += "*🚚 Almar* — última semana cargada $(Get-FechaCorta $alU.fecha)"
                if ($semSin -ge 2) { $msg += " (hace $semSin sem, sin cargas nuevas en la planilla)" }
                $msg += "`n"
                $msg += "R$ $(([double]$alU.precio_avg_caja).ToString('F2'))/caja prom · $($alU.cargas) cargas"
                if ($spreadAvg -ne 0) { $msg += " · spread $(if ($spreadAvg -ge 0) {'+'} else {''})R$ $($spreadAvg.ToString('F1'))/caja vs Cepea" }
                $msg += "`n"
            }

            # Recomendación accionable según score + zona
            #
            # FIX 04/09/2026 - este bloque tenia dos errores:
            #
            #  1) El corte de "compras normales" era -ge 0, pero $oppLevel (y el JS
            #     de index_brasil.html, que se supone que estan en sync) cortan en
            #     -ge -1. Un score -1 imprimia "Score: -1 · NORMAL" y en el renglon
            #     siguiente "Cautela": el mismo mensaje se contradecia solo.
            #
            #  2) Decia "precio en zona alta" leyendo solo $zonaAct, que sale del
            #     promedio historico del mes cruzando TODOS los anios. Eso es
            #     calendario, no el precio de hoy. El 04/09/2026 mando "precio en
            #     zona alta" con Cepea en R$ 0,91 = -49% contra ese mismo promedio,
            #     o sea el consejo justo al reves. Es el mismo error que ya se habia
            #     arreglado el 02/09 en las alertas de zona con Get-AccionZona; aca
            #     habia quedado el texto viejo hardcodeado.
            #
            # Ahora ninguna rama afirma nada sobre el nivel del precio: eso lo dice
            # Get-AccionZona, que cruza calendario contra precio real, y solo se
            # agrega cuando los dos efectivamente divergen (si coinciden, la frase
            # del score ya alcanza y repetirla solo alarga el mensaje).
            $zonaDiverge = [math]::Abs($vsProm) -ge $script:ZONA_DIVERGE_PCT
            $msg += "`n*👉 Sugerencia:* "
            if ($oppScore -ge 4) {
                $msg += "Comprar fuerte — ventana óptima."
            } elseif ($oppScore -ge 2) {
                $msg += "Buena ventana de compra. "
                if ($null -ne $deltaSemPct -and $deltaSemPct -gt 5) { $msg += "Precio recuperando desde mínimo." }
                elseif ($zonaAct -eq "BAJA") { $msg += "Aprovechar zafra alta." }
            } elseif ($oppScore -ge -1) {
                $msg += "Compras normales, sin urgencia."
            } elseif ($oppScore -ge -3) {
                $msg += "Cautela — señales combinadas negativas."
            } else {
                $msg += "STOP compras spot — momento de descarga."
            }
            # La rama "Buena ventana" deja un espacio colgado si no entra ninguna
            # de sus dos sub-condiciones, asi que recortamos siempre.
            $msg = $msg.TrimEnd()
            if ($zonaDiverge) {
                $msg += " " + (Get-AccionZona -zona $zonaAct -vsHistPct $vsProm)
            }
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
