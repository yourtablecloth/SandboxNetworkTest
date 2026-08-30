# Windows Sandbox Host and Guest Discovery Boundaries

English | [한국어](DISCOVERY.ko.md)

As of August 31, 2026, Windows Sandbox connects to the Hyper-V Default Switch when networking is enabled. Microsoft's published `.wsb` options do not expose a setting for assigning or reading the Sandbox computer name or a fixed IP address. When mapped files and folders and the Windows Sandbox CLI are excluded, discovery capabilities differ by direction.

This document separately evaluates finding the Sandbox IP address and computer name from the host and finding the host IP address and host name from Sandbox. It distinguishes direct discovery through platform information, cooperative discovery through a peer response, and heuristics that provide only candidate addresses.

The matrix below presents the conclusion first. The remaining sections define the scope and decision labels, then cover host-side discovery, Sandbox-side discovery, cooperative alternatives, and methods that are not dependable enough to act as a discovery contract.

> Snapshot date: August 31, 2026. The test environment used Windows 11 Pro build 26200 and Windows Sandbox 0.8.107.0. Windows Sandbox implementation details and the Hyper-V Default Switch address range may change in later versions.

## Discovery outcome matrix

The matrix summarizes the available discovery result by direction, identity type, and peer cooperation. Protected Client produced the same results as standard networking in the tested environment.

| Direction | Identity | `Networking=Enable` without peer cooperation | `Networking=Enable` with peer cooperation | `Networking=Disable` |
| --- | --- | --- | --- | --- |
| Host to Sandbox | IP address | Heuristic candidates only | Available from the remote address of a guest connection | Unavailable |
| Host to Sandbox | Computer name | Unavailable | Available when the guest sends its name | Unavailable |
| Sandbox to host | IP address | Directly available from the default route | Available and verifiable through a host response | Unavailable |
| Sandbox to host | Host name | Unavailable | Available when the host returns its name | Unavailable |

## Scope and decision labels

Microsoft's [Windows Sandbox configuration documentation](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) states that enabling networking creates a virtual switch on the host and connects Sandbox through a virtual NIC. The published options do not include `ComputerName`, a fixed IP, a DHCP reservation, or a property that returns the network identity of a running session.

This document applies the following conditions:

- `<Networking>Enable</Networking>`
- No Windows Sandbox CLI
- No status files delivered through mapped files or folders
- No clipboard or manual copy operation
- Both standard and Protected Client modes
- One Windows Sandbox instance running on the host

`Directly available` means that the target can be identified from published operating-system network information without the peer transmitting its identity. `Available with peer cooperation` means that the peer must respond on a known port or send a registration message. `Heuristic` means that a candidate can be found but cannot be proven to be the Windows Sandbox endpoint.

