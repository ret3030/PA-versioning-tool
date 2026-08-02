# PPV.Sync.ps1 - orchestrace: export -> unpack -> canvas -> normalizace -> commit
Set-StrictMode -Version Latest

function Export-PpvSolutionZip {
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TargetFolder,
        [bool]$Managed = $false
    )

    $suffix = if ($Managed) { 'managed' } else { 'unmanaged' }
    $file   = Join-Path $TargetFolder ("{0}_{1}.zip" -f $Name, $suffix)
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }

    $exportArgs = @('solution', 'export', '--path', $file, '--name', $Name, '--async')
    if ($Managed) { $exportArgs += @('--managed') }

    $r = Invoke-Pac -Pac $Pac -Arguments $exportArgs
    if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $file)) {
        throw "Export solution '$Name' selhal (exit $($r.ExitCode))."
    }
    return $file
}

function Expand-PpvCanvasApps {
    <#
        Fallback pro pripad, ze --processCanvasApps neprojde (je deprecated):
        rozbali kazdy .msapp zvlast pres 'pac canvas unpack'.
    #>
    param(
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string]$SolutionFolder
    )

    $canvasDir = Join-Path $SolutionFolder 'CanvasApps'
    if (-not (Test-Path -LiteralPath $canvasDir)) { return @{ Count = 0; Failed = 0 } }

    $msapps = @(Get-ChildItem -LiteralPath $canvasDir -Filter '*.msapp' -File -ErrorAction SilentlyContinue)
    if ($msapps.Count -eq 0) { return @{ Count = 0; Failed = 0 } }

    $failed = 0
    foreach ($app in $msapps) {
        $appName = [System.IO.Path]::GetFileNameWithoutExtension($app.Name) -replace '_DocumentUri$', ''
        $target  = Join-Path (Join-Path $canvasDir 'src') $appName

        $r = Invoke-Pac -Pac $Pac -Arguments @('canvas', 'unpack', '--msapp', $app.FullName, '--sources', $target)
        if ($r.ExitCode -ne 0) { $failed++ }
    }
    return @{ Count = $msapps.Count; Failed = $failed }
}

function Invoke-PpvSolutionSync {
    <#
        Kompletni pipeline pro jeden zip: precte info, vycisti cil, rozbali,
        canvas fallback, normalizuje, commitne. Vraci pscustomobject se
        stavem kazde faze - volajici (interaktivni i davkovy) si z toho
        poskladá vlastni vypis.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$EnvironmentName,
        [bool]$AutoCommit = $true,
        [bool]$CreateTag = $false,
        [bool]$Push = $false,
        [string]$MessageOverride
    )

    $result = [pscustomobject]@{
        Solution        = $null
        Version         = $null
        Type            = $null
        SolutionFolder  = $null
        UnpackedOk      = $false
        UsedFallback    = $false
        CanvasCount     = 0
        CanvasFailed    = 0
        FilesNormalized = 0
        Committed       = $false
        CommitResult    = 'no-changes'
        TagName         = $null
        Error           = $null
    }

    try {
        $info = Get-SolutionInfoFromZip -ZipPath $ZipPath
        $type = if ($info.Managed) { 'Managed' } else { 'Unmanaged' }
        $result.Solution = $info.UniqueName
        $result.Version  = $info.Version
        $result.Type     = $type

        $relativePath   = Get-PpvSourcePath -Config $Config -EnvironmentName $EnvironmentName -SolutionName $info.UniqueName
        $solutionFolder = Join-Path $RepoRoot $relativePath
        $result.SolutionFolder = $solutionFolder

        Clear-TargetFolder -Path $solutionFolder

        $unpackArgs = @(
            'solution', 'unpack',
            '--zipfile',     $ZipPath,
            '--folder',      $solutionFolder,
            '--packagetype', $type
        )

        $canvasMode = [string](Get-PpvProperty -Object $Config.canvas -Name 'mode' -Default 'Auto')
        $useProcessFlag = ($canvasMode -eq 'Auto' -or $canvasMode -eq 'ProcessFlag')

        if ($useProcessFlag) {
            $r = Invoke-Pac -Pac $Pac -Arguments ($unpackArgs + '--processCanvasApps')
            if ($r.ExitCode -ne 0) {
                $result.UsedFallback = $true
                Clear-TargetFolder -Path $solutionFolder
                $r = Invoke-Pac -Pac $Pac -Arguments $unpackArgs
                if ($r.ExitCode -eq 0 -and $canvasMode -ne 'None') {
                    $c = Expand-PpvCanvasApps -Pac $Pac -SolutionFolder $solutionFolder
                    $result.CanvasCount  = $c.Count
                    $result.CanvasFailed = $c.Failed
                }
            }
        } else {
            $r = Invoke-Pac -Pac $Pac -Arguments $unpackArgs
            if ($r.ExitCode -eq 0 -and $canvasMode -eq 'PerMsapp') {
                $c = Expand-PpvCanvasApps -Pac $Pac -SolutionFolder $solutionFolder
                $result.CanvasCount  = $c.Count
                $result.CanvasFailed = $c.Failed
            }
        }

        if ($r.ExitCode -ne 0) { throw "pac solution unpack selhal (exit $($r.ExitCode))." }
        $result.UnpackedOk = $true

        $result.FilesNormalized = Invoke-SourceNormalization -Path $solutionFolder -NormalizeConfig $Config.normalize

        if ($AutoCommit) {
            $gitCfg   = $Config.git
            $template = [string](Get-PpvProperty -Object $gitCfg -Name 'messageTemplate' -Default '[{env}] {solution} {version} ({type})')
            $msg = $template.
                Replace('{env}',      $EnvironmentName).
                Replace('{solution}', $info.UniqueName).
                Replace('{version}',  $info.Version).
                Replace('{type}',     $type).
                Replace('{date}',     (Get-Date -Format 'yyyy-MM-dd HH:mm'))
            if ($MessageOverride) { $msg = $MessageOverride }

            $tagName = if ($CreateTag) { "$EnvironmentName/$($info.UniqueName)/v$($info.Version)" } else { $null }
            $result.TagName = $tagName

            # ppv.config.json se meni bokem (napr. nove objevene unique names
            # ulozene pri interaktivnim exportu) - vezme se do stejneho commitu,
            # aby nezustaval trvale necommitnuty mimo dohled sync flow.
            $commitPaths = @($relativePath)
            $configPath = Get-PpvConfigPath -RepoRoot $RepoRoot
            if (Test-Path -LiteralPath $configPath) { $commitPaths += 'ppv.config.json' }

            $commitResult = Invoke-GitCommit -RepoRoot $RepoRoot -RelativePath $commitPaths `
                                             -Message $msg -TagName $tagName -Push:$Push
            $result.CommitResult = $commitResult
            $result.Committed    = ($commitResult -in @('committed', 'pushed', 'push-failed'))
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}
