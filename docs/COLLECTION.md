# Collection and evidence workflow

The repository is a handover, not an automatic claim that everything is healthy.
Every collected file needs a source, timestamp and interpretation.

## Sources already uploaded

| Source | Location | Evidence |
|---|---|---|
| Original operations bundle scripts | packages/ and archive/underlay-migration/ | All 52 compared; root run_checks.sh intentionally updated |
| Exact host RoCE scripts/persistence | packages/host-roce-reference/ | Collected from weka61, commit 1c95746 |
| Nine switch snapshots | configs/switches/20261001T044650Z/ | Sanitized, commit 1a77fd2; leaf-05 identity confirmed |

## Server collection

Run python3 scripts/collect_server_snapshots.py from a Mac with client management
access. It covers weka40–79 by default. The collector gathers all Netplan YAMLs,
policy rules, route tables, Mellanox NIC/PCI/MAC/firmware mappings, RDMA links,
QoS, services and boot state. It performs no apply, reboot or benchmark.
Unavailable hosts and commands are retained in summaries; it does not declare
readiness. Use --hosts "60 61" to select a smaller read-only set.

The code redacts matching sensitive output lines before saving them to Git
folders. It does not collect BMC credentials or private keys. Review any unusual
files before publication; a pattern scan is not proof all secrets are absent.

## Local reports

Run python3 scripts/import_local_reports.py. Available RoCE reports, CX7 scans, post-reboot switch reports, selected cable diagnostics and the dated upgrade guide in Downloads are imported as text, excluding reference source payloads and binary archives. Private SN5600 backup folders and unrelated files are not imported. SHA-256 provenance and redaction counts are recorded. Original files
remain in Downloads. Imports do not overwrite the curated five-direction result
summary or automatically raise the validated reboot count.

Review the most recent complete run, including resume rows. For each directed
pair, both NIC exit codes must be zero, GIDs must identify the intended datapath,
and both rates must be present. Preserve server-log collection warnings. Review
before/after NIC counters and preserve missing data. A generated heatmap is
shareable only with its run timestamp, scope and remaining warnings identified.

## Remaining acceptance work

- Latest complete twelve-direction cross-leaf evidence review.
- All intended uplinks, not only a representative ECMP-selected path.
- Controlled congestion with ECN/PFC/discard deltas.
- Controlled link/peer failover and recovery.
- WEKA cluster health and real application I/O.
- Deferred/missing client inventory and backend expansion.

The completion package captures files for these reviews; it does not execute
congestion, failover, application load or expansion changes.
