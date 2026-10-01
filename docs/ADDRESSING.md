# Addressing and source routing

| Purpose | Pool / pattern |
|---|---|
| Switch management | 172.31.17.x; exact masks preserved in underlay plan |
| Client OS management | 172.31.18.N |
| Client BMC | 172.31.16.N |
| Leaf–spine links | 10.254.0.0/24 divided into 128 /31s |
| Client datapath | 10.200.N.0/31 and 10.200.N.2/31 |
| Switch loopbacks | 10.255.0.x/32; exact identity in switch inventory |

A /31 contains two usable point-to-point endpoint addresses. On underlay
links, the spine receives the even address and leaf receives the odd address.
On client links, the leaf receives the even address and client the odd address.

## Example: weka60

| Link | Server interface | Client address | Leaf gateway | Leaf port | Policy table |
|---|---|---|---|---|---:|
| 1 | ens4047np0 | 10.200.60.1/31 | 10.200.60.0 | swp4s1 | 100 |
| 2 | ens3919np0 | 10.200.60.3/31 | 10.200.60.2 | swp4s0 | 101 |

Each table has a route to 10.200.0.0/16 through that link’s leaf gateway.
A rule selects table 100 for source 10.200.N.1/32 and table 101 for
10.200.N.3/32, at priorities 32764 and 32765. Management routing is separate.

```bash
ip -4 address show
ip rule show
ip -4 route show table 100
ip -4 route show table 101
ip -4 route get 10.200.49.1 from 10.200.60.1
ping -n -I 10.200.60.1 -c 5 -W 2 -M do -s 8972 10.200.49.1
```

Use the **source IP** for these routed probes. Earlier cross-leaf tests bound
to an interface name failed; source-IP tests succeeded without a route change.
This was a test-binding issue, not proof that BGP or reverse-path filtering was broken.

8972 bytes of ICMP payload + 8-byte ICMP header + 20-byte IPv4 header = a
9000-byte IP packet. The ping reply display of 8980 bytes excludes the IPv4 header.
Server MTU is 9000 and switch MTU 9216. RDMA perftest can separately report
4096-byte verbs MTU; that does not contradict the IP MTU.

The older /16 client configuration used a self-address as a gateway and an
InfiniBand interface. It was replaced by the matched Ethernet interfaces,
/31 addresses and real leaf gateways. Exact candidate YAMLs and MACs are
in the client package. Do not reuse an interface name or MAC from another host.

The 80-backend expansion is a future requirement. This repository does not
allocate backend identities, switch ports or an approved backend address plan.
Avoid claiming all backends can reach all clients until those endpoints are
inventoried, configured and tested.
