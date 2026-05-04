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

Configuration:
  foreign/build.sh sources foreign/config/local.env when present.

Important variables emitted by foreign/tools/innit-menuconfig:
  INNIT_ROOT=/path/to/android_system_core_innit_init_only
  AOSP_QUARRY=/path/to/sparse/aosp/quarry
  RECOVERY_SYSTEM=/path/to/dsgsi/staging/root/system
  RECOVERY_LIB=/path/to/dsgsi/staging/root/system/lib64
  NDK_ROOT=/path/to/android-ndk
  NDK_PREBUILT=/path/to/android-ndk/toolchains/llvm/prebuilt/<host-tag>
  NDK_CC=/path/to/<triple><api>-clang
  NDK_CXX=/path/to/<triple><api>-clang++
  ANDROID_API=31
  TARGET_TRIPLE=aarch64-linux-android
  OUT_DIR=/path/to/repo/foreign/out/aarch64
  INIT_OUTPUT=/path/to/repo/foreign/out/aarch64/init.innit

Compatibility aliases still accepted:
  NDK=/path/to/android-ndk
  API=31
  TRIPLE=aarch64-linux-android
  QUARRY_DIR=/path/to/quarry
  DSGSI_ROOTFS=/path/to/dsgsi/staging/root

Optional:
  LOCAL_ENV=/path/to/local.env          Override local.env path
  PROTOC=protoc                         Host protoc executable
  SEPOLICY_VERSION=30                   Foreign replacement for Soong selinux_policy_version
  INNIT_LIBCAP_A=/path/libcap.a         Use when RECOVERY_LIB has no libcap.so
  INNIT_ALLOW_GSI_STUB=1                Allow local libgsi fallback if libgsi.so is absent. Default: 1
  INNIT_ASSUME_GSI_RUNNING=1            Return true from fallback IsGsiRunning(). Default: 1
  INNIT_EXTRA_INCLUDE_DIRS="a:b"       Extra target include dirs
  INNIT_EXTRA_LIB_DIRS="a:b"           Extra target library dirs
  INNIT_EXTRA_LDLIBS="-lfoo ..."       Extra linker flags

EOF_USAGE
}


LOCAL_ENV="${LOCAL_ENV:-$REPO_ROOT/foreign/config/local.env}"

load_local_env() {
  [[ -f "$LOCAL_ENV" ]] || return 0
  # shellcheck disable=SC1090
  source "$LOCAL_ENV"
}

normalize_menuconfig_env() {
  if [[ -n "${INNIT_ROOT:-}" ]]; then
    local configured_root
    configured_root="$(abs_path "$INNIT_ROOT")"
    if [[ "$configured_root" != "$REPO_ROOT" ]]; then
      warn "local.env INNIT_ROOT differs from script repo root"
      warn "  INNIT_ROOT=$configured_root"
      warn "  script root=$REPO_ROOT"
      warn "using script root; run innit-menuconfig from this checkout if this is wrong"
    fi
  fi

  if [[ -n "${AOSP_QUARRY:-}" ]]; then
    QUARRY_DIR="$(abs_path "$AOSP_QUARRY")"
  fi

  if [[ -n "${NDK_ROOT:-}" ]]; then
    NDK="$NDK_ROOT"
  fi

  if [[ -n "${ANDROID_API:-}" ]]; then
    API="$ANDROID_API"
  fi

  if [[ -n "${TARGET_TRIPLE:-}" ]]; then
    TRIPLE="$TARGET_TRIPLE"
  fi

  if [[ -n "${OUT_DIR:-}" ]]; then
    OUT_DIR="$(abs_path "$OUT_DIR")"
  fi

  if [[ -z "${INIT_OUTPUT:-}" ]]; then
    INIT_OUTPUT="$OUT_DIR/init.innit"
  else
    INIT_OUTPUT="$(abs_path "$INIT_OUTPUT")"
  fi

  if [[ -n "${RECOVERY_SYSTEM:-}" ]]; then
    RECOVERY_SYSTEM="$(abs_path "$RECOVERY_SYSTEM")"
  fi

  if [[ -n "${RECOVERY_LIB:-}" ]]; then
    RECOVERY_LIB="$(abs_path "$RECOVERY_LIB")"
  fi

  if [[ -z "${RECOVERY_LIB:-}" && -n "${RECOVERY_SYSTEM:-}" ]]; then
    RECOVERY_LIB="$RECOVERY_SYSTEM/${RECOVERY_LIBDIR:-lib64}"
  fi

  if [[ -z "${DSGSI_ROOTFS:-}" && -n "${RECOVERY_SYSTEM:-}" && "$(basename "$RECOVERY_SYSTEM")" == "system" ]]; then
    local maybe_root
    maybe_root="$(dirname "$RECOVERY_SYSTEM")"
    if [[ -d "$maybe_root/system/${RECOVERY_LIBDIR:-lib64}" ]]; then
      DSGSI_ROOTFS="$maybe_root"
    fi
  fi

  export NDK API TRIPLE QUARRY_DIR OUT_DIR INIT_OUTPUT
  export RECOVERY_SYSTEM RECOVERY_LIB DSGSI_ROOTFS
}

