#!/bin/sh
# shellcheck disable=SC2317,SC2329,SC2016,SC2002
# (helpers are called through t(); sh -c snippets are single-quoted on
# purpose; "cat file | sh" stands in for "curl ... | sh")
#
# tests/test-install.sh - sandboxed tests for install.sh, uninstall.sh and
# tools/sync-theme.sh (the macOS / Linux side).
#
#   sh tests/test-install.sh          exit 0 = all checks passed
#
# Safe to run on your own machine: every check uses a temporary HOME,
# XDG_CONFIG_HOME and --config-dir, so your real shell startup files and
# lazygit config are never read or written.
#
# Environment:
#   LAZYGIT=/path/to/lazygit   binary for the config validation check
#                              (default: lazygit on PATH; skipped if none)
#   LGVDM_KEEP=1               keep the sandbox directory for inspection
#
# On Git Bash / MSYS / Cygwin the tests export LGVDM_FORCE_POSIX=1, so
# install.sh runs its macOS/Linux code instead of handing over to install.ps1.

set -u

BEGIN_MARK='# >>> lazygit-vscode-dark-modern >>>'
END_MARK='# <<< lazygit-vscode-dark-modern <<<'
THEME_FILE_NAME='vscode-dark-modern.yml'
LG_OK_TEXT='must be run inside a git repository'

# ---------------------------------------------------------------------------
# reporting

