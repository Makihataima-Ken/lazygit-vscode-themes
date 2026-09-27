#!/bin/sh
# lazygit-vscode-themes installer for macOS and Linux (POSIX sh).
#
#   curl -fsSL https://raw.githubusercontent.com/Makihataima-Ken/lazygit-vscode-themes/main/install.sh | sh
#   sh install.sh                    # from a clone (default: overlay mode)
#   sh install.sh --theme vscode-light-modern
#   sh install.sh --list-themes
#   sh install.sh --mode append      # write the theme into config.yml instead
#   sh install.sh --uninstall        # undo either mode
#   sh install.sh --help
#
# Overlay mode (default) copies the theme to
#   <lazygit config dir>/themes/<catalog theme>.yml
# and adds a marker-delimited block to your shell startup file that puts the
# theme FIRST in LG_CONFIG_FILE. Your config.yml is loaded after the theme, so
# your own settings still win. Nothing outside the marker block is touched.
#
# On Windows use install.ps1; from Git Bash this script hands over to it.
#
# All work happens in main(), called on the last line, so a truncated
# download (curl | sh) never runs a partial script.

set -eu

LGVDM_NAME='lazygit-vscode-themes'
LGVDM_DEFAULT_THEME_ID='vscode-dark-modern'
LGVDM_THEME_ID=''
LGVDM_REPO_URL='https://github.com/Makihataima-Ken/lazygit-vscode-themes'
LGVDM_RAW_URL='https://raw.githubusercontent.com/Makihataima-Ken/lazygit-vscode-themes/main'
LGVDM_BEGIN='# >>> lazygit-vscode-dark-modern >>>'
LGVDM_END='# <<< lazygit-vscode-dark-modern <<<'
# Flag lines inside a block. They let --uninstall restore the file exactly.
LGVDM_FLAG_CREATED='# lgvdm: this file was created by the installer (uninstall deletes it if nothing else is left)'
LGVDM_FLAG_NEWLINE='# lgvdm: the installer added a line break before this block (uninstall removes it)'
# The config.yml block records a checksum of the theme it holds, so a re-run
# can tell a theme update from your own edits inside the block.
LGVDM_SUM_PREFIX='# lgvdm: theme checksum '
# A top-level gui: key, also written as "gui": or 'gui': (awk regex).
LGVDM_GUI_RE='^(gui|"gui"|'"'"'gui'"'"')[ \t]*:'

# ---------------------------------------------------------------------------
# messages

say() { printf '[%s] %s\n' "$LGVDM_NAME" "$*"; }
detail() { printf '    %s\n' "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$LGVDM_NAME" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$LGVDM_NAME" "$*" >&2; exit 1; }

usage_error() {
  printf '[%s] ERROR: %s\n' "$LGVDM_NAME" "$1" >&2
  printf 'Run "sh install.sh --help" for usage.\n' >&2
  exit 2
}

# note TEXT: remember one line for the "what changed" summary.
note() {
  LGVDM_CHANGES="${LGVDM_CHANGES}  - $*
"
}

usage() {
  cat <<'EOF'
Usage: sh install.sh [options]
       curl -fsSL https://raw.githubusercontent.com/Makihataima-Ken/lazygit-vscode-themes/main/install.sh | sh -s -- [options]

Installs a VS Code-inspired theme for lazygit.

Options:
  --theme ID         Select a catalog theme (default: vscode-dark-modern).
  --list-themes      Print available themes and make no changes.
  --mode overlay     (default) Copy the theme to <config dir>/themes/ and load it
                     through LG_CONFIG_FILE, set by a block in your shell startup
                     file. Your config.yml is loaded after the theme and wins.
  --mode append      Append the theme to <config dir>/config.yml between marker
                     comments instead. For lazygit started from GUI/IDE launchers
                     that do not see shell variables. Refuses (changes nothing)
                     if config.yml already has a top-level "gui:" key.
  --config-dir DIR   lazygit config directory
                     (default: output of "lazygit --print-config-dir").
  --shell NAME       Startup file(s) to edit in overlay mode:
                       auto (default, from $SHELL): bash, zsh or fish;
                            any other shell uses ~/.profile
                       bash  ~/.bashrc (macOS: ~/.bash_profile)
                       zsh   ~/.zshenv, and $ZDOTDIR/.zshenv if ZDOTDIR is set
                       fish  ~/.config/fish/conf.d/lazygit-vscode-themes.fish
                       all   bash + zsh + fish
                       none  edit nothing; print what to add yourself
  --uninstall        Undo both modes: remove the theme file, the config.yml
                     block and all shell blocks. config.yml is never deleted.
  -h, --help         Show this help.
EOF
}

# ---------------------------------------------------------------------------
# small helpers

# sq TEXT: escape TEXT for use inside '...' in sh.
sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

# fish_sq TEXT: escape TEXT for use inside '...' in fish.
fish_sq() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g"; }

# ps_sq TEXT: escape TEXT for use inside '...' in PowerShell.
ps_sq() { printf '%s' "$1" | sed "s/'/''/g"; }

# same_content A B: true if both files exist and have identical bytes.
same_content() {
  if [ ! -f "$1" ] || [ ! -f "$2" ]; then
    return 1
  fi
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  else
    [ "$(cat "$1"; printf x)" = "$(cat "$2"; printf x)" ]
  fi
}

# ends_without_newline FILE: true if FILE is non-empty and its last byte is not LF.
ends_without_newline() {
  [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]
}

# abs_path PATH: print PATH as an absolute path without trailing slashes
# (a leading ~/ is expanded, e.g. from --config-dir=~/x).
abs_path() {
  # shellcheck disable=SC2088 # '~' is matched literally on purpose
  case $1 in
    /*) _ap_path=$1 ;;
    '~') _ap_path=$HOME ;;
    '~/'*) _ap_path=$HOME/${1#??} ;;
    *) _ap_path=$(pwd)/$1 ;;
  esac
  if [ -d "$_ap_path" ]; then
    _ap_path=$(CDPATH='' cd -- "$_ap_path" && pwd)
  fi
  while :; do
    case $_ap_path in
      /) break ;;
      */) _ap_path=${_ap_path%/} ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$_ap_path"
}

# normalize_text: stdin -> stdout with LF endings, no UTF-8 BOM, no trailing
# blank lines and exactly one final newline.
normalize_text() {
  LC_ALL=C awk '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    $0 == "" { blank++; next }
    { while (blank > 0) { print ""; blank-- } print }'
}

setup_tmp() {
  LGVDM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/lgvdm.XXXXXX" 2>/dev/null) || LGVDM_TMP=''
  if [ -z "$LGVDM_TMP" ]; then
    LGVDM_TMP="${TMPDIR:-/tmp}/lgvdm.$$"
    (umask 077 && mkdir "$LGVDM_TMP") || die "cannot create a temporary directory"
  fi
  trap 'rm -rf "$LGVDM_TMP"' EXIT
  trap 'exit 130' HUP INT TERM
}

detect_script_dir() {
  SCRIPT_DIR=''
  SCRIPT_PATH=''
  # curl | sh: $0 is the shell ("sh"), not a file next to a themes/ folder.
  if [ -f "$0" ]; then
    case $0 in
      */*) _sd_dir=${0%/*} ;;
      *) _sd_dir=. ;;
    esac
    if [ -z "$_sd_dir" ]; then
      _sd_dir=/
    fi
    SCRIPT_DIR=$(CDPATH='' cd -- "$_sd_dir" 2>/dev/null && pwd) || SCRIPT_DIR=''
    if [ -n "$SCRIPT_DIR" ]; then
      SCRIPT_PATH=$SCRIPT_DIR/${0##*/}
    fi
  fi
}

# ---------------------------------------------------------------------------
# arguments

parse_args() {
  OPT_UNINSTALL=0
  OPT_MODE=overlay
  OPT_CONFIG_DIR=''
  OPT_CONFIG_DIR_SET=0
  OPT_SHELL=auto
  OPT_THEME=$LGVDM_DEFAULT_THEME_ID
  OPT_LIST=0
  while [ $# -gt 0 ]; do
    case $1 in
      --uninstall) OPT_UNINSTALL=1 ;;
      --mode)
        [ $# -ge 2 ] || usage_error "--mode needs a value (overlay or append)"
        OPT_MODE=$2
        shift
        ;;
      --mode=*) OPT_MODE=${1#*=} ;;
      --theme)
        [ $# -ge 2 ] || usage_error "--theme needs a theme ID"
        OPT_THEME=$2
        shift
        ;;
      --theme=*) OPT_THEME=${1#*=} ;;
      --list-themes) OPT_LIST=1 ;;
      --config-dir)
        [ $# -ge 2 ] || usage_error "--config-dir needs a directory"
        OPT_CONFIG_DIR=$2
        OPT_CONFIG_DIR_SET=1
        shift
        ;;
      --config-dir=*)
        OPT_CONFIG_DIR=${1#*=}
        OPT_CONFIG_DIR_SET=1
        ;;
      --shell)
        [ $# -ge 2 ] || usage_error "--shell needs a value"
        OPT_SHELL=$2
        shift
        ;;
      --shell=*) OPT_SHELL=${1#*=} ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_error "unknown option: $1" ;;
    esac
    shift
  done
  case $OPT_MODE in
    overlay | Overlay) OPT_MODE=overlay ;;
    append | Append) OPT_MODE=append ;;
    *) usage_error "--mode must be overlay or append, not '$OPT_MODE'" ;;
  esac
  case $OPT_SHELL in
    auto | bash | zsh | fish | all | none) ;;
    *) usage_error "--shell must be auto, bash, zsh, fish, all or none, not '$OPT_SHELL'" ;;
  esac
  if [ "$OPT_CONFIG_DIR_SET" = 1 ] && [ -z "$OPT_CONFIG_DIR" ]; then
    usage_error "--config-dir needs a non-empty directory"
  fi
  if [ "$OPT_LIST" = 1 ] && { [ "$OPT_UNINSTALL" = 1 ] || [ "$OPT_MODE" = append ]; }; then
    usage_error "--list-themes cannot be combined with --uninstall or --mode append"
  fi
}

