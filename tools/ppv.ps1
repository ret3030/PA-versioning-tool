<#
.SYNOPSIS
    ppv - interaktivni CLI pro verzovani Power Platform solution exportu v gitu.

.DESCRIPTION
    Bez parametru se spusti interaktivni prostredi s menu (setup pruvodce,
    sprava vice prostredi, synchronizace, stav repozitare).

    S parametry funguje jako klasicky prikazovy radek pro automatizaci/CI:

        ppv.ps1 sync -Environment dev
        ppv.ps1 sync -Environment dev -Mode Export -Solution MojeSolution
        ppv.ps1 env list
        ppv.ps1 setup
        ppv.ps1 diff -From v1.2.0 -To HEAD

.EXAMPLE
    .\tools\ppv.ps1
    Otevre interaktivni menu.

.EXAMPLE
    .\tools\ppv.ps1 sync -Environment prod -Mode Export -Solution MojeSolution -Tag -Push
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'sync', 'env', 'status', 'diff', '')]
    [string]$Command = '',

    [Parameter(Position = 1)]
    [string]$SubCommand = '',

    [string]$Environment,
    [ValidateSet('Drop', 'Export')]
    [string]$Mode = 'Drop',
    [string[]]$Solution,
    [string]$Zip,
    [switch]$NoCommit,
    [switch]$Tag,
    [switch]$Push,
    [string]$Message,
    [string]$From,
    [string]$To,
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host "  !! $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LibRoot  = Join-Path $PSScriptRoot 'lib'
foreach ($lib in @('PPV.Config.ps1', 'PPV.UI.ps1', 'PPV.Pac.ps1', 'PPV.Common.ps1', 'PPV.Sync.ps1', 'PPV.Setup.ps1', 'PPV.Compare.ps1')) {
    . (Join-Path $LibRoot $lib)
}

# --------------------------------------------------------------- priprava ---

function Get-PpvPacOrExit {
    param([Parameter(Mandatory)]$Config)
    $pac = Resolve-PacCommand -PacPath $Config.pacPath
    if (-not $pac) {
        throw "pac CLI nenalezeno. Zkontroluj instalaci (winget install Microsoft.PowerAppsCLI) nebo nastav 'pacPath' v ppv.config.json."
    }
    return $pac
}

function Assert-PpvGitRepo {
    param([Parameter(Mandatory)][string]$RepoRoot)
    if (-not (Test-GitRepo -RepoRoot $RepoRoot)) {
        throw "'$RepoRoot' neni git repozitar. Spust: git init"
    }
}

# -------------------------------------------------------- sync - core logic -

function Get-PpvZipsForDropMode {
    param(
        [Parameter(Mandatory)][string]$DropRoot,
        [string[]]$SolutionFilter
    )
    $candidates = @(Get-ChildItem -LiteralPath $DropRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { return @() }

    if ($SolutionFilter -and $SolutionFilter.Count -gt 0) {
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($name in $SolutionFilter) {
            $match = $candidates | Where-Object { $_.BaseName -like "$name*" } | Select-Object -First 1
            if ($match) { $out.Add($match.FullName) }
        }
        return @($out)
    }
    return @($candidates | ForEach-Object { $_.FullName })
}

function Invoke-PpvSyncBatch {
    <#
        Spolecne jadro pro interaktivni i davkovy rezim. Bere uz hotovy seznam
        zipu (nebo je sama vyexportuje) a vypise vysledek kazde solution.
        Vraci pocet chyb.
    #>
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Environment,
        [Parameter(Mandatory)][string[]]$ZipPaths,
        [bool]$AutoCommit = $true,
        [bool]$CreateTag = $false,
        [bool]$DoPush = $false,
        [string]$MessageOverride
    )

    $failed = 0
    foreach ($z in @($ZipPaths)) {
        Write-Host ''
        Write-Host "  $($script:G.Dot) $(Split-Path -Leaf $z)" -ForegroundColor White

        $r = Invoke-PpvSolutionSync -RepoRoot $RepoRoot -Pac $Pac -ZipPath $z -Config $Config `
                                    -EnvironmentName $Environment.name -AutoCommit $AutoCommit `
                                    -CreateTag $CreateTag -Push $DoPush -MessageOverride $MessageOverride

        if ($r.Error) {
            Write-PpvErr $r.Error
            $failed++
            continue
        }

        Write-PpvField -Label 'Solution' -Value "$($r.Solution)  v$($r.Version)  [$($r.Type)]" -Color Cyan
        if ($r.UsedFallback) { Write-PpvWarn '--processCanvasApps neprosel, pouzit fallback per-msapp' }
        if ($r.CanvasCount -gt 0) {
            if ($r.CanvasFailed -gt 0) { Write-PpvWarn "canvas: $($r.CanvasCount - $r.CanvasFailed)/$($r.CanvasCount) rozbaleno" }
            else { Write-PpvOk "canvas appy rozbaleny: $($r.CanvasCount)" }
        }
        Write-PpvOk "normalizovano souboru: $($r.FilesNormalized)"

        if ($AutoCommit) {
            switch ($r.CommitResult) {
                'push-failed' { Write-PpvWarn 'commit OK, ale git push selhal - pushni rucne' }
                'pushed'      { Write-PpvOk 'commit vytvoren a pushnut' }
                'committed'   { Write-PpvOk 'commit vytvoren' }
                default       { Write-PpvHint 'zadne zmeny opreti poslednimu commitu' }
            }
            if ($r.Committed -and $r.TagName) { Write-PpvOk "tag: $($r.TagName)" }
        }
    }
    return $failed
}