load_local_env
normalize_menuconfig_env

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
POLICY_CHECK_OUTPUT="$OUT_DIR/innit-policy-check"

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
  [[ -d "$QUARRY_DIR/system/core/fs_mgr/include_fstab" ]] || die "quarry missing system/core/fs_mgr/include_fstab; add fs_mgr/include_fstab to the system/core quarry"
  [[ -f "$QUARRY_DIR/system/core/fs_mgr/libsnapshot/android/snapshot/snapshot.proto" ]] || die "quarry missing system/core/fs_mgr/libsnapshot/android/snapshot/snapshot.proto; add fs_mgr/libsnapshot/android/snapshot to the quarry"
  [[ -f "$QUARRY_DIR/system/update_engine/update_metadata.proto" ]] || die "quarry missing system/update_engine/update_metadata.proto; add system/update_engine to the quarry"
  [[ -f "$QUARRY_DIR/system/core/libkeyutils/include/keyutils.h" ]] || die "quarry missing system/core/libkeyutils/include/keyutils.h; add system/core/libkeyutils to the quarry"
  [[ -f "$QUARRY_DIR/system/core/libprocessgroup/setup/include/processgroup/setup.h" ]] || die "quarry missing system/core/libprocessgroup/setup/include/processgroup/setup.h; add system/core/libprocessgroup/setup to the quarry"
  [[ -f "$QUARRY_DIR/system/unwinding/libbacktrace/include/backtrace/Backtrace.h" ]] || die "quarry missing system/unwinding/libbacktrace/include/backtrace/Backtrace.h; add system/unwinding/libbacktrace to the quarry"
  [[ -f "$QUARRY_DIR/system/logging/logwrapper/include/logwrap/logwrap.h" ]] || die "quarry missing system/logging/logwrapper/include/logwrap/logwrap.h; add system/logging/logwrapper to the quarry"
  [[ -d "$QUARRY_DIR/bootable/recovery/bootloader_message/include" ]] || die "quarry missing bootable/recovery/bootloader_message/include; add platform/bootable/recovery/bootloader_message to the quarry"
  [[ -d "$QUARRY_DIR/system/extras/libfscrypt/include" ]] || die "quarry missing system/extras/libfscrypt/include; add system/extras/libfscrypt to the quarry"
  [[ -d "$QUARRY_DIR/external/protobuf/src" ]] || die "quarry missing external/protobuf/src; run foreign/quarry.sh sync"
  [[ -d "$QUARRY_DIR/external/fmtlib/include" ]] || die "quarry missing external/fmtlib/include; fetch platform/external/fmtlib at android-12.0.0_r8"
  [[ -f "$QUARRY_DIR/external/avb/libavb/libavb.h" ]] || die "quarry missing external/avb/libavb/libavb.h; add external/avb/libavb to the quarry"
}

if ! declare -F resolve_ndk_api_for_prebuilt >/dev/null 2>&1; then
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
    warn "requested Android API $requested_api is not available for $triple in this NDK; using API $best wrapper"
    printf '%s\n' "$best"
    return 0
  fi

  return 1
}
fi


setup_tools() {
  if [[ -n "${NDK_ROOT:-}" && -z "${NDK:-}" ]]; then
    NDK="$NDK_ROOT"
  fi

  # innit-menuconfig may emit any of these shapes:
  #   NDK_ROOT=/path/to/ndk
  #   NDK_ROOT=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64
  #   NDK_ROOT=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
  #   NDK_PREBUILT=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64
  #   NDK_PREBUILT=/path/to/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
  #
  # Prefer direct prebuilt normalization first. Do not call find_ndk_toolchain
  # until after these cases are exhausted, because find_ndk_toolchain may still
  # validate the requested API wrapper too early.
  if [[ -n "${NDK_PREBUILT:-}" ]]; then
    if TC="$(normalize_ndk_prebuilt_path "$NDK_PREBUILT")"; then
      :
    else
      warn "NDK_PREBUILT is not directly usable; falling back to NDK_ROOT/NDK normalization: $NDK_PREBUILT"
      TC=""
    fi
  fi

  if [[ -z "${TC:-}" && -n "${NDK_ROOT:-}" ]]; then
    if TC="$(normalize_ndk_prebuilt_path "$NDK_ROOT")"; then
      :
    else
      TC=""
    fi
  fi

  if [[ -z "${TC:-}" && -n "${NDK:-}" ]]; then
    if TC="$(normalize_ndk_prebuilt_path "$NDK")"; then
      :
    else
      TC=""
    fi
  fi

  if [[ -z "${TC:-}" && ( -n "${NDK_ROOT:-}" || -n "${NDK:-}" ) ]]; then
    : "${NDK:?set NDK_ROOT in foreign/config/local.env or export NDK=/path/to/android-ndk}"
    TC="$(find_ndk_toolchain)"
  elif [[ -z "${TC:-}" ]]; then
    die "set NDK_ROOT in foreign/config/local.env or export NDK=/path/to/android-ndk"
  fi

  local requested_api="$API"
  local resolved_api
  if ! resolved_api="$(resolve_ndk_api_for_prebuilt "$TC" "$TRIPLE" "$requested_api")"; then
    die "could not find any ${TRIPLE}<api>-clang++ wrapper under $TC/bin for requested API $requested_api"
  fi

  API="$resolved_api"
  ANDROID_API="$resolved_api"
  export API ANDROID_API

  CC="${NDK_CC:-$TC/bin/${TRIPLE}${API}-clang}"
  CXX="${NDK_CXX:-$TC/bin/${TRIPLE}${API}-clang++}"
  AR="${NDK_AR:-$TC/bin/llvm-ar}"
  READELF_TOOL="${READELF:-$TC/bin/llvm-readelf}"
  NM_TOOL="${NM:-$TC/bin/llvm-nm}"

  [[ -x "$CC" ]] || die "missing target C compiler: $CC"
  [[ -x "$CXX" ]] || die "missing target C++ compiler: $CXX"
  [[ -x "$AR" ]] || die "missing llvm-ar: $AR"
  [[ -x "$READELF_TOOL" ]] || die "missing llvm-readelf: $READELF_TOOL"
  [[ -x "$NM_TOOL" ]] || die "missing llvm-nm: $NM_TOOL"
}


setup_abi() {
  if [[ -n "${RECOVERY_LIB:-}" ]]; then
    ABI_LIB64="$RECOVERY_LIB"
    DSGSI_ABI_ROOT="${RECOVERY_SYSTEM:-$(dirname "$ABI_LIB64")}"
  elif [[ -n "${RECOVERY_SYSTEM:-}" ]]; then
    DSGSI_ABI_ROOT="$RECOVERY_SYSTEM"
    ABI_LIB64="$RECOVERY_SYSTEM/${RECOVERY_LIBDIR:-lib64}"
  else
    DSGSI_ABI_ROOT="$(require_dsgsi_rootfs)"
    ABI_LIB64="$DSGSI_ABI_ROOT/system/${RECOVERY_LIBDIR:-lib64}"
  fi

  [[ -d "$ABI_LIB64" ]] || die "recovery ABI library directory is missing: $ABI_LIB64"

  if [[ -n "${RECOVERY_SYSTEM:-}" && ! -e "$RECOVERY_SYSTEM/bin/linker64" ]]; then
    warn "recovery system linker not found at $RECOVERY_SYSTEM/bin/linker64"
    warn "link will still use runtime interpreter /system/bin/linker64"
  fi
}

