# Validated and reusable coupling lessons

These conclusions combine current implementation behavior with bounded target
evidence. Each portability boundary remains part of the conclusion.

## MPI lifetime

The coupling remains well-defined when `CouplingDriver` owns MPI and Smarties
uses its borrowed-communicator constructor. Smarties then skips MPI
initialization/finalization and frees only derived communicators.

**Boundary:** every new entrypoint must use the borrowed constructor; Smarties'
owned-MPI constructors have different ownership semantics.

## Environment communicator

PETSc, SAMRAI, IBTK, and IBAMR must agree on the environment communicator.
Assigning only `PETSC_COMM_WORLD` is insufficient when a SAMRAI source path
still calls `MPI_COMM_WORLD` directly.

**Boundary:** the current SAMRAI patch is version-specific. Inspect and rebuild
a separate overlay for every dependency version.

## Action synchronization

The environment can remain alive for the full MPI job. At a safe point,
`recvAction()` blocks the environment call stack; no IBAMR step executes until
the action arrives. The action is applied before a complete CFD control
interval and the resulting state is returned afterward.

**Boundary:** the case must not run an independent background time loop and
must identify an application point at which its controlled objects are
consistent.

## Logical versus physical boundaries

Smarties replay segmentation can continue across one physical CFD timeline.
Closing a logical segment does not require destroying or reconstructing the
hierarchy, flow, geometry, time, or case-control state.

**Boundary:** this proves continuing-segment mechanics, not independent
episode reset. A reset claim requires explicit restoration and target-case
validation.

## Failure convergence

Normal shutdown is reliable only when CFD objects die before Smarties returns
to the driver and the driver finalizes MPI last. A distributed fatal error
must converge on `MPI_Abort`; returning one environment rank independently can
leave peers blocked or permit unintended callback reentry.

**Boundary:** recoverable numerical terminals require a case-specific reset
contract and are not interchangeable with the fatal path.

## Evidence identity

Source revision alone does not identify a run. Build manifests, executable and
runtime-library identities, dependency roots, patch identity, launch topology,
frozen inputs, exit status, and scoped process cleanup are needed to attribute
a coupling result.

**Boundary:** mechanical manifests establish provenance, not policy quality,
physical validity, or repeatability.

## Long-run output

Replay capacity, transition logging, learner checkpoints, scalar traces,
field visualization, and IBAMR restart dumps are separate controls. Default
short-test output settings can grow without bound in a long run.

**Boundary:** define a run-specific retention policy before long training. A
checkpoint supports restart/evaluation; it does not replace physical field
output needed for later CFD analysis.