# ---------------------------------------------------------------------------
# Windows (Git Bash / MSYS / Cygwin): hand over to install.ps1

to_windows_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s\n' "$1"
  fi
}

delegate_to_windows() {
  _dw_ps1=''
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install.ps1" ]; then
    _dw_ps1=$SCRIPT_DIR/install.ps1
  fi
  _dw_dir_win=''
  if [ -n "$OPT_CONFIG_DIR" ]; then
    _dw_dir_win=$(to_windows_path "$(abs_path "$OPT_CONFIG_DIR")")
  fi
  if [ -z "$_dw_ps1" ]; then
    _dw_args=''
    if [ "$OPT_LIST" = 1 ]; then
      _dw_args=' -ListThemes'
    elif [ "$OPT_UNINSTALL" = 1 ]; then
      _dw_args=' -Uninstall'
    elif [ "$OPT_MODE" = append ]; then
      _dw_args=' -Mode Append'
    fi
    if [ "$OPT_THEME" != "$LGVDM_DEFAULT_THEME_ID" ]; then
      _dw_args="$_dw_args -Theme '$(ps_sq "$OPT_THEME")'"
    fi
    if [ -n "$_dw_dir_win" ]; then
      _dw_args="$_dw_args -ConfigDir '$(ps_sq "$_dw_dir_win")'"
    fi
    say "This is Windows ($OS_NAME). Run the PowerShell installer instead, in PowerShell:"
    if [ -z "$_dw_args" ]; then
      printf '    irm %s/install.ps1 | iex\n' "$LGVDM_RAW_URL"
    else
      printf '    & ([scriptblock]::Create((irm %s/install.ps1)))%s\n' "$LGVDM_RAW_URL" "$_dw_args"
    fi
    exit 1
  fi
  command -v powershell.exe >/dev/null 2>&1 ||
    die "powershell.exe not found; run $(to_windows_path "$_dw_ps1") from PowerShell"
  _dw_ps1_win=$(to_windows_path "$_dw_ps1")
  set --
  if [ "$OPT_LIST" = 1 ]; then
    set -- "$@" -ListThemes
  fi
  if [ "$OPT_UNINSTALL" = 1 ]; then
    set -- "$@" -Uninstall
  fi
  if [ "$OPT_MODE" = append ]; then
    set -- "$@" -Mode Append
  fi
  if [ -n "$_dw_dir_win" ]; then
    set -- "$@" -ConfigDir "$_dw_dir_win"
  fi
  if [ "$OPT_THEME" != "$LGVDM_DEFAULT_THEME_ID" ]; then
    set -- "$@" -Theme "$OPT_THEME"
  fi
  if [ "$OPT_SHELL" != auto ]; then
    say "Note: --shell is ignored on Windows (LG_CONFIG_FILE is a user environment variable there)."
  fi
  say "Windows detected ($OS_NAME): running install.ps1 with Windows PowerShell."
  exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$_dw_ps1_win" "$@"
}

# ---------------------------------------------------------------------------
# paths

resolve_config_dir() {
  _rc_dir=''
  if [ -n "$OPT_CONFIG_DIR" ]; then
    _rc_dir=$OPT_CONFIG_DIR
  else
    if command -v lazygit >/dev/null 2>&1; then
      _rc_dir=$(lazygit --print-config-dir </dev/null 2>/dev/null |
        awk 'NR == 1 { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }') || _rc_dir=''
    fi
    if [ -z "$_rc_dir" ] && [ -n "${CONFIG_DIR:-}" ]; then
      _rc_dir=$CONFIG_DIR
    fi
    if [ -z "$_rc_dir" ]; then
      if [ "$OS_NAME" = Darwin ] && [ -z "${XDG_CONFIG_HOME:-}" ]; then
        _rc_dir="$HOME/Library/Application Support/lazygit"
      else
        _rc_dir="${XDG_CONFIG_HOME:-$HOME/.config}/lazygit"
      fi
    fi
  fi
  case $_rc_dir in
    *'
'*) die "the config directory path contains a line break: $_rc_dir" ;;
  esac
  CONFIG_DIR_ABS=$(abs_path "$_rc_dir")
  CONFIG_FILE=$CONFIG_DIR_ABS/config.yml
  THEMES_DIR=$CONFIG_DIR_ABS/themes
  THEME_DEST=$THEMES_DIR/$LGVDM_THEME_ID.yml
  MANAGED_FILE=$THEMES_DIR/.lazygit-vscode-themes-managed
  OWNED_THEME_LIST=''
  for _rc_id in $THEME_IDS; do
    _rc_theme=$THEMES_DIR/$_rc_id.yml
    OWNED_THEME_LIST="${OWNED_THEME_LIST}${OWNED_THEME_LIST:+,}$_rc_theme"
  done
}

# bash_rc_file: the startup file bash reads for new terminals.
bash_rc_file() {
  if [ "$OS_NAME" = Darwin ]; then
    # macOS terminals start login shells, which read only the FIRST of these
    # that exists. Creating ~/.bash_profile would hide an existing ~/.profile.
    if [ -e "$HOME/.bash_profile" ]; then
      printf '%s\n' "$HOME/.bash_profile"
    elif [ -e "$HOME/.bash_login" ]; then
      printf '%s\n' "$HOME/.bash_login"
    elif [ -e "$HOME/.profile" ]; then
      printf '%s\n' "$HOME/.profile"
    else
      printf '%s\n' "$HOME/.bash_profile"
    fi
  else
    printf '%s\n' "$HOME/.bashrc"
  fi
}

fish_file() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/$LGVDM_NAME.fish"
}

# zsh_dirs: one directory per line whose zsh startup files may matter: $HOME,
# $ZDOTDIR, the usual XDG location, and the ZDOTDIR that ~/.zshenv (or
# /etc/zshenv) sets, asked from zsh itself when those files mention ZDOTDIR.
# zsh reads .zshenv once, from ${ZDOTDIR:-$HOME} BEFORE ~/.zshenv can change
# ZDOTDIR; .zprofile, .zshrc and .zlogin come from the new ZDOTDIR.
zsh_dirs() {
  printf '%s\n' "$HOME"
  if [ -n "${ZDOTDIR:-}" ]; then
    printf '%s\n' "$ZDOTDIR"
  fi
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/zsh" "$HOME/.config/zsh"
  if command -v zsh >/dev/null 2>&1 &&
    grep -q ZDOTDIR "$HOME/.zshenv" /etc/zshenv /etc/zsh/zshenv 2>/dev/null; then
    # shellcheck disable=SC2016 # expanded by zsh, not here
    (unset ZDOTDIR && zsh -c 'print -r -- "lgvdm-zdotdir:$ZDOTDIR"' </dev/null 2>/dev/null) |
      sed -n 's/^lgvdm-zdotdir://p' || :
  fi
}

uninstall_command() {
  _uc_dir=''
  if [ "$OPT_CONFIG_DIR_SET" = 1 ]; then
    _uc_dir=" --config-dir '$(sq "$CONFIG_DIR_ABS")'"
  fi
  if [ -n "$SCRIPT_PATH" ]; then
    printf "sh '%s' --uninstall%s\n" "$(sq "$SCRIPT_PATH")" "$_uc_dir"
  else
    printf 'curl -fsSL %s/install.sh | sh -s -- --uninstall%s\n' "$LGVDM_RAW_URL" "$_uc_dir"
  fi
}

# ---------------------------------------------------------------------------
# theme source

# catalog_stream: print the source catalog in clone mode, otherwise the copy
# embedded in this installer for curl | sh installs.
catalog_stream() {
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/themes/catalog.txt" ]; then
    cat "$SCRIPT_DIR/themes/catalog.txt"
  else
    embedded_catalog
  fi
}

