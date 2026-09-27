# tests/test-install.ps1 - sandboxed tests for install.ps1 and uninstall.ps1
# https://github.com/Makihataima-Ken/lazygit-vscode-themes
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-install.ps1
#
# Exit code 0 = every check passed (skips allowed), 1 = at least one failure.
#
# Safety: every install/uninstall call works in a sandbox config directory (-ConfigDir, or
# CONFIG_DIR / XDG_CONFIG_HOME / XDG_CONFIG_DIRS pointing into the sandbox). Nothing is written
# to the real User/Machine environment: the whole run sets LGVDM_TEST_ENV_KEY, which makes
# install.ps1 keep its "User" and "Machine" LG_CONFIG_FILE values under a throwaway key
# HKCU:\Software\lgvdm-test\<id> (deleted at the end). The persisted-mode checks (14) run only
# after check (14a) has shown that install.ps1 honors it. LG_CONFIG_FILE, CONFIG_DIR, PATH and
# the XDG_* variables of this process are saved and restored. The last check verifies that the
# real User-scope LG_CONFIG_FILE and the real config directory are unchanged.
#
# Optional environment variables:
#   LGVDM_TEST_TMPDIR     parent directory for the sandbox (default: the system temp directory)
#   LGVDM_LAZYGIT         lazygit executable for the config validation checks (default: lazygit
#                         from PATH, with Chocolatey/Scoop shims resolved to the real exe)
#   LGVDM_KEEP_SANDBOX=1  keep the sandbox directory afterwards

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$TestScript  = $PSCommandPath
$Installer   = Join-Path $RepoRoot 'install.ps1'
$Uninstaller = Join-Path $RepoRoot 'uninstall.ps1'
$ShInstaller = Join-Path $RepoRoot 'install.sh'
$CatalogSource = Join-Path (Join-Path $RepoRoot 'themes') 'catalog.txt'
$ThemeSource = Join-Path (Join-Path $RepoRoot 'themes') 'vscode-dark-modern.yml'
$BeginMarker = '# >>> lazygit-vscode-dark-modern >>>'
$EndMarker   = '# <<< lazygit-vscode-dark-modern <<<'
$ValidPhrase = 'must be run inside a git repository'
# All fixtures are ASCII; ISO-8859-1 maps each byte to one char, so string equality below is
# byte equality.
$Latin1      = [System.Text.Encoding]::GetEncoding(28591)

$script:PassCount  = 0
$script:FailCount  = 0
$script:SkipCount  = 0
$script:LastOutput = ''
$script:Completed  = $false

# ------------------------------------------------------------------ harness

function Invoke-Check([string]$Name, [scriptblock]$Body) {
    try {
        $null = & $Body
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:PassCount++
    } catch {
        $message = [string]$_.Exception.Message
        if ($message.StartsWith('SKIP:', [System.StringComparison]::Ordinal)) {
            Write-Host "SKIP  $Name -- $($message.Substring(5).Trim())" -ForegroundColor Yellow
            $script:SkipCount++
        } else {
            Write-Host "FAIL  $Name" -ForegroundColor Red
            foreach ($line in ($message -split "`n")) { Write-Host "        $line" }
            $where = @(([string]$_.ScriptStackTrace) -split "`n" | Where-Object { $_ -notmatch '^at (Assert-|Skip-Check)' }) | Select-Object -First 1
            if ($where) { Write-Host "        ($($where.Trim()))" }
            $script:FailCount++
        }
    }
}

function Skip-Check([string]$Reason) { throw "SKIP: $Reason" }

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function ConvertTo-Visible([string]$Text) {
    return $Text.Replace("`r", '\r').Replace("`n", '\n')
}

function Assert-Equal($Expected, $Actual, [string]$What) {
    $e = [string]$Expected
    $a = [string]$Actual
    if ([string]::Equals($e, $a, [System.StringComparison]::Ordinal)) { return }
    $n = [Math]::Min($e.Length, $a.Length)
    $i = 0
    while ($i -lt $n -and $e[$i] -ceq $a[$i]) { $i++ }
    $from = [Math]::Max(0, $i - 30)
    $eShow = ConvertTo-Visible $e.Substring($from, [Math]::Min(90, $e.Length - $from))
    $aShow = ConvertTo-Visible $a.Substring($from, [Math]::Min(90, $a.Length - $from))
    throw ("{0}: first difference at offset {1} (lengths {2} vs {3})`n  expected: ...{4}`n  actual:   ...{5}" -f $What, $i, $e.Length, $a.Length, $eShow, $aShow)
}

function Read-Bytes([string]$Path) { return $Latin1.GetString([System.IO.File]::ReadAllBytes($Path)) }

function Write-Bytes([string]$Path, [string]$Text) { [System.IO.File]::WriteAllBytes($Path, $Latin1.GetBytes($Text)) }

function Assert-FileText([string]$Path, [string]$Expected, [string]$What) {
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "$What (file missing: $Path)"
    Assert-Equal $Expected (Read-Bytes $Path) $What
}

function Assert-Missing([string]$Path, [string]$What) {
    Assert-True (-not (Test-Path -LiteralPath $Path)) "$What (still exists: $Path)"
}

function Get-Count([string]$Text, [string]$Needle) {
    return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
}

function Set-TestLg([string]$Value) {
    if ($Value) { $env:LG_CONFIG_FILE = $Value } else { Remove-Item -LiteralPath 'Env:LG_CONFIG_FILE' -ErrorAction SilentlyContinue }
}

function Get-TestLg { return [Environment]::GetEnvironmentVariable('LG_CONFIG_FILE', 'Process') }

# The fake User/Machine LG_CONFIG_FILE store (see LGVDM_TEST_ENV_KEY in install.ps1).
function Set-Stored([string]$Scope, [string]$Value) {
    $key = "$script:EnvKey\$Scope"
    try {
        if ($Value) {
            if (-not (Test-Path -LiteralPath $key)) { [void](New-Item -Path $key -Force) }
            [void](New-ItemProperty -LiteralPath $key -Name 'LG_CONFIG_FILE' -Value $Value -PropertyType String -Force)
        } else {
            try { Remove-ItemProperty -LiteralPath $key -Name 'LG_CONFIG_FILE' -ErrorAction Stop } catch { }
        }
    } catch [System.UnauthorizedAccessException] {
        Skip-Check 'the current sandbox does not allow the HKCU test registry store'
    }
}

function Get-Stored([string]$Scope) {
    $item = $null
    try { $item = Get-ItemProperty -LiteralPath "$script:EnvKey\$Scope" -Name 'LG_CONFIG_FILE' -ErrorAction Stop } catch { $item = $null }
    if ($null -eq $item) { return $null }
    return [string]$item.LG_CONFIG_FILE
}

function Reset-Env([string]$Process, [string]$User, [string]$Machine) {
    Set-TestLg $Process
    Set-Stored 'User' $User
    Set-Stored 'Machine' $Machine
}

# The "To undo: ..." command from the last installer output.
function Get-UndoLine {
    $m = [regex]::Match($script:LastOutput, 'To undo: (.*)')
    Assert-True $m.Success "no 'To undo:' line in the output:`n$script:LastOutput"
    return $m.Groups[1].Value.Trim()
}

# First line of `lazygit --print-config-dir`, decoded as UTF-8 (what lazygit writes).
function Get-PrintedConfigDir([string]$Exe) {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $saved = $null
    try { $saved = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $saved = $null }
    $lines = @()
    try {
        $lines = @(& $Exe --print-config-dir 2>$null)
    } finally {
        if ($null -ne $saved) { try { [Console]::OutputEncoding = $saved } catch { } }
    }
    return "$($lines | Select-Object -First 1)".Trim()
}

# A sandbox config dir with the paths the installer derives from it.
function New-Box([string]$Name, [switch]$NoCreate) {
    $dir = Join-Path $script:Sandbox $Name
    if (-not $NoCreate) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $themes = Join-Path $dir 'themes'
    return New-Object PSObject -Property @{
        Dir    = $dir
        Config = Join-Path $dir 'config.yml'
        Bak    = (Join-Path $dir 'config.yml') + '.bak'
        Themes = $themes
        Theme  = Join-Path $themes 'vscode-dark-modern.yml'
    }
}

function New-File([string]$Path, [string]$Text) {
    Write-Bytes $Path $Text
    return $Path
}

# Runs a script with named parameters, capturing all output streams as text.
function Invoke-Script([string]$Path, [hashtable]$Params) {
    $out = & $Path @Params *>&1 | ForEach-Object { [string]$_ }
    $script:LastOutput = (@($out) -join "`n")
}

# install.ps1 -ConfigDir <box> -NoPersist [extra parameters]
function Install-Box($Box, [hashtable]$Extra) {
    $params = @{ ConfigDir = $Box.Dir; NoPersist = $true }
    if ($Extra) { foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] } }
    Invoke-Script $Installer $params
}

