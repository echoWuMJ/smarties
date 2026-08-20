#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_ENV_SCRIPT=/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
readonly EXPECTED_IBAMR_ROOT=/data2/mjwu/autoibamr-v0.18.0/packages/IBAMR-0.18.0
readonly GCC=/data2/mjwu/local/gcc-8.5.0/bin/gcc
readonly GXX=/data2/mjwu/local/gcc-8.5.0/bin/g++

usage()
{
  cat <<'EOF'
Usage:
  run_node3.sh smoke [options]
  run_node3.sh train [options]

Smoke options:
  --envs N                 Concurrent IBAMR environments (default: 1)
  --ranks-per-env N        MPI ranks used by each environment (default: 1)
  --learner-ranks N        Smarties master/learner ranks (default: 1)
  --learner-threads N      Native CPU threads per learner rank (default: 1)
  --fidelity LEVEL         medium only (default: medium)
  --training FILE          Smarties JSON settings file
  --smoke-steps N          IBAMR steps in the lifecycle episode (default: 1)
  --fault-after-initialize Test-only coordinated failure after IBAMR starts
  --source DIR             Immutable Smarties source snapshot
  --build DIR              Matching node3 build directory
  --dry-run                Validate and print the derived launch command

Train options additionally require:
  --task FILE              Validated eel control task configuration
  --train-steps N          Positive post-startup data-step budget (default: 1)

Smoke validates process ownership and the communication lifecycle. Train runs
the stage-two, one-physical-episode frequency-control path with Smarties' native
CPU learner; it does not establish policy quality or reset support.
EOF
}

die()
{
  printf 'run_node3.sh: %s\n' "$*" >&2
  exit "${2:-65}"
}

is_positive_integer()
{
  [[ $1 =~ ^[1-9][0-9]*$ ]]
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

manifest_value()
{
  local key=$1 manifest=$2
  sed -n "s/^${key}=//p" "$manifest" | tail -n 1
}

validate_task_config()
{
  local task_file=$1
  awk '
    BEGIN {
      split("baseline_angular_frequency minimum_frequency_ratio maximum_frequency_ratio maximum_ratio_delta decisions_per_baseline_period target_forward_speed forward_direction_x forward_direction_y velocity_scale tracking_weight frequency_weight smoothness_weight warmup_cycles episode_decisions", names, " ")
      for (i in names) required[names[i]] = 1
      number = "^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$"
    }
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") next
      copy = line
      if (gsub(/=/, "=", copy) != 1) { invalid = 1; exit }
      split(line, fields, "=")
      key = fields[1]
      value = fields[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (!(key in required) || key in seen || value !~ number) {
        invalid = 1
        exit
      }
      if ((key == "decisions_per_baseline_period" ||
           key == "episode_decisions") && value !~ /^[1-9][0-9]*$/) {
        invalid = 1
        exit
      }
      seen[key] = 1
    }
    END {
      if (invalid) exit 1
      for (key in required) if (!(key in seen)) exit 1
    }
  ' "$task_file"
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(cd "$script_dir/../../.." && pwd)
mode=${1:-}
[[ -n "$mode" ]] || {
  usage >&2
  exit 64
}
shift

if [[ $mode != smoke && $mode != train ]]; then
  die "mode must be 'smoke' or 'train'" 64
fi

envs=1
ranks_per_env=1
learner_ranks=1
learner_threads=1
fidelity=medium
smoke_steps=1
train_steps=1
task=
build_dir=
dry_run=0
fault_after_initialize=0
if [[ $mode == smoke ]]; then
  training=couplings/ibamr/configs/training/smoke.json
  eel_mode=smoke
  control_stage=phase1_lifecycle_smoke
  state_dimension=1
else
  training=couplings/ibamr/configs/training/speed_tracking.json
  eel_mode=speed-tracking
  control_stage=stage2_physical_control_experimental
  state_dimension=5
fi
action_dimension=1

while (($#)); do
  case $1 in
    --envs|--ranks-per-env|--learner-ranks|--learner-threads|--fidelity|--training|--smoke-steps|--train-steps|--task|--source|--build)
      (($# >= 2)) || die "missing value after $1"
      option=$1
      value=$2
      case $option in
        --envs) envs=$value ;;
        --ranks-per-env) ranks_per_env=$value ;;
        --learner-ranks) learner_ranks=$value ;;
        --learner-threads)
          learner_threads=$value
          ;;
        --fidelity) fidelity=$value ;;
        --training) training=$value ;;
        --smoke-steps) smoke_steps=$value ;;
        --train-steps) train_steps=$value ;;
        --task) task=$value ;;
        --source) source_dir=$value ;;
        --build) build_dir=$value ;;
      esac
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --fault-after-initialize)
      fault_after_initialize=1
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

