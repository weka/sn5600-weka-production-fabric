# Operations and command index

Run workstation commands from the repository root. Host commands run through
SSH as root on the selected server. Switch commands use cumulus and sudo where
required. Every command below identifies whether it reads state or changes it.

## Read-only entry points

```bash
bash run_checks.sh verify
bash run_checks.sh all-switches
bash run_checks.sh leaf-end-to-end leaf-02
bash run_checks.sh server-validate weka60
HOSTS="60 61 62" bash scripts/cx7_convert_ib_to_eth_reboot.sh --validate
```

Client package checks execute remote per-host scripts. If a script is missing,
the explicit package copy operation is needed first; that copies files but does
not apply configuration:

```bash
cd packages/SN5600_Client31_Rollout_20260929
bash fabric.sh copy-switches leaf-02
bash fabric.sh copy-servers weka60
```

## Historical /31 client deployment sequence — changes configuration

Only use for an approved, mapped host needing deployment. This was already
completed on the in-scope hosts. Check current state before reapplying.

```bash
cd packages/SN5600_Client31_Rollout_20260929
bash fabric.sh switch-check leaf-02
bash fabric.sh switch-stage leaf-02
# Review diff on the leaf before applying:
ssh -t cumulus@172.31.17.21 'nv config diff'
ssh -t cumulus@172.31.17.21 'nv config apply --assume-yes && nv config save'
bash fabric.sh switch-validate leaf-02
bash fabric.sh server-check weka60
bash fabric.sh server-stage weka60
# Review the candidate before this change:
bash fabric.sh server-apply weka60
bash fabric.sh server-validate weka60
bash fabric.sh switch-end-to-end leaf-02
```

Switch/client package scripts have per-host MAC and address checks, backups and
staging. The server backup path is `/root/sn5600-client31-state/<host>`.
Server-apply replaces `/etc/netplan/70-datapath.yaml`, generates and applies
Netplan. Other Netplan files can merge with it; inspect the full effective
configuration before troubleshooting management or stale routes.

## Ethernet conversion — firmware change and possible reboot

```bash
HOSTS="SELECTED_HOST_NUMBER" bash scripts/cx7_convert_ib_to_eth_reboot.sh --check
HOSTS="SELECTED_HOST_NUMBER" bash scripts/cx7_convert_ib_to_eth_reboot.sh --apply
HOSTS="SELECTED_HOST_NUMBER" bash scripts/cx7_convert_ib_to_eth_reboot.sh --validate
```

The conversion script requires a typed confirmation for apply. A no-RDMA-devices
error is not proof the host is down and is not a conversion success. Separate
OS reachability, PCI inventory, driver discovery and firmware port mode.

## RoCE deployment and reboot runners

`scripts/roce_client_batch_deploy.sh` is the exact dated 26-host resume wrapper
used after weka40. It fetches the tested scripts from weka61 and changes host
configuration. Its hardcoded host selection describes that completed batch;
do not call it a generic next-host deployer.

`scripts/roce_client_reboot_validate.sh` reboots the dated 27-host selection
including weka40. It first preflights all 27, queues reboots and checks the
changed boot IDs. Do not rerun its default mode as a routine check.

```bash
# Re-check an existing reboot report without another reboot:
bash scripts/roce_client_reboot_validate.sh --validate "$HOME/Downloads/RoCE_Reboot_Validate_RUN"

# Benchmark and generate heatmap; bounded test traffic, no config changes:
bash scripts/roce_cross_leaf_test.sh
bash scripts/roce_cross_leaf_test.sh --resume "$HOME/Downloads/RoCE_Cross_Leaf_RUN"
```

## Store new evidence

Reports default to `~/Downloads`. Before adding logs to Git, remove credentials
and personal information, retain commands/metrics needed to interpret the test,
and update `docs/CURRENT_STATUS.md`, `inventory/client-status.csv` and issue records.
Do not commit BMC credentials, private keys, tokens or environment files.
Run `python3 scripts/validate_repository.py`, then `bash scripts/update_checksums.sh`
after approved file changes. GitHub CI only performs local checks.


## Collect current client state and existing reports — no device changes

```bash
python3 scripts/collect_server_snapshots.py
python3 scripts/import_local_reports.py
```

The default client inventory covers weka40–79, including deferred hosts; failures
are recorded and do not mean a configuration was applied. Use --hosts "60 61"
for a smaller read-only collection. If SSHPASS is supplied locally, sshpass is
used; otherwise SSH prompts interactively. Never put its value in Git.

Switch collectors in scripts/ preserve tonight's collection method. They capture
state without applying it. The dated sanitizer is specifically for the original
20261001T044650Z snapshot; do not run it on another timestamp as a generic tool.
See [collection](COLLECTION.md) for evidence review and publication.
