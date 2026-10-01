# Current status — September 30, 2026

This is an evidence snapshot, not an automatic live status page.

## Completed

- Numbered /31 leaf–spine eBGP underlay configured; all four client leaves have mapped server /31s and their BGP network advertisements.
- Four spines and leaf-01 through leaf-04 have standard lossless RoCE enabled, applied and saved. Before/after established peer sets were checked during QoS rollout; this preserved the observed baseline, not a guarantee that all 128 links are up.
- 34 clients have RoCE configured. Client profile uses DSCP trust, PFC only on priority 3, traffic class 106 and persistent service configuration.
- Pilots weka60, weka61 and weka62 passed reboot and bandwidth checks. The latest 27-client reboot batch passed all checks, with zero failures.
- Client link /31s, source policy routes, MTU 9000 and peer jumbo probes survived reboot on the validated hosts.
- Four leaf client endpoint checks passed apart from weka44 link1, which was explicitly skipped as known down.

## Reboot evidence

Latest 27: weka40–43, weka45–47, weka49–58, weka63, weka65, weka70–77.
The report was `RoCE_Reboot_Validate_20260930_155247`; the operator supplied
the final 27-row success summary. Full per-host post-reboot logs were not uploaded.

Pilot three: weka60–62. Total confirmed reboot checks: **30**.
weka66–69 already had the profile and passed prechecks, but were excluded from
the new deployment/reboot batch. Their persistence should not be counted as
newly reboot-tested from this evidence.

## Bandwidth evidence

Same-leaf 400G endpoints delivered approximately 392 Gb/s per NIC, with both
NICs running concurrently at approximately 784 Gb/s combined.
Cross-leaf tests involving weka68 used its 200G NICs and delivered approximately
195–196 Gb/s per NIC. These are RDMA payload measurements, not Ethernet link rates.

Only five of twelve directed cross-leaf tests have been supplied. In the fifth,
both client benchmarks returned zero, but SSH closed during server-log retrieval.
The original runner called that `FAILED`; the repository records the successful
client result with a separate evidence-collection warning. SSH subsequently
returned and weka40 uptime showed no reboot. The resumed run is still awaiting results.

## Not established

Do not claim every ECMP uplink, all clients, all backends, lossless operation
under congestion, failover or WEKA application performance has been validated.
NIC counter snapshots were collected by the bandwidth runner, but the newest
before/after files have not been supplied. Earlier same-leaf counters were zero;
zero pause or ECN counts during uncongested tests do not test congestion response.
