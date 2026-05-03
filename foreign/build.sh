#!/usr/bin/env bash
# Foreign NDK build for Innit RevA.
# This script deliberately avoids Soong, lunch, m/mm, and generated Android
# product outputs. It treats AOSP as a sparse source/header quarry and links
# against the supplied DSGSI staging root filesystem ABI.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=foreign/common.sh
source "$SCRIPT_DIR/common.sh"

usage() {
  cat <<EOF_USAGE
Usage: foreign/build.sh [command]

Commands:
  all            prepare, generate proto, build policy-check, build init, check ABI, package
  prepare        create foreign/compat, foreign/stubs, and output directories
  proto          generate local protobuf C++ outputs under foreign/generated/
  policy-check   build target-side innit-policy-check
  init           build target-side /system/bin/init
  check-abi      run foreign/check-abi.sh against built init
  package        stage init + ueventd symlink under out/foreign/arm64/package-root
  clean          remove out/foreign/arm64 and foreign/generated

Required environment for target builds:
  NDK=/path/to/android-ndk
  DSGSI_ROOTFS=/path/to/dsgsi/staging/root

Important optional environment:
  API=31                         Android API level for NDK clang driver
  QUARRY_DIR=$QUARRY_DIR
  OUT_DIR=$OUT_DIR
  PROTOC=protoc                   Host protoc executable
  SEPOLICY_VERSION=30             Foreign replacement for Soong selinux_policy_version
  INNIT_LIBCAP_A=/path/libcap.a    Use when DSGSI rootfs has no /system/lib64/libcap.so
  INNIT_ALLOW_GSI_STUB=1          Allow local libgsi fallback if libgsi.so is absent. Default: 1
  INNIT_ASSUME_GSI_RUNNING=1      Return true from fallback IsGsiRunning(). Default: 1
  INNIT_EXTRA_INCLUDE_DIRS="a:b"  Extra target include dirs
  INNIT_EXTRA_LIB_DIRS="a:b"      Extra target library dirs
  INNIT_EXTRA_LDLIBS="-lfoo ..."  Extra linker flags

EOF_USAGE
}

API="${API:-31}"
TRIPLE="${TRIPLE:-aarch64-linux-android}"
SEPOLICY_VERSION="${SEPOLICY_VERSION:-30}"
PROTOC="${PROTOC:-protoc}"
INNIT_ALLOW_GSI_STUB="${INNIT_ALLOW_GSI_STUB:-1}"
INNIT_ASSUME_GSI_RUNNING="${INNIT_ASSUME_GSI_RUNNING:-1}"

BUILD_DIR="$OUT_DIR/build"
OBJ_DIR="$BUILD_DIR/obj"
GEN_DIR="$REPO_ROOT/foreign/generated"
PROTO_SRC_DIR="$GEN_DIR/proto_src"
PROTO_OUT_DIR="$GEN_DIR/proto_out"
FALLBACK_INCLUDE_DIR="$GEN_DIR/fallback_include"
STAGING_SYSTEM_DIR="$OUT_DIR/system"

TC=""
CC=""
CXX=""
AR=""
READELF_TOOL=""
NM_TOOL=""
DSGSI_ABI_ROOT=""
ABI_LIB64=""

ensure_quarry() {
  [[ -d "$QUARRY_DIR" ]] || die "quarry is missing: $QUARRY_DIR ; run foreign/quarry.sh sync"
  [[ -d "$QUARRY_DIR/system/libbase/include" ]] || die "quarry missing system/libbase/include; run foreign/quarry.sh sync"
  [[ -d "$QUARRY_DIR/external/protobuf/src" ]] || die "quarry missing external/protobuf/src; run foreign/quarry.sh sync"
}

setup_tools() {
  : "${NDK:?set NDK to the Android NDK path}"
  TC="$(find_ndk_toolchain)"
  CC="$TC/bin/${TRIPLE}${API}-clang"
  CXX="$TC/bin/${TRIPLE}${API}-clang++"
  AR="$TC/bin/llvm-ar"
  READELF_TOOL="$TC/bin/llvm-readelf"
  NM_TOOL="$TC/bin/llvm-nm"

  [[ -x "$CC" ]] || die "missing target C compiler: $CC"
  [[ -x "$CXX" ]] || die "missing target C++ compiler: $CXX"
  [[ -x "$AR" ]] || die "missing llvm-ar: $AR"
}

