# Reproducibility, gaps and provenance

The repository combines supplied session logs, corrected maps and the available
project artifacts. It is not a complete export of live device configurations.
The exact tested host deployment/precheck payloads and six persistence components were collected from weka61 and committed as 1c95746. Sanitized snapshots from all nine switches were committed as 1a77fd2. Full runtime report coverage must be checked against the local-report import manifest and server capture summaries; missing files remain gaps rather than fabricated evidence.

Original handovers and editable drawings are archived intact. They predate the
latest RoCE progress; current Markdown status and inventory take precedence.
The underlay migration archive is retained to explain the build sequence and
backups, not as the routine current-state gate. Existing switch-local migration
baseline directories are not present here and should be collected separately.

Source session logs are redacted copies. `evidence/provenance.json` retains
original filenames and handling. The separately recorded reboot summary was
copied from operator-provided conversation output; it is not fabricated per-host
log evidence. Cross-leaf TSV is extracted from the supplied benchmark output.

No actual heatmap image is claimed complete while seven directions are missing.
The test runner creates a local HTML heatmap from its measured TSV and identifies
missing cells and collection warnings. Share it after reviewing final results.

The repository’s GitHub workflow performs only offline checks: shell/Python
syntax, inventory consistency, credential screening, Markdown links and checksums.
It has no production credentials and never applies settings, reboots or benchmarks.


The completion update adds collection helpers, recovery procedures and an
ownership checklist. Archives remain dated historical evidence; current Markdown
includes the latest operator-confirmed updates. No assignment to Matt/DC Ops was
sent or accepted through this repository. Do not treat proposed coordination as
an agreed owner or deadline.
