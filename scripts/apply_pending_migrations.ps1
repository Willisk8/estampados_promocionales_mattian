param(
    [string]$MigrationsDir = "database/migrations",
    [string]$DatabaseUrl = $env:DATABASE_URL
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

function ConvertTo-PsqlLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )
    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-PsqlIncludePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )
    return $Value.Replace("\", "/").Replace("'", "''")
}

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    throw "psql no esta instalado o no esta en PATH."
}

if (-not $DatabaseUrl) {
    throw "DATABASE_URL no esta configurado."
}

Invoke-PsqlChecked `
    -Arguments @($DatabaseUrl, "-v", "ON_ERROR_STOP=1", "-c", @"
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
"@) `
    -Context "inicializar schema_migrations"

$migrations = Get-ChildItem -LiteralPath $MigrationsDir -Filter "*.sql" |
    Sort-Object Name

foreach ($migration in $migrations) {
    $filename = $migration.Name
    $filenameLiteral = ConvertTo-PsqlLiteral $filename
    $alreadyApplied = & psql $DatabaseUrl -At -v ON_ERROR_STOP=1 -c "SELECT 1 FROM schema_migrations WHERE filename = $filenameLiteral;"
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "psql fallo ($exitCode): consultar schema_migrations para $filename"
    }

    if ($alreadyApplied -eq "1") {
        Write-Host "Saltando $filename (ya aplicada)."
        continue
    }

    Write-Host "Aplicando $filename..."
    $migrationPath = ConvertTo-PsqlIncludePath $migration.FullName
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("apply_migration_" + [guid]::NewGuid().ToString("N") + ".sql")
    $script = @"
\set ON_ERROR_STOP on
BEGIN;
\i '$migrationPath'
INSERT INTO schema_migrations (filename) VALUES ($filenameLiteral);
COMMIT;
"@
    Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8
    try {
        Invoke-PsqlChecked `
            -Arguments @($DatabaseUrl, "-v", "ON_ERROR_STOP=1", "-f", $scriptPath) `
            -Context "aplicar y registrar $filename"
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Migraciones pendientes aplicadas correctamente."
