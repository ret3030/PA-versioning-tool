# PPV.Pac.ps1 - obalka nad pac CLI: hledani binarky, auth profily per prostredi
Set-StrictMode -Version Latest

function Resolve-PacCommand {
    param([string]$PacPath = 'pac')

    $cmd = Get-Command $PacPath -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $probes = @(
        @{ Root = $env:USERPROFILE;   Tail = '.dotnet\tools\pac.exe' },
        @{ Root = ${env:ProgramFiles}; Tail = 'Microsoft Power Platform CLI\pac.exe' },
        @{ Root = ${env:LOCALAPPDATA}; Tail = 'Microsoft\PowerAppsCLI\pac.exe' }
    )
    foreach ($p in $probes) {
        if ([string]::IsNullOrWhiteSpace($p.Root)) { continue }
        $candidate = Join-Path $p.Root $p.Tail
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return $null
}

function Test-PpvPacAvailable {
    param([string]$PacPath = 'pac')
    return ($null -ne (Resolve-PacCommand -PacPath $PacPath))
}

function Invoke-Pac {
    <#
        Spusti pac s danymi argumenty. Vraci hashtable @{ ExitCode; Output }.
        Nehazi vyjimku - o reakci na exit code rozhoduje volajici.
    #>
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Quiet
    )

    if (-not $Quiet) { Write-PpvHint ("pac " + ($Arguments -join ' ')) }

    $output = & $Pac @Arguments 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if (-not $Quiet) { Write-Host ("      " + $line) -ForegroundColor DarkGray }
        $line
    }

    return @{
        ExitCode = $LASTEXITCODE
        Output   = ($output -join [Environment]::NewLine)
    }
}

# ------------------------------------------------------------- auth profily -

function Get-PacAuthProfiles {
    <#
        Vraci pole objektu z 'pac auth list' @{ Index; IsActive; Name; Kind; Url }.
        Format vystupu pac se obcas meni mezi verzemi, takze parsujeme benevolentne.
    #>
    param([Parameter(Mandatory)][string]$Pac)

    $r = Invoke-Pac -Pac $Pac -Arguments @('auth', 'list') -Quiet
    if ($r.ExitCode -ne 0) { return @() }

    $profiles = @()
    foreach ($line in ($r.Output -split "`n")) {
        # ocekavany radek: "[1]  * ppv-dev   DATAVERSE   https://foo.crm4.dynamics.com"
        # a nebo bez hvezdicky u neaktivniho profilu
        if ($line -notmatch '^\s*\[\d+\]') { continue }
        $isActive = $line -match '\*'
        $clean = $line -replace '^\s*\[\d+\]\s*', '' -replace '^\*\s*', ''
        $parts = @($clean -split '\s{2,}' | Where-Object { $_ -and $_.Trim() })
        if ($parts.Count -eq 0) { continue }

        $profiles += [pscustomobject]@{
            IsActive = $isActive
            Name     = $parts[0].Trim()
            Kind     = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
            Url      = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
        }
    }
    return $profiles
}

function Test-PacAuthProfile {
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string]$ProfileName
    )
    $profiles = Get-PacAuthProfiles -Pac $Pac
    return [bool]($profiles | Where-Object { $_.Name -eq $ProfileName })
}

function New-PacAuthProfile {
    <#
        Vytvori pojmenovany auth profil pro dane prostredi (otevre prohlizec).
        Vraci $true/$false podle uspechu.
    #>
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)][string]$Url
    )
    $r = Invoke-Pac -Pac $Pac -Arguments @('auth', 'create', '--name', $ProfileName, '--environment', $Url)
    return ($r.ExitCode -eq 0)
}

function Select-PacAuthProfile {
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string]$ProfileName
    )
    $r = Invoke-Pac -Pac $Pac -Arguments @('auth', 'select', '--name', $ProfileName) -Quiet
    return ($r.ExitCode -eq 0)
}

function Remove-PacAuthProfile {
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string]$ProfileName
    )
    $r = Invoke-Pac -Pac $Pac -Arguments @('auth', 'delete', '--name', $ProfileName) -Quiet
    return ($r.ExitCode -eq 0)
}

function Set-PpvActiveAuthProfile {
    <#
        Zajisti, ze pred operaci nad danym prostredim je vybrany spravny
        auth profil. Pokud neexistuje, vrati $false (volajici nabidne vytvoreni).
    #>
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)]$Environment
    )
    if (-not (Test-PacAuthProfile -Pac $Pac -ProfileName $Environment.authProfile)) {
        return $false
    }
    return (Select-PacAuthProfile -Pac $Pac -ProfileName $Environment.authProfile)
}