pass() {
  PASSED=$((PASSED + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL  %s\n' "$1"
  if [ $# -gt 1 ]; then
    printf '%s\n' "$2" | sed 's/^/        /'
  fi
}

skip() {
  SKIPPED=$((SKIPPED + 1))
  printf 'SKIP  %s\n' "$1"
}

# t DESCRIPTION COMMAND...: pass if COMMAND succeeds.
t() {
  _t_desc=$1
  shift
  if "$@"; then
    pass "$_t_desc"
  else
    fail "$_t_desc"
  fi
}

# t_eq DESCRIPTION GOT EXPECTED
t_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected: [$3]
got:      [$2]"
  fi
}

# t_status DESCRIPTION EXPECTED_STATUS: checks $ST of the last installer run.
t_status() {
  if [ "$ST" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "exit status $ST, expected $2; output:
$(tail -n 15 "$SB/out")"
  fi
}

# ---------------------------------------------------------------------------
# file predicates

same() { cmp -s "$1" "$2"; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
missing() { ! exists "$1"; }
empty_file() { [ -f "$1" ] && [ ! -s "$1" ]; }
contains() { grep -q -F -- "$2" "$1"; }
lacks() { ! grep -q -F -- "$2" "$1"; }
out_has() { grep -q -F -- "$1" "$SB/out"; }
out_lacks() { ! grep -q -F -- "$1" "$SB/out"; }
size_of() { wc -c <"$1" | tr -d ' '; }
to_crlf() { awk '{ printf "%s\r\n", $0 }'; }
count_lines() { grep -c -x -F -- "$2" "$1" 2>/dev/null || true; }

# one_block FILE: exactly one begin and one end marker line.
one_block() {
  [ -f "$1" ] && [ "$(count_lines "$1" "$BEGIN_MARK")" = 1 ] && [ "$(count_lines "$1" "$END_MARK")" = 1 ]
}

# no_block FILE: FILE has no marker lines (or does not exist).
no_block() {
  [ ! -f "$1" ] || [ "$(count_lines "$1" "$BEGIN_MARK")" = 0 ]
}

# starts_with FILE PREFIX_FILE: the first bytes of FILE are PREFIX_FILE.
starts_with() {
  _sw_n=$(size_of "$2")
  dd if="$1" bs=1 count="$_sw_n" 2>/dev/null | cmp -s - "$2"
}

# rest_after FILE PREFIX_FILE: print FILE without its first size(PREFIX) bytes.
rest_after() {
  _ra_n=$(size_of "$2")
  dd if="$1" bs=1 skip="$_ra_n" 2>/dev/null
}

# block_right_after FILE PREFIX_FILE: FILE = PREFIX + one marker block and
# nothing else.
block_right_after() {
  starts_with "$1" "$2" || return 1
  rest_after "$1" "$2" >"$SB/rest"
  [ "$(sed -n '1p' "$SB/rest")" = "$BEGIN_MARK" ] &&
    [ "$(tail -n 1 "$SB/rest")" = "$END_MARK" ] &&
    [ -z "$(tail -c 1 "$SB/rest")" ] &&
    one_block "$SB/rest"
}

# block_is_theme FILE: FILE ends with the theme followed by the end marker.
block_is_theme() {
  _bt_n=$(wc -l <"$THEME_SRC" | tr -d ' ')
  tail -n $((_bt_n + 1)) "$1" | sed '$d' >"$SB/block-theme"
  same "$SB/block-theme" "$THEME_SRC" && [ "$(tail -n 1 "$1")" = "$END_MARK" ]
}

# rc_files: which startup files exist in the sandbox HOME (sorted names).
rc_files() {
  _rf_list=''
  for _rf in .bashrc .bash_profile .bash_login .profile .zshenv .zshrc; do
    if exists "$HOME/$_rf"; then
      _rf_list="$_rf_list $_rf"
    fi
  done
  if exists "$FISHF"; then
    _rf_list="$_rf_list fish"
  fi
  printf '%s\n' "${_rf_list# }"
}

# ---------------------------------------------------------------------------
# sandbox and runners

new_sandbox() {
  SB=$TMPBASE/$1
  rm -rf "$SB"
  mkdir -p "$SB/home" "$SB/xdg" "$SB/run"
  HOME=$SB/home
  XDG_CONFIG_HOME=$SB/xdg
  SHELL=/bin/sh
  export HOME XDG_CONFIG_HOME SHELL
  unset ZDOTDIR LG_CONFIG_FILE
  RUN=$SB/run
  CFG=$SB/cfg
  T=$CFG/themes/$THEME_FILE_NAME
  C=$CFG/config.yml
  if [ "$OS" = Darwin ]; then
    BASHRC=$HOME/.bash_profile
  else
    BASHRC=$HOME/.bashrc
  fi
  ZSHENV=$HOME/.zshenv
  FISHF=$XDG_CONFIG_HOME/fish/conf.d/lazygit-vscode-themes.fish
  : >"$SB/out"
}

# inst ARGS...: run install.sh (from the repo) in $RUN; sets ST, output in $SB/out.
inst() {
  (cd "$RUN" && $RUNNER "$ROOT/install.sh" "$@") >"$SB/out" 2>&1 </dev/null
  ST=$?
}

# inst_lg VALUE ARGS...: like inst, with LG_CONFIG_FILE=VALUE in the environment.
inst_lg() {
  _il_value=$1
  shift
  (cd "$RUN" && LG_CONFIG_FILE=$_il_value && export LG_CONFIG_FILE &&
    $RUNNER "$ROOT/install.sh" "$@") >"$SB/out" 2>&1 </dev/null
  ST=$?
}

# lg_after SHELL RC unset|set VALUE [twice]: source RC in a fresh SHELL and
# print "LG_CONFIG_FILE|lgvdm_theme" (<unset> for unset variables).
lg_after() {
  _la_shell=$1
  _la_rc=$2
  _la_mode=$3
  _la_value=$4
  _la_twice=${5:-}
  (
    unset LG_CONFIG_FILE lgvdm_theme lgvdm_config
    if [ "$_la_mode" = set ]; then
      LG_CONFIG_FILE=$_la_value
      export LG_CONFIG_FILE
    fi
    case $_la_shell in
      zsh)
        zsh -f -c '. "$1"; if [ -n "$2" ]; then . "$1"; fi
          printf "%s|%s" "${LG_CONFIG_FILE-<unset>}" "${lgvdm_theme-<unset>}"' zsh "$_la_rc" "$_la_twice"
        ;;
      fish)
        LGVDM_T_RC=$_la_rc LGVDM_T_TWICE=$_la_twice fish --no-config -c '
          source $LGVDM_T_RC
          if test -n "$LGVDM_T_TWICE"; source $LGVDM_T_RC; end
          if set -q LG_CONFIG_FILE; printf "%s" "$LG_CONFIG_FILE"; else; printf "<unset>"; end
          printf "|"
          if set -q lgvdm_theme; printf "%s" "$lgvdm_theme"; else; printf "<unset>"; end'
        ;;
      *)
        $_la_shell -c '. "$1"; if [ -n "$2" ]; then . "$1"; fi
          printf "%s|%s" "${LG_CONFIG_FILE-<unset>}" "${lgvdm_theme-<unset>}"' sh "$_la_rc" "$_la_twice"
        ;;
    esac
  )
}

# native PATH: a path lazygit.exe understands (Windows), else PATH unchanged.
native() {
  if [ "$IS_WIN" = 1 ]; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

native_list() {
  if [ "$IS_WIN" != 1 ]; then
    printf '%s\n' "$1"
    return 0
  fi
  _nl_out=''
  _nl_ifs=$IFS
  IFS=,
  set -f
  for _nl_entry in $1; do
    _nl_out=${_nl_out:+$_nl_out,}$(cygpath -m "$_nl_entry")
  done
  set +f
  IFS=$_nl_ifs
  printf '%s\n' "$_nl_out"
}

run_with_timeout() {
  _rt_secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_rt_secs" "$@"
    return $?
  fi
  "$@" &
  _rt_pid=$!
  (sleep "$_rt_secs" && kill "$_rt_pid" 2>/dev/null) &
  _rt_dog=$!
  wait "$_rt_pid"
  _rt_status=$?
  kill "$_rt_dog" 2>/dev/null
  return $_rt_status
}

find_lazygit() {
  LAZYGIT_BIN=''
  if [ -n "${LAZYGIT:-}" ]; then
    LAZYGIT_BIN=$LAZYGIT
    return 0
  fi
  _fl_path=$(command -v lazygit 2>/dev/null) || _fl_path=''
  if [ "$IS_WIN" = 1 ] && [ -n "$_fl_path" ]; then
    # A Chocolatey shim does not pass a kill on to the real exe; use the real one.
    case $_fl_path in
      *[Cc]hocolatey/bin/*)
        _fl_choco=$(cygpath -u "${ChocolateyInstall:-C:/ProgramData/chocolatey}")
        if [ -f "$_fl_choco/lib/lazygit/tools/lazygit.exe" ]; then
          _fl_path=$_fl_choco/lib/lazygit/tools/lazygit.exe
        fi
        ;;
    esac
  fi
  LAZYGIT_BIN=$_fl_path
}

# lg_validate LIST: run lazygit with LIST (comma-separated config files) plus
# a guard file that makes it quit outside a git repository. Succeeds if the
# config loaded (lazygit then complains about the missing repository).
lg_validate() {
  mkdir -p "$SB/lg-config-dir"
  printf 'notARepository: quit\n' >"$SB/lg-guard.yml"
  (cd "$RUN" && run_with_timeout 20 "$LAZYGIT_BIN" \
    --use-config-dir "$(native "$SB/lg-config-dir")" \
    --use-config-file "$(native_list "$1,$SB/lg-guard.yml")") >"$SB/lg.out" 2>&1 </dev/null
  grep -q -F "$LG_OK_TEXT" "$SB/lg.out"
}

# extract_sh_theme FILE ID: the named embedded theme of an install.sh.
extract_sh_theme() {
  _es_delim=$(printf '%s' "$2" | tr '[:lower:]-' '[:upper:]_')
  LC_ALL=C awk -v id="$2" -v e="LGVDM_THEME_$_es_delim"'_EOF' '
    $0 ~ "^[ \t]*" id "\\)" { hit = 1; next }
    hit && index($0, "cat <<") { body = 1; next }
    body && $0 == e { exit }
    body { print }' "$1"
}

# extract_ps1_theme FILE ID: the named embedded theme of an install.ps1.
extract_ps1_theme() {
  LC_ALL=C awk -v sq="'" '
    { sub(/\r$/, "") }
    $0 == "    " id " = @" sq { f = 1; next }
    $0 == sq "@" { f = 0 }
    f { print }' id="'$2'" "$1"
}

# ---------------------------------------------------------------------------
# tests

test_00_syntax() {
  for _sx_file in install.sh uninstall.sh tools/sync-theme.sh tests/test-install.sh; do
    for _sx_shell in sh dash 'bash --posix'; do
      if command -v "${_sx_shell%% *}" >/dev/null 2>&1; then
        # shellcheck disable=SC2086 # "bash --posix" is split on purpose
        t "(0) $_sx_shell -n $_sx_file" $_sx_shell -n "$ROOT/$_sx_file"
      fi
    done
  done
  t "(0) install.sh has LF line endings only" lacks "$ROOT/install.sh" "$CR"
}

test_01_sync() {
  new_sandbox t01
  (cd "$RUN" && sh "$ROOT/tools/sync-theme.sh" --check) >"$SB/out" 2>&1
  ST=$?
  t_status "(1) tools/sync-theme.sh --check passes" 0
  for _s_id in $THEME_IDS; do
    extract_sh_theme "$ROOT/install.sh" "$_s_id" >"$SB/emb-sh-$_s_id"
    t "(1) install.sh embeds $_s_id byte-identically" same "$SB/emb-sh-$_s_id" "$ROOT/themes/$_s_id.yml"
    if [ -f "$ROOT/install.ps1" ]; then
      extract_ps1_theme "$ROOT/install.ps1" "$_s_id" >"$SB/emb-ps1-$_s_id"
      t "(1) install.ps1 embeds $_s_id byte-identically" same "$SB/emb-ps1-$_s_id" "$ROOT/themes/$_s_id.yml"
    fi
  done
  if [ -f "$ROOT/install.ps1" ]; then
    t "(1) sync-theme --check covered install.ps1" out_has "install.ps1: embedded catalog is up to date"
  fi

  # A complete copy with one changed catalog theme: --check fails, sync fixes,
  # and the unaffected catalog entries remain embedded too.
  _s1=$SB/repo
  mkdir -p "$_s1/tools"
  cp "$ROOT/install.sh" "$_s1/"
  cp "$ROOT/uninstall.sh" "$_s1/"
  cp "$ROOT/tools/sync-theme.sh" "$_s1/tools/"
  cp -R "$ROOT/themes" "$_s1/"
  cp -R "$ROOT/extras" "$_s1/"
  if [ -f "$ROOT/install.ps1" ]; then cp "$ROOT/install.ps1" "$_s1/"; fi
  printf '# a new last line\n' >>"$_s1/themes/$THEME_FILE_NAME"
  (cd "$RUN" && sh "$_s1/tools/sync-theme.sh" --check) >"$SB/out" 2>&1
  ST=$?
  t_status "(1) --check exits 1 when the theme changed" 1
  cp "$_s1/install.sh" "$SB/before-sync.sh"
  cp "$ROOT/install.sh" "$SB/orig-install.sh"
  t "(1) --check wrote nothing" same "$_s1/install.sh" "$SB/orig-install.sh"
  (cd "$RUN" && sh "$_s1/tools/sync-theme.sh") >"$SB/out" 2>&1
  ST=$?
  t_status "(1) sync-theme.sh regenerates" 0
  extract_sh_theme "$_s1/install.sh" vscode-dark-modern >"$SB/emb2"
  t "(1) regenerated install.sh region holds the changed theme" same "$SB/emb2" "$_s1/themes/$THEME_FILE_NAME"
  if [ -f "$_s1/install.ps1" ]; then
    extract_ps1_theme "$_s1/install.ps1" vscode-dark-modern >"$SB/emb2ps"
    t "(1) regenerated install.ps1 region holds the changed theme" same "$SB/emb2ps" "$_s1/themes/$THEME_FILE_NAME"
  fi
  # everything outside the region is unchanged
  LC_ALL=C awk '/^# BEGIN EMBEDDED CATALOG/ { f = 1 } !f; /^# END EMBEDDED CATALOG/ { f = 0 }' "$ROOT/install.sh" >"$SB/outside-a"
  LC_ALL=C awk '/^# BEGIN EMBEDDED CATALOG/ { f = 1 } !f; /^# END EMBEDDED CATALOG/ { f = 0 }' "$_s1/install.sh" >"$SB/outside-b"
  t "(1) bytes outside the region are unchanged" same "$SB/outside-a" "$SB/outside-b"
  cp "$_s1/install.sh" "$SB/after-sync1.sh"
  (cd "$RUN" && sh "$_s1/tools/sync-theme.sh" && sh "$_s1/tools/sync-theme.sh" --check) >"$SB/out" 2>&1
  ST=$?
  t_status "(1) second sync + --check pass" 0
  t "(1) second sync changes nothing (idempotent)" same "$_s1/install.sh" "$SB/after-sync1.sh"
  (cd "$RUN" && sh "$_s1/install.sh" --help) >"$SB/out" 2>&1
  ST=$?
  t_status "(1) regenerated install.sh still runs" 0
  to_crlf <"$THEME_SRC" >"$_s1/themes/$THEME_FILE_NAME"
  cp "$_s1/install.sh" "$SB/before-crlf.sh"
  (cd "$RUN" && sh "$_s1/tools/sync-theme.sh") >"$SB/out" 2>&1
  ST=$?
  t_status "(1) sync-theme.sh refuses a CRLF theme" 1
  t "(1) ... and names the problem" out_has "CRLF"
  t "(1) ... and writes nothing" same "$_s1/install.sh" "$SB/before-crlf.sh"
}

test_02_03_fresh() {
  new_sandbox t02
  inst --config-dir "$CFG" --shell all
  t_status "(2) fresh overlay install --shell all exits 0" 0
  t "(2) theme copied byte-identical" same "$T" "$THEME_SRC"
  t "(2) config.yml created empty" empty_file "$C"
  t "(2) ${BASHRC##*/} has exactly one block" one_block "$BASHRC"
  t "(2) .zshenv has exactly one block" one_block "$ZSHENV"
  t "(2) fish drop-in exists" test -f "$FISHF"
  t "(2) fish drop-in names the theme path" contains "$FISHF" "$T"
  t_eq "(2) no other startup files created" "$(rc_files)" "${BASHRC##*/} .zshenv fish"
  t "(2) output says what changed" out_has "What changed"
  t "(2) output explains how to undo" out_has "--uninstall"
  t "(2) output mentions extras/ terminal colors" out_has "extras"

  mkdir -p "$SB/snap"
  for _f in "$T" "$C" "$BASHRC" "$ZSHENV" "$FISHF"; do
    cp "$_f" "$SB/snap/${_f##*/}"
  done
  inst --config-dir "$CFG" --shell all
  t_status "(3) re-run exits 0" 0
  t "(3) ${BASHRC##*/} still has exactly one block" one_block "$BASHRC"
  t "(3) .zshenv still has exactly one block" one_block "$ZSHENV"
  for _f in "$T" "$C" "$BASHRC" "$ZSHENV" "$FISHF"; do
    t "(3) ${_f##*/} byte-identical after re-run" same "$_f" "$SB/snap/${_f##*/}"
  done
}

test_03_catalog() {
  for _cat_id in $THEME_IDS; do
    new_sandbox "t03-$_cat_id"
    inst --config-dir "$CFG" --shell none --theme "$_cat_id"
    t "(3) $_cat_id overlay install exits 0" test "$ST" = 0
    for _cat_installed in $THEME_IDS; do
      t "(3) $_cat_id installs catalog file $_cat_installed" same "$CFG/themes/$_cat_installed.yml" "$ROOT/themes/$_cat_installed.yml"
    done
    t "(3) $_cat_id selects only itself" out_has "$CFG/themes/$_cat_id.yml,$C"
    t "(3) $_cat_id has a terminal palette" contains "$ROOT/extras/windows-terminal/$_cat_id.json" '"name"'
  done

  new_sandbox t03-switch
  inst --config-dir "$CFG" --shell bash --theme vscode-dark-modern
  inst --config-dir "$CFG" --shell bash --theme vscode-light-modern
  _cat_value=$(lg_after sh "$BASHRC" set "$CFG/themes/vscode-dark-modern.yml,$C")
  t_eq "(3) switching strips stale catalog themes from shell LG_CONFIG_FILE" "$_cat_value" "$CFG/themes/vscode-light-modern.yml,$C|<unset>"

  new_sandbox t03-invalid
  inst --config-dir "$CFG" --shell none --theme not-a-theme
  t "(3) invalid theme is rejected before writes" test "$ST" = 1
  t "(3) invalid theme creates no config directory" missing "$CFG"
}

test_04_preserve() {
  new_sandbox t04
  printf 'export A=1\nalias ll="ls -l"' >"$BASHRC"
  printf 'export B=2\r\nexport C=3\r\n' >"$ZSHENV"
  printf '# my profile\nexport P=1\n' >"$HOME/.profile"
  mkdir -p "$SB/orig"
  cp "$BASHRC" "$SB/orig/bashrc"
  cp "$ZSHENV" "$SB/orig/zshenv"
  cp "$HOME/.profile" "$SB/orig/profile"

  inst --config-dir "$CFG" --shell all
  t_status "(4) install over existing startup files exits 0" 0
  # Defined behavior for a file without a final newline: the installer adds
  # one LF (so the marker starts on its own line) and records that inside the
  # block; uninstall removes it again when the block is still the last thing
  # in the file, restoring the original bytes exactly.
  {
    cat "$SB/orig/bashrc"
    printf '\n'
  } >"$SB/exp-bashrc-prefix"
  t "(4) no-final-newline file = original + one LF + block" block_right_after "$BASHRC" "$SB/exp-bashrc-prefix"
  t "(4) block records the added line break" contains "$BASHRC" "# lgvdm: the installer added a line break"
  t "(4) CRLF file = original bytes (CRLF kept) + block" block_right_after "$ZSHENV" "$SB/orig/zshenv"
  t "(4) CRLF file block has no added-line-break flag" lacks "$ZSHENV" "# lgvdm: the installer added a line break"
  t "(4) ~/.profile untouched (not selected)" same "$HOME/.profile" "$SB/orig/profile"

  cp "$BASHRC" "$SB/after1-bashrc"
  cp "$ZSHENV" "$SB/after1-zshenv"
  inst --config-dir "$CFG" --shell all
  t "(4) re-run: no-final-newline file unchanged" same "$BASHRC" "$SB/after1-bashrc"
  t "(4) re-run: CRLF file unchanged" same "$ZSHENV" "$SB/after1-zshenv"

  inst --config-dir "$CFG" --uninstall
  t_status "(4) uninstall exits 0" 0
  t "(4) uninstall restores the no-final-newline file byte-for-byte" same "$BASHRC" "$SB/orig/bashrc"
  t "(4) uninstall restores the CRLF file byte-for-byte" same "$ZSHENV" "$SB/orig/zshenv"
  t "(4) ~/.profile still untouched" same "$HOME/.profile" "$SB/orig/profile"

  # Content added after the block: the added LF must stay (else two lines join).
  new_sandbox t04b
  printf 'export X=1' >"$BASHRC"
  inst --config-dir "$CFG" --shell bash
  printf 'export Y=2\n' >>"$BASHRC"
  inst --config-dir "$CFG" --uninstall
  printf 'export X=1\nexport Y=2\n' >"$SB/expected"
  t "(4) text added after the block is kept, added LF stays as separator" same "$BASHRC" "$SB/expected"

  # Content both before and after the block, block replaced in place.
  new_sandbox t04c
  printf 'before=1\n' >"$BASHRC"
  inst --config-dir "$CFG" --shell bash
  printf 'after=2\n' >>"$BASHRC"
  sed 's/^lgvdm_theme=.*/lgvdm_theme=OLD/' "$BASHRC" >"$SB/edited"
  cat "$SB/edited" >"$BASHRC"
  inst --config-dir "$CFG" --shell bash
  t "(4) stale block is replaced in place" one_block "$BASHRC"
  t "(4) replaced block has the current theme path" lacks "$BASHRC" "lgvdm_theme=OLD"
  t_eq "(4) text before and after the block kept in order" \
    "$(sed -n '1p;$p' "$BASHRC" | tr '\n' ' ')" "before=1 after=2 "
}

# check_snippet SHELL RC
check_snippet() {
  _cs_sh=$1
  _cs_rc=$2
  t_eq "(5) $_cs_sh: LG_CONFIG_FILE unset -> theme,config" \
    "$(lg_after "$_cs_sh" "$_cs_rc" unset '')" "$T,$C|<unset>"
  t_eq "(5) $_cs_sh: LG_CONFIG_FILE empty -> theme,config" \
    "$(lg_after "$_cs_sh" "$_cs_rc" set '')" "$T,$C|<unset>"
  t_eq "(5) $_cs_sh: LG_CONFIG_FILE=/x/a.yml -> theme,/x/a.yml" \
    "$(lg_after "$_cs_sh" "$_cs_rc" set /x/a.yml)" "$T,/x/a.yml|<unset>"
  t_eq "(5) $_cs_sh: catalog theme already listed -> moved first" \
    "$(lg_after "$_cs_sh" "$_cs_rc" set "/x/a.yml,$T")" "$T,/x/a.yml|<unset>"
  t_eq "(5) $_cs_sh: sourced twice -> no duplicate" \
    "$(lg_after "$_cs_sh" "$_cs_rc" unset '' twice)" "$T,$C|<unset>"
  t_eq "(5) $_cs_sh: sourced twice with /x/a.yml -> no duplicate" \
    "$(lg_after "$_cs_sh" "$_cs_rc" set /x/a.yml twice)" "$T,/x/a.yml|<unset>"
  t_eq "(5) $_cs_sh: similar path is not mistaken for the theme" \
    "$(lg_after "$_cs_sh" "$_cs_rc" set "$T.bak")" "$T,$T.bak|<unset>"
  mv "$C" "$C.away"
  t_eq "(5) $_cs_sh: config.yml missing -> theme only" \
    "$(lg_after "$_cs_sh" "$_cs_rc" unset '')" "$T|<unset>"
  mv "$C.away" "$C"
  mv "$T" "$T.away"
  t_eq "(5) $_cs_sh: theme file deleted -> stays unset" \
    "$(lg_after "$_cs_sh" "$_cs_rc" unset '')" "<unset>|<unset>"
  t_eq "(5) $_cs_sh: theme file deleted -> value unchanged" \
    "$(lg_after "$_cs_sh" "$_cs_rc" set /x/a.yml)" "/x/a.yml|<unset>"
  mv "$T.away" "$T"
}

test_05_snippet() {
  new_sandbox t05
  inst --config-dir "$CFG" --shell all
  t_status "(5) install for snippet tests" 0
  for _s5 in sh dash bash; do
    if command -v "$_s5" >/dev/null 2>&1; then
      check_snippet "$_s5" "$BASHRC"
    else
      skip "(5) $_s5 not installed"
    fi
  done
  if command -v zsh >/dev/null 2>&1; then
    check_snippet zsh "$ZSHENV"
  else
    skip "(5) zsh not installed - WARNING: zsh snippet not exercised"
  fi
  if command -v fish >/dev/null 2>&1; then
    check_snippet fish "$FISHF"
  else
    skip "(5) fish not installed - WARNING: fish drop-in not exercised"
  fi
}

test_06_paths() {
  new_sandbox t06
  CFG="$SB/Application Support/lazygit"
  T=$CFG/themes/$THEME_FILE_NAME
  C=$CFG/config.yml
  inst --config-dir "$CFG" --shell bash
  t_status "(6) config dir with a space: install exits 0" 0
  t "(6) theme copied byte-identical" same "$T" "$THEME_SRC"
  t_eq "(6) snippet gives the spaced paths" "$(lg_after sh "$BASHRC" unset '')" "$T,$C|<unset>"
  inst --config-dir "$CFG" --uninstall
  t "(6) uninstall removes the theme" missing "$T"
  t "(6) uninstall removes the block" no_block "$BASHRC"

  new_sandbox t06b
  CFG="$SB/it's a dir/lazygit"
  T=$CFG/themes/$THEME_FILE_NAME
  C=$CFG/config.yml
  inst --config-dir "$CFG" --shell bash
  t_status "(6) config dir with a single quote: install exits 0" 0
  t_eq "(6) snippet handles the single quote" "$(lg_after sh "$BASHRC" unset '')" "$T,$C|<unset>"

  new_sandbox t06c
  inst --config-dir "$SB/a,b/lazygit" --shell bash
  t_status "(6) config dir with a comma: overlay refused" 1
  t "(6) comma: nothing created" missing "$SB/a,b/lazygit/themes"
  t "(6) comma: no startup file written" missing "$BASHRC"

  new_sandbox t06d
  mkdir -p "$SB/rel"
  (cd "$SB/rel" && $RUNNER "$ROOT/install.sh" --config-dir cfg --shell bash) >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(6) relative --config-dir works" 0
  t "(6) relative --config-dir: snippet uses an absolute path" contains "$BASHRC" "lgvdm_theme='$SB/rel/cfg/themes/"
}

test_07_pipe() {
  new_sandbox t07
  (cd "$RUN" && cat "$ROOT/install.sh" | sh -s -- --config-dir "$CFG" --shell none) >"$SB/out" 2>&1
  ST=$?
  t_status "(7) cat install.sh | sh -s -- ... exits 0" 0
  t "(7) piped install uses the embedded theme" out_has "embedded copy"
  t "(7) embedded theme installed byte-identical" same "$T" "$THEME_SRC"
  if command -v dash >/dev/null 2>&1; then
    new_sandbox t07b
    (cd "$RUN" && cat "$ROOT/install.sh" | dash -s -- --config-dir "$CFG" --shell none) >"$SB/out" 2>&1
    ST=$?
    t_status "(7) cat install.sh | dash -s exits 0" 0
    t "(7) dash: embedded theme installed byte-identical" same "$T" "$THEME_SRC"
  fi
  new_sandbox t07c
  sed '$d' "$ROOT/install.sh" >"$SB/truncated.sh"
  (cd "$RUN" && sh "$SB/truncated.sh" --config-dir "$CFG" --shell bash) >"$SB/out" 2>&1
  t "(7) truncated download (no main line) changes nothing" missing "$CFG"
}

test_08_none() {
  new_sandbox t08
  printf 'export KEEP=1\n' >"$BASHRC"
  cp "$BASHRC" "$SB/orig"
  inst --config-dir "$CFG" --shell none
  t_status "(8) --shell none exits 0" 0
  t "(8) prints the block to add" out_has "$BEGIN_MARK"
  t "(8) prints the LG_CONFIG_FILE value" out_has "LG_CONFIG_FILE=$T,$C"
  t "(8) existing startup file untouched" same "$BASHRC" "$SB/orig"
  t_eq "(8) no startup files created" "$(rc_files)" "${BASHRC##*/}"
  t "(8) theme still installed" same "$T" "$THEME_SRC"
}

test_09_append() {
  # 9a: no config.yml yet
  new_sandbox t09a
  inst --config-dir "$CFG" --mode append
  t_status "(9) append, no config.yml: exits 0" 0
  t "(9) config.yml created with one block" one_block "$C"
  t_eq "(9) block starts at line 1" "$(sed -n '1p' "$C")" "$BEGIN_MARK"
  t "(9) block holds the theme verbatim, then the end marker" block_is_theme "$C"
  t "(9) no .bak for a new file" missing "$C.bak"
  t "(9) append mode installs no theme file" missing "$T"
  t_eq "(9) append mode edits no startup files" "$(rc_files)" ""
  cp "$C" "$TMPBASE/fresh-block.yml"
  cp "$C" "$SB/after1"
  inst --config-dir "$CFG" --mode append
  t "(9) re-run: identical, one block" same "$C" "$SB/after1"
  t "(9) re-run: still no .bak" missing "$C.bak"
  inst --config-dir "$CFG" --uninstall
  t "(9) uninstall keeps config.yml (now empty)" empty_file "$C"

  # 9b: existing empty config.yml
  new_sandbox t09b
  mkdir -p "$CFG"
  : >"$C"
  inst --config-dir "$CFG" --mode append
  t_status "(9) append, empty config.yml: exits 0" 0
  t "(9) empty config.yml -> just the block" same "$C" "$TMPBASE/fresh-block.yml"
  t "(9) no .bak for an empty file" missing "$C.bak"

  # 9c/9d: existing content, LF and CRLF
  for _v in lf crlf; do
    new_sandbox "t09-$_v"
    mkdir -p "$CFG"
    if [ "$_v" = lf ]; then
      printf 'git:\n  paging:\n    colorArg: always\n' >"$C"
    else
      printf 'git:\r\n  autoFetch: false\r\n' >"$C"
    fi
    cp "$C" "$SB/orig"
    inst --config-dir "$CFG" --mode append
    t_status "(9) append, $_v config: exits 0" 0
    {
      cat "$SB/orig"
      cat "$TMPBASE/fresh-block.yml"
    } >"$SB/expected"
    t "(9) $_v: config = original bytes + block" same "$C" "$SB/expected"
    t "(9) $_v: .bak = original" same "$C.bak" "$SB/orig"
    cp "$C" "$SB/after1"
    inst --config-dir "$CFG" --mode append
    t "(9) $_v: re-run identical (one block)" same "$C" "$SB/after1"
    t "(9) $_v: re-run leaves .bak alone" same "$C.bak" "$SB/orig"
    inst --config-dir "$CFG" --uninstall
    t_status "(9) $_v: uninstall exits 0" 0
    t "(9) $_v: uninstall restores config byte-for-byte" same "$C" "$SB/orig"
    t "(9) $_v: uninstall backs up the version with the block" same "$C.bak" "$SB/after1"
  done

  # 9e: no final newline
  new_sandbox t09e
  mkdir -p "$CFG"
  printf 'git:\n  autoFetch: false' >"$C"
  cp "$C" "$SB/orig"
  inst --config-dir "$CFG" --mode append
  {
    cat "$SB/orig"
    printf '\n'
  } >"$SB/prefix"
  t "(9) no final newline: original + LF + block" block_right_after "$C" "$SB/prefix"
  inst --config-dir "$CFG" --uninstall
  t "(9) no final newline: uninstall restores byte-for-byte" same "$C" "$SB/orig"

  # 9f: top-level gui: -> refused
  for _v in lf crlf; do
    new_sandbox "t09f-$_v"
    mkdir -p "$CFG"
    if [ "$_v" = lf ]; then
      printf '# mine\ngui:\n  showIcons: true\n' >"$C"
    else
      printf 'gui :\r\n  nerdFontsVersion: "3"\r\n' >"$C"
    fi
    cp "$C" "$SB/orig"
    inst --config-dir "$CFG" --mode append
    t_status "(9) top-level gui: ($_v) -> refused with exit 1" 1
    t "(9) refusal explains the alternatives" out_has "overlay mode"
    t "(9) refused: config.yml unchanged" same "$C" "$SB/orig"
    t "(9) refused: no .bak written" missing "$C.bak"
  done
  # 9f2: the same key after a UTF-8 BOM, or quoted
  for _v in bom dq sq; do
    new_sandbox "t09f2-$_v"
    mkdir -p "$CFG"
    case $_v in
      bom) printf '\357\273\277gui:\n  showIcons: true\n' >"$C" ;;
      dq) printf '"gui":\n  showIcons: true\n' >"$C" ;;
      sq) printf "'gui' :\n  showIcons: true\n" >"$C" ;;
    esac
    cp "$C" "$SB/orig"
    inst --config-dir "$CFG" --mode append
    t_status "(9) top-level gui: ($_v) -> refused with exit 1" 1
    t "(9) refused ($_v): config.yml unchanged" same "$C" "$SB/orig"
  done
  new_sandbox t09g
  mkdir -p "$CFG"
  printf 'git:\n  gui: not-top-level\n' >"$C"
  inst --config-dir "$CFG" --mode append
  t_status "(9) indented gui: key is not a conflict" 0

  # 9h: stale block replaced in place, text around it kept
  new_sandbox t09h
  mkdir -p "$CFG"
  printf 'git:\n  autoFetch: false\n' >"$C"
  cp "$C" "$SB/orig"
  inst --config-dir "$CFG" --mode append
  printf 'os:\n  editPreset: vim\n' >>"$C"
  sed "s/#0078D4/#123456/" "$C" >"$SB/edited"
  cat "$SB/edited" >"$C"
  inst --config-dir "$CFG" --mode append
  {
    cat "$SB/orig"
    cat "$TMPBASE/fresh-block.yml"
    printf 'os:\n  editPreset: vim\n'
  } >"$SB/expected"
  t "(9) stale block replaced in place, text before/after kept" same "$C" "$SB/expected"
  t "(9) replacing wrote a .bak of the previous version" same "$C.bak" "$SB/edited"

  # 9i: begin marker without end marker -> refuse
  new_sandbox t09i
  mkdir -p "$CFG"
  printf 'git:\n  autoFetch: false\n%s\ngui:\n' "$BEGIN_MARK" >"$C"
  cp "$C" "$SB/orig"
  inst --config-dir "$CFG" --mode append
  t_status "(9) unterminated block -> error" 1
  t "(9) unterminated block: config.yml unchanged" same "$C" "$SB/orig"

  # 9j: lazygit ignores whatever follows the end of the first YAML document
  for _v in flow docend doc2 flowstart; do
    new_sandbox "t09j-$_v"
    mkdir -p "$CFG"
    case $_v in
      flow) printf '{}\n' >"$C" ;;
      docend) printf 'git:\n  autoFetch: false\n...\n' >"$C" ;;
      doc2) printf 'git:\n  autoFetch: false\n---\nos:\n  editPreset: vim\n' >"$C" ;;
      flowstart) printf '%s\n' '--- {git: {autoFetch: false}}' >"$C" ;;
    esac
    cp "$C" "$SB/orig"
    inst --config-dir "$CFG" --mode append
    t_status "(9) YAML document ends early ($_v) -> refused with exit 1" 1
    t "(9) refused ($_v): config.yml unchanged" same "$C" "$SB/orig"
  done
  new_sandbox t09k
  mkdir -p "$CFG"
  printf '%s\n' '# mine' '---' 'git:' '  autoFetch: false' >"$C"
  inst --config-dir "$CFG" --mode append
  t_status "(9) a leading --- line is not a problem" 0

  # 9l: UTF-8 BOM (left by some Windows editors)
  new_sandbox t09l
  mkdir -p "$CFG"
  printf '\357\273\277git:\n  autoFetch: false\n' >"$C"
  cp "$C" "$SB/orig"
  inst --config-dir "$CFG" --mode append
  t_status "(9) BOM config: append exits 0" 0
  {
    cat "$SB/orig"
    cat "$TMPBASE/fresh-block.yml"
  } >"$SB/expected"
  t "(9) BOM config = original bytes + block" same "$C" "$SB/expected"
  inst --config-dir "$CFG" --uninstall
  t "(9) BOM config: uninstall restores byte-for-byte" same "$C" "$SB/orig"
  # a block on line 1 that later got a BOM in front of it
  new_sandbox t09m
  mkdir -p "$CFG"
  {
    printf '\357\273\277'
    cat "$TMPBASE/fresh-block.yml"
  } >"$C"
  cp "$C" "$SB/orig"
  inst --config-dir "$CFG" --mode append
  t "(9) BOM before a line-1 block: re-run finds the block (no second block)" same "$C" "$SB/orig"
  printf 'os:\n  editPreset: vim\n' >>"$C"
  inst --config-dir "$CFG" --uninstall
  t_status "(9) BOM before a line-1 block: uninstall exits 0" 0
  printf '\357\273\277os:\n  editPreset: vim\n' >"$SB/expected"
  t "(9) BOM before a line-1 block: block removed, BOM and the rest kept" same "$C" "$SB/expected"

  # 9n: a theme update replaces an unedited block quietly; lines changed
  # inside the block are kept in a dated copy that later runs never touch.
  new_sandbox t09n
  for _v in a b c; do
    mkdir -p "$SB/clone-$_v/themes"
    cp "$ROOT/install.sh" "$SB/clone-$_v/"
  done
  cp "$THEME_SRC" "$SB/clone-a/themes/"
  sed 's/#0078D4/#1177BB/' "$THEME_SRC" >"$SB/clone-b/themes/$THEME_FILE_NAME"
  sed 's/#0078D4/#2288CC/' "$THEME_SRC" >"$SB/clone-c/themes/$THEME_FILE_NAME"
  (cd "$RUN" && $RUNNER "$SB/clone-a/install.sh" --config-dir "$CFG" --mode append) >"$SB/out" 2>&1 </dev/null
  (cd "$RUN" && $RUNNER "$SB/clone-b/install.sh" --config-dir "$CFG" --mode append) >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(9) theme update: exits 0" 0
  t "(9) theme update: block holds the new theme" contains "$C" "'#1177BB'"
  t "(9) theme update of an unedited block: no warning" out_lacks "changed lines inside"
  t_eq "(9) theme update of an unedited block: no dated copy" "$(dated_copies "$C")" ""
  awk '{ print } $0 == "  border: single" { print "  showIcons: true" }' "$C" >"$SB/edited"
  cat "$SB/edited" >"$C"
  (cd "$RUN" && $RUNNER "$SB/clone-c/install.sh" --config-dir "$CFG" --mode append) >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(9) update of an edited block: exits 0" 0
  t "(9) update of an edited block: warns" out_has "changed lines inside"
  t "(9) update of an edited block: block holds the new theme" contains "$C" "'#2288CC'"
  t "(9) update of an edited block: the edited lines are replaced" lacks "$C" "showIcons"
  _keep9=$(dated_copies "$C")
  t "(9) update of an edited block: dated copy holds the edited version" same "$_keep9" "$SB/edited"
  (cd "$RUN" && $RUNNER "$SB/clone-a/install.sh" --config-dir "$CFG" --mode append) >"$SB/out" 2>&1 </dev/null
  t "(9) next update leaves the dated copy alone" same "$_keep9" "$SB/edited"
  t_eq "(9) next update of the unedited block: no new dated copy" "$(dated_copies "$C")" "$_keep9"
}

