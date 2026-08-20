# Smarties Exact Update and Evaluation Termination Design

## Purpose

This change removes two blockers discovered while executing the native CPU
learner validation matrix:

1. `--nTrainSteps` counts collected environment transitions, so it cannot
   promise an exact number of optimizer updates.
2. Evaluation disables replay tracking, and the same early return also skips
   the episode counter used by `--nEvalEpisodes`; evaluation therefore never
   reaches its normal stop condition.

The change adds an explicit optimizer-update budget and restores bounded
evaluation without changing the existing meaning of `--nTrainSteps`.

## Classification and boundaries

This is an architectural Smarties runtime change because it adds a termination
interface used by the learner loop. It does not change the coupled topology.

- `CouplingDriver` remains the sole owner of MPI initialization and
  finalization.
- Learner ranks remain separate from environment ranks and
  `--learnersOnWorkers 0` remains mandatory for the coupling.
- Only environment ranks may initialize PETSc, SAMRAI, IBTK, and IBAMR.
- No process is forked after MPI initialization.
- Normal shutdown remains environment/CFD teardown, return through Smarties,
  and driver-owned MPI finalization.
- PyTorch, CUDA, pybind11, Python bindings, and GPU execution are out of scope.

## Selected interface

Add `--nTrainUpdates N`, with default `0`.

- `N == 0`: preserve the legacy `--nTrainSteps` termination behavior.
- `N > 0`: training ends after every learner has completed exactly `N` new
  gradient updates in this invocation.
- The starting gradient-step value is captured after learner restart state has
  been loaded, so a restarted run performs `N` additional updates rather than
  treating historical checkpoint steps as work done in the new invocation.
- `--nTrainUpdates` controls only termination. Replay startup thresholds,
  `obsPerStep`, minibatch sampling, optimizer selection, and network topology
  remain unchanged.
- When `N > 0`, `--nTrainSteps` is not used as a competing stop condition.
  This prevents the transition counter from stopping an exact-update run
  early. The selected mode and target are printed once for auditability.

The C++ `Engine` receives a matching
`setNumTrainingGradientSteps(Uint numUpdates)` method. Python exposure is not
added in this stage because Python bindings are intentionally disabled for the
coupling build.

## Exactness argument

`Worker::runTraining()` invokes `algoTasks.run()` and then checks termination.
`TaskQueue::run()` visits all registered tasks once. Each learner's task state
machine can complete at most one `globalGradCounterUpdate()` during that pass.
The worker records a per-learner baseline before the first update and compares
`nGradSteps() - baseline` with `nTrainUpdates` after every pass. Therefore a
fresh or restarted one-learner run stops on the requested update count without
the transition-count off-by-one observed in the validation matrix.

Multiple learners use independent baselines and the worker stops only when all
learners reach the same additional-update budget. A zero budget never enters
this path and remains backward compatible.

## Evaluation episode accounting

Replay insertion and evaluation completion are distinct responsibilities.
When `Agent::trackEpisodes` is false:

- states, actions, rewards, and policies continue to be excluded from replay;
- a non-empty terminated episode increments the existing local seen-episode
  counter exactly once;
- no episode is finalized, shared, or inserted into a training set;
- the counter remains the source consumed by `Learner::nSeqsEval()` and
  `Worker::isOverTesting()`.

This preserves frozen-policy evaluation while allowing `--nEvalEpisodes` to
terminate normally. Empty sequences remain uncounted.

## Error handling

- A malformed `--nTrainUpdates` value is rejected by the existing argument
  parser before the coupled application starts.
- Evaluation child timeout is classified as an operational test failure, not
  as successful termination.
- No new private MPI finalization or exception-to-finalize path is introduced.
- Existing fatal distributed errors continue to use the established abort
  path.

## Verification

Tests are added before production changes.

1. A synthetic training protocol requests two exact additional updates and
   requires exactly two update audit records ending at gradient step 2.
2. A restart protocol loads a checkpoint and requires exactly two additional
   update records beyond the checkpoint baseline.
3. A frozen-policy evaluation requests two episodes and must exit zero with
   exactly 64 synthetic decisions, two completed episodes, one summary, and no
   optimizer-update audit records.
4. A negative control proves the old implementation times out rather than
   falsely passing the evaluation test.
5. Runner script fixtures require `--nTrainUpdates`, retain the existing
   process-residual gates, and reject malformed evidence.
6. After focused tests pass, the frozen node3 CPU matrix runs seeds 11 and 29
   with one and two learner threads, exactly 1024 updates per training run,
   finite audit records, parameter movement, checkpoint reload, and bounded
   initial/final evaluation.

No result is promoted to `experience/verified/` until the full matrix and its
independent evidence review pass.