# load_catalog validates the portable id|display-name catalog before any user
# file is changed. A clone also proves that every entry has a terminal palette.
load_catalog() {
  : >"$LGVDM_TMP/catalog" || die "cannot create a temporary catalog"
  catalog_stream >"$LGVDM_TMP/catalog" || die "cannot read the theme catalog"
  THEME_IDS=''
  while IFS='|' read -r _lc_id _lc_name _lc_extra || [ -n "$_lc_id$_lc_name$_lc_extra" ]; do
    _lc_id=$(printf '%s' "$_lc_id" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _lc_name=$(printf '%s' "$_lc_name" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _lc_extra=$(printf '%s' "$_lc_extra" | tr -d '\r')
    [ -n "$_lc_id" ] || continue
    [ "${_lc_id#\#}" = "$_lc_id" ] || continue
    printf '%s\n' "$_lc_id" | grep -Eq '^[a-z0-9]$|^[a-z0-9]([a-z0-9-]*[a-z0-9])$' || die "invalid catalog theme ID '$_lc_id'"
    if printf '%s\n' "$_lc_id" | grep -q -- '--'; then die "invalid catalog theme ID '$_lc_id'"; fi
    [ -n "$_lc_name" ] && [ -z "$_lc_extra" ] || die "invalid catalog line for $_lc_id (expected id|display name)"
    if printf '%s\n' " $THEME_IDS " | grep -Fq " $_lc_id "; then die "duplicate catalog theme ID: $_lc_id"; fi
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/themes/catalog.txt" ]; then
      [ -f "$SCRIPT_DIR/themes/$_lc_id.yml" ] || die "catalog theme $_lc_id is missing themes/$_lc_id.yml"
      [ -f "$SCRIPT_DIR/extras/windows-terminal/$_lc_id.json" ] || die "catalog theme $_lc_id is missing extras/windows-terminal/$_lc_id.json"
    fi
    THEME_IDS="${THEME_IDS}${THEME_IDS:+ }$_lc_id"
  done <"$LGVDM_TMP/catalog"
  [ -n "$THEME_IDS" ] || die "the theme catalog is empty"
  case " $THEME_IDS " in *" $OPT_THEME "*) ;; *) die "unknown theme '$OPT_THEME'. Run --list-themes to see available IDs." ;; esac
  LGVDM_THEME_ID=$OPT_THEME
}

list_themes() {
  say 'Available themes:'
  while IFS='|' read -r _lt_id _lt_name; do
    [ -n "$_lt_id" ] || continue
    [ "${_lt_id#\#}" = "$_lt_id" ] || continue
    printf '  %-24s %s\n' "$_lt_id" "$_lt_name"
  done <"$LGVDM_TMP/catalog"
}

theme_dest() { printf '%s/%s.yml\n' "$THEMES_DIR" "$1"; }

load_managed_ids() {
  MANAGED_IDS=''
  if [ -f "$MANAGED_FILE" ]; then
    while IFS= read -r _mi || [ -n "$_mi" ]; do
      case " $THEME_IDS " in *" $_mi "*) MANAGED_IDS="${MANAGED_IDS}${MANAGED_IDS:+ }$_mi" ;; esac
    done <"$MANAGED_FILE"
  fi
  # Migration from the single-theme installer: only adopt a file that still
  # identifies this repository, never an arbitrary colliding file.
  _mi_legacy=$(theme_dest "$LGVDM_DEFAULT_THEME_ID")
  if [ -z "$MANAGED_IDS" ] && [ -f "$_mi_legacy" ] && grep -q 'lazygit-vscode-themes' "$_mi_legacy"; then
    MANAGED_IDS=$LGVDM_DEFAULT_THEME_ID
  fi
}