# install.ps1 -ConfigDir <box> [extra parameters], WITHOUT -NoPersist: the persisted code path,
# with the User/Machine values in the fake store. Only after check (15a) proved the store works.
function Install-Persisted($Box, [hashtable]$Extra) {
    if (-not $script:SeamOk) { Skip-Check 'check (15a) did not confirm the test environment store' }
    Assert-Equal $script:EnvKey $env:LGVDM_TEST_ENV_KEY 'LGVDM_TEST_ENV_KEY'
    $params = @{ ConfigDir = $Box.Dir }
    if ($Extra) { foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] } }
    Invoke-Script $Installer $params
    Assert-True ($script:LastOutput.Contains("Test mode: the User/Machine LG_CONFIG_FILE values are kept under $script:EnvKey")) "install.ps1 did not report the test store; output:`n$script:LastOutput"
}

function Find-RealLazygit {
    if ($env:LGVDM_LAZYGIT) {
        if (Test-Path -LiteralPath $env:LGVDM_LAZYGIT -PathType Leaf) { return $env:LGVDM_LAZYGIT }
        return $null
    }
    $cmd = Get-Command -Name 'lazygit' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $cmd) { return $null }
    $path = $cmd.Path
    # Shims start the real exe as a child; killing a shim on timeout would orphan lazygit.
    $candidates = @()
    if ($path -match '\\chocolatey\\bin\\lazygit\.exe$') {
        $candidates += Join-Path (Split-Path -Parent (Split-Path -Parent $path)) 'lib\lazygit\tools\lazygit.exe'
    }
    if ($path -match '\\scoop\\shims\\lazygit\.exe$') {
        $candidates += Join-Path (Split-Path -Parent (Split-Path -Parent $path)) 'apps\lazygit\current\lazygit.exe'
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
    return $path
}

function Test-InsideGitRepo([string]$Dir) {
    $git = Get-Command -Name 'git' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $git) { return $false }
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $answer = & $git.Path -C $Dir rev-parse --is-inside-work-tree 2>$null
    # "$x" rather than [string]$x: an empty native result is AutomationNull, which casts to $null.
    return ("$answer".Trim() -eq 'true')
}

# Starts lazygit outside any repository with <files>,<guard.yml> (guard: notARepository: quit).
# A valid config makes lazygit print "must be run inside a git repository" and exit.
function Invoke-LazygitValidation([string]$Label, [string[]]$Files) {
    $vdir = Join-Path $script:Sandbox ('validate-' + $Label)
    $cfgDir = Join-Path $vdir 'config-dir'
    $cwd = Join-Path $vdir 'cwd'
    [void][System.IO.Directory]::CreateDirectory($cfgDir)
    [void][System.IO.Directory]::CreateDirectory($cwd)
    if (Test-InsideGitRepo $cwd) { Skip-Check "$cwd is inside a git work tree; lazygit would not quit" }
    $guard = New-File (Join-Path $vdir 'guard.yml') "notARepository: quit`n"
    $stdin = New-File (Join-Path $vdir 'stdin.txt') ''
    $outFile = Join-Path $vdir 'stdout.txt'
    $errFile = Join-Path $vdir 'stderr.txt'
    $list = (@($Files) + $guard) -join ','
    $argLine = '--use-config-dir "{0}" --use-config-file "{1}"' -f $cfgDir, $list
    $savedGitDir = $env:GIT_DIR
    $savedWorkTree = $env:GIT_WORK_TREE
    Remove-Item -LiteralPath 'Env:GIT_DIR', 'Env:GIT_WORK_TREE' -ErrorAction SilentlyContinue
    try {
        $p = Start-Process -FilePath $script:RealLazygit -ArgumentList $argLine -WorkingDirectory $cwd `
            -RedirectStandardInput $stdin -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
            -NoNewWindow -PassThru
        if (-not $p.WaitForExit(20000)) {
            try { $p.Kill() } catch { }
            throw "lazygit did not exit within 20 s and was killed (args: $argLine)"
        }
    } finally {
        if ($savedGitDir) { $env:GIT_DIR = $savedGitDir }
        if ($savedWorkTree) { $env:GIT_WORK_TREE = $savedWorkTree }
    }
    return ((Read-Bytes $outFile) + (Read-Bytes $errFile)).Trim()
}

function Test-AppendRoundTrip([string]$BoxName, [string]$Original, [string]$AddedNewline) {
    $b = New-Box $BoxName
    Write-Bytes $b.Config $Original
    Install-Box $b @{ Mode = 'Append' }
    $expected = $Original + $AddedNewline + $script:Block
    Assert-FileText $b.Config $expected 'config.yml after append (original bytes + block)'
    Assert-FileText $b.Bak $Original '.bak holds the original bytes'
    Install-Box $b @{ Mode = 'Append' }
    Assert-FileText $b.Config $expected 'config.yml after a second append (idempotent)'
    Assert-Equal 1 (Get-Count (Read-Bytes $b.Config) $BeginMarker) 'number of theme blocks'
    Install-Box $b @{ Uninstall = $true }
    Assert-FileText $b.Config ($Original + $AddedNewline) 'config.yml after uninstall (original bytes + the EOF newline added by append, if any)'
    Assert-FileText $b.Bak $expected '.bak holds the file as it was before uninstall'
}

# ------------------------------------------------------------------ setup

$tmpParent = $env:LGVDM_TEST_TMPDIR
if (-not $tmpParent) { $tmpParent = [System.IO.Path]::GetTempPath() }
[void][System.IO.Directory]::CreateDirectory($tmpParent)
$script:Sandbox = Join-Path $tmpParent ('lgvdm-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][System.IO.Directory]::CreateDirectory($script:Sandbox)
$script:Sandbox = (Resolve-Path -LiteralPath $script:Sandbox).ProviderPath

$SavedLg = [Environment]::GetEnvironmentVariable('LG_CONFIG_FILE', 'Process')
$SavedConfigDir = [Environment]::GetEnvironmentVariable('CONFIG_DIR', 'Process')
$SavedEnv = @{}
foreach ($name in @('PATH', 'XDG_CONFIG_HOME', 'XDG_CONFIG_DIRS', 'LGVDM_TEST_ENV_KEY')) {
    $SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$UserLgBefore = [string][Environment]::GetEnvironmentVariable('LG_CONFIG_FILE', 'User')
$script:EnvKey = 'HKCU:\Software\lgvdm-test\' + [System.IO.Path]::GetFileName($script:Sandbox)
$script:SeamOk = $false
$RealConfigDir = $SavedConfigDir
if (-not $RealConfigDir) {
    $RealConfigDir = [System.IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'lazygit')
}
$RealThemeFile = Join-Path (Join-Path $RealConfigDir 'themes') 'vscode-dark-modern.yml'
$RealConfigFile = Join-Path $RealConfigDir 'config.yml'
function Get-RealState {
    $cfg = '(missing)'
    if (Test-Path -LiteralPath $RealConfigFile -PathType Leaf) {
        $cfg = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($RealConfigFile))
    }
    return "theme-exists=$(Test-Path -LiteralPath $RealThemeFile) config=$cfg"
}
$RealStateBefore = Get-RealState

$ThemeRaw = Read-Bytes $ThemeSource
$script:ThemeText = (($ThemeRaw -replace "`r`n", "`n") -replace "`n+\z", '') + "`n"
$script:Block = $BeginMarker + "`n" + $script:ThemeText + $EndMarker + "`n"
$script:Catalog = @(
    Get-Content -LiteralPath $CatalogSource | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $parts = $line -split '\|', 2
        [pscustomobject]@{ Id = $parts[0]; Name = $parts[1] }
    }
)
$script:Catalog | ForEach-Object {
    Assert-True ($_.Id -match '^[a-z0-9]+(?:-[a-z0-9]+)*$') "invalid catalog ID: $($_.Id)"
    Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $RepoRoot 'themes') ($_.Id + '.yml')) -PathType Leaf) "missing theme source for $($_.Id)"
    $palette = Join-Path (Join-Path (Join-Path $RepoRoot 'extras') 'windows-terminal') ($_.Id + '.json')
    Assert-True (Test-Path -LiteralPath $palette -PathType Leaf) "missing terminal palette for $($_.Id)"
    Assert-True (-not [string]::IsNullOrWhiteSpace(([IO.File]::ReadAllText($palette) | ConvertFrom-Json).name)) "terminal palette for $($_.Id) has no name"
}
$script:RealLazygit = Find-RealLazygit

Write-Host "Repository: $RepoRoot"
Write-Host "Sandbox:    $script:Sandbox"
Write-Host "PowerShell: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
if ($script:RealLazygit) { Write-Host "lazygit:    $script:RealLazygit" } else { Write-Host 'lazygit:    not found (validation checks will be skipped)' }
Write-Host ''

# ------------------------------------------------------------------ checks

