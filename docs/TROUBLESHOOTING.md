# Troubleshooting from observed cases

| Symptom | What the evidence showed | Next step |
|---|---|---|
| BMC ping fails but HTTPS 443 succeeds | weka73 BMC was reachable by HTTPS | Check service access; do not infer BMC outage from ICMP alone |
| No ARP entry from workstation | Routed management networks need not create an endpoint ARP entry locally | Check route and TCP reachability, not just ARP |
| OS ping/SSH fails, BMC responds | weka78 remained OS-unreachable | Use BMC console to inspect OS/network state |
| Conversion scan says no RDMA devices | weka64 remained reachable over SSH | Inspect PCI devices, driver and firmware discovery; do not mark conversion successful |
| `master` falsely reported on standalone port | Broken shell test treated an absent sysfs link as a master | Check `-L /sys/class/net/PORT/master`; corrected client package includes this |
| Underlay check says only loopback network expected | Migration-era preflight conflicts with subsequently added client networks | Use current snapshot; never remove valid client advertisements to pass stale check |
| Cross-leaf ping bound to interface fails | Source-IP probe succeeded with existing BGP routes | Bind to mapped source IP and inspect policy route selection |
| `sysctl: command not found` on switch | Utility not in that shell’s PATH | Use the installed absolute path or read the relevant /proc/sys entry |
| Netplan warns `gateway4` deprecated | Datapath apply/validation succeeded; warning may come from another YAML | Inspect full Netplan files; modernize the correct file separately |
| Deployment says precheck missing/not executable | File existed but executable bit absent | Verify exact file, then chmod u+x; do not silently substitute scripts |
| Precheck rejects `--tos` | The precheck expects `--expected-tos` | Use the distinct deploy/precheck options |
| Warning-only precheck stops batch | Exit code 1 with zero FAIL and READY AFTER WARNING REVIEW | Accept only that explicit condition; keep warnings recorded |
| `ib_write_bw --help` check stops with no useful message | `grep -q` plus pipefail can produce producer SIGPIPE | Fully capture help output first; fixed runner does so |
| Benchmark succeeds but summary says failed | SSH closed during server log collection | Check both client exit codes, distinguish log-collection warning, resume only missing directions |
| Reboot runner appears idle at waiting for SSH | Polls TCP port for up to five minutes | Check OS/BMC reachability; let timeout be recorded rather than reboot again blindly |

## Physical uplink work

Capture `nv show interface PORT link`, `sudo l1-show PORT`, `sudo ethtool -m PORT`
and `sudo ethtool -S PORT` at both ends. Record serials and expected physical
pair. A module ready status does not prove a working link. `No issue was observed`
while link down is not a health pass. Do not diagnose from lane eye values alone;
consider explicit troubleshooting status and before/after physical/FEC counters.

Most inspected missing uplinks were 3m AXIOM passive copper DACs, part
MCP4Y10-N003-AX. spine-02 swp1 reported cable unplugged. leaf-01 swp41 had
an unusual part-number read. Serial AXMPOSPA01682 appeared at leaf-01 swp41 and
spine-01 swp1, inconsistent with the intended mapping (spine-02 swp1). This is
evidence to investigate a wrong patch, not proof of the final physical path.
Serial AXMPOSPA01674 at leaf-01 swp33 was not found in the scanned spine swp1–32
ports. Inspect both endpoints and unused/deferred ports before declaring it absent.

## Boot warnings

networkd-wait-online timeouts were recorded in prior boots; later pilot checks
showed no current-boot timeout on weka62. A broad boot-warning grep counts many
lines without classifying them. Review timestamps, actual failed units and the
affected interface before disabling a service or suppressing the warning.