is_managed_id() {
  case " $MANAGED_IDS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

write_managed_ids() {
  : >"$MANAGED_FILE" || die "cannot write $MANAGED_FILE"
  for _wm_id in $THEME_IDS; do printf '%s\n' "$_wm_id" >>"$MANAGED_FILE"; done
}

# write_theme_to ID FILE: the theme from the clone next to this script if
# there is one, else the matching copy embedded at the bottom of this script.
write_theme_to() {
  _wt_id=$1
  _wt_out=$2
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/themes/$_wt_id.yml" ]; then
    THEME_ORIGIN="$SCRIPT_DIR/themes/$_wt_id.yml"
    normalize_text <"$THEME_ORIGIN" >"$_wt_out"
  else
    THEME_ORIGIN="embedded copy for $_wt_id (inside this script)"
    embedded_theme "$_wt_id" >"$_wt_out"
  fi
  [ -s "$_wt_out" ] || die "the theme is empty ($THEME_ORIGIN)"
}

# ---------------------------------------------------------------------------
# marker blocks (awk; every file is read as bytes). Each line is compared
# without its CR and, on line 1, without a UTF-8 BOM.

has_block() {
  LC_ALL=C awk -v B="$LGVDM_BEGIN" '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    $0 == B { found = 1; exit }
    END { exit !found }' "$1"
}

# block_has_line FILE LINE: true if a marker block in FILE contains LINE.
block_has_line() {
  LC_ALL=C awk -v B="$LGVDM_BEGIN" -v E="$LGVDM_END" -v L="$2" '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    inb && $0 == E { inb = 0; next }
    inb && $0 == L { found = 1; exit }
    $0 == B { inb = 1 }
    END { exit !found }' "$1"
}

# has_top_level_gui FILE: a top-level "gui:" key outside our block.
has_top_level_gui() {
  LC_ALL=C awk -v B="$LGVDM_BEGIN" -v E="$LGVDM_END" -v G="$LGVDM_GUI_RE" '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    inb { if ($0 == E) inb = 0; next }
    $0 == B { inb = 1; next }
    $0 ~ G { found = 1; exit }
    END { exit !found }' "$1"
}

# has_gui_theme FILE: a "theme:" key under the top-level "gui:" key, outside
# our block. Those keys override the theme in overlay mode.
has_gui_theme() {
  LC_ALL=C awk -v B="$LGVDM_BEGIN" -v E="$LGVDM_END" -v G="$LGVDM_GUI_RE" -v Q="'" '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    inb { if ($0 == E) inb = 0; next }
    $0 == B { inb = 1; next }
    $0 ~ G { ingui = 1; next }
    /^[^ \t#]/ { ingui = 0 }
    ingui && $0 ~ ("^[ \t]+(theme|\"theme\"|" Q "theme" Q ")[ \t]*:") { found = 1; exit }
    END { exit !found }' "$1"
}

# yaml_ends_early FILE: true if lazygit would ignore lines added at the end
# of FILE (before our block): the YAML document ends first ("..." or a
# second "---"), or the top level is a flow collection ("{...}" / "[...]").
yaml_ends_early() {
  LC_ALL=C awk -v B="$LGVDM_BEGIN" '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    $0 == B { exit }
    /^[ \t]*#/ || /^[ \t]*$/ || /^%/ { next }
    $0 == "..." || /^\.\.\.[ \t]/ { found = 1; exit }
    $0 == "---" || /^---[ \t]/ {
      if (content) { found = 1; exit }
      rest = substr($0, 4)
      sub(/^[ \t]+/, "", rest)
      if (rest == "" || rest ~ /^#/) next
      $0 = rest
    }
    !content && /^[ \t]*[{[]/ { found = 1; exit }
    { content = 1 }
    END { exit !found }' "$1"
}

# block_rewrite remove|replace FILE OUT [NEWBLOCK]
#   remove:  write FILE without any marker block to OUT.
#   replace: write FILE to OUT with the first marker block replaced by the
#            contents of NEWBLOCK (other blocks are dropped).
# Bytes outside the blocks are copied unchanged (CRLF included). A missing
# final newline is kept missing. If a removed block at the end of the file
# carries LGVDM_FLAG_NEWLINE, the line break before it is removed as well.
# A UTF-8 BOM in front of a block on line 1 stays at the start of the file
# (unless nothing else is left).
# Exit status 3: a begin marker without an end marker (OUT is then invalid).
# BINMODE=3 stops gawk builds that read files in text mode (MSYS2, Cygwin)
# from dropping CR bytes; other awks ignore the variable.
block_rewrite() {
  _bw_fnl=1
  if ends_without_newline "$2"; then
    _bw_fnl=0
  fi
  LC_ALL=C LGVDM_NEWBLOCK="${4:-}" awk -v BINMODE=3 -v op="$1" -v final_nl="$_bw_fnl" \
    -v B="$LGVDM_BEGIN" -v E="$LGVDM_END" -v FNL="$LGVDM_FLAG_NEWLINE" '
    function emit(s) {
      if (pending) printf "\n"
      printf "%s%s", bom, s
      bom = ""
      pending = 1
    }
    {
      key = $0
      sub(/\r$/, "", key)
      if (NR == 1 && sub(/^\357\273\277/, "", key) && key == B) bom = "\357\273\277"
      if (inb) {
        if (key == E) inb = 0
        else if (key == FNL) addnl = 1
        next
      }
      if (key == B) {
        inb = 1
        addnl = 0
        nblocks++
        if (op == "replace" && nblocks == 1) {
          nbf = ENVIRON["LGVDM_NEWBLOCK"]
          while ((getline line < nbf) > 0) emit(line)
          close(nbf)
        }
        last = "block"
        next
      }
      emit($0)
      last = "orig"
    }
    END {
      if (inb) exit 3
      if (!pending) exit 0
      if (last == "orig") {
        if (final_nl) printf "\n"
      } else if (!(op == "remove" && addnl)) {
        printf "\n"
      }
    }' "$2" >"$3"
}

# write_file SRC DEST: copy SRC over DEST with cat (keeps symlinks,
# permissions and ownership of DEST). Sets WROTE=1 if DEST changed.
write_file() {
  WROTE=0
  if same_content "$1" "$2"; then
    return 0
  fi
  cat "$1" >"$2" || die "cannot write $2"
  WROTE=1
}

# ---------------------------------------------------------------------------
# shell snippets

# posix_block OUT CREATED ADDNL: the block for bash/zsh/sh startup files.
# It puts the selected theme first in LG_CONFIG_FILE and removes stale catalog
# themes first, so switching themes never leaves a merged mixture behind.
# shellcheck disable=SC2016 # the $ in the snippet lines is for the startup file
posix_block() {
  _q="'"
  {
    printf '%s\n' "$LGVDM_BEGIN"
    printf '%s\n' "# Loads the selected VS Code theme for lazygit before your own config.yml."
    printf '%s\n' "# From $LGVDM_REPO_URL - remove with: install.sh --uninstall"
    if [ "$2" = 1 ]; then
      printf '%s\n' "$LGVDM_FLAG_CREATED"
    fi
    if [ "$3" = 1 ]; then
      printf '%s\n' "$LGVDM_FLAG_NEWLINE"
    fi
    printf '%s\n' "lgvdm_theme=$_q$(sq "$THEME_DEST")$_q"
    printf '%s\n' "lgvdm_config=$_q$(sq "$CONFIG_FILE")$_q"
    printf '%s\n' "lgvdm_owned=$_q$(sq "$OWNED_THEME_LIST")$_q"
    printf '%s\n' 'if [ -f "$lgvdm_theme" ]; then'
    printf '%s\n' '  lgvdm_rest='
    printf '%s\n' '  lgvdm_oldifs=$IFS; IFS=,'
    printf '%s\n' '  for lgvdm_entry in ${LG_CONFIG_FILE-}; do'
    printf '%s\n' '    [ -n "$lgvdm_entry" ] || continue'
    printf '%s\n' '    case ",$lgvdm_owned," in *,"$lgvdm_entry",*) ;; *) lgvdm_rest=${lgvdm_rest:+$lgvdm_rest,}$lgvdm_entry ;; esac'
    printf '%s\n' '  done'
    printf '%s\n' '  IFS=$lgvdm_oldifs'
    printf '%s\n' '  if [ -z "$lgvdm_rest" ] && [ -f "$lgvdm_config" ]; then lgvdm_rest=$lgvdm_config; fi'
    printf '%s\n' '  export LG_CONFIG_FILE="$lgvdm_theme${lgvdm_rest:+,$lgvdm_rest}"'
    printf '%s\n' 'fi'
    printf '%s\n' 'unset lgvdm_theme lgvdm_config lgvdm_owned lgvdm_rest lgvdm_oldifs lgvdm_entry'
    printf '%s\n' "$LGVDM_END"
  } >"$1"
}

# fish_block OUT: the whole fish drop-in file (same logic as posix_block).
# shellcheck disable=SC2016 # the $ in the snippet lines is for fish
fish_block() {
  _q="'"
  {
    printf '%s\n' "$LGVDM_BEGIN"
    printf '%s\n' "# Loads the selected VS Code theme for lazygit before your own config.yml."
    printf '%s\n' "# From $LGVDM_REPO_URL - remove with: install.sh --uninstall"
    printf '%s\n' "set -l lgvdm_theme $_q$(fish_sq "$THEME_DEST")$_q"
    printf '%s\n' "set -l lgvdm_config $_q$(fish_sq "$CONFIG_FILE")$_q"
    printf '%s\n' "set -l lgvdm_owned $_q$(fish_sq "$OWNED_THEME_LIST")$_q"
    printf '%s\n' 'if test -f "$lgvdm_theme"'
    printf '%s\n' '    set -l lgvdm_rest'
    printf '%s\n' '    for lgvdm_entry in (string split -- '"'"','"'"' "$LG_CONFIG_FILE")'
    printf '%s\n' '        if test -n "$lgvdm_entry"; and not contains -- "$lgvdm_entry" (string split -- '"'"','"'"' "$lgvdm_owned")'
    printf '%s\n' '            set -a lgvdm_rest "$lgvdm_entry"'
    printf '%s\n' '        end'
    printf '%s\n' '    end'
    printf '%s\n' '    if test (count $lgvdm_rest) -eq 0; and test -f "$lgvdm_config"'
    printf '%s\n' '        set -a lgvdm_rest "$lgvdm_config"'
    printf '%s\n' '    end'
    printf '%s\n' '    set -gx LG_CONFIG_FILE (string join '"'"','"'"' "$lgvdm_theme" $lgvdm_rest)'
    printf '%s\n' 'end'
    printf '%s\n' "$LGVDM_END"
  } >"$1"
}

# skip_rc sh|fish FILE REASON: a startup file the installer cannot change
# (read-only, e.g. a Nix home-manager symlink into /nix/store). The install
# goes on; the summary shows what to add by hand.
skip_rc() {
  if [ "$1" = fish ]; then
    SKIPPED_FISH=1
  else
    SKIPPED_SH=1
  fi
  LGVDM_SKIPPED="${LGVDM_SKIPPED}    $2 ($3)
"
  note "$2: NOT changed ($3)"
}

# usable_rc sh|fish FILE: true if FILE is a regular file or can be created
# (its directory is created if needed); else skip_rc.
usable_rc() {
  _ur_dir=$(dirname "$2")
  if [ ! -d "$_ur_dir" ] && ! mkdir -p "$_ur_dir" 2>/dev/null; then
    skip_rc "$1" "$2" "cannot create $_ur_dir"
    return 1
  fi
  if [ -e "$2" ] || [ -L "$2" ]; then
    if [ ! -f "$2" ]; then
      skip_rc "$1" "$2" "not a regular file, or a broken symlink"
      return 1
    fi
  elif [ ! -w "$_ur_dir" ]; then
    skip_rc "$1" "$2" "cannot create files in $_ur_dir"
    return 1
  fi
  return 0
}

# writable_rc sh|fish FILE: true if the existing FILE can be written; else skip_rc.
writable_rc() {
  if [ -w "$2" ]; then
    return 0
  fi
  skip_rc "$1" "$2" "read-only"
  return 1
}

# install_rc_block FILE: add or refresh the block in a bash/zsh/sh startup file.
install_rc_block() {
  _ir_file=$1
  usable_rc sh "$_ir_file" || return 0
  _ir_new=$LGVDM_TMP/rc.new
  _ir_block=$LGVDM_TMP/rc.block
  if [ -e "$_ir_file" ]; then
    if has_block "$_ir_file"; then
      _ir_created=0
      _ir_addnl=0
      if block_has_line "$_ir_file" "$LGVDM_FLAG_CREATED"; then _ir_created=1; fi
      if block_has_line "$_ir_file" "$LGVDM_FLAG_NEWLINE"; then _ir_addnl=1; fi
      posix_block "$_ir_block" "$_ir_created" "$_ir_addnl"
      _ir_status=0
      block_rewrite replace "$_ir_file" "$_ir_new" "$_ir_block" || _ir_status=$?
      if [ "$_ir_status" != 0 ]; then
        warn "$_ir_file has a '$LGVDM_BEGIN' line without a matching end line; not changed. Fix it by hand."
        return 0
      fi
      if same_content "$_ir_new" "$_ir_file"; then
        note "$_ir_file: block already up to date"
        return 0
      fi
      writable_rc sh "$_ir_file" || return 0
      write_file "$_ir_new" "$_ir_file"
      note "$_ir_file: updated the $LGVDM_NAME block"
      return 0
    fi
    writable_rc sh "$_ir_file" || return 0
    _ir_addnl=0
    if ends_without_newline "$_ir_file"; then _ir_addnl=1; fi
    posix_block "$_ir_block" 0 "$_ir_addnl"
    {
      cat "$_ir_file"
      if [ "$_ir_addnl" = 1 ]; then printf '\n'; fi
      cat "$_ir_block"
    } >"$_ir_new"
    cat "$_ir_new" >"$_ir_file" || die "cannot write $_ir_file"
    note "$_ir_file: added a $LGVDM_NAME block at the end"
  else
    posix_block "$_ir_new" 1 0
    cat "$_ir_new" >"$_ir_file" || die "cannot write $_ir_file"
    note "$_ir_file: created, with a $LGVDM_NAME block"
  fi
}

install_fish_file() {
  _if_file=$(fish_file)
  SHOW_FISH_HINT=1
  usable_rc fish "$_if_file" || return 0
  fish_block "$LGVDM_TMP/fish.new"
  if [ -e "$_if_file" ]; then
    if same_content "$LGVDM_TMP/fish.new" "$_if_file"; then
      note "$_if_file: already up to date"
      return 0
    fi
    writable_rc fish "$_if_file" || return 0
    write_file "$LGVDM_TMP/fish.new" "$_if_file"
    note "$_if_file: updated"
  else
    cat "$LGVDM_TMP/fish.new" >"$_if_file" || die "cannot write $_if_file"
    note "$_if_file: created"
  fi
}

# lg_overrides FILE all|after: print "FILE:LINE: TEXT" for each line of FILE
# outside our block ("after": only below it) that sets or erases
# LG_CONFIG_FILE without reusing its value (sh "LG_CONFIG_FILE=...", fish
# "set [-gx] LG_CONFIG_FILE ..."). Run after the block, such a line drops
# the theme again.
lg_overrides() {
  [ -f "$1" ] || return 0
  LC_ALL=C LGVDM_FILE="$1" awk -v B="$LGVDM_BEGIN" -v E="$LGVDM_END" -v from="$2" '
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    inb { if ($0 == E) { inb = 0; below = 1 } next }
    $0 == B { inb = 1; next }
    from == "after" && !below { next }
    /^[ \t]*#/ { next }
    { line = " " $0 " " }
    match(line, /[^A-Za-z0-9_$]LG_CONFIG_FILE=/) {
      if (!index(substr(line, RSTART + RLENGTH), "LG_CONFIG_FILE")) hit()
      next
    }
    match(line, /[ \t;(]set([ \t]+-[-A-Za-z]*)*[ \t]+LG_CONFIG_FILE[ \t]/) {
      if (substr(line, RSTART, RLENGTH) ~ /[ \t]-[A-Za-z]*[qUlS]|--(query|universal|local|show)/) next
      if (!index(substr(line, RSTART + RLENGTH), "LG_CONFIG_FILE")) hit()
    }
    function hit() { printf "%s:%d: %s\n", ENVIRON["LGVDM_FILE"], NR, $0 }' "$1"
}

# check_overrides FILE all|after: remember the lines lg_overrides finds.
check_overrides() {
  _co_found=$(lg_overrides "$1" "$2") || _co_found=''
  if [ -n "$_co_found" ]; then
    LGVDM_OVERRIDES="${LGVDM_OVERRIDES}$_co_found
"
  fi
}

setup_shell() {
  case $1 in
    bash)
      _sh_rc=$(bash_rc_file)
      install_rc_block "$_sh_rc"
      check_overrides "$_sh_rc" after
      if [ "$OS_NAME" != Darwin ]; then
        # Login shells (SSH, a console, some tmux setups) read these, and
        # they usually source ~/.bashrc before their own lines.
        for _sh_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          check_overrides "$_sh_f" all
        done
      fi
      ;;
    zsh)
      # zsh reads .zshenv once, from ${ZDOTDIR:-$HOME}, before ~/.zshenv can
      # set ZDOTDIR. So a new terminal reads ~/.zshenv even when ZDOTDIR is
      # set in this shell, while shells started with ZDOTDIR in their
      # environment read $ZDOTDIR/.zshenv. The block goes into both; it adds
      # the theme only once.
      install_rc_block "$HOME/.zshenv"
      check_overrides "$HOME/.zshenv" after
      if [ -n "${ZDOTDIR:-}" ] && [ "$(abs_path "$ZDOTDIR")" != "$(abs_path "$HOME")" ]; then
        install_rc_block "$ZDOTDIR/.zshenv"
        check_overrides "$ZDOTDIR/.zshenv" after
      fi
      zsh_dirs | awk '$0 != "" && !seen[$0]++' >"$LGVDM_TMP/zsh.dirs"
      while IFS= read -r _sh_d; do
        for _sh_f in .zprofile .zshrc .zlogin; do
          check_overrides "$_sh_d/$_sh_f" all
        done
      done <"$LGVDM_TMP/zsh.dirs"
      ;;
    fish)
      install_fish_file
      _sh_fd=${XDG_CONFIG_HOME:-$HOME/.config}/fish
      check_overrides "$_sh_fd/config.fish" all
      # conf.d files run in name order: only the ones after ours matter.
      _sh_after=0
      for _sh_f in "$_sh_fd"/conf.d/*.fish; do
        if [ "${_sh_f##*/}" = "$LGVDM_NAME.fish" ]; then
          _sh_after=1
        elif [ "$_sh_after" = 1 ]; then
          check_overrides "$_sh_f" all
        fi
      done
      ;;
    *)
      install_rc_block "$HOME/.profile"
      check_overrides "$HOME/.profile" after
      ;;
  esac
}

setup_shells() {
  case $OPT_SHELL in
    none) ;;
    all)
      setup_shell bash
      setup_shell zsh
      setup_shell fish
      ;;
    auto)
      _ss_name=${SHELL:-}
      _ss_name=${_ss_name##*/}
      _ss_name=${_ss_name%.exe}
      case $_ss_name in
        bash | zsh | fish) setup_shell "$_ss_name" ;;
        *)
          setup_shell profile
          case $_ss_name in
            sh | dash | ash | ksh | ksh93 | mksh | lksh | oksh | loksh | pdksh | yash | posh | busybox) ;;
            *)
              # ~/.profile is read only by POSIX login shells.
              ODD_SHELL=1
              ODD_SHELL_NAME=$_ss_name
              ;;
          esac
          ;;
      esac
      ;;
    *) setup_shell "$OPT_SHELL" ;;
  esac
}