setup_abi() {
  DSGSI_ABI_ROOT="$(require_dsgsi_rootfs)"
  ABI_LIB64="$DSGSI_ABI_ROOT/system/lib64"
}

write_compat_headers() {
  mkdir -p "$REPO_ROOT/foreign/compat"

  cat > "$REPO_ROOT/foreign/compat/ApexProperties.sysprop.h" <<'EOF_APEX'
#pragma once
#include <optional>

namespace android::sysprop {

class ApexProperties final {
  public:
    static inline std::optional<bool> updatable() {
        return false;
    }
};

}  // namespace android::sysprop
EOF_APEX

  cat > "$REPO_ROOT/foreign/compat/InitProperties.sysprop.h" <<'EOF_INITPROP'
#pragma once
#include <optional>

namespace android::sysprop {

class InitProperties final {
  public:
    static inline std::optional<bool> is_userspace_reboot_supported() {
        return false;
    }

    static inline std::optional<bool> userspace_reboot_in_progress() {
        return false;
    }

    static inline bool userspace_reboot_in_progress(bool) {
        // RevA does not implement userspace reboot. Return true for setter-shaped
        // calls so that accidental call sites do not introduce a link dependency
        // on Soong-generated sysprop code. The feature gate above remains false.
        return true;
    }
};

}  // namespace android::sysprop
EOF_INITPROP

  cat > "$REPO_ROOT/foreign/compat/foreign_config.h" <<EOF_CONFIG
#pragma once
#define INNIT_FOREIGN_BUILD 1
#define INNIT_FOREIGN_API_LEVEL $API
#define INNIT_FOREIGN_SEPOLICY_VERSION $SEPOLICY_VERSION
EOF_CONFIG
}

write_stubs() {
  mkdir -p "$REPO_ROOT/foreign/stubs"

  cat > "$REPO_ROOT/foreign/stubs/first_stage_main_stub.cpp" <<'EOF_FIRST_STAGE'
#include "first_stage_init.h"

#include <android-base/logging.h>

namespace android::init {

int FirstStageMain(int, char**) {
    android::base::InitLogging(nullptr, &android::base::KernelLogger);
    LOG(FATAL) << "Innit RevA foreign build does not implement Android first-stage init";
    return 127;
}

}  // namespace android::init
EOF_FIRST_STAGE

  cat > "$REPO_ROOT/foreign/stubs/snapuserd_transition_stub.cpp" <<'EOF_SNAPUSERD'
#include "snapuserd_transition.h"

#include <memory>
#include <optional>

namespace android::init {

void LaunchFirstStageSnapuserd() {}

void SnapuserdSelinuxHelper::StartTransition() {}
void SnapuserdSelinuxHelper::FinishTransition() {}

std::unique_ptr<SnapuserdSelinuxHelper> SnapuserdSelinuxHelper::CreateIfNeeded() {
    return nullptr;
}

void CleanupSnapuserdSocket() {}
void KillFirstStageSnapuserd(pid_t) {}
void SaveRamdiskPathToSnapuserd() {}

bool IsFirstStageSnapuserdRunning() {
    return false;
}

std::optional<pid_t> GetSnapuserdFirstStagePid() {
    return std::nullopt;
}

}  // namespace android::init
EOF_SNAPUSERD

  cat > "$REPO_ROOT/foreign/stubs/lmkd_service_stub.cpp" <<'EOF_LMKD'
#include "lmkd_service.h"

#include <android-base/logging.h>

namespace android::init {

void LmkdRegister(const std::string& name, uid_t, pid_t, int) {
    LOG(VERBOSE) << "Innit foreign RevA: lmkd registration skipped for " << name;
}

void LmkdUnregister(const std::string& name, pid_t) {
    LOG(VERBOSE) << "Innit foreign RevA: lmkd unregistration skipped for " << name;
}

}  // namespace android::init
EOF_LMKD
}

