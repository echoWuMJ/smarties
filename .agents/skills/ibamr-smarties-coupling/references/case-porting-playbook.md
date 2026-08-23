# Porting an IBAMR case to Smarties

## Target structure

Transform an official IBAMR example without changing the global coupling
architecture:

```text
official example main loop
  -> thin main: mode selection + CouplingDriver
  -> CaseEnvironment: initialize, observe, apply action, advance, reset/shutdown
  -> CaseSmartiesAdapter: protocol, dimensions, state, action, reward, terminal
  -> case-specific control implementation
```

Keep the official input, geometry, kinematics, and time loop as the numerical
reference. Record provenance for copied sources and identify every intentional
formula or API change.

## CaseEnvironment boundary

The environment owns all case-specific CFD objects. Its public operations
should cover only the capabilities the adapter needs:

- initialize on a supplied environment communicator;
- extract observations and physical time;
- validate and apply control at the current safe time;
- advance one solver step or one complete control interval;
- report whether physical steps remain;
- perform a fully defined physical reset when supported;
- release CFD resources before returning from the callback.

Set the PETSc and SAMRAI communicator before any case object can communicate.
Do not expose CFD objects to learner ranks or let the adapter advance a hidden
second time loop.

## Adapter boundary

The adapter owns the reinforcement-learning contract:

- state components, units, scaling, and finite-value checks;
- action dimensions, bounds, clipping, slew limits, and application time;
- control cadence expressed in physical time or verified solver events;
- reward terms, units, weights, and distinction between physical measurement
  and regularization;
- logical terminal/truncation rules and Smarties messages;
- physical end-time and distributed-failure handling.

The control cycle is synchronous:

```cpp
comm->sendInitState(state);
const auto action = comm->recvAction();
environment.applyAction(validate(action));
const auto interval = environment.advanceControlInterval(duration);
comm->sendState(nextState(interval), reward(interval));
```

`recvAction()` is the pause point. Apply the action only after it returns and
before the first CFD step in the new interval.

## Decisions required before implementation

| Decision | Required definition |
|---|---|
| Observation | Physical variables, sample time, units, scaling, validity range |
| Action | Controlled quantity, bounds, rate limit, effective safe point |
| Cadence | Number of solver steps or physical duration per action |
| Reward | Measured terms versus regularizers, sign, scale, terminal contribution |
| Logical boundary | When Smarties closes a trajectory and whether physics continues |
| Physical reset | Complete restoration method or an explicit continuing timeline |
| Physical end | Normal terminal state or coordinated fatal condition |
| Output | Transition, scalar trace, field dump, restart, checkpoint retention |
| Version port | IBAMR/SAMRAI/PETSc API and communicator assumptions to revalidate |

## Validation sequence

1. Build the case and link one Smarties executable.
2. Confirm only the driver owns MPI and only environment ranks initialize CFD.
3. Confirm all CFD collectives use the environment communicator.
4. Run one action interval and verify exactly one bounded action application.
5. Verify physical time, observations, reward, and solver invariants.
6. Exercise the defined logical or physical boundary without callback reentry.
7. Verify normal destruction and one relevant fatal/reset path.
8. Check residual MPI processes and output completeness.
9. Repeat at the intended rank topology and fidelity before making scale or
   stability claims.

For a new IBAMR or SAMRAI version, create a separate dependency overlay,
inspect communicator-sensitive source paths, adapt against the new APIs, and
repeat the sequence. Never infer source or binary compatibility from a prior
version.
