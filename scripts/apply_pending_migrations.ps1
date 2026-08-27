param(
    [string]$MigrationsDir = "database/migrations",
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

function Get-NormalizedSha256 {
    <#
        SHA-256 sobre el contenido normalizado, no sobre los bytes crudos.
        Git entrega CRLF en Windows y LF en el runner de CI; hashear los bytes
        crudos daria dos checksums distintos para el mismo archivo y el runner
        abortaria en una de las dos plataformas.
        Debe coincidir con scripts/audit_change.py y con
        scripts/backfill_migration_checksums.py.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bytes = $bytes[3..($bytes.Length - 1)]
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes).Replace("`r`n", "`n")

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLower()
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
    # psql \i recibe un path de filesystem entre comillas simples. Dentro de
    # ese contexto una comilla simple se escapa con backslash, no duplicandola
    # como literal SQL.
    return $Value.Replace("\", "/").Replace("'", "\'")
}

if (-not (Get-Command psql -ErrorAction SilentlyContinue)) {
    throw "psql no esta instalado o no esta en PATH."
}

if (-not $DatabaseUrl) {
    throw "DATABASE_URL no esta configurado."
}

Invoke-PsqlChecked `
    -Arguments @("-v", "ON_ERROR_STOP=1", "-c", @"
CREATE TABLE IF NOT EXISTS public.schema_migrations (
    filename TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Se califica con public. porque Supabase tiene otras tablas llamadas
-- schema_migrations en los esquemas auth y realtime.
ALTER TABLE public.schema_migrations
    ADD COLUMN IF NOT EXISTS checksum_sha256 TEXT;
ALTER TABLE public.schema_migrations
    ADD COLUMN IF NOT EXISTS checksum_backfilled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.schema_migrations ENABLE ROW LEVEL SECURITY;
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
"@, $DatabaseUrl) `
    -Context "inicializar schema_migrations"

$migrations = Get-ChildItem -LiteralPath $MigrationsDir -Filter "*.sql" |
    Sort-Object Name

foreach ($migration in $migrations) {
    $filename = $migration.Name
    $filenameLiteral = ConvertTo-PsqlLiteral $filename
    $checksum = Get-NormalizedSha256 -Path $migration.FullName
    $checksumLiteral = ConvertTo-PsqlLiteral $checksum

    $registered = & psql -At -F "|" -v ON_ERROR_STOP=1 -c `
        "SELECT coalesce(checksum_sha256, ''), checksum_backfilled FROM public.schema_migrations WHERE filename = $filenameLiteral;" `
        $DatabaseUrl
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "psql fallo ($exitCode): consultar schema_migrations para $filename"
    }

    if ($registered) {
        $parts = ([string]$registered).Split("|", 2)
        $recordedChecksum = $parts[0]
        $backfilled = ($parts.Count -gt 1 -and $parts[1] -eq "t")

        if (-not $recordedChecksum) {
            Write-Host "Saltando $filename (ya aplicada, sin checksum registrado)."
        }
        elseif ($recordedChecksum -eq $checksum) {
            Write-Host "Saltando $filename (ya aplicada, checksum coincide)."
        }
        elseif ($backfilled) {
            # El checksum se registro despues de aplicar la migracion, asi que
            # no sabemos si el archivo cambio antes o despues de ese registro.
            Write-Warning "$filename cambio respecto al checksum reconstruido. Revisar manualmente."
        }
        else {
            throw @"
$filename ya fue aplicada y su contenido cambio.
  registrado: $recordedChecksum
  actual:     $checksum
Una migracion aplicada no se edita: crea una migracion nueva.
"@
        }
        continue
    }

    Write-Host "Aplicando $filename..."
    $migrationPath = ConvertTo-PsqlIncludePath $migration.FullName
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("apply_migration_" + [guid]::NewGuid().ToString("N") + ".sql")
    $script = @"
\set ON_ERROR_STOP on
BEGIN;
\i '$migrationPath'
INSERT INTO public.schema_migrations (filename, checksum_sha256, checksum_backfilled)
VALUES ($filenameLiteral, $checksumLiteral, false);
COMMIT;
"@
    Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8
    try {
        Invoke-PsqlChecked `
            -Arguments @("-v", "ON_ERROR_STOP=1", "-f", $scriptPath, $DatabaseUrl) `
            -Context "aplicar y registrar $filename"
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Migraciones pendientes aplicadas correctamente."