write_gsi_fallback_if_needed() {
  [[ "$INNIT_ALLOW_GSI_STUB" == "1" ]] || return 0
  [[ -n "$ABI_LIB64" ]] || return 0
  [[ ! -e "$ABI_LIB64/libgsi.so" ]] || return 0

  warn "libgsi.so absent in DSGSI_ROOTFS; enabling local RevA gsi fallback"
  mkdir -p "$FALLBACK_INCLUDE_DIR/libgsi" "$GEN_DIR/fallback_src"

  cat > "$FALLBACK_INCLUDE_DIR/libgsi/libgsi.h" <<'EOF_GSI_H'
#pragma once

namespace android::gsi {

inline constexpr const char kGsiBootedProp[] = "ro.gsid.image_running";
inline constexpr const char kGsiInstalledProp[] = "gsid.image_installed";

bool IsGsiRunning();
bool IsGsiInstalled();

}  // namespace android::gsi
EOF_GSI_H

  cat > "$GEN_DIR/fallback_src/libgsi_stub.cpp" <<EOF_GSI_CPP
#include <libgsi/libgsi.h>

namespace android::gsi {

bool IsGsiRunning() {
#if $INNIT_ASSUME_GSI_RUNNING
    return true;
#else
    return false;
#endif
}

bool IsGsiInstalled() {
    return IsGsiRunning();
}

}  // namespace android::gsi
EOF_GSI_CPP
}

prepare() {
  ensure_repo_root
  refuse_android_product_env
  mkdir -p "$OUT_DIR" "$BUILD_DIR" "$OBJ_DIR" "$GEN_DIR"
  write_compat_headers
  write_stubs
  log "prepared foreign build tree under $REPO_ROOT/foreign"
}

generate_proto() {
  ensure_repo_root
  refuse_android_product_env
  require_cmd "$PROTOC"
  mkdir -p "$PROTO_SRC_DIR/system/core/init" "$PROTO_OUT_DIR"

  cp "$INIT_DIR/persistent_properties.proto" "$PROTO_SRC_DIR/system/core/init/"
  cp "$INIT_DIR/property_service.proto" "$PROTO_SRC_DIR/system/core/init/"
  cp "$INIT_DIR/subcontext.proto" "$PROTO_SRC_DIR/system/core/init/"

  "$PROTOC" \
    -I"$PROTO_SRC_DIR" \
    --cpp_out="$PROTO_OUT_DIR" \
    "$PROTO_SRC_DIR/system/core/init/persistent_properties.proto" \
    "$PROTO_SRC_DIR/system/core/init/property_service.proto" \
    "$PROTO_SRC_DIR/system/core/init/subcontext.proto"

  log "generated protobuf outputs under $PROTO_OUT_DIR"
}

build_include_flags() {
  INCLUDE_FLAGS=()

  add_existing_include INCLUDE_FLAGS "$FALLBACK_INCLUDE_DIR"
  add_existing_include INCLUDE_FLAGS "$REPO_ROOT/foreign/compat"
  add_existing_include INCLUDE_FLAGS "$PROTO_OUT_DIR"
  add_existing_include INCLUDE_FLAGS "$INIT_DIR"
  add_existing_include INCLUDE_FLAGS "$REPO_ROOT"

  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/libbase/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/logging/liblog/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libcutils/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libsystem/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocessgroup/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocessgroup/cgrouprc/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocessgroup/profiles/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libmodprobe/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocinfo/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/liblogwrap/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/bootloader_message/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/libdm/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/libfiemap/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/libfs_avb/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/libgsi/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/liblp/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/libsnapshot/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/property_service/libpropertyinfoparser/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/property_service/libpropertyinfoserializer/include"

  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/vold"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/vold/fscrypt"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/extras/ext4_utils/include"

  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/selinux/libselinux/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/tinyxml2"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/protobuf/src"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/libcap/libcap/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/avb/libavb"

  if [[ -n "${INNIT_EXTRA_INCLUDE_DIRS:-}" ]]; then
    local IFS=':'
    local d
    for d in $INNIT_EXTRA_INCLUDE_DIRS; do
      add_existing_include INCLUDE_FLAGS "$d"
    done
  fi
}

