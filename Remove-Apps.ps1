[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Name,
    [string]$ListUrl
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptRoot 'config.json'

function Get-ListUrl {
    param([string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "No encuentro config.json junto al script. Sigue los pasos de publicacion del README."
    }

    $settings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$settings.repository) -or $settings.repository -match 'TU_USUARIO|tu-lista-apps') {
        throw "Configura repository en config.json con tu usuario y repositorio de GitHub."
    }

    $branch = [string]$settings.branch
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = 'main' }
    $encodedBranch = [uri]::EscapeDataString($branch)
    return "https://raw.githubusercontent.com/$($settings.repository)/$encodedBranch/apps.json"
}

function Get-Manifest {
    param([string]$Url)

    $response = Invoke-RestMethod -Uri $Url -Method Get -Headers @{ 'Cache-Control' = 'no-cache' }
    if ($null -eq $response.apps -or $response.apps -isnot [System.Array]) {
        throw "La lista remota no tiene el formato esperado (debe contener 'apps')."
    }

    foreach ($app in $response.apps) {
        if ([string]::IsNullOrWhiteSpace([string]$app.name)) {
            throw "La lista contiene una app sin nombre."
        }
        if ([string]$app.wingetId -and [string]$app.wingetId -notmatch '^(?:[A-Za-z0-9][A-Za-z0-9._+{}-]*|\{[0-9A-Fa-f-]{20,}\})$') {
            throw "La app '$($app.name)' tiene un ID de WinGet invalido."
        }
        $appxNames = @()
        if ($null -ne $app.appxNames) {
            if ($app.appxNames -isnot [System.Array]) {
                throw "La app '$($app.name)' debe tener una lista de nombres Appx."
            }
            $appxNames = @($app.appxNames | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        }
        foreach ($packageName in $appxNames) {
            if ([string]$packageName -and [string]$packageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                throw "La app '$($app.name)' tiene un nombre Appx invalido."
            }
        }
        foreach ($residue in @($app.residualPaths)) {
            if ($null -eq $residue) { continue }
            if ([string]$residue.root -notin @('LocalAppData','RoamingAppData','ProgramData','ProgramFiles','ProgramFilesX86')) {
                throw "La app '$($app.name)' contiene una ruta de residuos no permitida."
            }
            $parts = ([string]$residue.path -replace '\\', '/').Split('/')
            $invalidParts = @($parts | Where-Object { $_ -notmatch '^[A-Za-z0-9 _().+-]+$' -or $_ -in @('.', '..') })
            if ([string]::IsNullOrWhiteSpace([string]$residue.path) -or $invalidParts.Count -gt 0) {
                throw "La app '$($app.name)' contiene una ruta de residuos insegura."
            }
        }
        if (-not $app.wingetId -and $appxNames.Count -eq 0) {
            throw "La app '$($app.name)' no especifica ningun identificador de desinstalacion."
        }
    }

    return @($response.apps)
}

function Resolve-ResiduePath {
    param($Residue)

    $roots = @{
        LocalAppData    = $env:LOCALAPPDATA
        RoamingAppData  = $env:APPDATA
        ProgramData     = $env:PROGRAMDATA
        ProgramFiles    = $env:ProgramFiles
        ProgramFilesX86 = ${env:ProgramFiles(x86)}
    }

    $base = [string]$roots[[string]$Residue.root]
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "Windows no tiene configurada la carpeta '$($Residue.root)'."
    }

    $relative = ([string]$Residue.path).Replace('/', '\')
    if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.?($|\\)') {
        throw "La ruta de residuos '$($Residue.path)' no es relativa o contiene segmentos no permitidos."
    }

    $baseFull = [System.IO.Path]::GetFullPath($base).TrimEnd('\')
    $target = [System.IO.Path]::GetFullPath((Join-Path $baseFull $relative))
    if (-not $target.StartsWith($baseFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "La ruta de residuos '$($Residue.path)' sale de su carpeta autorizada."
    }
    return $target
}

function Invoke-AppRemoval {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param($App)

    Write-Host "`n$($App.name)" -ForegroundColor Cyan
    if ($App.wingetId) { Write-Host "  WinGet: $($App.wingetId)" }
    foreach ($packageName in @($App.appxNames)) { Write-Host "  Appx: $packageName" }
    foreach ($residue in @($App.residualPaths)) {
        if ($null -ne $residue) { Write-Host "  Residuo: $($residue.root)/$($residue.path)" }
    }

    if (-not $PSCmdlet.ShouldProcess($App.name, 'Desinstalar y borrar solo los residuos indicados')) {
        return
    }

    if ($App.wingetId) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-Warning "No encuentro WinGet. Se omitio la desinstalacion de '$($App.name)' por WinGet."
        }
        else {
            & winget.exe uninstall --id ([string]$App.wingetId) --exact --silent --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "WinGet devolvio el codigo $LASTEXITCODE para '$($App.name)'; continuare con Appx y residuos indicados."
            }
        }
    }

    foreach ($packageName in @($App.appxNames)) {
        $installed = @(Get-AppxPackage | Where-Object { $_.Name -eq [string]$packageName })
        foreach ($package in $installed) {
            Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
            Write-Host "  Se quito el paquete Appx de este usuario: $($package.Name)"
        }
    }

    foreach ($residue in @($App.residualPaths)) {
        if ($null -eq $residue) { continue }
        $target = Resolve-ResiduePath -Residue $residue
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            Write-Host "  Se borro: $target"
        }
    }

    Write-Host "Proceso terminado para '$($App.name)'."
}

try {
    $uri = Get-ListUrl -Override $ListUrl
    Write-Host "Leyendo lista web: $uri"
    $apps = @(Get-Manifest -Url $uri)
    if ($apps.Count -eq 0) {
        Write-Host 'La lista aun no contiene apps. Abre la pagina del proyecto y agrega una.' -ForegroundColor Yellow
        return
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-Host "`nApps disponibles:"
        for ($i = 0; $i -lt $apps.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $apps[$i].name)
        }
        $choice = Read-Host 'Escribe el numero de la app que quieres quitar (Enter para cancelar)'
        if ([string]::IsNullOrWhiteSpace($choice)) { return }
        $index = 0
        if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $apps.Count) {
            throw 'La seleccion no es valida.'
        }
        $selected = @($apps[$index - 1])
    }
    else {
        $selected = @($apps | Where-Object { $_.name -ieq $Name })
        if ($selected.Count -ne 1) {
            throw "No encontre exactamente una app llamada '$Name' en la lista web."
        }
    }

    foreach ($app in $selected) { Invoke-AppRemoval -App $app }
}
catch {
    throw $_
}
