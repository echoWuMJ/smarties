# eel2d Tail-Beat Frequency Control Design

**Status:** Approved for implementation planning on 2026-08-10

**Scope:** Stage-two physical control for the Smarties-IBAMR eel2d coupling

**Baseline:** IBAMR 0.18.0 `examples/ConstraintIB/eel2d`

## 1. Purpose

Stage one proved the MPI, Smarties, PETSc, SAMRAI, IBTK, and IBAMR lifecycle on
node3. The Smarties action is currently checked for shape but is deliberately
not applied to the fish. Stage two will establish the first physical closed
loop:

```text
Smarties action
  -> commanded tail-beat frequency
  -> official eel2d kinematics
  -> IBAMR fluid-structure advance
  -> eel center-of-mass motion
  -> normalized observation and tracking reward
  -> Smarties
```

The initial learning task is forward target-speed tracking. This stage must
demonstrate that a Smarties action changes the real eel kinematics and that the
resulting IBAMR motion changes the state and reward returned to Smarties.

## 2. Scope and non-goals

### In scope

- Preserve the official IBAMR 0.18.0 eel geometry, amplitude envelope,
  ConstraintIB formulation, fluid configuration, and force/COM calculations.
- Replace the fixed temporal phase in the vendored eel kinematics with a
  continuous phase driven by one bounded tail-beat-frequency command.
- Perform eight Smarties decisions per nominal baseline tail-beat period.
- Advance multiple native IBAMR timesteps for each held Smarties action.
- Expose a normalized state and target-speed tracking reward.
- Run one meaningful, multi-decision episode with optional baseline-frequency
  warmup.
- Keep Smarties on its native CPU neural-network implementation.
- Extend reproducible local and node3 verification and evidence capture.

### Out of scope

- Replacing the official eel body model or modifying the shared node3 IBAMR
  installation.
- Steering, amplitude control, multiple simultaneous control variables, or a
  learned body shape.
- PyTorch, CUDA, GPU training, or pybind11.
- Claiming that a frequency regularizer is a physical energy or efficiency
  measurement.
- Robust physical reset of the IBAMR hierarchy for multiple independent
  episodes in one MPI job. Reset is a later stage because PETSc, SAMRAI, IBTK,
  and IBAMR singleton lifecycles require separate design and validation.

## 3. Fixed process architecture

Implementation is constrained by
`.agents/skills/ibamr-smarties-coupling/SKILL.md` and its architecture
contract:

- One long-lived MPI job is used for a run.
- `CouplingDriver` is the sole owner of `MPI_Init_thread` and `MPI_Finalize`.
- Smarties borrows the caller communicator and frees only communicators that it
  creates.
- Smarties never privately finalizes MPI.
- Learner ranks and IBAMR environment ranks remain separate, with
  `--learnersOnWorkers 0`.
- Only environment ranks initialize PETSc, SAMRAI, IBTK, and IBAMR.
- Environment ranks bind `PETSC_COMM_WORLD` and SAMRAI to the environment
  communicator before framework operations.
- No process is forked after MPI initialization.
- IBAMR owns its fluid timestep loop. Smarties exchanges state, action, reward,
  and terminal information only at explicit control-safe points.
- Fatal distributed failures use the existing coordinated fatal path; they do
  not create a second MPI-lifecycle owner.

These constraints are invariants, not implementation suggestions. Any change
that violates them requires a new architecture decision before implementation.

## 4. Official-case provenance and modification boundary

The coupled environment is derived from IBAMR 0.18.0
`examples/ConstraintIB/eel2d/example.cpp`, and the kinematics source is derived
from the corresponding official `IBEELKinematics` implementation. Stage two
will retain an explicit record of:

- IBAMR version and official source path;
- the unmodified baseline equations;
- the exact local frequency-control modifications; and
- numerical tests that recover the official equations at the baseline
  frequency.

The node3 shared IBAMR tree remains read-only. All changes live in this
repository's coupling source and are packaged with a Git revision, manifest,
and hashes.

Subclassing the official kinematics class is rejected because the parsers and
kinematic state needed for control are private. Rewriting inputs or rebuilding
parsers at every action is also rejected because it is expensive and cannot
guarantee phase continuity. A small, auditable change to the vendored official
implementation is the selected approach.