try {

Remove-Item -LiteralPath 'Env:CONFIG_DIR', 'Env:XDG_CONFIG_HOME', 'Env:XDG_CONFIG_DIRS' -ErrorAction SilentlyContinue
$env:LGVDM_TEST_ENV_KEY = $script:EnvKey
Set-TestLg ''

Invoke-Check '(0) static: scripts are pure ASCII without BOM' {
    foreach ($f in @($Installer, $Uninstaller, $TestScript)) {
        $m = [regex]::Match((Read-Bytes $f), '[^\x00-\x7F]')
        Assert-True (-not $m.Success) "$f has a non-ASCII byte at offset $($m.Index)"
    }
}

Invoke-Check '(0) static: install.ps1/uninstall.ps1 parse on this PowerShell, no exit, no ?. operator' {
    foreach ($f in @($Installer, $Uninstaller)) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) {
            throw "$f has parse errors: $(@($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')"
        }
        $exits = @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Exit })
        if ($exits.Count -gt 0) {
            throw "$f uses exit (line $($exits[0].Extent.StartLineNumber)); it must use return/throw"
        }
        # Windows PowerShell 5.1 reads $x?.y as a variable named 'x?'.
        $odd = @($tokens | Where-Object { $_.Kind -eq [System.Management.Automation.Language.TokenKind]::Variable -and $_.Text.EndsWith('?') })
        if ($odd.Count -gt 0) {
            throw "$f uses ?. style syntax (line $($odd[0].Extent.StartLineNumber))"
        }
    }
}

Invoke-Check '(1) embedded catalog in install.ps1 equals every catalog theme' {
    $text = (Read-Bytes $Installer) -replace "`r`n", "`n"
    foreach ($entry in $script:Catalog) {
        $source = ((Read-Bytes (Join-Path (Join-Path $RepoRoot 'themes') ($entry.Id + '.yml'))) -replace "`r`n", "`n") -replace "`n\z", ''
        $pattern = "(?s)'$([regex]::Escape($entry.Id))'\s*=\s*@'\n(.*?)\n'@"
        $matches2 = [regex]::Matches($text, $pattern)
        Assert-True ($matches2.Count -eq 1) "expected one embedded $($entry.Id) theme in install.ps1, found $($matches2.Count)"
        Assert-Equal $source $matches2[0].Groups[1].Value "embedded $($entry.Id) theme in install.ps1"
    }
}

Invoke-Check '(1) embedded catalog in install.sh equals every catalog theme' {
    if (-not (Test-Path -LiteralPath $ShInstaller -PathType Leaf)) {
        Write-Warning "install.sh not found at $ShInstaller; skipping its embedded theme check"
        Skip-Check 'install.sh not found'
    }
    $text = (Read-Bytes $ShInstaller) -replace "`r`n", "`n"
    foreach ($entry in $script:Catalog) {
        $source = ((Read-Bytes (Join-Path (Join-Path $RepoRoot 'themes') ($entry.Id + '.yml'))) -replace "`r`n", "`n") -replace "`n\z", ''
        $delimiter = $entry.Id.ToUpperInvariant().Replace('-', '_')
        $pattern = "(?s)\s$([regex]::Escape($entry.Id))\)\n\s+cat <<'LGVDM_THEME_$delimiter`_EOF'\n(.*?)\nLGVDM_THEME_$delimiter`_EOF"
        $matches2 = [regex]::Matches($text, $pattern)
        Assert-True ($matches2.Count -eq 1) "expected one embedded $($entry.Id) theme in install.sh, found $($matches2.Count)"
        Assert-Equal $source $matches2[0].Groups[1].Value "embedded $($entry.Id) theme in install.sh"
    }
}

Invoke-Check '(2) fresh install: empty config.yml created, theme byte-identical, LG_CONFIG_FILE = theme,config' {
    $b = New-Box 'fresh'
    Set-TestLg ''
    Install-Box $b
    Assert-FileText $b.Config '' 'config.yml is created empty'
    Assert-FileText $b.Theme $script:ThemeText 'installed theme is byte-identical to themes/vscode-dark-modern.yml'
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE'
    Assert-True ($script:LastOutput -match 'Theme source: .*themes') "a clone should use its themes/ file; output:`n$script:LastOutput"
    Assert-Missing $b.Bak 'overlay mode writes no .bak'
}

Invoke-Check '(2) every catalog theme installs, selects cleanly, and has a terminal palette' {
    foreach ($entry in $script:Catalog) {
        $b = New-Box ('catalog-' + $entry.Id)
        Set-TestLg ''
        Install-Box $b @{ Theme = $entry.Id }
        $selected = Join-Path $b.Themes ($entry.Id + '.yml')
        Assert-Equal "$selected,$($b.Config)" (Get-TestLg) "LG_CONFIG_FILE for $($entry.Id)"
        foreach ($installed in $script:Catalog) {
            $source = ((Read-Bytes (Join-Path (Join-Path $RepoRoot 'themes') ($installed.Id + '.yml'))) -replace "`r`n", "`n") -replace "`n+\z", ''
            $source += "`n"
            Assert-FileText (Join-Path $b.Themes ($installed.Id + '.yml')) $source "installed $($installed.Id) theme"
        }
        Assert-True ((Read-Bytes (Join-Path $b.Themes '.lazygit-vscode-themes-managed')) -match [regex]::Escape($entry.Id)) "manifest tracks $($entry.Id)"
        $palette = Join-Path (Join-Path (Join-Path $RepoRoot 'extras') 'windows-terminal') ($entry.Id + '.json')
        Assert-True (-not [string]::IsNullOrWhiteSpace(([IO.File]::ReadAllText($palette) | ConvertFrom-Json).name)) "palette name for $($entry.Id)"
    }
    $b = New-Box 'catalog-switch'
    Set-TestLg ''
    Install-Box $b @{ Theme = 'vscode-dark-modern' }
    Install-Box $b @{ Theme = 'vscode-light-modern' }
    $light = Join-Path $b.Themes 'vscode-light-modern.yml'
    Assert-Equal "$light,$($b.Config)" (Get-TestLg) 'switch removes the previous catalog theme from LG_CONFIG_FILE'
}

Invoke-Check '(2) -ListThemes and an invalid -Theme change no config files' {
    $b = New-Box 'catalog-list-invalid' -NoCreate
    Invoke-Script $Installer @{ ListThemes = $true }
    foreach ($entry in $script:Catalog) { Assert-True ($script:LastOutput.Contains($entry.Id)) "-ListThemes includes $($entry.Id)" }
    $before = Test-Path -LiteralPath $b.Dir
    $thrown = $false
    try { Install-Box $b @{ Theme = 'not-a-theme' } } catch { $thrown = $true }
    Assert-True $thrown 'unknown theme is rejected'
    Assert-Equal $before (Test-Path -LiteralPath $b.Dir) 'invalid theme created no config directory'
}

Invoke-Check '(2) catalog ownership prevents overwrite and preserves a modified managed theme on uninstall' {
    $collision = New-Box 'catalog-collision'
    [void][System.IO.Directory]::CreateDirectory($collision.Themes)
    $userLight = Join-Path $collision.Themes 'vscode-light-modern.yml'
    New-File $userLight "user-owned`n"
    $thrown = $false
    try { Install-Box $collision @{ Theme = 'vscode-dark-modern' } } catch { $thrown = $true }
    Assert-True $thrown 'untracked catalog filename is not overwritten'
    Assert-FileText $userLight "user-owned`n" 'untracked catalog filename is unchanged'

    $b = New-Box 'catalog-modified-uninstall'
    Set-TestLg ''
    Install-Box $b @{ Theme = 'vscode-light-modern' }
    $light = Join-Path $b.Themes 'vscode-light-modern.yml'
    [System.IO.File]::AppendAllText($light, "# user edit`n", [System.Text.UTF8Encoding]::new($false))
    Install-Box $b @{ Uninstall = $true }
    Assert-True (Test-Path -LiteralPath $light) 'modified managed file is preserved'
    Assert-Missing (Join-Path $b.Themes 'vscode-dark-modern.yml') 'unmodified managed file is removed'
    Assert-Missing (Join-Path $b.Themes '.lazygit-vscode-themes-managed') 'ownership manifest is removed'
}

Invoke-Check '(3) an existing config.yml with content is left untouched' {
    $b = New-Box 'existing-config'
    $original = "# my settings`r`ngit:`r`n  autoFetch: false`r`ngui:`r`n  nerdFontsVersion: `"3`"`r`n"
    Write-Bytes $b.Config $original
    Set-TestLg ''
    Install-Box $b
    Assert-FileText $b.Config $original 'config.yml bytes'
    Assert-Missing $b.Bak 'overlay mode writes no .bak'
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE'
}

Invoke-Check '(4) LG_CONFIG_FILE with ONE existing entry -> theme,entry; no config.yml, customize the entry' {
    $b = New-Box 'one-entry'
    $mine = New-File (Join-Path $b.Dir 'mine.yml') "git:`n  autoFetch: false`n"
    Set-TestLg $mine
    Install-Box $b
    Assert-Equal "$($b.Theme),$mine" (Get-TestLg) 'LG_CONFIG_FILE'
    # config.yml is not listed, so lazygit would not read it: neither create nor recommend it.
    Assert-Missing $b.Config 'config.yml (not listed in LG_CONFIG_FILE)'
    Assert-True ($script:LastOutput.Contains("Customize in $mine (the last file in LG_CONFIG_FILE)")) "should point at $mine; output:`n$script:LastOutput"
    Assert-True (-not $script:LastOutput.Contains("Customize in $($b.Config)")) "should not point at config.yml; output:`n$script:LastOutput"
    # A listed but missing config.yml is created (lazygit refuses to start without it).
    Set-TestLg "$mine,$($b.Config)"
    Install-Box $b
    Assert-Equal "$($b.Theme),$mine,$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE with config.yml listed'
    Assert-FileText $b.Config '' 'listed config.yml is created empty'
    Assert-True ($script:LastOutput.Contains("Customize in $($b.Config); it overrides the theme")) "output:`n$script:LastOutput"
}

