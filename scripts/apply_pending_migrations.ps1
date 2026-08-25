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
ALTER TABLE schema_migrations ENABLE ROW LEVEL SECURITY;
DO `$`$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies
        WHERE schemaname = current_schema()
          AND tablename = 'schema_migrations'
          AND policyname = 'deny_all'
    ) THEN
        CREATE POLICY deny_all ON schema_migrations
            AS RESTRICTIVE FOR ALL USING (false);
    END IF;
END `$`$;
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