## 5. Frequency-controlled kinematics

The official body-line motion has the form

```text
y(s, t) = A(s) sin(2 pi s - omega_0 t)
```

with a matching normal deformation velocity. Stage two replaces only the
temporal phase:

```text
d phi(t) / dt = omega_0 r_applied(t)
y(s, t)       = A(s) sin(2 pi s - phi(t))
v_n(s, t)     = -A(s) dphi/dt cos(2 pi s - phi(t))
```

Here `omega_0 = 0.785 / 0.125 = 6.28` is retained exactly from the official
input rather than silently replaced by exact `2 pi`, and `r_applied` is the
dimensionless ratio between the applied and official baseline frequencies.
The corresponding baseline cycle frequency is `f0 = omega_0 / (2 pi)`. The
shape and deformation velocity must use the same phase and applied frequency.
With `r_applied = 1`, the new formulation must reproduce the official
expression within a specified floating-point tolerance.

### Piecewise-continuous phase

The kinematics object stores:

- phase at the last command-change time;
- last command-change time;
- current applied frequency; and
- current target frequency.

At a control-safe point, changing frequency first evaluates the phase at the
effective IBAMR time under the old frequency, then installs the new frequency.
Subsequent phase values are evaluated from that anchor. Phase must not be
incremented by callback count because IBAMR may evaluate kinematics more than
once for a timestep.

## 6. Action contract and safety limits

Smarties exposes one continuous action:

```text
a in [-1, 1]
```

It is mapped to a configured target frequency ratio and then to frequency:

```text
r_target = r_min + (a + 1) / 2 * (r_max - r_min)
f_target = r_target f0
```

Conservative initial defaults are:

- `omega_0 = 6.28` and `f0 = omega_0 / (2 pi)` in the official
  nondimensional time units;
- `r_min = 0.5`;
- `r_max = 1.5`; and
- maximum applied ratio change per decision `delta_r_max = 0.1`.

These values are task configuration, not hard-coded adapter constants. A
finite out-of-range action is clipped to `[-1, 1]` and the clipping event is
recorded. NaN or infinite actions are protocol errors and enter the fatal path.
The environment reports the applied frequency after clipping and slew limiting,
not merely the requested target.

## 7. Control cadence

The nominal control interval is one eighth of the official baseline period:

```text
Delta_t_control = 2 pi / (8 omega_0)
```

One Smarties action is held while IBAMR advances as many native timesteps as
needed to reach or cross the next nominal boundary. The adapter does not force
IBAMR to change a stable timestep merely to land exactly on that boundary.
Observation and reward calculations use the actual elapsed physical time, so a
one-timestep overshoot does not bias average velocity.

The environment, rather than the adapter, owns the loop over native IBAMR
timesteps. This preserves the existing ownership boundary and gives the
environment one operation equivalent to "advance one control interval under
the current command."

## 8. Observation contract

The initial state has five normalized components:

1. forward interval-averaged center-of-mass velocity;
2. configured target forward velocity;
3. current applied tail-beat frequency ratio;
4. `sin(phi)`; and
5. `cos(phi)`.

The target is included even when fixed so later target curricula do not require
changing the state contract. Sine and cosine encode phase without a wrap
discontinuity. The forward unit direction and all normalization scales are
explicit configuration values. A baseline run must verify the forward sign;
the implementation must not silently assume that positive global x is forward.

The velocity used in a transition is

```text
u_bar = dot(COM_end - COM_start, forward_direction) / elapsed_time
```

rather than a noisy single-CFD-step sample.

## 9. Reward contract

For one control interval, the initial reward is

```text
r = -w_v  ((u_bar - u_target) / u_scale)^2
    -w_f  (r_applied - 1)^2
    -w_df (r_applied - r_previous)^2
```

where all weights and scales are configured and recorded in the run manifest.
The three terms represent target tracking, frequency regularization, and
command smoothness. Reward components are logged separately for diagnosis.

The frequency term is only a control regularizer. No result from this stage may
describe it as power, energy, cost of transport, or swimming efficiency.
Hydrodynamic power and efficiency require a later verified measurement design.

## 10. Episode behavior

A stage-two run contains:

1. environment initialization using the official-case initial state;
2. an optional configurable warmup at `f0`;
3. one multi-decision controlled episode;
4. terminal exchange at the configured horizon or normal IBAMR end time; and
5. coordinated shutdown and model/evidence persistence.

This stage does not destroy and reconstruct IBTK/IBAMR for another independent
episode in the same process. It must not simulate reset by privately finalizing
MPI, reinitializing global frameworks without proof, or forking a replacement
solver. Training-quality claims that require many independent resets remain
blocked until the reset stage is separately admitted.

## 11. Error handling

- Invalid configuration is rejected before MPI launch when possible.
- Invalid action values are handled according to the action contract.
- Missing or non-finite COM/time/state data is a distributed fatal error.
- IBAMR exceptions after distributed initialization enter the existing
  coordinated fatal callback and `MPI_Abort` path.
- Normal terminal conditions use the Smarties protocol and then the single
  driver-owned shutdown path.
- Every real run records terminal reason, number of decisions, number of IBAMR
  timesteps, clipping count, actual control-interval durations, and exit code.

## 12. Expected code boundaries

The implementation plan may refine file names, but responsibility remains:

- `cases/eel2d/upstream/IBEELKinematics.{h,cpp}`: auditable continuous-phase
  frequency control while preserving official geometry and amplitude.
- `cases/eel2d/EelEnvironment.{h,cpp}`: command application at safe times,
  control-interval advancement, COM/time/phase/frequency observations.
- `cases/eel2d/EelSmartiesAdapter.cpp`: Smarties protocol, normalization,
  reward calculation, logging, and episode horizon.
- `configs/`: task parameters, reward weights, normalization, warmup, and
  horizon.
- `scripts/`: rendering, manifest capture, and eventual enabling of `train`
  only after its admission requirements pass.
- `tests/`: kinematics equivalence, phase continuity, action mapping, reward,
  protocol, topology, failures, and repeatability.

## 13. Verification and admission gates

Verification is cumulative:

1. **Analytic baseline:** fixed `f0` matches official shape and deformation
   velocity at sampled positions and times.
2. **Command mapping:** actions `-1`, `0`, and `1` produce the configured target
   frequencies and correct slew-limited applied frequencies.
3. **Phase continuity:** frequency changes do not create a phase or fish-shape
   jump at the switching time.
4. **Build/link:** the real IBAMR/Smarties executable builds using GCC 8.5.0 and
   the isolated node3 dependency overlay.
5. **Short physical response:** distinct actions produce distinct verified
   kinematics and IBAMR COM trajectories.
6. **Protocol:** a multi-decision episode sends the five-component state,
   scalar action, componentized reward, and one terminal transition correctly.
7. **Topology:** supported learner/environment/rank combinations complete
   without cross-communicator deadlock.
8. **Failure:** injected failures after distributed initialization abort
   coherently and leave no residual eel/MPI process.
9. **Repeatability:** the required matrix passes repeated runs from one clean
   revision and executable hash.
10. **Evidence:** source revision, build revision, executable hash, task config,
    environment identity, logs, and terminal summaries agree.

Before node3 admission, `train` remains disabled or explicitly experimental.
All unverified output stays under `.artifacts`. Only conclusions that satisfy
the repository's experience-admission rules may be written under
`experience/verified/`.

## 14. Implementation order

1. Add tests for the official baseline equations.
2. Introduce continuous phase while holding `r_applied = 1`.
3. Prove baseline equivalence.
4. Add action mapping, bounds, slew limiting, and phase-switch tests.
5. Connect the Smarties action to the real kinematics command.
6. Add control-interval advancement and COM-derived observations.
7. Add normalized state, componentized tracking reward, and logging.
8. Run a multi-decision episode locally with test doubles where appropriate.
9. Extend task configuration, run manifests, and launcher validation.
10. Package the exact revision and perform the full node3 admission matrix.
11. Promote verified conclusions only after independent evidence review.

## 15. Deferred next stages

After this stage is admitted, separate designs are required for:

- robust physical reset or continuing-task semantics for long training;
- target-speed curricula and policy-quality evaluation;
- real hydrodynamic work, power, and cost-of-transport rewards;
- amplitude and steering actions; and
- optional PyTorch CPU/GPU inference and training.