Invoke-Check '(5) two entries, spaces around commas, trailing comma -> normalized, theme first' {
    $b = New-Box 'two-entries'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    $two = New-File (Join-Path $b.Dir 'two.yml') ''
    Set-TestLg "  $one , $two ,"
    Install-Box $b
    Assert-Equal "$($b.Theme),$one,$two" (Get-TestLg) 'LG_CONFIG_FILE'
}

Invoke-Check '(6) reinstall is idempotent (value and files identical, nothing reported)' {
    $b = New-Box 'idempotent'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    Write-Bytes $b.Config "git:`n  autoFetch: false`n"
    Set-TestLg " $one ,, $($b.Config)"
    Install-Box $b
    $value1 = Get-TestLg
    $theme1 = Read-Bytes $b.Theme
    $config1 = Read-Bytes $b.Config
    Assert-Equal "$($b.Theme),$one,$($b.Config)" $value1 'LG_CONFIG_FILE after the first run'
    Install-Box $b
    Assert-Equal $value1 (Get-TestLg) 'LG_CONFIG_FILE after the second run'
    Assert-FileText $b.Theme $theme1 'theme file after the second run'
    Assert-FileText $b.Config $config1 'config.yml after the second run'
    Assert-True ($script:LastOutput -match 'Nothing changed') "second run should report no changes; output:`n$script:LastOutput"
    Install-Box $b
    Assert-Equal $value1 (Get-TestLg) 'LG_CONFIG_FILE after the third run'
}

Invoke-Check '(7) theme already listed in a non-first position -> moved first, not duplicated' {
    $b = New-Box 'reorder'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    $two = New-File (Join-Path $b.Dir 'two.yml') ''
    Set-TestLg "$one,$($b.Theme),$two"
    Install-Box $b
    Assert-Equal "$($b.Theme),$one,$two" (Get-TestLg) 'LG_CONFIG_FILE (same spelling)'
    # Same file spelled with other case and forward slashes (Windows paths are case-insensitive).
    Set-TestLg "$one,$($b.Theme.ToUpperInvariant().Replace('\', '/'))"
    Install-Box $b
    Assert-Equal "$($b.Theme),$one" (Get-TestLg) 'LG_CONFIG_FILE (other spelling)'
}

Invoke-Check '(8) uninstall: theme + empty themes dir removed, LG_CONFIG_FILE deleted when only config.yml remains' {
    $b = New-Box 'uninstall-basic'
    Set-TestLg ''
    Install-Box $b
    Write-Bytes $b.Config "git:`n  autoFetch: false`n"
    Install-Box $b @{ Uninstall = $true }
    Assert-Missing $b.Theme 'theme file'
    Assert-Missing $b.Themes 'empty themes directory'
    Assert-True ($null -eq (Get-TestLg)) "LG_CONFIG_FILE should be deleted, is: $(Get-TestLg)"
    Assert-FileText $b.Config "git:`n  autoFetch: false`n" 'config.yml is kept unchanged'
    Assert-Missing $b.Bak 'no .bak when config.yml has no theme block'
    # Remainder empty: the value listed only the theme.
    Install-Box $b
    Set-TestLg $b.Theme
    Install-Box $b @{ Uninstall = $true }
    Assert-True ($null -eq (Get-TestLg)) "LG_CONFIG_FILE should be deleted when only the theme was listed, is: $(Get-TestLg)"
}

Invoke-Check '(8) uninstall: other entries are kept, a non-empty themes dir is kept, config.yml untouched' {
    $b = New-Box 'uninstall-keep'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    $two = New-File (Join-Path $b.Dir 'two.yml') ''
    Write-Bytes $b.Config "gui:`r`n  border: rounded`r`n"
    Set-TestLg "$one,$two"
    Install-Box $b
    Assert-Equal "$($b.Theme),$one,$two" (Get-TestLg) 'LG_CONFIG_FILE after install'
    $other = New-File (Join-Path $b.Themes 'other.yml') ''
    Install-Box $b @{ Uninstall = $true }
    Assert-Equal "$one,$two" (Get-TestLg) 'LG_CONFIG_FILE after uninstall'
    Assert-Missing $b.Theme 'theme file'
    Assert-True (Test-Path -LiteralPath $other) 'other files in themes/ are kept'
    Assert-FileText $b.Config "gui:`r`n  border: rounded`r`n" 'config.yml is untouched'
    # config.yml plus another entry: not "only config.yml", so the value is kept.
    Set-TestLg "$($b.Theme),$($b.Config),$one"
    Install-Box $b @{ Uninstall = $true }
    Assert-Equal "$($b.Config),$one" (Get-TestLg) 'LG_CONFIG_FILE with config.yml and another entry'
}

Invoke-Check '(8) uninstall with nothing installed changes nothing' {
    $b = New-Box 'uninstall-noop'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    Set-TestLg $one
    Install-Box $b @{ Uninstall = $true }
    Assert-Equal $one (Get-TestLg) 'LG_CONFIG_FILE'
    Assert-Missing $b.Config 'config.yml is not created by uninstall'
    Assert-True ($script:LastOutput -match 'Nothing changed') "output:`n$script:LastOutput"
}

Invoke-Check '(8) uninstall.ps1 forwards -ConfigDir and -NoPersist to install.ps1 -Uninstall' {
    $b = New-Box 'uninstall-wrapper'
    Set-TestLg ''
    Install-Box $b
    Invoke-Script $Uninstaller @{ ConfigDir = $b.Dir; NoPersist = $true }
    Assert-Missing $b.Theme 'theme file'
    Assert-True ($null -eq (Get-TestLg)) "LG_CONFIG_FILE should be deleted, is: $(Get-TestLg)"
    Assert-FileText $b.Config '' 'config.yml is kept'
}

Invoke-Check '(8) -NoPersist: the printed undo command runs in this session and restores it' {
    # Quotes in the path: the command must quote them for PowerShell (incl. typographic ones).
    $b = New-Box ("undo o'brien " + [char]0x2019 + 'x')
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    Set-TestLg $one
    Install-Box $b
    $undo = Get-UndoLine
    Assert-True ($undo.StartsWith("& '", [System.StringComparison]::Ordinal)) "a -NoPersist undo must run in this process (not powershell -File): $undo"
    Assert-True ($undo.EndsWith(' -NoPersist', [System.StringComparison]::Ordinal)) "undo command: $undo"
    $null = Invoke-Expression $undo *>&1
    Assert-Equal $one (Get-TestLg) 'LG_CONFIG_FILE of this process after running the undo command'
    Assert-Missing $b.Theme 'theme file after running the undo command'
}

Invoke-Check '(8) uninstall fixes LG_CONFIG_FILE before it deletes the theme file (config.yml write fails)' {
    $b = New-Box 'uninstall-order'
    Set-TestLg ''
    Install-Box $b @{ Mode = 'Append' }
    Install-Box $b
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE after both installs'
    $withBlock = Read-Bytes $b.Config
    (Get-Item -LiteralPath $b.Config).IsReadOnly = $true
    $threw = $false
    try { Install-Box $b @{ Uninstall = $true } } catch { $threw = $true } finally { (Get-Item -LiteralPath $b.Config).IsReadOnly = $false }
    Assert-True $threw 'uninstall should fail on a read-only config.yml'
    Assert-True ($null -eq (Get-TestLg)) "LG_CONFIG_FILE must no longer list the theme, is: $(Get-TestLg)"
    Assert-True (Test-Path -LiteralPath $b.Theme) 'the theme file is deleted last, so it still exists'
    Assert-FileText $b.Config $withBlock 'config.yml unchanged'
    Assert-True (-not (Get-Item -LiteralPath $b.Bak).IsReadOnly) '.bak must not inherit the read-only attribute (it would block the next backup)'
    Install-Box $b @{ Uninstall = $true }
    Assert-Missing $b.Theme 'theme file after a second uninstall'
    Assert-Equal 0 (Get-Count (Read-Bytes $b.Config) $BeginMarker) 'theme blocks after a second uninstall'
}

$RemoteDir = Join-Path $script:Sandbox 'remote-src'
[void][System.IO.Directory]::CreateDirectory($RemoteDir)
$RemoteCopy = Join-Path $RemoteDir 'install.ps1'
[System.IO.File]::Copy($Installer, $RemoteCopy, $true)