# current_value: what LG_CONFIG_FILE becomes when the block runs in this
# environment (same logic as the snippet).
current_value() {
  _cv_rest=''
  _cv_ifs=$IFS; IFS=,
  for _cv_entry in ${LG_CONFIG_FILE-}; do
    [ -n "$_cv_entry" ] || continue
    case ",$OWNED_THEME_LIST," in *,"$_cv_entry",*) ;; *) _cv_rest=${_cv_rest:+$_cv_rest,}$_cv_entry ;; esac
  done
  IFS=$_cv_ifs
  if [ -z "$_cv_rest" ] && [ -f "$CONFIG_FILE" ]; then _cv_rest=$CONFIG_FILE; fi
  printf '%s\n' "$THEME_DEST${_cv_rest:+,$_cv_rest}"
}

# print_lines FILE: FILE indented, between blank lines, to copy by hand.
print_lines() {
  printf '\n'
  sed 's/^/    /' "$1"
  printf '\n'
}

print_manual_instructions() {
  say "--shell none: no startup file was changed. To load the theme in every new shell,"
  say "add these lines to your shell startup file (bash: ~/.bashrc, zsh: ~/.zshenv, sh: ~/.profile):"
  posix_block "$LGVDM_TMP/manual.block" 0 0
  print_lines "$LGVDM_TMP/manual.block"
  say "fish users: run the installer with --shell fish instead (it writes a conf.d file)."
  say "Or set it by hand (the theme first, then your own config files, comma-separated, no spaces):"
  detail "LG_CONFIG_FILE=$(current_value)"
}

warn_detail() { printf '    %s\n' "$*" >&2; }

# print_shell_warnings: startup files that could not be changed, a $SHELL
# that does not read ~/.profile, and lines that override the block.
print_shell_warnings() {
  if [ -n "$LGVDM_SKIPPED" ]; then
    warn "these startup files could not be changed, so shells that read them do not get the theme yet:"
    printf '%s' "$LGVDM_SKIPPED" >&2
    if [ "$SKIPPED_SH" = 1 ]; then
      say "Add these lines to them yourself (Nix home-manager: programs.bash.bashrcExtra, programs.zsh.envExtra):"
      posix_block "$LGVDM_TMP/manual.block" 0 0
      print_lines "$LGVDM_TMP/manual.block"
    fi
    if [ "$SKIPPED_FISH" = 1 ]; then
      say "fish: add these lines to config.fish yourself (Nix home-manager: programs.fish.shellInit):"
      fish_block "$LGVDM_TMP/manual.fish"
      print_lines "$LGVDM_TMP/manual.fish"
    fi
  fi
  if [ "$ODD_SHELL" = 1 ]; then
    _sw_value=$(current_value)
    case $ODD_SHELL_NAME in
      '')
        warn "SHELL is not set, so the block went into ~/.profile, which only login shells read (bash in a container or an IDE terminal usually is not one)."
        warn_detail "Run the installer again with --shell bash, --shell zsh or --shell fish for the shell you use."
        ;;
      csh | tcsh)
        warn "$ODD_SHELL_NAME does not read ~/.profile. Add this line to ~/.tcshrc (csh: ~/.cshrc):"
        warn_detail "setenv LG_CONFIG_FILE '$(sq "$_sw_value")'"
        ;;
      *)
        warn "$ODD_SHELL_NAME does not read ~/.profile, where the block went (only POSIX login shells read it)."
        warn_detail "Set LG_CONFIG_FILE in its own startup file to: $_sw_value"
        ;;
    esac
    warn_detail "Or use --mode append, which needs no environment variable."
  fi
  if [ -n "$LGVDM_OVERRIDES" ]; then
    warn "these lines set LG_CONFIG_FILE after the $LGVDM_NAME block has run, so new shells would not load the theme:"
    printf '%s' "$LGVDM_OVERRIDES" | sed 's/^/    /' >&2
    warn_detail "Put the theme first in those lines (LG_CONFIG_FILE=\"$THEME_DEST,<your files>\"),"
    warn_detail "or move them above the block (for zsh: into ~/.zshenv, before the block)."
  else
    case ",${LG_CONFIG_FILE-}," in
      ,, | *,"$THEME_DEST",*) ;;
      *)
        say "Note: LG_CONFIG_FILE is already set. The block keeps its entries after the theme, as long as the"
        detail "line that sets it runs before the block; a startup file that sets it later must list the theme first."
        ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# modes