write_compat_headers() {
  mkdir -p "$REPO_ROOT/foreign/compat"

  cat > "$REPO_ROOT/foreign/compat/ApexProperties.sysprop.h" <<'EOF_APEX'
#pragma once
#include <optional>

namespace android::sysprop::ApexProperties {

static inline std::optional<bool> updatable() {
    return false;
}

}  // namespace android::sysprop::ApexProperties
EOF_APEX

  cat > "$REPO_ROOT/foreign/compat/InitProperties.sysprop.h" <<'EOF_INITPROP'
#pragma once
#include <optional>

namespace android::sysprop::InitProperties {

static inline std::optional<bool> is_userspace_reboot_supported() {
    return false;
}

static inline std::optional<bool> userspace_reboot_in_progress() {
    return false;
}

static inline bool userspace_reboot_in_progress(bool) {
    // RevA does not implement userspace reboot. Return true for setter-shaped
    // calls so accidental call sites do not introduce a dependency on
    // Soong-generated sysprop code. The feature gate above remains false.
    return true;
}

}  // namespace android::sysprop::InitProperties
EOF_INITPROP

  cat > "$REPO_ROOT/foreign/compat/foreign_config.h" <<EOF_CONFIG
#pragma once
#define INNIT_FOREIGN_BUILD 1
#define INNIT_FOREIGN_API_LEVEL $API
#define INNIT_FOREIGN_SEPOLICY_VERSION $SEPOLICY_VERSION
#define INNIT_FOREIGN_STUB_HIDL_UTIL 1
EOF_CONFIG

  mkdir -p "$REPO_ROOT/foreign/compat/hidl-util"

  cat > "$REPO_ROOT/foreign/compat/hidl-util/FQName.h" <<'EOF_FQNAME'
#pragma once

#include <string>
#include <utility>

namespace android {

// Minimal foreign-build stand-in for system/tools/hidl's FQName.
//
// It intentionally implements only the subset used by Android init:
//   - FQName::parse(...)
//   - isFullyQualified()
//   - isValidValueName()
//   - string()
//   - ordering/equality for std::set/std::map
//
// Accepted form:
//   package.name@major.minor::IInterface
// Optional value-name form:
//   package.name@major.minor::IInterface.ValueName
class FQName {
  public:
    FQName() = default;

    explicit FQName(std::string raw) {
        FQName parsed;
        if (parse(raw, &parsed)) {
            *this = std::move(parsed);
        } else {
            raw_ = std::move(raw);
        }
    }

    FQName(std::string package, std::string version, std::string name = "",
            std::string value_name = "")
        : package_(std::move(package)),
          version_(std::move(version)),
          name_(std::move(name)),
          value_name_(std::move(value_name)) {}

    static bool parse(const std::string& raw, FQName* out) {
        if (out == nullptr || raw.empty()) return false;

        const std::size_t at = raw.find('@');
        const std::size_t sep = raw.find("::");

        if (at == std::string::npos) return false;
        if (sep == std::string::npos) return false;
        if (at == 0) return false;
        if (sep <= at + 1) return false;
        if (sep + 2 >= raw.size()) return false;

        std::string package = raw.substr(0, at);
        std::string version = raw.substr(at + 1, sep - at - 1);
        std::string type_and_value = raw.substr(sep + 2);

        if (package.empty() || version.empty() || type_and_value.empty()) {
            return false;
        }

        std::string name = type_and_value;
        std::string value_name;

        const std::size_t value_sep = type_and_value.find('.');
        if (value_sep != std::string::npos) {
            name = type_and_value.substr(0, value_sep);
            value_name = type_and_value.substr(value_sep + 1);
            if (name.empty() || value_name.empty()) return false;
        }

        if (name.empty()) return false;

        out->raw_.clear();
        out->package_ = std::move(package);
        out->version_ = std::move(version);
        out->name_ = std::move(name);
        out->value_name_ = std::move(value_name);
        return true;
    }

    const std::string& package() const { return package_; }
    const std::string& version() const { return version_; }
    const std::string& name() const { return name_; }
    const std::string& valueName() const { return value_name_; }

    bool isFullyQualified() const {
        return !package_.empty() && !version_.empty() && !name_.empty();
    }

    bool isValidValueName() const {
        return isFullyQualified() && !value_name_.empty();
    }

    std::string string() const {
        if (!raw_.empty()) return raw_;

        std::string out = package_;
        if (!version_.empty()) out += "@" + version_;
        if (!name_.empty()) out += "::" + name_;
        if (!value_name_.empty()) out += "." + value_name_;
        return out;
    }

    bool operator<(const FQName& other) const {
        return string() < other.string();
    }

    bool operator==(const FQName& other) const {
        return string() == other.string();
    }

    bool operator!=(const FQName& other) const {
        return !(*this == other);
    }

  private:
    std::string raw_;
    std::string package_;
    std::string version_;
    std::string name_;
    std::string value_name_;
};

}  // namespace android
EOF_FQNAME

  cat > "$REPO_ROOT/foreign/compat/hidl-util/FqInstance.h" <<'EOF_FQINSTANCE'
#pragma once

#include <string>
#include <utility>

#include <hidl-util/FQName.h>

namespace android {

// Minimal foreign-build stand-in for system/tools/hidl's FqInstance.
//
// Accepted form:
//   android.hardware.foo@1.0::IFoo/default
class FqInstance {
  public:
    FqInstance() = default;

    bool setTo(const std::string& s) {
        const auto slash = s.find('/');
        const std::string iface = slash == std::string::npos ? s : s.substr(0, slash);

        FQName parsed;
        if (!FQName::parse(iface, &parsed)) return false;

        fq_name_ = std::move(parsed);
        instance_ = slash == std::string::npos ? std::string() : s.substr(slash + 1);
        return true;
    }

    const FQName& getFqName() const {
        return fq_name_;
    }

    const std::string& getInstance() const {
        return instance_;
    }

  private:
    FQName fq_name_;
    std::string instance_;
};

}  // namespace android
EOF_FQINSTANCE
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

  local real_gsi_header="$QUARRY_DIR/system/core/fs_mgr/libgsi/include/libgsi/libgsi.h"
  local need_header=0
  local need_stub_cpp=0

  if [[ ! -f "$real_gsi_header" ]]; then
    need_header=1
  fi

  if [[ ! -e "$ABI_LIB64/libgsi.so" ]]; then
    need_header=1
    need_stub_cpp=1
  fi

  [[ "$need_header" == "1" ]] || return 0

  if [[ "$need_stub_cpp" == "1" ]]; then
    warn "libgsi.so absent from recovery ABI; enabling local RevA gsi fallback"
  else
    warn "libgsi header absent from quarry; generating local RevA libgsi header shim"
  fi

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

  if [[ "$need_stub_cpp" == "1" ]]; then
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
  else
    rm -f "$GEN_DIR/fallback_src/libgsi_stub.cpp"
  fi
}