Invoke-Check '(9) remote mode: & ([scriptblock]::Create(text)) uses every embedded catalog theme; caller state intact, no exit' {
    Assert-Missing (Join-Path $RemoteDir 'themes') 'themes/ next to the remote copy'
    $b = New-Box 'remote'
    Set-TestLg ''
    $code = Get-Content -LiteralPath $RemoteCopy -Raw
    $ErrorActionPreference = 'Continue'
    $out = & ([scriptblock]::Create($code)) -ConfigDir $b.Dir -NoPersist *>&1 | ForEach-Object { [string]$_ }
    $reached = $true
    $eapAfter = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    Assert-True $reached 'execution continued after the installer'
    Assert-Equal 'Continue' $eapAfter 'caller $ErrorActionPreference'
    $text = @($out) -join "`n"
    Assert-True ($text -match 'embedded') "the embedded theme should be used; output:`n$text"
    Assert-FileText $b.Theme $script:ThemeText 'default theme written from the embedded copy'
    Assert-FileText $b.Config '' 'config.yml is created empty'
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE'
    $light = Join-Path $b.Themes 'vscode-light-modern.yml'
    $null = & ([scriptblock]::Create($code)) -ConfigDir $b.Dir -NoPersist -Theme vscode-light-modern *>&1
    Assert-Equal "$light,$($b.Config)" (Get-TestLg) 'remote installer switches to its embedded light theme'
    foreach ($entry in $script:Catalog) {
        Assert-True (Test-Path -LiteralPath (Join-Path $b.Themes ($entry.Id + '.yml'))) "remote installer wrote $($entry.Id)"
    }
    # Uninstall the same way (the documented remote uninstall one-liner).
    $null = & ([scriptblock]::Create($code)) -Uninstall -ConfigDir $b.Dir -NoPersist *>&1
    Assert-Missing $b.Theme 'theme file after remote uninstall'
    Assert-True ($null -eq (Get-TestLg)) 'LG_CONFIG_FILE after remote uninstall'
}

Invoke-Check '(9) dot-sourced script text (the scope irm | iex runs in) leaks no variables, preferences or strict mode' {
    $b = New-Box 'dot-source'
    Set-TestLg ''
    $code = Get-Content -LiteralPath $RemoteCopy -Raw
    Set-StrictMode -Off
    $ErrorActionPreference = 'Continue'
    $null = . ([scriptblock]::Create($code)) -ConfigDir $b.Dir -NoPersist *>&1
    $eapAfter = $ErrorActionPreference
    $probe = $ThisVariableIsNeverDefined   # throws only if the installer leaked Set-StrictMode
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0
    Assert-Equal 'Continue' $eapAfter 'caller $ErrorActionPreference'
    Assert-True ($null -eq $probe) 'probe'
    foreach ($name in @('EmbeddedCatalog', 'EmbeddedThemes', 'ThemeDest', 'TargetDir', 'ConfigFile', 'Changes', 'Prefix', 'Latin1')) {
        Assert-True ($null -eq (Get-Variable -Name $name -Scope 0 -ErrorAction SilentlyContinue)) "variable `$$name leaked into the caller scope"
    }
    Assert-True ($null -eq (Get-Command -Name 'Install-LazygitVSCodeThemes' -ErrorAction SilentlyContinue)) 'function Install-LazygitVSCodeThemes leaked into the caller scope'
    Assert-FileText $b.Theme $script:ThemeText 'theme written'
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE'
}

Invoke-Check '(9) Invoke-Expression of the script text (irm | iex) works and leaks no variables' {
    $b = New-Box 'iex'
    Set-TestLg ''
    $code = Get-Content -LiteralPath $RemoteCopy -Raw
    $call = 'Install-LazygitVSCodeThemes -Uninstall:$Uninstall -Mode $Mode -ConfigDir $ConfigDir -NoPersist:$NoPersist -Theme $Theme -ListThemes:$ListThemes'
    Assert-Equal 1 (Get-Count $code $call) 'occurrences of the call line at the bottom of install.ps1'
    # iex cannot pass parameters (a real irm | iex persists to the User scope), so the call
    # line is pointed at the sandbox with -NoPersist; the rest of the text runs unchanged.
    $code = $code.Replace($call, "Install-LazygitVSCodeThemes -ConfigDir '$($b.Dir)' -NoPersist")
    # Caller variables that share a name with the installer's internal variables must survive.
    # (Ones named like its parameters -Uninstall/-Mode/-ConfigDir/-NoPersist do not: iex runs
    # the param() block in this scope. install.ps1 documents that limit.)
    $ThemeDest = 'caller ThemeDest'
    $Changes = 'caller Changes'
    $ErrorActionPreference = 'Continue'
    $null = Invoke-Expression $code *>&1
    $eapAfter = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    Assert-Equal 'Continue' $eapAfter 'caller $ErrorActionPreference'
    Assert-Equal 'caller ThemeDest' $ThemeDest 'caller variable $ThemeDest'
    Assert-Equal 'caller Changes' $Changes 'caller variable $Changes'
    foreach ($name in @('EmbeddedCatalog', 'EmbeddedThemes', 'TargetDir', 'ConfigFile', 'Prefix', 'Uninstall', 'Mode', 'NoPersist', 'Theme', 'ListThemes')) {
        Assert-True ($null -eq (Get-Variable -Name $name -Scope 0 -ErrorAction SilentlyContinue)) "variable `$$name leaked into the caller scope"
    }
    Assert-True ($null -eq (Get-Command -Name 'Install-LazygitVSCodeThemes' -ErrorAction SilentlyContinue)) 'function Install-LazygitVSCodeThemes leaked into the caller scope'
    Assert-FileText $b.Theme $script:ThemeText 'theme written from the embedded copy'
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE'
}

Invoke-Check '(10) CONFIG_DIR is honored when -ConfigDir is not given (non-ASCII path)' {
    # A non-ASCII letter checks that lazygit's UTF-8 output is decoded as such (any console code page).
    $b = New-Box ('config dir from env ' + [char]0xE9) -NoCreate
    $env:CONFIG_DIR = $b.Dir
    try {
        $lg = Get-Command -Name 'lazygit' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lg) {
            # Safety pre-check: the installer asks lazygit, so lazygit must answer the sandbox.
            Assert-Equal $b.Dir (Get-PrintedConfigDir $lg.Path) 'lazygit --print-config-dir with CONFIG_DIR set (installer not run)'
        }
        Set-TestLg ''
        Invoke-Script $Installer @{ NoPersist = $true }
        Assert-FileText $b.Theme $script:ThemeText 'theme installed under CONFIG_DIR'
        Assert-FileText $b.Config '' 'config.yml created under CONFIG_DIR'
        Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE'
        if ($lg) { $source = 'lazygit --print-config-dir' } else { $source = 'CONFIG_DIR' }
        Assert-True ($script:LastOutput -match [regex]::Escape("(from $source)")) "config dir should come from $source; output:`n$script:LastOutput"
        Invoke-Script $Installer @{ NoPersist = $true; Uninstall = $true }
        Assert-Missing $b.Theme 'theme file after uninstall'
    } finally {
        Remove-Item -LiteralPath 'Env:CONFIG_DIR' -ErrorAction SilentlyContinue
    }
}

Invoke-Check '(10) a relative -ConfigDir is resolved to an absolute path' {
    $b = New-Box 'relative dir' -NoCreate
    Set-TestLg ''
    Push-Location -LiteralPath $script:Sandbox
    try {
        Invoke-Script $Installer @{ ConfigDir = '.\relative dir'; NoPersist = $true }
    } finally {
        Pop-Location
    }
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE'
    Assert-FileText $b.Theme $script:ThemeText 'theme file'
}

Invoke-Check '(10) overlay mode refuses a config dir containing a comma' {
    $b = New-Box 'comma,dir' -NoCreate
    Set-TestLg ''
    $threw = $false
    try { Install-Box $b } catch { $threw = $true; $msg = $_.Exception.Message }
    Assert-True $threw 'install should throw'
    Assert-True ($msg -match 'comma') "message: $msg"
    Assert-Missing $b.Dir 'config dir'
    Assert-True ($null -eq (Get-TestLg)) 'LG_CONFIG_FILE unchanged'
}

Invoke-Check '(11) append: empty config.yml -> exactly one block; rerun keeps one block; no .bak' {
    $b = New-Box 'append-empty'
    Write-Bytes $b.Config ''
    Install-Box $b @{ Mode = 'Append' }
    Assert-FileText $b.Config $script:Block 'config.yml after append'
    Assert-Missing $b.Bak 'no .bak for an empty config.yml'
    Install-Box $b @{ Mode = 'Append' }
    Assert-FileText $b.Config $script:Block 'config.yml after a second append'
    Assert-Equal 1 (Get-Count (Read-Bytes $b.Config) $BeginMarker) 'number of theme blocks'
    Assert-True ($script:LastOutput -match 'already up to date') "output:`n$script:LastOutput"
    Install-Box $b @{ Uninstall = $true }
    Assert-FileText $b.Config '' 'config.yml after uninstall'
}

Invoke-Check '(11) append: missing config.yml is created with the block' {
    $b = New-Box 'append-missing' -NoCreate
    Install-Box $b @{ Mode = 'Append' }
    Assert-FileText $b.Config $script:Block 'config.yml'
    Assert-Missing $b.Bak '.bak'
}

