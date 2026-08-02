# PPV.UI.ps1 - terminalove UI: menu se sipkami, prompty, multiselect
Set-StrictMode -Version Latest

# ------------------------------------------------------------- vzhled -------

$script:PpvAscii = ($env:PPV_ASCII -eq '1')
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    $script:PpvAscii = $true
}

if ($script:PpvAscii) {
    $script:G = @{ H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'
                   Arrow = '>'; Dot = '*'; Check = '+'; Cross = 'x'
                   Box = '[ ]'; BoxOn = '[x]' }
} else {
    $script:G = @{ H = '─'; V = '│'; TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'
                   Arrow = '❯'; Dot = '•'; Check = '✓'; Cross = '✗'
                   Box = '☐'; BoxOn = '☑' }
}

function Get-PpvWidth {
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 20) { return [Math]::Min($w - 1, 100) }
    } catch { }
    return 78
}

function Test-PpvInteractive {
    <# Da se cist klavesnice? V pipe/CI ne. #>
    try {
        if ([Console]::IsInputRedirected) { return $false }
        $null = [Console]::CursorTop
        return $true
    } catch { return $false }
}

# ------------------------------------------------------------- vypisy -------

function Write-PpvBanner {
    param([string]$Subtitle = '')
    $w = Get-PpvWidth
    $inner = $w - 4   # sirka mezi svislymi carami (bez "  " odsazeni)

    $title = "ppv"
    $desc  = "  Power Platform solution versioning"
    $contentLen = $title.Length + $desc.Length
    $pad = [Math]::Max(1, $inner - $contentLen - 2)

    Write-Host ''
    Write-Host ("  " + $script:G.TL + ($script:G.H * $inner) + $script:G.TR) -ForegroundColor DarkCyan
    Write-Host ("  " + $script:G.V + "  ") -NoNewline -ForegroundColor DarkCyan
    Write-Host $title -NoNewline -ForegroundColor Cyan
    Write-Host $desc -NoNewline -ForegroundColor Gray
    Write-Host ((' ' * $pad) + $script:G.V) -ForegroundColor DarkCyan
    Write-Host ("  " + $script:G.BL + ($script:G.H * $inner) + $script:G.BR) -ForegroundColor DarkCyan
    if ($Subtitle) { Write-Host "  $Subtitle" -ForegroundColor DarkGray }
    Write-Host ''
}

function Write-PpvTitle {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ("  " + ($script:G.H * [Math]::Min(60, (Get-PpvWidth) - 4))) -ForegroundColor DarkGray
}

function Write-PpvField {
    param([Parameter(Mandatory)][string]$Label, [string]$Value, [string]$Color = 'White')
    Write-Host ("  {0,-22}" -f $Label) -NoNewline -ForegroundColor DarkGray
    Write-Host $Value -ForegroundColor $Color
}

