"""Node3 integration probe: invalid CFD input must stop the supervisor/learner.

Uses a fresh directory supplied by the caller. Never modifies training inputs.
"""
import os
from pathlib import Path
import subprocess
import sys

source, build, directory = map(Path, sys.argv[1:])
subprocess.run([sys.executable, str(source/"couplings/ibamr/scripts/prepare_near_wall_run.py"),
                str(source), str(directory)], check=True)
(directory/"input2d").write_text("Intentionally invalid input for failure propagation check.\n")
with (directory/"supervisor.log").open("w") as log:
    result = subprocess.run([sys.executable,
        str(source/"couplings/ibamr/scripts/external_episode_manager.py"),
        "--run",str(directory),"--build",str(build),"--environments","1",
        "--ranks","2","--threads","2","--steps","2"],stdout=log,stderr=subprocess.STDOUT)
assert result.returncode != 0, "CFD failure was reported as success"
assert int((directory/"manager.exit.status").read_text()) != 0
assert int((directory/"env_1/episode_1/exit.status").read_text()) != 0
assert (directory/"exit.status").exists(), "learner was not reaped"
for path in directory.glob("**/launcher.pid"):
    try:
        os.kill(int(path.read_text()),0)
    except ProcessLookupError:
        continue
    raise AssertionError(f"launcher remains alive: {path}")
print("EXTERNAL_FAILURE_PROPAGATION_PASS")