Invoke-Check '(11) append: LF config -> original bytes kept as prefix, .bak, uninstall restores' {
    Test-AppendRoundTrip 'append-lf' "# mine`ngit:`n  autoFetch: false`n" ''
}

Invoke-Check '(11) append: CRLF config -> original bytes kept as prefix, .bak, uninstall restores' {
    Test-AppendRoundTrip 'append-crlf' "# mine`r`ngit:`r`n  autoFetch: false`r`n" ''
}

Invoke-Check '(11) append: UTF-8 BOM + non-ASCII bytes are preserved' {
    $bom = [string][char]0xEF + [char]0xBB + [char]0xBF
    $utf8 = [string][char]0xC3 + [char]0xA9   # "e acute" as UTF-8 bytes
    Test-AppendRoundTrip 'append-bom' ($bom + "# caf$utf8`ngit:`n  autoFetch: false`n") ''
}

Invoke-Check '(11) append: no final newline -> exactly one newline added (LF file: LF), kept on uninstall' {
    Test-AppendRoundTrip 'append-noeol-lf' "git:`n  autoFetch: false" "`n"
}

Invoke-Check '(11) append: no final newline -> exactly one newline added (CRLF file: CRLF), kept on uninstall' {
    Test-AppendRoundTrip 'append-noeol-crlf' "git:`r`n  autoFetch: false" "`r`n"
}

