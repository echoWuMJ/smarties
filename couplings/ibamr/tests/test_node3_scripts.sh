#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
build_script="$repo_root/couplings/ibamr/scripts/build_node3.sh"
prepare_script="$repo_root/couplings/ibamr/scripts/prepare_node3_ibamr.sh"
run_script="$repo_root/couplings/ibamr/scripts/run_node3.sh"
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fixture_root/bin"

cat >"$fixture_root/bin/gcc" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FIXTURE_GCC_VERSION:-8.5.0}"
EOF
cat >"$fixture_root/bin/g++" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FIXTURE_GXX_VERSION:-8.5.0}"
EOF
cat >"$fixture_root/bin/mpicc" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--showme:command" ]]
printf '%s\n' /data2/mjwu/local/gcc-8.5.0/bin/gcc
EOF
cat >"$fixture_root/bin/mpicxx" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--showme:command" ]]
printf '%s\n' /data2/mjwu/local/gcc-8.5.0/bin/g++
EOF
cat >"$fixture_root/bin/cmake" <<'EOF'
#!/usr/bin/env bash
for argument in "$@"; do
  case $argument in
    -DOUTPUT_FILE=*)
      output=${argument#-DOUTPUT_FILE=}
      printf 'rendered fixture input\n' >"$output"
      ;;
  esac
done
EOF
cat >"$fixture_root/bin/mpiexec" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'Open MPI fixture 5.0.9\n'
  exit 0
fi
[[ "${1:-}" == "-n" ]]
shift 2
"$@"
EOF
chmod +x "$fixture_root/bin/gcc" "$fixture_root/bin/g++" \
  "$fixture_root/bin/mpicc" "$fixture_root/bin/mpicxx" \
  "$fixture_root/bin/cmake" "$fixture_root/bin/mpiexec"

cat >"$fixture_root/enable.sh" <<EOF
export PATH="$fixture_root/bin:\$PATH"
export IBAMR_ROOT=/data2/mjwu/autoibamr-v0.18.0/packages/IBAMR-0.18.0
EOF
export SMARTIES_IBAMR_ENV_SCRIPT="$fixture_root/enable.sh"

fail()
{
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains()
{
  local output=$1 expected=$2
  [[ "$output" == *"$expected"* ]] ||
    fail "expected output to contain '$expected', got: $output"
}

capture_status()
{
  local output_file=$1
  shift
  set +e
  "$@" >"$output_file" 2>&1
  local status=$?
  set -e
  return "$status"
}

mkdir -p "$fixture_root/base/tmp/unpack/IBSAMRAI2-2025.10.29" \
  "$fixture_root/base/tmp/unpack/IBAMR-0.18.0"
printf '#!/usr/bin/env bash\n' > \
  "$fixture_root/base/tmp/unpack/IBSAMRAI2-2025.10.29/configure"
printf 'cmake_minimum_required(VERSION 3.5)\n' > \
  "$fixture_root/base/tmp/unpack/IBAMR-0.18.0/CMakeLists.txt"

output=$(SMARTIES_IBAMR_BASE_ROOT="$fixture_root/base" \
  bash "$prepare_script" --prefix "$fixture_root/overlay" --dry-run)
assert_contains "$output" 'OVERLAY_STATUS=would-build'
assert_contains "$output" "IBAMR_ROOT=$fixture_root/overlay/packages/IBAMR-0.18.0"

output=$(bash "$run_script" smoke --dry-run --envs 1 --ranks-per-env 1 \
  --fidelity coarse --training couplings/ibamr/configs/training/smoke.json \
  --smoke-steps 1)
assert_contains "$output" "ENVIRONMENT_RANKS=1"
assert_contains "$output" "MPI_RANKS=2"
assert_contains "$output" "--learnersOnWorkers 0"

output=$(bash "$run_script" smoke --dry-run --envs 2 --ranks-per-env 2 \
  --fidelity medium --training couplings/ibamr/configs/training/smoke.json \
  --smoke-steps 1)
assert_contains "$output" "ENVIRONMENT_RANKS=4"
assert_contains "$output" "MPI_RANKS=5"

output=$(bash "$run_script" smoke --dry-run --envs 1 --ranks-per-env 1 \
  --fidelity curriculum \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" 'app-coarse.args\,app-medium.args\,app-fine.args'
assert_contains "$output" '1\,1\,0'

output=$(bash "$run_script" smoke --dry-run --envs 1 --ranks-per-env 2 \
  --fidelity coarse --fault-after-initialize \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" "--fault-after-initialize"

fixture_source="$fixture_root/smarties-fixture-0123456789ab"
fixture_build="$fixture_root/build-real"
mkdir -p "$fixture_source/couplings/ibamr/configs/fidelity" \
  "$fixture_source/couplings/ibamr/configs/training" \
  "$fixture_source/couplings/ibamr/scripts" \
  "$fixture_source/couplings/ibamr/cases/eel2d/upstream" \
  "$fixture_build/couplings/ibamr"
printf 'cmake_minimum_required(VERSION 3.5)\n' >"$fixture_source/CMakeLists.txt"
printf 'fixture fidelity\n' >"$fixture_source/couplings/ibamr/configs/fidelity/coarse.conf"
printf '{}\n' >"$fixture_source/couplings/ibamr/configs/training/smoke.json"
printf 'fixture renderer\n' >"$fixture_source/couplings/ibamr/scripts/render_input.cmake"
printf 'fixture vertex\n' >"$fixture_source/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex"
cat >"$fixture_build/couplings/ibamr/ibamr_eel2d_smoke" <<'EOF'
#!/usr/bin/env bash
printf 'fixture coupling completed\n'
EOF
chmod +x "$fixture_build/couplings/ibamr/ibamr_eel2d_smoke"
fixture_executable_sha=$(sha256sum \
  "$fixture_build/couplings/ibamr/ibamr_eel2d_smoke" | awk '{print $1}')
cat >"$fixture_build/couplings/ibamr/build_manifest.txt" <<EOF
revision=0123456789ab
source=$fixture_source
executable_sha256=$fixture_executable_sha
ibamr_root=/fixture/IBAMR-0.18.0
ibamr_version=0.18.0
petsc_root=/fixture/petsc-3.23.3
petsc_version=3.23.3
samrai_overlay=/fixture/overlay
samrai_patch_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
cat >"$fixture_source/couplings/ibamr/scripts/build_node3.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_dir=
build_dir=
while (($#)); do
  case $1 in
    --source) source_dir=$2; shift 2 ;;
    --build) build_dir=$2; shift 2 ;;
    *) exit 64 ;;
  esac
done
executable="$build_dir/couplings/ibamr/ibamr_eel2d_smoke"
mkdir -p "$(dirname "$executable")"
cat >"$executable" <<'PROGRAM'
#!/usr/bin/env bash
printf 'fixture coupling rebuilt and completed\n'
PROGRAM
chmod +x "$executable"
executable_sha=$(sha256sum "$executable" | awk '{print $1}')
cat >"$build_dir/couplings/ibamr/build_manifest.txt" <<MANIFEST
revision=0123456789ab
source=$source_dir
executable_sha256=$executable_sha
ibamr_root=/fixture/IBAMR-0.18.0
ibamr_version=0.18.0
petsc_root=/fixture/petsc-3.23.3
petsc_version=3.23.3
samrai_overlay=/fixture/overlay
samrai_patch_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MANIFEST
printf 'rebuilt\n' >"$build_dir/rebuild-called.txt"
EOF
chmod +x "$fixture_source/couplings/ibamr/scripts/build_node3.sh"

output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity coarse \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" "fixture coupling completed"
real_run_dir=$(printf '%s\n' "$output" | sed -n 's/^RUN_DIRECTORY=//p')
[[ -f "$real_run_dir/manifest.txt" ]] || fail "real-path manifest was not written"
[[ "$(<"$real_run_dir/exit_code.txt")" == 0 ]] ||
  fail "real-path exit code was not preserved"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "build_revision=0123456789ab"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "executable_sha256=$fixture_executable_sha"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "mpi_version=Open MPI fixture 5.0.9"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "ibamr_root=/fixture/IBAMR-0.18.0"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "petsc_version=3.23.3"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "samrai_patch_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

sed -i 's/revision=0123456789ab/revision=deadbeefdead/' \
  "$fixture_build/couplings/ibamr/build_manifest.txt"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity coarse \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" "fixture coupling rebuilt and completed"
[[ -f "$fixture_build/rebuild-called.txt" ]] ||
  fail "stale build revision did not trigger build_node3.sh"
assert_contains "$(<"$fixture_build/couplings/ibamr/build_manifest.txt")" \
  "revision=0123456789ab"

rm "$fixture_build/rebuild-called.txt"
printf '# tampered\n' >>"$fixture_build/couplings/ibamr/ibamr_eel2d_smoke"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity coarse \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" "fixture coupling rebuilt and completed"
[[ -f "$fixture_build/rebuild-called.txt" ]] ||
  fail "executable hash mismatch did not trigger build_node3.sh"

if capture_status "$fixture_root/envs-zero.log" bash "$run_script" smoke \
  --dry-run --envs 0 --ranks-per-env 1; then
  fail "--envs 0 was accepted"
fi
assert_contains "$(<"$fixture_root/envs-zero.log")" "--envs must be a positive integer"

if capture_status "$fixture_root/ranks-zero.log" bash "$run_script" smoke \
  --dry-run --envs 1 --ranks-per-env 0; then
  fail "--ranks-per-env 0 was accepted"
fi
assert_contains "$(<"$fixture_root/ranks-zero.log")" \
  "--ranks-per-env must be a positive integer"

set +e
bash "$run_script" train --dry-run >"$fixture_root/train.log" 2>&1
status=$?
set -e
[[ $status -eq 64 ]] || fail "train returned $status instead of 64"
assert_contains "$(<"$fixture_root/train.log")" "train mode is not supported"

FIXTURE_GCC_VERSION=8.4.0
export FIXTURE_GCC_VERSION
if capture_status "$fixture_root/gcc.log" bash "$build_script" --dry-run \
  --source "$repo_root" --build "$fixture_root/build"; then
  fail "GCC 8.4.0 fixture passed preflight"
fi
assert_contains "$(<"$fixture_root/gcc.log")" "requires gcc 8.5.0"
[[ ! -e "$fixture_root/build/CMakeCache.txt" ]] ||
  fail "build preflight invoked CMake after compiler rejection"

printf 'node3 script behavior tests passed\n'