do_overlay() {
  case $CONFIG_DIR_ABS in
    *,*) die "the config directory contains a comma ($CONFIG_DIR_ABS); LG_CONFIG_FILE is a comma-separated list and cannot hold it. Use --mode append instead." ;;
  esac
  mkdir -p "$THEMES_DIR" || die "cannot create $THEMES_DIR"
  load_managed_ids
  # Detect every collision before writing anything. A user file named like a
  # catalog theme is never silently claimed or overwritten.
  for _ov_id in $THEME_IDS; do
    _ov_dest=$(theme_dest "$_ov_id")
    if [ -e "$_ov_dest" ] && ! is_managed_id "$_ov_id"; then
      die "refusing to overwrite untracked theme file $_ov_dest; rename or remove it, then run the installer again"
    fi
  done
  for _ov_id in $THEME_IDS; do
    _ov_src=$LGVDM_TMP/theme-$_ov_id.yml
    _ov_dest=$(theme_dest "$_ov_id")
    write_theme_to "$_ov_id" "$_ov_src"
    if [ -e "$_ov_dest" ]; then
      write_file "$_ov_src" "$_ov_dest"
      if [ "$WROTE" = 1 ]; then
        note "$_ov_dest: updated (from $THEME_ORIGIN)"
      else
        note "$_ov_dest: already up to date"
      fi
    else
      cat "$_ov_src" >"$_ov_dest" || die "cannot write $_ov_dest"
      note "$_ov_dest: installed (from $THEME_ORIGIN)"
    fi
  done
  write_managed_ids
  if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE exists but is not a regular file"
  else
    : >"$CONFIG_FILE" || die "cannot create $CONFIG_FILE"
    note "$CONFIG_FILE: created (empty) - put your own settings here"
  fi

  SHOW_FISH_HINT=0
  LGVDM_SKIPPED=''
  SKIPPED_SH=0
  SKIPPED_FISH=0
  ODD_SHELL=0
  ODD_SHELL_NAME=''
  LGVDM_OVERRIDES=''
  setup_shells

  say "Overlay install done. What changed:"
  printf '%s' "$LGVDM_CHANGES"
  if [ "$OPT_SHELL" = none ]; then
    print_manual_instructions
  fi
  if has_gui_theme "$CONFIG_FILE"; then
    warn "$CONFIG_FILE has its own gui.theme settings. config.yml is loaded after the theme, so those keys override it. Remove them (or the whole theme: section) to see the theme."
  fi
  if has_block "$CONFIG_FILE"; then
    warn "$CONFIG_FILE also contains a $LGVDM_NAME block from --mode append; it is loaded after the theme file and wins. Remove it with --uninstall and install again if you want only overlay mode."
  fi
  print_shell_warnings
  _ov_value=$(current_value)
  say "Next:"
  detail "1. Open a new terminal, then restart lazygit. To use it in this terminal right away:"
  detail "     export LG_CONFIG_FILE='$(sq "$_ov_value")'"
  if [ "$SHOW_FISH_HINT" = 1 ]; then
    detail "   fish: set -gx LG_CONFIG_FILE '$(fish_sq "$_ov_value")'"
  fi
  detail "2. Import extras/windows-terminal/$LGVDM_THEME_ID.json in your terminal to match the theme."
  detail "Your own settings go in $CONFIG_FILE; it is loaded after the theme, so it wins."
  detail "lazygit started from a GUI or IDE launcher may not see LG_CONFIG_FILE; use --mode append there."
  say "Undo: $(uninstall_command)"
}

# theme_sum FILE: "CRC SIZE" of FILE (POSIX cksum).
theme_sum() { cksum <"$1" | awk '{ print $1, $2 }'; }

# yaml_block OUT ADDNL: the block appended to config.yml.
yaml_block() {
  {
    printf '%s\n' "$LGVDM_BEGIN"
    printf '%s\n' "# $LGVDM_THEME_ID theme for lazygit, from $LGVDM_REPO_URL"
    printf '%s\n' "# Re-running the installer with --mode append replaces this whole block; --uninstall removes it."
    if [ "$2" = 1 ]; then
      printf '%s\n' "$LGVDM_FLAG_NEWLINE"
    fi
    printf '%s%s\n' "$LGVDM_SUM_PREFIX" "$(theme_sum "$LGVDM_TMP/theme.yml")"
    cat "$LGVDM_TMP/theme.yml"
    printf '%s\n' "$LGVDM_END"
  } >"$1"
}

# block_body FILE OUT: write the lines of the first block in FILE that follow
# its checksum line to OUT (without CRs) and print the recorded checksum.
# Prints nothing for a block without a checksum line (written by an older
# version, or by install.ps1).
block_body() {
  : >"$2"
  LC_ALL=C LGVDM_OUT="$2" awk -v B="$LGVDM_BEGIN" -v E="$LGVDM_END" -v P="$LGVDM_SUM_PREFIX" '
    BEGIN { out = ENVIRON["LGVDM_OUT"] }
    NR == 1 { sub(/^\357\273\277/, "") }
    { sub(/\r$/, "") }
    inb && $0 == E { exit }
    inb && body { print > out; next }
    inb && index($0, P) == 1 { print substr($0, length(P) + 1); body = 1; next }
    $0 == B { inb = 1 }' "$1"
}

# keep_copy FILE: copy FILE to FILE.bak-<date> (never overwritten later) and
# print that name.
keep_copy() {
  _kc_dest=$1.bak-$(date +%Y%m%d-%H%M%S)
  if [ -e "$_kc_dest" ]; then
    _kc_dest=$_kc_dest-$$
  fi
  cat "$1" >"$_kc_dest" || die "cannot write $_kc_dest"
  printf '%s\n' "$_kc_dest"
}

refuse_ends_early() {
  printf '[%s] ERROR: lazygit would ignore a theme block appended to %s:\n' "$LGVDM_NAME" "$CONFIG_FILE" >&2
  printf '    its YAML document ends before the end of the file (a "..." line or a second\n' >&2
  printf '    "---" line), or its top level is written as {...} / [...]. Nothing was changed.\n' >&2
  printf '    Use the default overlay mode (no --mode append) instead, or add the theme by hand.\n' >&2
  exit 1
}

refuse_append() {
  printf '[%s] ERROR: %s already has a top-level "gui:" key.\n' "$LGVDM_NAME" "$CONFIG_FILE" >&2
  printf '    Appending the theme would add a second "gui:" key, and lazygit refuses to start\n' >&2
  printf '    with that (mapping key "gui" already defined). Nothing was changed.\n' >&2
  printf '    Instead, either:\n' >&2
  printf '      - use the default overlay mode (no --mode append), which loads the theme\n' >&2
  printf '        through LG_CONFIG_FILE and keeps your gui: settings, or\n' >&2
  printf '      - paste the "theme:" section of %s\n' "$LGVDM_RAW_URL/themes/$LGVDM_THEME_ID.yml" >&2
  printf '        under your existing "gui:" key by hand.\n' >&2
  exit 1
}

do_append() {
  EDITED_COPY=''
  write_theme_to "$LGVDM_THEME_ID" "$LGVDM_TMP/theme.yml"
  _ap_block=$LGVDM_TMP/yaml.block
  _ap_new=$LGVDM_TMP/config.new
  if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "$CONFIG_FILE exists but is not a regular file (or is a broken symlink)"
    if has_block "$CONFIG_FILE"; then
      _ap_addnl=0
      if block_has_line "$CONFIG_FILE" "$LGVDM_FLAG_NEWLINE"; then _ap_addnl=1; fi
      yaml_block "$_ap_block" "$_ap_addnl"
      _ap_status=0
      block_rewrite replace "$CONFIG_FILE" "$_ap_new" "$_ap_block" || _ap_status=$?
      if [ "$_ap_status" != 0 ]; then
        die "$CONFIG_FILE has a '$LGVDM_BEGIN' line without a matching end line. Nothing was changed; fix it by hand."
      fi
      if has_top_level_gui "$CONFIG_FILE"; then
        warn "$CONFIG_FILE has a top-level gui: key outside the $LGVDM_NAME block. lazygit refuses a second gui: key; merge them by hand."
      fi
      if yaml_ends_early "$CONFIG_FILE"; then
        warn "$CONFIG_FILE ends its YAML document before the $LGVDM_NAME block (a \"...\" or second \"---\" line, or a {...} top level), so lazygit ignores the block. Fix that by hand or use overlay mode."
      fi
      if same_content "$_ap_new" "$CONFIG_FILE"; then
        note "$CONFIG_FILE: block already up to date"
      else
        # Was the block edited since the installer wrote it? A block without
        # a checksum line cannot tell, so it is treated the same way.
        _ap_sum=$(block_body "$CONFIG_FILE" "$LGVDM_TMP/old.body")
        _ap_keep=''
        if [ -z "$_ap_sum" ] || [ "$_ap_sum" != "$(theme_sum "$LGVDM_TMP/old.body")" ]; then
          _ap_keep=$(keep_copy "$CONFIG_FILE")
        fi
        cat "$CONFIG_FILE" >"$CONFIG_FILE.bak" || die "cannot write $CONFIG_FILE.bak"
        cat "$_ap_new" >"$CONFIG_FILE" || die "cannot write $CONFIG_FILE"
        note "$CONFIG_FILE: updated the $LGVDM_NAME block (backup: $CONFIG_FILE.bak)"
        if [ -n "$_ap_keep" ] && [ -n "$_ap_sum" ]; then
          note "$_ap_keep: copy of the previous $CONFIG_FILE (the block had changes of your own)"
          EDITED_COPY=$_ap_keep
        elif [ -n "$_ap_keep" ]; then
          note "$_ap_keep: copy of the previous $CONFIG_FILE (the old block has no checksum, so edits in it cannot be ruled out)"
        fi
      fi
    elif has_top_level_gui "$CONFIG_FILE"; then
      refuse_append
    elif yaml_ends_early "$CONFIG_FILE"; then
      refuse_ends_early
    else
      _ap_addnl=0
      if ends_without_newline "$CONFIG_FILE"; then _ap_addnl=1; fi
      yaml_block "$_ap_block" "$_ap_addnl"
      {
        cat "$CONFIG_FILE"
        if [ "$_ap_addnl" = 1 ]; then printf '\n'; fi
        cat "$_ap_block"
      } >"$_ap_new"
      if [ -s "$CONFIG_FILE" ]; then
        cat "$CONFIG_FILE" >"$CONFIG_FILE.bak" || die "cannot write $CONFIG_FILE.bak"
        cat "$_ap_new" >"$CONFIG_FILE" || die "cannot write $CONFIG_FILE"
        note "$CONFIG_FILE: appended the theme between marker lines (backup: $CONFIG_FILE.bak)"
      else
        cat "$_ap_new" >"$CONFIG_FILE" || die "cannot write $CONFIG_FILE"
        note "$CONFIG_FILE: appended the theme between marker lines"
      fi
    fi
  else
    mkdir -p "$CONFIG_DIR_ABS" || die "cannot create $CONFIG_DIR_ABS"
    yaml_block "$_ap_block" 0
    cat "$_ap_block" >"$CONFIG_FILE" || die "cannot write $CONFIG_FILE"
    note "$CONFIG_FILE: created, with the theme between marker lines"
  fi

  say "Append install done (theme from $THEME_ORIGIN). What changed:"
  printf '%s' "$LGVDM_CHANGES"
  if [ -n "$EDITED_COPY" ]; then
    warn "you had changed lines inside the $LGVDM_NAME block of $CONFIG_FILE; the update replaced them."
    warn_detail "Your version is kept in $EDITED_COPY. Settings inside the block are always replaced:"
    warn_detail "keep your own settings outside it, or use overlay mode for your own gui: settings."
  fi
  say "Next:"
  detail "1. Restart lazygit (it also reloads config.yml when its terminal regains focus)."
  detail "2. Set your terminal colors to match: background #181818 and the ANSI palette"
  detail "   from extras/ ($LGVDM_REPO_URL/tree/main/extras)."
  detail "Re-running with --mode append updates the theme by replacing the whole block, so keep your"
  detail "own settings outside it. For your own gui: settings, use overlay mode instead."
  say "Undo: $(uninstall_command)"
}

