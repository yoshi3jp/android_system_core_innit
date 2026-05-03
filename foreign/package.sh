#!/usr/bin/env bash
# Stage Innit foreign build products into a small package-root that can be
# copied into the DSGSI staging root filesystem by the outer dsgsi build.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=foreign/common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF_USAGE
Usage: foreign/package.sh [--binary path] [--destdir path] [--no-tar]

Defaults:
  --binary   $OUT_DIR/system/bin/init
  --destdir  $OUT_DIR/package-root

Output layout:
  package-root/system/bin/init
  package-root/system/bin/ueventd -> init
  package-root/manifest.txt
  package-root/sha256sums.txt

EOF_USAGE
}

binary="${BINARY:-$OUT_DIR/system/bin/init}"
destdir="${DESTDIR:-$OUT_DIR/package-root}"
make_tar=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      [[ $# -ge 2 ]] || die "--binary requires a path"
      binary="$2"
      shift 2
      ;;
    --destdir)
      [[ $# -ge 2 ]] || die "--destdir requires a path"
      destdir="$2"
      shift 2
      ;;
    --no-tar)
      make_tar=0
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

ensure_repo_root
refuse_android_product_env

binary="$(abs_path "$binary")"
destdir="$(abs_path "$destdir")"

[[ -f "$binary" ]] || die "binary does not exist: $binary"

mkdir_clean "$destdir"
mkdir -p "$destdir/system/bin"

install -m 0755 "$binary" "$destdir/system/bin/init"
ln -sfn init "$destdir/system/bin/ueventd"

if [[ -f "$OUT_DIR/system/bin/innit-policy-check" ]]; then
  install -m 0755 "$OUT_DIR/system/bin/innit-policy-check" "$destdir/system/bin/innit-policy-check"
fi

manifest="$destdir/manifest.txt"
{
  printf 'Innit foreign RevA package\n'
  printf 'repository_root=%s\n' "$REPO_ROOT"
  printf 'source_version=%s\n' "$(cat "$REPO_ROOT/INNIT_VERSION" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  printf 'git_commit=%s\n' "$(git -C "$REPO_ROOT" rev-parse --short=16 HEAD 2>/dev/null || printf unknown)"
  printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\nFiles:\n'
  (cd "$destdir" && find . -mindepth 1 -maxdepth 4 -print | sort)
} > "$manifest"

(cd "$destdir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$destdir/sha256sums.txt"

if [[ "$make_tar" -eq 1 ]]; then
  tarball="$OUT_DIR/innit-foreign-arm64-package.tar.xz"
  mkdir -p "$(dirname "$tarball")"
  tar -C "$destdir" -cJf "$tarball" .
  log "wrote package root: $destdir"
  log "wrote tarball: $tarball"
else
  log "wrote package root: $destdir"
fi
