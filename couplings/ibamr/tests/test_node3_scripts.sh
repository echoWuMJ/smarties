#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
build_script="$repo_root/couplings/ibamr/scripts/build_node3.sh"
prepare_script="$repo_root/couplings/ibamr/scripts/prepare_node3_ibamr.sh"
run_script="$repo_root/couplings/ibamr/scripts/run_node3.sh"
speed_settings="$repo_root/couplings/ibamr/configs/training/speed_tracking.json"
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

assert_not_contains()
{
  local output=$1 unexpected=$2
  [[ "$output" != *"$unexpected"* ]] ||
    fail "expected output not to contain '$unexpected', got: $output"
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

min_training_observations=$(sed -n \
  's/.*"minTotObsNum"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
  "$speed_settings")
[[ "$min_training_observations" == 1 ]] ||
  fail "speed-tracking learner must leave one post-startup protocol transition"
if grep -Eiq 'pytorch|cuda' "$speed_settings"; then
  fail "speed-tracking baseline unexpectedly enables PyTorch/CUDA"
fi

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
  --training couplings/ibamr/configs/training/smoke.json \
  --smoke-steps 1)
assert_contains "$output" "ENVIRONMENT_RANKS=1"
assert_contains "$output" "MPI_RANKS=2"
assert_contains "$output" "--learnersOnWorkers 0"
assert_contains "$output" "--eel-mode smoke"
assert_contains "$output" "--smoke-steps 1"
assert_contains "$output" "FIDELITY=medium"

output=$(bash "$run_script" smoke --dry-run --envs 2 --ranks-per-env 2 \
  --fidelity medium --training couplings/ibamr/configs/training/smoke.json \
  --smoke-steps 1)
assert_contains "$output" "ENVIRONMENT_RANKS=4"
assert_contains "$output" "MPI_RANKS=5"

for invalid_fidelity in coarse fine curriculum; do
  log="$fixture_root/fidelity-${invalid_fidelity}.log"
  if capture_status "$log" \
    bash "$run_script" smoke --dry-run \
      --envs 1 --ranks-per-env 1 \
      --fidelity "$invalid_fidelity" \
      --training couplings/ibamr/configs/training/smoke.json \
      --smoke-steps 1; then
    fail "unsupported fidelity $invalid_fidelity was accepted"
  fi
  assert_contains "$(<"$log")" \
    "only medium is supported for physical eel2d runs"
  assert_not_contains "$(<"$log")" "COMMAND="
done

