#!/usr/bin/env bash
# Bounded real-CFD external-process protocol check, not policy training.
set -euo pipefail
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
build=/data2/mjwu/local/coupling-build/smarties-near-wall-20260908
prefix=/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1/packages/IBAMR-0.18.0
run=${1:?Supply a new absolute validation directory}
export LD_LIBRARY_PATH="$prefix/lib64:$build/lib:${LD_LIBRARY_PATH:-}"
py=/data2/mjwu/local/smarties/.venv/bin/python
"$py" "$src/couplings/ibamr/scripts/prepare_near_wall_run.py" "$src" "$run"
cp "$src/couplings/ibamr/tests/fixtures/near_wall_protocol.json" "$run/settings.json"
"$py" "$src/couplings/ibamr/scripts/external_episode_manager.py" \
  --run "$run" --build "$build" --environments "${NEAR_WALL_ENVS:-1}" \
  --ranks "${NEAR_WALL_RANKS:-2}" --threads "${NEAR_WALL_LEARNER_THREADS:-2}" \
  --steps 2 --max-periods 0.00015
echo NEAR_WALL_CHECK_COMPLETE