With `<Networking>Disable</Networking>`, the guest had no network adapter or default route. None of the network discovery methods in this document can operate in that state. See the [networking disabled comparison](README.md#networking-disabled-comparison).

Windows Sandbox uses the Hyper-V Default Switch, while Protected Client applies a separate security boundary to the RDP session. Microsoft's [Windows Sandbox default configuration](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) and the [bidirectional TCP and UDP results](README.md#reverse-probe-from-sandbox-to-host-listeners) show that Protected Client did not change these decisions in the tested environment.

## Discovering Sandbox from the host

The host has no published `.wsb` property that returns the current IP address of a running Windows Sandbox. The configuration file also cannot assign or read the Sandbox computer name. Without guest cooperation, no general method was confirmed that identifies the exact Sandbox endpoint.

The host IPv4 neighbor cache can provide candidate addresses. Microsoft's [`Get-NetNeighbor` documentation](https://learn.microsoft.com/powershell/module/nettcpip/get-netneighbor) states that the command returns IPv4 ARP-cache IP and link-layer addresses. The following query can list addresses that have communicated on virtual networks:

```powershell
Get-NetNeighbor -AddressFamily IPv4 |
    Where-Object State -in Reachable, Stale |
    Select-Object InterfaceAlias, IPAddress, LinkLayerAddress, State
```

Neighbor entries depend on prior traffic and cache state. When Hyper-V VMs, WSL, or containers are also active, the list does not identify which entry belongs to Windows Sandbox. ARP and neighbor-cache inspection therefore collect candidates rather than complete discovery.

Scanning a subnet for a known guest port and validating an application-specific response can identify the guest IP. This method requires a guest listener, an inbound firewall allowance, and a unique response marker, so it counts as cooperative discovery. An open port without an identity marker can be mistaken for another virtual endpoint.

DNS, LLMNR, or NetBIOS name resolution can be attempted when the computer name is already known. These protocols do not discover the name first and do not guarantee that the returned address belongs to the current session. In the existing experiments, the same generated name appeared in two sessions, but the second session resolved to the previous IP and the connection failed. See the [per-session name-resolution results](README.md#results-from-august-31-2026).

## Discovering the host from Sandbox

Sandbox can read the next hop of its default IPv4 route. Microsoft's [`Get-NetRoute` documentation](https://learn.microsoft.com/powershell/module/nettcpip/get-netroute) defines the `NextHop` of `0.0.0.0/0` as the default gateway. The following query selects the highest-priority default gateway:

```powershell
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
    Where-Object NextHop -ne '0.0.0.0' |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1 -ExpandProperty NextHop
```

Both standard and Protected Client tests returned `172.26.160.1`. Sandbox connected to host TCP `18080` and UDP `18081` listeners at that address, and the host received the requests. See the [Sandbox-to-host comparison](README.md#reverse-probe-from-sandbox-to-host-listeners).

Microsoft documents that Windows Sandbox uses the Hyper-V Default Switch, but it does not define the default-route next hop as a permanent Windows Sandbox host API. Reusable code therefore queries the routing table for every session instead of persisting a particular address. Hyper-V NAT connects a VM to host networking through a gateway on an internal virtual switch. See [Microsoft's Hyper-V NAT documentation](https://learn.microsoft.com/windows-server/virtualization/hyper-v/setup-nat-network).

The default gateway provides only an IP address. It does not guarantee a PTR record, DNS suffix, or host computer name. When the guest also needs the host name, a host service on a known port can return the name in its response. In the reverse-direction experiment, the host returned `rkttu-surface`, and the guest received it.

## Cooperative discovery

When the host needs to find Sandbox, a guest registration connection makes the fewest assumptions. After startup, the guest connects to a prearranged TCP or UDP port on the default gateway. The host obtains the guest IP from the connection's remote address and receives the guest computer name and protocol version in the request body.

When Sandbox needs to identify the host, it uses the default gateway and a prearranged port. The host includes its computer name and a service identifier in the response. The guest can then verify host identity without reverse DNS.

This design does not use mapped files or folders. Bootstrapping the two processes is outside the scope of this document. The guest registration code can be started manually, embedded in a single `.wsb` `LogonCommand`, or retrieved over the network. Microsoft documents that [`LogonCommand` runs one command after Sandbox signs in](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file#logon-command).

A registration protocol can validate a per-session nonce and application identifier rather than trusting only the guest-reported name. Using the remote IP observed by the host also avoids relying on a potentially incorrect self-reported guest address.

## Constraints by discovery method

The following table separates the available information from each method and its limitations.

| Method | Information available | Limitation | Decision |
| --- | --- | --- | --- |
| `.wsb` configuration inspection | Whether networking is enabled | No running IP or computer-name property | Unavailable |
| Guest default route | Host-side gateway IP | Implementation may change; no host name | Available in the tested implementation |
| Host neighbor cache | Recently observed IP and MAC candidates | Cannot prove Sandbox identity | Heuristic |
| Known-port scan | Guest IP candidates that respond | Requires listener and firewall allowance | Available with cooperation |
| DNS, LLMNR, NetBIOS | Address for an already known name | Cannot discover the initial name; depends on cache and registration | Auxiliary only |
| Guest registration connection | Guest remote IP and self-reported name | Requires guest code and host listener | Available with cooperation |
| Host service response | Host name and service identity | Requires a known gateway port | Available with cooperation |
| HNS or Hyper-V internal state | Internal endpoint candidates | No confirmed public contract for Windows Sandbox | Unsupported implementation dependency |

Windows name resolution includes LLMNR, WINS, and NetBIOS mechanisms in addition to DNS. These protocols resolve a supplied name to an address and do not act as an API for enumerating an arbitrary Windows Sandbox name. See the [Microsoft Windows name-resolution overview](https://learn.microsoft.com/openspecs/windows_protocols/ms-wpo/f00add7f-a321-4a5f-a5d8-1748e748cd44).

The DNS client caches previous responses for their TTL. A short-lived guest that reuses a name with a new IP can therefore leave the previous address in cache. [Microsoft's DNS client cache documentation](https://learn.microsoft.com/windows-server/networking/dns/queries-lookups#dns-client-service-resolver) and the per-session experiment show the same risk.

## Resulting discovery boundary

When mapped files and the Windows Sandbox CLI are excluded, Sandbox can obtain the host IP from its default route. It can obtain the host name when a host service includes it in a response. In the other direction, the host needs a guest registration connection to confirm both the guest IP and computer name.

Without any peer cooperation, the host can use neighbor-cache inspection and port scanning only to collect guest IP candidates, not to prove Sandbox identity. DNS and the automatically generated computer name do not provide session-to-session cache consistency. Direct discovery without peer cooperation is therefore limited to Sandbox reading its current default gateway IP in the tested implementation.

Protected Client did not change this conclusion. Disabling networking removes the default route and both TCP and UDP paths, so network-based discovery becomes unavailable.
