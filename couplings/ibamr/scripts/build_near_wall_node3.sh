#!/usr/bin/env bash
set -euo pipefail
source /data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh
src=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
overlay=/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1
build=/data2/mjwu/local/coupling-build/smarties-near-wall-20260908
export IBAMR_ROOT="$overlay/packages/IBAMR-0.18.0"
cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/data2/mjwu/local/gcc-8.5.0/bin/gcc \
  -DCMAKE_CXX_COMPILER=/data2/mjwu/local/gcc-8.5.0/bin/g++ \
  -DCOMPILE_PY_SO=OFF -DBUILD_IBAMR_COUPLING=ON -DBUILD_IBAMR_COUPLING_TESTS=ON \
  -DIBAMR_DIR="$IBAMR_ROOT/lib64/cmake/ibamr"
cmake --build "$build" --parallel 8 --target ibamr_eel2d_smoke eel_near_wall_episode eel_near_wall_task_test
echo NEAR_WALL_BUILD_COMPLETE
