#!/usr/bin/env bash
# Common helpers for the Innit foreign build path.
# Repository root is the directory that contains init/ and foreign/.
# No script assumes files above this repository root.

set -euo pipefail

foreign_common_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -h "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd
}

FOREIGN_DIR="${FOREIGN_DIR:-$(foreign_common_dir)}"
REPO_ROOT="${REPO_ROOT:-$(cd "$FOREIGN_DIR/.." >/dev/null 2>&1 && pwd)}"
INIT_DIR="${INIT_DIR:-$REPO_ROOT/init}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out/foreign/arm64}"
QUARRY_DIR="${QUARRY_DIR:-$REPO_ROOT/quarry/aosp-android-12.0.0_r8}"
AOSP_TAG="${AOSP_TAG:-android-12.0.0_r8}"

log()  { printf '[innit-foreign] %s\n' "$*" >&2; }
warn() { printf '[innit-foreign][warn] %s\n' "$*" >&2; }
die()  { printf '[innit-foreign][fatal] %s\n' "$*" >&2; exit 1; }

usage_var() {
  cat >&2 <<EOF_USAGE
Required variables are normally supplied like this:

  cd android_system_core_innit_init_only
  NDK=/path/to/android-ndk \\
  DSGSI_ROOTFS=/path/to/dsgsi/staging/root \\
  foreign/build.sh all

EOF_USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ensure_repo_root() {
  [[ -d "$REPO_ROOT/init" ]] || die "repo root does not contain init/: $REPO_ROOT"
  [[ -d "$REPO_ROOT/foreign" ]] || die "repo root does not contain foreign/: $REPO_ROOT"
  [[ -f "$REPO_ROOT/init/main.cpp" ]] || die "missing init/main.cpp under $REPO_ROOT"
  [[ -f "$REPO_ROOT/init/Android.bp" ]] || die "missing init/Android.bp under $REPO_ROOT"
}

refuse_android_product_env() {
  if [[ -n "${ANDROID_BUILD_TOP:-}" || -n "${ANDROID_PRODUCT_OUT:-}" || -n "${TARGET_PRODUCT:-}" ]]; then
    die "refusing to run inside an Android/Soong product build environment; unset ANDROID_BUILD_TOP/ANDROID_PRODUCT_OUT/TARGET_PRODUCT"
  fi
}

abs_path() {
  local p="${1:-}"

  case "$p" in
    "")
      printf '%s
' "$(pwd)"
      ;;
    "~")
      printf '%s
' "${HOME:-~}"
      ;;
    "~/"*)
      printf '%s