# ------------------------------------------------------------ interaktivni --

function Invoke-PpvInteractiveSync {
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)]$Config
    )

    if (@($Config.environments).Count -eq 0) {
        Write-PpvWarn 'Zatim neni nastavene zadne prostredi.'
        Wait-PpvKey
        return $Config
    }

    $envItems = @($Config.environments | ForEach-Object {
        $hint = if ($_.name -eq $Config.activeEnvironment) { '(aktivni)' } else { '' }
        [pscustomobject]@{ Key = $_.name; Label = "$($_.name)  -  $($_.url)"; Hint = $hint }
    })
    $envName = Show-PpvMenu -Items $envItems -Title 'Pro ktere prostredi synchronizovat?'
    if (-not $envName) { return $Config }
    $environment = Get-PpvEnvironment -Config $Config -Name $envName

    if (-not (Set-PpvActiveAuthProfile -Pac $Pac -Environment $environment)) {
        Write-PpvWarn "Auth profil '$($environment.authProfile)' neexistuje."
        if (Read-PpvConfirm -Prompt 'Prihlasit se ted?' -Default $true) {
            if (-not (New-PacAuthProfile -Pac $Pac -ProfileName $environment.authProfile -Url $environment.url)) {
                Write-PpvErr 'Prihlaseni selhalo.'
                Wait-PpvKey
                return $Config
            }
        } else {
            return $Config
        }
    }

    $modeItems = @(
        [pscustomobject]@{ Key = 'drop';   Label = 'Zpracovat zipy ze slozky drop\'; Hint = 'rucni export ze studia' }
        [pscustomobject]@{ Key = 'export'; Label = 'Vyexportovat rovnou z prostredi' }
    )
    $modeChoice = Show-PpvMenu -Items $modeItems -Title 'Odkud vzit solution?'
    if (-not $modeChoice) { return $Config }

    $dropRoot = Join-Path $RepoRoot $Config.dropFolder
    $zips = @()

    if ($modeChoice -eq 'drop') {
        if (-not (Test-Path -LiteralPath $dropRoot)) { New-Item -ItemType Directory -Path $dropRoot -Force | Out-Null }
        $found = @(Get-ChildItem -LiteralPath $dropRoot -Filter '*.zip' -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Write-PpvWarn "Ve slozce '$($Config.dropFolder)\' nejsou zadne .zip soubory."
            Write-PpvHint 'Exportuj solution z make.powerapps.com a zip sem hod, pak spust znovu.'
            Wait-PpvKey
            return $Config
        }
        $zips = @($found | ForEach-Object { $_.FullName })
        Write-PpvHint "Zpracuji vsech nalezenych zipu: $($zips.Count)"
    }
    else {
        $known = @($environment.solutions)
        $extra = Read-PpvText -Prompt 'Pripadne dalsi unique name (carkou oddelene, nebo prazdne)'
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($n in $known) { $names.Add($n) }
        if ($extra) { foreach ($n in ($extra -split ',')) { if ($n.Trim()) { $names.Add($n.Trim()) } } }
        $names = @($names | Select-Object -Unique)

        if ($names.Count -eq 0) {
            Write-PpvWarn 'Zadna solution k exportu neni znama. Zadej alespon jeden unique name.'
            Wait-PpvKey
            return $Config
        }

        $selectItems = @($names | ForEach-Object { [pscustomobject]@{ Key = $_; Label = $_; Selected = $true } })
        $picked = @(Show-PpvMultiSelect -Items $selectItems -Title 'Ktere solution exportovat?')
        if ($picked.Count -eq 0) { return $Config }

        # nove zadane nazvy si ulozime pro priste
        $newlyKnown = @($picked | Where-Object { $known -notcontains $_ })
        if ($newlyKnown.Count -gt 0) {
            $environment.solutions = @($environment.solutions) + $newlyKnown
            $Config = Remove-PpvEnvironment -Config $Config -Name $environment.name
            $Config = Add-PpvEnvironment -Config $Config -Environment $environment
            Save-PpvConfig -RepoRoot $RepoRoot -Config $Config
        }

        Write-Host ''
        foreach ($name in $picked) {
            try {
                $managed = ($environment.packageType -eq 'Managed')
                Write-PpvHint "exportuji '$name'..."
                if ($environment.packageType -in @('Unmanaged', 'Both')) {
                    $zips += Export-PpvSolutionZip -Pac $Pac -Name $name -TargetFolder $dropRoot -Managed $false
                }
                if ($environment.packageType -in @('Managed', 'Both')) {
                    $zips += Export-PpvSolutionZip -Pac $Pac -Name $name -TargetFolder $dropRoot -Managed $true
                }
                Write-PpvOk "'$name' vyexportovano"
            } catch {
                Write-PpvErr $_.Exception.Message
            }
        }
    }

    if ($zips.Count -eq 0) { Wait-PpvKey; return $Config }

    $autoCommit = Read-PpvConfirm -Prompt 'Po rozbaleni rovnou commitnout?' -Default ([bool]$Config.git.autoCommit)
    $doTag  = $false
    $doPush = $false
    if ($autoCommit) {
        $doTag  = Read-PpvConfirm -Prompt 'Vytvorit i git tag?' -Default ([bool]$Config.git.tag)
        $doPush = Read-PpvConfirm -Prompt 'Po commitu pushnout?' -Default ([bool]$Config.git.push)
    }

    $failed = Invoke-PpvSyncBatch -Pac $Pac -Config $Config -Environment $environment -ZipPaths $zips `
                                  -AutoCommit $autoCommit -CreateTag $doTag -DoPush $doPush

    Write-Host ''
    if ($failed -gt 0) { Write-PpvWarn "Hotovo, ale $failed z $($zips.Count) skoncilo chybou." }
    else { Write-PpvOk "Hotovo - zpracovano $($zips.Count) polozek." }
    Wait-PpvKey
    return $Config
}

function Show-PpvStatus {
    param([Parameter(Mandatory)]$Config)

    Write-PpvTitle 'Stav repozitare'
    if (-not (Test-GitRepo -RepoRoot $RepoRoot)) {
        Write-PpvWarn 'Neni git repozitar.'
        Wait-PpvKey
        return
    }

    Push-Location $RepoRoot
    try {
        $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
        Write-PpvField -Label 'Branch' -Value $branch
        Write-PpvField -Label 'Aktivni prostredi' -Value ($(if ($Config.activeEnvironment) { $Config.activeEnvironment } else { '(zadne)' }))

        $dirty = @(& git status --porcelain 2>$null)
        Write-PpvField -Label 'Necommitnute zmeny' -Value ($(if ($dirty.Count -gt 0) { "$($dirty.Count) souboru" } else { 'zadne' })) `
                       -Color ($(if ($dirty.Count -gt 0) { 'Yellow' } else { 'Green' }))

        Write-Host ''
        Write-Host '  Posledni commity:' -ForegroundColor DarkGray
        & git log --oneline -n 8 2>$null | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    } finally { Pop-Location }

    Wait-PpvKey
}

