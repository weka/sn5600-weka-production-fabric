# Evidence guide

`session-logs/` contains redacted dated terminal output. Older files may include
superseded role assignments, candidate configurations or failed attempts. They
are historical evidence, not instructions to run verbatim.

`reboot-summary-2026-09-30.tsv` is the 27-host final summary supplied by the
operator. It confirms the runner reported success; full individual logs are
not included. `cross-leaf-summary-2026-09-30.tsv` has the five supplied directed
RDMA results. Its collection-warning row has client exit codes 0/0 in the source
log, but missing server-log evidence. Seven cells remain unmeasured here.

Useful session sources:

- `Pasted_text_20260930-220854_.txt`: consolidated host inventory/prechecks.
- `Pasted_text_20260930-222956_.txt`: final leaf switch RoCE apply evidence.
- `Pasted_text_20260930-224503_.txt`: 26-host deployment final summary.
- `Pasted_text_20261001-014421_.txt`: first five cross-leaf bandwidth results;
  filename uses UTC, while the operator was on September 30 local time.

Update provenance and current status when new results arrive. Counter snapshots
should be compared as before/after deltas for the same interfaces and interval.
