#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
real_cmake=$(command -v cmake)
build_script="$repo_root/couplings/ibamr/scripts/build_node3.sh"
prepare_script="$repo_root/couplings/ibamr/scripts/prepare_node3_ibamr.sh"
run_script="$repo_root/couplings/ibamr/scripts/run_node3.sh"
speed_settings="$repo_root/couplings/ibamr/configs/training/speed_tracking.json"
activity_settings="$repo_root/couplings/ibamr/configs/training/cpu_learner_eel_activity.json"
activity_task="$repo_root/couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf"
longrun_settings="$repo_root/couplings/ibamr/configs/training/eel2d_longrun.json"
longrun_task="$repo_root/couplings/ibamr/configs/tasks/eel2d_longrun.conf"
activity_wrapper="$repo_root/couplings/ibamr/tests/test_eel_learner_activity.cmake"
fixture_root=$(mktemp -d)

cleanup_fixture()
{
  local pid_file pid
  for pid_file in "$fixture_root/eel-residual.pid" \
                  "$fixture_root/orted-residual.pid"; do
    if [[ -f $pid_file ]]; then
      pid=$(<"$pid_file")
      kill "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$fixture_root"
}
trap cleanup_fixture EXIT

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
  if [[ $argument == *test_eel_learner_activity.cmake ]]; then
    exec "$REAL_CMAKE" "$@"
  fi
