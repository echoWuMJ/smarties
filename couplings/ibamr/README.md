# Smarties-IBAMR eel2d coupling

This directory contains the executable coupling framework for the IBAMR 0.18.0
`eel2d` example and Smarties. The original `smoke` mode remains a lifecycle
probe. The experimental stage-two `train` mode applies one bounded Smarties
action to the official eel tail-beat frequency, observes a five-component
target-speed state, and advances multiple native IBAMR steps per decision.

Stage two supports one multi-decision physical episode. It does **not** yet
reconstruct/reset IBAMR for independent episodes, establish policy quality,
measure swimming energy/efficiency, or enable PyTorch/CUDA.

## Fixed process architecture

- `CouplingDriver` is the sole owner of `MPI_Init_thread` and `MPI_Finalize`.
- Smarties borrows `MPI_COMM_WORLD`; it must not finalize caller-owned MPI.
- Smarties learner ranks and IBAMR environment ranks are separate.
- Launches always use `--learnersOnWorkers 0`; IBAMR ranks do not host networks.
- No process is forked after MPI initialization.
- Both modes use the native CPU Smarties learner. PyTorch/CUDA are not enabled.

## Build on node3

Upload or extract an immutable source snapshot, then run:

```bash
./couplings/ibamr/scripts/build_node3.sh \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot>
```

The script sources
`/data2/mjwu/autoibamr-v0.18.0/configuration/enable.sh` and rejects the build
before CMake unless GCC/G++ 8.5.0, the matching Open MPI wrappers, and the base
IBAMR 0.18.0 environment are active. It then creates or reuses the isolated
dependency overlay
`/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1`. The shared
autoibamr installation is never modified. Python bindings remain disabled.

The overlay is required because the IBSAMRAI2 source bundled on node3 contains
operational `MPI_COMM_WORLD` calls in its box-clustering code. Those calls
deadlock when an IBAMR environment uses a Smarties-created MPI
subcommunicator. The tracked patch redirects them to the active SAMRAI or
caller-supplied communicator. To prepare the overlay explicitly, run:

```bash
./couplings/ibamr/scripts/prepare_node3_ibamr.sh
```

The overlay is content-guarded by the SHA-256 of
`patches/ibsamrai2-subcommunicator.patch`; a stale or partial overlay is not
silently reused.

Create the snapshot locally with:

```powershell
.\couplings\ibamr\scripts\package_local.ps1 `
  -Repository . `
  -OutputDirectory .artifacts\packages
```

Packages contain tracked files only by default. A required untracked file must
be named explicitly with `-IncludeUntracked`; unrelated untracked work is never
copied implicitly. `SOURCE_METADATA.txt` records the full Git revision, tracked
dirty state, allowlisted files, and excluded gitlinks. After extraction,
`SOURCE_MANIFEST.sha256` validates every packaged source and metadata file from
the archive root. Shell scripts are normalized to UTF-8/LF in the package
staging area so an archive created on Windows remains directly executable on
node3; the local working tree is not rewritten.

## One-command smoke run

From the source snapshot:

```bash
./couplings/ibamr/scripts/run_node3.sh smoke \
  --envs 1 \
  --ranks-per-env 1 \
  --fidelity coarse \
  --training couplings/ibamr/configs/training/smoke.json \
  --smoke-steps 1
```

The launcher derives total MPI ranks as:

```text
learner ranks + environments * ranks per environment
```

`--fidelity` accepts `coarse`, `medium`, `fine`, or `curriculum`. Each real run
gets a unique directory below `couplings/ibamr/runs/` containing the rendered
input, copied settings, stdout log, exit code, and a revision/hash manifest.
Use `--dry-run` to validate the environment and print the command without
creating a run directory.

The build writes `couplings/ibamr/build_manifest.txt` inside the selected build
directory. A real run verifies its source revision, source path, and executable
SHA-256. If the executable is missing, stale, or changed, `run_node3.sh`
automatically invokes the matching snapshot's `build_node3.sh` before MPI is
started. The run manifest records both source and verified build identities.
It also records the host, OS/kernel, compiler and MPI wrapper identities,
IBAMR/PETSc roots and versions, and the isolated SAMRAI overlay patch hash.

`--fault-after-initialize` is a test-only failure injection. It starts MPI and
initializes the real IBAMR environment, then exercises the fatal callback path;
the environment communicator is aborted without any private `MPI_Finalize`.

## Experimental frequency-control run

Use an explicitly calibrated task file for scientific runs. The committed
example and protocol-test files contain placeholders or synthetic values and
must not be treated as node3 calibration evidence.

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --envs 1 \
  --ranks-per-env 1 \
  --fidelity coarse \
  --training couplings/ibamr/configs/training/speed_tracking.json \
  --task /absolute/or/repository/relative/task.conf \
  --train-steps 1
```

The launcher validates the task-file structure before building or launching
MPI, copies the selected file to the run directory as `task.conf`, and passes
only that frozen copy to the adapter. The run manifest records its SHA-256,
the five-state/one-action dimensions, training-step budget, executable path and
hash, and `control_stage=stage2_physical_control_experimental`.

Smarties counts `nTrainSteps` only after its initial replay-data threshold.
Because this stage deliberately runs exactly one physical episode, the launcher
rejects a budget larger than `episode_decisions - minTotObsNum`; such a run
cannot reach Smarties termination without a reset. The conservative baseline
uses `minTotObsNum=1` and `--train-steps 1`.

One action in `[-1,1]` requests a configured frequency ratio; clipping and slew
limits are applied before the command reaches `EelEnvironment`. IBAMR owns the
inner CFD loop and returns actual start/end times and center-of-mass positions.
The adapter uses those actual values for interval-averaged velocity and logs
tracking, frequency-regularization, and smoothness reward terms separately.
The frequency penalty is not a physical energy or efficiency measurement.

### Calibrated node3 coarse task

`configs/tasks/speed_tracking_node3_coarse.conf` is the admission configuration
for the official eel2d case at node3 coarse fidelity. A baseline-ratio run from
source revision `6b2faccc03f08c7a13edfa7e22f570d0ed54b2ff` advanced 10008 native
IBAMR steps over 1.0008 simulation-time units and measured global COM
displacement `(-0.11510557, 0.01536821)`. This gives the measured forward unit
direction `(-0.99120442, 0.13233973)`.

After the first four control intervals, interval-averaged speeds along that
direction ranged from 0.12050 to 0.13337. The configured target 0.125 is a
rounded conservative value inside that observed range, and `velocity_scale`
uses the same value so nominal observations are order one. One baseline cycle
is used as warm-up before a 16-decision episode. These values are specific to
this host, fidelity, case, and calibration revision; they are admission inputs,
not a claim of physical or control optimality.

The `train` path remains experimental until one immutable revision passes the
full node3 topology, repeated-run, failure-injection, process-cleanup, and
evidence-review admission matrix.

## Tests

```bash
bash couplings/ibamr/tests/test_node3_scripts.sh
powershell.exe -NoProfile -ExecutionPolicy Bypass \
  -File couplings/ibamr/tests/test_package_local.ps1
SAMRAI_SOURCE_ROOT=/data2/mjwu/autoibamr-v0.18.0/tmp/unpack/IBSAMRAI2-2025.10.29 \
  bash couplings/ibamr/tests/test_samrai_subcommunicator_patch.sh
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> --output-on-failure
```

Only results that pass the full admission gate may be promoted into
`experience/verified/`.
