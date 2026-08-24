param(
    [string]$EnvFile = ".env.staging"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    throw "psql no esta instalado o no esta en PATH."
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    throw "No existe $EnvFile. Copia .env.example a .env.staging y completa DATABASE_URL."
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

if (-not $env:DATABASE_URL) {
    throw "DATABASE_URL no esta configurado en $EnvFile."
}

$migrations = Get-ChildItem -LiteralPath "database/migrations" -Filter "*.sql" |
    Sort-Object Name

foreach ($migration in $migrations) {
    Write-Host "Aplicando $($migration.Name)..."
    psql $env:DATABASE_URL -v ON_ERROR_STOP=1 -f $migration.FullName
}

Write-Host "Migraciones aplicadas correctamente."
