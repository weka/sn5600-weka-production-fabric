# SN5600 / WEKA production fabric

An operations handover for the physical WEKA fabric: switch bring-up, cabling,
numbered /31 routing, Ethernet conversion, client addressing, lossless RoCE,
reboot validation and RDMA bandwidth testing.

**This is the real production environment. It is not DSX Air or Nitro.**
Snapshot: September 30, 2026, America/Los_Angeles. This repository records
supplied evidence; it does not claim to be a fresh scan of the equipment.

## Start here

1. Read [current status](docs/CURRENT_STATUS.md) and [open issues](docs/OPEN_ISSUES.md).
2. Read [the beginner handover](docs/HANDOVER.md) to understand the network.
3. Use [the topology](docs/TOPOLOGY.md) and [inventory](inventory/README.md) to locate equipment.
4. Follow [the operations guide](docs/OPERATIONS.md) for checks and changes.
5. Run `bash run_checks.sh verify` to check local file integrity.
6. Run `bash run_checks.sh all-switches` for a read-only switch snapshot.

## Status at this snapshot

| Item | Evidence-backed status |
|---|---|
| Fabric scope | Four spines and four active client leaves; leaf-05 deferred |
| Switch lossless RoCE | Enabled, applied and saved on all eight in-scope switches |
| Client population | 40 planned clients; 35 have confirmed mappings |
| Client RoCE | 34 configured; weka44 deferred because one link remains down |
| Client reboot validation | 30 passed: 27 latest-batch clients plus pilots weka60–62 |
| Previously configured clients | weka66–69 passed prechecks; not rebooted in latest batch |
| Same-leaf RDMA | Approximately 392 Gb/s per 400G NIC; 784 Gb/s combined |
| Cross-leaf RDMA | Five directed tests passed; seven directions still pending |
| All-path/congestion/failover/WEKA application tests | Not completed |

Successful pings and bandwidth tests do not mean all physical uplinks are healthy.
See [evidence](evidence/README.md) for what was actually tested.

## Repository layout

| Directory | Purpose |
|---|---|
| `docs/` | Current handover, topology, addressing, operations, RoCE, troubleshooting, issues and timeline |
| `inventory/` | Corrected five-rack placement, switch identities, per-port /31 maps and client status |
| `scripts/` | Read-only snapshots, conversion, tested rollout wrappers, reboot checks, RDMA tests and heatmap generator |
| `packages/SN5600_Client31_Rollout_20260929/` | Client and leaf-specific /31 deployment package |
| `evidence/` | Redacted dated session logs, recorded results and provenance |
| `diagrams/` | Editable rack drawings and current topology references |
| `archive/` | Original dated handover documents, workbooks and underlay migration tools |
| `.github/workflows/` | Offline checks only; no production deployment |

## Important gaps

The exact tested `/root/weka-roce-precheck.sh` and `/root/deploy-weka-roce.sh`
payloads were not present in the supplied local project files. Their runtime
output and the batch wrapper are included. Collect the exact copies from weka61:

```bash
bash scripts/collect_roce_reference.sh
```

This copies the scripts and persistence files without applying anything.
Review the collected files before committing. Do not replace the missing tested
payloads with an invented implementation. Latest cross-leaf results beyond the
five recorded directions have not yet been supplied; add them after the running
test completes.

## Credentials and publishing

No password is embedded. Use SSH keys, interactive authentication, or supply
`SSHPASS` for the supported cross-leaf runner without writing the value into Git.
Host-key verification is retained. Reports may contain infrastructure information;
use a **private repository** and review additions before publishing.

```bash
# After reviewing the files, publish using your authenticated GitHub account:
bash scripts/publish_github.sh OWNER/sn5600-weka-production-fabric
```

No license grant is assumed. This repository contains internal operations material.
