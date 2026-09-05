# ==========================================================================
#  correr_servidor.ps1  -  Lo que ejecuta la tarea programada en el servidor
# ==========================================================================
#  v2 (04/09/2026, reescrito tras la primera instalacion en el servidor).
#
#  El servidor se pone IGUAL que origin/main:  git fetch  +  git reset --hard.
#  No hay pull ni merge: el servidor nunca commitea, asi que "espejo de GitHub"
#  es exactamente lo que se quiere. Esto aguanta force-push, historia divergida
#  y archivos regenerados sucios -- todo eso a `git pull --ff-only` lo trababa
#  PARA SIEMPRE y en silencio (paso el 04/09: inicio.html y fuentes/ecuador.json
#  quedaban modificados tras cada corrida y el primer commit que los tocara
#  iba a dejar al servidor corriendo codigo viejo sin que nadie se enterara).
#
#  Tres clases de archivos:
#    $preservar   DEL SERVIDOR (config, estado anti-spam, caches, logs). Se
#                 respaldan antes del reset y se restauran despues, SIEMPRE,
#                 creando las carpetas que falten (el primer pull borro config\
#                 entera y la restauracion v1 fallaba por eso). Su version manda.
#    $entradas    DE LA LAPTOP (planillas). Viajan por git. Si alguien las edito
#                 en el servidor, se guardan en respaldos_servidor\<fecha>\ y se
#                 avisa en el log ANTES de pisarlas. Nunca se pierden en silencio.
#    el resto     codigo y dashboards regenerados: lo que diga GitHub.
#
#  Si el fetch falla (sin internet, sin credenciales) corre igual con el codigo
#  local y lo deja anotado en la PRIMERA linea de last_run.log.
#
#  Se registra desde setup_servidor.ps1. Tambien se puede correr a mano:
#     & "<esta-carpeta>\correr_servidor.ps1"
# ==========================================================================
$ErrorActionPreference = 'Continue'
$base       = $PSScriptRoot
$logRun     = Join-Path $base 'last_run.log'
$scriptMain = Join-Path $base 'actualizar_precios.ps1'

$preservar = @(
    'config/whatsapp.json',
    'fuentes/state_alertas.json',
    'fuentes/state_whatsapp.json',
    'fuentes/precios_py_cache.json',
    'fuentes/indexmundi_cache.json',
    'alertas.log'
)
$preservarDirs = @('fuentes/clima_archive_cache')

$entradas = @(
    'fuentes/cargas 2026.xlsx',
    'fuentes/productores.xlsx',
    'fuentes/calidad_lotes.xlsx'
)

$script:lineasSync = @()
function Log { param([string]$t) $script:lineasSync += "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] [sync] $t" }
function Copiar-Seguro {
    # Copy-Item -Force NO crea la carpeta destino: si falta, revienta. Aca se crea.
    param([string]$desde, [string]$hacia)
    $dir = Split-Path $hacia -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $desde -Destination $hacia -Force
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Log "git no esta instalado: corro con el codigo local. Para sincronizar con GitHub instalar Git for Windows."
} elseif (-not (Test-Path (Join-Path $base '.git'))) {
    Log "la carpeta no es un clon git: corro con el codigo local (ver MIGRACION_SERVIDOR.md, seccion 13)."
} else {
    Push-Location $base
    try {
        $baseAbs = (Resolve-Path $base).Path
        $antes   = (git rev-parse --short HEAD 2>$null)
        $fetchOut = (git fetch origin 2>&1 | Out-String).Trim() -replace '\s+', ' '
        if ($LASTEXITCODE -ne 0) {
            Log "git fetch FALLO, corro con el codigo local ($antes): $fetchOut"
        } else {
            $upstream = (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
            if (-not $upstream) { $upstream = 'origin/main' }

            # 1) respaldo de lo que es del servidor
            $bk = Join-Path $env:TEMP ('poronga_estado_' + (Get-Date).ToString('yyyyMMdd_HHmmss'))
            foreach ($p in $preservar) { if (Test-Path -LiteralPath $p) { Copiar-Seguro $p (Join-Path $bk $p) } }
            foreach ($d in $preservarDirs) {
                if (Test-Path -LiteralPath $d) {
                    Get-ChildItem -LiteralPath $d -File -Recurse | ForEach-Object {
                        $rel = $_.FullName.Substring($baseAbs.Length + 1)
                        Copiar-Seguro $_.FullName (Join-Path $bk $rel)
                    }
                }
            }

            # 2) planillas editadas en el servidor (no deberian): respaldo + aviso
            $sucias = @(git status --porcelain -- $entradas 2>$null | Where-Object { $_ })
            if ($sucias.Count -gt 0) {
                $rs = Join-Path $base ('respaldos_servidor\' + (Get-Date).ToString('yyyyMMdd_HHmmss'))
                $nombres = @()
                foreach ($l in $sucias) {
                    $f = $l.Substring(3).Trim().Trim('"')
                    $nombres += $f
                    if (Test-Path -LiteralPath $f) { Copiar-Seguro $f (Join-Path $rs $f) }
                }
                Log "AVISO: planilla(s) editadas en el servidor, respaldadas en $rs y pisadas por la version de GitHub: $($nombres -join ', ')"
            }

            # 3) espejo de GitHub
            $resetOut = (git reset --hard $upstream 2>&1 | Out-String).Trim() -replace '\s+', ' '
            if ($LASTEXITCODE -ne 0) {
                Log "git reset --hard $upstream FALLO, corro con el codigo local ($antes): $resetOut"
            } else {
                $despues = (git rev-parse --short HEAD 2>$null)
                if ($antes -ne $despues) { Log "sync OK: $antes -> $despues ($upstream)" } else { Log "sync OK: sin cambios ($despues)" }
            }

            # 4) restaurar lo que es del servidor, siempre: su version manda
            if (Test-Path -LiteralPath $bk) {
                Get-ChildItem -LiteralPath $bk -File -Recurse | ForEach-Object {
                    $rel = $_.FullName.Substring($bk.Length + 1)
                    Copiar-Seguro $_.FullName (Join-Path $base $rel)
                }
                Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        Pop-Location
    }
}

# 5) correr el pipeline. Out-File -Encoding utf8 (y no '*> archivo'): la
#    redireccion nativa de PS 5.1 escribe UTF-16 y el log queda ilegible.
$script:lineasSync | Out-File -FilePath $logRun -Encoding utf8
& $scriptMain *>&1 | Out-File -FilePath $logRun -Encoding utf8 -Append
