[CmdletBinding()]
param(
    [Parameter()]
    [switch]$UseDebugKey
)

$OutputEncoding = [System.Console]::InputEncoding = [System.Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- CONFIGURACAO ---
$ENV_FILE_PATHS = @(".env", "QrLinkki.Web\.env")
$REQUIRED_ENV_VARS = @("API_URL")
$EXPO_PROJECT_SUBDIR = "QrLinkki.Web"
$KEYSTORE_REL_PATH = "keystores\qrlinkki-release.jks"

function Get-ProjectRoot {
    return (Get-Location).Path
}

function Load-EnvFile {
    param([string]$RootPath)
    
    foreach ($path in $ENV_FILE_PATHS) {
        $fullPath = Join-Path $RootPath $path
        if (Test-Path $fullPath) {
            Write-Host " [Configuration] Carregando .env de: $fullPath" -ForegroundColor Gray
            Get-Content $fullPath | ForEach-Object {
                $line = $_.Trim()
                if ($line -match "^[^#=]+=[^#]+$") {
                    $parts = $line -split "=", 2
                    $key = $parts[0].Trim()
                    $val = $parts[1].Trim().Trim('"').Trim("'")
                    Set-Item -Path "env:$key" -Value $val -ErrorAction SilentlyContinue
                }
            }
            return
        }
    }
    Write-Warning "Arquivo .env nao encontrado. Assumindo que variaveis ja estao no ambiente."
}

function Assert-EnvVars {
    foreach ($var in $REQUIRED_ENV_VARS) {
        if (-not (Get-Item "env:$var" -ErrorAction SilentlyContinue)) {
            throw "Variavel de ambiente obrigatoria faltando: $var"
        }
    }
}

function Get-SigningConfig {
    param([string]$RootPath, [switch]$ForceDebug)

    $ksPath = Join-Path $RootPath $KEYSTORE_REL_PATH
    $hasKeystoreFile = Test-Path $ksPath
    $hasCreds = ($env:KEYSTORE_PASSWORD -and $env:KEY_ALIAS)
    
    if ($ForceDebug) {
        return @{ Type = "Debug"; Reason = "Solicitado pelo usuario (-UseDebugKey)" }
    }

    if ($hasKeystoreFile -and $hasCreds) {
        return @{ 
            Type = "Release"; 
            Path = $ksPath; 
            Reason = "Keystore e credenciais encontradas" 
        }
    }

    if ($hasKeystoreFile -and -not $hasCreds) {
        Write-Warning "Keystore encontrada ($ksPath) mas SEM senhas no ambiente."
        Write-Warning "Para usar Release Key, configure KEYSTORE_PASSWORD e KEY_ALIAS no .env."
        return @{ Type = "Debug"; Reason = "Credenciais de Release faltando (Fallback)" }
    }

    return @{ Type = "Debug"; Reason = "Keystore de Release nao encontrada (Fallback)" }
}

function Should-Run-ExpoPrebuild {
    param([string]$RootPath)

    # If running locally (no GITHUB_REF), default to true to be safe
    if (-not (Test-Path ".git")) { return $true }

    # Try to fetch base branch (dev) and check for changes in native-related files
    try {
        git fetch origin dev --depth=1 | Out-Null
    } catch {
        # If fetch fails, be conservative and run prebuild
        return $true
    }

    $diff = git diff --name-only origin/dev...HEAD
    if (-not $diff) { return $true }

    $patterns = @(
        '^QrLinkki.Web/package.json',
        '^QrLinkki.Web/app.json',
        '^QrLinkki.Web/app.config.js',
        '^QrLinkki.Web/package-lock.json',
        '^QrLinkki.Web/app/.*',
        '^QrLinkki.Web/assets/.*',
        '^QrLinkki.Web/scripts/.*',
        '^QrLinkki.Web/expo.*'
    )

    foreach ($p in $patterns) {
        if ($diff -match $p) { return $true }
    }

    return $false
}

# --- EXECUCAO PRINCIPAL ---
try {
    Write-Host "`n=== QrLinkki Android Staging CI Build (optimized) ===`n" -ForegroundColor Cyan

    $rootPath = Get-ProjectRoot
    Load-EnvFile -RootPath $rootPath
    Assert-EnvVars

    # Define STAGING context
    $env:BUILD_ENV = "staging"
    $env:EXPO_PUBLIC_BUILD_ENV = "staging"
    $env:NODE_ENV = "production"
    Write-Host " [Environment] API_URL: $env:API_URL" -ForegroundColor Gray
    Write-Host " [Environment] Build Mode: STAGING (CI optimized)" -ForegroundColor Gray

    # Locate Expo
    $expoRoot = Join-Path $rootPath $EXPO_PROJECT_SUBDIR
    if (-not (Test-Path "$expoRoot\package.json")) {
        if (Test-Path "$rootPath\package.json") { $expoRoot = $rootPath }
        else { throw "Projeto Expo nao encontrado." }
    }

    # Prebuild: run only if necessary to save time on CI
    Write-Host "`n [Expo] Checking whether prebuild is needed..." -ForegroundColor Gray
    Push-Location $expoRoot
    $needPrebuild = Should-Run-ExpoPrebuild -RootPath $rootPath
    if ($needPrebuild) {
        Write-Host " [Expo] Running prebuild (native changes detected)" -ForegroundColor Gray
        & npx expo prebuild --platform android --no-install --clean
        if ($LASTEXITCODE -ne 0) { throw "Falha no expo prebuild." }
    } else {
        Write-Host " [Expo] No native changes detected — skipping prebuild to speed up CI." -ForegroundColor Yellow
    }
    Pop-Location

    # Signing config
    $signing = Get-SigningConfig -RootPath $rootPath -ForceDebug:$UseDebugKey
    $gradleArgs = @("assembleRelease")
    if ($signing.Type -eq "Release") {
        Write-Host " [Signing] MODO RELEASE (Producao)" -ForegroundColor Green
        Write-Host "           Usando: $($signing.Path)" -ForegroundColor Gray
        $gradleArgs += "-PKEYSTORE_PATH=$($signing.Path)"
        $gradleArgs += "-PKEYSTORE_PASSWORD=$env:KEYSTORE_PASSWORD"
        $gradleArgs += "-PKEY_ALIAS=$env:KEY_ALIAS"
        $gradleArgs += "-PKEY_PASSWORD=$($env:KEY_PASSWORD)"
    } else {
        Write-Host " [Signing] MODO DEBUG (Teste Rapido)" -ForegroundColor Yellow
        Write-Host "           Motivo: $($signing.Reason)" -ForegroundColor Yellow
        $gradleArgs += "-PSTAGING_USE_DEBUG_KEY=true"
    }

    # Build Gradle
    $androidDir = Join-Path $expoRoot "android"
    $gradlew = Join-Path $androidDir "gradlew.bat"
    Write-Host "`n [Gradle] Iniciando compilacao..." -ForegroundColor Gray
    Push-Location $androidDir
    & $gradlew @gradleArgs
    if ($LASTEXITCODE -ne 0) { throw "Falha no build do Gradle." }
    Pop-Location

    # Finalization
    $apkSource = Join-Path $androidDir "app\build\outputs\apk\release\app-release.apk"
    $apkDest = Join-Path $androidDir "app\build\outputs\apk\release\app-staging.apk"
    if (Test-Path $apkSource) {
        Copy-Item -Path $apkSource -Destination $apkDest -Force
        Write-Host "`n Sucesso! APK gerado em:" -ForegroundColor Green
        Write-Host " $apkDest" -ForegroundColor Cyan
    } else {
        throw "APK nao encontrado apos build."
    }

} catch {
    Write-Host "`n [ERRO CRITICO] $_" -ForegroundColor Red
    exit 1
} finally {
    Set-Location $rootPath
}