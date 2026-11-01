[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Name,
    [string]$ListUrl,
    [switch]$Info,
    [switch]$ListOnly,
    [switch]$All,
    [switch]$RequestInstalled
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$configPath = if (-not [string]::IsNullOrWhiteSpace($scriptRoot)) { Join-Path $scriptRoot 'config.json' } else { $null }
$defaultRepository = 'EixX0/EIX-Extermination-Apps'
$defaultBranch = 'main'

function Get-RepositorySettings {
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
    return [pscustomobject]@{ Repository = $repository; Branch = $branch }
}

function Get-ListUrl {
    param([string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }

    $settings = Get-RepositorySettings
    $repository = [string]$settings.Repository
    $branch = [string]$settings.Branch
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
        if ($null -ne $app.programFolder) {
            $programFolder = $app.programFolder
            if ([string]$programFolder.root -notin @('LocalAppData','RoamingAppData','ProgramData','ProgramFiles','ProgramFilesX86')) {
                throw "La app '$($app.name)' contiene una carpeta de programa no permitida."
            }
            $parts = ([string]$programFolder.path).Replace([string][char]92, '/').Split('/')
            $invalidParts = @($parts | Where-Object { $_ -notmatch '^[A-Za-z0-9 _().+-]+$' -or $_ -in @('.', '..') })
            if ([string]::IsNullOrWhiteSpace([string]$programFolder.path) -or $invalidParts.Count -gt 0) {
                throw "La app '$($app.name)' contiene una carpeta de programa insegura."
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
    Write-Host 'RECODED WIN' -ForegroundColor Cyan
    Write-Host 'By EIX  //  HORIZON 02' -ForegroundColor DarkCyan
    Write-Host 'SECURE THE CORE. CONTROL THE SYSTEM' -ForegroundColor Gray
    Write-Host ''
}

function Clear-ConsoleScreen {
    Clear-Host
    if ($env:WT_SESSION) {
        try { [Console]::Write("$([char]27)[3J") } catch { }
    }
}

function Reset-MenuScreen {
    Write-Host "`nEsta pantalla se limpiará en 6 segundos y volverá al menú." -ForegroundColor DarkGray
    Start-Sleep -Seconds 6
    Clear-ConsoleScreen
    Show-ToolHeader
}

function Resolve-ProgramFolder {
    param($ProgramFolder)

    $roots = @{
        LocalAppData    = $env:LOCALAPPDATA
        RoamingAppData  = $env:APPDATA
        ProgramData     = $env:PROGRAMDATA
        ProgramFiles    = $env:ProgramFiles
        ProgramFilesX86 = ${env:ProgramFiles(x86)}
    }

    $base = [string]$roots[[string]$ProgramFolder.root]
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "Windows no tiene configurada la carpeta '$($ProgramFolder.root)'."
    }

    $relative = ([string]$ProgramFolder.path).Replace('/', '\')
    if ([System.IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.?($|\\)') {
        throw "La carpeta de programa '$($ProgramFolder.path)' no es relativa o contiene segmentos no permitidos."
    }

    $baseFull = [System.IO.Path]::GetFullPath($base).TrimEnd('\')
    $target = [System.IO.Path]::GetFullPath((Join-Path $baseFull $relative))
    if (-not $target.StartsWith($baseFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "La carpeta de programa '$($ProgramFolder.path)' sale de su ubicación autorizada."
    }
    return $target
}

function ConvertTo-ProgramFolderReference {
    param([string]$InstallLocation)

    if ([string]::IsNullOrWhiteSpace($InstallLocation)) { return '' }
    try { $fullPath = [System.IO.Path]::GetFullPath($InstallLocation.Trim().Trim('"')).TrimEnd([char]92) }
    catch { return '' }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { return '' }

    $roots = @(
        [pscustomobject]@{ Name = 'LocalAppData'; Path = $env:LOCALAPPDATA },
        [pscustomobject]@{ Name = 'RoamingAppData'; Path = $env:APPDATA },
        [pscustomobject]@{ Name = 'ProgramData'; Path = $env:PROGRAMDATA },
        [pscustomobject]@{ Name = 'ProgramFiles'; Path = $env:ProgramFiles },
        [pscustomobject]@{ Name = 'ProgramFilesX86'; Path = ${env:ProgramFiles(x86)} }
    )
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$root.Path)) { continue }
        try { $base = [System.IO.Path]::GetFullPath([string]$root.Path).TrimEnd([char]92) }
        catch { continue }
        if (-not $fullPath.StartsWith($base + [char]92, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $relative = $fullPath.Substring($base.Length).TrimStart([char]92)
        $parts = @($relative.Split([char]92))
        $invalidParts = @($parts | Where-Object { $_ -notmatch '^[A-Za-z0-9 _().+-]+$' -or $_ -in @('.', '..') })
        if ([string]::IsNullOrWhiteSpace($relative) -or $invalidParts.Count -gt 0) { return '' }
        return "$($root.Name)/$($relative.Replace([char]92, [char]47))"
    }
    return ''
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
    $localPrograms = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' } else { $null }
    $roots = @(
        [pscustomobject]@{ Name = 'LocalAppData'; Path = $env:LOCALAPPDATA; SearchPath = $localPrograms },
        [pscustomobject]@{ Name = 'ProgramFiles'; Path = $env:ProgramFiles; SearchPath = $env:ProgramFiles },
        [pscustomobject]@{ Name = 'ProgramFilesX86'; Path = ${env:ProgramFiles(x86)}; SearchPath = ${env:ProgramFiles(x86)} }
    )
    $candidateCount = 0
    Write-Host "`nCARPETAS DE INSTALACIÓN  //  CANDIDATOS PARA REVISAR" -ForegroundColor Cyan
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace([string]$root.SearchPath) -or -not (Test-Path -LiteralPath $root.SearchPath)) { continue }
        $folders = @(Get-ChildItem -LiteralPath $root.SearchPath -Directory -ErrorAction SilentlyContinue | Where-Object {
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
        Write-Host 'No encontré carpetas candidatas. Revisa la ruta de instalación en el Registro o deja este campo vacío.'
    }
    Write-Host 'Agrega solo una carpeta exacta de instalación. Al desinstalar, su contenido se borrará completo.' -ForegroundColor Yellow
}

function Show-ManifestList {
    param([array]$Apps)

    Write-Host "`nLISTA WEB DE APPS" -ForegroundColor Cyan
    if ($Apps.Count -eq 0) {
        Write-Host 'Todavía no hay apps agregadas.' -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]
        Write-Host ("  {0,2}. {1}" -f ($i + 1), $app.name) -ForegroundColor White
        $details = @()
        if ($app.wingetId) { $details += "WinGet: $($app.wingetId)" }
        if (@($app.appxNames).Count -gt 0) { $details += "Appx: $(@($app.appxNames) -join ', ')" }
        if ($app.programFolder) { $details += "Carpeta del programa: $($app.programFolder.root)/$($app.programFolder.path)" }
        if ($details.Count -gt 0) { Write-Host ("      " + ($details -join '  |  ')) -ForegroundColor DarkGray }
    }
}

function Select-ManifestApps {
    param([array]$Apps)

    if ($Apps.Count -eq 0) {
        Write-Host 'No hay apps en la lista para seleccionar.' -ForegroundColor Yellow
        return @()
    }

    Show-ManifestList -Apps $Apps
    $choice = Read-Host 'Escribe números separados por coma (ej. 1,3) o A para todas; Enter cancela'
    if ([string]::IsNullOrWhiteSpace($choice)) { return @() }
    if ($choice.Trim() -match '^(?i:a|todas)$') { return @($Apps) }

    $selected = @()
    $seen = @{}
    foreach ($part in ($choice -split '[,; ]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $index = 0
        if (-not [int]::TryParse($part, [ref]$index) -or $index -lt 1 -or $index -gt $Apps.Count) {
            Write-Host "Número inválido: $part. No se hizo ningún cambio." -ForegroundColor Red
            return @()
        }
        if (-not $seen.ContainsKey($index)) {
            $selected += $Apps[$index - 1]
            $seen[$index] = $true
        }
    }
    return @($selected)
}

function Get-InstalledAppCandidates {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    $uninstallLocations = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($location in $uninstallLocations) {
        $entries = @(Get-ItemProperty -Path $location -ErrorAction SilentlyContinue)
        foreach ($entry in $entries) {
            $appName = [string]$entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($appName) -or $entry.SystemComponent -eq 1) { continue }
            $appName = $appName.Trim()
            $signature = ("program|{0}|{1}" -f $appName, $entry.PSChildName).ToLowerInvariant()
            if ($seen.ContainsKey($signature)) { continue }
            $seen[$signature] = $true
            $items.Add([pscustomobject]@{
                Name = $appName
                Source = 'Programa instalado'
                AppxName = ''
                ProgramFolder = (ConvertTo-ProgramFolderReference -InstallLocation ([string]$entry.InstallLocation))
            })
        }
    }

    $appxCommand = Get-Command Get-AppxPackage -ErrorAction SilentlyContinue
    if ($appxCommand) {
        $startAppsCommand = Get-Command Get-StartApps -ErrorAction SilentlyContinue
        $startApps = if ($startAppsCommand) { @(Get-StartApps -ErrorAction SilentlyContinue) } else { @() }
        $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
            -not [bool]$_.IsFramework -and -not [bool]$_.IsResourcePackage
        })
        foreach ($package in $packages) {
            $appxName = [string]$package.Name
            if ([string]::IsNullOrWhiteSpace($appxName)) { continue }
            $signature = ("appx|{0}" -f $appxName).ToLowerInvariant()
            if ($seen.ContainsKey($signature)) { continue }
            $seen[$signature] = $true
            $displayName = $appxName
            $familyName = [string]$package.PackageFamilyName
            $startEntry = $startApps | Where-Object {
                -not [string]::IsNullOrWhiteSpace($familyName) -and
                ([string]$_.AppID).StartsWith($familyName + '!', [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1
            if ($startEntry -and -not [string]::IsNullOrWhiteSpace([string]$startEntry.Name)) {
                $displayName = [string]$startEntry.Name
            }
            else {
                $manifestCommand = Get-Command Get-AppxPackageManifest -ErrorAction SilentlyContinue
                if ($manifestCommand) {
                    $manifest = Get-AppxPackageManifest -Package $package -ErrorAction SilentlyContinue
                    $manifestName = [string]$manifest.Package.Properties.DisplayName
                    if (-not [string]::IsNullOrWhiteSpace($manifestName) -and
                        -not $manifestName.StartsWith('ms-resource:', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $displayName = $manifestName
                    }
                }
            }
            $items.Add([pscustomobject]@{
                Name = $displayName
                Source = 'Paquete Appx'
                AppxName = $appxName
                ProgramFolder = ''
            })
        }
    }

    return $items.ToArray()
}

function Find-ExactWingetId {
    param([string]$AppName)

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Id = ''; Output = @() }
    }

    $output = @()
    try {
        $output = @(& winget.exe search --name $AppName --source winget --count 20 --accept-source-agreements --disable-interactivity 2>$null)
    }
    catch {
        return [pscustomobject]@{ Id = ''; Output = @() }
    }

    $candidateIds = @()
    foreach ($line in $output) {
        if ($line -match '^\s*(?<candidateName>.+?)\s{2,}(?<candidateId>[A-Za-z0-9][A-Za-z0-9._+{}-]*)\s{2,}\S') {
            $candidateName = [string]$Matches.candidateName
            $candidateId = [string]$Matches.candidateId
            if ($candidateId -ieq 'Id') { continue }
            if ([string]::Equals($candidateName.Trim(), $AppName.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
                $candidateIds += $candidateId
            }
        }
    }

    $uniqueIds = @($candidateIds | Sort-Object -Unique)
    $id = if ($uniqueIds.Count -eq 1) { [string]$uniqueIds[0] } else { '' }
    return [pscustomobject]@{ Id = $id; Output = @($output) }
}

function Request-InstalledApp {
    $installedApps = @(Get-InstalledAppCandidates | Sort-Object Name, Source)
    if ($installedApps.Count -eq 0) {
        Write-Host 'No encontré apps instaladas para seleccionar.' -ForegroundColor Yellow
        return
    }

    Write-Host "`nAPPS INSTALADAS DE ESTE USUARIO" -ForegroundColor Cyan
    for ($i = 0; $i -lt $installedApps.Count; $i++) {
        Write-Host ("  {0,3}. {1}  [{2}]" -f ($i + 1), $installedApps[$i].Name, $installedApps[$i].Source) -ForegroundColor Gray
        if ($installedApps[$i].ProgramFolder) { Write-Host "        Carpeta detectada: $($installedApps[$i].ProgramFolder)" -ForegroundColor DarkGray }
    }

    $choice = Read-Host 'Escribe el número de la app para solicitar que la agreguen; Enter cancela'
    if ([string]::IsNullOrWhiteSpace($choice)) { return }
    $index = 0
    if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $installedApps.Count) {
        Write-Host 'Número inválido. No se abrió ninguna solicitud.' -ForegroundColor Red
        return
    }

    $app = $installedApps[$index - 1]
    $wingetLookup = Find-ExactWingetId -AppName $app.Name
    $wingetId = [string]$wingetLookup.Id
    Write-Host "App seleccionada: $($app.Name)" -ForegroundColor White
    if (@($wingetLookup.Output).Count -gt 0) {
        Write-Host "COINCIDENCIAS DE WINGET" -ForegroundColor Cyan
        foreach ($line in $wingetLookup.Output) { Write-Host $line }
    }
    if ($wingetId) { Write-Host "ID de WinGet detectado: $wingetId" -ForegroundColor Gray }
    elseif (-not $app.AppxName) { Write-Host 'No encontré una coincidencia exacta de WinGet; ese campo quedará vacío para que lo revises.' -ForegroundColor Yellow }
    if ($app.AppxName) { Write-Host "Nombre Appx: $($app.AppxName)" -ForegroundColor Gray }
    if ($app.ProgramFolder) { Write-Host "Carpeta detectada: $($app.ProgramFolder)" -ForegroundColor Gray }
    $missingData = @()
    if (-not $app.ProgramFolder) { $missingData += 'carpeta de instalación' }
    if (-not $wingetId -and -not $app.AppxName) { $missingData += 'ID de WinGet o nombre Appx' }
    if ($missingData.Count -gt 0) {
        Write-Host ("No se detectó: {0}." -f ($missingData -join ', ')) -ForegroundColor Yellow
        Write-Host 'Puedes completar el dato desde GitHub; si falta un identificador, el reporte no se agregará hasta completarlo.' -ForegroundColor Gray
        do {
            $continueWithMissing = (Read-Host '¿Quieres agregar la app al registro y completar esos datos después? (S/N)').Trim().ToUpperInvariant()
            if ($continueWithMissing -notin @('S','SI','SÍ','N','NO')) { Write-Host 'Responde S o N.' -ForegroundColor Yellow }
        } while ($continueWithMissing -notin @('S','SI','SÍ','N','NO'))
        if ($continueWithMissing -in @('N','NO')) {
            Write-Host 'Solicitud cancelada; no se abrió GitHub.' -ForegroundColor Yellow
            return
        }
    }
    $confirmation = Read-Host 'Escribe SOLICITAR para abrir el formulario de GitHub'
    if (-not [string]::Equals($confirmation, 'SOLICITAR', [System.StringComparison]::Ordinal)) {
        Write-Host 'Solicitud cancelada.' -ForegroundColor Yellow
        return
    }

    $settings = Get-RepositorySettings
    $titleText = "Solicitar agregar: $($app.Name)"
    $appxValue = [string]$app.AppxName
    $programFolderValue = [string]$app.ProgramFolder
    $description = @"
### Nombre de la app
$($app.Name)

### ID de WinGet
$wingetId

### Nombres de paquetes Appx
$appxValue

### Carpeta del programa
$programFolderValue
"@
    Write-Host "`nCOPIA ESTOS DATOS EN EL ISSUE DE GITHUB" -ForegroundColor Cyan
    Write-Host "Título: $titleText" -ForegroundColor White
    Write-Host "`nDescripción:" -ForegroundColor White
    Write-Host $description -ForegroundColor Gray
    $clipboardCopied = $false
    try {
        Set-Clipboard -Value $description -ErrorAction Stop
        $clipboardCopied = $true
    }
    catch { }
    if ($clipboardCopied) {
        Write-Host 'La descripción ya se copió al portapapeles. Pégala en el campo Description de GitHub.' -ForegroundColor Green
    }
    else {
        Write-Host 'Copia manualmente la descripción de arriba y pégala en GitHub.' -ForegroundColor Yellow
    }
    Write-Host 'Revisa los identificadores y la carpeta sugerida antes de enviar el issue.' -ForegroundColor Yellow
    if (-not $wingetId -and -not $appxValue) {
        Write-Host 'Falta un ID de WinGet o un nombre Appx exacto; el issue no se agregará a la lista hasta completarlo.' -ForegroundColor Yellow
    }
    $title = [uri]::EscapeDataString($titleText)
    $requestUrl = "https://github.com/$($settings.Repository)/issues/new?title=$title"
    Start-Process -FilePath $requestUrl
    Write-Host 'Se abrió GitHub. Verifica el título; pega la descripción si hace falta y pulsa Submit new issue cuando esté lista.' -ForegroundColor Cyan
    Write-Host 'Esta pantalla seguirá abierta hasta que confirmes que terminaste.' -ForegroundColor Yellow
    do {
        $ready = (Read-Host '¿Ya terminaste de pegar y revisar el reporte en GitHub? Escribe LISTO para confirmarlo').Trim()
        if (-not [string]::Equals($ready, 'LISTO', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host 'La consola se mantendrá abierta. Escribe LISTO cuando acabes en GitHub.' -ForegroundColor Yellow
        }
    } while (-not [string]::Equals($ready, 'LISTO', [System.StringComparison]::OrdinalIgnoreCase))
}

function Invoke-SelectedApps {
    param(
        [array]$Selected,
        [switch]$BatchAll
    )

    if ($Selected.Count -eq 0) { return }

    Write-Host "`nRESUMEN DE ELIMINACIÓN" -ForegroundColor Cyan
    Write-Host ("Se procesarán {0} app(s):" -f $Selected.Count) -ForegroundColor White
    foreach ($app in $Selected) {
        Write-Host "  • $($app.name)" -ForegroundColor Gray
        if ($app.wingetId) { Write-Host "      WinGet: $($app.wingetId)" -ForegroundColor DarkGray }
        foreach ($packageName in @($app.appxNames)) { Write-Host "      Appx: $packageName" -ForegroundColor DarkGray }
        if ($app.programFolder) { Write-Host "      Carpeta del programa: $($app.programFolder.root)/$($app.programFolder.path)" -ForegroundColor DarkGray }
    }

    if ($WhatIfPreference) {
        Write-Host "`nVista previa: no se desinstaló ni borró nada." -ForegroundColor Yellow
        return
    }

    $expected = if ($BatchAll) { 'BORRAR TODO' } else { 'BORRAR SELECCION' }
    Write-Host "`nSolo se borrarán las carpetas de programa específicas que aparecen arriba." -ForegroundColor Yellow
    $confirmation = Read-Host "Escribe $expected para continuar (cualquier otra respuesta cancela)"
    if (-not [string]::Equals($confirmation, $expected, [System.StringComparison]::Ordinal)) {
        Write-Host 'Operación cancelada. No se hicieron cambios.' -ForegroundColor Yellow
        return
    }

    $completed = @()
    $withWarnings = @()
    $failed = @()
    foreach ($app in $Selected) {
        try {
            $result = Invoke-AppRemoval -App $app
            $completed += [string]$app.name
            if (@($result.Warnings).Count -gt 0) { $withWarnings += [string]$app.name }
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

function Invoke-AppRemoval {
    param($App)

    Write-Host "`n$($App.name)" -ForegroundColor White
    if ($App.wingetId) { Write-Host "  WinGet: $($App.wingetId)" }
    foreach ($packageName in @($App.appxNames)) { Write-Host "  Appx: $packageName" }
    if ($App.programFolder) { Write-Host "  Carpeta del programa: $($App.programFolder.root)/$($App.programFolder.path)" }

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
                Write-Warning "WinGet devolvio el codigo $LASTEXITCODE para '$($App.name)'; continuare con Appx y la carpeta indicada."
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

    if ($null -ne $App.programFolder) {
        $target = Resolve-ProgramFolder -ProgramFolder $App.programFolder
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            Write-Host "  Se borró la carpeta del programa: $target"
        }
    }

    Write-Host "Proceso terminado para '$($App.name)'." -ForegroundColor Cyan
    return [pscustomobject]@{ Warnings = @($warnings) }
}

try {
    Clear-ConsoleScreen
    Show-ToolHeader

    if ($Info) {
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = Read-Host 'Nombre de la app que quieres buscar' }
        if ([string]::IsNullOrWhiteSpace($Name)) { return }
        Show-AppInfo -Query $Name
        return
    }

    if ($RequestInstalled) {
        Request-InstalledApp
        return
    }

    $uri = Get-ListUrl -Override $ListUrl
    Write-Host "Leyendo lista web: $uri" -ForegroundColor DarkCyan
    $apps = @(Get-Manifest -Url $uri)

    if ($ListOnly) {
        Show-ManifestList -Apps $apps
        return
    }
    if ($Name) {
        $selected = @($apps | Where-Object { $_.name -ieq $Name })
        if ($selected.Count -ne 1) { throw "No encontré exactamente una app llamada '$Name' en la lista web." }
        Invoke-SelectedApps -Selected $selected
        return
    }
    if ($All) {
        if ($apps.Count -eq 0) { Write-Host 'No hay apps en la lista web.' -ForegroundColor Yellow; return }
        Invoke-SelectedApps -Selected $apps -BatchAll
        return
    }

    while ($true) {
        Write-Host "`nMENÚ PRINCIPAL" -ForegroundColor Cyan
        Write-Host '  1. Desinstalar todas las apps de la lista'
        Write-Host '  2. Ver apps instaladas en el equipo y solicitar agregar a la lista'
        Write-Host '  0. Salir'
        $choice = Read-Host 'Elige una opción'

        switch ($choice) {
            '1' {
                if ($apps.Count -eq 0) { Write-Host 'No hay apps en la lista web.' -ForegroundColor Yellow }
                else { Invoke-SelectedApps -Selected $apps -BatchAll }
                Reset-MenuScreen
            }
            '2' {
                Request-InstalledApp
                Reset-MenuScreen
            }
            '0' { Clear-ConsoleScreen; return }
            default {
                Write-Host 'Opción inválida.' -ForegroundColor Yellow
                Reset-MenuScreen
            }
        }
    }
}
catch {
    throw $_
}

