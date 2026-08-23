# eel2d reference implementation

Use this page only for the official IBAMR 0.18.0 `ConstraintIB/eel2d` frequency-control implementation or as a concrete example of the generic coupling architecture.

## Provenance and file boundary

- `couplings/ibamr/cases/eel2d/upstream/` is derived from the official IBAMR 0.18.0 example. `PROVENANCE.md` records the origin and hashes.
- `eel2d.vertex` is the unmodified official Lagrangian model. Never resample it to match a coarser Eulerian grid.
- `upstream/IBEELKinematics.*` changes only temporal phase and angular frequency. Official geometry, amplitude envelope, maneuvering logic, and normals remain intact; frequency ratio 1 preserves the official angular frequency `6.28`.
- `TailBeatPhase.*` keeps phase continuous across frequency changes.
- `EelEnvironment.*` owns IBAMR initialization, advancement, measurement, and shutdown on the environment communicator.
- `EelControlTask.*` owns state, action mapping, cadence, and reward mathematics.
- `EelSmartiesAdapter.*` owns the synchronous Smarties protocol.
- `main.cpp` only selects the mode and delegates lifetime to `CouplingDriver`.

## Control definition

The action is one scalar. It is clipped to `[-1, 1]`, mapped linearly to `[minimum_frequency_ratio, maximum_frequency_ratio]`, and slew-limited by `maximum_ratio_delta` before being applied.

The five-dimensional state is:

1. forward velocity divided by `velocity_scale`;
2. target forward speed divided by `velocity_scale`;
3. applied tail-frequency ratio;
4. sine of the continuous tail phase;
5. cosine of the continuous tail phase.

Forward velocity is the center-of-mass displacement over the actual completed interval, projected onto the configured forward direction and divided by actual elapsed time.

The reward is the sum of three non-positive terms:

- tracking: `-tracking_weight * ((velocity - target) / velocity_scale)^2`;
- frequency regularization: `-frequency_weight * (applied_ratio - 1)^2`;
- smoothness: `-smoothness_weight * (applied_ratio - previous_ratio)^2`.

The frequency term is a control regularizer, not a physical energy or propulsive-efficiency measurement. Task files used only for protocol or learner-activity tests contain synthetic values and are not calibrated training tasks.

One control interval is `2*pi / (decisions_per_baseline_period * baseline_angular_frequency)`. The adapter performs this sequence: publish current state, block for one action, apply one frequency ratio at the safe boundary, advance the complete interval, measure the resulting state and reward, and publish the transition.

## Segment semantics

`EelEnvironment` is initialized once per worker callback. A logical horizon emits `sendLastState()` and the next segment emits `sendInitState()` from the same physical trajectory. The hierarchy, flow, geometry, physical time, phase, applied frequency, and control task are not reset.

Smarties termination is checked after each protocol exchange. If IBAMR reaches physical `END_TIME` first, the adapter publishes the truncated final transition and enters the coordinated fatal path; it must not return normally and allow an unintended second environment callback.

## Bounded validation result

At source revision `f4bc6d8835634302b93ec5341a504d96e6f2f874`, node3 validation used GCC 8.5, Open MPI 5.0.9, IBAMR 0.18, CPU Smarties, one learner rank, one two-rank IBAMR environment, and two learner threads. The medium run completed two logical segments, four decisions, 5004 IBAMR steps, retained 2932 global Lagrangian points, performed exactly two finite native CPU learner updates, and reloaded a checkpoint with the same final network digest. A bounded early-`END_TIME` run reached the coordinated fatal path without observed callback reentry. Revision `b376ee7` added only scoped `orted` cleanup detection.

This evidence supports bounded coupling correctness for that topology and environment. It does not establish policy quality, reward calibration, convergence, long-run repeatability, independent physical reset, PyTorch/CUDA support, or compatibility with another IBAMR/SAMRAI version.
