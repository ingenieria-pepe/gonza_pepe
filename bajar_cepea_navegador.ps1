# ==========================================================================
#  bajar_cepea_navegador.ps1  -  SOLO LAPTOP  [04/11/2026]
#  hfbrasil (Cepea) devuelve 403 a todo programa (servidor y laptop), pero deja
#  bajar el Excel si se abre con el navegador de verdad. Este script abre en el
#  Edge de Gonzalo los 4 links de exportacion (SC, Vale do Ribeira, Norte de
#  Minas, Bom Jesus da Lapa), espera los 4 "<fecha>-precos-medios.xlsx" en
#  Descargas, reconoce la region por el contenido, y si traen una semana nueva
#  los copia a fuentes\ y los sube a GitHub (el servidor los toma por git).
#  Gonzalo: "las dos, deja automatico" (tarea Poronga_Cepea_Navegador, mie 10:30
#  y vie 19:45, antes de las corridas del servidor de mie 12:00 y vie 20:30; hasta el 13/11/2026 era vie 17:30 / 19:00,
#  antes de que Cepea publique (~19:00), y el resumen del viernes salia con la semana vieja).
#
#  -Servidor [04/11/2026, pedido del servidor]: en la PC de Ingenieria (sesion User). Guarda en fuentes\cepea_servidor\ con los
#  nombres de siempre, log ahi mismo, SIN git (el servidor no commitea; esa carpeta esta en $preservarDirs y en .gitignore).
#  actualizar_precios.ps1 usa, por region, el xlsx con la fecha de dato mas nueva entre fuentes\ (laptop) y fuentes\cepea_servidor\.
#
#  Uso: powershell -ExecutionPolicy Bypass -File bajar_cepea_navegador.ps1 [-SinSubir] [-Servidor]
# ==========================================================================
param([switch]$SinSubir, [switch]$Servidor)
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$dl   = Join-Path $env:USERPROFILE 'Downloads'
$destDir = $(if ($Servidor) { Join-Path $repo 'fuentes\cepea_servidor' } else { Join-Path $repo 'fuentes' })
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
$log  = $(if ($Servidor) { Join-Path $destDir 'cepea_servidor.log' } else { Join-Path $repo 'fuentes\cepea_navegador.log' })
function Log($s) { $l = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $s"; Write-Host $l; try { Add-Content -Path $log -Value $l -Encoding UTF8 } catch {} }
Add-Type -AssemblyName System.IO.Compression.FileSystem

# lector de la serie: el mismo de actualizar_precios.ps1 (Nanica primeira - produtor)
$tt = [IO.File]::ReadAllText((Join-Path $repo 'actualizar_precios.ps1'), [Text.Encoding]::UTF8)
$fn = [regex]::Match($tt, '(?s)function Read-CepeaXlsx\s*\{.*?\r?\n\}').Value
if (-not $fn) { throw 'no encontre Read-CepeaXlsx en actualizar_precios.ps1' }
Invoke-Expression $fn

$regiones = @(
    @{ id = 25; destino = 'precios_banana_SC_2023-2026.xlsx'; clave = 'Santa Catarina' },
    @{ id = 52; destino = 'precios_banana_VRibeira.xlsx';     clave = 'Vale do Ribeira' },
    @{ id = 24; destino = 'precios_banana_NMinas.xlsx';       clave = 'Norte de Minas' },
    @{ id = 6;  destino = 'precios_banana_BJLapa.xlsx';       clave = 'Bom Jesus da Lapa' })
$anoF = (Get-Date).Year; $anoI = $anoF - 3

try {
    $t0 = (Get-Date).AddSeconds(-2)
    foreach ($r in $regiones) {
        Start-Process 'msedge' "https://www.hfbrasil.org.br/br/estatistica/preco/exportar.aspx?produto=4&regiao%5B%5D=$($r.id)&periodicidade=diario&ano_inicial=$anoI&ano_final=$anoF"
        Start-Sleep -Seconds 4
    }
    # esperar hasta 90 s los 4 archivos
    $nuevos = @()
    for ($s = 0; $s -lt 90 -and $nuevos.Count -lt 4; $s += 5) {
        Start-Sleep -Seconds 5
        $nuevos = @(Get-ChildItem $dl -Filter '*-precos-medios*.xlsx' -File | Where-Object { $_.LastWriteTime -ge $t0 -and $_.Length -gt 2048 })
    }
    if ($nuevos.Count -lt 4) { Log "FALLA: bajaron $($nuevos.Count) de 4 archivos (el navegador no descargo, o pidio algo)"; exit 1 }

    $cambios = @()
    foreach ($x in $nuevos) {
        $z = [IO.Compression.ZipFile]::OpenRead($x.FullName); $ss = $z.GetEntry('xl/sharedStrings.xml'); $txt = ''
        if ($ss) { $sr = New-Object IO.StreamReader($ss.Open()); $txt = $sr.ReadToEnd(); $sr.Close() }; $z.Dispose()
        $r = $regiones | Where-Object { $txt -match [regex]::Escape($_.clave) } | Select-Object -First 1
        if (-not $r) { Log "FALLA: $($x.Name) no es de ninguna de las 4 regiones"; continue }
        $serie = Read-CepeaXlsx -Path $x.FullName
        if (-not $serie -or $serie.Count -lt 10) { Log "FALLA: $($x.Name) ($($r.clave)) sin serie legible"; continue }
        $dest = Join-Path $destDir $r.destino
        $ultViejo = $null; if (Test-Path $dest) { try { $ultViejo = (Read-CepeaXlsx -Path $dest)[-1].fecha } catch {} }
        $ultNuevo = $serie[-1].fecha
        if ($ultViejo -and $ultNuevo -le $ultViejo) { Log "$($r.clave): sin semana nueva (ultima $ultNuevo)"; continue }
        Copy-Item $x.FullName $dest -Force
        $cambios += "$($r.clave) $ultNuevo = $($serie[-1].precio)"
        Log "$($r.clave): actualizado $ultViejo -> $ultNuevo ($($serie[-1].precio) R$/kg)"
    }
    # los descargados quedan en una subcarpeta para no llenar Descargas
    $arch = Join-Path $dl 'cepea_bajados'; if (-not (Test-Path $arch)) { New-Item -ItemType Directory -Path $arch | Out-Null }
    foreach ($x in $nuevos) { try { Move-Item $x.FullName (Join-Path $arch $x.Name) -Force } catch {} }

    if (-not $cambios.Count) { Log 'nada nuevo: no se sube nada'; exit 0 }
    if ($Servidor) { Log "guardados en fuentes\cepea_servidor (sin git): $($cambios -join ' · ')"; exit 0 }
    if ($SinSubir) { Log "copiados sin subir (-SinSubir): $($cambios -join ' · ')"; exit 0 }
    Push-Location $repo
    try {
        git pull --rebase -q 2>&1 | Out-Null
        git add -- 'fuentes/precios_banana_SC_2023-2026.xlsx' 'fuentes/precios_banana_VRibeira.xlsx' 'fuentes/precios_banana_NMinas.xlsx' 'fuentes/precios_banana_BJLapa.xlsx'
        git commit -q -m "Cepea bajado con el navegador (laptop): $($cambios -join ' · ')" 2>&1 | Out-Null
        git push -q 2>&1 | Out-Null
        Log "subido: $(git rev-parse --short HEAD) · $($cambios -join ' · ')"
    } finally { Pop-Location }
} catch { Log "FALLA: $($_.Exception.Message)"; exit 1 }
