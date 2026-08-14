# Smarties CPU Learner Consistency and Convergence Design

## Purpose

This stage verifies the existing Smarties CPU neural-network path before any
PyTorch or CUDA work. It separates three questions that must not be conflated:

1. Does the native network and Adam optimizer perform reproducible, finite
   updates on frozen data?
2. Does the production VRACER learner improve on a deterministic synthetic
   reinforcement-learning problem?
3. Does the real medium-fidelity eel2d coupling deliver transitions to the
   learner and cause at least one valid network update?

The stage does not claim that the eel swimming policy converges. Long-horizon
eel training requires a separately designed and verified IBAMR reset or
continuing-task model, a calibrated target speed, and repeated multi-seed
physical training.

## Fixed coupling architecture

The existing IBAMR-Smarties architecture contract remains binding.

- `CouplingDriver` is the sole owner of `MPI_Init_thread()` and
  `MPI_Finalize()`.
- Smarties borrows the driver communicator, duplicates only what it needs,
  frees only owned communicators, and never finalizes borrowed MPI.
- Learner ranks and environment ranks remain separate. Runs keep
  `--learnersOnWorkers 0`.
- No process forks after MPI initialization.
- Synthetic environment ranks do not initialize PETSc, SAMRAI, IBTK, or
  IBAMR.
- Only eel2d environment ranks set `PETSC_COMM_WORLD` to their environment
  communicator and initialize the CFD stack.
- IBAMR owns the CFD time-stepping loop. The adapter exchanges state, action,
  reward, and terminal status only at established control boundaries.
- Normal shutdown destroys environment and CFD objects first, then returns
  through Smarties, and lets the driver finalize MPI last. An unrecoverable
  distributed error uses coordinated `MPI_Abort`, never private finalization.

PyTorch, CUDA, pybind11, Python bindings, and neural-network algorithm changes
are outside this stage.

## Why the verification is layered

Running convergence experiments directly on eel2d would mix neural-network
behavior with CFD discretization, target calibration, physical reset, MPI
decomposition, and long wall-clock time. A failure would not identify the
responsible layer. The tests therefore progress from a deterministic network
fixture, through the real VRACER learner on a cheap synthetic environment, to
one short real-IBAMR update.

The preferred design is:

1. a direct native-network update and checkpoint probe;
2. a full Smarties/VRACER synthetic-learning probe;
3. a short medium eel2d learner-activity probe.

Each layer must pass its own gate before the next, more expensive layer starts.

## CPU threading model

Smarties uses OpenMP for gradient computation and parameter updates. The
current eel training settings use `batchSize=1`, which cannot be reused with
four learner threads because the training code partitions work using
`batchSize / nThreads`.

This stage adds dedicated validation settings whose batch size is a positive
multiple of the learner thread count. The frozen matrix uses:

- serial baseline: `nThreads=1`;
- threaded baseline: `nThreads=4`;
- deterministic network-probe batch size: 64;
- synthetic VRACER batch size: `batchSize=8`;
- eel learner-activity batch size: `batchSize=4`;
- explicit `OMP_NUM_THREADS=4`, `OMP_PROC_BIND=close`, and
  `OMP_PLACES=cores` for threaded target runs;
- no dynamic OpenMP thread adjustment during a run.

MPI and OpenMP parallelism remain distinct. The synthetic test uses one
learner rank and four cheap single-rank environments. The eel test uses one
learner rank and one two-rank IBAMR environment. Target runs use Open MPI core
binding with four processing elements reserved per MPI rank. The synthetic
matrix therefore reserves 20 logical CPUs and the eel probe reserves 12. The
launcher records the actual rank/thread placement and rejects oversubscription
instead of silently changing it.

## Layer 1: deterministic native-network probe

### Fixture

The probe builds the same small topology used by the eel policy dimensions:

- five inputs;
- two hidden layers of 16 units;
- one continuous output;
- Smarties' existing native CPU network and Adam optimizer;
- the repository's default float32 neural-network precision.

The fixture supplies fixed initial parameters, a fixed batch, a fixed target
function, and a fixed update count. It must not use `std::random_device`.

### Required observations