# dated_copies FILE: the FILE.bak-<date> copies that exist (one per line).
dated_copies() {
  for _dc in "$1".bak-*; do
    if [ -f "$_dc" ]; then
      printf '%s\n' "$_dc"
    fi
  done
}

test_10_uninstall() {
  new_sandbox t10
  inst --config-dir "$CFG" --shell all
  inst --config-dir "$CFG" --mode append
  t_status "(10) overlay + append on the same config dir" 0
  inst --config-dir "$CFG" --uninstall
  t_status "(10) uninstall exits 0" 0
  t "(10) theme file removed" missing "$T"
  t "(10) empty themes dir removed" missing "$CFG/themes"
  t "(10) config.yml kept" test -f "$C"
  t "(10) config.yml block removed (file back to empty)" empty_file "$C"
  t "(10) config.yml backed up before removing the block" one_block "$C.bak"
  t "(10) startup files the installer created are removed" missing "$BASHRC"
  t "(10) .zshenv removed (was created by the installer)" missing "$ZSHENV"
  t "(10) fish drop-in removed" missing "$FISHF"
  inst --config-dir "$CFG" --uninstall
  t_status "(10) second uninstall exits 0" 0
  t "(10) second uninstall: nothing to do" out_has "Nothing to uninstall"
  t "(10) config.yml still kept" test -f "$C"

  new_sandbox t10b
  inst --config-dir "$CFG" --shell none
  printf 'x: 1\n' >"$CFG/themes/other.yml"
  inst --config-dir "$CFG" --uninstall
  t "(10) themes dir with other files is kept" test -f "$CFG/themes/other.yml"
  t "(10) ... but our theme is removed" missing "$T"

  new_sandbox t10c
  inst --config-dir "$CFG" --shell bash
  inst_lg "$T,$C" --config-dir "$CFG" --uninstall
  t "(10) hint: unset LG_CONFIG_FILE when only theme+config were listed" out_has "unset LG_CONFIG_FILE"
  inst --config-dir "$CFG" --shell bash
  inst_lg "$T,/x/a.yml" --config-dir "$CFG" --uninstall
  t "(10) hint: export the remaining entries" out_has "export LG_CONFIG_FILE='/x/a.yml'"

  new_sandbox t10d
  inst --config-dir "$CFG" --shell bash
  (cd "$RUN" && $RUNNER "$ROOT/uninstall.sh" --config-dir "$CFG") >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(10) uninstall.sh exits 0" 0
  t "(10) uninstall.sh removed the theme" missing "$T"
  t "(10) uninstall.sh removed the block" missing "$BASHRC"

  # uninstall.sh runs only the install.sh of this project next to it, never
  # one that happens to be in the current directory.
  new_sandbox t10e
  mkdir -p "$SB/other" "$SB/lone" "$SB/bin"
  printf 'echo FOREIGN-INSTALL-RAN\n' >"$SB/other/install.sh"
  (cd "$SB/other" && cat "$ROOT/uninstall.sh" | sh -s -- --config-dir "$CFG") >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(10) piped uninstall.sh exits 1" 1
  t "(10) piped uninstall.sh does not run ./install.sh" out_lacks "FOREIGN-INSTALL-RAN"
  t "(10) ... and prints the curl command instead" out_has "curl -fsSL"
  cp "$ROOT/uninstall.sh" "$SB/lone/"
  printf 'echo FOREIGN-INSTALL-RAN\n' >"$SB/lone/install.sh"
  (cd "$RUN" && $RUNNER "$SB/lone/uninstall.sh" --config-dir "$CFG") >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(10) uninstall.sh next to another project's install.sh exits 1" 1
  t "(10) ... without running it" out_lacks "FOREIGN-INSTALL-RAN"
  if command -v bash >/dev/null 2>&1; then
    cp "$ROOT/uninstall.sh" "$SB/bin/"
    (cd "$SB/other" && PATH="$SB/bin:$PATH" bash uninstall.sh --config-dir "$CFG") >"$SB/out" 2>&1 </dev/null
    ST=$?
    t_status "(10) bash uninstall.sh found through PATH exits 1" 1
    t "(10) ... without running ./install.sh" out_lacks "FOREIGN-INSTALL-RAN"
  fi
}