# ---------------------------------------------------------------- settings --

function Invoke-PpvSettingsMenu {
    param([Parameter(Mandatory)]$Config)

    while ($true) {
        Write-PpvBanner 'Nastaveni'
        Write-PpvField -Label 'Struktura zdroje' -Value $Config.sourceLayout
        Write-PpvField -Label 'Canvas rezim'      -Value $Config.canvas.mode
        Write-PpvField -Label 'Auto-commit'       -Value $Config.git.autoCommit
        Write-PpvField -Label 'Auto-tag'          -Value $Config.git.tag
        Write-PpvField -Label 'Auto-push'         -Value $Config.git.push
        Write-PpvField -Label 'Pretty-print JSON' -Value $Config.normalize.prettyPrintJson
        Write-PpvField -Label 'Scrub timestamps'  -Value $Config.normalize.scrubTimestamps

        $items = @(
            [pscustomobject]@{ Key = 'commit'; Label = "Prepnout auto-commit ($($Config.git.autoCommit))" }
            [pscustomobject]@{ Key = 'tag';    Label = "Prepnout auto-tag ($($Config.git.tag))" }
            [pscustomobject]@{ Key = 'push';   Label = "Prepnout auto-push ($($Config.git.push))" }
            [pscustomobject]@{ Key = 'pretty'; Label = "Prepnout pretty-print JSON ($($Config.normalize.prettyPrintJson))" }
            [pscustomobject]@{ Key = 'scrub';  Label = "Prepnout scrub timestamps ($($Config.normalize.scrubTimestamps))" }
            [pscustomobject]@{ Key = 'canvas'; Label = 'Zmenit canvas rezim' }
            [pscustomobject]@{ Key = 'back';   Label = 'Zpet' }
        )
        $choice = Show-PpvMenu -Items $items
        if (-not $choice -or $choice -eq 'back') { return $Config }

        switch ($choice) {
            'commit' { $Config.git.autoCommit = -not [bool]$Config.git.autoCommit }
            'tag'    { $Config.git.tag        = -not [bool]$Config.git.tag }
            'push'   { $Config.git.push       = -not [bool]$Config.git.push }
            'pretty' { $Config.normalize.prettyPrintJson = -not [bool]$Config.normalize.prettyPrintJson }
            'scrub'  { $Config.normalize.scrubTimestamps = -not [bool]$Config.normalize.scrubTimestamps }
            'canvas' {
                $modeItems = @(
                    [pscustomobject]@{ Key = 'Auto';        Label = 'Auto (doporuceno)'; Hint = 'zkusi --processCanvasApps, pak fallback' }
                    [pscustomobject]@{ Key = 'ProcessFlag'; Label = 'Vzdy --processCanvasApps' }
                    [pscustomobject]@{ Key = 'PerMsapp';    Label = 'Vzdy rozbalit kazdy .msapp zvlast' }
                    [pscustomobject]@{ Key = 'None';        Label = 'Nerozbalovat canvas appy' }
                )
                $pick = Show-PpvMenu -Items $modeItems
                if ($pick) { $Config.canvas.mode = $pick }
            }
        }
        Save-PpvConfig -RepoRoot $RepoRoot -Config $Config
    }
}

