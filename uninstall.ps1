# uninstall.ps1 - remove the VS Code "Dark Modern" lazygit theme (Windows)
# https://github.com/Makihataima-Ken/lazygit-vscode-themes
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 [-ConfigDir DIR] [-NoPersist]
#
# Same as `install.ps1 -Uninstall`: undoes both install modes (overlay and append) and never
# deletes config.yml. -Mode is accepted for symmetry with install.ps1 and ignored.
# Without install.ps1 next to it (e.g. `irm .../uninstall.ps1 | iex`), it runs the published
# install.ps1 from GitHub with -Uninstall. After a -NoPersist install, run it in that same
# session (& '...\uninstall.ps1' -NoPersist), not with `powershell -File`: -NoPersist changes
# only the process it runs in. This script never calls `exit`.

param(
    [ValidateSet('Overlay', 'Append')]
    [string]$Mode = 'Overlay',
    [string]$ConfigDir,
    [switch]$NoPersist
)

function Uninstall-LazygitVSCodeDarkModern {
    param(
        [string]$ConfigDir,
        [switch]$NoPersist
    )

    Set-StrictMode -Version 2.0
    $ErrorActionPreference = 'Stop'

    $installer = ''
    if ($PSScriptRoot) { $installer = [System.IO.Path]::Combine($PSScriptRoot, 'install.ps1') }
    if ($installer -and (Test-Path -LiteralPath $installer -PathType Leaf)) {
        & $installer -Uninstall -ConfigDir $ConfigDir -NoPersist:$NoPersist
        return
    }

    $url = 'https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.ps1'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    Write-Host "[lazygit-vscode-dark-modern] install.ps1 is not next to this script; running $url -Uninstall"
    $code = Invoke-RestMethod -Uri $url -UseBasicParsing
    & ([scriptblock]::Create([string]$code)) -Uninstall -ConfigDir $ConfigDir -NoPersist:$NoPersist
}

try {
    Uninstall-LazygitVSCodeDarkModern -ConfigDir $ConfigDir -NoPersist:$NoPersist
} finally {
    Remove-Item -LiteralPath 'Function:\Uninstall-LazygitVSCodeDarkModern' -ErrorAction SilentlyContinue
}