The probe emits a machine-readable audit record at initialization and after
each selected update. Each record contains:

- random seed;
- OpenMP thread count;
- optimizer update count;
- number of network parameters;
- byte-level parameter digest;
- stable numeric parameter summaries;
- loss and fixed-evaluation-set prediction summaries;
- finite/non-finite status.

The instrumentation is diagnostic only. It must not change the optimizer,
gradient order, replay sampling, or policy behavior when disabled.

### Tests

1. Two runs with the same seed and the same thread count must reproduce the
   same initialization and update audit records.
2. One-thread and four-thread runs start from identical parameters and consume
   identical samples. After one Adam update, parameter and prediction
   differences must satisfy `atol=1e-6` and `rtol=1e-5`.
3. Every parameter, gradient, optimizer statistic, loss, and prediction must be
   finite.
4. The reported optimizer step count must equal the requested count.
5. Over 200 fixed-data updates, the mean loss of the last 20 updates must be no
   more than 25 percent of the mean loss of the first 20 updates. The fixed
   evaluation error must also decrease.
6. Saving and immediately reloading a checkpoint must reproduce the saved
   parameter digest, optimizer update count, and fixed-set predictions.

The test does not require a monotonically decreasing loss at every update.

## Layer 2: production VRACER synthetic convergence probe

### Environment

The synthetic environment exercises the normal Smarties communicator,
experience collection, replay memory, VRACER learner, action sampling,
optimizer, checkpoint, and termination paths without linking IBAMR.

It exposes the eel-compatible interface:

- five state components;
- one bounded continuous action;
- deterministic seeded state sequences with each state component in `[-1,1]`;
- analytic target action
  `clip(0.60*s0 - 0.25*s1 + 0.15*s2, -0.80, 0.80)`;
- reward based on negative squared action error;
- fixed episode length and a controlled reset with no external state.

The last two state components are deterministic distractors. The target action
depends on the first three components, so a constant action cannot pass the
convergence gate. Each episode contains 32 decisions. Training and evaluation
sequences are distinct but are generated from frozen seeds. Evaluation uses a
fixed set of 256 states and never adds those transitions to replay memory.

### Run matrix

The convergence matrix uses seeds 11, 29, and 47 for both the one-thread and
four-thread learner configurations. Each run performs exactly 1024 optimizer
updates. The episode count is derived from the frozen update budget and replay
threshold, and the runner records both the expected and actual count. No seed
may be replaced after observing a result.

### Acceptance criteria

For every run:

- learner initialization and all updates complete without NaN or Inf;
- the observed optimizer update count equals the configured budget;
- parameters change from initialization;
- checkpoint save and immediate reload preserve policy output on the frozen
  evaluation set;
- normal termination leaves no learner or environment process behind.

For each thread configuration across the three frozen seeds:

- all runs must complete the protocol;
- each run's final 256-state action mean-squared error must be no more than 50
  percent of its initial action mean-squared error;
- because evaluation reward is negative squared action error, each run's final
  average return must cover at least half of the gap from its initial return to
  the analytic optimum of zero;
- the median final action error and median final return must show the same
  improvement direction.

One-thread and four-thread long runs are not required to finish with identical
weights. For each seed they must have the same update budget, both must satisfy
the 50-percent improvement gate, and the four-thread final action mean-squared
error must not exceed the corresponding one-thread result by more than 0.02.
The same 0.02 absolute bound applies to their final average-return difference.

RL training loss is recorded for diagnosis but is not required to decrease
monotonically. Policy error and return are the convergence criteria.

## Layer 3: medium eel2d learner-activity probe

The final test uses the official medium grid and the existing eel speed-control
adapter. It proves only that the physical path can generate enough transitions
to execute one real Smarties network update.

The run uses:

- one dedicated Smarties learner rank;
- four learner threads;
- one IBAMR environment with two MPI ranks;
- medium fidelity and the previously guarded 2932-point eel layout;
- a dedicated validation training file with `batchSize=4`;
- a training budget of exactly one completed optimizer update;
- a task horizon long enough to satisfy the frozen replay threshold and that
  one update, but no unverified episode reconstruction or reset.

The run passes only if:

- the initialization audit is present;
- exactly one optimizer update is reported;
- the final parameter digest differs from the initialization digest;
- all network, state, action, reward, and optimizer audit values are finite;
- every recorded physical transition reports 2932 Lagrangian points;
- a valid terminal transition is published;
- the checkpoint reloads and reproduces the saved policy output;
- all environment objects are destroyed before return to Smarties;
- the driver alone finalizes MPI;
- immediate exact-name process checks show no residual coupling, learner,
  `mpiexec`, or `prterun` process.

This test does not compare eel reward improvement and does not claim learned
swimming control.

## Tolerances and reproducibility

The repository default neural-network precision is float32. Double-precision
PETSc does not make the neural-network update double precision. Therefore:

- same-seed, same-thread deterministic micro-runs use exact audit digest
  equality as the primary reproducibility gate;
- the one-update one-thread/four-thread comparison uses the frozen
  `atol=1e-6`, `rtol=1e-5` numeric gate;
- long stochastic RL runs compare frozen evaluation behavior and update
  counts, not byte-identical final weights;
- physical eel values are not reused as neural-network tolerance scales.

If a frozen tolerance proves inappropriate, the current evidence remains a
failure or open investigation. A new tolerance requires a new design revision
and new immutable runs; it is never retroactively applied to old evidence.

## Failure classification

- `NONFINITE_UPDATE`: any parameter, gradient, loss, action, reward, or
  optimizer statistic is NaN or Inf.
- `DETERMINISM_MISMATCH`: same-seed, same-thread micro-runs disagree.
- `THREADED_UPDATE_MISMATCH`: the frozen one-update one-thread/four-thread
  tolerance is exceeded.
- `UPDATE_NOT_OBSERVED`: the requested optimizer update count is not reached or
  parameters do not change.
- `CHECKPOINT_MISMATCH`: reload does not reproduce the saved audit state and
  policy output.
- `NO_SYNTHETIC_CONVERGENCE`: the frozen synthetic policy error/return criteria
  are not met.
- `COUPLING_PROTOCOL_FAILURE`: the eel transition, layout, lifecycle, or MPI
  shutdown contract fails.
- `OPERATIONAL_INCOMPLETE`: an external timeout, scheduler interruption, or
  unrelated node failure prevents a result. Slow but demonstrably advancing
  computation is not an algorithm failure.

No failed or incomplete layer may be hidden by running a later layer.

## Evidence and execution order

Verification proceeds in this order:

1. compile and link the new probes against the exact Smarties runtime library;
2. run focused deterministic network tests;
3. run the three-seed synthetic matrix first with one thread, then four;
4. independently compare archived audit and evaluation records;
5. only after layers 1 and 2 pass, freeze the medium eel input, task, and
   training files;
6. run the single admitted eel learner-activity probe;
7. verify checkpoint identity, process cleanup, source/build/runtime hashes,
   and MPI ownership evidence;
8. perform an independent evidence review.

Every target run records the full Git revision, clean/dirty status, package and
source-manifest hashes, compiler and library identities, random seeds,
configuration hashes, exact command, rank topology, OpenMP placement, start and
end times, exit status, and evidence paths.

Hypotheses, failed attempts, and incomplete evidence remain under
`.artifacts/ibamr-smarties-investigations/`. Nothing enters
`experience/verified/` until the coupling skill's closure and independent
admission requirements are fully satisfied.

## Deliverables

- a deterministic native-network update/checkpoint probe;
- a full VRACER synthetic convergence environment and frozen settings;
- opt-in machine-readable learner audit output;
- script and CTest coverage for the one-thread/four-thread matrix;
- a dedicated medium eel learner-activity configuration and gate;
- node3 evidence and an independent review report;
- documentation that states the precise boundary between verified network
  behavior and unverified long-horizon eel learning.

## Explicit non-goals

- enabling or repairing PyTorch;
- CUDA or GPU execution;
- Python bindings or pybind11;
- changing VRACER mathematics to make a test pass;
- calibrating the eel target speed;
- implementing or validating IBAMR episode reset;
- demonstrating long-horizon eel reward convergence or policy quality;
- proving bitwise equality between one-thread and four-thread stochastic
  training.