build_common_cflags() {
  COMMON_CFLAGS=(
    -DRECOVERY
    -DANDROID_INIT_INNIT
    -DINNIT_FOREIGN_BUILD
    -D__ANDROID_API__="$API"
    -DPLATFORM_SDK_VERSION="$API"
    -DSEPOLICY_VERSION="$SEPOLICY_VERSION"
    -DLOG_UEVENTS=0
    -DALLOW_FIRST_STAGE_CONSOLE=0
    -DALLOW_LOCAL_PROP_OVERRIDE=0
    -DALLOW_PERMISSIVE_SELINUX=1
    -DREBOOT_BOOTLOADER_ON_PANIC=0
    -DWORLD_WRITABLE_KMSG=0
    -DDUMP_ON_UMOUNT_FAILURE=0
    -DSHUTDOWN_ZERO_TIMEOUT=0
    -DINIT_FULL_SOURCES
    -D_GNU_SOURCE
    -include foreign_config.h
    -fPIE
    -ffunction-sections
    -fdata-sections
    -fvisibility=hidden
    -fno-strict-aliasing
    -Wall
    -Wextra
    -Wno-unused-parameter
    -Wno-c99-designator
    -Wno-missing-field-initializers
    -Wno-gnu-designator
  )

  CXXFLAGS=(
    "${COMMON_CFLAGS[@]}"
    -std=gnu++17
  )

  CFLAGS=(
    "${COMMON_CFLAGS[@]}"
    -std=gnu11
  )
}

sanitize_obj_name() {
  local src="$1"
  src="${src#$REPO_ROOT/}"
  printf '%s.o\n' "$(printf '%s' "$src" | sed 's#[/. -]#_#g')"
}

compile_source() {
  local src="$1"
  local obj="$OBJ_DIR/$(sanitize_obj_name "$src")"
  mkdir -p "$(dirname "$obj")"

  case "$src" in
    *.c)
      printf '%q ' "$CC" "${CFLAGS[@]}" "${INCLUDE_FLAGS[@]}" -c "$src" -o "$obj" >> "$BUILD_DIR/compile.commands"
      printf '\n' >> "$BUILD_DIR/compile.commands"
      "$CC" "${CFLAGS[@]}" "${INCLUDE_FLAGS[@]}" -c "$src" -o "$obj" >>"$BUILD_DIR/compile.log" 2>&1
      ;;
    *.cc|*.cpp|*.cxx)
      printf '%q ' "$CXX" "${CXXFLAGS[@]}" "${INCLUDE_FLAGS[@]}" -c "$src" -o "$obj" >> "$BUILD_DIR/compile.commands"
      printf '\n' >> "$BUILD_DIR/compile.commands"
      "$CXX" "${CXXFLAGS[@]}" "${INCLUDE_FLAGS[@]}" -c "$src" -o "$obj" >>"$BUILD_DIR/compile.log" 2>&1
      ;;
    *)
      die "unsupported source suffix: $src"
      ;;
  esac

  OBJECTS+=("$obj")
}

add_src() {
  local -n arr="$1"
  local p="$2"
  [[ -f "$p" ]] || die "source not found: $p"
  arr+=("$p")
}

add_src_if_exists() {
  local -n arr="$1"
  local p="$2"
  [[ -f "$p" ]] && arr+=("$p")
}

add_sources_from_dir_if_exists() {
  local -n arr="$1"
  local d="$2"
  local pattern="$3"
  [[ -d "$d" ]] || return 0
  while IFS= read -r -d '' f; do
    arr+=("$f")
  done < <(find "$d" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z)
}

