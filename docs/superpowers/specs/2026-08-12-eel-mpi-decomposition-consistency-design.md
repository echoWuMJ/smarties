# Eel MPI-decomposition physical consistency gate

## Goal

Add a deterministic admission test that runs the official-medium eel2d case
with one and two IBAMR environment ranks and decides whether MPI domain
decomposition preserves the controlled physical trajectory. The comparison
uses the same input, task configuration, fixed action sequence, and decision
horizon. Physical quantities are authoritative; the task reward is checked as
a derived end-to-end result.

This gate answers whether the current coupled environment can advance the same
short controlled case consistently across the two supported environment-rank
counts. It does not measure scalability, impose a wall-clock performance
requirement, prove grid convergence, validate a learned policy, or add episode
reset support.

## Selected approach

Extend the existing standalone `frequency_response_probe` instead of creating
a second solver entry point or routing deterministic actions through a
Smarties learner. The probe already owns one MPI job, constructs
`EelEnvironment`, applies eel frequency control, advances IBAMR, and reports
center-of-mass and phase measurements. Reusing it keeps the comparison on the
same environment implementation while excluding learner randomness and message
scheduling from this physics-specific gate.

The existing direct-ratio mode remains supported for its current response
test. A new task-driven mode accepts an eel task file and one fixed normalized
action. A host-side CMake comparator launches the task-driven probe once with
one rank and once with two ranks and compares their canonical result streams.

Rejected alternatives:

- A separate consistency executable would duplicate environment-driving and
  reporting logic without increasing coverage.
- Injecting actions through Smarties would test a wider protocol but would mix
  learner scheduling with the MPI-decomposition question. The existing
  topology matrix covers the coupling protocol separately.

## Fixed architecture and ownership

The standalone probe's `MpiSession` initializes MPI once and finalizes it once.
`MPI_COMM_WORLD` is the environment communicator for that invocation. All its
ranks initialize PETSc, SAMRAI, IBTK, and IBAMR, participate in every CFD step,
and destroy the environment before `MpiSession` finalizes MPI. No learner ranks
or Smarties communicator exist in this diagnostic executable, and no process
forks after MPI initialization.

Only environment rank zero emits canonical comparison records. Other ranks
participate in collective computation and shutdown but do not duplicate the
records. The current probe's per-rank catch-and-return path is insufficient
after distributed environment initialization: one rank could return while a
peer remains in an IBAMR collective. This stage therefore adds a small probe
fatal boundary that reports once and calls `MPI_Abort(MPI_COMM_WORLD, 64)` for
an unrecoverable post-initialization exception; no rank privately finalizes
MPI. Before environment initialization, ordinary argument or file validation
errors return normally and identically on every rank.

This diagnostic ownership is compatible with, but does not replace, the
production coupling contract: in the production executable the coupling
driver remains the sole MPI owner, Smarties borrows its communicator, and only
environment subcommunicators initialize the CFD stack.

## Task-driven probe interface

The probe retains the required `--input-file` and `--decisions` options and its
existing direct mode:

```text
--ratio R --direction-x X --direction-y Y
```

Task-driven mode instead requires:

```text
--task-file PATH --action A
```

The modes are mutually exclusive. `A` must be finite. The task mode loads the
configuration with `loadEelTaskConfig`, constructs `EelControlTask`, and, for
each decision, calls the same production methods in the same order:

1. `applyAction(A)`;
2. apply `decision.applied_ratio` to `EelEnvironment`;
3. advance by `task.controlInterval()`;
4. compute interval forward velocity using the task's configured unit
   direction and the interval center-of-mass displacement;
5. call `task.reward(forward_velocity, decision.previous_ratio)`.

No warmup is performed by this gate. The task fixture used for admission must
therefore have `warmup_cycles=0`; a nonzero value is rejected rather than
silently changing the compared initial condition. The requested decision count
must not exceed the task episode horizon. Repeating one action intentionally
still exercises the production slew-rate limit because every decision passes
through `applyAction`.

The first admitted comparison uses the existing deterministic
`speed_tracking_protocol.conf` fixture, action `1.0`, and two decisions. That
action advances the applied ratio from 1.0 to 1.1 and then 1.2 through the
configured slew limit, so both the frequency and smoothness reward paths are
exercised. The fixture's target speed is synthetic: its reward is meaningful
for implementation consistency only and is not a calibrated physical training
objective.

## Canonical result contract

Rank zero prints one `EEL_FIXED_ACTION_STEP` line after every completed control
interval. Each line contains, at minimum:

- one-based decision index and environment communicator size;
- requested action, target ratio, previous ratio, and applied ratio;
- interval start and end physical time and IBAMR step count;
- start and end center-of-mass coordinates;
- x/y displacement, configured forward displacement, and interval forward
  velocity;
- tail-beat phase at the end of the interval and the global Lagrangian point
  count;
- tracking, frequency, smoothness, and total reward.