test_11_symlink() {
  new_sandbox t11
  mkdir -p "$SB/dotfiles"
  printf 'export D=1\n' >"$SB/dotfiles/bashrc"
  cp "$SB/dotfiles/bashrc" "$SB/orig"
  ln -s "$SB/dotfiles/bashrc" "$BASHRC" 2>/dev/null
  if [ ! -L "$BASHRC" ]; then
    rm -f "$BASHRC"
    skip "(11) ln -s does not create symlinks here (e.g. Git Bash without winsymlinks)"
    return 0
  fi
  inst --config-dir "$CFG" --shell bash
  t "(11) startup file is still a symlink after install" test -L "$BASHRC"
  t "(11) symlink target got the block" one_block "$SB/dotfiles/bashrc"
  inst --config-dir "$CFG" --uninstall
  t "(11) startup file is still a symlink after uninstall" test -L "$BASHRC"
  t "(11) symlink target restored byte-for-byte" same "$SB/dotfiles/bashrc" "$SB/orig"
}

test_12_lazygit() {
  find_lazygit
  if [ -z "$LAZYGIT_BIN" ]; then
    skip "(12) WARNING: lazygit not found (set LAZYGIT=...); config validation skipped"
    return 0
  fi
  new_sandbox t12
  if command -v git >/dev/null 2>&1 &&
    [ "$(cd "$RUN" && git rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    skip "(12) sandbox is inside a git repository; lazygit validation skipped"
    return 0
  fi
  printf '# not a lazygit config\ngui:\n  border: rounded\n' >"$SB/dup-a.yml"
  cp "$SB/dup-a.yml" "$SB/dup-b.yml"
  cat "$THEME_SRC" >>"$SB/dup-b.yml"
  if lg_validate "$SB/dup-b.yml"; then
    skip "(12) WARNING: lazygit accepted a broken config; validation technique unusable here"
    return 0
  fi
  pass "(12) control: lazygit rejects a config with two gui: keys"

  inst --config-dir "$CFG" --shell bash
  _v12=$(lg_after sh "$BASHRC" unset '')
  _v12=${_v12%|*}
  if lg_validate "$_v12"; then
    pass "(12) lazygit loads the overlay LG_CONFIG_FILE ($LAZYGIT_BIN)"
  else
    fail "(12) lazygit loads the overlay LG_CONFIG_FILE" "$(cat "$SB/lg.out")"
  fi

  printf 'git:\n  autoFetch: false\ngui:\n  showIcons: false\n' >"$C"
  if lg_validate "$_v12"; then
    pass "(12) lazygit loads the theme followed by a config.yml with its own gui: key"
  else
    fail "(12) lazygit loads the theme followed by a config.yml with its own gui: key" "$(cat "$SB/lg.out")"
  fi

  new_sandbox t12b
  CFG="$SB/Application Support/lazygit"
  C=$CFG/config.yml
  mkdir -p "$CFG"
  printf 'git:\r\n  autoFetch: false\r\n' >"$C"
  inst --config-dir "$CFG" --mode append
  if lg_validate "$C"; then
    pass "(12) lazygit loads an append-mode config.yml (CRLF user part, path with a space)"
  else
    fail "(12) lazygit loads an append-mode config.yml" "$(cat "$SB/lg.out")"
  fi

  new_sandbox t12c
  mkdir -p "$CFG"
  printf '\357\273\277---\ngit:\n  autoFetch: false\n' >"$C"
  inst --config-dir "$CFG" --mode append
  if [ "$ST" = 0 ] && lg_validate "$C"; then
    pass "(12) lazygit loads an append-mode config.yml that starts with a BOM and ---"
  else
    fail "(12) lazygit loads an append-mode config.yml that starts with a BOM and ---" "exit $ST; $(cat "$SB/lg.out" 2>/dev/null)"
  fi
}

test_13_other_shells() {
  _found13=0
  for _r13 in dash bash-posix busybox ksh mksh yash posh; do
    case $_r13 in
      bash-posix) _cmd13='bash --posix' ;;
      busybox) _cmd13='busybox sh' ;;
      *) _cmd13=$_r13 ;;
    esac
    if ! command -v "${_cmd13%% *}" >/dev/null 2>&1; then
      continue
    fi
    _found13=1
    RUNNER=$_cmd13
    new_sandbox "t13-$_r13"
    printf 'export A=1' >"$BASHRC"
    printf 'export Z=1\r\n' >"$ZSHENV"
    cp "$BASHRC" "$SB/orig-bashrc"
    cp "$ZSHENV" "$SB/orig-zshenv"
    inst --config-dir "$CFG" --shell all
    t_status "(13) $_cmd13: overlay install exits 0" 0
    t "(13) $_cmd13: theme byte-identical" same "$T" "$THEME_SRC"
    t_eq "(13) $_cmd13: snippet value" "$(lg_after sh "$BASHRC" unset '')" "$T,$C|<unset>"
    cp "$BASHRC" "$SB/a1"
    inst --config-dir "$CFG" --shell all
    t "(13) $_cmd13: re-run identical" same "$BASHRC" "$SB/a1"
    inst --config-dir "$CFG" --mode append
    t_status "(13) $_cmd13: append on empty config exits 0" 0
    t "(13) $_cmd13: append block holds the theme" block_is_theme "$C"
    inst --config-dir "$CFG" --uninstall
    t_status "(13) $_cmd13: uninstall exits 0" 0
    t "(13) $_cmd13: rc restored" same "$BASHRC" "$SB/orig-bashrc"
    t "(13) $_cmd13: CRLF rc restored" same "$ZSHENV" "$SB/orig-zshenv"
    t "(13) $_cmd13: config.yml emptied, kept" empty_file "$C"
    t "(13) $_cmd13: fish drop-in removed" missing "$FISHF"
    RUNNER='sh'
  done
  if [ "$_found13" = 0 ]; then
    skip "(13) no other POSIX shells (dash, bash --posix, busybox, ksh...) found"
  fi
}

