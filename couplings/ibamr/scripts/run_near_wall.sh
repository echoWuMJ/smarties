#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
action=${1:-}
run=''
config=''
argv=("$@")
while (($#)); do
  case "$1" in
    --run) run=${2:?missing --run value}; shift 2;;
    --config) config=${2:?missing --config value}; shift 2;;
    *) shift;;
  esac
done
if [[ $action != start && $action != resume && $action != stop ]]; then
  echo 'Usage: run_near_wall.sh start --run /path --config /path/node4.json' >&2
  echo '       run_near_wall.sh resume|stop --run /path' >&2
  exit 64
fi
[[ $run == /* ]] || { echo '--run must be absolute' >&2; exit 64; }
if [[ $action != start ]]; then config="$run/run-config.json"; fi
[[ -r $config ]] || { echo "cannot read configuration: $config" >&2; exit 66; }
# System Python only bootstraps the two paths. Runtime uses the specified uv
# Python 3.12 installation. Values are arguments, never evaluated as shell code.
bootstrap=$(python3 - "$config" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    cfg = json.load(stream)
for key in ('environment_script', 'python'):
    value = cfg[key]
    if not isinstance(value, str) or not value.startswith('/') or '\n' in value:
        raise SystemExit('invalid runtime path: ' + key)
    print(value)
PY
)
mapfile -t runtime_paths <<< "$bootstrap"
[[ ${#runtime_paths[@]} == 2 ]] || exit 64
# Existing site setup files may reference unset optional variables.
set +u
source "${runtime_paths[0]}"
set -u
exec "${runtime_paths[1]}" "$script_dir/paired_run.py" "${argv[@]}"
