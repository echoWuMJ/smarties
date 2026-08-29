# Verified experience index

This directory is the experience governance root for the IBAMR-Smarties work. Only records under `experience/verified/` that pass `.agents/skills/ibamr-smarties-coupling/references/experience-admission.md` are authoritative.

Unverified hypotheses, research notes, partial logs, failed attempts, and candidate fixes belong in `.artifacts/ibamr-smarties-investigations/`, not here.

## Verified records

| Record | Exact verified scope | Implementation revision |
|---|---|---|
| [eel2d stage-one lifecycle](verified/2026-08-08-eel2d-stage1-lifecycle.md) | IBAMR 0.18.0 eel2d lifecycle, specified MPI topologies, normal shutdown, and coordinated fatal failure on node03 | `1b8d437a54f5` |
| [distributed-environment shutdown](verified/2026-08-24-distributed-environment-shutdown.md) | Smarties multi-rank environment declaration and clean master/IBAMR termination for the verified node03 topology | `a4d0d91ad653` |
| [terminal visualization idempotence](verified/2026-08-29-terminal-visualization-idempotence.md) | IBAMR 0.18.0 eel2d last-step plus adapter-requested terminal VisIt/Silo output on node03 | `d9af395df2ee` |

## Legacy documents pending audit

The following files predate the evidence gate and must not be treated as verified experience or cited as proof until they are audited and split into atomic, evidence-backed records:

- `node3_smarties_uv_install.md` — contains installation observations together with unresolved or proposed follow-up work.
- `smarties_api_ibamr_coupling_research.md` — research and architecture exploration; it is not target-coupling validation evidence.

Do not add these files to the verified table merely by relabeling them. Re-run the applicable checks and admit only the claims directly supported by complete evidence into `experience/verified/`.
