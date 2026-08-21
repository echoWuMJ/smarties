---
name: ibamr-smarties-coupling
description: Use when designing, implementing, reviewing, debugging, or documenting an IBAMR-Smarties coupling, especially MPI ownership, communicator partitioning, long-lived training segments, shutdown, or admission of lessons into experience.
---

# IBAMR-Smarties Coupling

## Purpose

Keep every coupling case on one long-lived, driver-owned MPI architecture and prevent unverified conclusions from becoming project knowledge. The architecture contract is a design decision; it is not itself a verified experience.

## Required workflow

1. Read [references/architecture-contract.md](references/architecture-contract.md) before proposing or changing coupling code.
2. For the official eel2d continuing-training path, also read
   [references/eel2d-continuing-coupling.md](references/eel2d-continuing-coupling.md).
3. State the MPI owner, rank partition, communicator passed to each library, and shutdown path in the plan. Reject any design that conflicts with the contract.
4. Keep case-specific state, action, reward, terminal conditions, and reset logic behind the adapter boundary. Do not change the ownership model to suit one case.
5. Keep neural-network execution on the current Smarties CPU path. PyTorch and GPU enablement are out of scope until the user explicitly starts that phase.
6. Verify in increasing scope: build/link, communicator topology, one safe control interval, logical-boundary continuity where applicable, clean normal shutdown, relevant failure behavior, and repeated target-case runs when claiming repeatability.
7. For every coupling problem, use the closure gate below. Do not describe a suspected cause as solved.
8. Only after the gate passes, create one atomic record in `experience/verified/` using [references/experience-admission.md](references/experience-admission.md) and update `experience/README.md`.

## Fixed decisions

- The coupling driver is the sole owner of `MPI_Init_thread()` and `MPI_Finalize()`.
- Smarties borrows a supplied communicator, duplicates what it needs, frees only its own communicators, and never finalizes MPI in borrowed mode.
- Never `fork()` after MPI initialization. Allocate dedicated MPI ranks to learners and environment workers.
- Only environment ranks initialize PETSc, SAMRAI, IBTK, and IBAMR. Set `PETSC_COMM_WORLD` to the environment communicator before PETSc/IBTK initialization.
- IBAMR owns the CFD time-stepping loop inside the environment worker. The adapter exchanges state, action, reward, terminal status, and reset commands only at explicit safe points.
- A logical Smarties training segment is not automatically an IBAMR reset. In a continuing case, preserve the existing environment, hierarchy, flow, geometry, time, and case-control state across `sendLastState()` / next `sendInitState()`; only perform a physical reset when that case explicitly defines one.
- Normal destruction is inside-out; the driver finalizes MPI last. Distributed fatal errors coordinate and call `MPI_Abort`, never independent rank finalization.

If current Smarties code cannot honor borrowed-MPI semantics, treat that as an implementation gap. Do not silently fall back to dual ownership.

## Problem closure and experience promotion

Keep all hypotheses, partial logs, failed attempts, and pending fixes outside `experience/`, under `.artifacts/ibamr-smarties-investigations/<issue-id>/`.

A problem is **closed** only when all of these are true:

- the original symptom and affected scope are recorded;
- the root cause is demonstrated, not merely plausible;
- the fix is exercised on the target IBAMR-Smarties path;
- normal shutdown and at least one relevant failure/reset path pass;
- repeated runs rule out a one-off success;
- exact revisions, environment, topology, commands, expected results, actual results, and artifact locations are recorded;
- limitations and the boundary of the claim are explicit.

If any item is missing, report the result as open or partially verified and leave it outside `experience/`. Time pressure, scarce compute, success in CartPole, or success under a different MPI stack never lowers the gate.

## Experience integrity

An experience record must contain only claims directly covered by its evidence. Split mixed records so a verified fact is never bundled with an unverified recommendation. `experience/verified/` is the only authoritative record area. Never copy research notes, proposed architecture, or candidate fixes into it. Mechanical completeness checks do not prove correctness; inspect the referenced logs and rerun the stated verification before admission.
