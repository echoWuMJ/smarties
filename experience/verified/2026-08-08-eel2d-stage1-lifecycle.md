# Verified eel2d stage-one lifecycle coupling

- Status: verified
- Verified on: 2026-08-08 (Asia/Shanghai)
- Scope: Smarties plus IBAMR 0.18.0 `ConstraintIB/eel2d` lifecycle coupling on node3
- Coupling revision: `1b8d437a54f5ec1c73e41cc896490be67e115759`
- Baseline revision: `971846b4f4df`
- Source archive SHA-256: `4863f0ca02c17f7211a5453c59526ebee8974e6746c07fc51c852fa45bea9d87`
- SAMRAI patch SHA-256: `5dbfa5c25cf91dd13ab2d253bcc1511824129623be7e81bcbc4b79a918b6cf10`
- Final evidence: `.artifacts/ibamr-smarties-investigations/eel2d-stage1/eel2d-stage1-1b8d437a54f5/`
- Baseline evidence: `.artifacts/ibamr-smarties-investigations/eel2d-stage1/eel2d-stage1-32552a0c3fd6/`
- Reviewer: independent code and artifact inspection by the final code-review agent

## Environment

- Host: `node03`
- OS/kernel: CentOS Linux 7, Linux `3.10.0-1160.108.1.el7.x86_64`
- CPU: Intel Xeon Platinum 8179M at 2.40 GHz
- GPU present but unused: Quadro GV100, driver 525.60.13
- C/C++ compiler: GCC/G++ 8.5.0
- MPI: Open MPI 5.0.9; wrappers resolve to the required GCC/G++ 8.5.0
- PETSc: 3.23.3
- IBAMR: 0.18.0
- SAMRAI base: IBSAMRAI2 2025.10.29 with the tracked subcommunicator patch
- Smarties network backend: native CPU; Python, PyTorch, CUDA, and pybind11 are not enabled

## Problem and original symptom

The topology `--envs 1 --ranks-per-env 2` hung during IBAMR hierarchy initialization. The Smarties master waited for the environment descriptor while the two IBAMR ranks blocked in SAMRAI `BinaryTree::reduce()` and `BinaryTree::partialBcast()`.

A pre-fix reproduction used revision `971846b4f4df` with the same three-rank topology. It did not reach Smarties setup or terminal exchange within 15 seconds and the controlled outer timeout returned 124. The post-timeout process snapshot contained no residual `mpiexec` or `ibamr_eel2d_smoke` process.

## Demonstrated root cause

IBSAMRAI2 computed tree members in the environment communicator's rank space but sent operational tree messages through hard-coded `MPI_COMM_WORLD`; related box and asynchronous clustering paths also defaulted to the world communicator. With a separate learner rank, environment rank 0/1 did not equal world rank 0/1, so messages were routed to the wrong processes.

The patch guard applies the tracked patch to the exact node3 source, rejects a second application, and confirms that the four affected implementation files retain no operational `MPI_COMM_WORLD`. The identical pre-fix timeout and post-fix 3/3 success of the `1 environment x 2 ranks` topology provide the behavioral A/B check.

## Resolution

`prepare_node3_ibamr.sh` builds a content-guarded SAMRAI/IBAMR overlay at `/data2/mjwu/local/coupling-deps/ibamr-0.18.0-samrai-subcomm-v1`; the shared autoibamr installation remains unchanged. `build_node3.sh` records source, executable, IBAMR/PETSc, overlay, and patch identities. `run_node3.sh` rejects or rebuilds a missing, stale, or modified executable before MPI launch and records the verified build and environment provenance in every run manifest.

The fixed architecture is preserved: `CouplingDriver` alone initializes/finalizes MPI; Smarties borrows the driver communicator and does not free caller aliases; learner ranks do not initialize IBAMR; each environment uses its Smarties-created subcommunicator; and no process forks after MPI initialization. Unrecoverable callback exceptions are logged once and end with `MPI_Abort` on the environment communicator, never private `MPI_Finalize` recovery.

## Verification matrix

| Check | Command/input | Expected | Actual | Artifact | Result |
|---|---|---|---|---|---|
| Source identity | local/node3 archive SHA-256 and `sha256sum -c` after extraction | Equal hash; every entry validates | `4863f0ca...bea9d87`; 330/330 entries validated; clean tracked tree; zero included untracked files | `package.sha256`, `SOURCE_METADATA.txt`, `source-manifest-verification.log` | PASS |
| Complete regression suite | node3 `ctest --output-on-failure` | All tests pass | 11/11 in 5.33 s, including communicator alias, curriculum, real eel2d, SAMRAI guard, and MPI failure | `ctest.log` | PASS |
| Baseline failure | pre-fix `1 env x 2 ranks`, coarse, one step, 15 s timeout | Reproduce hang | Exit 124 before Smarties setup | baseline `baseline-unpatched.log` | PASS |
| Serial environment | `1 env x 1 rank`, coarse, one step | Clean terminal/shutdown | 3/3 exit 0; one terminal marker each | final `runs/eel2d-20260808T16393*/` | PASS |
| Distributed environment | `1 env x 2 ranks`, coarse, one step | No SAMRAI deadlock | 3/3 exit 0; one terminal marker each | final `runs/eel2d-20260808T16394[0-2]*/` | PASS |
| Concurrent environments | `2 env x 1 rank`, coarse, one step | No cross-environment traffic | 3/3 exit 0; two terminal markers each | final `runs/eel2d-20260808T16394[3-5]*/` | PASS |
| Higher fidelity | `1 env x 1 rank`, medium, one step | Clean terminal/shutdown | 3/3 exit 0 | final `runs/eel2d-20260808T16394[6-8]*/` | PASS |
| Curriculum entry | `1 env x 1 rank`, curriculum, one step | Parse/render three stages and run | Exit 0; coarse/medium/fine argument files present | final `runs/eel2d-20260808T163949*/` | PASS |
| Fatal callback path | `1 env x 2 ranks --fault-after-initialize` | Fail after real IBAMR init; no private finalize or residual ranks | Exit 98; injected error logged; zero terminal markers; no residual process | final `runs/eel2d-20260808T164014*/`, `process-snapshot.txt` | PASS |
| Build/source identity | every final run manifest | Source, build, executable, dependencies match final revision | All 14 manifests use `1b8d437a54f5`, one executable hash, and one build-manifest hash | `verification-summary.txt`, `build_manifest.txt` | PASS |

## Limitations

This evidence establishes only MPI ownership, communicator isolation, a real IBAMR eel2d one-step lifecycle, input/curriculum rendering, normal termination, and the unrecoverable distributed-failure path. The action is shape-checked but deliberately not applied to the fish; state is normalized time and reward is zero. It does not establish a physical control law, meaningful observation/reward design, controlled episode reset after a recoverable numerical failure, multi-step training, policy quality, numerical convergence, fine-fidelity operation, GPU/PyTorch behavior, or performance scalability.