write_libcap_fallback_headers() {
  mkdir -p "$GEN_DIR/libcap"

  cat > "$GEN_DIR/libcap/cap_names.h" <<'EOF_CAP_NAMES'
#pragma once

/*
 * Foreign RevA libcap shim.
 *
 * Android's external/libcap normally generates cap_names.h through Soong using
 * generate_cap_names_list.awk and _makenames. cap_alloc.c still needs
 * __CAP_BITS for cap_max_bits() even when cap_text.c is not compiled.
 *
 * Linux 4.9+ kernels, including the Android kernels relevant to this project,
 * define capabilities through CAP_AUDIT_READ == 37, so the generated value is
 * CAP_LAST_CAP + 1 == 38 on modern Android trees. If the NDK/kernel headers
 * expose CAP_LAST_CAP, derive it from there; otherwise fall back to 38.
 */

#include <linux/capability.h>

#ifdef CAP_LAST_CAP
#define __CAP_BITS (CAP_LAST_CAP + 1)
#else
#define __CAP_BITS 38
#endif

#ifdef LIBCAP_PLEASE_INCLUDE_ARRAY
/*
 * RevA does not compile cap_text.c, so no code should require the textual
 * capability-name table. Provide a correctly-sized null table anyway, in case
 * some internal object is later added by mistake.
 */
static const char *_cap_names[__CAP_BITS] = { 0 };
#endif
EOF_CAP_NAMES
}


write_protobuf_target_config_headers() {
  mkdir -p "$GEN_DIR/protobuf_config"

  cat > "$GEN_DIR/protobuf_config/config.h" <<'EOF_PROTOBUF_CONFIG_H'
#pragma once

/*
 * Foreign RevA target protobuf config shim.
 *
 * Android external/protobuf's common.cc includes "config.h". Soong normally
 * arranges the generated/configured header environment. In the foreign NDK
 * build we provide the tiny subset needed by protobuf-lite.
 */
#define HAVE_PTHREAD 1
#define HAVE_ZLIB 0
EOF_PROTOBUF_CONFIG_H
}


write_fs_mgr_foreign_stubs() {
  cat > "$REPO_ROOT/foreign/stubs/fs_mgr_foreign_stub.cpp" <<'EOF_FSMGR_STUB'
#include <set>
#include <string>
#include <vector>

#include <fstab/fstab.h>
#include <fs_avb/fs_avb.h>

// RevA fs_mgr boundary shim.
//
// Do not link recovery/platform libfs_mgr.so into NDK-compiled Innit objects:
// fs_mgr exposes C++ STL types, so that crosses the platform/NDK libc++ ABI
// boundary. RevA runs after stock Android first-stage init has already mounted
// the DSU/GSI root. Therefore Android second-stage mount_all support is
// intentionally inert here until we decide to compile a full NDK-side fs_mgr.

namespace android::fs_mgr {

bool ReadDefaultFstab(Fstab* fstab) {
    if (fstab) fstab->clear();
    return false;
}

bool ReadFstabFromFile(const std::string&, Fstab* fstab) {
    if (fstab) fstab->clear();
    return false;
}

FstabEntry* GetEntryForMountPoint(Fstab*, const std::string&) {
    return nullptr;
}

bool SkipMountingPartitions(Fstab*, bool) {
    return true;
}

std::set<std::string> GetBootDevices() {
    return {};
}

bool AvbHandle::IsDeviceUnlocked() {
    return true;
}

}  // namespace android::fs_mgr

std::string fs_mgr_get_slot_suffix() {
    return {};
}

int fs_mgr_mount_all(android::fs_mgr::Fstab*, int) {
    return -1;
}

int fs_mgr_umount_all(android::fs_mgr::Fstab*) {
    return -1;
}

int fs_mgr_remount_userdata_into_checkpointing(android::fs_mgr::Fstab*) {
    return -1;
}

int fs_mgr_swapon_all(const android::fs_mgr::Fstab&) {
    return -1;
}

bool fs_mgr_update_logical_partition(android::fs_mgr::FstabEntry*) {
    return false;
}

bool fs_mgr_do_mount_one(const android::fs_mgr::FstabEntry&, const std::string&) {
    return false;
}

bool fs_mgr_is_verity_enabled(const android::fs_mgr::FstabEntry&) {
    return false;
}

std::string fs_mgr_get_hashtree_algorithm(const android::fs_mgr::FstabEntry&) {
    return {};
}

int fs_mgr_load_verity_state(int* mode) {
    if (mode) *mode = 0;
    return 0;
}

int fs_mgr_vendor_overlay_mount_all() {
    return 0;
}
EOF_FSMGR_STUB
}