function Write-PpvOk    { param([string]$Message) Write-Host "  $($script:G.Check) $Message" -ForegroundColor Green }
function Write-PpvWarn  { param([string]$Message) Write-Host "  ! $Message" -ForegroundColor Yellow }
function Write-PpvErr   { param([string]$Message) Write-Host "  $($script:G.Cross) $Message" -ForegroundColor Red }
function Write-PpvHint  { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-PpvBullet{ param([string]$Message) Write-Host "  $($script:G.Dot) $Message" -ForegroundColor Gray }

# -------------------------------------------------------------- menu --------

function Show-PpvMenu {
    <#
        Menu ovladane sipkami. Items = pole objektu s Key, Label a volitelne Hint.
        Vraci Key vybrane polozky, nebo $null pri Esc.
    #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title,
        [string]$Footer = 'sipky = pohyb   Enter = vybrat   Esc = zpet'
    )

    $items = @($Items | Where-Object { $_ })
    if ($items.Count -eq 0) { return $null }

    if ($Title) { Write-PpvTitle $Title }

    # neinteraktivni fallback: cislovany seznam
    if (-not (Test-PpvInteractive)) {
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $items[$i].Label)
        }
        $answer = Read-Host '  Cislo volby'
        $idx = 0
        if ([int]::TryParse($answer, [ref]$idx) -and $idx -ge 1 -and $idx -le $items.Count) {
            return $items[$idx - 1].Key
        }
        return $null
    }

    $selected = 0
    $width    = Get-PpvWidth
    $lines    = $items.Count + 2
    $top      = $null

    try { [Console]::CursorVisible = $false } catch { }
    try {
        while ($true) {
            if ($null -ne $top) { [Console]::SetCursorPosition(0, $top) }

            Write-Host ''
            for ($i = 0; $i -lt $items.Count; $i++) {
                $it = $items[$i]
                $hint = ''
                if ($it.PSObject.Properties.Name -contains 'Hint' -and $it.Hint) { $hint = "  $($it.Hint)" }

                if ($i -eq $selected) {
                    $text = "  $($script:G.Arrow) $($it.Label)"
                    Write-Host $text.PadRight($width) -NoNewline -ForegroundColor Cyan
                    Write-Host ''
                } else {
                    Write-Host "    $($it.Label)" -NoNewline -ForegroundColor Gray
                    Write-Host $hint.PadRight([Math]::Max(0, $width - $it.Label.Length - 4)) -ForegroundColor DarkGray
                }
            }
            Write-Host ("  " + $Footer).PadRight($width) -ForegroundColor DarkGray

            $top = [Console]::CursorTop - $lines

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $selected = ($selected - 1 + $items.Count) % $items.Count }
                'DownArrow' { $selected = ($selected + 1) % $items.Count }
                'Home'      { $selected = 0 }
                'End'       { $selected = $items.Count - 1 }
                'Enter'     { return $items[$selected].Key }
                'Escape'    { return $null }
                default {
                    $ch = $key.KeyChar
                    if ($ch -match '^[1-9]$') {
                        $n = [int]::Parse($ch)
                        if ($n -le $items.Count) { return $items[$n - 1].Key }
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

function Show-PpvMultiSelect {
    <#
        Vicenasobny vyber. Items = objekty s Key, Label, volitelne Selected.
        Vraci pole Key. Prazdne pole = nic nevybrano / Esc.
    #>
    param(
        [Parameter(Mandatory)][array]$Items,
        [string]$Title,
        [string]$Footer = 'sipky = pohyb   mezernik = prepnout   a = vse   Enter = potvrdit   Esc = zrusit'
    )

    $items = @($Items | Where-Object { $_ })
    if ($items.Count -eq 0) { return @() }

    if ($Title) { Write-PpvTitle $Title }

    $state = @{}
    foreach ($it in $items) {
        $pre = $false
        if ($it.PSObject.Properties.Name -contains 'Selected') { $pre = [bool]$it.Selected }
        $state[$it.Key] = $pre
    }

    if (-not (Test-PpvInteractive)) {
        for ($i = 0; $i -lt $items.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $items[$i].Label)
        }
        $answer = Read-Host '  Cisla oddelena carkou (nebo prazdne = zadne)'
        $result = @()
        foreach ($part in ($answer -split ',')) {
            $idx = 0
            if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $items.Count) {
                $result += $items[$idx - 1].Key
            }
        }
        return $result
    }

    $selected = 0
    $width    = Get-PpvWidth
    $lines    = $items.Count + 2
    $top      = $null

    try { [Console]::CursorVisible = $false } catch { }
    try {
        while ($true) {
            if ($null -ne $top) { [Console]::SetCursorPosition(0, $top) }

            Write-Host ''
            for ($i = 0; $i -lt $items.Count; $i++) {
                $it  = $items[$i]
                $box = if ($state[$it.Key]) { $script:G.BoxOn } else { $script:G.Box }
                $marker = if ($i -eq $selected) { $script:G.Arrow } else { ' ' }
                $line = "  $marker $box $($it.Label)"
                $color = if ($i -eq $selected) { 'Cyan' } elseif ($state[$it.Key]) { 'White' } else { 'Gray' }
                Write-Host $line.PadRight($width) -ForegroundColor $color
            }
            Write-Host ("  " + $Footer).PadRight($width) -ForegroundColor DarkGray

            $top = [Console]::CursorTop - $lines

            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $selected = ($selected - 1 + $items.Count) % $items.Count }
                'DownArrow' { $selected = ($selected + 1) % $items.Count }
                'Spacebar'  { $state[$items[$selected].Key] = -not $state[$items[$selected].Key] }
                'Enter'     { return @($items | Where-Object { $state[$_.Key] } | ForEach-Object { $_.Key }) }
                'Escape'    { return @() }
                default {
                    if ($key.KeyChar -eq 'a' -or $key.KeyChar -eq 'A') {
                        $allOn = -not (@($items | Where-Object { -not $state[$_.Key] }).Count -gt 0)
                        foreach ($it in $items) { $state[$it.Key] = -not $allOn }
                    }
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $true } catch { }
    }
}

# ------------------------------------------------------------ prompty -------

function Read-PpvText {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default,
        [switch]$Required,
        [scriptblock]$Validator,
        [string]$ValidationMessage = 'Neplatna hodnota.'
    )

    while ($true) {
        $suffix = if ($Default) { " [$Default]" } else { '' }
        Write-Host "  $Prompt$suffix" -NoNewline -ForegroundColor White
        Write-Host ': ' -NoNewline -ForegroundColor DarkGray
        $value = Read-Host

        if ([string]::IsNullOrWhiteSpace($value) -and $Default) { $value = $Default }
        $value = $value.Trim()

        if ([string]::IsNullOrWhiteSpace($value)) {
            if ($Required) { Write-PpvErr 'Hodnota je povinna.'; continue }
            return ''
        }
        if ($Validator -and -not (& $Validator $value)) {
            Write-PpvErr $ValidationMessage; continue
        }
        return $value
    }
}

function Read-PpvConfirm {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )
    $hint = if ($Default) { 'A/n' } else { 'a/N' }
    while ($true) {
        Write-Host "  $Prompt " -NoNewline -ForegroundColor White
        Write-Host "[$hint]: " -NoNewline -ForegroundColor DarkGray
        $answer = (Read-Host).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ($answer -in @('a', 'ano', 'y', 'yes')) { return $true }
        if ($answer -in @('n', 'ne', 'no'))        { return $false }
    }
}

function Wait-PpvKey {
    param([string]$Message = 'Pokracuj libovolnou klavesou...')
    Write-Host ''
    Write-Host "  $Message" -ForegroundColor DarkGray
    if (Test-PpvInteractive) { $null = [Console]::ReadKey($true) }
}