# --------------------------------------------------------- hlavni smycka ----

function Invoke-PpvMainMenu {
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)]$Config
    )

    while ($true) {
        Write-PpvBanner
        $activeLabel = if ($Config.activeEnvironment) { $Config.activeEnvironment } else { '(zadne)' }
        Write-PpvField -Label 'Aktivni prostredi' -Value $activeLabel -Color Cyan
        Write-PpvField -Label 'Repozitar'          -Value $RepoRoot

        $items = @(
            [pscustomobject]@{ Key = 'sync';   Label = 'Synchronizovat solution' }
            [pscustomobject]@{ Key = 'env';    Label = 'Sprava prostredi' }
            [pscustomobject]@{ Key = 'status'; Label = 'Stav repozitare' }
            [pscustomobject]@{ Key = 'diff';   Label = 'Porovnat commity' }
            [pscustomobject]@{ Key = 'settings'; Label = 'Nastaveni' }
            [pscustomobject]@{ Key = 'exit';   Label = 'Konec' }
        )
        $choice = Show-PpvMenu -Items $items -Footer 'sipky = pohyb   Enter = vybrat   Esc/q = konec'
        if (-not $choice -or $choice -eq 'exit') { return }

        switch ($choice) {
            'sync'     { $Config = Invoke-PpvInteractiveSync -Pac $Pac -Config $Config }
            'env'      { $Config = Invoke-PpvEnvironmentMenu -RepoRoot $RepoRoot -Pac $Pac -Config $Config }
            'status'   { Show-PpvStatus -Config $Config }
            'diff'     { Invoke-PpvCompareCommits -RepoRoot $RepoRoot }
            'settings' { $Config = Invoke-PpvSettingsMenu -Config $Config }
        }
    }
}

# ------------------------------------------------------------- non-interakt -

