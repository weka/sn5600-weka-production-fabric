# Future 76-backend deployment — draft, not deployed

This package is for 19 additional 2U, four-node chassis. Each node has one
dual-port CX-8, two 400G ports. Existing 40 clients remain in place.

| Rack | Leaf | Chassis | Backends | 400G links | Proposed 800G parent ports |
|---|---|---|---|---|---|
| 1 | leaf-01 | 4 | 16 | 32 | swp13–28 |
| 2 | leaf-02 | 5 | 20 | 40 | swp13–32 |
| 4 | leaf-03 | 5 | 20 | 40 | swp13–32 |
| 5 | leaf-04 | 5 | 20 | 40 | swp13–32 |

All proposed parents require verified compatible 2x400G breakout. They are
reservations, not confirmed free ports. Do not alter existing client ports or
swp33–64 spine uplinks. Both backend links on one leaf provide link paths but
not leaf-switch redundancy. Confirm adapter/cable part numbers, connector and
breakout support before buying cables. No generic breakout or firmware conversion
command is automatically applied by this package.

## Known and missing inventory

known-management.json records Orca EVT 6–20, 60 nodes with OS .109–.168 and
BMC .109–.168. Rack placement, actual hostnames, MACs, interface names, physical
chassis slots and CX-8 part numbers are not confirmed. Four chassis/16 addresses
remain unknown. plan.json contains 76 logical backend IDs; none is an asserted
hostname or assigned management IP. Populate it from actual inventory.

## Proposed /31 addressing

BE001 provisionally reserves 10.200.128.1/31 and .3/31 with leaf peers .0 and .2.
BE076 reserves 10.200.203.1/31 and .3/31. Backend IDs are independent of management
IP last octets. Each backend's two /31s remain inside 10.200/16 so existing client
policy routes can reach them. Verify no other installed or reserved network uses
these addresses before approving any entry. Do not put backends in another /16
without changing and validating the client routing design.

## 1. Discover and complete the plan — read-only

```bash
cd packages/backend-expansion
python3 backendctl.py status
python3 backendctl.py scan
```

The scan covers only the 60 supplied OS addresses and records unreachable hosts.
It does not guess missing addresses or change the adapters. Confirm Ethernet mode,
exact dual-port RDMA mapping, 400G operation, firmware and cable support. Inspect
both ends/LLDP and current leaf configuration before assigning child ports.

Edit plan.json for a chosen logical ID: actual hostname, management/BMC IPs,
chassis/slot, rack/leaf, netdevs, lowercase MACs and confirmed leaf child ports.
Review all Netplan files, management interface exclusion, source-policy rules,
existing routing tables and the intended replacement of 70-datapath.yaml. Set
approved and the three verified flags true only after those reviews. Missing
values or duplicate addresses/ports stop generation. Approve one pilot first.

## 2. Generate and deploy the pilot /31s

```bash
python3 backendctl.py generate BE001
python3 backendctl.py switch-check leaf-01
python3 backendctl.py switch-stage leaf-01
# Inspect the printed NVUE diff and baseline BGP before applying:
python3 backendctl.py switch-apply leaf-01
python3 backendctl.py server-check BE001
python3 backendctl.py server-stage BE001
# Inspect candidate Netplan and all effective Netplan files:
python3 backendctl.py server-apply BE001
python3 backendctl.py server-validate BE001
python3 backendctl.py switch-validate leaf-01
python3 backendctl.py test BE001
```

Select the actual mapped leaf, not necessarily leaf-01. These are real mutations
in apply modes. server-stage validates candidate Netplan without applying it.
server-apply backs up all /etc/netplan then replaces 70-datapath.yaml. Missing
Ethernet/MAC/400G/preflight checks stop it; a candidate must still be reviewed.
No reboot occurs. The two mapped ports must not carry the management IP.
Switch stages require an empty candidate, preserve applied configuration backups,
and store candidate/applied hashes. Apply rejects changes since staging. Review
route/BGP output as well as endpoint probes; printed routes are not an automatic
all-fabric health pass. A failed apply requires investigation and console/backup
recovery, not blind retries. Re-generate after any plan edit.

## 3. Backend RoCE — use exact tested source package

```bash
python3 backendctl.py roce-stage BE001
python3 backendctl.py roce-apply BE001
python3 backendctl.py roce-validate BE001
```

roce-stage copies the collected precheck/deploy files to the selected backend and
runs a precheck. It does not stage switch QoS or change host QoS. The copied source
was collected/tested on clients; backend role support must be inspected and
piloted on this hardware. The intended backend profile uses role backend and TOS
96 (DSCP 24), PFC priority 3 and DSCP trust. Confirm WEKA/NVIDIA requirements for
the installed software/hardware before accepting that profile. Existing switches
already use the lossless profile; validate rather than blindly reapplying it.
Prechecks can return warnings/nonzero; review the summary. This wrapper does not
silently accept backend protection/alert/workload warnings. RoCE apply may affect
services; confirm cluster protection and workload state first.

## 4. Acceptance before production

- Both mapped ports: Ethernet, correct MAC and RDMA port, up at 400G, MTU 9000.
- Correct /31s, source rules/tables and local 9000-byte probes.
- Expected backend networks advertised across every intended leaf/spine.
- Client-to-backend and backend-to-backend source-bound jumbo probes in both directions.
- Pilot reboot persistence: changed boot ID, services/profile/routes/probes recovered.
- RoCE v2 GID inventory per device AND port; never assume GID index 3 or port 1.
- Same-leaf and cross-leaf ib_write_bw per port, concurrent ports, both directions;
  collect exit codes/server logs and before/after counters. Do not reuse the old
  client test runner unchanged: it assumes two RDMA devices with port 1.
- Controlled congestion/failover and WEKA health, protection and real I/O checks.
- Pilot accepted before remaining approved-host rollout; no readiness claim from generation alone.

Generic RDMA test template, after discovery on each selected endpoint:

```bash
# Run matching device/port/GID on the receiver first; choose an unused TCP port:
ib_write_bw -d DEVICE -i RDMA_PORT -x GID_INDEX --tclass 96 -F -D 30 --report_gbits -p 18620
# On the sender, with its own verified device/port/GID:
ib_write_bw -d DEVICE -i RDMA_PORT -x GID_INDEX --tclass 96 -F -D 30 --report_gbits -p 18620 RECEIVER_MGMT_IP
```

Verify available perftest options with ib_write_bw --help. The DEVICE/RDMA_PORT/
GID placeholders are intentional; they cannot be guessed before discovery.
The management IP exchanges parameters; displayed GIDs must identify intended
10.200 backend addresses. Record measurements and counters before updating status.
For recovery, use the main docs/RECOVERY.md and each host's printed backup path.