test_14_auto() {
  for _c14 in /bin/bash:bash /usr/local/bin/bash.exe:bash /usr/bin/zsh:zsh /opt/homebrew/bin/fish:fish /bin/ksh:profile /bin/sh:profile :profile; do
    _shell14=${_c14%:*}
    _want14=${_c14##*:}
    new_sandbox t14
    SHELL=$_shell14
    case $_want14 in
      bash) _exp14=${BASHRC##*/} ;;
      zsh) _exp14=.zshenv ;;
      fish) _exp14=fish ;;
      profile) _exp14=.profile ;;
    esac
    inst --config-dir "$CFG"
    t_eq "(14) --shell auto with SHELL='$_shell14' edits $_exp14 only" "$(rc_files)" "$_exp14"
  done
  SHELL=/bin/sh

  new_sandbox t14z
  ZDOTDIR=$SB/zdot
  export ZDOTDIR
  inst --config-dir "$CFG" --shell zsh
  t "(14) ZDOTDIR set: block goes to \$ZDOTDIR/.zshenv" one_block "$ZDOTDIR/.zshenv"
  t "(14) ZDOTDIR set: block also goes to ~/.zshenv (read before ZDOTDIR is set)" one_block "$HOME/.zshenv"
  inst --config-dir "$CFG" --uninstall
  t "(14) ZDOTDIR set: uninstall removes \$ZDOTDIR/.zshenv" missing "$ZDOTDIR/.zshenv"
  t "(14) ZDOTDIR set: uninstall removes ~/.zshenv" missing "$HOME/.zshenv"
  unset ZDOTDIR

  # The usual XDG setup: ~/.zshenv sets ZDOTDIR=~/.config/zsh. The installer,
  # run from zsh, sees ZDOTDIR, but a new terminal reads only ~/.zshenv.
  new_sandbox t14x
  mkdir -p "$HOME/.config/zsh"
  printf 'export ZDOTDIR="$HOME/.config/zsh"\n' >"$HOME/.zshenv"
  printf '# zshrc\n' >"$HOME/.config/zsh/.zshrc"
  cp "$HOME/.zshenv" "$SB/orig-zshenv"
  (ZDOTDIR=$HOME/.config/zsh && export ZDOTDIR && cd "$RUN" &&
    $RUNNER "$ROOT/install.sh" --config-dir "$CFG" --shell zsh) >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(14) ZDOTDIR set by ~/.zshenv: install exits 0" 0
  t "(14) ZDOTDIR set by ~/.zshenv: ~/.zshenv gets the block" one_block "$HOME/.zshenv"
  if command -v zsh >/dev/null 2>&1; then
    t_eq "(14) ZDOTDIR set by ~/.zshenv: a new zsh has the theme" \
      "$(unset ZDOTDIR LG_CONFIG_FILE && zsh -c 'print -r -- "${LG_CONFIG_FILE-<unset>}"' </dev/null 2>/dev/null)" "$T,$C"
  else
    skip "(14) zsh not installed - new-zsh check skipped"
  fi
  inst --config-dir "$CFG" --uninstall
  t "(14) uninstall without ZDOTDIR (e.g. from bash) restores ~/.zshenv" same "$HOME/.zshenv" "$SB/orig-zshenv"
  t "(14) uninstall without ZDOTDIR removes ~/.config/zsh/.zshenv" missing "$HOME/.config/zsh/.zshenv"
  if command -v zsh >/dev/null 2>&1; then
    # A ZDOTDIR elsewhere is found by asking zsh.
    new_sandbox t14y
    printf 'export ZDOTDIR="%s/zdot"\n' "$SB" >"$HOME/.zshenv"
    (ZDOTDIR=$SB/zdot && export ZDOTDIR && cd "$RUN" &&
      $RUNNER "$ROOT/install.sh" --config-dir "$CFG" --shell zsh) >"$SB/out" 2>&1 </dev/null
    t "(14) custom ZDOTDIR: \$ZDOTDIR/.zshenv gets the block" one_block "$SB/zdot/.zshenv"
    inst --config-dir "$CFG" --uninstall
    t "(14) custom ZDOTDIR: uninstall without ZDOTDIR finds it through zsh" missing "$SB/zdot/.zshenv"
  fi

  # $SHELL values that never read ~/.profile get a warning and a hint.
  new_sandbox t14w
  SHELL=/bin/tcsh
  inst --config-dir "$CFG"
  t "(14) SHELL=tcsh: warns that ~/.profile is not read" out_has "tcsh does not read ~/.profile"
  t "(14) SHELL=tcsh: prints a setenv line" out_has "setenv LG_CONFIG_FILE '$T,$C'"
  new_sandbox t14w2
  SHELL=/usr/bin/nu
  inst --config-dir "$CFG"
  t "(14) SHELL=nu: warns that ~/.profile is not read" out_has "nu does not read ~/.profile"
  new_sandbox t14w3
  SHELL=''
  inst --config-dir "$CFG"
  t "(14) SHELL empty: warns" out_has "SHELL is not set"
  new_sandbox t14w4
  SHELL=/bin/dash
  inst --config-dir "$CFG"
  t "(14) SHELL=dash: no ~/.profile warning" out_lacks "does not read ~/.profile"
  SHELL=/bin/sh

  new_sandbox t14p
  printf 'export P=1\n' >"$HOME/.profile"
  cp "$HOME/.profile" "$SB/orig"
  SHELL=/bin/dash
  inst --config-dir "$CFG"
  t "(14) ~/.profile block added" one_block "$HOME/.profile"
  t_eq "(14) ~/.profile snippet works in sh" "$(lg_after sh "$HOME/.profile" unset '')" "$T,$C|<unset>"
  inst --config-dir "$CFG" --uninstall
  t "(14) ~/.profile restored" same "$HOME/.profile" "$SB/orig"
  SHELL=/bin/sh
}