done
output=
end_time=
for argument in "$@"; do
  case $argument in
    -DOUTPUT_FILE=*)
      output=${argument#-DOUTPUT_FILE=}
      ;;
    -DEEL_END_TIME=*) end_time=${argument#-DEEL_END_TIME=} ;;
  esac
done
if [[ -n $output ]]; then
  [[ -n $end_time ]] || {
    printf 'fixture cmake: missing -DEEL_END_TIME for %s\n' "$output" >&2
    exit 65
  }
  printf 'rendered fixture input\n' >"$output"
  printf '%s|%s\n' "$output" "$end_time" >>"$FAKE_CMAKE_RENDER_LOG"
fi
EOF
cat >"$fixture_root/bin/mpiexec" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf 'Open MPI fixture 5.0.9\n'
  exit 0
fi
while [[ ${1:-} == --bind-to || ${1:-} == --map-by ]]; do
  shift 2
done
[[ "${1:-}" == "-n" ]]
shift 2
"$@"
EOF
chmod +x "$fixture_root/bin/gcc" "$fixture_root/bin/g++" \
  "$fixture_root/bin/mpicc" "$fixture_root/bin/mpicxx" \
  "$fixture_root/bin/cmake" "$fixture_root/bin/mpiexec"
cp "$(command -v sleep)" "$fixture_root/bin/prterun"
cp "$(command -v sleep)" "$fixture_root/bin/orted"
chmod +x "$fixture_root/bin/prterun" "$fixture_root/bin/orted"
export FAKE_EEL_PRTERUN="$fixture_root/bin/prterun"
export FAKE_EEL_ORTED="$fixture_root/bin/orted"
export FAKE_EEL_RESIDUAL_PID_FILE="$fixture_root/eel-residual.pid"
export FAKE_EEL_ORTED_RESIDUAL_PID_FILE="$fixture_root/orted-residual.pid"
export FAKE_CMAKE_RENDER_LOG="$fixture_root/render.log"
: >"$FAKE_CMAKE_RENDER_LOG"

cat >"$fixture_root/enable.sh" <<EOF
export PATH="$fixture_root/bin:\$PATH"
export IBAMR_ROOT=/data2/mjwu/autoibamr-v0.18.0/packages/IBAMR-0.18.0
EOF
export SMARTIES_IBAMR_ENV_SCRIPT="$fixture_root/enable.sh"
export REAL_CMAKE="$real_cmake"

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
[[ -f $activity_settings && -f $activity_task ]] ||
  fail "missing frozen eel learner activity settings/task"
activity_batch=$(sed -n \
  's/.*"batchSize"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
  "$activity_settings")
activity_minimum=$(sed -n \
  's/.*"minTotObsNum"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
  "$activity_settings")
[[ $activity_batch == 4 && $activity_minimum == 4 ]] ||
  fail "eel learner activity settings must freeze batch/minimum at 4"
grep -Eq '^[[:space:]]*warmup_cycles[[:space:]]*=[[:space:]]*0([.]0)?[[:space:]]*$' \
  "$activity_task" || fail "eel learner activity warmup must be zero"
grep -Eq '^[[:space:]]*episode_decisions[[:space:]]*=[[:space:]]*2[[:space:]]*$' \
  "$activity_task" || fail "eel learner activity segment must have two decisions"
if grep -Eiq 'pytorch|torch|cuda|pybind' "$activity_settings"; then
  fail "eel learner activity settings enable a forbidden backend"
fi

[[ -f $longrun_settings && -f $longrun_task ]] ||
  fail "missing long-run eel settings/task"
longrun_batch=$(sed -n \
  's/.*"batchSize"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
  "$longrun_settings")
longrun_minimum=$(sed -n \
  's/.*"minTotObsNum"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
  "$longrun_settings")
longrun_capacity=$(sed -n \
  's/.*"maxTotObsNum"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
  "$longrun_settings")
longrun_save_frequency=$(sed -n \
  's/.*"saveFreq"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
  "$longrun_settings")
[[ $longrun_batch == 4 && $longrun_minimum == 8 &&
   $longrun_capacity == 256 && $longrun_save_frequency == 8 ]] ||
  fail "long-run learner settings must bound replay and checkpoint cadence"
grep -Eq '^[[:space:]]*episode_decisions[[:space:]]*=[[:space:]]*2[[:space:]]*$' \
  "$longrun_task" || fail "long-run task must use two-decision logical segments"
grep -Eq '^[[:space:]]*warmup_cycles[[:space:]]*=[[:space:]]*0([.]0)?[[:space:]]*$' \
  "$longrun_task" || fail "long-run task warmup must be zero"
if grep -Eiq 'pytorch|torch|cuda|pybind' "$longrun_settings"; then
  fail "long-run settings enable a forbidden backend"
fi

cat >"$fixture_root/activity-settings.json" <<'EOF'
{"learner":"VRACER","batchSize":4,"minTotObsNum":1,"obsPerStep":1}
EOF
eval_checkpoint="$fixture_root/checkpoint/final"
mkdir -p "$eval_checkpoint"
printf 'weights\n' >"$eval_checkpoint/agent_00_net_weights.raw"
printf 'scaling\n' >"$eval_checkpoint/agent_00_scaling.raw"
cat >"$fixture_root/batch-too-small.json" <<'EOF'
{"learner":"VRACER","batchSize":2,"minTotObsNum":1,"obsPerStep":1}
EOF
cat >"$fixture_root/batch-not-divisible.json" <<'EOF'
{"learner":"VRACER","batchSize":6,"minTotObsNum":1,"obsPerStep":1}
EOF

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
assert_contains "$output" "--nTrainUpdates 0"
assert_contains "$output" "--nThreads 1"

output=$(bash "$run_script" train --dry-run --envs 1 --ranks-per-env 2 \
  --learner-threads 2 --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
  --train-updates 2 --end-time 12.5)
assert_contains "$output" "--nTrainSteps 0"
assert_contains "$output" "--nTrainUpdates 2"
assert_contains "$output" "SIMULATION_END_TIME=12.5"

output=$(bash "$run_script" train --dry-run --envs 1 --ranks-per-env 16 \
  --learner-ranks 1 --learner-threads 2 --fidelity medium \
  --training "$fixture_root/activity-settings.json" \
  --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
  --train-updates 32 --end-time 20 --long-run-output)
assert_contains "$output" "ENVIRONMENT_RANKS=16"
assert_contains "$output" "MPI_RANKS=17"
assert_contains "$output" "OUTPUT_PROFILE=long-run-sparse"
assert_contains "$output" "LOG_ALL_SAMPLES=0"
assert_contains "$output" "EEL_OUTPUT_INTERVAL=1000000000"
assert_contains "$output" "EEL_VIZ_DUMP_INTERVAL=1000000000"
assert_contains "$output" "EEL_RESTART_DUMP_INTERVAL=0"
assert_contains "$output" "EEL_TIMER_DUMP_INTERVAL=0"
assert_contains "$output" "--logAllSamples 0"

output=$(bash "$run_script" eval --dry-run --envs 1 --ranks-per-env 16 \
  --learner-ranks 1 --learner-threads 2 --fidelity medium \
  --training "$fixture_root/activity-settings.json" \
  --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
  --checkpoint "$eval_checkpoint" --eval-episodes 3 --end-time 20 \
  --long-run-output)
assert_contains "$output" "ENVIRONMENT_RANKS=16"
assert_contains "$output" "MPI_RANKS=17"
assert_contains "$output" "CONTROL_STAGE=stage2_policy_evaluation"
assert_contains "$output" "EVAL_EPISODES=3"
assert_contains "$output" "CHECKPOINT=$eval_checkpoint"
assert_contains "$output" "--nTrainSteps 0"
assert_contains "$output" "--nTrainUpdates 0"
assert_contains "$output" "--nEvalEpisodes 3"
assert_contains "$output" "--restart $eval_checkpoint"
assert_contains "$output" "--eel-mode speed-tracking"
assert_contains "$output" "--task-file task.conf"
assert_contains "$output" "OUTPUT_PROFILE=long-run-sparse"

if capture_status "$fixture_root/eval-multiple-environments.log" \
  bash "$run_script" eval --dry-run --envs 2 --ranks-per-env 2 \
    --training "$fixture_root/activity-settings.json" \
    --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
    --checkpoint "$eval_checkpoint"; then
  fail "eval accepted multiple environments with an ambiguous local episode budget"
fi
assert_contains "$(<"$fixture_root/eval-multiple-environments.log")" \
  "eval mode requires --envs 1 for exact episode budgeting"
assert_not_contains "$(<"$fixture_root/eval-multiple-environments.log")" "COMMAND="

if capture_status "$fixture_root/eval-missing-checkpoint.log" \
  bash "$run_script" eval --dry-run --envs 1 --ranks-per-env 2 \
    --training "$fixture_root/activity-settings.json" \
    --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf; then
  fail "eval accepted a missing --checkpoint option"
fi
assert_contains "$(<"$fixture_root/eval-missing-checkpoint.log")" \
  "--checkpoint is required for eval mode"
assert_not_contains "$(<"$fixture_root/eval-missing-checkpoint.log")" "COMMAND="

incomplete_checkpoint="$fixture_root/checkpoint-incomplete/final"
mkdir -p "$incomplete_checkpoint"
printf 'weights\n' >"$incomplete_checkpoint/agent_00_net_weights.raw"
if capture_status "$fixture_root/eval-incomplete-checkpoint.log" \
  bash "$run_script" eval --dry-run --envs 1 --ranks-per-env 2 \
    --training "$fixture_root/activity-settings.json" \
    --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
    --checkpoint "$incomplete_checkpoint"; then
  fail "eval accepted a checkpoint without scaling data"
fi
assert_contains "$(<"$fixture_root/eval-incomplete-checkpoint.log")" \
  "checkpoint scaling file not found"
assert_not_contains "$(<"$fixture_root/eval-incomplete-checkpoint.log")" "COMMAND="

if capture_status "$fixture_root/eval-training-budget.log" \
  bash "$run_script" eval --dry-run --envs 1 --ranks-per-env 2 \
    --training "$fixture_root/activity-settings.json" \
    --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
    --checkpoint "$eval_checkpoint" --train-updates 1; then
  fail "eval accepted a training budget"
fi
assert_contains "$(<"$fixture_root/eval-training-budget.log")" \
  "training budgets are not valid in eval mode"
assert_not_contains "$(<"$fixture_root/eval-training-budget.log")" "COMMAND="

if capture_status "$fixture_root/train-budget-conflict.log" \
  bash "$run_script" train --dry-run --envs 1 --ranks-per-env 2 \
    --fidelity medium \
    --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
    --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
    --train-steps 1 --train-updates 2; then
  fail "train accepted both explicit training budgets"
fi
assert_contains "$(<"$fixture_root/train-budget-conflict.log")" \
  "choose exactly one training budget"

for invalid_end_time in 0 -1 NaN infinity 1e9999; do
  log="$fixture_root/end-time-${invalid_end_time//[^A-Za-z0-9]/_}.log"
  if capture_status "$log" \
    bash "$run_script" train --dry-run --envs 1 --ranks-per-env 2 \
      --fidelity medium \
      --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
      --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
      --train-updates 2 --end-time "$invalid_end_time"; then
    fail "train accepted invalid --end-time $invalid_end_time"
  fi
  assert_contains "$(<"$log")" "--end-time must be a positive finite number"
done

output=$(bash "$run_script" train --dry-run --envs 1 --ranks-per-env 2 \
  --learner-threads 4 --fidelity medium \
  --training "$fixture_root/activity-settings.json" \
  --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
  --train-steps 1)
assert_contains "$output" "MPI_RANKS=3"
assert_contains "$output" "LEARNER_THREADS=4"
assert_contains "$output" "OMP_NUM_THREADS=4"
assert_contains "$output" "LEARNER_ACTIVITY_GATE=0"
assert_contains "$output" "--nThreads 4"
assert_contains "$output" "--learnerAuditDir"
assert_contains "$output" "--bind-to core --map-by slot:PE=4 -n 3"
if grep -Eiq 'pytorch|torch|cuda|pybind' <<<"$output"; then
  fail "threaded eel launcher exposed a forbidden backend token"
fi

if capture_status "$fixture_root/batch-too-small.log" \
  bash "$run_script" train --dry-run --envs 1 --ranks-per-env 2 \
    --learner-threads 4 --fidelity medium \
    --training "$fixture_root/batch-too-small.json" \
    --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
    --train-steps 1; then
  fail "threaded eel launcher accepted batchSize smaller than threads"
fi
assert_contains "$(<"$fixture_root/batch-too-small.log")" \
  "batchSize must be at least learner threads"
assert_not_contains "$(<"$fixture_root/batch-too-small.log")" "COMMAND="

if capture_status "$fixture_root/batch-not-divisible.log" \
  bash "$run_script" train --dry-run --envs 1 --ranks-per-env 2 \
    --learner-threads 4 --fidelity medium \
    --training "$fixture_root/batch-not-divisible.json" \
    --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
    --train-steps 1; then
  fail "threaded eel launcher accepted non-divisible batchSize"
fi
assert_contains "$(<"$fixture_root/batch-not-divisible.log")" \
  "batchSize must be divisible by learner threads"
assert_not_contains "$(<"$fixture_root/batch-not-divisible.log")" "COMMAND="

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

output=$(bash "$run_script" train --dry-run --envs 1 --ranks-per-env 1 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf \
  --train-steps 2)
assert_contains "$output" "COMMAND="
assert_contains "$output" "--nTrainSteps 2"
assert_contains "$output" "--nTrainUpdates 0"

fixture_source="$fixture_root/smarties-fixture-0123456789ab"
fixture_build="$fixture_root/build-real"
mkdir -p "$fixture_source/couplings/ibamr/configs/fidelity" \
  "$fixture_source/couplings/ibamr/configs/training" \
  "$fixture_source/couplings/ibamr/configs/tasks" \
  "$fixture_source/couplings/ibamr/scripts" \
  "$fixture_source/couplings/ibamr/cases/eel2d/upstream" \
  "$fixture_build/couplings/ibamr" \
  "$fixture_build/lib"
printf 'SINGLE_PRECISION:BOOL=ON\n' >"$fixture_build/CMakeCache.txt"
printf 'cmake_minimum_required(VERSION 3.5)\n' >"$fixture_source/CMakeLists.txt"
printf 'fixture fidelity\n' >"$fixture_source/couplings/ibamr/configs/fidelity/medium.conf"
printf '{}\n' >"$fixture_source/couplings/ibamr/configs/training/smoke.json"
cp "$speed_settings" \
  "$fixture_source/couplings/ibamr/configs/training/speed_tracking.json"
cp "$activity_settings" \
  "$fixture_source/couplings/ibamr/configs/training/cpu_learner_eel_activity.json"
cp "$repo_root/couplings/ibamr/tests/fixtures/speed_tracking_protocol.conf" \
  "$fixture_source/couplings/ibamr/configs/tasks/task.conf"
cp "$activity_task" \
  "$fixture_source/couplings/ibamr/configs/tasks/speed_tracking_learner_activity.conf"
mkdir -p "$fixture_source/couplings/ibamr/tests"
cp "$activity_wrapper" \
  "$fixture_source/couplings/ibamr/tests/test_eel_learner_activity.cmake"
printf 'fixture renderer\n' >"$fixture_source/couplings/ibamr/scripts/render_input.cmake"
printf 'fixture vertex\n' >"$fixture_source/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex"
cat >"$fixture_build/couplings/ibamr/ibamr_eel2d_smoke" <<'EOF'
#!/usr/bin/env bash
if [[ ${FAKE_EEL_RESIDUAL:-0} == 1 ]]; then
  "$FAKE_EEL_PRTERUN" 30 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$FAKE_EEL_RESIDUAL_PID_FILE"
fi
if [[ ${FAKE_EEL_ORTED_RESIDUAL:-0} == 1 ]]; then
  "$FAKE_EEL_ORTED" 120 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$FAKE_EEL_ORTED_RESIDUAL_PID_FILE"
fi
audit=none
restart=none
eval_episodes=0
while (($#)); do
  case $1 in
    --learnerAuditDir) audit=$2; shift 2 ;;
    --restart) restart=$2; shift 2 ;;
    --nEvalEpisodes) eval_episodes=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ $audit != none ]]; then
  mkdir -p "$audit/initial" "$audit/final"
  printf 'initial\n' >"$audit/initial/agent_00_net_weights.raw"
  printf 'initial scaling\n' >"$audit/initial/agent_00_scaling.raw"
  printf 'final\n' >"$audit/final/agent_00_net_weights.raw"
  printf 'final scaling\n' >"$audit/final/agent_00_scaling.raw"
  if [[ $restart != none && $eval_episodes -gt 0 ]]; then
    cat >"$audit/learner_audit.log" <<'AUDIT'
