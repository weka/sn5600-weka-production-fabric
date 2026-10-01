# Internal operations material

Publish privately. Keep passwords, tokens, private keys and BMC credentials out
of files and Git history. Use SSH authentication configured by the operator.
Review imported backups and reports before staging them. `SSHPASS` is accepted
only as an environment variable for the bandwidth runner; no value is saved by
the runner. Avoid shell tracing while using a credential.

CI checks files without connecting to production. Do not add automatic apply or
reboot jobs to CI. Report operational problems internally with the relevant
timestamp and redacted evidence, rather than publishing private network details.