test_15_warnings() {
  new_sandbox t15
  mkdir -p "$CFG"
  printf 'gui:\n  theme:\n    activeBorderColor:\n      - red\n' >"$C"
  cp "$C" "$SB/orig"
  inst --config-dir "$CFG" --shell none
  t_status "(15) overlay with gui.theme in config.yml still installs" 0
  t "(15) warns that config.yml gui.theme overrides the theme" out_has "WARNING"
  t "(15) config.yml not modified" same "$C" "$SB/orig"

  new_sandbox t15b
  mkdir -p "$CFG"
  printf 'gui:\n  showIcons: true\nos:\n  theme: x\n' >"$C"
  inst --config-dir "$CFG" --shell none
  t "(15) no warning for gui: without theme:" out_lacks "gui.theme"
}

test_16_windows() {
  if [ "$IS_WIN" != 1 ]; then
    skip "(16) Windows hand-over only applies to Git Bash/MSYS/Cygwin"
    return 0
  fi
  if ! command -v powershell.exe >/dev/null 2>&1; then
    skip "(16) powershell.exe not found"
    return 0
  fi
  new_sandbox t16
  mkdir -p "$SB/clone" "$SB/x y"
  cp "$ROOT/install.sh" "$SB/clone/install.sh"
  # A stand-in install.ps1 that only records the parameters it received.
  cat >"$SB/clone/install.ps1" <<'EOF'
param([switch]$Uninstall, [string]$Mode = 'Overlay', [string]$ConfigDir, [switch]$NoPersist)
$line = 'Uninstall=' + $Uninstall + ';Mode=' + $Mode + ';ConfigDir=' + $ConfigDir
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'args.txt'), $line)
EOF
  (unset LGVDM_FORCE_POSIX && cd "$RUN" &&
    sh "$SB/clone/install.sh" --uninstall --mode append --config-dir "$SB/x y") >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(16) Git Bash hands over to install.ps1" 0
  t_eq "(16) arguments mapped to -Uninstall -Mode Append -ConfigDir <windows path>" \
    "$(cat "$SB/clone/args.txt" 2>/dev/null)" "Uninstall=True;Mode=Append;ConfigDir=$(cygpath -w "$SB/x y")"
  rm -f "$SB/clone/args.txt"
  (unset LGVDM_FORCE_POSIX && cd "$RUN" && sh "$SB/clone/install.sh") >"$SB/out" 2>&1 </dev/null
  t_eq "(16) no arguments -> Overlay defaults" "$(cat "$SB/clone/args.txt" 2>/dev/null)" "Uninstall=False;Mode=Overlay;ConfigDir="
  (unset LGVDM_FORCE_POSIX && cd "$RUN" && cat "$ROOT/install.sh" | sh -s) >"$SB/out" 2>&1
  ST=$?
  t_status "(16) curl|sh on Git Bash (no install.ps1 next to it) exits 1" 1
  t "(16) ... and prints the irm | iex one-liner" out_has "install.ps1 | iex"
  (unset LGVDM_FORCE_POSIX && cd "$RUN" &&
    cat "$ROOT/install.sh" | sh -s -- --uninstall --config-dir "$SB/it's here") >"$SB/out" 2>&1
  ST=$?
  t_status "(16) curl|sh --uninstall --config-dir on Git Bash exits 1" 1
  _w16=$(cygpath -w "$SB/it's here" | sed "s/'/''/g")
  t "(16) ... the one-liner keeps -Uninstall and -ConfigDir (quote doubled)" out_has "))) -Uninstall -ConfigDir '$_w16'"
  (unset LGVDM_FORCE_POSIX && cd "$RUN" &&
    cat "$ROOT/install.sh" | sh -s -- --mode append --config-dir "$SB/x y") >"$SB/out" 2>&1
  t "(16) ... and -Mode Append with -ConfigDir" out_has "))) -Mode Append -ConfigDir '$(cygpath -w "$SB/x y")'"
  (unset LGVDM_FORCE_POSIX && cd "$RUN" && cat "$ROOT/install.sh" | sh -s -- --config-dir "$SB/x y") >"$SB/out" 2>&1
  t "(16) ... and overlay with -ConfigDir uses the scriptblock form" out_has "))) -ConfigDir '$(cygpath -w "$SB/x y")'"
}

