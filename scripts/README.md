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
