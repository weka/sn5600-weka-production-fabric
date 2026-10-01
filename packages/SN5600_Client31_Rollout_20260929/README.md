# SN5600 client /31 rollout

Prepared September 29, 2026 for the confirmed local-rack cabling. This is a delta for the current Cumulus Linux 5.11.5 fabric. It does not change breakout configuration, link speed, leaf-spine addresses, leaf-spine BGP neighbors, or any port in `swp33-64`.

## Scope

- 35 ready clients, 70 server-facing links.
- Each client receives two routed /31 links:
  - link 1: leaf `10.200.N.0/31`, server `10.200.N.1/31`, policy table 100.
  - link 2: leaf `10.200.N.2/31`, server `10.200.N.3/31`, policy table 101.
- Every configured leaf advertises each directly connected /31 as an explicit IPv4-unicast BGP network.
- Server MTU is 9000; leaf MTU remains 9216. Existing RoCE QoS is retained, not rewritten by this package.
- Deferred and untouched: weka48, weka59, weka64, weka78 and weka79.

| Leaf | Management | Rack | Ready clients | Ready links |
|---|---|---|---:|---:|
| leaf-01 | 172.31.17.19 | Rack 1 | 10 | 20 |
| leaf-02 | 172.31.17.21 | Rack 2 | 7 | 14 |
| leaf-03 | 172.31.17.23 | Rack 3 | 10 | 20 |
| leaf-04 | 172.31.17.24 | Rack 4 | 8 | 16 |

Ready clients: weka40, weka41, weka42, weka43, weka44, weka45, weka46, weka47, weka49, weka50, weka51, weka52, weka53, weka54, weka55, weka56, weka57, weka58, weka60, weka61, weka62, weka63, weka65, weka66, weka67, weka68, weka69, weka70, weka71, weka72, weka73, weka74, weka75, weka76, weka77.

## Important preflight conditions

Run this in a maintenance window with console/BMC access available. Scripts stop for a wrong hostname, management IP, Cumulus version, switch model, NIC MAC, non-Ethernet NIC, duplicate Netplan interface definition, unexpected 10.200/16 switch address, or pending NVUE candidate.

The latest scan showed one known physical exception among the ready clients: **weka44 link 1, leaf-04 swp2s1, was down**. The leaf script permits this known baseline as degraded, but end-to-end validation will skip it until it links. Fix and revalidate it before production.

The tentative parents for deferred weka48 and weka59 are recorded only in the workbook/CSV. No script configures those ports.

## 1. Verify checksums and copy switch scripts

From the extracted package directory on the Mac:

```bash
shasum -a 256 -c SHA256SUMS
bash fabric.sh copy-switches
bash fabric.sh switch-check
```

Passwords are prompted. They are not stored in this package.

## 2. Stage and apply one leaf at a time

Start with leaf-04 or another leaf of your choice. Stage first and review the exact NVUE diff:

```bash
bash fabric.sh switch-stage leaf-04
```

Because staging leaves a candidate on that leaf, either apply it manually on the switch:

```bash
nv config diff
nv config apply --assume-yes
nv config save
```

or detach it and use the package's apply action:

```bash
nv config detach
bash fabric.sh switch-apply leaf-04
bash fabric.sh switch-validate leaf-04
```

Repeat for leaf-03, leaf-02 and leaf-01. Applying a leaf adds only the ready server-facing /31s and BGP network statements listed in the workbook.

## 3. Copy, check and apply one server first

```bash
bash fabric.sh copy-servers
bash fabric.sh server-check weka40
bash fabric.sh server-stage weka40
```

Review the candidate and diff printed by the stage. Then apply:

```bash
bash fabric.sh server-apply weka40
bash fabric.sh server-validate weka40
```

The server script validates both expected MAC addresses and Ethernet mode before changing Netplan. It backs up the entire `/etc/netplan` directory under `/root/sn5600-client31-state/<hostname>/` before replacement. It overwrites only `/etc/netplan/70-datapath.yaml`; management configuration must remain in a different Netplan file.

After the pilot succeeds, continue one server at a time or by leaf/rack. The orchestrator supports an individual hostname; `all` is available but a one-at-a-time apply is safer.

## 4. End-to-end validation

```bash
bash fabric.sh server-validate
bash fabric.sh switch-end-to-end
```

The checks confirm Ethernet mode, MAC identity, addresses, source-policy rules, tables 100/101, 9000-byte direct-peer probes, leaf interface/link state, and BGP network statements. Then verify fabric route propagation and RoCE separately:

```bash
# On a spine
sudo vtysh -c 'show bgp ipv4 unicast'

# On each leaf
nv show qos roce
nv show qos congestion-control
nv show interface --view lldp
nv show system health
systemctl --failed --no-pager
nv config diff
```

Use sustained RDMA traffic and interface/FEC/error counters before production. ICMP probes do not prove lossless RoCE behavior.

## Configuration references

- NVIDIA Cumulus Linux 5.11, Basic BGP Configuration: https://docs.nvidia.com/networking-ethernet-software/cumulus-linux-511/Layer-3/Border-Gateway-Protocol-BGP/Basic-BGP-Configuration/
- NVIDIA Cumulus Linux 5.11, Interface Configuration and Management: https://docs.nvidia.com/networking-ethernet-software/cumulus-linux-511/Layer-1-and-Switch-Ports/Interface-Configuration-and-Management/
- Netplan YAML reference for static routes and policy routing: https://netplan.readthedocs.io/en/1.1/netplan-yaml/

## Rollback

Leaf: run the leaf script with `--rollback-stage`, review `nv config diff`, then deliberately apply/save. This removes only the package's server-facing IP addresses and BGP network statements.

Server: each apply prints its backup archive. Restore from console/BMC if necessary:

```bash
bash /root/SN5600_Client31_Rollout_20260929/servers/weka40_client31.sh --restore /root/sn5600-client31-state/weka40/netplan-before-TIMESTAMP.tar.gz
```

Do not use a backup from another host. Do not configure the five deferred hosts until their port/NIC identity is rescanned and the mapping is updated.
