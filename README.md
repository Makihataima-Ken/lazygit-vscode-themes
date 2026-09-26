# lazygit VS Code Dark Modern

A [lazygit](https://github.com/jesseduffield/lazygit) theme that uses the colors of VS Code's default **Dark Modern** theme, with installers for Windows, macOS and Linux and a matching terminal color scheme.

- [Requirements](#requirements)
- [Install](#install)
- [What the installer changes](#what-the-installer-changes)
- [Try it without installing](#try-it-without-installing)
- [Manual install](#manual-install)
- [Uninstall](#uninstall)
- [Theme colors](#theme-colors)
- [Terminal colors](#terminal-colors)
- [Optional: delta for VS Code-like diffs](#optional-delta-for-vs-code-like-diffs)
- [Optional: file icons](#optional-file-icons)
- [Customizing](#customizing)
- [Troubleshooting](#troubleshooting)
- [Publishing your own copy](#publishing-your-own-copy)
- [Development](#development)

## Requirements

- A recent lazygit (tested with 0.65.1). The default install mode lists several files in `LG_CONFIG_FILE`, which old releases don't support.
- A terminal with 24-bit ("true color") support. The theme uses hex colors.
- Windows: Windows PowerShell 5.1 or PowerShell 7. macOS/Linux: `sh`, with bash, zsh or fish as your shell (other shells get `~/.profile`).

## Install

### Windows (PowerShell)

From a clone:

```powershell
git clone https://github.com/Makihataima-Ken/lazygit-vscode-themes.git
cd lazygit-vscode-dark-modern
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Without cloning:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.ps1)))
```

Without cloning, with options (here: append mode):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.ps1))) -Mode Append
```

The shorter `irm <url> | iex` also installs, but it runs the script in your session's own scope, so it resets any variables named `$Mode`, `$ConfigDir`, `$Uninstall` or `$NoPersist` you have there. The script block form above runs in a child scope.

### macOS / Linux

From a clone:

```sh
git clone https://github.com/Makihataima-Ken/lazygit-vscode-themes.git
cd lazygit-vscode-dark-modern
sh install.sh
```

Without cloning:

```sh
curl -fsSL https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.sh | sh
```

Without cloning, with options (here: append mode):

```sh
curl -fsSL https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.sh | sh -s -- --mode append
```

### Git Bash on Windows

In a clone, `sh install.sh` hands over to `install.ps1` and translates the options (`--uninstall` to `-Uninstall`, `--mode append` to `-Mode Append`, `--config-dir` to `-ConfigDir`). Piped from `curl` it can't do that, so it prints the PowerShell one-liner and exits.

### After installing

1. Open a **new** terminal and restart lazygit. On Windows, also restart apps that host terminals (VS Code, for example), because they keep the environment they were started with.
2. Set your terminal colors, see [Terminal colors](#terminal-colors).

### Options

| PowerShell (`install.ps1`) | sh (`install.sh`) | Effect |
|---|---|---|
| `-Mode Overlay` (default) | `--mode overlay` (default) | Install the theme file and point `LG_CONFIG_FILE` at it |
| `-Mode Append` | `--mode append` | Write the theme into `config.yml` instead |
| `-ConfigDir <dir>` | `--config-dir <dir>` | Use this lazygit config directory |
| `-Uninstall` | `--uninstall` | Undo either mode |
| `-NoPersist` | | Change `LG_CONFIG_FILE` only in the current PowerShell session |
| | `--shell auto\|bash\|zsh\|fish\|all\|none` | Which shell startup files to edit (default `auto`) |
| | `-h`, `--help` | Show usage |

## What the installer changes

The installer works in lazygit's config directory. It asks lazygit for it (`lazygit --print-config-dir`, short `lazygit -cd`), so legacy locations and `CONFIG_DIR` are handled the way lazygit handles them. If lazygit isn't on `PATH` (for example in the terminal you installed it from), the installer warns and falls back to `$CONFIG_DIR`. On Windows it then looks for an existing `config.yml` where lazygit would (`jesseduffield\lazygit` and `lazygit` under `%XDG_CONFIG_HOME%` or `%LOCALAPPDATA%`, then under each `%XDG_CONFIG_DIRS%` entry or `%ProgramData%` and `%APPDATA%`). Otherwise it uses the default:

| OS | Default config directory |
|---|---|
| Windows | `%LOCALAPPDATA%\lazygit` (`%XDG_CONFIG_HOME%\lazygit` if `XDG_CONFIG_HOME` is set) |
| macOS | `~/Library/Application Support/lazygit` (`$XDG_CONFIG_HOME/lazygit` if `XDG_CONFIG_HOME` is set) |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/lazygit` |

`-ConfigDir` / `--config-dir` overrides all of this. The installer prints the directory it uses, so you can compare it with what `lazygit -cd` shows.

### Overlay mode (default)

1. Copies the theme to `<config dir>/themes/vscode-dark-modern.yml`. An existing copy is overwritten, so re-running the installer upgrades the theme.
2. Creates an empty `<config dir>/config.yml` if you don't have one. An existing `config.yml` is never modified.
3. Sets `LG_CONFIG_FILE` to the theme first, then your config:

   ```text
   <config dir>/themes/vscode-dark-modern.yml,<config dir>/config.yml
   ```

   If `LG_CONFIG_FILE` already lists files, they stay, after the theme, instead of `config.yml`. Running the installer again doesn't add duplicates.

   - **Windows:** sets the user environment variable (`HKCU\Environment`). When the installer runs inside your PowerShell session (`.\install.ps1` or the one-liners), it also updates that session; `powershell -File .\install.ps1` runs in a separate process, so only new terminals see the change. If only a machine-wide `LG_CONFIG_FILE` exists, its entries are the starting list. With `-NoPersist`, only the PowerShell session the installer runs in changes (so use `.\install.ps1 -NoPersist`).
   - **macOS/Linux:** adds a block between `# >>> lazygit-vscode-dark-modern >>>` and `# <<< lazygit-vscode-dark-modern <<<` to your shell startup file. At shell startup, the block puts the theme at the front of `LG_CONFIG_FILE`, followed by `config.yml` (if it exists) or by whatever `LG_CONFIG_FILE` already contained. It does nothing if the theme is already listed or the theme file is gone.

     | Shell | File |
     |---|---|
     | bash on Linux | `~/.bashrc` |
     | bash on macOS | `~/.bash_profile` (or an existing `~/.bash_login` or `~/.profile` when bash reads that one instead) |
     | zsh | `~/.zshenv`, plus `$ZDOTDIR/.zshenv` if `ZDOTDIR` is set (a new terminal reads `~/.zshenv`; a zsh started with `ZDOTDIR` already set reads `$ZDOTDIR/.zshenv`) |
     | fish | `${XDG_CONFIG_HOME:-~/.config}/fish/conf.d/lazygit-vscode-dark-modern.fish` (a separate file) |
     | anything else | `~/.profile` |

     `--shell auto` (default) picks by the name of `$SHELL`. `--shell all` sets up bash, zsh and fish. `--shell none` edits nothing and prints what to add yourself.

     The block runs early: zsh reads `.zshenv` before `.zprofile` and `.zshrc`, and fish reads `conf.d` before `config.fish`. If a startup file that runs after the block sets `LG_CONFIG_FILE` itself (for example `export LG_CONFIG_FILE=...` in `.zshrc`, in `.zprofile`, or in `~/.bash_profile` or `~/.profile` after they source `~/.bashrc`, or `set -gx LG_CONFIG_FILE ...` in `config.fish`), it replaces the whole list and the theme is gone. The installer looks for such lines and warns about each one it finds. Put the theme path (`<config dir>/themes/vscode-dark-modern.yml`) at the front of that assignment yourself, or (bash, zsh) move the assignment into the file that holds the block, above the block.

**Why the theme comes first.** lazygit reads the files in `LG_CONFIG_FILE` in order, and later files override earlier ones key by key. With the theme first:

- Anything in your `config.yml` wins, including colors under `gui.theme`, so `config.yml` is where you customize.
- It avoids a lazygit bug: when a later file has no `customCommands` key, the `customCommands` from earlier files are loaded twice. The theme has no custom commands and your `config.yml` comes last, so nothing is duplicated.

The installer warns if your `config.yml` already has a `gui.theme` block, because those keys override the theme.

### Append mode (`-Mode Append` / `--mode append`)

Use this when lazygit is started where your shell environment doesn't reach, for example from an IDE or a desktop launcher on macOS/Linux. Instead of setting `LG_CONFIG_FILE`, it writes the theme into `config.yml`:

- The theme is appended to `config.yml` between the same two marker lines.
- If `config.yml` already has a top-level `gui:` key, the installer refuses and changes nothing, because YAML doesn't allow a second `gui:` key. Use overlay mode, or paste the theme's `theme:` block under your existing `gui:` key (see [Manual install](#manual-install)).
- Running it again replaces the block in place.
- Before changing an existing `config.yml`, it saves a backup as `config.yml.bak`. Everything outside the block stays byte-for-byte the same.
- It doesn't touch `LG_CONFIG_FILE` and doesn't install the theme file.

Because the block owns the only `gui:` key, any other `gui` settings you want later would have to go inside the block. Re-running the installer (to update the theme, for example) replaces the whole block, so anything you added inside it disappears from `config.yml`. On macOS/Linux the installer notices changes inside the block and also keeps the previous `config.yml` as `config.yml.bak-<date>`, which later runs don't overwrite. On Windows your edits survive only in `config.yml.bak`, which the next run overwrites. If you want other `gui` settings, use overlay mode or a manual install instead.

## Try it without installing

From a clone (a git repository itself, so lazygit opens on it):

```sh
# bash / zsh
lazygit --use-config-file "$PWD/themes/vscode-dark-modern.yml,$(lazygit -cd)/config.yml"
```

```powershell
# PowerShell
lazygit --use-config-file "$PWD\themes\vscode-dark-modern.yml,$(lazygit -cd)\config.yml"
```

- Use absolute paths separated by a comma with no spaces. lazygit doesn't expand `~` or variables inside the list.
- Every listed file must exist. If you don't have a `config.yml` yet, list only the theme.
- In Git Bash, use `$(pwd -W)` instead of `$PWD`. Git Bash doesn't convert a comma-separated list of `/c/...` paths for `lazygit.exe`.

In PowerShell you can also install for the current session only. This copies the theme file (and creates `config.yml` if missing) but sets `LG_CONFIG_FILE` only in this window:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\install.ps1 -NoPersist
# undo: .\install.ps1 -Uninstall -NoPersist
```

## Manual install

Copy the theme into your `config.yml`, in the directory printed by `lazygit -cd`. If `config.yml` already has a `gui:` key, put `border` and `theme` under that key. Never add a second `gui:` key: lazygit refuses to start with `mapping key "gui" already defined`.

```yaml
gui:
  border: single
  theme:
    activeBorderColor:
      - '#0078D4'
      - bold
    inactiveBorderColor:
      - '#868686'
    searchingActiveBorderColor:
      - '#CCA700'
      - bold
    optionsTextColor:
      - '#4DAAFC'
    selectedLineBgColor:
      - '#04395E'
    inactiveViewSelectedLineBgColor:
      - '#37373D'
    cherryPickedCommitFgColor:
      - '#FFFFFF'
    cherryPickedCommitBgColor:
      - '#0078D4'
    markedBaseCommitFgColor:
      - '#FFFFFF'
    markedBaseCommitBgColor:
      - '#9E6A03'
    unstagedChangesColor:
      - '#E2C08D'
    defaultFgColor:
      - '#CCCCCC'
```

Keep the quotes around the hex values: an unquoted `- #0078D4` is a YAML comment.

## Uninstall

Windows:

```powershell
# from a clone (same as: .\install.ps1 -Uninstall)
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1

# without a clone
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.ps1))) -Uninstall
```

macOS / Linux:

```sh
# from a clone (same as: sh install.sh --uninstall)
sh uninstall.sh

# without a clone
curl -fsSL https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.sh | sh -s -- --uninstall
```

If you installed with `-ConfigDir` / `--config-dir`, pass the same option to uninstall. Uninstalling undoes both modes, whichever you used:

- Removes `<config dir>/themes/vscode-dark-modern.yml`, and the `themes` directory if it's then empty.
- Removes the marked block from `config.yml` if there is one, after saving `config.yml.bak`. `config.yml` itself is never deleted or emptied.
- Windows: removes the theme from `LG_CONFIG_FILE` (user variable, or only the current session with `-NoPersist`). If nothing is left, or only your `config.yml`, it deletes the variable. Other entries are kept.
- macOS/Linux: removes the marked blocks from the shell startup files (`~/.bashrc`, `~/.bash_profile`, `~/.bash_login`, `~/.profile`, and `.zshenv` and `.zshrc` in `~`, `$ZDOTDIR` and `~/.config/zsh`, whichever exist) and deletes the fish file.

Terminals that were already open keep the old `LG_CONFIG_FILE`, and lazygit started from them refuses to start because the theme file is gone. Open a new terminal. On macOS/Linux, the uninstaller prints the command that fixes the current shell.

## Theme colors

All values come from VS Code's Dark Modern theme or the defaults it inherits. `border: single` gives the square corners of VS Code's panels.

| lazygit key (`gui.theme.`) | Value | VS Code color | What it colors in lazygit |
|---|---|---|---|
| `activeBorderColor` | `#0078D4`, bold | `focusBorder` | Frame and title of the focused panel, and the selected tab label |
| `inactiveBorderColor` | `#868686` | `activityBar.inactiveForeground` | Frames and titles of unfocused panels |
| `searchingActiveBorderColor` | `#CCA700`, bold | `editorWarning.foreground` | Frame of the focused panel while searching or filtering |
| `optionsTextColor` | `#4DAAFC` | `textLink.foreground` | Keybinding hints in the bottom bar |
| `selectedLineBgColor` | `#04395E` | `list.activeSelectionBackground` | Selected line in the focused panel |
| `inactiveViewSelectedLineBgColor` | `#37373D` | `list.inactiveSelectionBackground` | Selected line in a panel that is visible but not focused (under a popup, or while the terminal window is unfocused) |
| `cherryPickedCommitFgColor` | `#FFFFFF` | `button.foreground` | Text of the hash cell of commits copied for cherry-pick |
| `cherryPickedCommitBgColor` | `#0078D4` | `button.background` | Background of that hash cell |
| `markedBaseCommitFgColor` | `#FFFFFF` | `button.foreground` | No visible effect in lazygit 0.65 (kept for other versions) |
| `markedBaseCommitBgColor` | `#9E6A03` | `editor.findMatchBackground` | No visible effect in lazygit 0.65 (kept for other versions) |
| `unstagedChangesColor` | `#E2C08D` | `gitDecoration.modifiedResourceForeground` | Unstaged and untracked (`??`) status letters in the Files panel, and the `D` of deleted files in a commit's file list |
| `defaultFgColor` | `#CCCCCC` | `foreground` | Default text everywhere |

**What the theme can't change.** lazygit's theme settings cover the interface only. Other colors are hard-coded ANSI colors in lazygit or come from git, so your terminal's 16-color palette decides how they look:

- staged file names (green) and partially staged files (yellow) in the Files panel
- commit hash colors in the Commits panel (by pushed, unpushed and merged status)
- the `+` and `-` lines in the staging view
- diffs, which are git's own colored output (or delta's, see below)

lazygit also can't paint the background: you see your terminal's. That's why the [terminal colors](#terminal-colors) matter.

## Terminal colors

If you run lazygit in VS Code's integrated terminal with Dark Modern, the colors already match.

**Windows Terminal:** open Settings, then "Open JSON file". Paste the object from [`extras/windows-terminal/vscode-dark-modern.json`](extras/windows-terminal/vscode-dark-modern.json) into the `schemes` list:

```jsonc
"schemes": [
    {
        "name": "VS Code Dark Modern",
        "background": "#181818",
        // ... rest of extras/windows-terminal/vscode-dark-modern.json
    }
],
```

Then set `"colorScheme": "VS Code Dark Modern"` in `profiles.defaults` (all profiles) or in one profile. In the Settings UI this is the profile's Appearance > Color scheme.

**Other terminals:** use these values.

| Setting | Value | VS Code source |
|---|---|---|
| Background | `#181818` | `panel.background` (the panel terminal; a terminal in the editor area uses `editor.background` `#1F1F1F`) |
| Foreground | `#CCCCCC` | `terminal.foreground` |
| Cursor | `#CCCCCC` | `terminal.foreground` (the cursor default) |
| Selection | `#264F78` | `editor.selectionBackground` (the `terminal.selectionBackground` default) |

| ANSI | Color | Normal | Bright |
|---|---|---|---|
| 0 / 8 | black | `#000000` | `#666666` |
| 1 / 9 | red | `#CD3131` | `#F14C4C` |
| 2 / 10 | green | `#0DBC79` | `#23D18B` |
| 3 / 11 | yellow | `#E5E510` | `#F5F543` |
| 4 / 12 | blue | `#2472C8` | `#3B8EEA` |
| 5 / 13 | magenta (purple) | `#BC3FBC` | `#D670D6` |
| 6 / 14 | cyan | `#11A8CD` | `#29B8DB` |
| 7 / 15 | white | `#E5E5E5` | `#E5E5E5` |

These are VS Code's `terminal.ansi*` defaults, which Dark Modern doesn't override.

## Optional: delta for VS Code-like diffs

Not installed by the theme. Install [delta](https://github.com/dandavison/delta) first, then add this to your `config.yml` (under your existing `git:` key if you have one):

```yaml
git:
  diffRenderers:
    - command: 'delta --dark --paging=never --syntax-theme="Visual Studio Dark+" --plus-style="syntax #383E2A" --minus-style="syntax #4C1919" --plus-emph-style="syntax #4C5A2A" --minus-emph-style="syntax #701414"'
```

- Keep the single quotes around the whole command. Unquoted, YAML treats ` #383E2A` and everything after it as a comment.
- The backgrounds are VS Code's diff colors (`diffEditor.insertedLineBackground`, `diffEditor.removedLineBackground`, `diffEditor.insertedTextBackground`, `diffEditor.removedTextBackground`). Those have transparency, so they are pre-blended over `#1F1F1F`. The word highlights are blended over the line color.
- delta 0.19.x ships the "Visual Studio Dark+" syntax theme, but bat plans to remove it. Check `delta --list-syntax-themes` and pick another theme if it's missing.
- lazygit 0.65 uses `git.diffRenderers` (not `git.paging` or `git.pagers` from older releases). If you list several renderers, `|` cycles through them.

## Optional: file icons

Not set by the theme. With a [Nerd Font](https://www.nerdfonts.com/) in your terminal, add to `config.yml` (under your existing `gui:` key if you have one):

```yaml
gui:
  nerdFontsVersion: "3"
```

## Customizing

In overlay mode, put your changes in your own `config.yml`. It is loaded after the theme, so its keys win. Only the keys you set change; for example, to use a different selection color:

```yaml
gui:
  theme:
    selectedLineBgColor:
      - '#264F78'
```

Don't edit the installed copy in `<config dir>/themes/`: re-running the installer overwrites it.

lazygit re-reads its config files when the terminal window regains focus. A change to `LG_CONFIG_FILE` itself needs a restart of lazygit (and a new terminal).

## Troubleshooting

- **lazygit refuses to start with `GetFileAttributesEx <path>: The system cannot find the file specified.`** (or `... the path specified.` when the file's directory is gone too, as after an uninstall; a `no such file or directory` error on macOS/Linux): a file listed in `LG_CONFIG_FILE` was deleted or moved. If it's the theme or `config.yml`, run the installer again (it restores the theme and creates `config.yml` if missing) or uninstall. A terminal opened before an uninstall still has the old value; open a new one.
- **The theme isn't applied.** Open a new terminal and restart lazygit. Check that the theme path is in the list: `echo $env:LG_CONFIG_FILE` (PowerShell) or `echo $LG_CONFIG_FILE` (sh). Check that your `config.yml` doesn't set its own `gui.theme` colors. On macOS/Linux, check that no startup file sets `LG_CONFIG_FILE` after the block (see [Overlay mode](#overlay-mode-default)).
- **lazygit started from an IDE or a desktop launcher (macOS/Linux) has no theme.** It doesn't read your shell startup files, so it never sees `LG_CONFIG_FILE`. Use `--mode append`.
- **tmux** gives new panes the environment the tmux server started with. After uninstalling, run `tmux set-environment -gu LG_CONFIG_FILE` or restart the tmux server.
- **LazyVim / snacks.nvim** generates its own lazygit theme from your Neovim colorscheme and adds it to `LG_CONFIG_FILE`, overriding this one. Set `lazygit = { configure = false }` in the snacks.nvim options (this also turns off snacks' editor integration for lazygit).
- **Per-repository config** (`.git/lazygit.yml`, or `.lazygit.yml` in a parent directory of the repository) is loaded on top and can override the theme.
- **`--use-config-file` / `-ucf`** (for example in an alias or a wrapper script) replaces `LG_CONFIG_FILE`. Put the theme path first in that list.
- **Editing the config from inside lazygit** (`Alt+Shift+C` by default in 0.65) offers both files. Edit `config.yml`, not the theme.

## Publishing your own copy

1. The GitHub URLs in all files use an upper-case placeholder where the owner goes. Replace it with your user or organization, then regenerate the theme copies embedded in the installers (the theme header contains the repository URL). The `[E]` in the pattern keeps these instructions from rewriting themselves:

   ```sh
   grep -rlI --exclude-dir=.git 'OWN[E]R' . | xargs perl -pi -e 's/OWN[E]R/your-name/g'
   sh tools/sync-theme.sh
   ```

2. Optionally, add a screenshot as `docs/screenshot.png` and show it below the first paragraph of this README with `![lazygit with the VS Code Dark Modern theme](docs/screenshot.png)`.

3. Create an empty repository named `lazygit-vscode-dark-modern` on GitHub, then push:

   ```sh
   git init -b main
   git add .
   git add --chmod=+x install.sh uninstall.sh tools/sync-theme.sh tests/test-install.sh
   git commit -m "Initial release"
   git remote add origin https://github.com/your-name/lazygit-vscode-dark-modern.git
   git push -u origin main
   ```

4. Tag the release:

   ```sh
   git tag v1.0.0 && git push --tags
   ```

   To pin the one-liners to that release, replace `/main/` in their URLs with `/v1.0.0/`.

## Development

- `themes/vscode-dark-modern.yml` is the source of truth. `install.ps1` and `install.sh` each embed a copy for the one-liners. After editing the theme, run `sh tools/sync-theme.sh`. CI runs `sh tools/sync-theme.sh --check`.
- Tests:

  ```sh
  powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-install.ps1
  sh tests/test-install.sh
  ```

  They work in temporary directories, not in your real config. If lazygit is on `PATH`, they also check that lazygit accepts the resulting config; otherwise that check is skipped.
- In Git Bash, `LGVDM_FORCE_POSIX=1` makes `install.sh` skip the hand-off to PowerShell. It exists for testing only.
- CI (`.github/workflows/ci.yml`) runs shellcheck, PSScriptAnalyzer, the sync check, and the tests on Ubuntu, macOS and Windows (Windows PowerShell 5.1, PowerShell 7 and Git Bash).
- Text files use LF line endings (`.gitattributes`, `.editorconfig`).

## Credits and license

Colors are taken from [microsoft/vscode](https://github.com/microsoft/vscode) (MIT License, Copyright (c) Microsoft Corporation): `extensions/theme-defaults/themes/dark_modern.json`, `extensions/git/package.json`, `src/vs/platform/theme/common/colors/listColors.ts` and `src/vs/workbench/contrib/terminal/common/terminalColorRegistry.ts`.

This project is released under the [MIT License](LICENSE).
