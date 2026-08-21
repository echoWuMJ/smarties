# Eel2d Continuing Training Design

## Goal

Allow the Smarties-controlled IBAMR eel2d environment to collect more than one
logical training segment in a single long-lived simulation. The CFD process,
Eulerian hierarchy, Lagrangian structure, fluid state, tail phase, controller
state, MPI ranks, and Smarties learner remain alive across every action and
logical segment boundary.

This phase proves continuation and clean termination. It does not claim that
the current target speed is calibrated or that a useful swimming policy has
converged.

## Chosen semantics

The eel is a continuing physical task divided into finite replay segments.
`episode_decisions` becomes the number of decisions in one logical segment,
not a request to reconstruct the IBAMR environment.

At startup, the adapter initializes IBAMR once, completes the configured
warmup once, computes the first state, and calls `sendInitState()`. Within a
segment it follows the existing synchronous control loop:

1. `recvAction()` waits for Smarties at a control-safe point.
2. The adapter bounds and applies the frequency command.
3. IBAMR advances for one control interval.
4. The adapter computes the next state and reward from the completed interval.
5. The transition is sent to Smarties.

At a normal logical horizon the adapter sends `sendLastState()`. This marks a
time-limit truncation, so Smarties may bootstrap from the final value. If
training should continue, the adapter immediately opens the next logical
segment with `sendInitState()` using the same current physical state. It does
not call `EelEnvironment::shutdown()`, reconstruct IBAMR, reset the flow,
reset the tail phase, or reset `EelControlTask`.

The duplicate state at the boundary is intentional: it is the final state of
the truncated segment and the initial state of the next replay segment. No CFD
time advances between those two messages.

## Alternatives rejected

### One unbounded Smarties episode

Sending only `sendState()` until the whole job ends avoids segment boundaries,
but Smarties cannot finalize ordinary replay episodes at a bounded cadence.
It also makes checkpoint and diagnostic episode summaries unnecessarily
coarse.

### Reconstruct IBAMR at every episode

Destroying and rebuilding PETSc, SAMRAI, IBTK, IBAMR, the hierarchy, and the
eel would create independent physical episodes, but it adds a much larger
distributed reset surface. It is not required for the current continuing-task
goal and is deferred until independent initial conditions become a scientific
requirement.

### Restart the MPI application at every action or segment

This violates the fixed coupling architecture, discards physical history, and
turns ordinary control exchange into repeated distributed startup and
shutdown. It is not permitted.

## Process and communicator ownership

`CouplingDriver` remains the sole owner of `MPI_Init_thread()` and
`MPI_Finalize()`. Smarties borrows the driver communicator. Learner ranks do
not initialize the CFD stack. Only ranks in one environment communicator
initialize PETSc, SAMRAI, IBTK, and IBAMR, with `PETSC_COMM_WORLD` bound to
that environment communicator before initialization.

The environment callback owns the single long-lived `EelEnvironment`. Normal
destruction remains inside-out: stop the control loop at a safe boundary,
destroy the environment and CFD objects, return from the callback, allow
Smarties to drain and free its own communicators, and let `CouplingDriver`
finalize MPI last.

## Termination classification

- A configured logical horizon is a truncation and uses `sendLastState()`.
- Reaching the IBAMR input end time is also a time-limit truncation and uses
  `sendLastState()`. If Smarties has not already ended training, the adapter
  then reports a configuration failure through the coordinated environment
  failure path. It must not return normally and let Smarties invoke the
  callback again, because that would silently construct a second IBAMR
  simulation.
- A future explicitly defined absorbing physical success or failure may use
  `sendTermState()`. This phase adds no such condition.
- A non-finite state/reward or an unusable distributed solver remains an
  unrecoverable environment error and follows the existing coordinated
  `MPI_Abort` path. This phase does not pretend that such a failure is
  recoverable.
- When Smarties returns its training-termination signal, the adapter performs
  no further CFD advance. It exits at that communication-safe point and shuts
  down normally.

Waiting for an action is not process destruction or an operating-system
suspend. The environment rank remains alive inside Smarties/MPI communication,
and simulated physical time remains unchanged until an action arrives.

## Configuration and launcher behavior

The existing task field `episode_decisions` controls logical segment length.
No reset flag or second episode mode is added.

The node3 launcher accepts an explicit positive finite simulation end time,
defaults it to the existing value `10.0`, passes it to the input renderer, and
records it in the run manifest. A continuation run is configured so the
Smarties training budget ends before this physical-time ceiling. The launcher
does not guess an end time from an optimizer-update count because asynchronous
learning provides no exact update-to-CFD-time conversion.

The node3 launcher must stop enforcing the old
`episode_decisions - minTotObsNum` single-episode ceiling. Long learner
validation should use Smarties' existing exact `--nTrainUpdates` budget through
one explicit launcher option, while `--train-steps` remains available for
backward-compatible data-step runs. The two counters must not be silently
reinterpreted.

No PyTorch, CUDA, pybind11, Python binding, remeshing, new geometry generator,
checkpoint format, content hash, frozen contract, baseline, or admission gate
is added by this phase.

## Observability

The adapter reports cumulative decisions and native IBAMR steps for the whole
callback, plus a one-based logical segment index and the decision index within
that segment. Each segment boundary reports `reason=logical_horizon` or
`reason=ibamr_end_time` and `status=truncated`. The final callback summary
reports the number of completed logical segments and whether Smarties or the
IBAMR end time stopped the run.

These records are operational evidence only. They do not by themselves prove
training convergence or policy quality.

## Verification sequence

Implementation follows test-driven development and increasing scope:

1. Add a focused protocol test that initially fails because the current
   adapter emits a terminal state after the first logical segment and never
   continues the physical environment.
2. Verify two logical segments produce one initialization per segment, a
   truncation at each completed horizon, monotonically increasing physical
   time, continuous task state, and no environment reconstruction.
3. Verify a Smarties termination signal stops further CFD advancement and
   returns through `CouplingDriver` with MPI still active until driver
   destruction.
4. Verify both the existing fatal-after-initialize path and the new premature
   IBAMR-end path coordinate through `MPI_Abort`, do not start a second
   callback, and leave no scoped residual process.
5. Package the clean revision and run a focused medium-fidelity node3 case with
   one learner rank and one environment communicator. It must cross at least
   two logical segment boundaries, observe native finite CPU learner updates,
   preserve the global Lagrangian point count, advance simulation time
   monotonically, reload the checkpoint for bounded evaluation, and shut down
   without residual processes.
6. Only after the focused case passes may a longer eel update run be started.
   Its result remains investigation evidence until the project experience
   admission checklist is completely satisfied.

Existing tests unrelated to the changed adapter/launcher are not rerun merely
to increase a test count. Focused tests cover the changed behavior, followed by
the directly related lifecycle, learner-activity, and failure-path tests.

## Claim boundary

Passing this phase would establish that one IBAMR eel2d simulation can remain
alive across multiple Smarties replay segments and native CPU learner updates,
with explicit truncation semantics and orderly shutdown. It would not
establish independent physical resets, policy convergence, hydrodynamic
optimality, calibrated reward weights, long-horizon numerical stability at
arbitrary duration, multi-environment reproducibility, or GPU execution.