write_reva_boundary_stubs() {
  cat > "$REPO_ROOT/foreign/stubs/reva_boundary_stubs.cpp" <<'EOF_REVA_BOUNDARY_STUBS'
#include <string>
#include <vector>

#include <bootloader_message/bootloader_message.h>
#include <fscrypt/fscrypt.h>
#include <libdm/dm.h>
#include <libsnapshot/snapshot.h>
#include <modprobe/modprobe.h>

bool fscrypt_is_native() {
    return false;
}

bool write_reboot_bootloader(std::string* err) {
    if (err) *err = "Innit RevA: write_reboot_bootloader is stubbed";
    return false;
}

bool read_bootloader_message(bootloader_message* boot, std::string* err) {
    if (boot) *boot = {};
    if (err) *err = "Innit RevA: read_bootloader_message is stubbed";
    return false;
}

bool write_bootloader_message(const bootloader_message&, std::string* err) {
    if (err) *err = "Innit RevA: write_bootloader_message(struct) is stubbed";
    return false;
}

bool write_bootloader_message(const std::vector<std::string>&, std::string* err) {
    if (err) *err = "Innit RevA: write_bootloader_message(args) is stubbed";
    return false;
}

namespace android::fscrypt {

bool ParseOptions(const std::string&, EncryptionOptions* options) {
    if (options) *options = {};
    return false;
}

bool EnsurePolicy(const EncryptionPolicy&, const std::string&) {
    return true;
}

void BytesToHex(const std::string& bytes, std::string* hex) {
    static constexpr char kHex[] = "0123456789abcdef";
    if (!hex) return;

    hex->clear();
    hex->reserve(bytes.size() * 2);

    for (unsigned char c : bytes) {
        hex->push_back(kHex[c >> 4]);
        hex->push_back(kHex[c & 0x0f]);
    }
}

}  // namespace android::fscrypt

Modprobe::Modprobe(const std::vector<std::string>&, std::string, bool) {}

bool Modprobe::LoadWithAliases(const std::string&, bool, const std::string&) {
    return false;
}

namespace android::dm {

DeviceMapper& DeviceMapper::Instance() {
    alignas(DeviceMapper) static unsigned char storage[sizeof(DeviceMapper)] = {};
    return *reinterpret_cast<DeviceMapper*>(storage);
}

bool DeviceMapper::GetDmDevicePathByName(const std::string&, std::string* path) {
    if (path) path->clear();
    return false;
}

}  // namespace android::dm

namespace android::snapshot {

std::string SnapshotManager::GetGlobalRollbackIndicatorPath() {
    return {};
}

// Do not define SnapshotManager::~SnapshotManager() as a normal C++ method.
// Doing so emits SnapshotManager's vtable and pulls in the full libsnapshot
// virtual method surface. RevA never constructs a real SnapshotManager; this
// only satisfies references emitted by default_delete / delete paths.
//
// Itanium C++ ABI destructor variants:
//   D0 = deleting destructor
//   D1 = complete object destructor
//   D2 = base object destructor
extern "C" void reva_snapshot_manager_d0(SnapshotManager*) __asm__("_ZN7android8snapshot15SnapshotManagerD0Ev");
extern "C" void reva_snapshot_manager_d1(SnapshotManager*) __asm__("_ZN7android8snapshot15SnapshotManagerD1Ev");
extern "C" void reva_snapshot_manager_d2(SnapshotManager*) __asm__("_ZN7android8snapshot15SnapshotManagerD2Ev");

extern "C" void reva_snapshot_manager_d0(SnapshotManager*) {}
extern "C" void reva_snapshot_manager_d1(SnapshotManager*) {}
extern "C" void reva_snapshot_manager_d2(SnapshotManager*) {}

}  // namespace android::snapshot
EOF_REVA_BOUNDARY_STUBS
}


prepare() {
  ensure_repo_root
  refuse_android_product_env
  mkdir -p "$OUT_DIR" "$BUILD_DIR" "$OBJ_DIR" "$GEN_DIR"
  write_compat_headers
  write_stubs
  write_fs_mgr_foreign_stubs
  write_reva_boundary_stubs
  write_libcap_fallback_headers
  write_protobuf_target_config_headers
  log "prepared foreign build tree under $REPO_ROOT/foreign"
}

select_protoc() {
  # Priority:
  #   1. explicit PROTOC from local.env/environment
  #   2. repo-local foreign/host-tools/protoc
  #   3. PATH protoc only when explicitly allowed
  #
  # Do not fetch Android prebuilts/build-tools for this. That repository is far
  # too large for one host-side generator.

  local candidate=""

  if [[ -n "${PROTOC:-}" && "$PROTOC" != "protoc" ]]; then
    candidate="$(abs_path "$PROTOC")"
    [[ -x "$candidate" ]] || die "configured PROTOC is not executable: $candidate"
    PROTOC_BIN="$candidate"
    log "using configured protoc: $PROTOC_BIN"
    return 0
  fi

  candidate="$REPO_ROOT/foreign/host-tools/protoc"
  if [[ -x "$candidate" ]]; then
    PROTOC_BIN="$candidate"
    log "using repo-local protoc: $PROTOC_BIN"
    return 0
  fi

  if [[ "${INNIT_ALLOW_HOST_PROTOC:-0}" == "1" ]]; then
    require_cmd "${PROTOC:-protoc}"
    PROTOC_BIN="$(command -v "${PROTOC:-protoc}")"
    warn "using host protoc: $PROTOC_BIN"
    warn "host protoc may be incompatible with Android 12 external/protobuf headers"
    return 0
  fi

  die "no compatible protoc found. Run foreign/build-host-protoc.sh, set PROTOC=/path/to/protoc-3.9.1, or set INNIT_ALLOW_HOST_PROTOC=1 to risk host protoc"
}


