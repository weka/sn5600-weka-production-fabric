# Open issues and next operator actions

| Item | Last observed state | Action / closure evidence |
|---|---|---|
| weka44 link1 | ens4047np0 / leaf-04 swp2s1 down; link2 configured and jumbo passed | Repair physical link with Matt/DC Ops; confirm link mode, speed, jumbo and host profile before deploying full RoCE |
| weka64 | Deferred; RDMA inventory incomplete despite OS SSH reachability | Collect PCI/RDMA/firmware inventory; confirm both port MACs/LLDP, then map and validate |
| weka78 | OS ping and SSH failed; BMC reachable | Diagnose via BMC; collect OS/NIC inventory after recovery |
| weka79 | Deferred; NIC inventory not completed | Collect and confirm MAC/interface mapping |
| weka48 and weka59 | No confirmed mapping in deployment package | Scan local leaf and host; do not use tentative ports as confirmed assignments |
| weka66–69 | Earlier persistent profile and passing prechecks | Reboot validation not in latest batch; obtain current evidence if required |
| Physical underlay exceptions | Dated issue register lists down/intermittent links | Inspect both ends and serials; fresh link/BGP snapshot required before closing |
| Boot warnings | Accepted during deployment, not resolved by acceptance | Review current-boot units and journal with Matt |
| Switch clock differences | Backup timestamps differed across switches | Check time/NTP and record corrected time state |
| Exact host RoCE scripts | CLOSED: tested payloads and persistence collected from weka61, commit 1c95746 | Use packages/host-roce-reference; retain provenance |
| Cross-leaf test completion | 5/12 directed results supplied | Finish resumed run; add summary, server evidence and counter deltas |
| Cross-leaf log collection | weka68 → weka40 bandwidth passed; SSH retrieval failed | Retain warning; collect remote server logs if available |
| Congestion and failover | Not tested | Define a controlled test and acceptance criteria; observe ECN/PFC/discard deltas and recovery |
| WEKA application tests | No application throughput result in this rollout | Confirm cluster health from backend/management host, then test application I/O |
| 80-backend expansion / leaf-05 | Outside current confirmed deployment | Inventory hosts/ports and approve separate addressing/routing plan |

The original physical issue register is retained in `archive/maps/` as dated
evidence. Some statuses may have changed; do not automatically carry them forward
as a fresh assertion. Snapshot counts observed during RoCE apply were spines
31/31/30/29 and leaves 26/32/31/32 established peers; these were preservation
baselines, not full expected-link counts or a new survey.

Continue with Matt on client/boot issues and DC Ops on cable inspection. No
issue was sent to another person automatically by this repository preparation.