# remove_rc_block FILE: take our block out of a startup file (if present).
remove_rc_block() {
  _rr_file=$1
  if [ ! -f "$_rr_file" ] || ! has_block "$_rr_file"; then
    return 0
  fi
  if [ ! -w "$_rr_file" ]; then
    warn "$_rr_file is read-only; remove the $LGVDM_NAME block from it by hand."
    return 0
  fi
  _rr_created=0
  if block_has_line "$_rr_file" "$LGVDM_FLAG_CREATED"; then _rr_created=1; fi
  _rr_status=0
  block_rewrite remove "$_rr_file" "$LGVDM_TMP/rc.new" || _rr_status=$?
  if [ "$_rr_status" != 0 ]; then
    warn "$_rr_file has a '$LGVDM_BEGIN' line without a matching end line; not changed. Remove the block by hand."
    return 0
  fi
  if [ "$_rr_created" = 1 ] && [ ! -s "$LGVDM_TMP/rc.new" ] && [ ! -L "$_rr_file" ]; then
    rm -f "$_rr_file"
    note "$_rr_file: deleted (the installer created it and nothing else was in it)"
  else
    cat "$LGVDM_TMP/rc.new" >"$_rr_file" || die "cannot write $_rr_file"
    note "$_rr_file: removed the $LGVDM_NAME block"
  fi
  RC_CHANGED=1
}

# remove_fish_file FILE
remove_fish_file() {
  if [ -f "$1" ]; then
    rm -f "$1"
    note "$1: deleted"
    RC_CHANGED=1
  fi
}

do_uninstall() {
  RC_CHANGED=0
  load_managed_ids
  for _un_id in $MANAGED_IDS; do
    _un_dest=$(theme_dest "$_un_id")
    [ -f "$_un_dest" ] || continue
    _un_source=$LGVDM_TMP/uninstall-$_un_id.yml
    write_theme_to "$_un_id" "$_un_source"
    if same_content "$_un_source" "$_un_dest"; then
      rm -f "$_un_dest"
      note "$_un_dest: deleted"
    else
      warn "kept modified or older managed theme $_un_dest; it is no longer tracked (remove it manually if unwanted)"
    fi
  done
  if [ -f "$MANAGED_FILE" ]; then
    rm -f "$MANAGED_FILE"
    note "$MANAGED_FILE: deleted"
  fi
  if [ -d "$THEMES_DIR" ] && rmdir "$THEMES_DIR" 2>/dev/null; then
    note "$THEMES_DIR: deleted (it was empty)"
  fi

  if [ -f "$CONFIG_FILE" ] && has_block "$CONFIG_FILE"; then
    _un_status=0
    block_rewrite remove "$CONFIG_FILE" "$LGVDM_TMP/config.new" || _un_status=$?
    if [ "$_un_status" != 0 ]; then
      warn "$CONFIG_FILE has a '$LGVDM_BEGIN' line without a matching end line; not changed. Remove the block by hand."
    else
      cat "$CONFIG_FILE" >"$CONFIG_FILE.bak" || die "cannot write $CONFIG_FILE.bak"
      cat "$LGVDM_TMP/config.new" >"$CONFIG_FILE" || die "cannot write $CONFIG_FILE"
      note "$CONFIG_FILE: removed the $LGVDM_NAME block (backup: $CONFIG_FILE.bak; the file itself is kept)"
    fi
  fi

  remove_rc_block "$HOME/.bashrc"
  remove_rc_block "$HOME/.bash_profile"
  remove_rc_block "$HOME/.bash_login"
  remove_rc_block "$HOME/.profile"
  zsh_dirs | awk '$0 != "" && !seen[$0]++' >"$LGVDM_TMP/zsh.dirs"
  while IFS= read -r _un_zdir; do
    remove_rc_block "$_un_zdir/.zshenv"
    remove_rc_block "$_un_zdir/.zshrc"
  done <"$LGVDM_TMP/zsh.dirs"
  remove_fish_file "$(fish_file)"
  remove_fish_file "$HOME/.config/fish/conf.d/$LGVDM_NAME.fish"
  remove_fish_file "$HOME/.config/fish/conf.d/lazygit-vscode-dark-modern.fish"

  if [ -z "$LGVDM_CHANGES" ]; then
    say "Nothing to uninstall: no $LGVDM_NAME files or blocks found (config dir: $CONFIG_DIR_ABS)."
  else
    say "Uninstalled. What changed:"
    printf '%s' "$LGVDM_CHANGES"
  fi
  if [ -f "$CONFIG_FILE" ]; then
    detail "$CONFIG_FILE was kept."
  fi
  print_env_hint
  say "Restart lazygit to see its default colors again."
}

# print_env_hint: this shell may still have one or more catalog themes in
# LG_CONFIG_FILE. The command it prints removes every catalog path.
print_env_hint() {
  _eh_has=0
  _eh_rest=''
  _eh_ifs=$IFS
  IFS=,
  set -f
  for _eh_entry in ${LG_CONFIG_FILE-}; do
    [ -n "$_eh_entry" ] || continue
    case ",$OWNED_THEME_LIST," in *,"$_eh_entry",*) _eh_has=1 ;; *) _eh_rest=${_eh_rest:+$_eh_rest,}$_eh_entry ;; esac
  done
  set +f
  IFS=$_eh_ifs
  if [ "$_eh_has" = 0 ]; then
    if [ "$RC_CHANGED" = 1 ]; then
      say "Shells that are already open keep LG_CONFIG_FILE until they are restarted (to clear it now: unset LG_CONFIG_FILE)."
    fi
    return 0
  fi
  say "This shell still has the theme in LG_CONFIG_FILE until it is restarted. To fix it now, run:"
  if [ -z "$_eh_rest" ] || [ "$_eh_rest" = "$CONFIG_FILE" ]; then
    detail "unset LG_CONFIG_FILE          (fish: set -e LG_CONFIG_FILE)"
  else
    detail "export LG_CONFIG_FILE='$(sq "$_eh_rest")'"
    detail "fish: set -gx LG_CONFIG_FILE '$(fish_sq "$_eh_rest")'"
  fi
}

# ---------------------------------------------------------------------------
# BEGIN EMBEDDED CATALOG (generated by tools/sync-theme.sh - do not edit by hand)
embedded_catalog() {
cat <<'LGVDM_CATALOG_EOF'
vscode-dark-modern|VS Code Dark Modern
vscode-light-modern|VS Code Light Modern
tokyo-night|Tokyo Night
neon-test|Neon Test (terminal-independent)
LGVDM_CATALOG_EOF
}
embedded_theme() {
  case $1 in
    vscode-dark-modern)
      cat <<'LGVDM_THEME_VSCODE_DARK_MODERN_EOF'
