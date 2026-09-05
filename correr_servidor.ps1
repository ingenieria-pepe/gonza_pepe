# ==========================================================================
#  correr_servidor.ps1  -  Lo que ejecuta la tarea programada en el servidor
# ==========================================================================
#  Flujo (agregado 04/09/2026):
#    1. Si la carpeta es un clon git y hay git instalado: descarta SOLO los
#       archivos que el pipeline regenera en cada corrida y hace
#       git pull --ff-only. Con eso alcanza pushear a GitHub desde la laptop:
#       la proxima corrida del servidor ya usa el codigo nuevo.
#       Si el pull falla (conflicto, sin internet, sin git, sin credenciales)
#       lo escribe en last_run.log y corre igual con el codigo que hay.
#    2. Corre actualizar_precios.ps1 y guarda toda la salida en last_run.log.
#
#  NUNCA toca: config/whatsapp.json, fuentes/state_*.json, los caches,
#  alertas.log ni las planillas de entrada (cargas 2026.xlsx, etc.). Si un
#  pull los borrara (porque dejaron de estar trackeados), los restaura desde
#  un respaldo hecho justo antes.
#
#  Se registra desde setup_servidor.ps1. Tambien se puede correr a mano:
#     & "<esta-carpeta>\correr_servidor.ps1"
# ==========================================================================
$ErrorActionPreference = 'Continue'
$base       = $PSScriptRoot
$logRun     = Join-Path $base 'last_run.log'
$scriptMain = Join-Path $base 'actualizar_precios.ps1'

# Archivos que el pipeline REGENERA en cada corrida: seguro descartarlos antes
# del pull (se vuelven a escribir enseguida). Lista explicita a proposito:
# "todo lo modificado" podria descartar una planilla editada en el servidor.
$regenerados = @(
    'index*.html',
    'fuentes/precios_cepea.json',
    'fuentes/precios_ecuador.json',
    'fuentes/precios_banana_SC_2023-2026.xlsx',
    'fuentes/portada.json',
    'fuentes/proyeccion.json',
    'fuentes/calidad.json',
    'fuentes/mercado_uy.json',
    'last_run.log'
)
# Archivos con ESTADO propio del servidor: no se descartan nunca y, si el
# pull los borra, se restauran.
$preservar = @(
    'config/whatsapp.json',
    'fuentes/state_alertas.json',
    'fuentes/state_whatsapp.json',
    'fuentes/precios_py_cache.json',
    'fuentes/indexmundi_cache.json',
    'alertas.log'
)
$preservarDirs = @('fuentes/clima_archive_cache')

$script:lineasSync = @()
function Log { param([string]$t) $script:lineasSync += "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [sync] $t" }

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Log "git no esta instalado: corro con el codigo local. Para sincronizar con GitHub instalar Git for Windows."
} elseif (-not (Test-Path (Join-Path $base '.git'))) {
    Log "la carpeta no es un clon git: corro con el codigo local. Para sincronizar, clonar el repo en vez de copiar la carpeta (ver MIGRACION_SERVIDOR.md, seccion 13)."
} else {
    Push-Location $base
    try {
        # 1) respaldo del estado
        $bk = Join-Path $env:TEMP ('poronga_estado_' + (Get-Date).ToString('yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Path $bk -Force | Out-Null
        foreach ($p in $preservar) {
            if (Test-Path $p) {
                $dest = Join-Path $bk $p
                New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
                Copy-Item $p $dest -Force
            }
        }
        foreach ($d in $preservarDirs) {
            if (Test-Path $d) {
                $dest = Join-Path $bk $d
                New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
                Copy-Item $d $dest -Recurse -Force
            }
        }

        # 2) descartar solo lo regenerado (si esta trackeado)
        $tracked = @(git ls-files -- $regenerados 2>$null | Where-Object { $_ })
        if ($tracked.Count -gt 0) { git checkout -- $tracked 2>&1 | Out-Null }

        # 3) pull
        $antes   = (git rev-parse --short HEAD 2>$null)
        $salida  = (git pull --ff-only 2>&1 | Out-String).Trim() -replace '\s+', ' '
        $rc      = $LASTEXITCODE
        $despues = (git rev-parse --short HEAD 2>$null)
        if ($rc -eq 0) {
            if ($antes -ne $despues) { Log "git pull OK: $antes -> $despues" } else { Log "git pull OK: sin cambios ($antes)" }
        } else {
            Log "git pull FALLO (rc=$rc), corro con el codigo local ($antes): $salida"
        }

        # 4) restaurar estado si el pull lo borro
        foreach ($p in $preservar) {
            $src = Join-Path $bk $p
            if ((Test-Path $src) -and -not (Test-Path $p)) { Copy-Item $src $p -Force; Log "restaurado $p" }
        }
        foreach ($d in $preservarDirs) {
            $src = Join-Path $bk $d
            if ((Test-Path $src) -and -not (Test-Path $d)) { Copy-Item $src $d -Recurse -Force; Log "restaurado $d/" }
        }
        Remove-Item $bk -Recurse -Force -ErrorAction SilentlyContinue
    } finally {
        Pop-Location
    }
}

# 5) correr el pipeline. Out-File -Encoding utf8 (y no '*> archivo'): la
#    redireccion nativa de PS 5.1 escribe UTF-16 y el log queda ilegible.
$script:lineasSync | Out-File -FilePath $logRun -Encoding utf8
& $scriptMain *>&1 | Out-File -FilePath $logRun -Encoding utf8 -Append