Invoke-Check '(11) append: top-level gui: -> refused, file unchanged, no .bak' {
    $bom = [string][char]0xEF + [char]0xBB + [char]0xBF
    $cases = @(
        "git:`n  autoFetch: false`ngui:`n  border: rounded`n",
        "gui :`r`n  border: rounded`r`n",
        ($bom + "gui:`n  nerdFontsVersion: `"3`"`n"),
        "`"gui`":`n  border: rounded`n",
        "'gui' :`n  border: rounded`n"
    )
    $i = 0
    foreach ($original in $cases) {
        $i++
        $b = New-Box "append-refuse-$i"
        Write-Bytes $b.Config $original
        $threw = $false
        $msg = ''
        try { Install-Box $b @{ Mode = 'Append' } } catch { $threw = $true; $msg = $_.Exception.Message }
        Assert-True $threw "case ${i}: append should be refused"
        Assert-True ($msg -match 'refused') "case ${i}: message: $msg"
        Assert-FileText $b.Config $original "case ${i}: config.yml unchanged"
        Assert-Missing $b.Bak "case ${i}: .bak"
    }
    # An indented gui: key (not top-level) is not a conflict.
    $b = New-Box 'append-nested-gui'
    Write-Bytes $b.Config "customCommands:`n  - key: X`n    gui: true`n"
    Install-Box $b @{ Mode = 'Append' }
    Assert-Equal 1 (Get-Count (Read-Bytes $b.Config) $BeginMarker) 'nested gui: key does not block append'
}

Invoke-Check '(11) append: UTF-16 config.yml (Windows PowerShell > / Out-File) -> refused, file unchanged, no .bak' {
    $text = "git:`r`n  autoFetch: false`r`n"
    $cases = @(
        ($Latin1.GetString([System.Text.Encoding]::Unicode.GetPreamble()) + $Latin1.GetString([System.Text.Encoding]::Unicode.GetBytes($text))),
        ($Latin1.GetString([System.Text.Encoding]::BigEndianUnicode.GetPreamble()) + $Latin1.GetString([System.Text.Encoding]::BigEndianUnicode.GetBytes($text))),
        $Latin1.GetString([System.Text.Encoding]::Unicode.GetBytes($text))   # no BOM: NUL bytes
    )
    $i = 0
    foreach ($original in $cases) {
        $i++
        $b = New-Box "append-utf16-$i"
        Write-Bytes $b.Config $original
        $threw = $false
        $msg = ''
        try { Install-Box $b @{ Mode = 'Append' } } catch { $threw = $true; $msg = $_.Exception.Message }
        Assert-True $threw "case ${i}: append should be refused"
        Assert-True ($msg -match 'refused' -and $msg -match 'UTF-16') "case ${i}: message: $msg"
        Assert-FileText $b.Config $original "case ${i}: config.yml unchanged"
        Assert-Missing $b.Bak "case ${i}: .bak"
    }
}

Invoke-Check '(11) uninstall leaves a UTF-16 config.yml alone (warns if it has a theme block)' {
    $b = New-Box 'uninstall-utf16'
    $utf16 = $Latin1.GetString([byte[]](0xFF, 0xFE)) + $Latin1.GetString([System.Text.Encoding]::Unicode.GetBytes("gui:`r`n  border: rounded`r`n"))
    # What an older append left behind: UTF-16 text followed by a UTF-8 block.
    $mixed = $utf16 + $script:Block
    Write-Bytes $b.Config $mixed
    Set-TestLg ''
    Install-Box $b @{ Uninstall = $true }
    Assert-FileText $b.Config $mixed 'config.yml unchanged'
    Assert-Missing $b.Bak '.bak'
    Assert-True ($script:LastOutput -match 'UTF-16LE.*left unchanged') "expected a warning; output:`n$script:LastOutput"
    Write-Bytes $b.Config $utf16
    Install-Box $b @{ Uninstall = $true }
    Assert-FileText $b.Config $utf16 'config.yml without a block unchanged'
    Assert-True ($script:LastOutput -notmatch 'left unchanged') "unexpected warning; output:`n$script:LastOutput"
}

Invoke-Check '(11) append: an existing (edited) block is replaced in place, content around it kept' {
    $b = New-Box 'append-replace'
    $before = "# mine`r`ngit:`r`n  autoFetch: false`r`n"
    $after = "os:`n  editPreset: vscode`n"
    $edited = $before + $script:Block.Replace("'#0078D4'", "'#FF0000'") + $after
    Write-Bytes $b.Config $edited
    Install-Box $b @{ Mode = 'Append' }
    Assert-FileText $b.Config ($before + $script:Block + $after) 'config.yml after replacing the block'
    Assert-FileText $b.Bak $edited '.bak holds the edited file'
    Assert-Equal 1 (Get-Count (Read-Bytes $b.Config) $BeginMarker) 'number of theme blocks'
    Install-Box $b @{ Uninstall = $true }
    Assert-FileText $b.Config ($before + $after) 'config.yml after uninstall'
}

Invoke-Check '(11) append mode does not touch LG_CONFIG_FILE or the themes directory' {
    $b = New-Box 'append-env'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    $value = "$one,$($b.Config)"
    Set-TestLg $value
    Install-Box $b @{ Mode = 'Append' }
    Assert-Equal $value (Get-TestLg) 'LG_CONFIG_FILE'
    Assert-Missing $b.Themes 'themes directory'
}

Invoke-Check '(12) overlay warns when config.yml sets gui.theme (and only then)' {
    $b = New-Box 'warn-theme'
    Write-Bytes $b.Config "gui:`n  border: rounded`n  theme:`n    activeBorderColor:`n      - '#FF0000'`n"
    Set-TestLg ''
    Install-Box $b
    Assert-True ($script:LastOutput -match 'sets gui\.theme') "expected a gui.theme warning; output:`n$script:LastOutput"
    $b2 = New-Box 'warn-none'
    Write-Bytes $b2.Config "gui:`n  border: rounded`nos:`n  theme: x`n"
    Set-TestLg ''
    Install-Box $b2
    Assert-True ($script:LastOutput -notmatch 'gui\.theme') "unexpected gui.theme warning; output:`n$script:LastOutput"
    # UTF-16 config.yml (Windows PowerShell 5.1's > writes that; lazygit reads it).
    $b3 = New-Box 'warn-theme-utf16'
    [System.IO.File]::WriteAllText($b3.Config, "gui:`r`n  theme:`r`n    activeBorderColor:`r`n      - '#FF0000'`r`n", [System.Text.Encoding]::Unicode)
    Set-TestLg ''
    Install-Box $b3
    Assert-True ($script:LastOutput -match 'sets gui\.theme') "expected a gui.theme warning for a UTF-16 config.yml; output:`n$script:LastOutput"
}

Invoke-Check '(13) lazygit accepts every catalog theme in overlay mode (theme first, user gui: settings after it)' {
    if (-not $script:RealLazygit) { Write-Warning 'lazygit not found; skipping'; Skip-Check 'lazygit not found' }
    $b = New-Box 'lazygit-overlay'
    Write-Bytes $b.Config "gui:`n  nerdFontsVersion: `"3`"`n"
    Set-TestLg ''
    Install-Box $b
    $files = @((Get-TestLg).Split(','))
    Assert-Equal 2 $files.Count 'entries in LG_CONFIG_FILE'
    foreach ($entry in $script:Catalog) {
        $files[0] = Join-Path $b.Themes ($entry.Id + '.yml')
        $out = Invoke-LazygitValidation ('overlay-' + $entry.Id) $files
        Assert-True ($out.Contains($ValidPhrase)) "lazygit rejected the $($entry.Id) overlay config:`n$out"
    }
}

Invoke-Check '(13) lazygit accepts an append-mode config.yml (CRLF user content + LF block)' {
    if (-not $script:RealLazygit) { Write-Warning 'lazygit not found; skipping'; Skip-Check 'lazygit not found' }
    $b = New-Box 'lazygit-append'
    Write-Bytes $b.Config "git:`r`n  autoFetch: false`r`n"
    Install-Box $b @{ Mode = 'Append' }
    $out = Invoke-LazygitValidation 'append' @($b.Config)
    Assert-True ($out.Contains($ValidPhrase)) "lazygit rejected the config:`n$out"
}

Invoke-Check '(13) validator control: lazygit rejects a config with two gui: keys' {
    if (-not $script:RealLazygit) { Write-Warning 'lazygit not found; skipping'; Skip-Check 'lazygit not found' }
    $bad = New-File (Join-Path $script:Sandbox 'bad.yml') ("gui:`n  border: rounded`n" + $script:ThemeText)
    $out = Invoke-LazygitValidation 'control' @($bad)
    Assert-True (-not $out.Contains($ValidPhrase)) "a broken config was accepted:`n$out"
    Assert-True ($out -match 'already defined') "unexpected lazygit output:`n$out"
}

Invoke-Check '(13) lazygit accepts overlay mode with a UTF-16 config.yml (what append mode refuses)' {
    if (-not $script:RealLazygit) { Write-Warning 'lazygit not found; skipping'; Skip-Check 'lazygit not found' }
    $b = New-Box 'lazygit-utf16'
    [System.IO.File]::WriteAllText($b.Config, "gui:`r`n  nerdFontsVersion: `"3`"`r`n", [System.Text.Encoding]::Unicode)
    Set-TestLg ''
    Install-Box $b
    $out = Invoke-LazygitValidation 'utf16' @((Get-TestLg).Split(','))
    Assert-True ($out.Contains($ValidPhrase)) "lazygit rejected the config:`n$out"
}

# ---- persisted mode (the default): User/Machine values in the fake store $script:EnvKey

Invoke-Check '(14a) test store: install.ps1 keeps User/Machine LG_CONFIG_FILE under LGVDM_TEST_ENV_KEY' {
    # Harmless even if install.ps1 ignored the store: nothing real lists this sandbox theme,
    # so a persisted uninstall would find nothing to change in the real User value.
    $b = New-Box 'store-probe'
    Reset-Env '' "$($b.Theme),$($b.Config)" ''
    Invoke-Script $Installer @{ ConfigDir = $b.Dir; Uninstall = $true }
    Assert-True ($script:LastOutput.Contains("Test mode: the User/Machine LG_CONFIG_FILE values are kept under $script:EnvKey")) "install.ps1 did not report the test store; output:`n$script:LastOutput"
    Assert-True ($null -eq (Get-Stored 'User')) "the fake User value should be deleted, is: $(Get-Stored 'User')"
    Assert-Equal $UserLgBefore ([string][Environment]::GetEnvironmentVariable('LG_CONFIG_FILE', 'User')) 'real User-scope LG_CONFIG_FILE'
    $script:SeamOk = $true
}

Invoke-Check '(14) persisted install: User value set, rerun idempotent, printed undo (powershell -File) removes it' {
    $b = New-Box 'persist-fresh'
    Reset-Env '' '' ''
    Install-Persisted $b
    $value = "$($b.Theme),$($b.Config)"
    Assert-Equal $value (Get-Stored 'User') 'User LG_CONFIG_FILE'
    Assert-Equal $value (Get-TestLg) 'LG_CONFIG_FILE of this process'
    Assert-True ($script:LastOutput.Contains("Set the User environment variable LG_CONFIG_FILE = $value (was not set)")) "output:`n$script:LastOutput"
    Assert-FileText $b.Config '' 'config.yml created empty'
    Assert-True ($null -eq (Get-Stored 'Machine')) 'Machine value untouched'
    Install-Persisted $b
    Assert-True ($script:LastOutput -match 'already up to date' -and $script:LastOutput -match 'Nothing changed') "second run should change nothing; output:`n$script:LastOutput"
    Assert-Equal $value (Get-Stored 'User') 'User LG_CONFIG_FILE after the second run'
    $undo = Get-UndoLine
    Assert-True ($undo.StartsWith('powershell -NoProfile -ExecutionPolicy Bypass -File "', [System.StringComparison]::Ordinal) -and $undo -notmatch 'NoPersist') "undo command: $undo"
    # The child powershell inherits LGVDM_TEST_ENV_KEY, so it uses the fake store too.
    $ErrorActionPreference = 'Continue'
    $childOut = @(Invoke-Expression $undo 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    $ErrorActionPreference = 'Stop'
    Assert-True ($childOut.Contains('Test mode:')) "the undo command did not use the test store; output:`n$childOut"
    Assert-True ($null -eq (Get-Stored 'User')) "User LG_CONFIG_FILE should be deleted, is: $(Get-Stored 'User')"
    Assert-Missing $b.Theme 'theme file after the undo command'
    Assert-FileText $b.Config '' 'config.yml is kept'
}

Invoke-Check '(14) persisted: only a Machine value -> it is the base list; uninstall deletes the User value again' {
    $b = New-Box 'persist-machine-base'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    Reset-Env '' '' $one
    Install-Persisted $b
    Assert-Equal "$($b.Theme),$one" (Get-Stored 'User') 'User LG_CONFIG_FILE'
    Assert-Missing $b.Config 'config.yml (not listed)'
    Install-Persisted $b @{ Uninstall = $true }
    Assert-True ($null -eq (Get-Stored 'User')) "User LG_CONFIG_FILE should be deleted (the Machine value is the same list), is: $(Get-Stored 'User')"
    Assert-Equal $one (Get-TestLg) 'LG_CONFIG_FILE of this process (what new terminals get from the Machine value)'
    Assert-Equal $one (Get-Stored 'Machine') 'Machine value untouched'
    Assert-Missing $b.Theme 'theme file'
}

Invoke-Check '(14) persisted: a User value that shadows a Machine value keeps shadowing it after uninstall' {
    $b = New-Box 'persist-shadow'
    Write-Bytes $b.Config "git:`n  autoFetch: false`n"
    $corp = New-File (Join-Path $b.Dir 'corp.yml') ''
    Reset-Env '' $b.Config $corp
    Install-Persisted $b
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-Stored 'User') 'User LG_CONFIG_FILE after install'
    Install-Persisted $b @{ Uninstall = $true }
    Assert-Equal $b.Config (Get-Stored 'User') 'User LG_CONFIG_FILE after uninstall (deleting it would bring the Machine value into effect)'
    Assert-Missing $b.Theme 'theme file'
}

Invoke-Check '(14) persisted: a Machine value that lists the theme keeps the theme file, with a warning' {
    $b = New-Box 'persist-machine-theme'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    Reset-Env '' '' "$($b.Theme),$one"
    Install-Persisted $b
    Assert-Equal "$($b.Theme),$one" (Get-Stored 'User') 'User LG_CONFIG_FILE'
    Install-Persisted $b @{ Uninstall = $true }
    Assert-True (Test-Path -LiteralPath $b.Theme) 'theme file kept while the Machine value lists it'
    Assert-True ($script:LastOutput -match 'Machine-wide LG_CONFIG_FILE lists') "expected a warning; output:`n$script:LastOutput"
    Assert-True (-not ((Get-Stored 'User') -match 'vscode-dark-modern')) "User value still lists the theme: $(Get-Stored 'User')"
    Set-Stored 'Machine' ''
    Install-Persisted $b @{ Uninstall = $true }
    Assert-Missing $b.Theme 'theme file once the Machine value no longer lists it'
}

Invoke-Check '(14) persisted: warns when this session has another LG_CONFIG_FILE than the stored one' {
    $b = New-Box 'persist-session'
    $one = New-File (Join-Path $b.Dir 'one.yml') ''
    Reset-Env $one '' ''
    Install-Persisted $b
    Assert-True ($script:LastOutput -match 'This session had LG_CONFIG_FILE') "expected a warning; output:`n$script:LastOutput"
    Assert-Equal "$($b.Theme),$($b.Config)" (Get-Stored 'User') 'User LG_CONFIG_FILE (built from the stored value, not the session)'
    Install-Persisted $b @{ Uninstall = $true }
}

Invoke-Check '(14) -Uninstall -NoPersist after a persisted install keeps the theme file the User value lists' {
    $b = New-Box 'persist-then-nopersist'
    Reset-Env '' '' ''
    Install-Persisted $b
    $value = "$($b.Theme),$($b.Config)"
    Install-Box $b @{ Uninstall = $true }
    Assert-True ($null -eq (Get-TestLg)) "LG_CONFIG_FILE of this process, is: $(Get-TestLg)"
    Assert-Equal $value (Get-Stored 'User') 'User LG_CONFIG_FILE untouched by -NoPersist'
    Assert-True (Test-Path -LiteralPath $b.Theme) 'theme file kept while the User value lists it'
    Assert-True ($script:LastOutput -match 'User environment variable LG_CONFIG_FILE still lists') "expected a warning; output:`n$script:LastOutput"
    Install-Persisted $b @{ Uninstall = $true }
    Assert-Missing $b.Theme 'theme file after a persisted uninstall'
    Assert-True ($null -eq (Get-Stored 'User')) 'User LG_CONFIG_FILE after a persisted uninstall'
}

Invoke-Check '(14) irm | iex: the unmodified script text installs persistently (config dir from lazygit / CONFIG_DIR)' {
    if (-not $script:SeamOk) { Skip-Check 'check (14a) did not confirm the test environment store' }
    $b = New-Box 'persist-iex' -NoCreate
    $env:CONFIG_DIR = $b.Dir
    try {
        $lg = Get-Command -Name 'lazygit' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lg) { Assert-Equal $b.Dir (Get-PrintedConfigDir $lg.Path) 'lazygit --print-config-dir with CONFIG_DIR set (installer not run)' }
        Reset-Env '' '' ''
        $code = Get-Content -LiteralPath $RemoteCopy -Raw
        $ErrorActionPreference = 'Continue'
        $out = @(Invoke-Expression $code *>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $ErrorActionPreference = 'Stop'
        Assert-True ($out.Contains("Test mode: the User/Machine LG_CONFIG_FILE values are kept under $script:EnvKey")) "output:`n$out"
        Assert-Equal "$($b.Theme),$($b.Config)" (Get-Stored 'User') 'User LG_CONFIG_FILE'
        Assert-Equal "$($b.Theme),$($b.Config)" (Get-TestLg) 'LG_CONFIG_FILE of this process'
        Assert-FileText $b.Theme $script:ThemeText 'theme written from the embedded copy'
        $null = & ([scriptblock]::Create($code)) -Uninstall *>&1
        Assert-True ($null -eq (Get-Stored 'User')) 'User LG_CONFIG_FILE after the remote uninstall'
        Assert-Missing $b.Theme 'theme file after the remote uninstall'
    } finally {
        Remove-Item -LiteralPath 'Env:CONFIG_DIR' -ErrorAction SilentlyContinue
    }
}

# ---- config directory when lazygit cannot be asked

Invoke-Check '(15) without lazygit, the config dir is found the way lazygit finds it (XDG_CONFIG_HOME / XDG_CONFIG_DIRS)' {
    # Load Get-DefaultConfigDir and its helper from install.ps1 and compare with real lazygit.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Installer, [ref]$tokens, [ref]$errors)
    $defs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @('Get-DefaultConfigDir', 'ConvertFrom-XdgPath') -contains $n.Name }, $true))
    Assert-Equal 2 $defs.Count 'functions Get-DefaultConfigDir and ConvertFrom-XdgPath in install.ps1'
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }

    $root = Join-Path $script:Sandbox 'xdg'
    $xdgHome = Join-Path $root 'home'
    $dirs1 = Join-Path $root 'dirs1'
    $dirs2 = Join-Path $root 'dirs2'
    foreach ($d in @($xdgHome, $dirs1, $dirs2)) { [void][System.IO.Directory]::CreateDirectory($d) }
    Remove-Item -LiteralPath 'Env:CONFIG_DIR' -ErrorAction SilentlyContinue
    $env:XDG_CONFIG_HOME = $xdgHome
    $env:XDG_CONFIG_DIRS = "$dirs1;$dirs2"
    try {
        $cases = @(
            @{ Make = @();                                                         Expect = Join-Path $xdgHome 'lazygit' },
            @{ Make = @((Join-Path $xdgHome 'jesseduffield\lazygit'));              Expect = Join-Path $xdgHome 'lazygit' },  # legacy dir without config.yml: ignored
            @{ Make = @((Join-Path $dirs2 'lazygit\config.yml'));                   Expect = Join-Path $dirs2 'lazygit' },
            @{ Make = @((Join-Path $xdgHome 'lazygit\config.yml'));                 Expect = Join-Path $xdgHome 'lazygit' },  # XDG_CONFIG_HOME before XDG_CONFIG_DIRS
            @{ Make = @((Join-Path $dirs1 'jesseduffield\lazygit\config.yml'));     Expect = Join-Path $dirs1 'jesseduffield\lazygit' }  # legacy name first
        )
        $n = 0
        foreach ($c in $cases) {
            $n++
            foreach ($m in $c.Make) {
                if ($m.EndsWith('config.yml')) {
                    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $m))
                    [void](New-File $m '')
                } else {
                    [void][System.IO.Directory]::CreateDirectory($m)
                }
            }
            Assert-Equal $c.Expect (Get-DefaultConfigDir) "case ${n}: Get-DefaultConfigDir"
            if ($script:RealLazygit) {
                Assert-Equal $c.Expect (Get-PrintedConfigDir $script:RealLazygit) "case ${n}: lazygit --print-config-dir"
            }
        }

        # End to end, with lazygit hidden from PATH (the state right after `winget install`).
        Remove-Item -LiteralPath (Join-Path $dirs1 'jesseduffield') -Recurse -Force
        Remove-Item -LiteralPath (Join-Path $xdgHome 'lazygit') -Recurse -Force
        $expectDir = Join-Path $dirs2 'lazygit'
        Assert-Equal $expectDir (Get-DefaultConfigDir) 'Get-DefaultConfigDir before the end-to-end run (must be in the sandbox)'
        $pathKept = foreach ($p in $env:PATH.Split(';')) {
            if (-not $p) { continue }
            $hasLazygit = $false
            try { $hasLazygit = @(Get-ChildItem -LiteralPath $p -Filter 'lazygit.*' -ErrorAction Stop).Count -gt 0 } catch { $hasLazygit = $false }
            if (-not $hasLazygit) { $p }
        }
        $env:PATH = @($pathKept) -join ';'
        if (Get-Command -Name 'lazygit' -CommandType Application -ErrorAction SilentlyContinue) { Skip-Check 'could not hide lazygit from PATH' }
        Set-TestLg ''
        Invoke-Script $Installer @{ NoPersist = $true }
        Assert-True ($script:LastOutput -match 'lazygit is not on PATH') "expected a warning; output:`n$script:LastOutput"
        Assert-True ($script:LastOutput.Contains("lazygit config directory: $expectDir (from lazygit's default lookup)")) "output:`n$script:LastOutput"
        $theme = Join-Path $expectDir 'themes\vscode-dark-modern.yml'
        Assert-Equal "$theme,$(Join-Path $expectDir 'config.yml')" (Get-TestLg) 'LG_CONFIG_FILE'
        Assert-FileText $theme $script:ThemeText 'theme file'
        Invoke-Script $Installer @{ NoPersist = $true; Uninstall = $true }
        Assert-Missing $theme 'theme file after uninstall'
    } finally {
        $env:PATH = $SavedEnv['PATH']
        Remove-Item -LiteralPath 'Env:XDG_CONFIG_HOME', 'Env:XDG_CONFIG_DIRS' -ErrorAction SilentlyContinue
    }
}