# yaml-language-server: $schema=https://raw.githubusercontent.com/jesseduffield/lazygit/master/schema/config.json
#
# VS Code "Dark Modern" theme for lazygit
# https://github.com/Makihataima-Ken/lazygit-vscode-themes
#
# Colors come from VS Code's own theme sources (microsoft/vscode):
#   extensions/theme-defaults/themes/dark_modern.json  (workbench colors)
#   extensions/git/package.json                          (gitDecoration.* defaults)
#   src/vs/platform/theme/common/colors/listColors.ts    (list selection defaults)
#
# Rules for editing this file:
#   - Every color value is a YAML list: ['#RRGGBB'] or ['#RRGGBB', bold].
#   - Hex values MUST be quoted. An unquoted "- #0078D4" is a YAML comment.
#   - Only #RGB / #RRGGBB work. lazygit rejects #RRGGBBAA (alpha) and draws white.
#   - One color per list; the only extra attributes are bold / underline / reverse.
#
# lazygit cannot paint the background. Set your terminal background to
# #181818 (VS Code panel terminal) or #1F1F1F (editor), and use the matching
# ANSI palette from extras/ so hard-coded ANSI colors (staged files, commit
# hashes, diff +/-) match VS Code too.

gui:
  # VS Code panels have square corners.
  border: single

  theme:
    # focusBorder / tab.activeBorderTop
    activeBorderColor:
      - '#0078D4'
      - bold
    # activityBar.inactiveForeground: unfocused chrome, still >= 4.5:1 on #181818 / #1F1F1F
    inactiveBorderColor:
      - '#868686'
    # editorWarning.foreground / list.warningForeground (VS Code amber)
    searchingActiveBorderColor:
      - '#CCA700'
      - bold
    # textLink.foreground (keybinding hints in the bottom bar)
    optionsTextColor:
      - '#4DAAFC'
    # list.activeSelectionBackground
    selectedLineBgColor:
      - '#04395E'
    # list.inactiveSelectionBackground
    inactiveViewSelectedLineBgColor:
      - '#37373D'
    # button.foreground on button.background
    cherryPickedCommitFgColor:
      - '#FFFFFF'
    cherryPickedCommitBgColor:
      - '#0078D4'
    # editor.findMatchBackground (no visible effect in lazygit 0.65, kept for newer versions)
    markedBaseCommitFgColor:
      - '#FFFFFF'
    markedBaseCommitBgColor:
      - '#9E6A03'
    # gitDecoration.modifiedResourceForeground
    unstagedChangesColor:
      - '#E2C08D'
    # foreground
    defaultFgColor:
      - '#CCCCCC'
LGVDM_THEME_VSCODE_DARK_MODERN_EOF
      ;;
    vscode-light-modern)
      cat <<'LGVDM_THEME_VSCODE_LIGHT_MODERN_EOF'
# yaml-language-server: $schema=https://raw.githubusercontent.com/jesseduffield/lazygit/master/schema/config.json
#
# VS Code "Light Modern" theme for lazygit
# https://github.com/Makihataima-Ken/lazygit-vscode-themes
#
# Colors come from VS Code's own Light Modern theme and inherited defaults
# (microsoft/vscode). LazyGit cannot paint the terminal background; use the
# matching Windows Terminal palette in extras/windows-terminal/.

gui:
  # VS Code panels have square corners.
  border: single

  theme:
    # focusBorder / tab.activeBorderTop
    activeBorderColor:
      - '#005FB8'
      - bold
    # activityBar.inactiveForeground
    inactiveBorderColor:
      - '#616161'
    # list.warningForeground
    searchingActiveBorderColor:
      - '#855F00'
      - bold
    # textLink.foreground
    optionsTextColor:
      - '#005FB8'
    # list.activeSelectionBackground
    selectedLineBgColor:
      - '#E8E8E8'
    # list.inactiveSelectionBackground
    inactiveViewSelectedLineBgColor:
      - '#E4E6F1'
    # button.foreground on button.background
    cherryPickedCommitFgColor:
      - '#FFFFFF'
    cherryPickedCommitBgColor:
      - '#005FB8'
    # editor.findMatchBackground, composited over #FFFFFF
    markedBaseCommitFgColor:
      - '#3B3B3B'
    markedBaseCommitBgColor:
      - '#D9B44A'
    # Git decoration modified-resource foreground
    unstagedChangesColor:
      - '#895503'
    # foreground
    defaultFgColor:
      - '#3B3B3B'
LGVDM_THEME_VSCODE_LIGHT_MODERN_EOF
      ;;
    tokyo-night)
      cat <<'LGVDM_THEME_TOKYO_NIGHT_EOF'
# yaml-language-server: $schema=https://raw.githubusercontent.com/jesseduffield/lazygit/master/schema/config.json
#
# Tokyo Night theme for lazygit
# https://github.com/Makihataima-Ken/lazygit-vscode-themes
#
# Based on the Tokyo Night `night` palette by folke/tokyonight.nvim:
# https://github.com/folke/tokyonight.nvim/blob/main/extras/lazygit/tokyonight_night.yml
#
# LazyGit cannot paint the terminal background. Set it to #1A1B26 and select
# extras/windows-terminal/tokyo-night.json to make its ANSI colors match.

gui:
  # Keep the catalogue's square panel corners.
  border: single

  theme:
    # Orange focus color
    activeBorderColor:
      - '#FF9E64'
      - bold
    # Cyan unfocused panel frames
    inactiveBorderColor:
      - '#27A1B9'
    # Orange search/filter focus
    searchingActiveBorderColor:
      - '#FF9E64'
      - bold
    # Blue keybinding hints
    optionsTextColor:
      - '#7AA2F7'
    # Deep blue selected-row background
    selectedLineBgColor:
      - '#283457'
    # A slightly quieter selected row in an unfocused view
    inactiveViewSelectedLineBgColor:
      - '#1F2335'
    cherryPickedCommitFgColor:
      - '#7AA2F7'
    cherryPickedCommitBgColor:
      - '#BB9AF7'
    markedBaseCommitFgColor:
      - '#1A1B26'
    markedBaseCommitBgColor:
      - '#E0AF68'
    # Red status letter for unstaged changes
    unstagedChangesColor:
      - '#DB4B4B'
    # Pale blue foreground
    defaultFgColor:
      - '#C0CAF5'
LGVDM_THEME_TOKYO_NIGHT_EOF
      ;;
    neon-test)
      cat <<'LGVDM_THEME_NEON_TEST_EOF'
# yaml-language-server: $schema=https://raw.githubusercontent.com/jesseduffield/lazygit/master/schema/config.json
#
# Neon Test theme for lazygit
# https://github.com/Makihataima-Ken/lazygit-vscode-themes
#
# A deliberately high-contrast theme for verifying that the installer selected
# a LazyGit theme. It does not set defaultFgColor, so your terminal's existing
# foreground and background remain in control. No terminal settings change is
# needed to see its magenta, cyan, yellow, and blue LazyGit UI accents.

gui:
  border: single

  theme:
    # Magenta focused panel frame and tab
    activeBorderColor:
      - '#FF00FF'
      - bold
    # Cyan unfocused panel frames
    inactiveBorderColor:
      - '#00E5FF'
    # Yellow while searching/filtering
    searchingActiveBorderColor:
      - '#FFD600'
      - bold
    # Cyan keybinding hints
    optionsTextColor:
      - '#00E5FF'
    # Strong blue selected-row backgrounds, visible over ordinary dark or light terminals
    selectedLineBgColor:
      - '#005CFF'
    inactiveViewSelectedLineBgColor:
      - '#3D2E78'
    cherryPickedCommitFgColor:
      - '#FFFFFF'
    cherryPickedCommitBgColor:
      - '#FF00FF'
    markedBaseCommitFgColor:
      - '#000000'
    markedBaseCommitBgColor:
      - '#FFD600'
    unstagedChangesColor:
      - '#FF1744'
LGVDM_THEME_NEON_TEST_EOF
      ;;
    *) return 1 ;;
  esac
}
# END EMBEDDED CATALOG

main() {
  LGVDM_CHANGES=''
  parse_args "$@"
  OS_NAME=$(uname -s 2>/dev/null) || OS_NAME=unknown
  detect_script_dir
  case $OS_NAME in
    MINGW* | MSYS* | CYGWIN*)
      if [ "${LGVDM_FORCE_POSIX:-}" != 1 ]; then
        delegate_to_windows
        return 0
      fi
      ;;
  esac
  [ -n "${HOME:-}" ] || die "HOME is not set"
  command -v awk >/dev/null 2>&1 || die "awk is required"
  setup_tmp
  load_catalog
  if [ "$OPT_LIST" = 1 ]; then
    list_themes
    return 0
  fi
  resolve_config_dir
  if [ -z "$OPT_CONFIG_DIR" ]; then
    say "lazygit config directory: $CONFIG_DIR_ABS (use --config-dir to choose another)"
  fi
  if [ "$OPT_UNINSTALL" = 1 ]; then
    do_uninstall
  elif [ "$OPT_MODE" = append ]; then
    do_append
  else
    if ! command -v lazygit >/dev/null 2>&1; then
      warn "lazygit is not on PATH. The theme is installed anyway; get lazygit from https://github.com/jesseduffield/lazygit#installation"
    fi
    do_overlay
  fi
}

main "$@"
