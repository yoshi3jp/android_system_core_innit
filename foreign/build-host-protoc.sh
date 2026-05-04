#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=foreign/common.sh
source "$SCRIPT_DIR/common.sh"

LOCAL_ENV="${LOCAL_ENV:-$REPO_ROOT/foreign/config/local.env}"

if [[ -f "$LOCAL_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_ENV"
fi

if [[ -n "${AOSP_QUARRY:-}" ]]; then
  QUARRY_DIR="$(abs_path "$AOSP_QUARRY")"
fi

PROTOBUF_SRC="${PROTOBUF_SRC:-$QUARRY_DIR/external/protobuf}"
PROTOBUF_VERSION_HEADER="$PROTOBUF_SRC/src/google/protobuf/stubs/common.h"

[[ -d "$PROTOBUF_SRC" ]] || die "protobuf quarry missing: $PROTOBUF_SRC"
[[ -f "$PROTOBUF_VERSION_HEADER" ]] || die "protobuf version header missing: $PROTOBUF_VERSION_HEADER"

PROTOBUF_VERSION="$(
  awk '/#define GOOGLE_PROTOBUF_VERSION / { print $3; exit }' "$PROTOBUF_VERSION_HEADER"
)"

log "quarry protobuf version: $PROTOBUF_VERSION"

HOST_OUT="$REPO_ROOT/foreign/out/host-protobuf"
HOST_TOOLS="$REPO_ROOT/foreign/host-tools"
HOST_CONFIG="$HOST_OUT/foreign-config"

mkdir -p "$HOST_OUT" "$HOST_TOOLS" "$HOST_CONFIG"

cat > "$HOST_CONFIG/config.h" <<'EOF_CONFIG_H'
#pragma once

/*
 * Host-only protobuf config shim for the old Android external/protobuf CMake
 * build path.
 *
 * The Android protobuf 3.0.0 / sc-release quarry can include "config.h" from
 * google/protobuf/stubs/common.cc, but the lightweight CMake path used here
 * does not generate the Autotools config header.
 */
#define HAVE_PTHREAD 1
#define HAVE_ZLIB 0
EOF_CONFIG_H

HOST_PROTOBUF_CFLAGS="-I$HOST_CONFIG ${HOST_PROTOBUF_CFLAGS:-}"

patch_host_protobuf_quarry_for_protoc() {
  local java_file="$PROTOBUF_SRC/src/google/protobuf/compiler/java/java_file.cc"
  local main_cc="$PROTOBUF_SRC/src/google/protobuf/compiler/main.cc"

  [[ -f "$java_file" ]] || die "protobuf java_file.cc missing: $java_file"
  [[ -f "$main_cc" ]] || die "protobuf compiler main.cc missing: $main_cc"

  python3 - "$java_file" "$main_cc" <<'PY_PATCH'
from pathlib import Path
import re
import sys

java_file = Path(sys.argv[1])
main_cc = Path(sys.argv[2])

# GCC 13/libstdc++ requires std::set comparators to be invocable as const.
# Old protobuf's FieldDescriptorCompare::operator() is non-const.
s = java_file.read_text()
s2 = re.sub(
    r'(struct\s+FieldDescriptorCompare\s*\{.*?bool\s+operator\(\)\s*\(\s*const\s+FieldDescriptor\*\s+field1\s*,\s*const\s+FieldDescriptor\*\s+field2\s*\))\s*(\{)',
    r'\1 const \2',
    s,
    count=1,
    flags=re.S,
)

if s2 == s:
    s2 = s.replace(
        'bool operator()(const FieldDescriptor* field1, const FieldDescriptor* field2) {',
        'bool operator()(const FieldDescriptor* field1, const FieldDescriptor* field2) const {',
        1,
    )

if s2 != s:
    java_file.write_text(s2)

# Replace the protobuf compiler frontend with a minimal C++-only protoc main.
#
# The normal Android protobuf main wires in many generators. For Innit RevA we
# only need --cpp_out for init/libsnapshot/update_engine proto generation.
# Avoiding JavaMicro/JavaNano/etc. also avoids fragile host-side link failures.
main_cc.write_text("""// Auto-patched by Innit foreign/build-host-protoc.sh.
// Host-only protoc frontend for RevA foreign build.
// Only --cpp_out is required.

#include <google/protobuf/compiler/command_line_interface.h>
#include <google/protobuf/compiler/cpp/cpp_generator.h>

int main(int argc, char* argv[]) {
  google::protobuf::compiler::CommandLineInterface cli;
  cli.AllowPlugins("protoc-");

  google::protobuf::compiler::cpp::CppGenerator cpp_generator;
  cli.RegisterGenerator("--cpp_out", "--cpp_opt", &cpp_generator,
                        "Generate C++ header and source.");

  return cli.Run(argc, argv);
}
""")
PY_PATCH

  log "patched protobuf host sources for C++-only local protoc build"
}

patch_host_protobuf_quarry_for_protoc

[[ -f "$PROTOBUF_SRC/cmake/CMakeLists.txt" ]] || {
  die "protobuf quarry does not contain cmake/CMakeLists.txt; provide PROTOC=/path/to/matching/protoc instead"
}

cmake -S "$PROTOBUF_SRC/cmake" \
      -B "$HOST_OUT" \
      -DCMAKE_BUILD_TYPE=Release \
      -Dprotobuf_BUILD_TESTS=OFF \
      -Dprotobuf_BUILD_SHARED_LIBS=OFF \
      -Dprotobuf_WITH_ZLIB=OFF \
      -DCMAKE_CXX_STANDARD=11 \
      -DCMAKE_CXX_STANDARD_REQUIRED=ON \
      -DCMAKE_CXX_EXTENSIONS=ON \
      -DCMAKE_C_FLAGS="$HOST_PROTOBUF_CFLAGS ${CMAKE_C_FLAGS:-}" \
      -DCMAKE_CXX_FLAGS="$HOST_PROTOBUF_CFLAGS -Wno-deprecated-declarations ${CMAKE_CXX_FLAGS:-}"

cmake --build "$HOST_OUT" --target protoc -j"${JOBS:-$(nproc)}"

PROTOC_BUILT=""

if [[ -f "$HOST_OUT/protoc" ]]; then
  PROTOC_BUILT="$HOST_OUT/protoc"
else
  PROTOC_BUILT="$(find "$HOST_OUT" -type f -name protoc -print -quit)"
fi

[[ -n "$PROTOC_BUILT" ]] || {
  warn "CMake reported protoc built, but discovery failed. Candidates under $HOST_OUT:"
  find "$HOST_OUT" -maxdepth 4 \( -name protoc -o -name 'protoc*' \) -print >&2 || true
  die "protoc build finished but no protoc file was found under $HOST_OUT"
}

cp "$PROTOC_BUILT" "$HOST_TOOLS/protoc"
chmod +x "$HOST_TOOLS/protoc"

log "installed host protoc: $HOST_TOOLS/protoc from $PROTOC_BUILT"
"$HOST_TOOLS/protoc" --version || true