init_sources() {
  INIT_SOURCES=()

  local common=(
    action.cpp
    action_manager.cpp
    action_parser.cpp
    capabilities.cpp
    epoll.cpp
    import_parser.cpp
    interface_utils.cpp
    keychords.cpp
    parser.cpp
    property_type.cpp
    rlimit_parser.cpp
    service.cpp
    service_list.cpp
    service_parser.cpp
    service_utils.cpp
    subcontext.cpp
    tokenizer.cpp
    util.cpp
  )

  local device=(
    block_dev_initializer.cpp
    bootchart.cpp
    builtins.cpp
    devices.cpp
    firmware_handler.cpp
    fscrypt_init_extensions.cpp
    init.cpp
    modalias_handler.cpp
    mount_handler.cpp
    mount_namespace.cpp
    persistent_properties.cpp
    property_service.cpp
    reboot.cpp
    reboot_utils.cpp
    security.cpp
    selabel.cpp
    selinux.cpp
    sigchld_handler.cpp
    switch_root.cpp
    uevent_listener.cpp
    ueventd.cpp
    ueventd_parser.cpp
  )

  local s
  for s in "${common[@]}" "${device[@]}"; do
    add_src INIT_SOURCES "$INIT_DIR/$s"
  done

  add_src INIT_SOURCES "$INIT_DIR/main.cpp"
  add_src INIT_SOURCES "$INIT_DIR/innit/innit_policy.cpp"
  add_src INIT_SOURCES "$REPO_ROOT/foreign/stubs/first_stage_main_stub.cpp"
  add_src INIT_SOURCES "$REPO_ROOT/foreign/stubs/snapuserd_transition_stub.cpp"
  add_src INIT_SOURCES "$REPO_ROOT/foreign/stubs/lmkd_service_stub.cpp"

  add_src_if_exists INIT_SOURCES "$GEN_DIR/fallback_src/libgsi_stub.cpp"

  while IFS= read -r -d '' f; do
    INIT_SOURCES+=("$f")
  done < <(find "$PROTO_OUT_DIR/system/core/init" -type f -name '*.pb.cc' -print0 2>/dev/null | sort -z)

  # Soong links these as static libraries. Foreign RevA compiles them directly
  # from the quarry when the source is available, avoiding Android product output.
  add_sources_from_dir_if_exists INIT_SOURCES "$QUARRY_DIR/system/core/property_service/libpropertyinfoparser" '*.cpp'
  add_sources_from_dir_if_exists INIT_SOURCES "$QUARRY_DIR/system/core/property_service/libpropertyinfoserializer" '*.cpp'

  # tinyxml2 may not exist in a recovery-derived /system/lib64. Compile it in
  # statically when absent.
  if [[ ! -e "$ABI_LIB64/libtinyxml2.so" ]]; then
    warn "libtinyxml2.so absent in DSGSI_ROOTFS; compiling tinyxml2.cpp into init"
    add_src INIT_SOURCES "$QUARRY_DIR/external/tinyxml2/tinyxml2.cpp"
  fi
}

policy_sources() {
  POLICY_SOURCES=()
  add_src POLICY_SOURCES "$INIT_DIR/innit/innit_policy.cpp"
  add_src POLICY_SOURCES "$INIT_DIR/innit/innit_policy_check_main.cpp"
  if [[ ! -e "$ABI_LIB64/libtinyxml2.so" ]]; then
    add_src POLICY_SOURCES "$QUARRY_DIR/external/tinyxml2/tinyxml2.cpp"
  fi
}

add_lib_flag_if_present() {
  local lib="$1"
  local required="${2:-0}"
  if [[ -e "$ABI_LIB64/lib${lib}.so" ]]; then
    LDLIBS+=("-l$lib")
  elif [[ "$required" == "1" ]]; then
    die "required ABI library missing: $ABI_LIB64/lib${lib}.so"
  fi
}

