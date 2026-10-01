# Inventory and source of truth

Use `switches.json`, `client-port-map.csv`, `client-port-map.json`,
`underlay-plan.json`, `underlay-port-map.csv` and `client-status.csv`.
The port map distinguishes planned/deferred entries from confirmed links.
Never configure a deferred row solely because it has a reserved address.

Rack placement was corrected after the original four-rack client package:
leaf-01 Rack 1, leaf-02 Rack 2, all spines and leaf-05 Rack 3,
leaf-03 Rack 4, leaf-04 Rack 5. Original archived spreadsheets may use old rack labels.
The corrections do not change port identities, MAC addresses or /31 addresses.

There are 128 planned leaf–spine links and 256 endpoint records. A planned
link is not proof that it is plugged in or that its BGP session is established.
The 40-client mapping contains 80 planned client links; only 35 clients have
confirmed mappings. For the dual-port adapter hosts, only the two mapped
interfaces are covered by the /31 deployment; do not assume every physical
CX-7 port was assigned or tested.