is_positive_integer "$envs" || die "--envs must be a positive integer"
is_positive_integer "$ranks_per_env" ||
  die "--ranks-per-env must be a positive integer"
is_positive_integer "$learner_ranks" ||
  die "--learner-ranks must be a positive integer"
is_positive_integer "$learner_threads" ||
  die "--learner-threads must be a positive integer"
is_positive_integer "$smoke_steps" ||
  die "--smoke-steps must be a positive integer"
if [[ $mode == train ]]; then
  is_positive_integer "$train_steps" ||
    die "--train-steps must be a positive integer"
  [[ -n $task ]] || die "--task is required for train mode"
fi
if [[ $fidelity != medium ]]; then
  die "only medium is supported for physical eel2d runs"
fi

[[ -f "$source_dir/CMakeLists.txt" ]] ||
  die "source directory does not contain CMakeLists.txt: $source_dir"
source_dir=$(cd "$source_dir" && pwd)
snapshot_name=$(basename "$source_dir")
build_dir=${build_dir:-/data2/mjwu/local/coupling-build/$snapshot_name}

if [[ $training != /* ]]; then
  training="$source_dir/$training"
fi
[[ -f "$training" ]] || die "training settings not found: $training"
if [[ $mode == train ]]; then
  batch_size=$(sed -n \
    's/.*"batchSize"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$training" | tail -n 1)
  is_positive_integer "$batch_size" ||
    die "training settings require a positive integer batchSize: $training"
  if ((batch_size < learner_threads)); then
    die "batchSize must be at least learner threads"
  fi
  if ((batch_size % learner_threads != 0)); then
    die "batchSize must be divisible by learner threads"
  fi
  if [[ $task != /* ]]; then
    task="$source_dir/$task"
  fi
  [[ -f "$task" ]] || die "task configuration not found: $task"
  validate_task_config "$task" ||
    die "invalid task configuration: $task"
  minimum_training_observations=$(sed -n \
    's/.*"minTotObsNum"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$training" | tail -n 1)
  is_positive_integer "$minimum_training_observations" ||
    die "training settings require a positive integer minTotObsNum: $training"
  episode_decisions=$(awk -F= '
    {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /^[[:space:]]*episode_decisions[[:space:]]*=/) {
        value = line
        sub(/^[^=]*=[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        print value
      }
    }
  ' "$task" | tail -n 1)
  is_positive_integer "$episode_decisions" ||
    die "task configuration has invalid episode_decisions: $task"
  maximum_single_episode_train_steps=$((episode_decisions - minimum_training_observations))
  if ((maximum_single_episode_train_steps < 1 ||
       train_steps > maximum_single_episode_train_steps)); then
    die "--train-steps $train_steps cannot finish within one physical episode (episode_decisions=$episode_decisions, minTotObsNum=$minimum_training_observations)"
  fi
else
  batch_size=not-applicable
fi

environment_ranks=$((envs * ranks_per_env))
mpi_ranks=$((learner_ranks + environment_ranks))
revision=$(revision_of "$source_dir")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_id="eel2d-${timestamp}-${revision}-$$"
run_dir="$source_dir/couplings/ibamr/runs/$run_id"
learner_audit_dir="$run_dir/learner-audit"
executable="$build_dir/couplings/ibamr/ibamr_eel2d_smoke"
runtime_library="$build_dir/lib/libsmarties.so"
build_manifest="$build_dir/couplings/ibamr/build_manifest.txt"
build_script="$source_dir/couplings/ibamr/scripts/build_node3.sh"
fidelity_dir="$source_dir/couplings/ibamr/configs/fidelity"
render_script="$source_dir/couplings/ibamr/scripts/render_input.cmake"
vertex_file="$source_dir/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex"
activity_wrapper="$source_dir/couplings/ibamr/tests/test_eel_learner_activity.cmake"
synthetic_executable="$build_dir/couplings/ibamr/smarties_cpu_learner_environment"

preflight

build_is_current()
{
  [[ -x "$executable" && -f "$runtime_library" &&
     -f "$build_manifest" ]] || return 1
  local recorded_revision recorded_source recorded_executable recorded_sha actual_sha
  local recorded_runtime_library recorded_runtime_library_sha
  local actual_runtime_library_sha
  recorded_revision=$(manifest_value revision "$build_manifest")
  recorded_source=$(manifest_value source "$build_manifest")
  recorded_sha=$(manifest_value executable_sha256 "$build_manifest")
  recorded_executable=$(manifest_value executable "$build_manifest")
  recorded_runtime_library=$(manifest_value runtime_library "$build_manifest")
  recorded_runtime_library_sha=$(
    manifest_value runtime_library_sha256 "$build_manifest")
  [[ "$recorded_revision" == "$revision" ]] || return 1
  [[ "$recorded_source" == "$source_dir" ]] || return 1
  [[ "$recorded_executable" == "$executable" ]] || return 1
  [[ "$recorded_runtime_library" == "$runtime_library" ]] || return 1
  [[ $recorded_sha =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ $recorded_runtime_library_sha =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_sha=$(sha256sum "$executable" | awk '{print $1}')
  actual_runtime_library_sha=$(sha256sum "$runtime_library" | awk '{print $1}')
  [[ "$actual_sha" == "$recorded_sha" ]] || return 1
  [[ "$actual_runtime_library_sha" == "$recorded_runtime_library_sha" ]] ||
    return 1
  local key value
  for key in ibamr_root ibamr_version petsc_root petsc_version samrai_overlay; do
    value=$(manifest_value "$key" "$build_manifest")
    [[ -n "$value" ]] || return 1
  done
  value=$(manifest_value samrai_patch_sha256 "$build_manifest")
  [[ $value =~ ^[0-9a-f]{64}$ ]]
}

if ((dry_run)); then
  if build_is_current; then
    build_status=current
  else
    build_status=would-build
  fi
else
  if ! build_is_current; then
    [[ -x "$build_script" ]] || die "build script not executable: $build_script"
    printf 'BUILD_STATUS=building\n'
    "$build_script" --source "$source_dir" --build "$build_dir"
  fi
  build_is_current ||
    die "build identity does not match source revision $revision: $build_manifest"
  build_status=current
fi

if [[ $build_status == current ]]; then
  build_revision=$(manifest_value revision "$build_manifest")
  executable_sha256=$(manifest_value executable_sha256 "$build_manifest")
  runtime_library_sha256=$(manifest_value runtime_library_sha256 "$build_manifest")
  build_manifest_sha256=$(sha256sum "$build_manifest" | awk '{print $1}')
  ibamr_build_root=$(manifest_value ibamr_root "$build_manifest")
  ibamr_version=$(manifest_value ibamr_version "$build_manifest")
  petsc_root=$(manifest_value petsc_root "$build_manifest")
  petsc_version=$(manifest_value petsc_version "$build_manifest")
  samrai_overlay=$(manifest_value samrai_overlay "$build_manifest")
  samrai_patch_sha256=$(manifest_value samrai_patch_sha256 "$build_manifest")
  precision_setting=$(sed -n 's/^SINGLE_PRECISION:BOOL=//p' \
    "$build_dir/CMakeCache.txt" 2>/dev/null | tail -n 1)
  case ${precision_setting^^} in
    ON|TRUE|YES|1) network_precision_bytes=4 ;;
    OFF|FALSE|NO|0) network_precision_bytes=8 ;;
    *) network_precision_bytes=unknown ;;
  esac
else
  build_revision=unbuilt
  executable_sha256=unbuilt
  runtime_library=unbuilt
  runtime_library_sha256=unbuilt
  build_manifest_sha256=unbuilt
  ibamr_build_root=unbuilt
  ibamr_version=unbuilt
  petsc_root=unbuilt
  petsc_version=unbuilt
  samrai_overlay=unbuilt
  samrai_patch_sha256=unbuilt
  network_precision_bytes=unbuilt
fi

hostname_value=$(hostname)
kernel_value=$(uname -sr)
if [[ -r /etc/os-release ]]; then
  os_pretty=$( (source /etc/os-release; printf '%s' "${PRETTY_NAME:-unknown}") )
else
  os_pretty=unknown
fi
mpi_version=$(mpiexec --version 2>&1 | sed -n '1p')
mpicc_command=$(mpicc --showme:command)
mpicxx_command=$(mpicxx --showme:command)
env_script_used=${SMARTIES_IBAMR_ENV_SCRIPT:-$DEFAULT_ENV_SCRIPT}
if [[ $mode == train ]]; then
  effective_train_steps=$train_steps
else
  effective_train_steps=0
fi
learner_activity_gate=0
if [[ $mode == train &&
      $(basename "$training") == cpu_learner_eel_activity.json ]]; then
  [[ $(basename "$task") == speed_tracking_learner_activity.conf ]] ||
    die "cpu_learner_eel_activity.json requires speed_tracking_learner_activity.conf"
  [[ $train_steps == 1 ]] ||
    die "eel learner activity gate requires --train-steps 1"
  learner_activity_gate=1
fi

launch_args=(
  --nMasters "$learner_ranks"
  --nThreads "$learner_threads"
  --nEnvironments "$envs"
  --workerProcessesPerEnv "$ranks_per_env"
  --learnersOnWorkers 0
  --nTrainSteps "$effective_train_steps"
  --restart none
  --setupFolder .
  --input-file input2d
  --eel-mode "$eel_mode"
)

if [[ $mode == smoke ]]; then
  launch_args+=(--smoke-steps "$smoke_steps")
else
  launch_args+=(--task-file task.conf --learnerAuditDir "$learner_audit_dir")
fi

if ((fault_after_initialize)); then
  launch_args+=(--fault-after-initialize)
fi

export OMP_NUM_THREADS=$learner_threads
export OMP_DYNAMIC=FALSE
export OMP_PROC_BIND=close
export OMP_PLACES=cores
if ((learner_threads > 1)); then
  command=(mpiexec --bind-to core --map-by slot:PE=4 -n "$mpi_ranks"
    "$executable" "${launch_args[@]}")
else
  command=(mpiexec -n "$mpi_ranks" "$executable" "${launch_args[@]}")
fi

printf 'SOURCE=%s\n' "$source_dir"
printf 'BUILD=%s\n' "$build_dir"
printf 'RUN_ID=%s\n' "$run_id"
printf 'RUN_DIRECTORY=%s\n' "$run_dir"
printf 'LEARNER_RANKS=%s\n' "$learner_ranks"
printf 'LEARNER_THREADS=%s\n' "$learner_threads"
printf 'LEARNER_ACTIVITY_GATE=%s\n' "$learner_activity_gate"
printf 'OMP_NUM_THREADS=%s\n' "$OMP_NUM_THREADS"
printf 'OMP_DYNAMIC=%s\n' "$OMP_DYNAMIC"
printf 'OMP_PROC_BIND=%s\n' "$OMP_PROC_BIND"
printf 'OMP_PLACES=%s\n' "$OMP_PLACES"
printf 'ENVIRONMENT_RANKS=%s\n' "$environment_ranks"
printf 'MPI_RANKS=%s\n' "$mpi_ranks"
printf 'FIDELITY=%s\n' "$fidelity"
printf 'EEL_MODE=%s\n' "$eel_mode"
printf 'CONTROL_STAGE=%s\n' "$control_stage"
printf 'BUILD_STATUS=%s\n' "$build_status"
printf 'BUILD_REVISION=%s\n' "$build_revision"
printf 'NETWORK_PRECISION_BYTES=%s\n' "$network_precision_bytes"
printf 'COMMAND='
printf '%q ' "${command[@]}"
printf '\n'

if ((dry_run)); then
  exit 0
fi

[[ -f "$render_script" ]] || die "input renderer not found: $render_script"
[[ -f "$vertex_file" ]] || die "eel vertex file not found: $vertex_file"
mkdir -p "$run_dir"

render_fidelity()
{
  local level=$1
  local output=$2
  local config="$fidelity_dir/$level.conf"
  [[ -f "$config" ]] || die "fidelity config not found: $config"
  cmake -D"FIDELITY_FILE=$config" -D"OUTPUT_FILE=$output" -P "$render_script"
}

render_fidelity "$fidelity" "$run_dir/input2d"
cp "$vertex_file" "$run_dir/eel2d.vertex"
cp "$training" "$run_dir/settings.json"
if [[ $mode == train ]]; then
  cp "$task" "$run_dir/task.conf"
  task_file_manifest="$run_dir/task.conf"
  task_sha256=$(sha256sum "$run_dir/task.conf" | awk '{print $1}')
else
  task_file_manifest=not-applicable
  task_sha256=not-applicable
fi

manifest="$run_dir/manifest.txt"
{
  printf 'run_id=%s\n' "$run_id"
  printf 'utc_timestamp=%s\n' "$timestamp"
  printf 'revision=%s\n' "$revision"
  printf 'source=%s\n' "$source_dir"
  printf 'build=%s\n' "$build_dir"
  printf 'build_revision=%s\n' "$build_revision"
  printf 'build_manifest_sha256=%s\n' "$build_manifest_sha256"
  printf 'executable_sha256=%s\n' "$executable_sha256"
  printf 'executable=%s\n' "$executable"
  printf 'runtime_library=%s\n' "$runtime_library"
  printf 'runtime_library_sha256=%s\n' "$runtime_library_sha256"
  printf 'hostname=%s\n' "$hostname_value"
  printf 'os=%s\n' "$os_pretty"
  printf 'kernel=%s\n' "$kernel_value"
  printf 'environment_script=%s\n' "$env_script_used"
  printf 'mpi_version=%s\n' "$mpi_version"
  printf 'mpicc_command=%s\n' "$mpicc_command"
  printf 'mpicxx_command=%s\n' "$mpicxx_command"
  printf 'ibamr_root=%s\n' "$ibamr_build_root"
  printf 'ibamr_version=%s\n' "$ibamr_version"
  printf 'petsc_root=%s\n' "$petsc_root"
  printf 'petsc_version=%s\n' "$petsc_version"
  printf 'samrai_overlay=%s\n' "$samrai_overlay"
  printf 'samrai_patch_sha256=%s\n' "$samrai_patch_sha256"
  printf 'learner_ranks=%s\n' "$learner_ranks"
  printf 'learner_threads=%s\n' "$learner_threads"
  printf 'omp_num_threads=%s\n' "$OMP_NUM_THREADS"
  printf 'omp_dynamic=%s\n' "$OMP_DYNAMIC"
  printf 'omp_proc_bind=%s\n' "$OMP_PROC_BIND"
  printf 'omp_places=%s\n' "$OMP_PLACES"
  printf 'batch_size=%s\n' "$batch_size"
  printf 'network_precision_bytes=%s\n' "$network_precision_bytes"
  printf 'learner_audit_dir=%s\n' "$learner_audit_dir"
  printf 'learner_activity_gate=%s\n' "$learner_activity_gate"
  printf 'environment_count=%s\n' "$envs"
  printf 'ranks_per_environment=%s\n' "$ranks_per_env"
  printf 'total_mpi_ranks=%s\n' "$mpi_ranks"
  printf 'fidelity=%s\n' "$fidelity"
  printf 'training=%s\n' "$training"
  printf 'eel_mode=%s\n' "$eel_mode"
  printf 'task_file=%s\n' "$task_file_manifest"
  printf 'task_sha256=%s\n' "$task_sha256"
  printf 'train_steps=%s\n' "$effective_train_steps"
  printf 'state_dimension=%s\n' "$state_dimension"
  printf 'action_dimension=%s\n' "$action_dimension"
  printf 'control_stage=%s\n' "$control_stage"
  printf 'smoke_steps=%s\n' "$smoke_steps"
  printf 'fault_after_initialize=%s\n' "$fault_after_initialize"
  printf 'gcc_version=%s\n' "$(gcc -dumpfullversion -dumpversion)"
  printf 'gxx_version=%s\n' "$(g++ -dumpfullversion -dumpversion)"
  printf 'input_sha256=%s\n' "$(sha256sum "$run_dir/input2d" | awk '{print $1}')"
  printf 'settings_sha256=%s\n' "$(sha256sum "$run_dir/settings.json" | awk '{print $1}')"
  printf 'command='
  printf '%q ' "${command[@]}"
  printf '\n'
} >"$manifest"

process_snapshot()
{
  local scope=$1 output=$2 uid pid name
  uid=$(id -u)
  : >"$output"
  while read -r pid name; do
    case $name in
      mpiexec|prterun|orterun|ibamr_eel2d_sm|ibamr_eel2d_smoke|\
      smarties_cpu_le|smarties_cpu_learner_environment)
        if [[ -r /proc/$pid/environ ]] &&
           tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null |
             grep -Fqx "SMARTIES_EEL_RUN_SCOPE=$scope"; then
          ps -p "$pid" -o pid= -o comm= -o args= >>"$output" 2>/dev/null || true
        fi
        ;;
    esac
  done < <(ps -u "$uid" -o pid= -o comm=)
}

set +e
(
  cd "$run_dir"
  SMARTIES_EEL_RUN_SCOPE="$run_dir/main" \
    "${command[@]}" 2>&1 | tee stdout.log
  exit "${PIPESTATUS[0]}"
)
status=$?
set -e
printf '%s\n' "$status" >"$run_dir/exit_code.txt"
printf 'exit_code=%s\n' "$status" >>"$manifest"
process_snapshot "$run_dir/main" "$run_dir/processes-after.txt"

if ((learner_activity_gate == 0)); then
  exit "$status"
fi

[[ -f $activity_wrapper ]] || die "learner activity wrapper not found: $activity_wrapper"
if ((status != 0)) || [[ -s $run_dir/processes-after.txt ]]; then
  printf 'NOT_RUN\n' >"$run_dir/restart_exit_code.txt"
  : >"$run_dir/restart-processes-after.txt"
else
  [[ -x $synthetic_executable ]] ||
    die "synthetic checkpoint reload executable is missing: $synthetic_executable"
  restart_dir="$run_dir/checkpoint-reload"
  restart_audit_dir="$run_dir/restart-audit"
  mkdir -p "$restart_dir"
  cp "$training" "$restart_dir/settings.json"
  restart_args=(
    --nMasters 1
    --nThreads "$learner_threads"
    --nEnvironments 1
    --workerProcessesPerEnv 1
    --learnersOnWorkers 0
    --nTrainSteps 0
    --nEvalEpisodes 1
    --randSeed 11
    --learnerAuditDir "$restart_audit_dir"
    --restart "$learner_audit_dir/final"
    --redirectAppStdoutToFile 0
  )
  if ((learner_threads > 1)); then
    restart_command=(mpiexec --bind-to core --map-by slot:PE=4 -n 2
      "$synthetic_executable" "${restart_args[@]}")
  else
    restart_command=(mpiexec -n 2 "$synthetic_executable" "${restart_args[@]}")
  fi
  printf 'CHECKPOINT_RELOAD_COMMAND='
  printf '%q ' "${restart_command[@]}"
  printf '\n'
  set +e
  (
    cd "$restart_dir"
    SMARTIES_EEL_RUN_SCOPE="$run_dir/restart" \
      "${restart_command[@]}" >"$run_dir/restart_stdout.log" \
      2>"$run_dir/restart_stderr.log"
  )
  restart_status=$?
  set -e
  printf '%s\n' "$restart_status" >"$run_dir/restart_exit_code.txt"
  process_snapshot "$run_dir/restart" "$run_dir/restart-processes-after.txt"
  {
    printf 'restart_executable=%s\n' "$synthetic_executable"
    printf 'restart_executable_sha256=%s\n' \
      "$(sha256sum "$synthetic_executable" | awk '{print $1}')"
    printf 'restart_command='
    printf '%q ' "${restart_command[@]}"
    printf '\n'
    printf 'restart_exit_code=%s\n' "$restart_status"
  } >>"$manifest"
fi

set +e
activity_output=$(cmake -DRUN_DIR="$run_dir" -P "$activity_wrapper" 2>&1)
activity_status=$?
set -e
printf '%s\n' "$activity_output" | tee "$run_dir/learner_activity_verdict.txt"
exit "$activity_status"
