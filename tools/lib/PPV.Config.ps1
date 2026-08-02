# PPV.Config.ps1 - schema v2: vice prostredi, migrace z v1
Set-StrictMode -Version Latest

$script:PpvConfigVersion = 2

function Get-PpvProperty {
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $v = $Object.$Name
        if ($null -eq $v) { return $Default }
        return $v
    }
    return $Default
}

function Get-PpvConfigPath {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Join-Path $RepoRoot 'ppv.config.json')
}

function New-PpvConfig {
    return [pscustomobject]@{
        version            = $script:PpvConfigVersion
        pacPath            = 'pac'
        sourceFolder       = 'src'
        dropFolder         = 'drop'
        sourceLayout       = 'byEnvironment'   # byEnvironment | bySolution
        activeEnvironment  = ''
        environments       = @()
        normalize          = [pscustomobject]@{
            prettyPrintJson  = $true
            scrubTimestamps  = $true
            removeNoiseFiles = $true
            noiseFiles       = @('Entropy.json', 'AppCheckerResult.sarif')
        }
        canvas             = [pscustomobject]@{ mode = 'Auto' }
        git                = [pscustomobject]@{
            autoCommit      = $true
            tag             = $false
            push            = $false
            messageTemplate = '[{env}] {solution} {version} ({type})'
        }
    }
}

function New-PpvEnvironment {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url,
        [string]$AuthProfile,
        [string]$PackageType = 'Unmanaged',
        [string[]]$Solutions = @()
    )
    if (-not $AuthProfile) { $AuthProfile = "ppv-$Name" }
    return [pscustomobject]@{
        name        = $Name
        url         = $Url
        authProfile = $AuthProfile
        packageType = $PackageType
        solutions   = @($Solutions)
    }
}

function Read-PpvConfig {
    <# Nacte config; pokud neexistuje, vrati $null (spusti se setup). #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $path = Get-PpvConfigPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    try { $cfg = $raw | ConvertFrom-Json }
    catch { throw "ppv.config.json neni platny JSON: $($_.Exception.Message)" }

    return (Convert-PpvConfig -Config $cfg)
}

function Convert-PpvConfig {
    <#
        Doplni chybejici klice a povysi schema v1 (jedno prostredi v koreni)
        na v2 (pole environments).
    #>
    param([Parameter(Mandatory)]$Config)

    $defaults = New-PpvConfig
    $version  = [int](Get-PpvProperty -Object $Config -Name 'version' -Default 1)

    foreach ($prop in $defaults.PSObject.Properties) {
        if (-not ($Config.PSObject.Properties.Name -contains $prop.Name)) {
            $Config | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
    }

    if ($version -lt 2) {
        # --- migrace v1 -> v2 -------------------------------------------
        $oldUrl = [string](Get-PpvProperty -Object $Config -Name 'environment' -Default '')
        $oldSol = @(Get-PpvProperty -Object $Config -Name 'solutions' -Default @() |
                    ForEach-Object { if ($_ -is [string]) { $_ } else { Get-PpvProperty -Object $_ -Name 'name' } } |
                    Where-Object { $_ })

        if ($oldUrl -or $oldSol.Count -gt 0) {
            $migrated = New-PpvEnvironment -Name 'dev' -Url $oldUrl `
                                           -PackageType ([string](Get-PpvProperty -Object $Config -Name 'packageType' -Default 'Unmanaged')) `
                                           -Solutions $oldSol
            $Config.environments      = @($migrated)
            $Config.activeEnvironment = 'dev'
            # v1 verzovalo primo do src/<Solution>
            $Config.sourceLayout      = 'bySolution'
        }

        foreach ($dead in @('environment', 'packageType', 'solutions')) {
            if ($Config.PSObject.Properties.Name -contains $dead) {
                $Config.PSObject.Properties.Remove($dead)
            }
        }
        $Config.version = $script:PpvConfigVersion
    }

    # environments vzdy jako pole
    $Config.environments = @(Get-PpvProperty -Object $Config -Name 'environments' -Default @())
    foreach ($e in $Config.environments) {
        if (-not ($e.PSObject.Properties.Name -contains 'solutions') -or $null -eq $e.solutions) {
            $e | Add-Member -NotePropertyName solutions -NotePropertyValue @() -Force
        }
        $e.solutions = @($e.solutions)
        foreach ($k in @{ authProfile = "ppv-$($e.name)"; packageType = 'Unmanaged' }.GetEnumerator()) {
            if (-not ($e.PSObject.Properties.Name -contains $k.Key) -or -not $e.($k.Key)) {
                $e | Add-Member -NotePropertyName $k.Key -NotePropertyValue $k.Value -Force
            }
        }
    }

    return $Config
}

function Save-PpvConfig {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$Config
    )
    $path = Get-PpvConfigPath -RepoRoot $RepoRoot
    $json = $Config | ConvertTo-Json -Depth 10
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $utf8)
}

# ------------------------------------------------------------ prostredi -----

function Get-PpvEnvironment {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$Name
    )
    if (-not $Name) { $Name = [string]$Config.activeEnvironment }
    if (-not $Name) { return $null }
    return ($Config.environments | Where-Object { $_.name -eq $Name } | Select-Object -First 1)
}

function Add-PpvEnvironment {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Environment
    )
    if ($Config.environments | Where-Object { $_.name -eq $Environment.name }) {
        throw "Prostredi '$($Environment.name)' uz existuje."
    }
    $Config.environments = @($Config.environments) + @($Environment)
    if (-not $Config.activeEnvironment) { $Config.activeEnvironment = $Environment.name }
    return $Config
}

function Remove-PpvEnvironment {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name
    )
    $Config.environments = @($Config.environments | Where-Object { $_.name -ne $Name })
    if ($Config.activeEnvironment -eq $Name) {
        $Config.activeEnvironment = if ($Config.environments.Count -gt 0) { $Config.environments[0].name } else { '' }
    }
    return $Config
}

function Get-PpvSourcePath {
    <#
        Kam se rozbaluje zdroj. byEnvironment = src\<env>\<Solution>
        (umoznuje porovnavat prostredi mezi sebou), bySolution = src\<Solution>.
        Vraci relativni cestu s lomitky podle platformy.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [Parameter(Mandatory)][string]$SolutionName
    )
    $layout = [string](Get-PpvProperty -Object $Config -Name 'sourceLayout' -Default 'byEnvironment')
    if ($layout -eq 'bySolution') {
        return (Join-Path $Config.sourceFolder $SolutionName)
    }
    return (Join-Path (Join-Path $Config.sourceFolder $EnvironmentName) $SolutionName)
}

function Test-PpvEnvironmentName {
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -match '^[a-zA-Z0-9._-]{1,40}$')
}

function Test-PpvUrl {
    param([Parameter(Mandatory)][string]$Url)
    return ($Url -match '^https://[^\s/]+\.[^\s/]+')
}