test_17_cli() {
  new_sandbox t17
  inst --help
  t_status "(17) --help exits 0" 0
  t "(17) --help prints usage" out_has "Usage:"
  inst --bogus
  t_status "(17) unknown option exits 2" 2
  inst --mode sideways
  t_status "(17) bad --mode exits 2" 2
  inst --shell tcsh
  t_status "(17) bad --shell exits 2" 2
  inst --config-dir
  t_status "(17) --config-dir without a value exits 2" 2
  inst --config-dir= --shell none
  t_status "(17) empty --config-dir= exits 2" 2
  inst "--config-dir=$CFG" --shell=none --mode=overlay
  t_status "(17) --opt=value forms work" 0
  t "(17) --opt=value: theme installed" same "$T" "$THEME_SRC"
  inst '--config-dir=~/tilde cfg' --shell=none
  t "(17) --config-dir=~/x expands ~ to HOME" same "$HOME/tilde cfg/themes/$THEME_FILE_NAME" "$THEME_SRC"
  t_eq "(17) usage errors created nothing in HOME" "$(rc_files)" ""
}

test_18_normalize() {
  new_sandbox t18
  mkdir -p "$SB/clone/themes"
  cp "$ROOT/install.sh" "$SB/clone/"
  # CRLF, a UTF-8 BOM and trailing blank lines, as a Windows editor might leave it.
  {
    printf '\357\273\277'
    to_crlf <"$THEME_SRC"
    printf '\r\n\r\n'
  } >"$SB/clone/themes/$THEME_FILE_NAME"
  (cd "$RUN" && $RUNNER "$SB/clone/install.sh" --config-dir "$CFG" --shell none) >"$SB/out" 2>&1 </dev/null
  ST=$?
  t_status "(18) install from a clone with a CRLF+BOM theme" 0
  t "(18) installed theme normalized to LF, no BOM, one final newline" same "$T" "$THEME_SRC"
}