output=$(bash "$run_script" smoke --dry-run --envs 1 --ranks-per-env 2 \
  --fidelity medium --fault-after-initialize \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" "--fault-after-initialize"

output=$(bash "$run_script" train --dry-run --envs 2 --ranks-per-env 2 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
  --train-steps 1)
assert_contains "$output" "ENVIRONMENT_RANKS=4"
assert_contains "$output" "MPI_RANKS=5"
assert_contains "$output" "CONTROL_STAGE=stage2_physical_control_experimental"
assert_contains "$output" "--eel-mode speed-tracking"
assert_contains "$output" "--task-file task.conf"
assert_contains "$output" "--nTrainSteps 1"

if capture_status "$fixture_root/train-missing-task.log" \
  bash "$run_script" train --dry-run --envs 1 --ranks-per-env 1 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --train-steps 1; then
  fail "train accepted a missing --task option"
fi
assert_contains "$(<"$fixture_root/train-missing-task.log")" \
  "--task is required"
assert_not_contains "$(<"$fixture_root/train-missing-task.log")" "COMMAND="

printf 'this is not key value syntax\n' >"$fixture_root/malformed-task.conf"
if capture_status "$fixture_root/train-malformed-task.log" \
  bash "$run_script" train --dry-run --envs 1 --ranks-per-env 1 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task "$fixture_root/malformed-task.conf" --train-steps 1; then
  fail "train accepted a malformed task file"
fi
assert_contains "$(<"$fixture_root/train-malformed-task.log")" \
  "invalid task configuration"
assert_not_contains "$(<"$fixture_root/train-malformed-task.log")" "COMMAND="

if capture_status "$fixture_root/train-steps-zero.log" \
  bash "$run_script" train --dry-run --envs 1 --ranks-per-env 1 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
  --train-steps 0; then
  fail "train accepted --train-steps 0"
fi
assert_contains "$(<"$fixture_root/train-steps-zero.log")" \
  "--train-steps must be a positive integer"

if capture_status "$fixture_root/train-steps-unreachable.log" \
  bash "$run_script" train --dry-run --envs 1 --ranks-per-env 1 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
  --train-steps 2; then
  fail "train accepted a step budget unreachable in one physical episode"
fi
assert_contains "$(<"$fixture_root/train-steps-unreachable.log")" \
  "cannot finish within one physical episode"

fixture_source="$fixture_root/smarties-fixture-0123456789ab"
fixture_build="$fixture_root/build-real"
mkdir -p "$fixture_source/couplings/ibamr/configs/fidelity" \
  "$fixture_source/couplings/ibamr/configs/training" \
  "$fixture_source/couplings/ibamr/configs/tasks" \
  "$fixture_source/couplings/ibamr/scripts" \
  "$fixture_source/couplings/ibamr/cases/eel2d/upstream" \
  "$fixture_build/couplings/ibamr" \
  "$fixture_build/lib"
printf 'cmake_minimum_required(VERSION 3.5)\n' >"$fixture_source/CMakeLists.txt"
printf 'fixture fidelity\n' >"$fixture_source/couplings/ibamr/configs/fidelity/medium.conf"
printf '{}\n' >"$fixture_source/couplings/ibamr/configs/training/smoke.json"
cp "$speed_settings" \
  "$fixture_source/couplings/ibamr/configs/training/speed_tracking.json"
cp "$repo_root/couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf" \
  "$fixture_source/couplings/ibamr/configs/tasks/task.conf"
printf 'fixture renderer\n' >"$fixture_source/couplings/ibamr/scripts/render_input.cmake"
printf 'fixture vertex\n' >"$fixture_source/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex"
cat >"$fixture_build/couplings/ibamr/ibamr_eel2d_smoke" <<'EOF'
#!/usr/bin/env bash
printf 'fixture coupling completed\n'
EOF
chmod +x "$fixture_build/couplings/ibamr/ibamr_eel2d_smoke"
printf 'fixture smarties runtime library\n' > \
  "$fixture_build/lib/libsmarties.so"
fixture_executable_sha=$(sha256sum \
  "$fixture_build/couplings/ibamr/ibamr_eel2d_smoke" | awk '{print $1}')
fixture_runtime_library_sha=$(sha256sum \
  "$fixture_build/lib/libsmarties.so" | awk '{print $1}')
cat >"$fixture_build/couplings/ibamr/build_manifest.txt" <<EOF
revision=0123456789ab
source=$fixture_source
executable_sha256=$fixture_executable_sha
executable=$fixture_build/couplings/ibamr/ibamr_eel2d_smoke
runtime_library=$fixture_build/lib/libsmarties.so
runtime_library_sha256=$fixture_runtime_library_sha
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
runtime_library="$build_dir/lib/libsmarties.so"
mkdir -p "$(dirname "$executable")" "$(dirname "$runtime_library")"
cat >"$executable" <<'PROGRAM'
#!/usr/bin/env bash
printf 'fixture coupling rebuilt and completed\n'
PROGRAM
chmod +x "$executable"
printf 'fixture smarties runtime library rebuilt\n' >"$runtime_library"
executable_sha=$(sha256sum "$executable" | awk '{print $1}')
runtime_library_sha=$(sha256sum "$runtime_library" | awk '{print $1}')
cat >"$build_dir/couplings/ibamr/build_manifest.txt" <<MANIFEST
revision=0123456789ab
source=$source_dir
executable_sha256=$executable_sha
executable=$executable
runtime_library=$runtime_library
runtime_library_sha256=$runtime_library_sha
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
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
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
  "runtime_library=$fixture_build/lib/libsmarties.so"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "runtime_library_sha256=$fixture_runtime_library_sha"
[[ ! -e "$fixture_build/rebuild-called.txt" ]] ||
  fail "valid cached runtime library unexpectedly triggered rebuild"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "mpi_version=Open MPI fixture 5.0.9"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "ibamr_root=/fixture/IBAMR-0.18.0"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "petsc_version=3.23.3"
assert_contains "$(<"$real_run_dir/manifest.txt")" \
  "samrai_patch_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_contains "$(<"$real_run_dir/manifest.txt")" "eel_mode=smoke"
assert_contains "$(<"$real_run_dir/manifest.txt")" "state_dimension=1"
assert_contains "$(<"$real_run_dir/manifest.txt")" "action_dimension=1"

output=$(bash "$run_script" train --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task couplings/ibamr/configs/tasks/task.conf --train-steps 1)
assert_contains "$output" "fixture coupling completed"
assert_contains "$output" "CONTROL_STAGE=stage2_physical_control_experimental"
real_train_run_dir=$(printf '%s\n' "$output" | sed -n 's/^RUN_DIRECTORY=//p')
[[ -f "$real_train_run_dir/task.conf" ]] ||
  fail "train task file was not frozen in the run directory"
train_task_sha=$(sha256sum "$real_train_run_dir/task.conf" | awk '{print $1}')
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "eel_mode=speed-tracking"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "task_file=$real_train_run_dir/task.conf"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "task_sha256=$train_task_sha"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "train_steps=1"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "state_dimension=5"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "action_dimension=1"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "control_stage=stage2_physical_control_experimental"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "--task-file task.conf"

rm "$fixture_build/lib/libsmarties.so"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" "fixture coupling rebuilt and completed"
[[ -f "$fixture_build/rebuild-called.txt" ]] ||
  fail "missing runtime library did not trigger build_node3.sh"
corrected_runtime_library_sha=$(sha256sum \
  "$fixture_build/lib/libsmarties.so" | awk '{print $1}')
assert_contains "$(<"$fixture_build/couplings/ibamr/build_manifest.txt")" \
  "runtime_library=$fixture_build/lib/libsmarties.so"
assert_contains "$(<"$fixture_build/couplings/ibamr/build_manifest.txt")" \
  "runtime_library_sha256=$corrected_runtime_library_sha"

rm "$fixture_build/rebuild-called.txt"
printf 'tampered runtime library\n' >>"$fixture_build/lib/libsmarties.so"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
[[ -f "$fixture_build/rebuild-called.txt" ]] ||
  fail "tampered runtime library did not trigger build_node3.sh"
assert_contains "$output" "fixture coupling rebuilt and completed"

rm "$fixture_build/rebuild-called.txt"
sed -i \
  's/^runtime_library_sha256=.*/runtime_library_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' \
  "$fixture_build/couplings/ibamr/build_manifest.txt"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
[[ -f "$fixture_build/rebuild-called.txt" ]] ||
  fail "runtime library hash mismatch did not trigger build_node3.sh"
corrected_runtime_library_sha=$(sha256sum \
  "$fixture_build/lib/libsmarties.so" | awk '{print $1}')
assert_contains "$(<"$fixture_build/couplings/ibamr/build_manifest.txt")" \
  "runtime_library_sha256=$corrected_runtime_library_sha"

rm "$fixture_build/rebuild-called.txt"
sed -i \
  's#^runtime_library=.*#runtime_library=/fixture/wrong/libsmarties.so#' \
  "$fixture_build/couplings/ibamr/build_manifest.txt"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
[[ -f "$fixture_build/rebuild-called.txt" ]] ||
  fail "wrong runtime library path did not trigger build_node3.sh"
assert_contains "$(<"$fixture_build/couplings/ibamr/build_manifest.txt")" \
  "runtime_library=$fixture_build/lib/libsmarties.so"

sed -i 's/revision=0123456789ab/revision=deadbeefdead/' \
  "$fixture_build/couplings/ibamr/build_manifest.txt"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training couplings/ibamr/configs/training/smoke.json --smoke-steps 1)
assert_contains "$output" "fixture coupling rebuilt and completed"
[[ -f "$fixture_build/rebuild-called.txt" ]] ||
  fail "stale build revision did not trigger build_node3.sh"
assert_contains "$(<"$fixture_build/couplings/ibamr/build_manifest.txt")" \
  "revision=0123456789ab"

rm "$fixture_build/rebuild-called.txt"
printf '# tampered\n' >>"$fixture_build/couplings/ibamr/ibamr_eel2d_smoke"
output=$(bash "$run_script" smoke --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
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
