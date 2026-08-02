<#
.SYNOPSIS
    Nainstaluje/aktualizuje nastroj ppv do samostatne cilove slozky (repo se
    solutions), oddelene od tohoto repozitare se zdrojovym kodem nastroje.

.DESCRIPTION
    Zkopiruje tools\, ppv.cmd, .gitignore a .gitattributes do -Target.
    Pokud -Target jeste neni git repozitar, nabidne 'git init' (bez remote -
    zustane ciste lokalni, nic se nikam nepushuje). ppv.config.json, src\ a
    drop\ v cilove slozce se nikdy neprepisuji, takze skript je bezpecne
    spustit opakovane i pro pouhou aktualizaci nastroje.

.EXAMPLE
    .\install.ps1 -Target C:\Users\jan\PowerApps-Solutions
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Target
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceRoot = $PSScriptRoot

if (-not (Test-Path -LiteralPath $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
}
$Target = (Resolve-Path -LiteralPath $Target).Path

if ($Target -eq $SourceRoot) {
    throw "Cil '-Target' nesmi byt tahle slozka (kod nastroje). Zadej jinou, oddelenou slozku pro solution repo."
}

Write-Host "Instaluji ppv do '$Target'..." -ForegroundColor Cyan

$toolsTarget = Join-Path $Target 'tools'
robocopy (Join-Path $SourceRoot 'tools') $toolsTarget /MIR /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy tools\ selhalo (exit $LASTEXITCODE)." }

foreach ($f in @('ppv.cmd', '.gitignore', '.gitattributes')) {
    Copy-Item -LiteralPath (Join-Path $SourceRoot $f) -Destination (Join-Path $Target $f) -Force
}

Write-Host "  tools\, ppv.cmd, .gitignore, .gitattributes zkopirovany." -ForegroundColor Green

Push-Location $Target
try {
    $isRepo = $true
    if (-not (Test-Path -LiteralPath '.git')) {
        $answer = (Read-Host "  '$Target' jeste neni git repozitar. Zalozit (git init)? [A/n]").Trim().ToLowerInvariant()
        if ($answer -notin @('n', 'ne', 'no')) {
            & git init | Out-Null
            Write-Host '  git init hotovo (bez remote - zustava lokalne).' -ForegroundColor Green
        } else {
            $isRepo = $false
        }
    }

    # Commitne jen skeleton nastroje (tools\, ppv.cmd, .gitignore, .gitattributes) -
    # bez tohohle by tyhle soubory zustavaly trvale necommitnute, protoze ppv
    # pri synchronizaci solution commituje vyhradne src\<prostredi>\<Solution>.
    if ($isRepo) {
        $skeletonPaths = @('tools', 'ppv.cmd', '.gitignore', '.gitattributes')
        & git add -- @skeletonPaths
        & git diff --cached --quiet -- @skeletonPaths
        if ($LASTEXITCODE -ne 0) {
            & git commit -m 'ppv: instalace/aktualizace nastroje' -- @skeletonPaths | Out-Null
            Write-Host '  Skeleton nastroje (tools\, ppv.cmd, .gitignore, .gitattributes) commitnut.' -ForegroundColor Green
        }
    }
} finally { Pop-Location }

Write-Host ''
Write-Host "Hotovo. Spust:" -ForegroundColor Cyan
Write-Host "  cd `"$Target`""
Write-Host "  .\ppv.cmd"
