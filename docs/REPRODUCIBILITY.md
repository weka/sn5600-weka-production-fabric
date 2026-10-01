# Reproducibility, gaps and provenance

The repository combines supplied session logs, corrected maps and the available
project artifacts. It is not a complete export of live device configurations.
The exact tested host deployment/precheck payloads and full latest reboot logs
remain on the hosts or the operator’s Mac. Reference collection is included so
the next operator can close that gap without reconstructing code from prose.

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
