---
name: ibamr-smarties-coupling
description: Use when designing, implementing, porting, installing, reviewing, debugging, or documenting any IBAMR-Smarties reinforcement-learning coupling, especially MPI ownership, subcommunicators, safe action points, solver lifecycle, shutdown, and verified-experience admission.
---

# IBAMR-Smarties Coupling

## Reference routing

- Read [references/architecture-contract.md](references/architecture-contract.md) for every coupling task.
- Read [references/case-porting-playbook.md](references/case-porting-playbook.md) when adding or restructuring a case.
- Read [references/validated-lessons.md](references/validated-lessons.md) before changing communicators, lifecycle, control cadence, output retention, or evidence handling.
- Read [references/eel2d-reference.md](references/eel2d-reference.md) only when working on eel2d or using it as an implementation example.
- Read [references/experience-admission.md](references/experience-admission.md) before writing under `experience/verified/`.

## Fixed invariants

- The coupling driver is the sole owner of `MPI_Init_thread()` and `MPI_Finalize()`.
- Smarties borrows a supplied communicator, duplicates what it needs, frees only its own communicators, and never finalizes MPI in borrowed mode.
- Never `fork()` after MPI initialization. Allocate dedicated MPI ranks to learners and environment workers.
- Only environment ranks initialize PETSc, SAMRAI, IBTK, and IBAMR. Set `PETSC_COMM_WORLD` to the environment communicator before PETSc/IBTK initialization.
- IBAMR owns the CFD time-stepping loop inside the environment worker. The adapter exchanges state, action, reward, terminal status, and reset commands only at explicit safe points.
- A blocking `recvAction()` is the synchronization point: the environment waits without advancing IBAMR, then applies exactly one accepted action before advancing one complete control interval.
- A logical Smarties training segment is not automatically an IBAMR reset. In a continuing case, preserve the existing environment, hierarchy, flow, geometry, time, and case-control state across `sendLastState()` / next `sendInitState()`; only perform a physical reset when that case explicitly defines one.
- Normal destruction is inside-out; the driver finalizes MPI last. Distributed fatal errors coordinate and call `MPI_Abort`, never independent rank finalization.

## Generic case integration

1. Preserve the official IBAMR example's numerical setup and time-stepping order before introducing control.
2. Move case initialization, observation extraction, control application, interval advancement, reset, and shutdown into a long-lived environment object.
3. Keep state/action/reward definitions, control cadence, terminal policy, and Smarties messages in a thin case adapter.
4. Keep `main()` limited to MPI ownership, rank partitioning, borrowed Smarties startup, environment dispatch, ordered destruction, and finalization.
5. Define explicitly whether an episode boundary is logical continuation, partial reset, or full physical reset; never infer reset semantics from `sendLastState()`.
6. Define output retention before a long run so CFD visualization, per-step samples, checkpoints, and restart data do not grow without a stated purpose. Make an adapter-requested terminal snapshot idempotent with the case loop's scheduled and last-step output.

## Verification and experience

Verify in increasing scope: build/link, communicator topology, one action interval, state/action/reward exchange, logical or physical boundary behavior, normal shutdown, and the relevant fatal or reset path. Add repeated or long runs only when the claim being made requires them.

Keep hypotheses, partial logs, failed attempts, and pending fixes under `.artifacts/ibamr-smarties-investigations/<issue-id>/`. Promote one atomic conclusion to `experience/verified/` only after the admission rules pass with exact revisions, environment, topology, commands, results, artifacts, and claim limits. Do not use successful compilation or an unrelated Smarties example as coupling evidence.

Use Smarties' current CPU neural-network path. PyTorch, CUDA, pybind11, and Python bindings remain outside this coupling baseline until a separate migration phase is requested.
