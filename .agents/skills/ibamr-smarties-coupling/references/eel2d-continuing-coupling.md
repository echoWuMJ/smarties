# Verified eel2d continuing-coupling guidance

Use this reference only for the official IBAMR eel2d speed-tracking case when
training is intentionally continued across logical Smarties segments. It
records bounded implementation and node3 validation facts, not policy-quality
or convergence claims.

## Fixed case architecture

- `CouplingDriver` owns MPI initialization and finalization. Smarties borrows
  the driver communicator; learner ranks do not initialize CFD libraries.
- One `EelEnvironment` is initialized once per worker callback. Its IBAMR
  hierarchy, flow, eel geometry, physical time, tail phase, and control task
  survive every logical segment boundary.
- `EelLogicalSegments` owns only the training-segment counters. At a segment
  start, publish `sendInitState()`. At a continuing decision publish
  `sendState()`. At a logical horizon publish `sendLastState()` and start the
  next segment from the same physical state.
- Check Smarties termination immediately after every init/state/last-state
  exchange and before another action application or CFD advance. Do not use
  speed-tracking `sendTermState()` or wait for a separate terminal handshake.
- If IBAMR reaches its physical end time before Smarties termination, publish
  the final truncated state, then take the coordinated fatal path. Returning
  normally would permit a second callback and is forbidden.

## Launch controls

`couplings/ibamr/scripts/run_node3.sh train` supports two mutually exclusive
training budgets:

- `--train-steps N` means Smarties receives `--nTrainSteps N --nTrainUpdates 0`.
- `--train-updates N` means Smarties receives `--nTrainSteps 0 --nTrainUpdates N`.

The default remains `--train-steps 1`. `--end-time T` is a positive finite
value, defaults to `10.0`, is rendered into the single top-level `END_TIME`
assignment, and is written to the run manifest. The checkpoint-reload command
must explicitly pass both unused counters as zero.

For cleanup evidence, run-scoped process snapshots must include Open MPI
launchers and daemons, including `orted`; a nonempty scoped snapshot must block
the learner-activity success verdict.

## Bounded node3 validation

The continuing implementation and launcher controls were validated on node3
for source revision `f4bc6d8835634302b93ec5341a504d96e6f2f874`, using GCC 8.5,
Open MPI 5.0.9, IBAMR 0.18, CPU Smarties, one learner rank, a two-rank IBAMR
environment, and two learner threads. The later revision `b376ee7` adds only
the scoped-`orted` cleanup detection and its pure launcher fixture.

- Focused `eel_logical_segments`, `eel_control_protocol`,
  `eel_continuing_protocol`, and `node3_scripts` CTests passed.
- A medium eel run with `--train-updates 2 --end-time 10.0` completed two
  logical segments and four decisions without physical reset, retained 2932
  global Lagrangian points, made exactly two finite native CPU updates, and
  reloaded a checkpoint with the same final network digest.
- An isolated `--end-time 0.13` run published an `ibamr_end_time` truncated
  state and exited through the coordinated MPI fatal path, with one observed
  initialization marker and no observed callback reentry.

Raw evidence and the exact claim boundary are in the ignored OPEN
investigation at
`.artifacts/ibamr-smarties-investigations/eel-continuing-f4bc6d883563/`.

## Boundaries

This validates that the two software systems can run the continuing eel2d
training computation together. It does not establish policy quality,
task-specific reward calibration, convergence, independent physical resets,
repeatability over many long runs, PyTorch/CUDA support, or a basis to promote
the investigation into `experience/verified/`.
