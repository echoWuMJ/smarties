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
  --fidelity LEVEL         coarse, medium, fine, or curriculum (default: coarse)
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
fidelity=coarse
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
    --envs|--ranks-per-env|--learner-ranks|--fidelity|--training|--smoke-steps|--train-steps|--task|--source|--build)
      (($# >= 2)) || die "missing value after $1"
      option=$1
      value=$2
      case $option in
        --envs) envs=$value ;;
        --ranks-per-env) ranks_per_env=$value ;;
        --learner-ranks) learner_ranks=$value ;;
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
is_positive_integer "$smoke_steps" ||
  die "--smoke-steps must be a positive integer"
if [[ $mode == train ]]; then
  is_positive_integer "$train_steps" ||
    die "--train-steps must be a positive integer"
  [[ -n $task ]] || die "--task is required for train mode"
fi
case $fidelity in
  coarse|medium|fine|curriculum) ;;
  *) die "--fidelity must be coarse, medium, fine, or curriculum" ;;
esac

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
fi

environment_ranks=$((envs * ranks_per_env))
mpi_ranks=$((learner_ranks + environment_ranks))
revision=$(revision_of "$source_dir")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_id="eel2d-${timestamp}-${revision}-$$"
run_dir="$source_dir/couplings/ibamr/runs/$run_id"
executable="$build_dir/couplings/ibamr/ibamr_eel2d_smoke"
build_manifest="$build_dir/couplings/ibamr/build_manifest.txt"
build_script="$source_dir/couplings/ibamr/scripts/build_node3.sh"
fidelity_dir="$source_dir/couplings/ibamr/configs/fidelity"
render_script="$source_dir/couplings/ibamr/scripts/render_input.cmake"
vertex_file="$source_dir/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex"

preflight

build_is_current()
{
  [[ -x "$executable" && -f "$build_manifest" ]] || return 1
  local recorded_revision recorded_source recorded_executable recorded_sha actual_sha
  recorded_revision=$(manifest_value revision "$build_manifest")
  recorded_source=$(manifest_value source "$build_manifest")
  recorded_sha=$(manifest_value executable_sha256 "$build_manifest")
  recorded_executable=$(manifest_value executable "$build_manifest")
  [[ "$recorded_revision" == "$revision" ]] || return 1
  [[ "$recorded_source" == "$source_dir" ]] || return 1
  [[ "$recorded_executable" == "$executable" ]] || return 1
  [[ $recorded_sha =~ ^[0-9a-f]{64}$ ]] || return 1
  actual_sha=$(sha256sum "$executable" | awk '{print $1}')
  [[ "$actual_sha" == "$recorded_sha" ]] || return 1
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
  build_manifest_sha256=$(sha256sum "$build_manifest" | awk '{print $1}')
  ibamr_build_root=$(manifest_value ibamr_root "$build_manifest")
  ibamr_version=$(manifest_value ibamr_version "$build_manifest")
  petsc_root=$(manifest_value petsc_root "$build_manifest")
  petsc_version=$(manifest_value petsc_version "$build_manifest")
  samrai_overlay=$(manifest_value samrai_overlay "$build_manifest")
  samrai_patch_sha256=$(manifest_value samrai_patch_sha256 "$build_manifest")
else
  build_revision=unbuilt
  executable_sha256=unbuilt
  build_manifest_sha256=unbuilt
  ibamr_build_root=unbuilt
  ibamr_version=unbuilt
  petsc_root=unbuilt
  petsc_version=unbuilt
  samrai_overlay=unbuilt
  samrai_patch_sha256=unbuilt
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

launch_args=(
  --nMasters "$learner_ranks"
  --nThreads 1
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
  launch_args+=(--task-file task.conf)
fi

if ((fault_after_initialize)); then
  launch_args+=(--fault-after-initialize)
fi

if [[ $fidelity == curriculum ]]; then
  launch_args+=(
    --appSettings "app-coarse.args,app-medium.args,app-fine.args"
    --nStepPappSett "1,1,0"
  )
fi
command=(mpiexec -n "$mpi_ranks" "$executable" "${launch_args[@]}")

printf 'SOURCE=%s\n' "$source_dir"
printf 'BUILD=%s\n' "$build_dir"
printf 'RUN_ID=%s\n' "$run_id"
printf 'RUN_DIRECTORY=%s\n' "$run_dir"
printf 'LEARNER_RANKS=%s\n' "$learner_ranks"
printf 'ENVIRONMENT_RANKS=%s\n' "$environment_ranks"
printf 'MPI_RANKS=%s\n' "$mpi_ranks"
printf 'FIDELITY=%s\n' "$fidelity"
printf 'EEL_MODE=%s\n' "$eel_mode"
printf 'CONTROL_STAGE=%s\n' "$control_stage"
printf 'BUILD_STATUS=%s\n' "$build_status"
printf 'BUILD_REVISION=%s\n' "$build_revision"
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

if [[ $fidelity == curriculum ]]; then
  for level in coarse medium fine; do
    render_fidelity "$level" "$run_dir/input2d.$level"
    if [[ $mode == smoke ]]; then
      printf '%s\n' "--input-file input2d.$level --eel-mode smoke --smoke-steps $smoke_steps" \
        >"$run_dir/app-$level.args"
    else
      printf '%s\n' "--input-file input2d.$level --eel-mode speed-tracking --task-file task.conf" \
        >"$run_dir/app-$level.args"
    fi
  done
  cp "$run_dir/input2d.coarse" "$run_dir/input2d"
else
  render_fidelity "$fidelity" "$run_dir/input2d"
fi
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

set +e
(
  cd "$run_dir"
  "${command[@]}" 2>&1 | tee stdout.log
  exit "${PIPESTATUS[0]}"
)
status=$?
set -e
printf '%s\n' "$status" >"$run_dir/exit_code.txt"
printf 'exit_code=%s\n' "$status" >>"$manifest"
exit "$status"
