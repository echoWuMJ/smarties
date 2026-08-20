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

Overlay reuse is guarded by two checks: `PATCHED_SMARTIES_SAMRAI.sha256` must
match the SHA-256 of `patches/ibsamrai2-subcommunicator.patch`, and the required
`IBAMRConfig.cmake` must exist. These checks do not hash the installed SAMRAI
or IBAMR libraries and therefore do not authenticate every overlay file.

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
  --fidelity medium \
  --training couplings/ibamr/configs/training/smoke.json \
  --smoke-steps 1
```

The launcher derives total MPI ranks as:

```text
learner ranks + environments * ranks per environment
```

`--fidelity` accepts only `medium` (and defaults to it). `coarse`, `fine`, and
`curriculum` are intentionally rejected before any build or MPI launch. Each
real run gets a unique directory below `couplings/ibamr/runs/` containing the
rendered input, copied settings, stdout log, exit code, and a revision/hash
manifest. Use `--dry-run` to validate the environment and print the command
without creating a run directory.

The build writes `couplings/ibamr/build_manifest.txt` inside the selected build
directory. A real run verifies its source revision and source path plus the
paths and SHA-256 identities of both the executable and build-tree
`lib/libsmarties.so`. If either runtime artifact is missing, stale, path
substituted, or changed, `run_node3.sh` automatically invokes the matching
snapshot's `build_node3.sh` before MPI is started. The run manifest records
both source and verified executable/library build identities.
It also records the host, OS/kernel, compiler and MPI wrapper identities,
IBAMR/PETSc roots and versions, and the isolated SAMRAI overlay patch hash.

`--fault-after-initialize` is a test-only failure injection. It starts MPI and
initializes the real IBAMR environment, then exercises the fatal callback path;
the environment communicator is aborted without any private `MPI_Finalize`.

## Experimental frequency-control run

Frequency-control runs require an explicitly provided task file. The committed
example and protocol-test files contain placeholders or synthetic values and
must not be treated as node3 calibration evidence. No calibrated medium task
configuration has been admitted.

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --envs 1 \
  --ranks-per-env 1 \
  --fidelity medium \
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

### Calibration status

The former coarse calibration and its task configuration were retracted after
the coarse layout was found invalid. The investigation is retained solely as
invalid evidence in the non-versioned artifact path
[`../../.artifacts/ibamr-smarties-investigations/coarse-lagrangian-collapse/investigation.md`](../../.artifacts/ibamr-smarties-investigations/coarse-lagrangian-collapse/investigation.md).
It is not an admission input, and it does not establish a target speed or
forward direction for medium fidelity.

The `train` path remains experimental until one immutable revision passes the
full node3 topology, repeated-run, failure-injection, process-cleanup, and
evidence-review admission matrix.

## Tests

### Native CPU learner convergence validation

`smarties_cpu_learner_environment` provides a deterministic five-state,
one-action analytic task for validating the production VRACER CPU learner.
The frozen validation trains one learner rank against four single-rank
synthetic environments, saves explicit initial/final audit checkpoints, and
evaluates both checkpoints on exactly 256 deterministic decisions. It requires
1024 finite optimizer updates, matching restart digests, at least a 50 percent
reduction in action MSE, and at least half of the return gap to zero to be
closed.

The runner's `--updates` value is passed to Smarties as `--nTrainUpdates`, not
`--nTrainSteps`. It therefore means an exact number of additional native
optimizer updates in the current invocation, including after restart.
`--nTrainSteps` retains its original environment-transition meaning for legacy
Smarties applications. Evaluation similarly counts only episodes completed in
the current restarted invocation; checkpoint history does not consume the
`--nEvalEpisodes` budget, and evaluation transitions remain outside replay.

Run one admitted target at a time from an immutable source/build pair:

```bash
./couplings/ibamr/scripts/run_cpu_learner_validation_node3.sh \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot> \
  --run-root /data2/mjwu/local/coupling-runs/cpu-learner-seed11-t1 \
  --threads 1 --seed 11 --updates 1024 \
  --training couplings/ibamr/configs/training/cpu_learner_convergence.json