SMARTIES_NETWORK_AUDIT stage=restart network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
SMARTIES_NETWORK_AUDIT stage=final network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
AUDIT
  else
    cat >"$audit/learner_audit.log" <<'AUDIT'
SMARTIES_NETWORK_AUDIT stage=initialized network=agent_00_network0 step=0 threads=4 precision_bytes=4 params=544 digest=1111111111111111 sum=0 sum_squares=1 max_abs=1 finite=1
SMARTIES_NETWORK_AUDIT stage=update network=agent_00_network0 step=1 threads=4 precision_bytes=4 params=544 digest=2222222222222222 sum=0 sum_squares=1 max_abs=1 finite=1
SMARTIES_NETWORK_AUDIT stage=update network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
SMARTIES_NETWORK_AUDIT stage=final network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
AUDIT
  fi
  printf 'EEL_CONTROL segment=1 segment_decision=1 decision=1 action=0 target_ratio=1 applied_ratio=1 start_time=0 end_time=0.1 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932\n'
  printf 'EEL_CONTROL segment=1 segment_decision=2 decision=2 action=0 target_ratio=1 applied_ratio=1 start_time=0.1 end_time=0.2 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932\n'
  printf 'EEL_CONTROL_SEGMENT segment=1 decisions=2 total_decisions=2 status=truncated reason=logical_horizon\n'
  printf 'EEL_CONTROL segment=2 segment_decision=1 decision=3 action=0 target_ratio=1 applied_ratio=1 start_time=0.2 end_time=0.3 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932\n'
  printf 'EEL_CONTROL segment=2 segment_decision=2 decision=4 action=0 target_ratio=1 applied_ratio=1 start_time=0.3 end_time=0.4 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932\n'
  printf 'EEL_CONTROL_SEGMENT segment=2 decisions=2 total_decisions=4 status=truncated reason=logical_horizon\n'
  printf 'EEL_CONTROL_COMPLETE segments=2 decisions=4 ibamr_steps=400 truncated_segments=2 stopped_by=smarties\n'