test_19_readonly() {
  # e.g. Nix home-manager: startup files are read-only links into /nix/store.
  new_sandbox t19
  printf 'export A=1\n' >"$BASHRC"
  cp "$BASHRC" "$SB/orig"
  chmod a-w "$BASHRC"
  if [ -w "$BASHRC" ]; then
    chmod u+w "$BASHRC"
    skip "(19) cannot make a file read-only here (running as root?)"
    return 0
  fi
  inst --config-dir "$CFG" --shell all
  t_status "(19) read-only startup file: install still exits 0" 0
  t "(19) read-only file left unchanged" same "$BASHRC" "$SB/orig"
  t "(19) the other shells are still set up (.zshenv)" one_block "$ZSHENV"
  t "(19) the other shells are still set up (fish)" test -f "$FISHF"
  t "(19) says the file was not changed" out_has "NOT changed (read-only)"
  t "(19) prints the block to add by hand" out_has "$BEGIN_MARK"
  t "(19) mentions home-manager" out_has "home-manager"
  t "(19) the summary and next steps are printed" out_has "Next:"
  cp "$FISHF" "$SB/fish-before"
  chmod a-w "$FISHF"
  inst --config-dir "$CFG" --shell fish
  t "(19) up-to-date read-only fish file: no complaint" out_lacks "NOT changed"
  printf '# changed\n' >"$SB/fish-changed"
  chmod u+w "$FISHF"
  cat "$SB/fish-changed" >"$FISHF"
  chmod a-w "$FISHF"
  inst --config-dir "$CFG" --shell fish
  t "(19) outdated read-only fish file: not changed" same "$FISHF" "$SB/fish-changed"
  t "(19) ... and the fish lines are printed instead" out_has "add these lines to config.fish yourself"
  chmod u+w "$BASHRC" "$FISHF"
}

test_20_overrides() {
  # Lines that set LG_CONFIG_FILE after the block has run drop the theme.
  new_sandbox t20
  printf 'export LG_CONFIG_FILE="$HOME/work.yml"\n' >"$HOME/.zshrc"
  printf 'export LG_CONFIG_FILE="$LG_CONFIG_FILE,$HOME/more.yml"\n# LG_CONFIG_FILE=/old.yml\n' >"$HOME/.zprofile"
  mkdir -p "$XDG_CONFIG_HOME/fish"
  printf 'if set -q LG_CONFIG_FILE\nend\nset -gx LG_CONFIG_FILE ~/work.yml\n' >"$XDG_CONFIG_HOME/fish/config.fish"
  inst --config-dir "$CFG" --shell all
  t_status "(20) install with later LG_CONFIG_FILE lines exits 0" 0
  t "(20) warns about ~/.zshrc line 1" out_has "$HOME/.zshrc:1: export LG_CONFIG_FILE="
  t "(20) a line that keeps \$LG_CONFIG_FILE is not reported" out_lacks ".zprofile:1:"
  t "(20) a comment is not reported" out_lacks ".zprofile:2:"
  t "(20) warns about config.fish line 3" out_has "config.fish:3: set -gx LG_CONFIG_FILE"
  t "(20) set -q is not reported" out_lacks "config.fish:1:"
  t "(20) says how to fix it" out_has "Put the theme first"

  new_sandbox t20b
  printf 'export LG_CONFIG_FILE=/x/early.yml\n' >"$BASHRC"
  inst --config-dir "$CFG" --shell bash
  t "(20) a line above the block is not reported" out_lacks "these lines set LG_CONFIG_FILE"
  printf 'export LG_CONFIG_FILE=/x/late.yml\n' >>"$BASHRC"
  inst --config-dir "$CFG" --shell bash
  t "(20) a line below the block is reported" out_has "$BASHRC:"
  inst_lg /x/work.yml --config-dir "$CFG" --shell none
  t "(20) LG_CONFIG_FILE already set: a note explains the order" out_has "LG_CONFIG_FILE is already set"
}

# ---------------------------------------------------------------------------

main() {
  PASSED=0
  FAILED=0
  SKIPPED=0
  RUNNER='sh'
  CR=$(printf '\r')

  case $0 in
    */*) _m_dir=${0%/*} ;;
    *) _m_dir=. ;;
  esac
  ROOT=$(CDPATH='' cd -- "$_m_dir/.." && pwd) || exit 2
  THEME_SRC=$ROOT/themes/$THEME_FILE_NAME
  CATALOG_SRC=$ROOT/themes/catalog.txt
  [ -f "$THEME_SRC" ] || {
    printf 'cannot find %s\n' "$THEME_SRC" >&2
    exit 2
  }
  [ -f "$CATALOG_SRC" ] || {
    printf 'cannot find %s\n' "$CATALOG_SRC" >&2
    exit 2
  }
  THEME_IDS=''
  while IFS='|' read -r _main_id _main_name _main_extra || [ -n "$_main_id$_main_name$_main_extra" ]; do
    case $_main_id in '' | \#*) continue ;; esac
    THEME_IDS="${THEME_IDS}${THEME_IDS:+ }$_main_id"
    [ -f "$ROOT/themes/$_main_id.yml" ] || exit 2
    [ -f "$ROOT/extras/windows-terminal/$_main_id.json" ] || exit 2
  done <"$CATALOG_SRC"
  [ -n "$THEME_IDS" ] || exit 2

  OS=$(uname -s 2>/dev/null) || OS=unknown
  IS_WIN=0
  case $OS in
    MINGW* | MSYS* | CYGWIN*)
      IS_WIN=1
      LGVDM_FORCE_POSIX=1
      export LGVDM_FORCE_POSIX
      ;;
  esac

  TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/lgvdm-test.XXXXXX") || exit 2
  if [ "${LGVDM_KEEP:-}" = 1 ]; then
    printf 'Sandbox kept at %s\n' "$TMPBASE"
  else
    trap 'rm -rf "$TMPBASE"' EXIT
  fi
  trap 'exit 130' HUP INT TERM

  # Never let a test see the real environment.
  HOME=$TMPBASE/no-home
  XDG_CONFIG_HOME=$TMPBASE/no-xdg
  export HOME XDG_CONFIG_HOME
  unset ZDOTDIR LG_CONFIG_FILE CONFIG_DIR BASH_ENV ENV

  printf 'Testing %s (os: %s, sh: %s)\n\n' "$ROOT" "$OS" "$(command -v sh)"

  test_00_syntax
  test_01_sync
  test_02_03_fresh
  test_03_catalog
  test_04_preserve
  test_05_snippet
  test_06_paths
  test_07_pipe
  test_08_none
  test_09_append
  test_10_uninstall
  test_11_symlink
  test_12_lazygit
  test_13_other_shells
  test_14_auto
  test_15_warnings
  test_16_windows
  test_17_cli
  test_18_normalize
  test_19_readonly
  test_20_overrides

  printf '\nSUMMARY: %s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
  if [ "$FAILED" != 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