build_ldflags() {
  LDFLAGS=(
    -pie
    -Wl,--gc-sections
    -Wl,--no-undefined
    -Wl,--dynamic-linker,/system/bin/linker64
    -Wl,-z,relro
    -Wl,-z,now
    -Wl,--as-needed
    -L"$ABI_LIB64"
    -Wl,-rpath-link,"$ABI_LIB64"
    -nostdlib++
  )

  if [[ -n "${INNIT_EXTRA_LIB_DIRS:-}" ]]; then
    local IFS=':'
    local d
    for d in $INNIT_EXTRA_LIB_DIRS; do
      add_existing_libdir LDFLAGS "$d"
      [[ -d "$d" ]] && LDFLAGS+=("-Wl,-rpath-link,$d")
    done
  fi

  [[ -e "$ABI_LIB64/libc++.so" ]] || die "missing platform C++ runtime: $ABI_LIB64/libc++.so"

  LDLIBS=(
    "$ABI_LIB64/libc++.so"
  )

  add_lib_flag_if_present log 1
  add_lib_flag_if_present base 1
  add_lib_flag_if_present cutils 1
  add_lib_flag_if_present selinux 1
  add_lib_flag_if_present processgroup 1
  add_lib_flag_if_present processgroup_setup 1
  add_lib_flag_if_present fs_mgr 1
  add_lib_flag_if_present lp 1
  add_lib_flag_if_present ext4_utils 1
  add_lib_flag_if_present bootloader_message 1
  add_lib_flag_if_present logwrap 1
  add_lib_flag_if_present keyutils 1
  add_lib_flag_if_present protobuf-cpp-lite 1

  add_lib_flag_if_present tinyxml2 0
  add_lib_flag_if_present backtrace 0
  add_lib_flag_if_present gsi 0
  add_lib_flag_if_present modprobe 0
  add_lib_flag_if_present procinfo 0

  # libcap is a real runtime requirement of capabilities.cpp/reboot_utils.cpp.
  # Android Soong normally supplies it as a static whole library. In the foreign
  # build path it must either exist in the DSGSI ABI root or be supplied as an
  # explicit archive.
  if [[ -e "$ABI_LIB64/libcap.so" ]]; then
    LDLIBS+=("-lcap")
  elif [[ -n "${INNIT_LIBCAP_A:-}" && -e "$INNIT_LIBCAP_A" ]]; then
    LDLIBS+=("$INNIT_LIBCAP_A")
  else
    die "libcap is required. Provide $ABI_LIB64/libcap.so or set INNIT_LIBCAP_A=/path/to/libcap.a"
  fi

  LDLIBS+=(
    -ldl
    -lm
    -lc
  )

  if [[ -n "${INNIT_EXTRA_LDLIBS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra=( $INNIT_EXTRA_LDLIBS )
    LDLIBS+=("${extra[@]}")
  fi
}

compile_objects() {
  local -n sources_ref="$1"
  OBJECTS=()
  : > "$BUILD_DIR/compile.log"
  : > "$BUILD_DIR/compile.commands"

  local src
  for src in "${sources_ref[@]}"; do
    log "CC $src"
    compile_source "$src"
  done
}

link_binary() {
  local output="$1"
  mkdir -p "$(dirname "$output")"
  printf '%s\n' "${OBJECTS[@]}" > "$BUILD_DIR/objects.rsp"

  {
    printf '%q ' "$CXX" "${LDFLAGS[@]}" @"$BUILD_DIR/objects.rsp" "${LDLIBS[@]}" -o "$output"
    printf '\n'
  } > "$BUILD_DIR/link.command"

  log "LD $output"
  "$CXX" "${LDFLAGS[@]}" @"$BUILD_DIR/objects.rsp" "${LDLIBS[@]}" -o "$output" >"$BUILD_DIR/link.log" 2>&1 || {
    cat "$BUILD_DIR/link.log" >&2
    die "link failed; see $BUILD_DIR/link.log"
  }

  "$READELF_TOOL" -d "$output" > "$BUILD_DIR/$(basename "$output").dynamic.txt" || true
  "$NM_TOOL" -u "$output" > "$BUILD_DIR/$(basename "$output").undefined.txt" || true
}

build_policy_check() {
  prepare
  ensure_quarry
  setup_tools
  setup_abi
  write_gsi_fallback_if_needed
  build_include_flags
  build_common_cflags
  build_ldflags
  policy_sources
  compile_objects POLICY_SOURCES
  link_binary "$STAGING_SYSTEM_DIR/bin/innit-policy-check"
  log "built $STAGING_SYSTEM_DIR/bin/innit-policy-check"
}

build_init() {
  prepare
  ensure_quarry
  generate_proto
  setup_tools
  setup_abi
  write_gsi_fallback_if_needed
  build_include_flags
  build_common_cflags
  build_ldflags
  init_sources
  compile_objects INIT_SOURCES
  link_binary "$STAGING_SYSTEM_DIR/bin/init"
  ln -sfn init "$STAGING_SYSTEM_DIR/bin/ueventd"
  log "built $STAGING_SYSTEM_DIR/bin/init"
}

clean() {
  ensure_repo_root
  rm -rf "$OUT_DIR" "$GEN_DIR"
  log "removed $OUT_DIR and $GEN_DIR"
}

cmd="${1:-all}"
case "$cmd" in
  all)
    build_policy_check
    build_init
    "$SCRIPT_DIR/check-abi.sh" --binary "$STAGING_SYSTEM_DIR/bin/init"
    "$SCRIPT_DIR/package.sh" --binary "$STAGING_SYSTEM_DIR/bin/init"
    ;;
  prepare) prepare ;;
  proto) prepare; generate_proto ;;
  policy-check) build_policy_check ;;
  init) build_init ;;
  check-abi) "$SCRIPT_DIR/check-abi.sh" --binary "$STAGING_SYSTEM_DIR/bin/init" ;;
  package) "$SCRIPT_DIR/package.sh" --binary "$STAGING_SYSTEM_DIR/bin/init" ;;
  clean) clean ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac
