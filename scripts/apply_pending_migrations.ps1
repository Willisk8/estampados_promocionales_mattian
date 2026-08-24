param(
    [string]$MigrationsDir = "database/migrations",
    [string]$DatabaseUrl = $env:DATABASE_URL
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    throw "psql no esta instalado o no esta en PATH."
}

if (-not $DatabaseUrl) {
    throw "DATABASE_URL no esta configurado."
}

psql $DatabaseUrl -v ON_ERROR_STOP=1 -c @"
CREATE TABLE IF NOT EXISTS schema_migrations (
    filename TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
"@

$migrations = Get-ChildItem -LiteralPath $MigrationsDir -Filter "*.sql" |
    Sort-Object Name

foreach ($migration in $migrations) {
    $filename = $migration.Name
    $alreadyApplied = psql $DatabaseUrl -At -v ON_ERROR_STOP=1 -c "SELECT 1 FROM schema_migrations WHERE filename = '$filename';"

    if ($alreadyApplied -eq "1") {
        Write-Host "Saltando $filename (ya aplicada)."
        continue
    }

    Write-Host "Aplicando $filename..."
    psql $DatabaseUrl -v ON_ERROR_STOP=1 -1 -f $migration.FullName
    psql $DatabaseUrl -v ON_ERROR_STOP=1 -c "INSERT INTO schema_migrations (filename) VALUES ('$filename');"
}

Write-Host "Migraciones pendientes aplicadas correctamente."
