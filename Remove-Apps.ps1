[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Name,
    [string]$ListUrl,
    [switch]$Info
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$configPath = if (-not [string]::IsNullOrWhiteSpace($scriptRoot)) { Join-Path $scriptRoot 'config.json' } else { $null }
$defaultRepository = 'EixX0/EIX-Extermination-Apps'
$defaultBranch = 'main'

function Get-ListUrl {
    param([string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }

    $repository = $defaultRepository
    $branch = $defaultBranch
    if (-not [string]::IsNullOrWhiteSpace($configPath) -and (Test-Path -LiteralPath $configPath)) {
        $settings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$settings.repository)) {
            $repository = [string]$settings.repository
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$settings.branch)) {
            $branch = [string]$settings.branch
        }
    }

    if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "El repositorio configurado en config.json no tiene el formato usuario/repositorio."
    }
    $encodedBranch = [uri]::EscapeDataString($branch)
    return "https://raw.githubusercontent.com/$repository/$encodedBranch/apps.json"
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

function Show-ToolHeader {
    Write-Host ''
    Write-Host 'EIX OS  //  HORIZON 02' -ForegroundColor Cyan
    Write-Host 'APP CONTROL  ·  WINDOWS 11' -ForegroundColor DarkCyan
    Write-Host 'BEYOND THE HORIZON' -ForegroundColor Gray
    Write-Host ''
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

function Show-AppInfo {
    param([string]$Query)

    Write-Host "`nIDENTIFICACIÓN DE APLICACIÓN  //  $Query" -ForegroundColor Cyan
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "`nCATÁLOGO WINGET  //  COPIA EL VALOR DE Id" -ForegroundColor Cyan
        & winget.exe search --query $Query --source winget --accept-source-agreements
        Write-Host "`nAPLICACIONES INSTALADAS RECONOCIDAS POR WINGET" -ForegroundColor Cyan
        & winget.exe list --query $Query
    }
    else {
        Write-Warning 'No encuentro WinGet. Continúo buscando paquetes Appx.'
    }

    $appxPackages = @(Get-AppxPackage | Where-Object {
        ([string]$_.Name).IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        ([string]$_.PackageFullName).IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    } | Select-Object Name, PackageFullName, Publisher)
    Write-Host "`nPAQUETES APPX DE ESTE USUARIO  //  COPIA Name" -ForegroundColor Cyan
    if ($appxPackages.Count -gt 0) {
        $appxPackages | Format-Table -AutoSize
    }
    else {
        Write-Host 'No encontré paquetes Appx con ese texto.'
    }

    $tokens = @($Query -split '[^A-Za-z0-9]+' | Where-Object { $_.Length -ge 3 } | Select-Object -Unique)
    $roots = @(
        [pscustomobject]@{ Name = 'LocalAppData'; Path = $env:LOCALAPPDATA },
        [pscustomobject]@{ Name = 'RoamingAppData'; Path = $env:APPDATA },
        [pscustomobject]@{ Name = 'ProgramData'; Path = $env:PROGRAMDATA },
        [pscustomobject]@{ Name = 'ProgramFiles'; Path = $env:ProgramFiles },
        [pscustomobject]@{ Name = 'ProgramFilesX86'; Path = ${env:ProgramFiles(x86)} }
    )
    $candidateCount = 0
    Write-Host "`nPOSIBLES RESIDUOS  //  CANDIDATOS PARA REVISAR" -ForegroundColor Cyan
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$root.Path) -or -not (Test-Path -LiteralPath $root.Path)) { continue }
        $folders = @(Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue | Where-Object {
            $folderName = $_.Name
            $matchedToken = $false
            foreach ($token in $tokens) {
                if ($folderName.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $matchedToken = $true
                    break
                }
            }
            $matchedToken
        } | Select-Object -First 20)

        foreach ($folder in $folders) {
            $relative = $folder.FullName.Substring($root.Path.TrimEnd('\').Length).TrimStart('\')
            Write-Host ("  {0}/{1}" -f $root.Name, $relative.Replace('\', '/'))
            $candidateCount++
        }
    }
    if ($candidateCount -eq 0) {
        Write-Host 'No encontré carpetas candidatas con ese texto. La búsqueda no es exhaustiva.'
    }
    Write-Host 'Las rutas candidatas no se borran automáticamente. Déjalas vacías en el formulario si no confirmas que sean propias de la app.' -ForegroundColor Gray
}

function Invoke-AppRemoval {
    param($App)

    Write-Host "`n$($App.name)" -ForegroundColor White
    if ($App.wingetId) { Write-Host "  WinGet: $($App.wingetId)" }
    foreach ($packageName in @($App.appxNames)) { Write-Host "  Appx: $packageName" }
    foreach ($residue in @($App.residualPaths)) {
        if ($null -ne $residue) { Write-Host "  Residuo: $($residue.root)/$($residue.path)" }
    }

    $warnings = @()

    if ($App.wingetId) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $winget) {
            Write-Warning "No encuentro WinGet. Se omitio la desinstalacion de '$($App.name)' por WinGet."
            $warnings += 'No se pudo usar WinGet.'
        }
        else {
            & winget.exe uninstall --id ([string]$App.wingetId) --exact --silent --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "WinGet devolvio el codigo $LASTEXITCODE para '$($App.name)'; continuare con Appx y residuos indicados."
                $warnings += "WinGet devolvio el codigo $LASTEXITCODE."
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

    Write-Host "Proceso terminado para '$($App.name)'." -ForegroundColor Cyan
    return [pscustomobject]@{ Warnings = @($warnings) }
}

try {
    Show-ToolHeader

    if ($Info) {
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-Host 'Nombre de la app que quieres buscar' }
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        Show-AppInfo -Query $Name
        return
    }

    $uri = Get-ListUrl -Override $ListUrl
    Write-Host "Leyendo lista web: $uri" -ForegroundColor DarkCyan
    $apps = @(Get-Manifest -Url $uri)
    if ($apps.Count -eq 0) {
        Write-Host 'La lista aun no contiene apps. Abre la pagina del proyecto y agrega una.' -ForegroundColor Yellow
        return
    }

    $batchAll = [string]::IsNullOrWhiteSpace($Name)
    if ($batchAll) {
        $selected = @($apps)
    }
    else {
        $selected = @($apps | Where-Object { $_.name -ieq $Name })
        if ($selected.Count -ne 1) {
            throw "No encontre exactamente una app llamada '$Name' en la lista web."
        }
    }

    Write-Host "`nRESUMEN DE ELIMINACIÓN" -ForegroundColor Cyan
    Write-Host ("Se procesarán {0} app(s) de la lista:" -f $selected.Count) -ForegroundColor White
    foreach ($app in $selected) {
        Write-Host "  • $($app.name)" -ForegroundColor Gray
        if ($app.wingetId) { Write-Host "      WinGet: $($app.wingetId)" -ForegroundColor DarkGray }
        foreach ($packageName in @($app.appxNames)) { Write-Host "      Appx: $packageName" -ForegroundColor DarkGray }
        foreach ($residue in @($app.residualPaths)) {
            if ($null -ne $residue) { Write-Host "      Residuo: $($residue.root)/$($residue.path)" -ForegroundColor DarkGray }
        }
    }

    if ($WhatIfPreference) {
        Write-Host "`nVista previa: no se desinstaló ni borró nada." -ForegroundColor Yellow
        return
    }

    $expected = if ($batchAll) { 'BORRAR TODO' } else { 'BORRAR' }
    Write-Host "`nLa operación quitará las apps seleccionadas y borrará únicamente las rutas de residuos indicadas arriba." -ForegroundColor Yellow
    $confirmation = Read-Host "Escribe $expected para continuar (cualquier otra respuesta cancela)"
    if (-not [string]::Equals($confirmation, $expected, [System.StringComparison]::Ordinal)) {
        Write-Host 'Operación cancelada. No se hicieron cambios.' -ForegroundColor Yellow
        return
    }

    $completed = @()
    $withWarnings = @()
    $failed = @()
    foreach ($app in $selected) {
        try {
            $result = Invoke-AppRemoval -App $app
            $completed += [string]$app.name
            if (@($result.Warnings).Count -gt 0) {
                $withWarnings += [string]$app.name
            }
        }
        catch {
            Write-Host "Error en '$($app.name)': $($_.Exception.Message)" -ForegroundColor Red
            $failed += [string]$app.name
        }
    }

    Write-Host "`nRESULTADO" -ForegroundColor Cyan
    Write-Host ("Procesadas: {0}  |  Con advertencias: {1}  |  Con error: {2}" -f $completed.Count, $withWarnings.Count, $failed.Count)
    if ($failed.Count -gt 0) { Write-Host ("Revisa estas apps: {0}" -f ($failed -join ', ')) -ForegroundColor Red }
}
catch {
    throw $_
}