function Invoke-PpvCliSync {
    param([Parameter(Mandatory)]$Config)

    Assert-PpvGitRepo -RepoRoot $RepoRoot
    $pac = Get-PpvPacOrExit -Config $Config

    $envName = if ($Environment) { $Environment } else { [string]$Config.activeEnvironment }
    if (-not $envName) { throw 'Zadny -Environment a v configu neni aktivni prostredi.' }
    $env = Get-PpvEnvironment -Config $Config -Name $envName
    if (-not $env) { throw "Prostredi '$envName' neni v konfiguraci. Pouzij: ppv.ps1 env list" }

    if (-not (Set-PpvActiveAuthProfile -Pac $pac -Environment $env)) {
        throw "Auth profil '$($env.authProfile)' neexistuje. Spust interaktivne: ppv.ps1 env"
    }

    $dropRoot = Join-Path $RepoRoot $Config.dropFolder
    $zips = @()

    if ($Zip) {
        if (-not (Test-Path -LiteralPath $Zip)) { throw "Zip nenalezen: $Zip" }
        $zips = @((Resolve-Path -LiteralPath $Zip).Path)
    }
    elseif ($Mode -eq 'Export') {
        $names = @(if ($Solution) { $Solution } else { $env.solutions })
        if ($names.Count -eq 0) { throw 'Zadna solution: pouzij -Solution nebo pridej solutions do prostredi.' }
        foreach ($name in $names) {
            if ($env.packageType -in @('Unmanaged', 'Both')) { $zips += Export-PpvSolutionZip -Pac $pac -Name $name -TargetFolder $dropRoot -Managed $false }
            if ($env.packageType -in @('Managed', 'Both'))   { $zips += Export-PpvSolutionZip -Pac $pac -Name $name -TargetFolder $dropRoot -Managed $true }
        }
    }
    else {
        $zips = @(Get-PpvZipsForDropMode -DropRoot $dropRoot -SolutionFilter $Solution)
        if ($zips.Count -eq 0) { throw "Ve slozce '$($Config.dropFolder)' nejsou zadne zipy." }
    }

    # -NoCommit/-Tag/-Push explicitne prepisuji config, jinak se pouzije
    # ulozene nastaveni z ppv.config.json (git.autoCommit/tag/push).
    $autoCommit = if ($NoCommit.IsPresent) { $false } else { [bool]$Config.git.autoCommit }
    $createTag  = if ($PSBoundParameters.ContainsKey('Tag'))  { $Tag.IsPresent }  else { [bool]$Config.git.tag }
    $doPush     = if ($PSBoundParameters.ContainsKey('Push')) { $Push.IsPresent } else { [bool]$Config.git.push }

    $failed = Invoke-PpvSyncBatch -Pac $pac -Config $Config -Environment $env -ZipPaths $zips `
                                  -AutoCommit $autoCommit -CreateTag $createTag -DoPush $doPush `
                                  -MessageOverride $Message

    Write-Host ''
    if ($failed -gt 0) { Write-PpvWarn "Hotovo s chybami: $failed."; exit 1 }
    Write-PpvOk 'Hotovo.'
}

function Invoke-PpvCliEnv {
    param([Parameter(Mandatory)]$Config)

    switch ($SubCommand) {
        'list' {
            Show-PpvEnvironmentList -Config $Config
        }
        default {
            $pac = Get-PpvPacOrExit -Config $Config
            Invoke-PpvEnvironmentMenu -RepoRoot $RepoRoot -Pac $pac -Config $Config | Out-Null
        }
    }
}

function Invoke-PpvCliDiff {
    Assert-PpvGitRepo -RepoRoot $RepoRoot
    if (-not $From) { throw 'Chybi -From <commit/tag/branch>.' }
    $toRef = if ($To) { $To } else { 'HEAD' }
    Show-PpvDiffOutput -RepoRoot $RepoRoot -From $From -To $toRef -Path $Path -Full
}

# ------------------------------------------------------------------- main ---

$existingConfig = Read-PpvConfig -RepoRoot $RepoRoot

if ($Command -eq '') {
    # interaktivni rezim
    $pac = Resolve-PacCommand -PacPath 'pac'
    if (-not $pac) {
        Write-PpvBanner
        Write-PpvErr 'pac CLI nenalezeno v PATH.'
        Write-PpvHint 'Nainstaluj: winget install Microsoft.PowerAppsCLI'
        Write-PpvHint "Nebo uprav 'pacPath' v ppv.config.json na plnou cestu."
        exit 1
    }

    $cfg = $existingConfig
    if (-not $cfg) { $cfg = Invoke-PpvFirstRunSetup -RepoRoot $RepoRoot -Pac $pac }

    Invoke-PpvMainMenu -Pac $pac -Config $cfg
    Write-Host ''
    exit 0
}

# ---- davkovy / CI rezim ----
if (-not $existingConfig) {
    throw "ppv.config.json neexistuje. Spust bez parametru pro pruvodce nastavenim: ppv.ps1"
}

switch ($Command) {
    'setup'  {
        $pac = Get-PpvPacOrExit -Config $existingConfig
        Invoke-PpvFirstRunSetup -RepoRoot $RepoRoot -Pac $pac | Out-Null
    }
    'sync'   { Invoke-PpvCliSync -Config $existingConfig }
    'env'    { Invoke-PpvCliEnv -Config $existingConfig }
    'diff'   { Invoke-PpvCliDiff }
    'status' { Show-PpvStatus -Config $existingConfig }
}