validate_generated_proto_headers() {
  local version_header="$QUARRY_DIR/external/protobuf/src/google/protobuf/stubs/common.h"
  local quarry_version
  local quarry_min_protoc

  quarry_version="$(
    awk '/#define GOOGLE_PROTOBUF_VERSION / { print $3; exit }' "$version_header"
  )"

  quarry_min_protoc="$(
    awk '/#define GOOGLE_PROTOBUF_MIN_PROTOC_VERSION / { print $3; exit }' "$version_header"
  )"

  [[ "$quarry_version" =~ ^[0-9]+$ ]] || die "could not read GOOGLE_PROTOBUF_VERSION from $version_header"
  [[ "$quarry_min_protoc" =~ ^[0-9]+$ ]] || die "could not read GOOGLE_PROTOBUF_MIN_PROTOC_VERSION from $version_header"

  local bad=0
  local h required_header generator_version

  while IFS= read -r -d '' h; do
    required_header="$(
      awk '/#if GOOGLE_PROTOBUF_VERSION < [0-9]+/ { print $4; exit }' "$h"
    )"

    generator_version="$(
      awk '/#if [0-9]+ < GOOGLE_PROTOBUF_MIN_PROTOC_VERSION/ { print $2; exit }' "$h"
    )"

    if [[ -n "$required_header" && "$required_header" =~ ^[0-9]+$ ]]; then
      if (( quarry_version < required_header )); then
        bad=1
        printf '[innit-foreign][fatal] protobuf header too old for generated file: %s
' "$h" >&2
        printf '[innit-foreign][fatal]   quarry GOOGLE_PROTOBUF_VERSION=%s required>=%s
' "$quarry_version" "$required_header" >&2
      fi
    fi

    if [[ -n "$generator_version" && "$generator_version" =~ ^[0-9]+$ ]]; then
      if (( generator_version < quarry_min_protoc )); then
        bad=1
        printf '[innit-foreign][fatal] generated protobuf file too old for quarry headers: %s
' "$h" >&2
        printf '[innit-foreign][fatal]   generator=%s quarry GOOGLE_PROTOBUF_MIN_PROTOC_VERSION=%s
' "$generator_version" "$quarry_min_protoc" >&2
      fi
    fi
  done < <(find "$PROTO_OUT_DIR" -type f -name '*.pb.h' -print0 2>/dev/null)

  [[ "$bad" == "0" ]] || die "generated protobuf code is incompatible with quarry external/protobuf headers"

  log "validated generated protobuf headers against quarry protobuf $quarry_version"
}



generate_proto() {
  ensure_repo_root
  refuse_android_product_env
  select_protoc
  mkdir -p "$PROTO_SRC_DIR/system/core/init" "$PROTO_SRC_DIR/android/snapshot" "$PROTO_SRC_DIR/update_engine" "$PROTO_OUT_DIR"

  rm -rf "$PROTO_OUT_DIR/system/core/init" "$PROTO_OUT_DIR/android/snapshot" "$PROTO_OUT_DIR/update_engine"
  mkdir -p "$PROTO_OUT_DIR"

  cp "$INIT_DIR/persistent_properties.proto" "$PROTO_SRC_DIR/system/core/init/"
  cp "$INIT_DIR/property_service.proto" "$PROTO_SRC_DIR/system/core/init/"
  cp "$INIT_DIR/subcontext.proto" "$PROTO_SRC_DIR/system/core/init/"
  cp "$QUARRY_DIR/system/core/fs_mgr/libsnapshot/android/snapshot/snapshot.proto" \
    "$PROTO_SRC_DIR/android/snapshot/"
  cp "$QUARRY_DIR/system/update_engine/update_metadata.proto" \
    "$PROTO_SRC_DIR/update_engine/"

  "$PROTOC_BIN" \
    -I"$PROTO_SRC_DIR" \
    --cpp_out="$PROTO_OUT_DIR" \
    "$PROTO_SRC_DIR/system/core/init/persistent_properties.proto" \
    "$PROTO_SRC_DIR/system/core/init/property_service.proto" \
    "$PROTO_SRC_DIR/system/core/init/subcontext.proto" \
    "$PROTO_SRC_DIR/android/snapshot/snapshot.proto" \
    "$PROTO_SRC_DIR/update_engine/update_metadata.proto"

  validate_generated_proto_headers

  log "generated protobuf outputs under $PROTO_OUT_DIR using $PROTOC_BIN"
}


build_include_flags() {
  INCLUDE_FLAGS=()

  add_existing_include INCLUDE_FLAGS "$FALLBACK_INCLUDE_DIR"
  add_existing_include INCLUDE_FLAGS "$REPO_ROOT/foreign/compat"
  add_existing_include INCLUDE_FLAGS "$PROTO_OUT_DIR"
  add_existing_include INCLUDE_FLAGS "$GEN_DIR/libcap"
  add_existing_include INCLUDE_FLAGS "$GEN_DIR/protobuf_config"
  add_existing_include INCLUDE_FLAGS "$INIT_DIR"
  add_existing_include INCLUDE_FLAGS "$REPO_ROOT"

  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/libbase/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/logging/liblog/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/logging/logwrapper/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libcutils/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libkeyutils/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/unwinding/libbacktrace/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libsystem/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocessgroup/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocessgroup/cgrouprc/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocessgroup/setup/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocessgroup/profiles/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libmodprobe/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/libprocinfo/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/bootloader_message/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/bootable/recovery/bootloader_message/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/core/fs_mgr/include_fstab"
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
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/system/extras/libfscrypt/include"

  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/selinux/libselinux/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/tinyxml2"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/protobuf/src"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/fmtlib/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/libcap/libcap/include"
  add_existing_include INCLUDE_FLAGS "$QUARRY_DIR/external/avb"

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
    -Wno-inconsistent-missing-override
  )

  CXXFLAGS=(
    "${COMMON_CFLAGS[@]}"
    -std=gnu++17
  )

  CFLAGS=(
    "${COMMON_CFLAGS[@]}"
    -std=gnu11
  )

  if [[ -n "${CXXFLAGS_EXTRA:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_cxx=( $CXXFLAGS_EXTRA )
    CXXFLAGS+=("${extra_cxx[@]}")
  fi
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

  if [[ -f "$p" ]]; then
    arr+=("$p")
  fi

  return 0
}

add_sources_from_dir_if_exists() {
  local -n arr="$1"
  local d="$2"
  local pattern="$3"
  local base=""

  [[ -d "$d" ]] || return 0

  while IFS= read -r -d '' f; do
    base="$(basename "$f")"

    case "$base" in
      *_test.cpp|*_test.cc|*_tests.cpp|*_tests.cc|*_unittest.cpp|*_unittest.cc|\
      *_benchmark.cpp|*_benchmark.cc|*_fuzzer.cpp|*_fuzzer.cc|\
      *_windows.cpp|*_windows.cc|*_darwin.cpp|*_darwin.cc|*_mac.cpp|*_mac.cc|\
      *_host.cpp|*_host.cc|\
      test_*.cpp|test_*.cc)
        warn "skipping non-target quarry source: $f"
        continue
        ;;
    esac

    case "$base" in
      utf8.cpp|utf8.cc)
        warn "skipping Windows-only quarry source: $f"
        continue
        ;;
    esac

    arr+=("$f")
  done < <(find "$d" -maxdepth 1 -type f -name "$pattern" -print0 | sort -z)

  return 0
}

