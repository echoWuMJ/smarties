#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_ENV_SCRIPT=/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
readonly DEFAULT_BASE_ROOT=/data2/mjwu/autoibamr-v0.18.0
readonly GCC=/data2/mjwu/local/gcc-8.5.0/bin/gcc
readonly GXX=/data2/mjwu/local/gcc-8.5.0/bin/g++
readonly MPICC=/data2/mjwu/local/openmpi/bin/mpicc
readonly MPICXX=/data2/mjwu/local/openmpi/bin/mpicxx
readonly MPIF77=/data2/mjwu/local/openmpi/bin/mpif90
readonly DEFAULT_PREFIX=/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1

usage()
{
  cat <<'EOF'
Usage: prepare_node3_ibamr.sh [--prefix DIR] [--dry-run]

Build an isolated IBAMR 0.18.0 dependency overlay whose bundled IBSAMRAI2
uses the active SAMRAI communicator. The shared autoibamr installation is
read-only input and is never modified.
EOF
}

die()
{
  printf 'prepare_node3_ibamr.sh: %s\n' "$*" >&2
  exit 65
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
patch_file="$script_dir/../patches/ibsamrai2-subcommunicator.patch"
base_root=${SMARTIES_IBAMR_BASE_ROOT:-$DEFAULT_BASE_ROOT}
prefix=$DEFAULT_PREFIX
dry_run=0

while (($#)); do
  case $1 in
    --prefix)
      (($# >= 2)) || die 'missing value after --prefix'
      prefix=$2
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

[[ -f "$patch_file" ]] || die "patch not found: $patch_file"
env_script=${SMARTIES_IBAMR_ENV_SCRIPT:-$DEFAULT_ENV_SCRIPT}
[[ -f "$env_script" ]] || die "environment script not found: $env_script"
# shellcheck disable=SC1090
source "$env_script"

[[ "$(gcc -dumpfullversion -dumpversion)" == 8.5.0 ]] ||
  die 'requires gcc 8.5.0'
[[ "$(g++ -dumpfullversion -dumpversion)" == 8.5.0 ]] ||
  die 'requires g++ 8.5.0'
[[ "$(mpicc --showme:command)" == "$GCC" ]] ||
  die 'mpicc is not backed by the required GCC 8.5.0'
[[ "$(mpicxx --showme:command)" == "$GXX" ]] ||
  die 'mpicxx is not backed by the required G++ 8.5.0'

samrai_base_source="$base_root/tmp/unpack/IBSAMRAI2-2025.10.29"
ibamr_base_source="$base_root/tmp/unpack/IBAMR-0.18.0"
[[ -f "$samrai_base_source/configure" ]] ||
  die "SAMRAI source missing: $samrai_base_source"
[[ -f "$ibamr_base_source/CMakeLists.txt" ]] ||
  die "IBAMR source missing: $ibamr_base_source"

patch_sha=$(sha256sum "$patch_file" | awk '{print $1}')
marker="$prefix/PATCHED_SMARTIES_SAMRAI.sha256"
samrai_source="$prefix/src/IBSAMRAI2-2025.10.29"
samrai_build="$prefix/build/samrai"
samrai_install="$prefix/packages/IBSAMRAI2-2025.10.29"
ibamr_build="$prefix/build/ibamr"
ibamr_install="$prefix/packages/IBAMR-0.18.0"

printf 'OVERLAY_PREFIX=%s\n' "$prefix"
printf 'PATCH_SHA256=%s\n' "$patch_sha"
printf 'IBAMR_ROOT=%s\n' "$ibamr_install"

if [[ -f "$marker" && "$(<"$marker")" == "$patch_sha" &&
      -f "$ibamr_install/lib64/cmake/ibamr/IBAMRConfig.cmake" ]]; then
  printf 'OVERLAY_STATUS=reused\n'
  exit 0
fi

if ((dry_run)); then
  printf 'OVERLAY_STATUS=would-build\n'
  exit 0
fi

mkdir -p "$prefix/src" "$samrai_build" "$samrai_install" \
  "$ibamr_build" "$ibamr_install"
if [[ ! -d "$samrai_source" ]]; then
  cp -a "$samrai_base_source" "$samrai_source"
fi
if patch --dry-run -d "$samrai_source" -p1 -i "$patch_file" >/dev/null 2>&1; then
  patch -d "$samrai_source" -p1 -i "$patch_file"
elif patch --dry-run -R -d "$samrai_source" -p1 -i "$patch_file" >/dev/null 2>&1; then
  printf 'SAMRAI_PATCH_STATUS=already-applied\n'
else
  die "SAMRAI source is neither pristine nor patched as expected: $samrai_source"
fi

export CC=$MPICC
export CXX=$MPICXX
export F77=$MPIF77

if [[ ! -f "$samrai_install/lib/libSAMRAI.a" ]]; then
  (
    cd "$samrai_build"
    "$samrai_source/configure" \
      --with-F77="$MPIF77" \
      --with-hdf5="$base_root/packages/hdf5-1.12.2" \
      --without-petsc --without-hypre --without-blaslapack \
      --without-cubes --without-eleven --without-kinsol --without-sundials \
      --without-x --enable-dcomplex --enable-implicit-template-instantiation \
      --disable-deprecated \
      CFLAGS='-fPIC -O2' CXXFLAGS='-fPIC -O2' FFLAGS='-fPIC -O2' \
      --with-silo="$base_root/packages/silo-4.11-bsd" \
      --prefix="$samrai_install"
    make -j"${BUILD_JOBS:-8}"
    make install
  )
else
  printf 'SAMRAI_BUILD_STATUS=reused\n'
fi

cmake -S "$ibamr_base_source" -B "$ibamr_build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$MPICC" \
  -DCMAKE_CXX_COMPILER="$MPICXX" \
  -DCMAKE_INSTALL_PREFIX="$ibamr_install" \
  -DIBAMR_ENABLE_DOCUMENTATION=OFF \
  -DIBAMR_ENABLE_TESTING=OFF \
  -DIBAMR_FORCE_BUNDLED_Eigen3=ON \
  -DIBAMR_FORCE_BUNDLED_muParser=ON \
  -DHDF5_ROOT="$base_root/packages/hdf5-1.12.2" \
  -DHYPRE_ROOT="$base_root/packages/petsc-3.23.3" \
  -DPETSC_ROOT="$base_root/packages/petsc-3.23.3" \
  -DLIBMESH_ROOT="$base_root/packages/libmesh-1.7.8" \
  -DLIBMESH_METHOD=OPT \
  -DSAMRAI_ROOT="$samrai_install" \
  -DSILO_ROOT="$base_root/packages/silo-4.11-bsd"
cmake --build "$ibamr_build" --target install --parallel "${BUILD_JOBS:-8}"

printf '%s\n' "$patch_sha" >"$marker"
printf 'OVERLAY_STATUS=built\n'
