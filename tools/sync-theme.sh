#!/bin/sh
# tools/sync-theme.sh - copy themes/vscode-dark-modern.yml into the EMBEDDED
# THEME regions of install.sh and install.ps1. Those copies are what
# "curl | sh" and "irm | iex" install, since no themes/ folder comes with them.
#
#   sh tools/sync-theme.sh           rewrite the regions that are out of date
#   sh tools/sync-theme.sh --check   exit 1 if a region is out of date (no writes)
#
# Run it after every change to the theme. Only the lines between
# "# BEGIN EMBEDDED THEME" and "# END EMBEDDED THEME" change; every other byte
# of the installers is kept. Running it twice changes nothing.

set -eu

say() { printf '[sync-theme] %s\n' "$*"; }
fail() { printf '[sync-theme] ERROR: %s\n' "$*" >&2; }
die() {
  fail "$*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sh tools/sync-theme.sh [--check]

Regenerates the embedded theme in install.sh and install.ps1 from
themes/vscode-dark-modern.yml.

  --check   Only compare; exit 1 if any region is out of date.
EOF
}

# The theme must survive both embeddings unchanged: an sh here-document and a
# PowerShell single-quoted here-string (and Windows PowerShell 5.1 reads
# install.ps1 as ANSI, so it must be pure ASCII).
check_theme() {
  [ -f "$THEME" ] || die "$THEME not found"
  [ -s "$THEME" ] || die "$THEME is empty"
  # BINMODE=3: gawk on MSYS2/Cygwin would otherwise drop CR bytes on input.
  if LC_ALL=C awk -v BINMODE=3 '/\r/ { bad = 1; exit } END { exit !bad }' "$THEME"; then
    die "$THEME has CRLF line endings; convert it to LF"
  fi
  if LC_ALL=C awk -v BINMODE=3 '/[^\t -~]/ { bad = 1; exit } END { exit !bad }' "$THEME"; then
    die "$THEME contains non-ASCII bytes (or a BOM); install.ps1 must stay pure ASCII"
  fi
  if [ -n "$(tail -c 1 "$THEME")" ]; then
    die "$THEME does not end with a newline"
  fi
  if [ -z "$(tail -n 1 "$THEME")" ]; then
    die "$THEME ends with a blank line; it must end with exactly one newline"
  fi
  if LC_ALL=C awk -v sq="'" '
      $0 == "LGVDM_THEME_EOF" || index($0, sq "@") == 1 || /^[ \t]*# (BEGIN|END) EMBEDDED THEME/ { bad = 1; exit }
      END { exit !bad }' "$THEME"; then
    die "$THEME has a line that would end the embedded copy early (LGVDM_THEME_EOF, a line starting with '@, or an EMBEDDED THEME marker)"
  fi
}

# regenerate sh|ps1 TARGET OUT: TARGET with its region rebuilt, written to OUT.
# Exit status 3: no complete BEGIN/END region in TARGET.
regenerate() {
  _rg_final_nl=1
  if [ -s "$2" ] && [ -n "$(tail -c 1 "$2")" ]; then
    _rg_final_nl=0
  fi
  LC_ALL=C LGVDM_THEME="$THEME" awk -v BINMODE=3 -v kind="$1" -v final_nl="$_rg_final_nl" -v sq="'" '
    function emit(s) {
      if (pending) printf "\n"
      printf "%s", s
      pending = 1
    }
    BEGIN { theme = ENVIRON["LGVDM_THEME"] }
    {
      key = $0
      sub(/\r$/, "", key)
      marker = key
      sub(/^[ \t]+/, "", marker)
      if (state == 1) {
        if (index(marker, "# END EMBEDDED THEME") == 1) {
          emit($0)
          state = 2
        }
        next
      }
      emit($0)
      if (state == 0 && index(marker, "# BEGIN EMBEDDED THEME") == 1) {
        state = 1
        indent = substr(key, 1, length(key) - length(marker))
        if (kind == "sh") {
          emit(indent "embedded_theme() {")
          emit("cat <<" sq "LGVDM_THEME_EOF" sq)
        } else {
          emit(indent "$EmbeddedTheme = @" sq)
        }
        while ((getline line < theme) > 0) emit(line)
        close(theme)
        if (kind == "sh") {
          emit("LGVDM_THEME_EOF")
          emit(indent "}")
        } else {
          emit(sq "@")
        }
      }
    }
    END {
      if (state != 2) exit 3
      if (pending && final_nl) printf "\n"
    }' "$2" >"$3"
}

# sync_one sh|ps1 TARGET: sets FAILED=1 on problems.
sync_one() {
  _so_kind=$1
  _so_target=$2
  _so_name=${_so_target##*/}
  if [ ! -f "$_so_target" ]; then
    if [ "$_so_kind" = ps1 ]; then
      say "$_so_name: not found, skipped"
    else
      fail "$_so_name: not found ($_so_target)"
      FAILED=1
    fi
    return 0
  fi
  _so_status=0
  regenerate "$_so_kind" "$_so_target" "$TMP_OUT" || _so_status=$?
  if [ "$_so_status" != 0 ]; then
    fail "$_so_name: no complete '# BEGIN EMBEDDED THEME' ... '# END EMBEDDED THEME' region found"
    FAILED=1
    return 0
  fi
  if cmp -s "$TMP_OUT" "$_so_target"; then
    say "$_so_name: embedded theme is up to date"
    return 0
  fi
  if [ "$CHECK" = 1 ]; then
    fail "$_so_name: embedded theme is OUT OF DATE; run: sh tools/sync-theme.sh"
    FAILED=1
    return 0
  fi
  cat "$TMP_OUT" >"$_so_target"
  say "$_so_name: embedded theme updated"
}

main() {
  CHECK=0
  while [ $# -gt 0 ]; do
    case $1 in
      --check) CHECK=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fail "unknown option: $1"
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  case $0 in
    */*) _m_dir=${0%/*} ;;
    *) _m_dir=. ;;
  esac
  ROOT=$(CDPATH='' cd -- "$_m_dir/.." && pwd) || die "cannot find the repository root"
  THEME=$ROOT/themes/vscode-dark-modern.yml
  check_theme

  TMP_OUT=$(mktemp "${TMPDIR:-/tmp}/sync-theme.XXXXXX") || die "mktemp failed"
  trap 'rm -f "$TMP_OUT"' EXIT
  trap 'exit 130' HUP INT TERM

  FAILED=0
  sync_one sh "$ROOT/install.sh"
  sync_one ps1 "$ROOT/install.ps1"
  if [ "$FAILED" != 0 ]; then
    exit 1
  fi
}

main "$@"
