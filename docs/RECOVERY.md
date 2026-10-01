# Recovery guide for the next operator

Recovery changes production state. Begin with out-of-band access and a specific
failure; do not restore every device because a benchmark failed. This guide is a
review procedure, not an automatic rollback. Check current workloads, mounts and
cluster health before interruption. Keep management connectivity separate from
the 10.200 datapath and preserve current state before replacing anything.

## 1. Find the right backup

| Component | Backup location | Limitation |
|---|---|---|
| Client Netplan before /31 apply | /root/sn5600-client31-state/wekaN/netplan-before-TIMESTAMP.tar.gz | Inspect archive paths; includes dated pre-change files, not necessarily desired current state |
| Client RoCE deployment | /root/weka-roce-deployment-backup/TIMESTAMP/ | Review manifest and deployment-summary.txt; exact contents vary |
| Switch pre-RoCE configuration | /home/cumulus/sn5600-roce-manual-backup/ | Dated files can predate later changes; choose by timestamp and content |
| Switch current Git snapshot | configs/switches/20261001T044650Z/ | Sensitive lines removed; reference only, not a complete restore |
| Original switch exports on Mac | Downloads/SN5600_Private_Config_Backup_* | Private originals; keep access restricted and arrange approved team backup access |

The latest snapshot and a pre-change backup answer different questions. The
snapshot explains what was installed; a backup allows a targeted rollback.
Backups on the departing operator's laptop are not a durable team recovery plan.
Transfer private originals through the team's approved restricted storage and
record that location without recording credentials in Git.

## 2. A client loses datapath connectivity

Use BMC console if OS SSH is unavailable. If management SSH works, first record:

```bash
hostname
ip -br link
ip -4 -o address
ip -4 rule show
ip -4 route show table all
rdma link show
systemctl --failed --no-pager
```

Find that host's exact netdev/MAC pair in inventory/client-port-map.csv. Confirm
Ethernet mode, physical link and /31 peer. Check all /etc/netplan/*.yaml together;
Netplan merges files. Check route selection with both source and destination.
Use a source IP for routed pings, rather than binding the test to an interface.
Do not restore network settings to fix a physically down cable.

If the failure started immediately after a network change, inspect the selected
Netplan backup with `tar -tzf BACKUP.tar.gz`. Extract it to a separate working
directory, compare with the current files, and restore only the reviewed files.
Preserve management NIC configuration. Validate with `netplan generate` before
applying. Use console access and a supported `netplan try` session for a timed
rollback when applicable. Never replace every Netplan file blindly.

Verify after recovery: management SSH, both intended /31s, source policy rules,
route tables, MTU, source-bound local peer jumbo and cross-leaf jumbo tests.
Record the restored backup timestamp and results. A one-link host remains degraded.

## 3. RoCE service or WEKA agent does not start

```bash
systemctl status weka-roce.service weka-agent.service --no-pager
systemctl cat weka-roce.service weka-agent.service
journalctl -b -u weka-roce.service -u weka-agent.service --no-pager -n 150
cat /etc/weka-roce.conf
```

Compare installed components with the host's own backup and the tested reference
package. Reference files from weka61 contain that host's NIC selection; do not
copy its NIC list onto a dual-port client unchanged. Review competing RoCE sources
and sysctl precedence. A failed Requires dependency can keep the agent stopped;
read the RoCE failure before changing dependency ordering.

Restore only selected reviewed components, reload systemd if units changed, and
restart services only within an agreed maintenance period. Re-run the host
precheck with --expected-tos 106 and the host's correct NIC names. Zero failures
plus reviewed warnings is the acceptance condition; accepting a warning does not
resolve it. Check workload startup and, separately, post-reboot persistence.

## 4. A switch change breaks routing

Use console access or a working management connection. Record applied configuration,
pending diff, interfaces, BGP summary and routes before another change. Confirm
whether configuration was applied, saved, or only staged. Capture the established
peer set and expected physical neighbors; a retained peer count alone does not
identify which peers are present.

Select an unredacted reviewed backup matching the required known-good state.
Compare client /31 advertisements, underlay addresses, ASN, router ID, breakout,
VRF, MTU and RoCE settings. Replacing the whole configuration can undo later valid
client settings. Prefer a targeted correction where the error is isolated.
If a complete restore is necessary, consult the installed NVUE command help and
prepare a candidate from the reviewed backup, inspect its diff, then apply and
save only that approved change. Do not import sanitized Git exports as complete
restores or run archived migration scripts to bypass their preflight.

Verify management, port modes, LLDP, all expected BGP peers/routes, local endpoint
jumbo and selected cross-leaf paths. Test RDMA and record counters when restoring
QoS. Stop additional changes if the baseline does not recover.

## 5. A benchmark fails

Check source/destination GIDs, link speeds, both QP exit codes, timeouts and server
listener/log evidence. A log retrieval failure is an evidence collection warning
when the actual benchmark succeeded. Missing cells in the heatmap stay untested.
Check physical counters and compare before/after deltas, not totals alone.
An uncongested bandwidth pass does not validate congestion control or failover.

## 6. Close the incident

Record the trigger, device, original state, backup, exact change, verification,
remaining issues and rollback outcome. Update current status only from evidence.
Never put credentials or unredacted private originals into an incident commit.
