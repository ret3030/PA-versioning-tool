# PPV.Compare.ps1 - porovnani dvou commitu (diff) ve stejnem repu
Set-StrictMode -Version Latest

function Get-PpvRecentCommits {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$Count = 25
    )
    Push-Location $RepoRoot
    try {
        $lines = @(& git log -n $Count --date=short --pretty=format:'%H|%h|%ad|%s' 2>$null)
        return @($lines | Where-Object { $_ } | ForEach-Object {
            $parts = $_ -split '\|', 4
            [pscustomobject]@{
                Hash      = $parts[0]
                ShortHash = $parts[1]
                Date      = $parts[2]
                Subject   = $parts[3]
            }
        })
    } finally { Pop-Location }
}

function Show-PpvDiffOutput {
    <#
        Vypise diff mezi dvema referencemi (commit hash, tag, branch, HEAD~n...).
        Napred souhrn zmenenych souboru, pak nabidne i plny diff - do konzole,
        nebo ulozeny jako .patch soubor.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [string]$Path,
        [switch]$Full
    )

    Push-Location $RepoRoot
    try {
        $pathArgs = @()
        if ($Path) { $pathArgs = @('--', $Path) }

        & git rev-parse --verify --quiet ($From + '^{commit}') 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "'$From' neni platny commit/tag/branch v tomhle repu." }
        & git rev-parse --verify --quiet ($To + '^{commit}') 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "'$To' neni platny commit/tag/branch v tomhle repu." }

        Write-PpvTitle "Souhrn zmen: $From -> $To"
        # 2>&1 u externiho prikazu mixuje do pole ErrorRecord objekty (ne
        # ciste retezce) - .ToString() vsechno srovna na string, jinak pozdejsi
        # .NET volani (WriteAllLines) padaji na "Cannot convert System.Object[]".
        $stat = @(& git --no-pager diff --stat $From $To @pathArgs 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) { throw "git diff selhal: $($stat -join "`n")" }

        if ($stat.Count -eq 0) {
            Write-PpvHint 'Zadne rozdily.'
            return
        }
        $stat | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

        # V CI/davkovem rezimu (-Full, nebo kdyz terminal neumi cist klavesy)
        # se nikdy nesmi cekat na Read-Host - proto se ptame jen interaktivne.
        $showFull = $Full.IsPresent
        if (-not $showFull -and (Test-PpvInteractive)) {
            $showFull = Read-PpvConfirm -Prompt 'Zobrazit plny diff?' -Default $false
        }
        if (-not $showFull) { return }

        $fullDiff = @(& git --no-pager diff $From $To @pathArgs 2>&1 | ForEach-Object { $_.ToString() })

        $saveToFile = $false
        if (Test-PpvInteractive) {
            $saveToFile = Read-PpvConfirm -Prompt 'Ulozit diff do .patch souboru misto vypisu do konzole?' -Default $false
        }

        if ($saveToFile) {
            $shortFrom = $From.Substring(0, [Math]::Min(8, $From.Length))
            $shortTo   = $To.Substring(0, [Math]::Min(8, $To.Length))
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "ppv-diff-$shortFrom-$shortTo.patch"
            [System.IO.File]::WriteAllLines($tmp, $fullDiff)
            Write-PpvOk "Ulozeno: $tmp"
            if ((Test-PpvInteractive) -and (Read-PpvConfirm -Prompt 'Otevrit v defaultnim programu?' -Default $true)) {
                Start-Process $tmp
            }
        } else {
            Write-Host ''
            $fullDiff | ForEach-Object { Write-Host $_ }
        }
    } finally { Pop-Location }
}

function Invoke-PpvCompareCommits {
    <#
        Interaktivni vyber dvou commitu z historie stejneho repa a zobrazeni
        diffu mezi nimi.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not (Test-GitRepo -RepoRoot $RepoRoot)) {
        Write-PpvWarn 'Neni git repozitar.'
        Wait-PpvKey
        return
    }

    $commits = @(Get-PpvRecentCommits -RepoRoot $RepoRoot -Count 25)
    if ($commits.Count -lt 2) {
        Write-PpvWarn 'V historii je min nez 2 commity - neni co porovnavat.'
        Wait-PpvKey
        return
    }

    $items = @($commits | ForEach-Object {
        [pscustomobject]@{ Key = $_.Hash; Label = "$($_.ShortHash)  $($_.Date)  $($_.Subject)" }
    })

    $fromKey = Show-PpvMenu -Items $items -Title 'Starsi commit (From)'
    if (-not $fromKey) { return }

    $headItem = [pscustomobject]@{ Key = 'HEAD'; Label = 'HEAD (aktualni stav)' }
    $toItems  = @($headItem) + @($items | Where-Object { $_.Key -ne $fromKey })
    $toKey    = Show-PpvMenu -Items $toItems -Title 'Novejsi commit (To)'
    if (-not $toKey) { return }

    try {
        Show-PpvDiffOutput -RepoRoot $RepoRoot -From $fromKey -To $toKey
    } catch {
        Write-PpvErr $_.Exception.Message
    }
    Wait-PpvKey
}
