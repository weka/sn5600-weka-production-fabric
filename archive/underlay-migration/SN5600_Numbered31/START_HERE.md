# SN5600 /31 migration + lossless RoCE — Cumulus Linux 5.11.5

Prepared September 28, 2026 for the existing eight-switch fabric. This bundle changes the routed leaf–spine links from BGP unnumbered to IPv4 numbered eBGP, using the exact /31 assignments in `SN5600_Port_Mapping_31.xlsx` and `SN5600_Fabric_31_Address_Plan.json`.

**Run this in a maintenance window. Selected BGP sessions reset during conversion. Adding interface addresses can also cause interface/routing updates. A staged rollout limits the affected paths but is not a hitless guarantee.**

The files are migration deltas for your already configured switches, not factory-default configurations. The scripts stop on a different OS, device identity, incompatible addressing or neighbor policy, or pending NVUE changes. They have been checked against NVIDIA's 5.11 documentation and tested locally with simulated NVUE state; they have not been executed on the switches.

## Scope and addressing

| Switch | Management address | Existing loopback / router ID | Existing ASN | Fabric ports |
|---|---|---|---|---|
| spine-01 | 172.31.17.5/20 | 10.255.0.104/32 | 65200 | swp1–32 |
| spine-02 | 172.31.17.18/21 | 10.255.0.101/32 | 65200 | swp1–32 |
| spine-03 | 172.31.17.20/21 | 10.255.0.102/32 | 65200 | swp1–32 |
| spine-04 | 172.31.17.22/21 | 10.255.0.103/32 | 65200 | swp1–32 |
| leaf-01 | 172.31.17.19/21 | 10.255.0.11/32 | 65101 | swp33–64 |
| leaf-02 | 172.31.17.21/21 | 10.255.0.12/32 | 65102 | swp33–64 |
| leaf-03 | 172.31.17.23/21 | 10.255.0.13/32 | 65103 | swp33–64 |
| leaf-04 (SR8 fiber) | 172.31.17.24/21 | 10.255.0.14/32 | 65104 | swp33–64 |

128 independent links use 128 /31 subnets in **10.254.0.0/24**. The spine gets the even address; the leaf gets the odd address. Each endpoint's exact port, local address, peer address and peer ASN is in `plan.json` and its switch's `_commands.txt` file.

The /31 pool must be reserved for this fabric. The preflight detects local address/main-route overlap; it cannot check another system's IPAM or disconnected equipment.

| Leaf ports | Spine | Spine ports by leaf |
|---|---|---|
| swp33–40 | spine-01 (.5) | Leaf-01: 1–8; Leaf-02: 9–16; Leaf-03: 17–24; Leaf-04: 25–32 |
| swp41–48 | spine-02 (.18) | Same blocks |
| swp49–56 | spine-03 (.20) | Same blocks |
| swp57–64 | spine-04 (.22) | Same blocks |

Management addresses, management gateway/VRF, hostnames, loopbacks, ASNs, ECMP limit 64, native 800G settings, MTU 9216, and the existing loopback network advertisements are retained. No connected-route redistribution is added. IPv6/RA settings remain present to support unnumbered peers during migration and rollback. This bundle does not change link speed, autonegotiation or FEC.

**172.31.17.3 / Leaf-05 is excluded.** No SSH connection or configuration command targets it. Spine swp33–40 addressing and their existing deferred unnumbered neighbors remain unchanged. The new optional RoCE action is switch-wide, so its global QoS policy also affects reserved and host-facing data ports; it does not enable their links or configure the deferred Leaf-05. The reserved future pool 10.254.1.0/26 is not assigned.

## Update contents (revision 2)

This revision adds lossless RoCE to the existing /31 migration package. The numbered addressing plan and migration engine are unchanged, so earlier migration backups remain usable. See **ROCE.md** for the new configuration, checks, rollback and host requirements.

**If /31 migration is already finished:** extract this update into a fresh folder, copy it to all eight switches, run `bash fabric.sh validate`, then follow the RoCE steps below. Do not repeat the addresses/migrate stages. If migration is incomplete, finish the remaining spine groups first.

To avoid mixing older local files, extract in a new Mac folder:

```bash
mkdir -p "$HOME/Downloads/SN5600_31_RoCE_Update"
unzip -o "$HOME/Downloads/SN5600_Numbered31.zip" -d "$HOME/Downloads/SN5600_31_RoCE_Update"
cd "$HOME/Downloads/SN5600_31_RoCE_Update/SN5600_Numbered31"
bash fabric.sh copy
```

After the /31 migration and fabric validation:

```bash
bash fabric.sh roce-check
bash fabric.sh roce-apply
bash fabric.sh roce-validate
```

The RoCE runner applies one switch at a time and checks QoS and routing before proceeding. It stops on a failure. Global QoS buffer changes can briefly disrupt forwarding; use a maintenance window. A switch QoS pass does not validate host RDMA configuration or congestion behavior.

## 1. Initial migration: extract and copy — run on the Mac

```bash
cd "$HOME/Downloads"
unzip SN5600_Numbered31.zip
cd SN5600_Numbered31
bash fabric.sh copy
bash fabric.sh check
```

The copy command verifies SHA-256 hashes before copying the folder to `/home/cumulus/SN5600_Numbered31` on the eight switches. It does not apply anything. Enter your SSH/sudo passwords when prompted. Host key checking remains enabled.

`check` is read-only. A pending configuration makes it stop: inspect `nv config diff` on that switch, then deliberately apply your changes or use `nv config detach` to set them aside. Do not discard other work blindly. Run one configuration operation at a time; avoid concurrent edits by other operators.

## 2. Add /31 addresses on all eight switches

```bash
bash fabric.sh addresses
```

This first checks all eight switches, then adds 32 addresses per switch and applies/saves them. The existing BGP neighbor definitions stay in place. A private baseline is saved on each switch under `~/sn5600-numbered31-state/<hostname>/`; it includes NVUE YAML, FRR state, and the ports that had established BGP sessions. Keep this directory for rollback and comparison.

If this stage fails partway through, inspect the failed switch's `nv config diff`. Once resolved, rerun the addresses stage; already assigned planned addresses are accepted. **Finish the addresses stage on all eight before migrating BGP.**

## 3. Migrate one spine group at a time

Run each command separately. Review its results before running the next.

```bash
bash fabric.sh migrate spine-01
```

Then, after this group's checks pass or report only the baseline degradation:

```bash
bash fabric.sh migrate spine-02
```

```bash
bash fabric.sh migrate spine-03
```

```bash
bash fabric.sh migrate spine-04
```

For each group the runner:

1. Checks the spine and all four leaves.
2. Tests the directly connected /31 peer with 9000-byte IPv4 packets on each active link, from both endpoints. A failed active-link probe stops before any BGP changes.
3. Replaces that spine's 32 active unnumbered neighbors with IPv4 neighbors, then replaces only its eight neighbors on each leaf. Other spine groups stay configured as they were.
4. Applies and saves each switch's change, waits 15 seconds, then checks numbered BGP, ASNs, remote router IDs, 800G/MTU 9216 link state and loopback pings.

If BGP is still converging, recheck without making changes:

```bash
bash fabric.sh validate spine-01
```

Use the relevant spine name. A new loss compared with the saved BGP baseline, zero established sessions to a selected remote switch, a speed/MTU mismatch on an established session, or failed loopback probes returns failure. **Do not advance to another spine while these checks fail.** There is no automatic rollback or reboot.

## Existing missing links

The last uploaded LLDP run, September 28 at 09:32 PDT, showed 119/128 reciprocal 800G pairs. It was an LLDP snapshot, not a current BGP count. Seven absent pairs were on Leaf-01 and two on Leaf-03:

| Leaf | Leaf port | Spine | Spine port |
|---|---|---|---|
| leaf-01 (.19) | swp33 | spine-01 (.5) | swp1 |
| leaf-01 (.19) | swp41 | spine-02 (.18) | swp1 |
| leaf-01 (.19) | swp44 | spine-02 (.18) | swp4 |
| leaf-01 (.19) | swp49 | spine-03 (.20) | swp1 |
| leaf-01 (.19) | swp52 | spine-03 (.20) | swp4 |
| leaf-01 (.19) | swp58 | spine-04 (.22) | swp2 |
| leaf-01 (.19) | swp61 | spine-04 (.22) | swp5 |
| leaf-03 (.23) | swp61 | spine-04 (.22) | swp21 |
| leaf-03 (.23) | swp64 | spine-04 (.22) | swp24 |

All these links receive their planned configuration so they can establish after the physical issue is resolved. Validation always lists missing peers. `DEGRADED, no additional BGP losses` can return success for sequencing when no baseline sessions were lost and the other checks pass; this **does not mean the fabric is fully healthy**. The /31 conversion will not repair a down physical link. Target full state is 32 established active-fabric peers on every switch.

## 4. Final verification

```bash
bash fabric.sh validate
```

On a leaf, for example Leaf-04:

```bash
sudo vtysh -c 'show bgp ipv4 unicast summary'
sudo vtysh -c 'show ip route 10.255.0.11/32'
ip -4 route show table main 10.255.0.11/32
ip nexthop show
nv show interface --view lldp
nv show system health
systemctl --failed --no-pager
nv config diff
```

The active fabric neighbors should now be `10.254.0.x` addresses. Reserved spine swp33–40 may remain Idle because Leaf-05 is deferred. Routes to other leaf loopbacks should use IPv4 next hops; the actual ECMP count depends on working links. Check FEC/error-counter changes and hardware forwarding with traffic before declaring the fabric ready. Loopback pings do not exercise every ECMP path or prove sustained throughput.

## Apply on an individual switch instead

Each switch has a wrapper such as `leaf-01.sh`, plus an explicit `_commands.txt` reference. The wrapper uses `migrate.py` and `plan.json` from the same directory.

```bash
cd /home/cumulus/SN5600_Numbered31
bash leaf-01.sh check
bash leaf-01.sh addresses
nv config diff
nv config apply && nv config save
```

After addresses are applied on all eight switches:

```bash
bash leaf-01.sh probe spine-01
bash leaf-01.sh bgp spine-01
nv config diff
nv config apply && nv config save
```

Without `--apply`, a mutation command stages only. After staging, apply manually as above; do not rerun the script with `--apply` while a candidate exists. With `--apply`, it stages, shows the diff, applies and saves. Complete the same spine group on its spine and all four leaves before validation. Prefer the Mac runner to keep the order consistent.

## Roll back a group

Restore the original unnumbered peers on the affected spine and all four leaves:

```bash
bash fabric.sh rollback spine-01
```

Use the actual group. This removes its numbered BGP neighbors and restores the exact saved unnumbered neighbor attributes. /31 interface addresses remain in place. Other spine groups and unrelated settings are unchanged. If an apply failed with a pending candidate, inspect it and use `nv config detach` before rollback.

For a complete rollback, roll back every migrated spine group in reverse order. Once the original unnumbered sessions have been validated, remove only addresses that this migration added. On each switch, use its own wrapper:

```bash
cd /home/cumulus/SN5600_Numbered31
bash leaf-01.sh remove-addresses --apply
```

Repeat for the other seven switches, using the corresponding script. This refuses to remove addresses while a planned numbered neighbor still exists locally. Then run `bash fabric.sh validate-unnumbered` from the Mac. Do not delete or replace the saved baseline during the migration.

## Sources and local checks

- [NVIDIA Cumulus Linux 5.11 — Basic BGP configuration](https://docs.nvidia.com/networking-ethernet-software/cumulus-linux-511/Layer-3/Border-Gateway-Protocol-BGP/Basic-BGP-Configuration/)
- [NVIDIA Cumulus Linux 5.11 — NVUE CLI, patch/apply/save](https://docs.nvidia.com/networking-ethernet-software/cumulus-linux-511/System-Configuration/NVIDIA-User-Experience-NVUE/NVUE-CLI/)
- [NVIDIA Cumulus Linux 5.11 — Static routing /31 interface examples](https://docs.nvidia.com/networking-ethernet-software/cumulus-linux-511/Layer-3/Routing/Static-Routing/)
- Address source: `SN5600_Fabric_31_Address_Plan.json`, existing /31 worksheet; current hostnames and unchanged router IDs.
- Local checks: unique 128 /31 networks and 256 endpoints; reciprocal peer/port addresses; all eight switch migrations and rollback; preserving management, global BGP, other spine groups and deferred neighbors; rejecting pending changes, unexpected neighbor policy and unsafe address removal. Shell/Python syntax checked. Simulated checks do not validate NVUE execution on hardware.

## 5. Add lossless RoCE after /31 routing validates

Read `ROCE.md`, then run `bash fabric.sh roce-check`, `bash fabric.sh roce-apply`, and `bash fabric.sh roce-validate` on the Mac. This enables standard PFC/ECN with DSCP trust and automatic buffer thresholds. Native 800G uses ECMP; adaptive routing is not enabled. Custom PFC buffer values and the example's 90/10 pool split are not imported.

The additions are the same on all eight switches. Each switch's `_commands.txt` ends with the RoCE delta, and its `.sh` wrapper accepts `roce-check`, `roce-enable`, `roce-validate`, and `roce-rollback`.
