#!/usr/bin/env bash

set -euo pipefail

die()
{
  printf 'CPU_LEARNER_VALIDATION verdict=OPERATIONAL_INCOMPLETE report=%s\n' "$*" >&2
  exit 1
}

source_dir=
build_dir=
run_root=
threads=
seed=
updates=
training=
while (($#)); do
  case $1 in
    --source) source_dir=$2; shift 2 ;;
    --build) build_dir=$2; shift 2 ;;
    --run-root) run_root=$2; shift 2 ;;
    --threads) threads=$2; shift 2 ;;
    --seed) seed=$2; shift 2 ;;
    --updates) updates=$2; shift 2 ;;
    --training) training=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $source_dir && -n $build_dir && -n $run_root && -n $threads &&
   -n $seed && -n $updates && -n $training ]] || die "all runner arguments are required"
[[ $source_dir == /* && $build_dir == /* && $run_root == /* ]] ||
  die "source, build, and run-root must be absolute"
[[ $threads == 1 || $threads == 4 ]] || die "threads must be 1 or 4"
[[ $seed =~ ^[1-9][0-9]*$ ]] || die "seed must be a positive integer"
[[ $updates =~ ^[1-9][0-9]*$ ]] || die "updates must be a positive integer"
[[ -d $source_dir && -f $source_dir/CMakeLists.txt ]] || die "source tree is missing"
[[ -d $build_dir ]] || die "build tree is missing"
source_dir=$(cd "$source_dir" && pwd -P)
build_dir=$(cd "$build_dir" && pwd -P)

if [[ $training != /* ]]; then
  training="$source_dir/$training"
fi
[[ -f $training ]] || die "training settings are missing: $training"
training=$(cd "$(dirname "$training")" && pwd -P)/$(basename "$training")

batch_size=$(awk '
  match($0, /"batchSize"[[:space:]]*:[[:space:]]*[0-9]+/) {
    value=substr($0, RSTART, RLENGTH)
    sub(/^.*:[[:space:]]*/, "", value)
    print value
    exit
  }
' "$training")
[[ $batch_size =~ ^[1-9][0-9]*$ ]] || die "training settings require a positive integer batchSize"
((batch_size >= threads)) || die "batchSize must be at least threads"
((batch_size % threads == 0)) || die "batchSize must be divisible by threads"

revision_of()
{
  local directory=$1 revision basename_value
  if git -C "$directory" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    [[ -z $(git -C "$directory" status --porcelain --untracked-files=all) ]] ||
      die "source tree is dirty: $directory"
    git -C "$directory" rev-parse --short=12 HEAD
    return
  fi
  basename_value=$(basename "$directory")
  if [[ $basename_value =~ ([0-9a-f]{12})$ ]]; then
    revision=${BASH_REMATCH[1]}
    printf '%s\n' "$revision"
    return
  fi
  die "cannot derive immutable source revision from $directory"
}

manifest_value()
{
  local key=$1 manifest=$2
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$manifest"
}

revision=$(revision_of "$source_dir")
executable="$build_dir/couplings/ibamr/smarties_cpu_learner_environment"
runtime_library="$build_dir/lib/libsmarties.so"
build_manifest="$build_dir/couplings/ibamr/build_manifest.txt"
comparator="$source_dir/couplings/ibamr/tests/CpuLearnerConvergenceCompare.cmake"
[[ -x $executable ]] || die "synthetic learner executable is missing or not executable"
[[ -f $runtime_library && -f $build_manifest && -f $comparator ]] ||
  die "build runtime, manifest, or comparator is missing"

recorded_revision=$(manifest_value revision "$build_manifest")
recorded_source=$(manifest_value source "$build_manifest")
recorded_runtime=$(manifest_value runtime_library "$build_manifest")
recorded_runtime_sha=$(manifest_value runtime_library_sha256 "$build_manifest")
actual_runtime_sha=$(sha256sum "$runtime_library" | awk '{print $1}')
[[ $recorded_revision == "$revision" ]] || die "build revision does not match source"
[[ $recorded_source == "$source_dir" ]] || die "build source path does not match source"
[[ $recorded_runtime == "$runtime_library" ]] || die "runtime library path does not match build"
[[ $recorded_runtime_sha =~ ^[0-9a-f]{64}$ &&
   $recorded_runtime_sha == "$actual_runtime_sha" ]] ||
  die "runtime library hash does not match build manifest"

run_dir="$run_root/run"
[[ ! -e $run_dir ]] || die "run directory already exists: $run_dir"
mkdir -p "$run_dir"
executable_sha=$(sha256sum "$executable" | awk '{print $1}')
manifest_sha=$(sha256sum "$build_manifest" | awk '{print $1}')
cat >"$run_dir/run_manifest.txt" <<EOF
revision=$revision
source=$source_dir
build=$build_dir
executable=$executable
executable_sha256=$executable_sha
runtime_library=$runtime_library
runtime_library_sha256=$actual_runtime_sha
build_manifest_sha256=$manifest_sha
threads=$threads
seed=$seed
updates=$updates
batch_size=$batch_size
mpi_ranks=5
processing_elements_per_rank=4
logical_cpus=20
omp_dynamic=FALSE
omp_proc_bind=close
omp_places=cores
EOF

