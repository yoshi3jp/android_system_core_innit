#!/usr/bin/env bash
# Validate the DSGSI staging rootfs ABI expected by Innit foreign builds.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=foreign/common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF_USAGE
Usage: foreign/check-abi.sh [--binary path] [--no-binary]

Environment:
  DSGSI_ROOTFS=/path/to/dsgsi/staging/root   required
  NDK=/path/to/android-ndk                   optional, used for llvm-readelf

Checks:
  - staging root has /system/bin/linker64
  - staging root has /system/lib64
  - required shared libraries are present
  - optional shared libraries are reported
  - if --binary is supplied, DT_NEEDED entries are checked against /system/lib64

EOF_USAGE
}

binary="${BINARY:-$OUT_DIR/system/bin/init}"
check_binary=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      [[ $# -ge 2 ]] || die "--binary requires a path"
      binary="$2"
      shift 2
      ;;
    --no-binary)
      check_binary=0
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
rootfs="$(require_dsgsi_rootfs)"
libdir="$rootfs/system/lib64"
linker="$rootfs/system/bin/linker64"
report="$OUT_DIR/abi-report.txt"
mkdir -p "$OUT_DIR"

required_libs=(
  libc.so
  libm.so
  libdl.so
  liblog.so
  libbase.so
  libcutils.so
  libselinux.so
  libprocessgroup.so
  libprocessgroup_setup.so
  libfs_mgr.so
  liblp.so
  libext4_utils.so
  libbootloader_message.so
  liblogwrap.so
  libkeyutils.so
  libc++.so
)

optional_libs=(
  libtinyxml2.so
  libprotobuf-cpp-lite.so
  libbacktrace.so
  libgsi.so
  libmodprobe.so
  libprocinfo.so
  libpropertyinfoparser.so
  libpropertyinfoserializer.so
  libcap.so
)

write_kv_report_header "$report"
{
  printf 'dsgsi_rootfs=%s\n' "$rootfs"
  printf 'abi_libdir=%s\n' "$libdir"
  printf 'abi_linker=%s\n' "$linker"
  printf '\n[required-libs]\n'
} >> "$report"

missing=0
for lib in "${required_libs[@]}"; do
  if [[ -e "$libdir/$lib" ]]; then
    printf 'OK      %s\n' "$lib" | tee -a "$report" >/dev/null
  else
    printf 'MISSING %s\n' "$lib" | tee -a "$report" >/dev/null
    missing=1
  fi
done

{
  printf '\n[optional-libs]\n'
  for lib in "${optional_libs[@]}"; do
    if [[ -e "$libdir/$lib" ]]; then
      printf 'OK      %s\n' "$lib"
    else
      printf 'ABSENT  %s\n' "$lib"
    fi
  done
} >> "$report"

if [[ "$check_binary" -eq 1 ]]; then
  if [[ ! -e "$binary" ]]; then
    warn "binary not present yet, skipping DT_NEEDED check: $binary"
  else
    reade="$(readelf_tool)"
    dt_needed="$OUT_DIR/dt-needed.txt"
    interp="$OUT_DIR/interpreter.txt"

    "$reade" -l "$binary" > "$OUT_DIR/readelf-program-headers.txt"
    "$reade" -d "$binary" > "$OUT_DIR/readelf-dynamic.txt"

    sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' \
      "$OUT_DIR/readelf-program-headers.txt" > "$interp" || true

    sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' \
      "$OUT_DIR/readelf-dynamic.txt" | sort -u > "$dt_needed"

    {
      printf '\n[binary]\n'
      printf 'path=%s\n' "$binary"
      printf 'interpreter=%s\n' "$(cat "$interp" 2>/dev/null || true)"
      printf '\n[dt-needed]\n'
      cat "$dt_needed"
      printf '\n[dt-needed-resolution]\n'
    } >> "$report"

    if ! grep -qx '/system/bin/linker64' "$interp"; then
      warn "unexpected ELF interpreter for runtime root; expected /system/bin/linker64"
      missing=1
    fi

    while IFS= read -r lib; do
      [[ -n "$lib" ]] || continue
      case "$lib" in
        libc.so|libm.so|libdl.so)
          printf 'NDK/PLATFORM %s\n' "$lib" >> "$report"
          ;;
        *)
          if [[ -e "$libdir/$lib" ]]; then
            printf 'OK           %s\n' "$lib" >> "$report"
          else
            printf 'MISSING      %s\n' "$lib" >> "$report"
            missing=1
          fi
          ;;
      esac
    done < "$dt_needed"
  fi
fi

if [[ "$missing" -ne 0 ]]; then
  cat "$report" >&2
  die "ABI check failed; see $report"
fi

log "ABI check passed; report: $report"
