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
  --source DIR             Immutable Smarties source snapshot
  --build DIR              Matching node3 build directory
  --dry-run                Validate and print the derived launch command

The phase-one smoke mode validates process ownership and the communication
lifecycle. It does not implement a fish control law or meaningful RL reward.
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

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(cd "$script_dir/../../.." && pwd)
mode=${1:-}
[[ -n "$mode" ]] || {
  usage >&2
  exit 64
}
shift

if [[ $mode == train ]]; then
  printf 'run_node3.sh: train mode is not supported until the state, action, reward, and physical control specification is approved\n' >&2
  exit 64
fi
[[ $mode == smoke ]] || die "mode must be 'smoke' or 'train'" 64

envs=1
ranks_per_env=1
learner_ranks=1
fidelity=coarse
training=couplings/ibamr/configs/training/smoke.json
smoke_steps=1
build_dir=
dry_run=0

while (($#)); do
  case $1 in
    --envs|--ranks-per-env|--learner-ranks|--fidelity|--training|--smoke-steps|--source|--build)
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
        --source) source_dir=$value ;;
        --build) build_dir=$value ;;
      esac
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

is_positive_integer "$envs" || die "--envs must be a positive integer"
is_positive_integer "$ranks_per_env" ||
  die "--ranks-per-env must be a positive integer"
is_positive_integer "$learner_ranks" ||
  die "--learner-ranks must be a positive integer"
is_positive_integer "$smoke_steps" ||
  die "--smoke-steps must be a positive integer"
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

environment_ranks=$((envs * ranks_per_env))
mpi_ranks=$((learner_ranks + environment_ranks))
revision=$(revision_of "$source_dir")
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_id="eel2d-${timestamp}-${revision}-$$"
run_dir="$source_dir/couplings/ibamr/runs/$run_id"
executable="$build_dir/couplings/ibamr/ibamr_eel2d_smoke"
fidelity_dir="$source_dir/couplings/ibamr/configs/fidelity"
render_script="$source_dir/couplings/ibamr/scripts/render_input.cmake"
vertex_file="$source_dir/couplings/ibamr/cases/eel2d/upstream/eel2d.vertex"

preflight

launch_args=(
  --nMasters "$learner_ranks"
  --nThreads 1
  --nEnvironments "$envs"
  --workerProcessesPerEnv "$ranks_per_env"
  --learnersOnWorkers 0
  --nTrainSteps 0
  --restart none
  --setupFolder .
  --input-file input2d
  --smoke-steps "$smoke_steps"
)

if [[ $fidelity == curriculum ]]; then
  launch_args+=(
    --appSettings "app-coarse.args;app-medium.args;app-fine.args"
    --nStepPappSett "1;1;0"
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
printf 'COMMAND='
printf '%q ' "${command[@]}"
printf '\n'

if ((dry_run)); then
  exit 0
fi

[[ -x "$executable" ]] || die "coupling executable not found: $executable"
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
    printf '%s\n' "--input-file input2d.$level --smoke-steps $smoke_steps" \
      >"$run_dir/app-$level.args"
  done
  cp "$run_dir/input2d.coarse" "$run_dir/input2d"
else
  render_fidelity "$fidelity" "$run_dir/input2d"
fi
cp "$vertex_file" "$run_dir/eel2d.vertex"
cp "$training" "$run_dir/settings.json"

manifest="$run_dir/manifest.txt"
{
  printf 'run_id=%s\n' "$run_id"
  printf 'utc_timestamp=%s\n' "$timestamp"
  printf 'revision=%s\n' "$revision"
  printf 'source=%s\n' "$source_dir"
  printf 'build=%s\n' "$build_dir"
  printf 'learner_ranks=%s\n' "$learner_ranks"
  printf 'environment_count=%s\n' "$envs"
  printf 'ranks_per_environment=%s\n' "$ranks_per_env"
  printf 'total_mpi_ranks=%s\n' "$mpi_ranks"
  printf 'fidelity=%s\n' "$fidelity"
  printf 'training=%s\n' "$training"
  printf 'smoke_steps=%s\n' "$smoke_steps"
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
