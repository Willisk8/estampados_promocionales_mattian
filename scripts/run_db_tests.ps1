param(
    [string]$EnvFile = ".env.staging",
    [switch]$ConfirmStaging
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

if (-not $env:DATABASE_URL) {
    if (-not $ConfirmStaging) {
        throw @"
DATABASE_URL no esta configurado. Este script ya NO carga $EnvFile por
defecto: ese archivo trae credenciales completas (SUPABASE_SERVICE_ROLE_KEY,
HMAC_SUPPRESSION_SECRET), y cargarlas al proceso sin querer solo para correr
tests locales es un riesgo innecesario.
  - Para Postgres local: define DATABASE_URL apuntando a tu instancia local.
  - Para correr de verdad contra STAGING: pasa -ConfirmStaging explicitamente.
"@
    }

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

<#
    El chequeo de arriba solo cubre el caso en que DATABASE_URL llega vacia.
    Si ya viene definida apuntando a STAGING -variable de usuario persistente,
    o resto de una tarea anterior en la misma shell- la suite destructiva
    corre sin pedir nada, exactamente el accidente que -ConfirmStaging existe
    para evitar, solo que entrando por la otra puerta. Por eso se valida el
    host en vez de solo la presencia de la variable.
#>
function Test-HostLocal {
    <#
        [Uri].Host normaliza una IPv6 loopback ("[::1]") a su forma expandida
        con corchetes ("[0000:...:0001]"), que nunca coincide contra el
        string literal "::1" -codigo muerto si se compara como texto-. Por
        eso se quitan los corchetes y se compara como IP con IsLoopback en
        vez de una lista de strings.
    #>
    param([string]$HostName)
    if ($HostName -eq "localhost") {
        return $true
    }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($HostName.Trim("[", "]"), [ref]$ip)) {
        return [System.Net.IPAddress]::IsLoopback($ip)
    }
    return $false
}

$databaseHost = ([Uri]$env:DATABASE_URL).Host
if ((-not (Test-HostLocal -HostName $databaseHost)) -and (-not $ConfirmStaging)) {
    throw @"
DATABASE_URL no apunta a un host local ($databaseHost). Este script corre
tests destructivos y no debe hacerlo contra STAGING sin confirmacion
explicita, aunque la variable ya venga definida.
  - Si es un error: define DATABASE_URL apuntando a tu Postgres local.
  - Si de verdad quieres correr contra ese destino: pasa -ConfirmStaging.
"@
}

$tests = Get-ChildItem -LiteralPath "database/tests" -Filter "*.sql" |
    Sort-Object Name

foreach ($test in $tests) {
    Write-Host "Ejecutando $($test.Name)..."
    Invoke-PsqlChecked `
        -Arguments @("-v", "ON_ERROR_STOP=1", "-f", $test.FullName, $env:DATABASE_URL) `
        -Context "ejecutar test $($test.Name)"
}

Write-Host "Tests de base de datos completados."