fi
printf 'COUPLING_DRIVER_RETURNED_MPI_ACTIVE\n'
printf 'COUPLING_DRIVER_DESTROYED_MPI_FINALIZED\n'
printf 'fixture coupling completed\n'
EOF
chmod +x "$fixture_build/couplings/ibamr/ibamr_eel2d_smoke"
cat >"$fixture_build/couplings/ibamr/smarties_cpu_learner_environment" <<'EOF'
#!/usr/bin/env bash
audit=none
while (($#)); do
  case $1 in
    --learnerAuditDir) audit=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$audit"
cat >"$audit/learner_audit.log" <<'AUDIT'
SMARTIES_NETWORK_AUDIT stage=restart network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
AUDIT
printf 'SMARTIES_SYNTHETIC_STEP seed=11 environment=1 episode=1 decision=1 action=0 target=0 reward=0 squared_error=0 terminal=0 finite=1\n'
printf 'COUPLING_DRIVER_RETURNED_MPI_ACTIVE\n'
printf 'COUPLING_DRIVER_DESTROYED_MPI_FINALIZED\n'
EOF
chmod +x "$fixture_build/couplings/ibamr/smarties_cpu_learner_environment"
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
assert_contains "$(<"$FAKE_CMAKE_RENDER_LOG")" \
  "$real_run_dir/input2d|10.0"

output=$(bash "$run_script" train --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task couplings/ibamr/configs/tasks/task.conf --train-steps 1 \
  --end-time 12.5)
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
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "train_updates=0"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "train_budget_kind=steps"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "simulation_end_time=12.5"
assert_contains "$(<"$FAKE_CMAKE_RENDER_LOG")" \
  "$real_train_run_dir/input2d|12.5"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "state_dimension=17"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "action_dimension=1"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "control_stage=stage2_physical_control_experimental"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "--task-file task.conf"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "learner_threads=1"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "omp_proc_bind=close"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "omp_places=cores"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" "batch_size=1"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "network_precision_bytes=4"
assert_contains "$(<"$real_train_run_dir/manifest.txt")" \
  "learner_audit_dir=$real_train_run_dir/learner-audit"

output=$(bash "$run_script" eval --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 1 --fidelity medium \
  --training "$real_train_run_dir/settings.json" \
  --task "$real_train_run_dir/task.conf" \
  --checkpoint "$real_train_run_dir/learner-audit/final" \
  --eval-episodes 2 --end-time 12.5)
assert_contains "$output" "fixture coupling completed"
assert_contains "$output" "CONTROL_STAGE=stage2_policy_evaluation"
real_eval_run_dir=$(printf '%s\n' "$output" | sed -n 's/^RUN_DIRECTORY=//p')
[[ "$(<"$real_eval_run_dir/exit_code.txt")" == 0 ]] ||
  fail "eval path did not preserve exit zero"
eval_manifest=$(<"$real_eval_run_dir/manifest.txt")
assert_contains "$eval_manifest" "run_mode=eval"
assert_contains "$eval_manifest" "eval_episodes=2"
assert_contains "$eval_manifest" \
  "checkpoint=$real_train_run_dir/learner-audit/final"
assert_contains "$eval_manifest" "train_steps=0"
assert_contains "$eval_manifest" "train_updates=0"
assert_contains "$eval_manifest" "train_budget_kind=not-applicable"
assert_contains "$eval_manifest" "task_file=$real_eval_run_dir/task.conf"
if grep -q 'stage=update' "$real_eval_run_dir/learner-audit/learner_audit.log"; then
  fail "eval fixture performed a learner update"
fi
grep -q 'stage=restart' "$real_eval_run_dir/learner-audit/learner_audit.log" ||
  fail "eval fixture did not load the checkpoint"

output=$(bash "$run_script" train --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 2 \
  --learner-threads 4 --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/configs/tasks/speed_tracking_learner_activity.conf \
  --train-updates 2)
assert_contains "$output" "EEL_LEARNER_ACTIVITY verdict=PASS"
restart_command=$(printf '%s\n' "$output" | \
  sed -n 's/^CHECKPOINT_RELOAD_COMMAND=//p')
assert_contains "$restart_command" "--nTrainSteps 0"
assert_contains "$restart_command" "--nTrainUpdates 0"
activity_run_dir=$(printf '%s\n' "$output" | sed -n 's/^RUN_DIRECTORY=//p')
[[ -f $activity_run_dir/restart-audit/learner_audit.log ]] ||
  fail "eel learner activity run did not archive restart audit"
[[ "$(<"$activity_run_dir/restart_exit_code.txt")" == 0 ]] ||
  fail "eel learner activity restart status was not zero"
assert_contains "$(<"$activity_run_dir/manifest.txt")" "learner_threads=4"
assert_contains "$(<"$activity_run_dir/manifest.txt")" "learner_activity_gate=1"
assert_contains "$(<"$activity_run_dir/manifest.txt")" "train_steps=0"
assert_contains "$(<"$activity_run_dir/manifest.txt")" "train_updates=2"
assert_contains "$(<"$activity_run_dir/manifest.txt")" "train_budget_kind=updates"
assert_contains "$(<"$activity_run_dir/manifest.txt")" "simulation_end_time=10.0"
assert_contains "$(<"$activity_run_dir/manifest.txt")" \
  "command=mpiexec --bind-to core --map-by slot:PE=4 -n 3"

set +e
FAKE_EEL_RESIDUAL=1 bash "$run_script" train --source "$fixture_source" \
  --build "$fixture_build" --envs 1 --ranks-per-env 2 \
  --learner-threads 4 --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/configs/tasks/speed_tracking_learner_activity.conf \
  --train-updates 2 >"$fixture_root/eel-residual.log" 2>&1
eel_residual_status=$?
set -e
eel_residual_output=$(<"$fixture_root/eel-residual.log")
eel_residual_run=$(printf '%s\n' "$eel_residual_output" | \
  sed -n 's/^RUN_DIRECTORY=//p')
if [[ -f $FAKE_EEL_RESIDUAL_PID_FILE ]]; then
  eel_residual_pid=$(<"$FAKE_EEL_RESIDUAL_PID_FILE")
  kill "$eel_residual_pid" 2>/dev/null || true
  rm "$FAKE_EEL_RESIDUAL_PID_FILE"
fi
[[ $eel_residual_status -ne 0 &&
   $eel_residual_output == *"verdict=OPERATIONAL_INCOMPLETE"* ]] ||
  fail "run-scoped eel residual was not operationally rejected: $eel_residual_output"
[[ "$(<"$eel_residual_run/restart_exit_code.txt")" == NOT_RUN ]] ||
  fail "checkpoint reload ran after eel left a process"
assert_not_contains "$eel_residual_output" "CHECKPOINT_RELOAD_COMMAND="

set +e
FAKE_EEL_ORTED_RESIDUAL=1 bash "$run_script" train \
  --source "$fixture_source" --build "$fixture_build" \
  --envs 1 --ranks-per-env 2 --learner-threads 4 --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/configs/tasks/speed_tracking_learner_activity.conf \
  --train-updates 2 >"$fixture_root/orted-residual.log" 2>&1
orted_residual_status=$?
set -e
orted_residual_output=$(<"$fixture_root/orted-residual.log")
orted_residual_run=$(printf '%s\n' "$orted_residual_output" | \
  sed -n 's/^RUN_DIRECTORY=//p')
orted_residual_pid=$(<"$FAKE_EEL_ORTED_RESIDUAL_PID_FILE")
orted_residual_comm=$(ps -p "$orted_residual_pid" -o comm= | \
  tr -d '[:space:]')
[[ $orted_residual_comm == orted ]] ||
  fail "orted residual fixture has unexpected comm '$orted_residual_comm'"
kill "$orted_residual_pid" 2>/dev/null || true
rm "$FAKE_EEL_ORTED_RESIDUAL_PID_FILE"
[[ $orted_residual_status -ne 0 &&
   $orted_residual_output == *"verdict=OPERATIONAL_INCOMPLETE"* ]] ||
  fail "run-scoped orted residual was not operationally rejected: $orted_residual_output"
[[ "$(<"$orted_residual_run/restart_exit_code.txt")" == NOT_RUN ]] ||
  fail "checkpoint reload ran after eel left a scoped orted process"
assert_not_contains "$orted_residual_output" "CHECKPOINT_RELOAD_COMMAND="

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

[[ -f $activity_wrapper ]] || fail "missing eel learner activity wrapper"
activity_valid="$fixture_root/activity-valid"
mkdir -p "$activity_valid/learner-audit" "$activity_valid/restart-audit"
printf '0\n' >"$activity_valid/exit_code.txt"
printf '0\n' >"$activity_valid/restart_exit_code.txt"
: >"$activity_valid/processes-after.txt"
: >"$activity_valid/restart-processes-after.txt"
cat >"$activity_valid/learner-audit/learner_audit.log" <<'EOF'
SMARTIES_NETWORK_AUDIT stage=initialized network=agent_00_network0 step=0 threads=4 precision_bytes=4 params=544 digest=1111111111111111 sum=0 sum_squares=1 max_abs=1 finite=1
SMARTIES_NETWORK_AUDIT stage=update network=agent_00_network0 step=1 threads=4 precision_bytes=4 params=544 digest=2222222222222222 sum=0 sum_squares=1 max_abs=1 finite=1
SMARTIES_NETWORK_AUDIT stage=update network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
SMARTIES_NETWORK_AUDIT stage=final network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
EOF
cat >"$activity_valid/restart-audit/learner_audit.log" <<'EOF'
SMARTIES_NETWORK_AUDIT stage=restart network=agent_00_network0 step=2 threads=4 precision_bytes=4 params=544 digest=3333333333333333 sum=0 sum_squares=1 max_abs=1 finite=1
EOF
cat >"$activity_valid/stdout.log" <<'EOF'
EEL_CONTROL segment=1 segment_decision=1 decision=1 action=0 target_ratio=1 applied_ratio=1 start_time=0 end_time=0.1 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932
EEL_CONTROL segment=1 segment_decision=2 decision=2 action=0 target_ratio=1 applied_ratio=1 start_time=0.1 end_time=0.2 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932
EEL_CONTROL_SEGMENT segment=1 decisions=2 total_decisions=2 status=truncated reason=logical_horizon
EEL_CONTROL segment=2 segment_decision=1 decision=3 action=0 target_ratio=1 applied_ratio=1 start_time=0.2 end_time=0.3 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932
EEL_CONTROL segment=2 segment_decision=2 decision=4 action=0 target_ratio=1 applied_ratio=1 start_time=0.3 end_time=0.4 ibamr_steps=100 forward_velocity=0 reward_tracking=-0.1 reward_frequency=0 reward_smoothness=0 reward_total=-0.1 lagrangian_points=2932
EEL_CONTROL_SEGMENT segment=2 decisions=2 total_decisions=4 status=truncated reason=logical_horizon
EEL_CONTROL_COMPLETE segments=2 decisions=4 ibamr_steps=400 truncated_segments=2 stopped_by=smarties
EOF
cat >"$activity_valid/restart_stdout.log" <<'EOF'
SMARTIES_SYNTHETIC_STEP seed=11 environment=1 episode=1 decision=1 action=0 target=0 reward=0 squared_error=0 terminal=0 finite=1
COUPLING_DRIVER_RETURNED_MPI_ACTIVE
COUPLING_DRIVER_DESTROYED_MPI_FINALIZED
EOF

activity_expect()
{
  local label=$1 directory=$2 verdict=$3 expected_status=$4 output status
  set +e
  output=$("$real_cmake" -DRUN_DIR="$directory" \
    -P "$activity_wrapper" 2>&1)
  status=$?
  set -e
  [[ $status -eq $expected_status &&
     $output == *"EEL_LEARNER_ACTIVITY verdict=$verdict"* ]] ||
    fail "$label expected $verdict/$expected_status, got $status: $output"
}

activity_expect valid "$activity_valid" PASS 0

activity_nested="$fixture_root/activity-valid-nested-output"
cp -R "$activity_valid" "$activity_nested"
mkdir -p "$activity_nested/simulation_000_00000"
mv "$activity_nested/stdout.log" \
  "$activity_nested/simulation_000_00000/output_000"
: >"$activity_nested/stdout.log"
activity_expect nested-output "$activity_nested" PASS 0

activity_case="$fixture_root/activity-missing-update"
cp -R "$activity_valid" "$activity_case"
sed -i '/ stage=update /d' "$activity_case/learner-audit/learner_audit.log"
activity_expect missing-update "$activity_case" UPDATE_NOT_OBSERVED 1

activity_case="$fixture_root/activity-unchanged"
cp -R "$activity_valid" "$activity_case"
sed -i 's/stage=final\(.*\)digest=3333333333333333/stage=final\1digest=1111111111111111/' \
  "$activity_case/learner-audit/learner_audit.log"
activity_expect unchanged "$activity_case" UPDATE_NOT_OBSERVED 1

activity_case="$fixture_root/activity-nonfinite"
cp -R "$activity_valid" "$activity_case"
sed -i '/ stage=update /s/finite=1/finite=0/' \
  "$activity_case/learner-audit/learner_audit.log"
activity_expect nonfinite "$activity_case" NONFINITE_UPDATE 1

activity_case="$fixture_root/activity-points"
cp -R "$activity_valid" "$activity_case"
sed -i 's/lagrangian_points=2932/lagrangian_points=76/' \
  "$activity_case/stdout.log"
activity_expect points "$activity_case" COUPLING_PROTOCOL_FAILURE 1

activity_case="$fixture_root/activity-terminal"
cp -R "$activity_valid" "$activity_case"
printf 'EEL_CONTROL_TERMINAL decisions=4 ibamr_steps=400 reason=episode_horizon\n' \
  >>"$activity_case/stdout.log"
activity_expect terminal "$activity_case" COUPLING_PROTOCOL_FAILURE 1

activity_case="$fixture_root/activity-missing-complete"
cp -R "$activity_valid" "$activity_case"
sed -i '/^EEL_CONTROL_COMPLETE /d' "$activity_case/stdout.log"
activity_expect missing-complete "$activity_case" COUPLING_PROTOCOL_FAILURE 1

activity_case="$fixture_root/activity-missing-segment"
cp -R "$activity_valid" "$activity_case"
sed -i '/^EEL_CONTROL_SEGMENT segment=2 /d' "$activity_case/stdout.log"
activity_expect missing-segment "$activity_case" COUPLING_PROTOCOL_FAILURE 1

activity_case="$fixture_root/activity-restart"
cp -R "$activity_valid" "$activity_case"
sed -i 's/digest=3333333333333333/digest=4444444444444444/' \
  "$activity_case/restart-audit/learner_audit.log"
activity_expect restart "$activity_case" CHECKPOINT_MISMATCH 1

activity_case="$fixture_root/activity-residual"
cp -R "$activity_valid" "$activity_case"
printf '12345 prterun stale fixture\n' >"$activity_case/processes-after.txt"
activity_expect residual "$activity_case" OPERATIONAL_INCOMPLETE 1

printf 'node3 script behavior tests passed\n'
