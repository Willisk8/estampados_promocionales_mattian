param(
    [string]$EnvFile = ".env.staging"
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
}

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

if (-not $env:DATABASE_URL) {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        throw "DATABASE_URL no esta configurado y no existe $EnvFile."
    }

    Get-Content -LiteralPath $EnvFile | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) {
            return
        }
        $parts = $line.Split("=", 2)
        if ($parts.Count -eq 2) {
            [Environment]::SetEnvironmentVariable($parts[0], $parts[1], "Process")
        }
    }
}

if (-not $env:DATABASE_URL) {
    throw "DATABASE_URL no esta configurado."
}

$tests = Get-ChildItem -LiteralPath "database/tests" -Filter "*.sql" |
    Sort-Object Name

foreach ($test in $tests) {
    Write-Host "Ejecutando $($test.Name)..."
    Invoke-PsqlChecked `
        -Arguments @($env:DATABASE_URL, "-v", "ON_ERROR_STOP=1", "-f", $test.FullName) `
        -Context "ejecutar test $($test.Name)"
}

Write-Host "Tests de base de datos completados."
