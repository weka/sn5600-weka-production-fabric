# RoCE configuration and tests

RoCE is RDMA over Ethernet. Firmware Ethernet mode, IP reachability, RoCE v2
GIDs and a consistent QoS profile are separate checks.

## Switch profile observed after apply

```bash
nv show qos roce
nv config diff
```

Applied standard profile: enabled; lossless mode; PFC RX and TX on priority 3;
trust PCP/DSCP; DSCP 24–31 maps to switch priority 3; that priority maps to
traffic class 3. ECN was shown on traffic classes 0 and 3. Priority 6 had strict
scheduling. Record current output instead of assuming a custom profile matches.

The commands used were `nv set qos roce` and `nv set qos roce mode lossless`,
then review `nv config diff`, apply and save. This was completed on all eight
in-scope switches. Do not repeat apply solely because an archived preflight stops.

## Host profile observed

- DSCP trust and PFC only on priority 3.
- Client traffic class/TOS 106: DSCP 26, ECN bits 2.
- TCP ECN value 1 for consistency with the deployed host script.
- weka-roce.service installed, enabled and active; WEKA agent starts after and
  requires the RoCE service in the deployed systemd drop-in.
- `/etc/weka-roce.conf` stores selected interfaces and TOS.

`net.ipv4.tcp_ecn` controls TCP ECN negotiation. Value 1 requests ECN on outgoing
TCP and accepts it on incoming TCP; value 2 accepts incoming requests without
requesting it on outgoing connections. This sysctl is not the RDMA NIC’s
congestion-control setting. A script’s TCP ECN check is a profile check,
not evidence of RDMA congestion behavior.

## Correct host commands

```bash
# Read-only precheck; note --expected-tos, not --tos:
/root/weka-roce-precheck.sh --role client \
  --nics ens4047np0,ens3919np0 --expected-tos 106

# Deployment changes configuration; only for a selected approved host:
/root/deploy-weka-roce.sh --role client \
  --nics ens4047np0,ens3919np0 --tos 106 --accept-warnings
```

The deployment script requires the precheck file to be executable. `chmod u+x`
resolved the earlier missing/not-executable error. The dual-port mapped hosts
use ens4047f0np0,ens4047f1np1 instead; consult the exact host map.

## Persistence and rollback evidence

Deployment backups are under `/root/weka-roce-deployment-backup/<timestamp>`.
Expected components include `/etc/weka-roce.conf`, the sysctl file,
RoCE startup/configuration scripts, systemd service and WEKA agent drop-in.
Collect the exact tested payloads and backups before changing them. Inspect the
backup and installed files to plan rollback; do not assume a generic restore
command is correct. Automatic rollback was not used during this rollout.

## Bandwidth runner

`scripts/roce_cross_leaf_test.sh` preflights four mapped clients, verifies
IPv4-mapped RoCE v2 GID index 3, then tests both NICs concurrently for 30 seconds
per directed pair. It sets `--tclass 106`, uses one QP per NIC and collects
before/after NIC counters. Management IPs are used for TCP parameter exchange;
the displayed GIDs identify the 10.200 RDMA data path.

```bash
bash scripts/roce_cross_leaf_test.sh
bash scripts/roce_cross_leaf_test.sh --resume "$HOME/Downloads/RoCE_Cross_Leaf_RUN"
```

Optional noninteractive passwords require sshpass and `SSHPASS` set locally.
Do not commit the password. Commands in this repository contain no credential.
Both QP exit codes must be zero. Server-log collection warnings are recorded
separately. `heatmap.html` uses a relative link-rate color scale, not a health
threshold. Missing measurements remain untested; do not fill them by symmetry.

The `Transport type: IB` label in verbs perftest does not mean the adapter is
in InfiniBand mode when `Link type: Ethernet` and the RoCE GIDs are confirmed.
An uncongested near-line-rate run does not prove PFC or ECN works under congestion.
