# PPV.Common.ps1 - jadro: cteni zipu, normalizace, git commit
# Config viz PPV.Config.ps1, vypisy viz PPV.UI.ps1, pac viz PPV.Pac.ps1
Set-StrictMode -Version Latest

# ------------------------------------------------------------ solution zip ---

function Get-SolutionInfoFromZip {
    <#
        Precte solution.xml primo ze zipu (bez rozbaleni) a vrati
        UniqueName, Version a priznak Managed.
    #>
    param([Parameter(Mandatory)][string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $archive = $null
    $reader  = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $entry = $archive.Entries | Where-Object { $_.FullName -ieq 'solution.xml' } | Select-Object -First 1
        if (-not $entry) {
            throw "V archivu chybi solution.xml - '$ZipPath' nevypada jako export solution."
        }

        $reader = New-Object System.IO.StreamReader($entry.Open())
        $xml = [xml]$reader.ReadToEnd()

        $manifest = $xml.ImportExportXml.SolutionManifest
        $managedRaw = Get-PpvProperty -Object $manifest -Name 'Managed' -Default '0'

        return [pscustomobject]@{
            UniqueName = [string]$manifest.UniqueName
            Version    = [string]$manifest.Version
            Managed    = ([string]$managedRaw -eq '1')
            ZipPath    = $ZipPath
        }
    }
    finally {
        if ($reader)  { $reader.Dispose() }
        if ($archive) { $archive.Dispose() }
    }
}

function Clear-TargetFolder {
    <#
        Vyprazdni cilovou slozku pred unpackem, aby se smazane komponenty
        projevily jako smazani v gitu. Zamerne NEpouzivame pac --allowDelete,
        ktery ve spojeni s --processCanvasApps maze rozbaleny canvas zdroj.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Get-ChildItem -LiteralPath $Path -Force |
            Where-Object { $_.Name -ne '.git' } |
            Remove-Item -Recurse -Force -ErrorAction Stop
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# ------------------------------------------------------------ normalizace ----

function Format-JsonText {
    <#
        Preformatuje JSON na odsazenou podobu. Preferuje System.Text.Json
        (PowerShell 7), jinak spadne zpet na ConvertFrom/ConvertTo-Json.
        Vraci $null, pokud vstup neni platny JSON.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    $stj = $null
    try { $stj = [Type]::GetType('System.Text.Json.JsonDocument, System.Text.Json') } catch { $stj = $null }

    if ($stj) {
        $doc = $null
        try {
            $doc = [System.Text.Json.JsonDocument]::Parse($Text)
            $opts = [System.Text.Json.JsonSerializerOptions]::new()
            $opts.WriteIndented = $true
            $opts.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
            return [System.Text.Json.JsonSerializer]::Serialize($doc.RootElement, $opts)
        } catch {
            return $null
        } finally {
            if ($doc) { $doc.Dispose() }
        }
    }

    try {
        return ($Text | ConvertFrom-Json | ConvertTo-Json -Depth 100)
    } catch {
        return $null
    }
}

function Invoke-SourceNormalization {
    <#
        Projde rozbalenou slozku a snizi sum v diffech:
          - preformatuje JSON (flows, canvas manifesty) na citelnou podobu
          - smaze regenerovatelne soubory (Entropy.json, AppCheckerResult.sarif)
          - odstrani volatilni casova razitka z Header.json
        Vraci pocet dotcenych souboru.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$NormalizeConfig
    )

    $prettyPrint   = [bool](Get-PpvProperty -Object $NormalizeConfig -Name 'prettyPrintJson'  -Default $true)
    $scrub         = [bool](Get-PpvProperty -Object $NormalizeConfig -Name 'scrubTimestamps'  -Default $true)
    $removeNoise   = [bool](Get-PpvProperty -Object $NormalizeConfig -Name 'removeNoiseFiles' -Default $true)
    $noiseFiles    = @(Get-PpvProperty -Object $NormalizeConfig -Name 'noiseFiles' -Default @('Entropy.json', 'AppCheckerResult.sarif'))
    $volatileKeys  = @('LastSavedDateTimeUTC', 'LastModifiedDateTime', 'CreatedByClientVersion')

    $touched = 0

    if ($removeNoise -and $noiseFiles.Count -gt 0) {
        $noise = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                 Where-Object { $noiseFiles -contains $_.Name }
        foreach ($f in $noise) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            $touched++
        }
    }

    if (-not $prettyPrint -and -not $scrub) { return $touched }

    $jsonFiles = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -Filter '*.json' -ErrorAction SilentlyContinue
    foreach ($f in $jsonFiles) {
        $raw = $null
        try { $raw = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 } catch { continue }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        $working = $raw

        if ($scrub -and $f.Name -ieq 'Header.json') {
            foreach ($key in $volatileKeys) {
                $working = [regex]::Replace(
                    $working,
                    ',?\s*"' + [regex]::Escape($key) + '"\s*:\s*("(?:[^"\\]|\\.)*"|[^,}\]]+)',
                    ''
                )
            }
        }

        $formatted = if ($prettyPrint) { Format-JsonText -Text $working } else { $working }
        if ($null -eq $formatted) { continue }

        $normalized = $formatted -replace "`r`n", "`n"
        $current    = $raw -replace "`r`n", "`n"
        if ($normalized -ne $current) {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($f.FullName, $normalized, $utf8)
            $touched++
        }
    }

    return $touched
}

