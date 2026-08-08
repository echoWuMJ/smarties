#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_ENV_SCRIPT=/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
readonly EXPECTED_IBAMR_ROOT=/data2/mjwu/autoibamr-v0.18.0/packages/IBAMR-0.18.0
readonly DEFAULT_IBAMR_OVERLAY=/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1
readonly GCC=/data2/mjwu/local/gcc-8.5.0/bin/gcc
readonly GXX=/data2/mjwu/local/gcc-8.5.0/bin/g++

usage()
{
  cat <<'EOF'
Usage: build_node3.sh [--source DIR] [--build DIR] [--ibamr-overlay DIR] [--dry-run]

Configure and build the Smarties-IBAMR coupling on node3 with the verified
IBAMR 0.18.0 and GCC 8.5.0 toolchain.
EOF
}

die()
{
  printf 'build_node3.sh: %s\n' "$*" >&2
  exit 65
}

revision_of()
{
  local source_dir=$1 revision
  if revision=$(git -C "$source_dir" rev-parse --short=12 HEAD 2>/dev/null); then
    printf '%s\n' "$revision"
    return
  fi
  revision=$(basename "$source_dir" | sed -n 's/.*-\([0-9a-f]\{12\}\).*/\1/p')
  printf '%s\n' "${revision:-unknown}"
}

preflight()
{
  local env_script=${SMARTIES_IBAMR_ENV_SCRIPT:-$DEFAULT_ENV_SCRIPT}
  [[ -f "$env_script" ]] || die "environment script not found: $env_script"
  # shellcheck disable=SC1090
  source "$env_script"

  local gcc_version gxx_version mpicc_command mpicxx_command
  gcc_version=$(gcc -dumpfullversion -dumpversion)
  gxx_version=$(g++ -dumpfullversion -dumpversion)
  [[ "$gcc_version" == 8.5.0 ]] ||
    die "requires gcc 8.5.0, found $gcc_version"
  [[ "$gxx_version" == 8.5.0 ]] ||
    die "requires g++ 8.5.0, found $gxx_version"

  mpicc_command=$(mpicc --showme:command)
  mpicxx_command=$(mpicxx --showme:command)
  [[ "$mpicc_command" == "$GCC" ]] ||
    die "mpicc uses '$mpicc_command', expected '$GCC'"
  [[ "$mpicxx_command" == "$GXX" ]] ||
    die "mpicxx uses '$mpicxx_command', expected '$GXX'"
  [[ "${IBAMR_ROOT:-}" == "$EXPECTED_IBAMR_ROOT" ]] ||
    die "IBAMR_ROOT is '${IBAMR_ROOT:-unset}', expected '$EXPECTED_IBAMR_ROOT'"
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(cd "$script_dir/../../.." && pwd)
build_dir=
ibamr_overlay=$DEFAULT_IBAMR_OVERLAY
dry_run=0

while (($#)); do
  case $1 in
    --source)
      (($# >= 2)) || die "missing value after --source"
      source_dir=$2
      shift 2
      ;;
    --build)
      (($# >= 2)) || die "missing value after --build"
      build_dir=$2
      shift 2
      ;;
    --ibamr-overlay)
      (($# >= 2)) || die "missing value after --ibamr-overlay"
      ibamr_overlay=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -f "$source_dir/CMakeLists.txt" ]] ||
  die "source directory does not contain CMakeLists.txt: $source_dir"
source_dir=$(cd "$source_dir" && pwd)
snapshot_name=$(basename "$source_dir")
build_dir=${build_dir:-/data2/mjwu/local/coupling-build/$snapshot_name}

preflight

prepare_script="$script_dir/prepare_node3_ibamr.sh"
patched_ibamr_root="$ibamr_overlay/packages/IBAMR-0.18.0"
if ((dry_run)); then
  "$prepare_script" --prefix "$ibamr_overlay" --dry-run
else
  "$prepare_script" --prefix "$ibamr_overlay"
  [[ -f "$patched_ibamr_root/lib64/cmake/ibamr/IBAMRConfig.cmake" ]] ||
    die "patched IBAMR overlay is incomplete: $patched_ibamr_root"
fi
IBAMR_ROOT=$patched_ibamr_root
export IBAMR_ROOT
SAMRAI_SOURCE_ROOT=/data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBSAMRAI2-2025.10.29
export SAMRAI_SOURCE_ROOT

cmake_configure=(
  cmake -S "$source_dir" -B "$build_dir"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER="$GCC"
  -DCMAKE_CXX_COMPILER="$GXX"
  -DCOMPILE_PY_SO=OFF
  -DBUILD_IBAMR_COUPLING=ON
  -DBUILD_IBAMR_COUPLING_TESTS=ON
  -DIBAMR_DIR="$IBAMR_ROOT/lib64/cmake/ibamr"
)
cmake_build=(cmake --build "$build_dir" --parallel "${BUILD_JOBS:-8}")

printf 'SOURCE=%s\n' "$source_dir"
printf 'BUILD=%s\n' "$build_dir"
printf 'SNAPSHOT_NAME=%s\n' "$snapshot_name"
printf 'IBAMR_ROOT=%s\n' "$IBAMR_ROOT"
printf 'CONFIGURE_COMMAND='
printf '%q ' "${cmake_configure[@]}"
printf '\nBUILD_COMMAND='
printf '%q ' "${cmake_build[@]}"
printf '\n'

if ((dry_run)); then
  exit 0
fi

mkdir -p "$build_dir"
"${cmake_configure[@]}"
"${cmake_build[@]}"

revision=$(revision_of "$source_dir")
executable="$build_dir/couplings/ibamr/ibamr_eel2d_smoke"
build_manifest="$build_dir/couplings/ibamr/build_manifest.txt"
[[ $revision != unknown ]] || die "cannot determine source revision: $source_dir"
[[ -x "$executable" ]] || die "build did not produce executable: $executable"
executable_sha256=$(sha256sum "$executable" | awk '{print $1}')
manifest_tmp="$build_manifest.tmp.$$"
{
  printf 'revision=%s\n' "$revision"
  printf 'source=%s\n' "$source_dir"
  printf 'executable_sha256=%s\n' "$executable_sha256"
} >"$manifest_tmp"
mv "$manifest_tmp" "$build_manifest"
printf 'BUILD_MANIFEST=%s\n' "$build_manifest"
printf 'BUILD_REVISION=%s\n' "$revision"
printf 'EXECUTABLE_SHA256=%s\n' "$executable_sha256"
