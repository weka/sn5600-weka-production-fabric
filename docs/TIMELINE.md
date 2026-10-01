# Project timeline and decisions

| Stage | Work and resulting decision |
|---|---|
| Initial design / switch bring-up | Explored earlier lab and physical packages; current scope is the real physical production fabric. Use corrected identity inventory, not old filename assumptions. |
| Cumulus upgrade | Standardized on Cumulus 5.11.5; console/ONIE and management prerequisites documented in original handover. Do not reinstall working production devices as a validation step. |
| Cabling and identity scan | LLDP, adapter MACs and transceiver serials used to pair ports. Five-rack placement later clarified. |
| September 28 | Numbered underlay migration: 128 planned /31 links in 10.254.0.0/24, retaining switch identity, ASNs, loopbacks, management and native 800G link settings. |
| September 29 | Client scans, IB-to-Ethernet conversion and exact /31 client package; deferred hosts separated from confirmed links. |
| September 29–30 | Leaf/client stage, backup, apply and local jumbo validation; routed source-IP cross-leaf jumbo tests passed. |
| September 30 | Persistent RoCE pilots weka60–62; same-leaf dual-NIC RDMA around 784 Gb/s; precheck options/executable-bit and warning-exit problems corrected. |
| September 30 | Lossless QoS staged and applied on eight switches; baseline established BGP peer sets retained. FRR JSON parser corrected for top-level peers. |
| September 30 | weka40 plus 26 remaining clients deployed; 27-client reboot batch passed; total 30 clients have reboot evidence including pilots. |
| September 30 evening | Representative cross-leaf RDMA started; five directions succeeded around 390–392 Gb/s combined at weka68’s 2 × 200G limit. SSH collection failed once; resume/collection reporting fixed. Seven directions pending latest evidence. |

## Decisions to preserve

- Client and underlay pools are separate. A host number lives in the third octet
  of the client datapath, not as an overlapping series of adjacent /31 addresses.
- Two mapped client links each have a real leaf gateway and source policy table.
- Leaf client /31s are explicitly advertised in BGP; migration-era checks must
  tolerate those legitimate additional networks.
- Client defaults differ by NIC layout; exact MAC/netdev mapping is authoritative.
- 48U racks and 2U/four-client chassis are physical constraints; arbitrary U slots
  in a drawing are not a confirmed rack survey.
- TOS 106 is the deployed client profile. Backend profile and full backend
  rollout must be verified separately rather than inferred from client tests.
- No workload was running during authorized bulk work; future maintenance
  decisions must use current workload state.
