# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-26

### Added

- lazygit theme `themes/vscode-dark-modern.yml` with the colors of VS Code's Dark Modern theme (square `single` borders, focus blue `#0078D4`, list selection colors, git decoration colors).
- `install.ps1` / `uninstall.ps1` for Windows PowerShell 5.1 and PowerShell 7, usable from a clone or as an `irm` one-liner without cloning.
- `install.sh` / `uninstall.sh` for macOS and Linux (POSIX `sh`), usable from a clone or as a `curl | sh` one-liner; under Git Bash they hand over to `install.ps1`.
- Overlay mode (default): installs the theme into `<config dir>/themes/` and puts it first in `LG_CONFIG_FILE`, keeping existing entries (Windows user environment variable; bash, zsh, fish or `~/.profile` startup snippet on macOS/Linux).
- Append mode: writes the theme into `config.yml` as a marked block, with a `config.yml.bak` backup; refuses when `config.yml` already has a top-level `gui:` key.
- Uninstall that reverts both modes and never deletes `config.yml`.
- Windows Terminal color scheme `extras/windows-terminal/vscode-dark-modern.json` and the terminal palette in the README.
- `tools/sync-theme.sh` to keep the theme copies embedded in the installers in sync.
- Installer tests for PowerShell and POSIX `sh`, and GitHub Actions CI on Ubuntu, macOS and Windows.

[Unreleased]: https://github.com/Makihataima-Ken/lazygit-vscode-themes/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Makihataima-Ken/lazygit-vscode-themes/releases/tag/v1.0.0