' "${HOME:-~}/${p#~/}"
      ;;
    /*)
      printf '%s
' "$p"
      ;;
    *)
      printf '%s
' "$(pwd)/$p"
      ;;
  esac
}

mkdir_clean() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d"
}

append_unique() {
  local -n _arr="$1"
  local item="$2"
  local x
  for x in "${_arr[@]:-}"; do
    [[ "$x" == "$item" ]] && return 0
  done
  _arr+=("$item")
}

add_existing_include() {
  local -n _arr="$1"
  local d="$2"
  [[ -d "$d" ]] && append_unique _arr "-I$d"
}

add_existing_libdir() {
  local -n _arr="$1"
  local d="$2"
  [[ -d "$d" ]] && append_unique _arr "-L$d"
}

normalize_ndk_root_path() {
  local p="$1"
  [[ -n "$p" ]] || return 1

  p="$(abs_path "$p")"

  # Canonical case: value is already the Android NDK root.
  if [[ -d "$p/toolchains/llvm/prebuilt" ]]; then
    printf '%s\n' "$p"
    return 0
  fi

  # Tolerate values selected from innit-menuconfig:
  #   NDK root
  #   toolchains/llvm/prebuilt/<host>
  #   toolchains/llvm/prebuilt/<host>/bin
  #   a clang/clang++ executable under that bin directory
  if [[ -f "$p" ]]; then
    p="$(dirname "$p")"
  fi

  while [[ "$p" != "/" && -n "$p" ]]; do
    if [[ -d "$p/toolchains/llvm/prebuilt" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
    p="$(dirname "$p")"
  done

  return 1
}

normalize_ndk_prebuilt_path() {
  local p="$1"
  [[ -n "$p" ]] || return 1

  p="$(abs_path "$p")"

  # Accept either:
  #   .../toolchains/llvm/prebuilt/<host>
  #   .../toolchains/llvm/prebuilt/<host>/bin
  #   .../toolchains/llvm/prebuilt/<host>/bin/<tool>
  if [[ -f "$p" ]]; then
    p="$(dirname "$p")"
  fi

  if [[ -d "$p" && "$(basename "$p")" == "bin" ]]; then
    p="$(dirname "$p")"
  fi

  [[ -d "$p/bin" ]] || return 1
  [[ -x "$p/bin/llvm-ar" ]] || return 1

  printf '%s\n' "$p"
}


resolve_ndk_api_for_prebuilt() {
  local tc="$1"
  local triple="$2"
  local requested_api="$3"

  [[ -d "$tc/bin" ]] || return 1

  if [[ -x "$tc/bin/${triple}${requested_api}-clang++" ]]; then
    printf '%s\n' "$requested_api"
    return 0
  fi

  local best=""
  local f base api
  for f in "$tc/bin/${triple}"*-clang++; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"
    api="${base#${triple}}"
    api="${api%-clang++}"
    [[ "$api" =~ ^[0-9]+$ ]] || continue

    if (( api <= requested_api )); then
      if [[ -z "$best" || api -gt best ]]; then
        best="$api"
      fi
    fi
  done

  if [[ -n "$best" ]]; then
    warn "requested Android API $requested_api is not available in this NDK for $triple; using API $best wrapper"
    printf '%s\n' "$best"
    return 0
  fi

  return 1
}


find_ndk_toolchain() {
  : "${NDK:?set NDK to an Android NDK path}"

  if [[ -n "${NDK_PREBUILT:-}" ]]; then
    local normalized_prebuilt
    if normalized_prebuilt="$(normalize_ndk_prebuilt_path "$NDK_PREBUILT")"; then
      printf '%s
' "$normalized_prebuilt"
      return 0
    fi
    warn "ignoring invalid NDK_PREBUILT: $NDK_PREBUILT"
  fi

  local ndk_root
  if ! ndk_root="$(normalize_ndk_root_path "$NDK")"; then
    die "NDK does not contain toolchains/llvm/prebuilt: $NDK"
  fi

  NDK="$ndk_root"
  export NDK

  local wanted_cxx="${TRIPLE:-aarch64-linux-android}${API:-31}-clang++"

  if [[ -n "${INNIT_NDK_PREBUILT:-}" ]]; then
    local requested="$NDK/toolchains/llvm/prebuilt/$INNIT_NDK_PREBUILT"
    [[ -d "$requested" ]] || die "INNIT_NDK_PREBUILT does not exist under NDK: $INNIT_NDK_PREBUILT"
    [[ -x "$requested/bin/$wanted_cxx" ]] || die "INNIT_NDK_PREBUILT lacks $wanted_cxx: $requested"
    printf '%s
' "$requested"
    return 0
  fi

  local requested_host="${NDK_HOST_TAG_RESOLVED:-}"
  [[ -n "$requested_host" ]] || requested_host="${NDK_HOST_TAG:-}"

  if [[ -n "$requested_host" && "$requested_host" != "auto" ]]; then
    local requested="$NDK/toolchains/llvm/prebuilt/$requested_host"
    [[ -d "$requested" ]] || die "requested NDK host prebuilt does not exist under NDK: $requested_host"
    [[ -x "$requested/bin/$wanted_cxx" ]] || die "requested NDK prebuilt lacks $wanted_cxx: $requested"
    printf '%s
' "$requested"
    return 0
  fi

  local candidates=()
  local d
  for d in "$NDK"/toolchains/llvm/prebuilt/*; do
    [[ -d "$d/bin" ]] || continue
    [[ -x "$d/bin/$wanted_cxx" ]] || continue
    candidates+=("$d")
  done

  [[ ${#candidates[@]} -gt 0 ]] || die "could not find an NDK LLVM prebuilt with $wanted_cxx under $NDK/toolchains/llvm/prebuilt"

  if [[ ${#candidates[@]} -gt 1 ]]; then
    warn "multiple NDK prebuilts found; using ${candidates[0]}"
  fi

  printf '%s
' "${candidates[0]}"
}

require_dsgsi_rootfs() {
  local root="${DSGSI_ROOTFS:-${ABI_ROOT:-}}"
  [[ -n "$root" ]] || {
    usage_var
    die "set DSGSI_ROOTFS to the dsgsi staging root filesystem"
  }
  root="$(abs_path "$root")"
  [[ -d "$root" ]] || die "DSGSI_ROOTFS is not a directory: $root"
  [[ -d "$root/system/lib64" ]] || die "missing $root/system/lib64"
  [[ -e "$root/system/bin/linker64" ]] || die "missing $root/system/bin/linker64"
  printf '%s\n' "$root"
}

readelf_tool() {
  if [[ -n "${READELF:-}" ]]; then
    printf '%s\n' "$READELF"
    return 0
  fi
  if [[ -n "${NDK:-}" ]]; then
    local tc
    tc="$(find_ndk_toolchain)"
    if [[ -x "$tc/bin/llvm-readelf" ]]; then
      printf '%s\n' "$tc/bin/llvm-readelf"
      return 0
    fi
  fi
  command -v llvm-readelf >/dev/null 2>&1 && { command -v llvm-readelf; return 0; }
  command -v readelf >/dev/null 2>&1 && { command -v readelf; return 0; }
  die "no readelf or llvm-readelf found"
}

nm_tool() {
  if [[ -n "${NM:-}" ]]; then
    printf '%s\n' "$NM"
    return 0
  fi
  if [[ -n "${NDK:-}" ]]; then
    local tc
    tc="$(find_ndk_toolchain)"
    if [[ -x "$tc/bin/llvm-nm" ]]; then
      printf '%s\n' "$tc/bin/llvm-nm"
      return 0
    fi
  fi
  command -v llvm-nm >/dev/null 2>&1 && { command -v llvm-nm; return 0; }
  command -v nm >/dev/null 2>&1 && { command -v nm; return 0; }
  die "no nm or llvm-nm found"
}

write_kv_report_header() {
  local f="$1"
  mkdir -p "$(dirname "$f")"
  {
    printf 'repo_root=%s\n' "$REPO_ROOT"
    printf 'init_dir=%s\n' "$INIT_DIR"
    printf 'foreign_dir=%s\n' "$FOREIGN_DIR"
    printf 'out_dir=%s\n' "$OUT_DIR"
    printf 'quarry_dir=%s\n' "$QUARRY_DIR"
    printf 'aosp_tag=%s\n' "$AOSP_TAG"
    printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$f"
}

# ---------------------------------------------------------------------------
# Optional path helpers override
#
# These helpers are intentionally tolerant. Many foreign build include/library
# paths are optional quarry or fallback paths. Under `set -e`, returning 1 for
# a missing optional directory aborts the whole build, which is not intended.
# ---------------------------------------------------------------------------

add_existing_include() {
  local -n _arr="$1"
  local d="$2"

  if [[ -d "$d" ]]; then
    _arr+=("-I$d")
  fi

  return 0
}

add_existing_libdir() {
  local -n _arr="$1"
  local d="$2"

  if [[ -d "$d" ]]; then
    _arr+=("-L$d")
  fi

  return 0
}