./couplings/ibamr/scripts/run_cpu_learner_validation_node3.sh \
  --source /data2/mjwu/local/coupling-src/<snapshot> \
  --build /data2/mjwu/local/coupling-build/<snapshot> \
  --run-root /data2/mjwu/local/coupling-runs/cpu-learner-seed11-t4 \
  --threads 4 --seed 11 --updates 1024 \
  --training couplings/ibamr/configs/training/cpu_learner_convergence.json
```

Both commands use five MPI ranks with `--bind-to core --map-by slot:PE=4`:
one learner plus four environments, reserving 20 logical CPUs. The four-thread
configuration changes only native Smarties/OpenMP learner computation; it does
not enable a Python, PyTorch, CUDA, or pybind11 backend. The full node3 target
matrix repeats both thread counts for seeds 11, 29, and 47, then compares each
four-thread result with its one-thread counterpart. It is an explicit
`node3;learner;convergence` gate and is intentionally not part of ordinary
CTest. Ordinary CTest runs only the fast fake-executable classification test
`cpu_learner_validation_scripts`.

This gate establishes native Smarties CPU update, checkpoint-restart, and
analytic-task convergence behavior. It does not establish eel policy quality,
eel convergence, swimming efficiency, or long-horizon IBAMR stability.

### Medium-eel native learner activity gate

After the synthetic matrix passes, the dedicated medium-eel gate checks that
the coupled production path performs one finite native learner update:

```bash
./couplings/ibamr/scripts/run_node3.sh train \
  --envs 1 --ranks-per-env 2 --learner-ranks 1 --learner-threads 4 \
  --fidelity medium \
  --training couplings/ibamr/configs/training/cpu_learner_eel_activity.json \
  --task couplings/ibamr/tests/fixtures/speed_tracking_learner_activity.conf \
  --train-steps 1
```

The target uses one learner rank and one two-rank IBAMR environment. Core
binding reserves four processing elements for each of the three MPI ranks, or
12 logical CPUs total. The manifest records learner threads, OpenMP binding,
batch size, network scalar width, and the absolute learner-audit directory.
Every canonical `EEL_CONTROL` transition also records the observed Lagrangian
point count; the gate requires the official-medium count of 2932.

Once the eel MPI job has returned and its run-scoped process snapshot is
empty, the launcher starts a separate synthetic MPI job that reloads the eel
final checkpoint. This second job does not initialize PETSc or IBAMR, does not
add evaluation transitions to replay memory, and must reproduce the final
parameter digest while emitting finite actions. The two MPI jobs never
overlap; `CouplingDriver` owns initialization/finalization in each job.

This proves one native CPU update, the eel protocol record, clean process
return, and checkpoint reload. The target speed and reward weights are
diagnostic only: the result does not prove eel convergence or policy quality.
It does not enable PyTorch, CUDA, pybind11, or Python bindings. Registration is
opt-in through `IBAMR_SMARTIES_ENABLE_NODE3_EEL_LEARNER_ACTIVITY=ON`; the test
is labelled `physical;node3;learner` and is absent from ordinary CTest.

### One-rank/two-rank physical consistency gate

On the configured node3 build, select the focused gate with:

```bash
ctest --test-dir /data2/mjwu/local/coupling-build/<snapshot> \
  -R '^eel_mpi_consistency$' --output-on-failure
```

The gate runs the official-medium case sequentially with one and then two
environment ranks in isolated directories. It compares the physical stream and
derived reward, not wall-clock speed. Each child has a 900-second operational
timeout; the 1860-second outer timeout is strictly larger than both sequential
child limits plus teardown/reporting overhead and remains a safety ceiling.
Either timeout is an inconclusive operational boundary, not a physical
mismatch. A pass does not
prove scaling, long-horizon stability, reset behavior, training convergence, or
policy quality.

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
