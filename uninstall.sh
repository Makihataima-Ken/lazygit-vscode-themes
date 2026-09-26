#!/bin/sh
# uninstall.sh - remove lazygit-vscode-dark-modern (both install modes).
#
#   sh uninstall.sh [--config-dir DIR]
#
# Same as: sh install.sh --uninstall [options]. See: sh install.sh --help
# Without a clone:
#   curl -fsSL https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.sh | sh -s -- --uninstall

set -eu

main() {
  _un_dir=''
  # Piped (curl ... | sh) or found through PATH (bash uninstall.sh), $0 is
  # not this file, and its directory may hold another project's install.sh.
  if [ -f "$0" ]; then
    case $0 in
      */*) _un_dir=${0%/*} ;;
      *) _un_dir=. ;;
    esac
    if [ -z "$_un_dir" ]; then
      _un_dir=/
    fi
  fi
  if [ -z "$_un_dir" ] || [ ! -f "$_un_dir/install.sh" ] ||
    ! grep -q -F -e '# >>> lazygit-vscode-dark-modern >>>' "$_un_dir/install.sh"; then
    printf '[lazygit-vscode-dark-modern] ERROR: the install.sh of lazygit-vscode-dark-modern is not next to uninstall.sh.\n' >&2
    printf 'Run instead:\n' >&2
    printf '    curl -fsSL https://raw.githubusercontent.com/OWNER/lazygit-vscode-dark-modern/main/install.sh | sh -s -- --uninstall\n' >&2
    exit 1
  fi
  exec sh "$_un_dir/install.sh" --uninstall "$@"
}

main "$@"
