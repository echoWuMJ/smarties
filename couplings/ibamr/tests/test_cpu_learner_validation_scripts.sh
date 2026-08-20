#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
runner="$repo_root/couplings/ibamr/scripts/run_cpu_learner_validation_node3.sh"
comparator="$repo_root/couplings/ibamr/tests/CpuLearnerConvergenceCompare.cmake"
fake="$repo_root/couplings/ibamr/tests/fixtures/fake_cpu_learner_environment.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -x $runner ]] || fail "missing CPU learner runner: $runner"
[[ -f $comparator ]] || fail "missing CPU learner comparator: $comparator"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
source_dir="$fixture/smarties-cpu-aaaaaaaaaaaa"
build_dir="$fixture/build"
mkdir -p "$source_dir/couplings/ibamr/configs/training" \
         "$source_dir/couplings/ibamr/tests" \
         "$build_dir/couplings/ibamr" "$build_dir/lib" "$fixture/bin"
printf 'cmake_minimum_required(VERSION 3.5)\n' >"$source_dir/CMakeLists.txt"
cp "$comparator" "$source_dir/couplings/ibamr/tests/CpuLearnerConvergenceCompare.cmake"
cat >"$source_dir/couplings/ibamr/configs/training/settings.json" <<'EOF'
{"batchSize":8,"minTotObsNum":64,"obsPerStep":1}
EOF
cp "$fake" "$build_dir/couplings/ibamr/smarties_cpu_learner_environment"
chmod +x "$build_dir/couplings/ibamr/smarties_cpu_learner_environment"
printf 'fixture library\n' >"$build_dir/lib/libsmarties.so"
runtime_sha=$(sha256sum "$build_dir/lib/libsmarties.so" | awk '{print $1}')
cat >"$build_dir/couplings/ibamr/build_manifest.txt" <<EOF
revision=aaaaaaaaaaaa
source=$source_dir
runtime_library=$build_dir/lib/libsmarties.so
runtime_library_sha256=$runtime_sha
EOF
cat >"$fixture/bin/mpiexec" <<'EOF'
#!/usr/bin/env bash
if [[ ${FAKE_CPU_SCENARIO:-valid} == residual ]]; then
  "$FAKE_PRTERUN" 10 &
  printf '%s\n' "$!" >"$FAKE_RESIDUAL_PID_FILE"
fi
while (($#)); do
  case $1 in
    --bind-to|--map-by|-n) shift 2 ;;
    *) break ;;
  esac
done
exec "$@"
EOF
chmod +x "$fixture/bin/mpiexec"
cp "$(command -v sleep)" "$fixture/bin/prterun"
chmod +x "$fixture/bin/prterun"
export SMARTIES_CPU_MPIEXEC="$fixture/bin/mpiexec"
export SMARTIES_CPU_CHILD_TIMEOUT=2
export FAKE_PRTERUN="$fixture/bin/prterun"
export FAKE_RESIDUAL_PID_FILE="$fixture/residual.pid"

run_case()
{
  local scenario=$1 threads=$2 expected=$3 expected_status=$4
  local root="$fixture/runs-$scenario-$threads" log="$fixture/$scenario-$threads.log"
  set +e
  FAKE_CPU_SCENARIO=$scenario bash "$runner" \
    --source "$source_dir" --build "$build_dir" --run-root "$root" \
    --threads "$threads" --seed 11 --updates 8 \
    --training couplings/ibamr/configs/training/settings.json >"$log" 2>&1
  local status=$?
  set -e
  [[ $status -eq $expected_status ]] ||
    fail "$scenario/$threads status expected $expected_status got $status: $(<"$log")"
  grep -q "verdict=$expected" "$log" ||
    fail "$scenario/$threads missing verdict $expected: $(<"$log")"
  printf '%s\n' "$root/run"
}

one_valid=$(run_case valid 1 PASS 0)
run_case unchanged 1 NO_SYNTHETIC_CONVERGENCE 1 >/dev/null
run_case nonfinite 1 NONFINITE_UPDATE 1 >/dev/null
run_case missing_update 1 UPDATE_NOT_OBSERVED 1 >/dev/null
run_case wrong_final_step 1 UPDATE_NOT_OBSERVED 1 >/dev/null
run_case wrong_seed 1 OPERATIONAL_INCOMPLETE 1 >/dev/null
run_case checkpoint_mismatch 1 CHECKPOINT_MISMATCH 1 >/dev/null

