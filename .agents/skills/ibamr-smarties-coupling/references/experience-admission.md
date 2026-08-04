# Verified experience admission

`experience/verified/` is the trusted knowledge base, not a notebook. Draft the candidate outside `experience/`, at `.artifacts/ibamr-smarties-investigations/<issue-id>/candidate.md`, and promote it only after every gate below passes.

## Admission gate

All answers must be yes:

1. Does the claim concern the exact IBAMR-Smarties path named in the scope?
2. Is the relevant code/configuration identified by immutable revision or checksum?
3. Is the hardware, OS, compiler, MPI, PETSc/IBAMR, and Smarties environment recorded as applicable?
4. Are topology, launch command, inputs, expected result, actual result, exit status, and log/artifact paths present?
5. Was the original failure reproduced or otherwise captured before the fix?
6. Does evidence distinguish the root cause from correlation?
7. Did the target-case fix pass normal operation, clean shutdown, and relevant failure/reset behavior?
8. Were sufficient repeated runs completed to reject a one-off success, with the count stated?
9. Did regression checks for affected neighboring paths pass?
10. Are limitations explicit, with no claim broader than the evidence?
11. Has a reviewer rerun or independently inspected the evidence?

One “no” means no promotion. Store the work only in `.artifacts/ibamr-smarties-investigations/` and state what remains to be verified.

## Atomic record template

Use one file per independently verified conclusion. Do not mix a passed fact with pending advice.

```markdown
# <Narrow verified conclusion>

- Status: verified
- Verified on: <ISO date>
- Scope: <exact cases, machines, and versions covered>
- Code revisions: <IBAMR revision; Smarties revision; coupling revision>
- Reviewer: <person or independent verification path>

## Problem and original symptom

<What failed, how it appeared, and how it was reproduced or captured.>

## Demonstrated root cause

<Evidence that distinguishes the cause from a plausible hypothesis.>

## Resolution

<Exact change or operational procedure.>

## Verification matrix

| Check | Command/input | Expected | Actual | Artifact | Result |
|---|---|---|---|---|---|
| Target coupling run | ... | ... | ... | ... | PASS |
| Clean shutdown | ... | ... | ... | ... | PASS |
| Failure/reset path | ... | ... | ... | ... | PASS |
| Repeated runs (N=...) | ... | ... | ... | ... | PASS |
| Regression | ... | ... | ... | ... | PASS |

## Limitations

<What this record does not establish.>
```

## Promotion procedure

1. Verify every linked artifact still exists and matches the stated run.
2. Rerun the decisive command or record why an independent artifact inspection is equivalent.
3. Check every admission question.
4. Copy the atomic record to `experience/verified/YYYY-MM-DD-<short-slug>.md`.
5. Add it to the verified table in `experience/README.md` with its exact scope.
6. Keep raw logs in artifacts; do not inflate the record with transient output.

Never “promote with a warning.” A warning does not turn incomplete evidence into verified knowledge.
