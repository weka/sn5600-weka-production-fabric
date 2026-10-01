# Script index

| Script | Effect | Scope |
|---|---|---|
| check_fabric.sh | Read-only state capture | Eight switches |
| collect_roce_reference.sh | Copies host files to workstation | weka61; no host config change |
| cx7_ready_server_inventory.sh | Inventory scan | Read script/host selection first |
| cx7_convert_ib_to_eth_reboot.sh | Check/validate read-only; apply changes firmware and can reboot | Explicit HOSTS recommended |
| roce_client_batch_deploy.sh | Changes host QoS/persistence, no reboot | Completed 26-host resume batch |
| roce_client_reboot_validate.sh | Default reboots; --validate only checks | Completed 27-host selection |
| roce_cross_leaf_test.sh | Bounded RDMA traffic; no settings change | Four representative clients, 12 directions |
| validate_repository.py | Offline checks | Local repository |
| update_checksums.sh | Regenerates integrity records | Local repository |
| publish_github.sh | Creates a private GitHub repo and pushes local files | Explicit owner/repo argument |

Do not use deployment/reboot wrappers as daily health checks. They encode the
maintenance selections used in this rollout. They are preserved for reproducibility.


## Completion helpers

| Script | Effect |
|---|---|
| collect_switch_configs.sh | Read-only switch capture; credential screening; Git push after successful collection |
| sanitize_upload_switch_snapshots.sh | Sanitizes the specific dated switch snapshot; backs up originals outside Git; commits and pushes |
| collect_server_snapshots.py | Read-only collection of 40 clients; sanitizes before saving; records unreachable hosts and unavailable commands |
| import_local_reports.py | Imports available RoCE report text from Downloads; redacts matching sensitive lines; no tests or device changes |

The first switch collector is retained as the method used originally. It accepts
leaf-05's confirmed default hostname in this updated copy. It stops if candidate
exports contain credential matches; use a reviewed sanitization step before
publication. A successfully captured file is not a successful functional test.