export OMP_NUM_THREADS=$threads
export OMP_DYNAMIC=FALSE
export OMP_PROC_BIND=close
export OMP_PLACES=cores
mpiexec_command=${SMARTIES_CPU_MPIEXEC:-mpiexec}
child_timeout=${SMARTIES_CPU_CHILD_TIMEOUT:-900}
[[ $child_timeout =~ ^[1-9][0-9]*$ ]] || die "SMARTIES_CPU_CHILD_TIMEOUT must be positive"

process_snapshot()
{
  local scope=$1 output=$2 uid pid name
  uid=$(id -u)
  : >"$output"
  while read -r pid name; do
    case $name in
      mpiexec|prterun|orterun|smarties_cpu_le|smarties_cpu_learner_environment)
        if [[ -r /proc/$pid/environ ]] &&
           tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null |
             grep -Fqx "SMARTIES_CPU_RUN_SCOPE=$scope"; then
          ps -p "$pid" -o pid= -o comm= -o args= >>"$output" 2>/dev/null || true
        fi
        ;;
    esac
  done < <(ps -u "$uid" -o pid= -o comm=)
}

process_snapshot "$run_dir" "$run_dir/processes-before.txt"
if [[ -s $run_dir/processes-before.txt ]]; then
  die "stale learner/environment/MPI process exists before launch"
fi

print_command()
{
  printf 'COMMAND='
  printf '%q ' "$@"
  printf '\n'
}

launch_stage()
{
  local stage=$1 restart=$2
  local directory="$run_dir/$stage" audit="$run_dir/$stage/audit"
  mkdir -p "$directory"
  cp "$training" "$directory/settings.json"
  local command=("$mpiexec_command" --bind-to core --map-by slot:PE=4 -n 5
    "$executable" --nMasters 1 --nThreads "$threads"
    --nEnvironments 4 --workerProcessesPerEnv 1 --learnersOnWorkers 0
    --randSeed "$seed" --learnerAuditDir "$audit"
    --redirectAppStdoutToFile 0)
  if [[ $restart == none ]]; then
    command+=(--nTrainSteps "$updates" --restart none)
  else
    command+=(--nTrainSteps 0 --nEvalEpisodes 8 --restart "$restart")
  fi
  print_command "${command[@]}"
  set +e
  (cd "$directory" && SMARTIES_CPU_RUN_SCOPE="$directory" \
    timeout --signal=TERM "${child_timeout}s" "${command[@]}") \
    >"$directory/stdout.log" 2>"$directory/stderr.log"
  local status=$?
  set -e
  printf '%s\n' "$status" >"$directory/exit_status.txt"
  process_snapshot "$directory" "$directory/processes-after.txt"
  if [[ -s $directory/processes-after.txt ]]; then
    die "stage $stage left a learner/environment/MPI process"
  fi
  if ((status != 0)); then
    die "stage $stage exited $status (timeout or child failure)"
  fi
}

launch_stage training none
[[ -d $run_dir/training/audit/initial && -d $run_dir/training/audit/final ]] ||
  die "training did not create initial and final checkpoints"
launch_stage evaluation-initial "$run_dir/training/audit/initial"
launch_stage evaluation-final "$run_dir/training/audit/final"

write_metrics()
{
  local stdout_log=$1 metrics=$2
  if ! awk -v expected_seed="$seed" '
    function value(key,   i,pair) {
      for(i=1; i<=NF; ++i) {
        split($i, pair, "=")
        if(pair[1] == key) return pair[2]
      }
      return ""
    }
    /^SMARTIES_SYNTHETIC_SUMMARY / {
      seen++
      record_seed=value("seed")
      record_episodes=value("episodes") + 0
      record_decisions=value("decisions") + 0
      record_return=value("mean_return") + 0
      record_mse=value("action_mse") + 0
      if(record_seed != expected_seed || value("finite") != "1" ||
         record_episodes <= 0 || record_decisions <= 0) valid=0
      episodes += record_episodes
      decisions += record_decisions
      return_sum += record_return * record_episodes
      squared_error += record_mse * record_decisions
    }
    BEGIN { valid=1 }
    END {
      if(seen < 1 || !valid || decisions != 256 || episodes < 1) exit 2
      printf "CPU_LEARNER_METRICS seed=%s episodes=%d decisions=%d mean_return=%.17g action_mse=%.17g finite=1\n", expected_seed, episodes, decisions, return_sum/episodes, squared_error/decisions
    }
  ' "$stdout_log" >"$metrics"; then
    die "evaluation summary is missing, malformed, non-finite, wrong-seed, or not 256 decisions"
  fi
}

write_metrics "$run_dir/evaluation-initial/stdout.log" \
              "$run_dir/evaluation-initial/metrics.txt"
write_metrics "$run_dir/evaluation-final/stdout.log" \
              "$run_dir/evaluation-final/metrics.txt"

set +e
comparison=$(cmake -DONE_RUN_DIR="$run_dir" -DEXPECTED_SEED="$seed" \
  -DEXPECTED_UPDATES="$updates" -P "$comparator" 2>&1)
comparison_status=$?
set -e
printf '%s\n' "$comparison" | tee "$run_dir/comparison.txt"
exit "$comparison_status"
