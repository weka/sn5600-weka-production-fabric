# Ownership and transition checklist

Sekhar is the outgoing project operator. The receiving owner has not been named
in this conversation. Matt is a named collaborator for client and boot issues;
DC Ops is the coordination group for cabling. Those mentions are not accepted
assignments, deadlines or evidence that messages were sent.

| Work area | Receiving owner | Coordination | Completion evidence |
|---|---|---|---|
| Repository/admin access and team access | To be assigned | WEKA team | Team can clone private repo after operator offboarding |
| Fabric routing and switch configuration | To be assigned | Network operator | Reviewed snapshots, expected peer map, fresh validation |
| Client mode, /31 and RoCE | To be assigned | Matt | Host map, current precheck, local/cross-leaf tests |
| Physical cables and failed links | To be assigned | Matt and DC Ops | Confirmed port/serial pairing and stable link/error deltas |
| Reboot/service warnings | To be assigned | Matt | Reviewed boot logs and documented remediation |
| Evidence and heatmap review | To be assigned | Test operator | Final directed results, server logs, counter deltas |
| Backend and leaf-05 expansion | To be assigned | WEKA/network team | Confirmed inventory, approved IP/port plan and application test |
| Private backup storage and access | To be assigned | Team administrator | Restricted storage location and successful access test |

## Before the outgoing operator leaves

- Identify the receiving engineer and repository administrator.
- Give authorized team members access; confirm clone and offline checks work.
- Transfer unredacted originals to approved restricted storage. Never Git.
- Confirm where BMC/SSH access is managed without copying credentials here.
- Walk through one client check, one switch check and a degraded-link diagnosis.
- Explain planned/observed/validated status and why missing heatmap cells are not passes.
- Review OPEN_ISSUES.md and the ownership register; assign owners and target dates.
- Confirm the latest report import manifest and client capture coverage.
- Document future maintenance authorization separately; earlier no-workload
  authorization does not permit future unannounced reboots.

No people were contacted automatically by these scripts or document updates.