add_sources_recursive_if_exists() {
  local -n arr="$1"
  local d="$2"
  local pattern="$3"
  local base=""

  [[ -d "$d" ]] || return 0

  while IFS= read -r -d '' f; do
    base="$(basename "$f")"

    case "$base" in
      *_test.cpp|*_test.cc|*_tests.cpp|*_tests.cc|*_unittest.cpp|*_unittest.cc|\
      *_benchmark.cpp|*_benchmark.cc|*_fuzzer.cpp|*_fuzzer.cc|\
      test_*.cpp|test_*.cc|mock_*.cc|mock_*.cpp)
        warn "skipping non-runtime quarry source: $f"
        continue
        ;;
    esac

    case "$f" in
      */compiler/*|*/test_util/*|*/testing/*|*/util/*|*/python/*|*/ruby/*|*/objectivec/*|*/js/*|*/java/*)
        warn "skipping non-lite protobuf quarry source: $f"
        continue
        ;;
    esac

    arr+=("$f")
  done < <(find "$d" -type f -name "$pattern" -print0 | sort -z)

  return 0
}


add_protobuf_lite_sources() {
  local target_array_name="$1"
  local android_bp="$QUARRY_DIR/external/protobuf/Android.bp"
  local src_list="$BUILD_DIR/protobuf-lite-srcs.txt"
  local rel=""

  [[ -f "$android_bp" ]] || die "protobuf Android.bp missing: $android_bp"

  mkdir -p "$BUILD_DIR"

  python3 - "$android_bp" > "$src_list" <<'PY_PROTO_SRCS'
from pathlib import Path
import re
import sys

bp = Path(sys.argv[1])
text = bp.read_text()

name = re.search(r'name\s*:\s*"libprotobuf-cpp-lite-defaults"', text)
if not name:
    raise SystemExit("could not find libprotobuf-cpp-lite-defaults in Android.bp")

srcs = text.find("srcs", name.end())
if srcs < 0:
    raise SystemExit("could not find srcs after libprotobuf-cpp-lite-defaults")

lb = text.find("[", srcs)
rb = text.find("]", lb)
if lb < 0 or rb < 0:
    raise SystemExit("could not parse srcs list for libprotobuf-cpp-lite-defaults")

block = text[lb + 1:rb]

for m in re.finditer(r'"([^"]+)"', block):
    src = m.group(1)
    if src.endswith((".cc", ".cpp", ".c")):
        print(src)
PY_PROTO_SRCS

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue

    case "$rel" in
      *_test.cc|*_test.cpp|*_unittest.cc|*_unittest.cpp|*_benchmark.cc|*_benchmark.cpp|*_fuzzer.cc|*_fuzzer.cpp)
        warn "skipping non-runtime protobuf source: $rel"
        continue
        ;;
    esac

    add_src "$target_array_name" "$QUARRY_DIR/external/protobuf/$rel"
  done < "$src_list"

  return 0
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
  add_src INIT_SOURCES "$REPO_ROOT/foreign/stubs/fs_mgr_foreign_stub.cpp"
  add_src INIT_SOURCES "$REPO_ROOT/foreign/stubs/reva_boundary_stubs.cpp"

  if [[ "${INNIT_COMPILE_LIBCAP:-0}" == "1" ]]; then
    local cap_src
    for cap_src in \
      cap_alloc.c \
      cap_extint.c \
      cap_flag.c \
      cap_proc.c
    do
      add_src INIT_SOURCES "$QUARRY_DIR/external/libcap/libcap/$cap_src"
    done
  fi

  while IFS= read -r -d '' f; do
    INIT_SOURCES+=("$f")
  done < <(find "$PROTO_OUT_DIR/system/core/init" -type f -name '*.pb.cc' -print0 2>/dev/null | sort -z)

  # Soong links these as static libraries. Foreign RevA compiles them directly
  # from the quarry when the source is available, avoiding Android product output.
  add_sources_from_dir_if_exists INIT_SOURCES "$QUARRY_DIR/system/core/property_service/libpropertyinfoparser" '*.cpp'
  add_sources_from_dir_if_exists INIT_SOURCES "$QUARRY_DIR/system/core/property_service/libpropertyinfoserializer" '*.cpp'

  # C++ ABI boundary rule:
  # Do not link recovery/platform C++ libraries such as libbase.so or
  # libprotobuf-cpp-lite.so into NDK-compiled objects. Compile their runtime
  # source into this binary so android::base and protobuf symbols use the same
  # std::__ndk1 ABI as init itself.
  add_sources_from_dir_if_exists INIT_SOURCES "$QUARRY_DIR/system/libbase" '*.cpp'
  add_protobuf_lite_sources INIT_SOURCES
  add_src_if_exists INIT_SOURCES "$QUARRY_DIR/external/fmtlib/src/format.cc"
  add_src_if_exists INIT_SOURCES "$QUARRY_DIR/external/fmtlib/src/os.cc"

  # tinyxml2 may not exist in a recovery-derived /system/lib64. Compile it in
  # statically when absent.
  case "${ENABLE_TINYXML2_DYNAMIC:-yes}" in
    yes)
      [[ -e "$ABI_LIB64/libtinyxml2.so" ]] || die "ENABLE_TINYXML2_DYNAMIC=yes but $ABI_LIB64/libtinyxml2.so is absent"
      ;;
    no)
      warn "ENABLE_TINYXML2_DYNAMIC=no; compiling tinyxml2.cpp into init"
      add_src INIT_SOURCES "$QUARRY_DIR/external/tinyxml2/tinyxml2.cpp"
      ;;
    *)
      die "invalid ENABLE_TINYXML2_DYNAMIC=${ENABLE_TINYXML2_DYNAMIC}; expected yes or no"
      ;;
  esac
}

policy_sources() {
  POLICY_SOURCES=()
  add_src POLICY_SOURCES "$INIT_DIR/innit/innit_policy.cpp"
  add_src POLICY_SOURCES "$INIT_DIR/innit/innit_policy_check_main.cpp"
  if [[ "${ENABLE_TINYXML2_DYNAMIC:-yes}" == "no" ]]; then
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
  )

  if [[ -n "${INNIT_EXTRA_LIB_DIRS:-}" ]]; then
    local IFS=':'
    local d
    for d in $INNIT_EXTRA_LIB_DIRS; do
      add_existing_libdir LDFLAGS "$d"
      [[ -d "$d" ]] && LDFLAGS+=("-Wl,-rpath-link,$d")
    done
  fi

  # Let the NDK C++ driver provide the matching libc++ runtime for objects
  # compiled with NDK libc++ headers. Prefer static libc++ for RevA so the
  # generated init binary does not depend on shipping libc++_shared.so.
  LDLIBS=(
    -lc++_shared
  )

  add_lib_flag_if_present log 1
  add_lib_flag_if_present cutils 1
  add_lib_flag_if_present selinux 1
  add_lib_flag_if_present processgroup 1
  add_lib_flag_if_present processgroup_setup 1
  add_lib_flag_if_present snapshot 0
  add_lib_flag_if_present lp 1
  add_lib_flag_if_present ext4_utils 1
  add_lib_flag_if_present bootloader_message 1
  add_lib_flag_if_present logwrap 1
  add_lib_flag_if_present keyutils 1

  if [[ "${ENABLE_TINYXML2_DYNAMIC:-yes}" == "yes" ]]; then
    add_lib_flag_if_present tinyxml2 1
  fi
  add_lib_flag_if_present backtrace 0
  add_lib_flag_if_present gsi 0
  add_lib_flag_if_present modprobe 0
  add_lib_flag_if_present procinfo 0

  # libcap is required by init/capabilities.cpp and init/reboot_utils.cpp.
  #
  # Recovery ramdisks often do not ship libcap.so. Do not force the runtime ABI
  # root to grow just for this. Prefer, in order:
  #   1. recovery ABI libcap.so, if present
  #   2. explicit external static archive via INNIT_LIBCAP_A
  #   3. minimal libcap source subset from the AOSP quarry, compiled into init
  #
  # The source-subset path intentionally avoids cap_text.c because that path
  # depends on Soong-generated cap_names.h. Init only needs proc/flag/allocation
  # capability operations.
  INNIT_COMPILE_LIBCAP="${INNIT_COMPILE_LIBCAP:-0}"

  if [[ -e "$ABI_LIB64/libcap.so" ]]; then
    LDLIBS+=("-lcap")
    INNIT_COMPILE_LIBCAP=0
  elif [[ -n "${INNIT_LIBCAP_A:-}" && -e "$INNIT_LIBCAP_A" ]]; then
    LDLIBS+=("$INNIT_LIBCAP_A")
    INNIT_COMPILE_LIBCAP=0
  elif [[ -d "$QUARRY_DIR/external/libcap/libcap" ]]; then
    warn "libcap.so absent from recovery ABI; compiling minimal libcap subset from quarry"
    INNIT_COMPILE_LIBCAP=1
  else
    die "libcap is required. Provide $ABI_LIB64/libcap.so, set INNIT_LIBCAP_A=/path/to/libcap.a, or quarry external/libcap"
  fi

  export INNIT_COMPILE_LIBCAP

  LDLIBS+=(
    -ldl
    -lm
    -lc
  )

  if [[ -n "${LDFLAGS_EXTRA:-}" ]]; then
    # shellcheck disable=SC2206
    local extra_ldflags=( $LDFLAGS_EXTRA )
    LDFLAGS+=("${extra_ldflags[@]}")
  fi

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
  link_binary "$POLICY_CHECK_OUTPUT"
  log "built $POLICY_CHECK_OUTPUT"
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
  link_binary "$INIT_OUTPUT"
  log "built $INIT_OUTPUT"
}

clean() {
  ensure_repo_root
  rm -rf "$OUT_DIR" "$GEN_DIR"
  log "removed $OUT_DIR and $GEN_DIR"
}

run_check_abi() {
  local binary="${1:-$INIT_OUTPUT}"

  if [[ -n "${DSGSI_ROOTFS:-}" ]]; then
    DSGSI_ROOTFS="$(abs_path "$DSGSI_ROOTFS")"
    export DSGSI_ROOTFS
    "$SCRIPT_DIR/check-abi.sh" --binary "$binary"
    return 0
  fi

  warn "skipping foreign/check-abi.sh because no DSGSI_ROOTFS root was provided"
  warn "local.env RECOVERY_SYSTEM/RECOVERY_LIB is sufficient for linking, but check-abi.sh still validates a full staging root"
}

run_package() {
  "$SCRIPT_DIR/package.sh" --binary "${1:-$INIT_OUTPUT}"
}

cmd="${1:-${BUILD_VARIANT:-all}}"
case "$cmd" in
  all|both)
    build_policy_check
    build_init
    run_check_abi "$INIT_OUTPUT"
    run_package "$INIT_OUTPUT"
    ;;
  second_stage|init) build_init ;;
  policy_check|policy-check) build_policy_check ;;
  prepare) prepare ;;
  proto) prepare; generate_proto ;;
  check-abi) run_check_abi "$INIT_OUTPUT" ;;
  package) run_package "$INIT_OUTPUT" ;;
  clean) clean ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac
