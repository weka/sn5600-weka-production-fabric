# Beginner handover

## 1. What was built

This is a physical Ethernet network connecting WEKA clients through local leaf
switches and a shared spine layer. Every active leaf has routes to the other
leaves through the spines. Clients have two mapped Ethernet datapath interfaces
with separate /31 links and source policy routes. RoCE enables their NICs to
perform RDMA transfers over those Ethernet links.

A leaf is the switch nearest the servers. A spine connects the leaves.
BGP is the protocol used by switches to exchange routes. ECMP lets routing
choose among multiple equal-cost established uplinks. A missing cable can
reduce the number of available paths even when a representative test succeeds.

## 2. Three kinds of access

Use the OS IP to SSH to a client. Use its BMC IP for out-of-band power and
console access when the OS is unavailable. Use a switch management IP to SSH
to Cumulus. Datapath addresses beginning 10.200 are used for client traffic;
10.254 is the leaf–spine underlay. Do not change management routes while fixing
a datapath problem unless evidence specifically identifies that as the cause.

## 3. Locate the equipment

Read [topology](TOPOLOGY.md), then find the host in
`inventory/client-port-map.csv`. It gives the server netdev, MAC address, leaf,
breakout child port, local /31 and gateway. Confirm the physical pair using
LLDP and MACs rather than relying on a handwritten cable label alone.
Racks are 48U; each 2U Supermicro chassis contains four clients. Rack positions
in drawings are references where exact as-installed U coordinates are unverified.

## 4. Understand the sequence already completed

1. Discover actual switch identity and ports; correct earlier role-map assumptions.
2. Upgrade/standardize Cumulus to 5.11.5 and establish the physical fabric.
3. Build the exact port map and convert routed underlay links to numbered /31 eBGP.
4. Scan clients, convert applicable adapter firmware ports from IB to Ethernet and reboot changed hosts.
5. Confirm LLDP/MAC pairs; stage leaf IPs and advertise client /31s with BGP.
6. Stage client Netplan, back up old configuration, apply and validate local jumbo probes.
7. Test source-IP routed jumbo connectivity across the fabric.
8. Apply lossless switch QoS and a consistent persistent host RoCE profile.
9. Reboot selected clients and check boot ID, services, link state, /31s, routes and jumbo pings.
10. Run same-leaf RDMA, then representative cross-leaf tests.

Steps 1–9 have evidence within the stated scope. Step 10 is partially complete.
The running cross-leaf test must be incorporated when its final results arrive.
Do not restart the project from step 1 on already configured production devices.

## 5. What a good client check looks like

The two mapped ports should show Ethernet RDMA link ACTIVE, expected link speed,
MTU 9000, correct /31s and policy routes. Precheck should show zero failures,
with any warnings read and recorded. The RoCE service should be enabled and
active; WEKA agent should be active. Probe the local leaf gateway using the
source IP and a 9000-byte IP packet. Then probe a mapped client on another leaf.

For a post-reboot claim, the boot ID must change. The reboot runner checks that
explicitly; merely receiving ping replies does not establish persistence.
weka44 link1 is a known physical exception, not a full pass.

## 6. What a good switch check looks like

Confirm hostname and management address, link state/speed/MTU, configured
addresses, BGP peers/routes and applied RoCE profile. `nv config diff` should
be empty unless an operator deliberately staged work. A baseline BGP check
asks whether previously established peers survived a change. An all-path check
asks whether every planned peer is currently established. They are different.

The older underlay migration `check` expected only the original loopback BGP
network. Once client /31 networks were added, that assumption became stale.
Its refusal does not justify removing the client networks. Use the current
read-only snapshot and compare against the maps and dated issue register.

## 7. Routine working practice

Begin with status and issue records. Collect a read-only snapshot. Choose one
specific failed host, cable pair or service, capture both ends, then change only
what the evidence supports. Preserve backups. Re-check the same failing test.
Record a result with timestamp, source/destination, exact command, result and
remaining limitation. Keep planned, observed and validated state distinct.

No workload was running when the operator authorized the bulk deployment and
reboots. That is historical authorization for that maintenance period, not a
permanent assumption for the next operator. Check mounts and workload status
again before making changes or rebooting.

## 8. Where to continue

Finish the seven outstanding cross-leaf directions; review physical counters;
validate weka66–69 persistence if needed; repair/defer the client and uplink
exceptions with Matt/DC Ops; then design controlled congestion/failover tests
and perform WEKA application I/O testing. Backend expansion needs its own
confirmed inventory and plan. See [open issues](OPEN_ISSUES.md).