four_bad=$(run_case four_bad 4 PASS 0)
set +e
cross_output=$(cmake -DONE_RUN_DIR="$one_valid" -DFOUR_RUN_DIR="$four_bad" \
  -DEXPECTED_SEED=11 -DEXPECTED_UPDATES=8 -P "$comparator" 2>&1)
cross_status=$?
set -e
[[ $cross_status -ne 0 && $cross_output == *"verdict=NO_SYNTHETIC_CONVERGENCE"* ]] ||
  fail "four-thread regression was not rejected: $cross_output"

export SMARTIES_CPU_CHILD_TIMEOUT=1
timeout_run=$(run_case timeout 1 OPERATIONAL_INCOMPLETE 1)
[[ -f $timeout_run/training/processes-after.txt &&
   ! -s $timeout_run/training/processes-after.txt ]] ||
  fail "timeout path did not record an empty run-scoped residual snapshot"

set +e
FAKE_CPU_SCENARIO=residual bash "$runner" \
  --source "$source_dir" --build "$build_dir" --run-root "$fixture/residual" \
  --threads 1 --seed 11 --updates 8 \
  --training couplings/ibamr/configs/training/settings.json \
  >"$fixture/residual.log" 2>&1
residual_status=$?
set -e
residual_output=$(<"$fixture/residual.log")
if [[ -f $FAKE_RESIDUAL_PID_FILE ]]; then
  residual_pid=$(<"$FAKE_RESIDUAL_PID_FILE")
  kill "$residual_pid" 2>/dev/null || true
fi
[[ $residual_status -ne 0 &&
   $residual_output == *"left a learner/environment/MPI process"* ]] ||
  fail "run-scoped detached prterun was not rejected: $residual_output"

manifest="$build_dir/couplings/ibamr/build_manifest.txt"
cp "$manifest" "$fixture/build_manifest.saved"
sed 's/^revision=.*/revision=bbbbbbbbbbbb/' \
  "$fixture/build_manifest.saved" >"$manifest"
set +e
identity_output=$(bash "$runner" --source "$source_dir" --build "$build_dir" \
  --run-root "$fixture/identity-mismatch" --threads 1 --seed 11 --updates 8 \
  --training couplings/ibamr/configs/training/settings.json 2>&1)
identity_status=$?
set -e
[[ $identity_status -ne 0 && $identity_output == *"verdict=OPERATIONAL_INCOMPLETE"* &&
   $identity_output != *"COMMAND="* ]] ||
  fail "mismatched build identity was not rejected before MPI: $identity_output"
cp "$fixture/build_manifest.saved" "$manifest"

printf 'tampered library\n' >>"$build_dir/lib/libsmarties.so"
set +e
tamper_output=$(bash "$runner" --source "$source_dir" --build "$build_dir" \
  --run-root "$fixture/runtime-tamper" --threads 1 --seed 11 --updates 8 \
  --training couplings/ibamr/configs/training/settings.json 2>&1)
tamper_status=$?
set -e
[[ $tamper_status -ne 0 && $tamper_output == *"verdict=OPERATIONAL_INCOMPLETE"* &&
   $tamper_output != *"COMMAND="* ]] ||
  fail "tampered runtime library was not rejected before MPI: $tamper_output"
printf 'fixture library\n' >"$build_dir/lib/libsmarties.so"

bad_training="$source_dir/couplings/ibamr/configs/training/bad.json"
printf '{"batchSize":6}\n' >"$bad_training"
set +e
bad_output=$(bash "$runner" --source "$source_dir" --build "$build_dir" \
  --run-root "$fixture/bad" --threads 4 --seed 11 --updates 8 \
  --training "$bad_training" 2>&1)
bad_status=$?
set -e
[[ $bad_status -ne 0 && $bad_output == *"batchSize must be divisible by threads"* ]] ||
  fail "invalid batch/thread combination was not rejected: $bad_output"

valid_log=$(<"$fixture/valid-1.log")
[[ $valid_log == *"--bind-to core --map-by slot:PE=4 -n 5"* ]] ||
  fail "missing frozen CPU binding command: $valid_log"
[[ $valid_log == *"--nTrainUpdates 8"* ]] ||
  fail "training command does not request exactly eight optimizer updates: $valid_log"
[[ $valid_log != *"--nTrainSteps 8"* ]] ||
  fail "training command still treats transition steps as optimizer updates: $valid_log"
if grep -Eiq 'pytorch|torch|cuda|pybind' "$fixture/valid-1.log"; then
  fail "forbidden backend token in runner output"
fi