# -------------------------------------------------------------------- git ----

function Test-GitRepo {
    param([Parameter(Mandatory)][string]$RepoRoot)
    Push-Location $RepoRoot
    try {
        & git rev-parse --is-inside-work-tree 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}

function Test-PpvIsGithubUrl {
    <#
        github.com je defaultne zamceny jako cil remote - je to verejna,
        firmou nespravovana sluzba a exporty solution mohou obsahovat
        citliva data (connection references, env promenne). Pokryje
        https i ssh tvar URL (git@github.com:...).
    #>
    param([Parameter(Mandatory)][string]$Url)
    return [bool]($Url -match '(?i)(^|[/@.])github\.com([:/]|$)')
}

function Get-PpvGitRemotes {
    <#
        Vraci pole @{ Name; Url } - bez remote (defaultni, ciste lokalni
        rezim) vraci prazdne pole.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)
    Push-Location $RepoRoot
    try {
        $lines = @(& git remote -v 2>$null)
        $seen = @{}
        $result = New-Object System.Collections.Generic.List[pscustomobject]
        foreach ($line in $lines) {
            if ($line -match '^(\S+)\s+(\S+)\s+\(fetch\)$') {
                $name = $matches[1]; $url = $matches[2]
                if (-not $seen.ContainsKey($name)) {
                    $seen[$name] = $true
                    $result.Add([pscustomobject]@{ Name = $name; Url = $url })
                }
            }
        }
        return @($result)
    } finally { Pop-Location }
}

function Add-PpvGitRemote {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url
    )
    Push-Location $RepoRoot
    try {
        & git remote add $Name $Url 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}

function Set-PpvGitRemoteUrl {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Url
    )
    Push-Location $RepoRoot
    try {
        & git remote set-url $Name $Url 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}

function Remove-PpvGitRemote {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Name
    )
    Push-Location $RepoRoot
    try {
        & git remote remove $Name 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally { Pop-Location }
}

function Invoke-GitCommit {
    <#
        Zaradi zmeny v dane slozce a commitne.
        Vraci vzdy retezec (NE bool - $true -eq 'jakykoliv-text' je v PowerShellu
        pravda kvuli koerzi typu, takze mix bool/string je zdrojem tichych chyb):
          'no-changes'          zadne zmeny, commit se nekonal
          'committed'           commit vytvoren (bez pozadavku na push)
          'pushed'              commit vytvoren a uspesne pushnut
          'push-failed'         commit vytvoren, ale push selhal
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$RelativePath,
        [Parameter(Mandatory)][string]$Message,
        [string]$TagName,
        [switch]$Push
    )

    Push-Location $RepoRoot
    try {
        & git add -A -- @RelativePath
        if ($LASTEXITCODE -ne 0) { throw "git add selhalo pro '$($RelativePath -join ', ')'." }

        & git diff --cached --quiet -- @RelativePath
        if ($LASTEXITCODE -eq 0) {
            & git reset --quiet -- @RelativePath 2>&1 | Out-Null
            return 'no-changes'
        }

        & git commit --only -m $Message -- @RelativePath | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git commit selhal.' }

        if ($TagName) {
            & git tag -a $TagName -m $Message 2>&1 | Out-Null
        }

        if (-not $Push) { return 'committed' }

        & git push 2>&1 | Out-Null
        $pushOk = ($LASTEXITCODE -eq 0)
        if ($TagName) { & git push origin $TagName 2>&1 | Out-Null }
        if ($pushOk) { return 'pushed' }
        return 'push-failed'
    } finally { Pop-Location }
}
