param(
    [string]$DatabaseUrl = $env:DATABASE_URL
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
}

<#
    ORDEN DE ARGUMENTOS DE PSQL — no reordenar.
    La cadena de conexion va SIEMPRE al final, despues de -v/-c/-f.
    El getopt de Windows no permuta: en cuanto encuentra el primer argumento
    posicional deja de interpretar opciones. Con la URL adelante, psql ignora
    -v, -c y -f, no ejecuta nada y avisa por stderr pero sale con codigo 0.
    Invoke-PsqlChecked solo mira el exit code, asi que el efecto es un fallo
    silencioso que hacia que run_db_tests.ps1 informara exito sin correr un
    solo test.
    En Linux (el runner del CI) glibc si permuta, por eso el error no se veia.
    Con la URL al final funciona igual en las dos plataformas.
#>
function Invoke-PsqlChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [Parameter(Mandatory = $true)]
        [string]$Context
    )

    & psql @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "psql fallo ($exitCode): $Context"
    }
}

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    throw "psql no esta instalado o no esta en PATH."
}

if (-not $DatabaseUrl) {
    throw "DATABASE_URL no esta configurado."
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$runner = Join-Path $repoRoot "scripts/apply_pending_migrations.ps1"
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("bad_migration_" + [guid]::NewGuid().ToString("N"))
$badFilename = "999_intentional_failure_" + [guid]::NewGuid().ToString("N") + ".sql"
$badPath = Join-Path $tmpDir $badFilename

New-Item -ItemType Directory -Path $tmpDir | Out-Null
Set-Content -LiteralPath $badPath -Encoding UTF8 -Value @"
-- Esta migracion debe fallar para probar el ejecutor.
SELECT * FROM tabla_que_no_debe_existir_para_test_runner;
"@

try {
    $failedAsExpected = $false
    try {
        & $runner -MigrationsDir $tmpDir -DatabaseUrl $DatabaseUrl
    } catch {
        $failedAsExpected = $true
        Write-Host "PASSED - migracion invalida fallo como se esperaba."
    }

    if (-not $failedAsExpected) {
        throw "El ejecutor acepto una migracion invalida."
    }

    $filenameLiteral = "'" + ($badFilename -replace "'", "''") + "'"
    $registered = & psql -At -v ON_ERROR_STOP=1 -c "SELECT COUNT(*) FROM schema_migrations WHERE filename = $filenameLiteral;" $DatabaseUrl
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "psql fallo ($exitCode): verificar que migracion invalida no fue registrada"
    }

    if ($registered.Trim() -ne "0") {
        throw "La migracion invalida quedo registrada en schema_migrations."
    }

    Write-Host "PASSED - migracion invalida no quedo registrada."
} finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
