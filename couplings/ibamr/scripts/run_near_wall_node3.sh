#!/usr/bin/env bash
set -euo pipefail
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
build=${NEAR_WALL_BUILD:-/data2/mjwu/local/coupling-build/smarties-near-wall-20260908}
prefix=${NEAR_WALL_IBAMR:-/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1/packages/IBAMR-0.18.0}
envs=${NEAR_WALL_ENVS:-2}
ranks=${NEAR_WALL_RANKS:-16}
threads=${NEAR_WALL_LEARNER_THREADS:-8}
steps=${NEAR_WALL_STEPS:-8192}
for value in "$envs" "$ranks" "$threads" "$steps"; do
  [[ $value =~ ^[1-9][0-9]*$ ]] || { echo 'positive integer required' >&2; exit 64; }
done
((envs*ranks<=32)) || { echo 'IBAMR ranks must not exceed 32' >&2; exit 64; }
run=${1:?Usage: run_near_wall_node3.sh NEW_ABSOLUTE_RUN_DIRECTORY}
[[ $run == /* ]] || { echo 'run directory must be absolute' >&2; exit 64; }
export LD_LIBRARY_PATH="$prefix/lib64:$build/lib:${LD_LIBRARY_PATH:-}"
export OMP_NUM_THREADS=$threads OMP_DYNAMIC=FALSE OPENBLAS_NUM_THREADS=1
exe="$build/couplings/ibamr/ibamr_eel2d_smoke"
[[ -x $exe ]] || { echo "missing executable: $exe" >&2; exit 66; }
/data2/mjwu/local/smarties/.venv/bin/python \
  "$src/couplings/ibamr/scripts/prepare_near_wall_run.py" "$src" "$run"
cd "$run"
# The supervisor is not an MPI rank. It starts independent MPI jobs.
/data2/mjwu/local/smarties/.venv/bin/python "$src/couplings/ibamr/scripts/external_episode_manager.py" \
  --run "$run" --build "$build" --environments "$envs" --ranks "$ranks" \
  --threads "$threads" --steps "$steps" \
  --max-periods "${NEAR_WALL_MAX_PERIODS:-10}"