After the last step, rank zero prints one `EEL_FIXED_ACTION_SUMMARY` containing
the environment size, completed decisions, total IBAMR steps, total elapsed
physical time, total center-of-mass displacement, final phase, and cumulative
reward components. All numeric values use `%.17g`. Every emitted quantity must
be finite, elapsed intervals must be positive, and both rank counts must emit
exactly the requested number of step records and one summary.

Expose the already-established global Lagrangian count from the initialized eel
kinematics/environment as a read-only diagnostic. It is the global structure
count derived from `getLagIdxRange()`, not a per-rank PETSc ownership size and
not a recount of the vertex text file. The production `EelLayoutInvariant`
continues to reject any mismatch before shape or velocity updates. The probe
reports this count without changing the layout or the body, so the comparator
can require exactly 2932 and equality across decompositions. Silo inspection
is not duplicated in this gate.

## Comparison and admission rules

The comparator executes the one-rank and two-rank invocations sequentially in
separate fresh working directories so their IBAMR, restart, and visualization
files cannot collide. It captures stdout, stderr, exit status, exact command,
and result records independently. The action, task, input, decision count, and
working-directory seed files are byte-identical between invocations.

For corresponding step records and summaries:

- decision indices, completed-decision counts, IBAMR step counts, global
  Lagrangian counts, and the declared environment sizes are exact integer
  checks; both global Lagrangian counts must be 2932;
- requested action, target/previous/applied ratios, start/end times, elapsed
  time, and phase use absolute tolerance `1e-12` plus relative tolerance
  `1e-12`;
- center-of-mass coordinates, displacements, forward velocity, and each reward
  component use absolute tolerance `1e-10` plus relative tolerance `1e-8`;
- a floating comparison passes when
  `abs(a-b) <= absolute_tolerance + relative_tolerance * max(abs(a),abs(b))`;
- reward disagreement is reported separately, but admission cannot pass if
  either an authoritative physical comparison or the derived reward comparison
  fails.

The tolerances are fixed before the target run and may not be widened in
response to its output. If this first evidence shows a reproducible difference
outside the limits, the result remains an investigation failure until the
numerical source and an independently justified tolerance policy are reviewed.

Wall time and CPU utilization are recorded only as operational context. They
are never compared and never form a physics verdict. A generous process timeout
may exist solely to terminate a lost or permanently stalled job; reaching it
produces `inconclusive: operational timeout`, not `physical mismatch`. That job
must not be silently rerun or relabelled as a numerical failure.

## Error and shutdown handling

The comparator fails closed for missing or duplicate result lines, malformed or
non-finite fields, nonzero child exit, unmatched decision indices, premature
IBAMR end time, or any numerical mismatch. It prints the exact field, decision,
one-rank value, two-rank value, absolute difference, and permitted tolerance.

A normal invocation shuts down `EelEnvironment` on all ranks, then returns to
the probe's MPI owner. Target evidence must include an immediate exact-name
process snapshot after each invocation. A remaining probe or MPI launcher is a
shutdown failure. Distributed failure injection is not added to this task;
that lifecycle is already covered by the existing coupled fatal-path test, and
this gate must not duplicate it.

## Test-driven implementation

1. Add pure parser/comparator fixtures with identical streams, a physical
   mismatch, a reward-only mismatch, a wrong global Lagrangian count,
   missing/duplicate steps, non-finite data, and an operational-timeout
   classification. Run them RED before implementing the comparator.
2. Add probe option and canonical-output tests that initially fail because
   task-driven mode and root-only records do not exist.
3. Implement the smallest task-driven extension, reusing `EelControlTask` and
   a shared forward-velocity helper rather than duplicating the adapter formula.
   Add only a read-only global Lagrangian-count accessor and the probe-specific
   distributed fatal boundary needed by the result contract.
4. Implement the sequential one-rank/two-rank comparator and rerun the pure and
   focused tests GREEN.
5. Build the clean revision locally, package it with source and runtime artifact
   identities, then build or reuse only a manifest-current node3 executable.
6. On node3, run exactly one admitted one-rank probe and one admitted two-rank
   probe using the official-medium case. Do not run the full 19-test suite or a
   frequency sweep as part of this gate.
7. Preserve commands, hashes, outputs, comparison report, exit codes, and
   immediate process snapshots under
   `.artifacts/ibamr-smarties-investigations/<issue-id>/`.

## Completion boundary

Passing establishes that this deterministic short official-medium trajectory,
under the recorded revision and MPI stack, is consistent between one and two
IBAMR environment ranks within the frozen tolerances; the formally configured
reward is correspondingly consistent; and both invocations shut down cleanly.

It does not establish bitwise reproducibility, arbitrary-rank equivalence,
parallel speedup, long-horizon stability, reset correctness, multi-environment
physical equivalence, training convergence, or policy quality. The result stays
under `.artifacts` until the coupling skill's full closure gate, including
repetition and all relevant lifecycle evidence, is satisfied. Only then may an
atomic, claim-bounded record be admitted to `experience/verified/`.
