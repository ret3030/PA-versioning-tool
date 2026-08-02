# PPV.Setup.ps1 - setup pruvodce a sprava prostredi
Set-StrictMode -Version Latest

function Invoke-PpvEnvironmentForm {
    <#
        Interaktivni formular pro jedno prostredi. Pokud je predano $Existing,
        jde o editaci (predvyplni hodnoty, jmeno se neda menit).
        Vraci hotovy objekt prostredi, nebo $null pri Esc/zruseni.
    #>
    param(
        [Parameter(Mandatory)][string]$Pac,
        $Existing = $null,
        [string[]]$TakenNames = @()
    )

    $isEdit = [bool]$Existing

    if ($isEdit) {
        $name = $Existing.name
        Write-PpvTitle "Uprava prostredi '$name'"
    } else {
        Write-PpvTitle 'Nove prostredi'
        Write-PpvHint 'Kratke jmeno pouzijeme i jako nazev slozky v src\ a jako auth profil v pac.'
        $name = Read-PpvText -Prompt 'Nazev (napr. dev, test, prod)' -Required `
                              -Validator {
                                  param($v)
                                  (Test-PpvEnvironmentName -Name $v) -and ($TakenNames -notcontains $v)
                              } `
                              -ValidationMessage 'Pouze pismena/cislice/./-/_ a jmeno jeste nesmi existovat.'
    }

    $defaultUrl = if ($isEdit) { $Existing.url } else { '' }
    $url = Read-PpvText -Prompt 'URL prostredi (https://...crm.dynamics.com)' -Default $defaultUrl -Required `
                        -Validator { param($v) Test-PpvUrl -Url $v } `
                        -ValidationMessage 'Musi zacinat https:// a obsahovat domenu.'

    $defaultPkg = if ($isEdit) { $Existing.packageType } else { 'Unmanaged' }
    $pkgItems = @(
        [pscustomobject]@{ Key = 'Unmanaged'; Label = 'Unmanaged (bezny vyvoj)' }
        [pscustomobject]@{ Key = 'Managed';   Label = 'Managed (release/prod)' }
        [pscustomobject]@{ Key = 'Both';      Label = 'Obojí' }
    )
    $preselect = @($pkgItems | Where-Object { $_.Key -eq $defaultPkg })
    if ($preselect) { $pkgItems = @($pkgItems | ForEach-Object { $_ }) }
    $pkgChoice = Show-PpvMenu -Items $pkgItems -Title 'Typ balicku pro export'
    if (-not $pkgChoice) { return $null }

    $authProfile = if ($isEdit) { $Existing.authProfile } else { "ppv-$name" }

    $env = New-PpvEnvironment -Name $name -Url $url -AuthProfile $authProfile -PackageType $pkgChoice `
                              -Solutions (@(if ($isEdit) { $Existing.solutions } else { @() }))

    # auth profil hned nastavime, at uzivatel neresi pac zvlast
    Write-Host ''
    if (Test-PacAuthProfile -Pac $Pac -ProfileName $authProfile) {
        Write-PpvOk "Auth profil '$authProfile' uz existuje."
    }
    elseif (Read-PpvConfirm -Prompt "Prihlasit se k '$url' ted? (otevre prohlizec)" -Default $true) {
        Write-PpvHint 'Cekam na prihlaseni v prohlizeci...'
        if (New-PacAuthProfile -Pac $Pac -ProfileName $authProfile -Url $url) {
            Write-PpvOk 'Prihlaseni uspesne.'
        } else {
            Write-PpvWarn 'Prihlaseni se nepodarilo. Muzes to zkusit pozdeji z menu Prostredi.'
        }
    } else {
        Write-PpvHint "Muzes pozdeji spustit: pac auth create --name $authProfile --environment $url"
    }

    return $env
}

function Invoke-PpvFirstRunSetup {
    <#
        Spusti se, kdyz ppv.config.json jeste neexistuje. Vytvori config,
        pripadne rovnou prvni prostredi.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Pac
    )

    Write-PpvBanner
    Write-Host '  Vitej! Vypada to, ze tu ppv bezi poprve.' -ForegroundColor White
    Write-Host '  Projdeme rychle zakladni nastaveni.' -ForegroundColor Gray
    Write-Host ''

    if (-not (Test-GitRepo -RepoRoot $RepoRoot)) {
        if (Read-PpvConfirm -Prompt 'Tahle slozka jeste neni git repozitar. Zalozit (git init)?' -Default $true) {
            Push-Location $RepoRoot
            try { & git init | Out-Null } finally { Pop-Location }
            Write-PpvOk 'git init hotovo.'
        } else {
            Write-PpvWarn 'Bez gitu nepujde commitovat - jen rozbalovani a normalizace budou fungovat.'
        }
    }

    $cfg = New-PpvConfig

    Write-PpvTitle 'Struktura zdroje'
    $layoutItems = @(
        [pscustomobject]@{ Key = 'byEnvironment'; Label = 'src/<prostredi>/<Solution>'; Hint = 'doporuceno - jde srovnavat prostredi' }
        [pscustomobject]@{ Key = 'bySolution';     Label = 'src/<Solution>'; Hint = 'jednodussi, jen kdyz mas 1 prostredi' }
    )
    $layoutChoice = Show-PpvMenu -Items $layoutItems
    if ($layoutChoice) { $cfg.sourceLayout = $layoutChoice }

    if (Read-PpvConfirm -Prompt 'Pridat prvni prostredi ted?' -Default $true) {
        $newEnv = Invoke-PpvEnvironmentForm -Pac $Pac
        if ($newEnv) {
            $cfg = Add-PpvEnvironment -Config $cfg -Environment $newEnv
        }
    }

    Save-PpvConfig -RepoRoot $RepoRoot -Config $cfg
    Write-Host ''
    Write-PpvOk 'ppv.config.json vytvoren.'
    Wait-PpvKey
    return $cfg
}

# --------------------------------------------------------- sprava prostredi -

function Show-PpvEnvironmentList {
    param([Parameter(Mandatory)]$Config)

    Write-PpvTitle 'Prostredi'
    if (@($Config.environments).Count -eq 0) {
        Write-PpvHint 'zadne prostredi zatim neni nastavene'
        return
    }
    foreach ($e in $Config.environments) {
        $mark = if ($e.name -eq $Config.activeEnvironment) { $script:G.Arrow } else { ' ' }
        $color = if ($e.name -eq $Config.activeEnvironment) { 'Cyan' } else { 'Gray' }
        Write-Host ("  $mark {0,-14} {1,-45} {2}" -f $e.name, $e.url, $e.packageType) -ForegroundColor $color
    }
}

function Invoke-PpvEnvironmentMenu {
    <#
        Hlavni obrazovka spravy prostredi. Modifikuje a uklada Config primo.
        Vraci (pripadne aktualizovany) Config.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Pac,
        [Parameter(Mandatory)]$Config
    )

    while ($true) {
        Write-PpvBanner 'Sprava prostredi'
        Show-PpvEnvironmentList -Config $Config

        $items = @(
            [pscustomobject]@{ Key = 'add';    Label = 'Pridat prostredi' }
        )
        if (@($Config.environments).Count -gt 0) {
            $items += [pscustomobject]@{ Key = 'switch'; Label = 'Prepnout aktivni prostredi' }
            $items += [pscustomobject]@{ Key = 'edit';   Label = 'Upravit prostredi' }
            $items += [pscustomobject]@{ Key = 'auth';   Label = 'Overit / obnovit prihlaseni' }
            $items += [pscustomobject]@{ Key = 'remove'; Label = 'Odebrat prostredi' }
        }
        $items += [pscustomobject]@{ Key = 'back'; Label = 'Zpet' }

        $choice = Show-PpvMenu -Items $items
        if (-not $choice -or $choice -eq 'back') { return $Config }

        switch ($choice) {
            'add' {
                $taken = @($Config.environments | ForEach-Object { $_.name })
                $newEnv = Invoke-PpvEnvironmentForm -Pac $Pac -TakenNames $taken
                if ($newEnv) {
                    $Config = Add-PpvEnvironment -Config $Config -Environment $newEnv
                    Save-PpvConfig -RepoRoot $RepoRoot -Config $Config
                    Write-PpvOk "Prostredi '$($newEnv.name)' pridano."
                    Wait-PpvKey
                }
            }
            'switch' {
                $items2 = @($Config.environments | ForEach-Object {
                    [pscustomobject]@{ Key = $_.name; Label = "$($_.name)  ($($_.url))" }
                })
                $pick = Show-PpvMenu -Items $items2 -Title 'Ktere prostredi aktivovat?'
                if ($pick) {
                    $Config.activeEnvironment = $pick
                    Save-PpvConfig -RepoRoot $RepoRoot -Config $Config
                    Write-PpvOk "Aktivni prostredi: $pick"
                    Wait-PpvKey
                }
            }
            'edit' {
                $items2 = @($Config.environments | ForEach-Object {
                    [pscustomobject]@{ Key = $_.name; Label = $_.name }
                })
                $pick = Show-PpvMenu -Items $items2 -Title 'Upravit ktere prostredi?'
                if ($pick) {
                    $existing = Get-PpvEnvironment -Config $Config -Name $pick
                    $updated = Invoke-PpvEnvironmentForm -Pac $Pac -Existing $existing
                    if ($updated) {
                        $Config = Remove-PpvEnvironment -Config $Config -Name $pick
                        $Config = Add-PpvEnvironment -Config $Config -Environment $updated
                        if ($Config.environments.Count -eq 1) { $Config.activeEnvironment = $updated.name }
                        Save-PpvConfig -RepoRoot $RepoRoot -Config $Config
                        Write-PpvOk 'Ulozeno.'
                        Wait-PpvKey
                    }
                }
            }
            'auth' {
                $items2 = @($Config.environments | ForEach-Object {
                    [pscustomobject]@{ Key = $_.name; Label = $_.name }
                })
                $pick = Show-PpvMenu -Items $items2 -Title 'Overit prihlaseni pro ktere prostredi?'
                if ($pick) {
                    $e = Get-PpvEnvironment -Config $Config -Name $pick
                    if (Test-PacAuthProfile -Pac $Pac -ProfileName $e.authProfile) {
                        Write-PpvOk "Profil '$($e.authProfile)' existuje, vybiram ho jako aktivni v pac."
                        Select-PacAuthProfile -Pac $Pac -ProfileName $e.authProfile | Out-Null
                    }
                    elseif (Read-PpvConfirm -Prompt 'Profil neexistuje. Prihlasit se ted?' -Default $true) {
                        if (New-PacAuthProfile -Pac $Pac -ProfileName $e.authProfile -Url $e.url) {
                            Write-PpvOk 'Prihlaseni uspesne.'
                        } else {
                            Write-PpvErr 'Prihlaseni selhalo.'
                        }
                    }
                    Wait-PpvKey
                }
            }
            'remove' {
                $items2 = @($Config.environments | ForEach-Object {
                    [pscustomobject]@{ Key = $_.name; Label = $_.name }
                })
                $pick = Show-PpvMenu -Items $items2 -Title 'Odebrat ktere prostredi?'
                if ($pick -and (Read-PpvConfirm -Prompt "Opravdu odebrat '$pick'? (zdrojove soubory v src\ zustanou)" -Default $false)) {
                    $Config = Remove-PpvEnvironment -Config $Config -Name $pick
                    Save-PpvConfig -RepoRoot $RepoRoot -Config $Config
                    Write-PpvOk 'Odebrano z konfigurace.'
                    Wait-PpvKey
                }
            }
        }
    }
}