Invoke-Check '(16) safety: User-scope LG_CONFIG_FILE and the real lazygit config dir are unchanged' {
    Assert-Equal $UserLgBefore ([string][Environment]::GetEnvironmentVariable('LG_CONFIG_FILE', 'User')) 'User-scope LG_CONFIG_FILE'
    Assert-Equal $RealStateBefore (Get-RealState) "real config dir $RealConfigDir"
}

$script:Completed = $true

} catch {
    Write-Host "ERROR outside a check: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      at $($_.InvocationInfo.PositionMessage)"
} finally {
    Set-TestLg $SavedLg
    if ($SavedConfigDir) { $env:CONFIG_DIR = $SavedConfigDir } else { Remove-Item -LiteralPath 'Env:CONFIG_DIR' -ErrorAction SilentlyContinue }
    foreach ($name in @($SavedEnv.Keys)) { [Environment]::SetEnvironmentVariable($name, $SavedEnv[$name], 'Process') }
    try {
        if (Test-Path -LiteralPath $script:EnvKey) { Remove-Item -LiteralPath $script:EnvKey -Recurse -Force }
        $parentKey = 'HKCU:\Software\lgvdm-test'
        if ((Test-Path -LiteralPath $parentKey) -and @(Get-ChildItem -LiteralPath $parentKey).Count -eq 0) {
            Remove-Item -LiteralPath $parentKey -Force
        }
    } catch {
        Write-Host "Could not delete the test registry key $($script:EnvKey): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    $keep = ($env:LGVDM_KEEP_SANDBOX -eq '1') -or ($script:FailCount -gt 0) -or (-not $script:Completed)
    if ($keep) {
        Write-Host "Sandbox kept: $script:Sandbox"
    } else {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $script:Completed) {
        Write-Host 'FAIL  the test run stopped early (unexpected exit or terminating error)' -ForegroundColor Red
        [Environment]::Exit(1)
    }
}

Write-Host ''
Write-Host ("Summary: {0} passed, {1} failed, {2} skipped" -f $script:PassCount, $script:FailCount, $script:SkipCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
