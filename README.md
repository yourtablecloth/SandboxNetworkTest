# Windows Sandbox Host and Guest Networking Prototype

English | [한국어](README.ko.md)

This project tests TCP, UDP, name resolution, disabled networking, Protected Client, and NTFS-path-based `AF_UNIX` behavior between Windows Sandbox and its host. It covers traffic in both the host-to-guest and guest-to-host directions.

See [Windows Sandbox host and guest discovery boundaries](DISCOVERY.md) for discovery options that exclude mapped files and folders and the Windows Sandbox CLI.

## Outcome matrix

The matrix below separates observed success and failure from combinations that were not tested. `Unavailable` means that the configuration removed the network path required by the capability.

| Capability | `Networking=Enable` | `Networking=Enable` with Protected Client | `Networking=Disable` |
| --- | --- | --- | --- |
| Host to Sandbox TCP/HTTP | Success | Success | Failure |
| Host to Sandbox UDP | Success | Success | Failure |
| Sandbox to host TCP | Success | Success | Unavailable |
| Sandbox to host UDP | Success | Success | Unavailable |
| Sandbox outbound Internet | Success | Success | Failure |
| Mapped `guest` and `runtime` folders | Success | Success | Success |
| Cross-kernel `AF_UNIX` through mapped NTFS | Not tested | Not tested | Failure |
| Generated Sandbox name as a fixed endpoint | Failure | Not tested | Unavailable |

## Summary of all experiment results

The following results were observed on August 31, 2026, using Windows 11 Pro build 26200 and Windows Sandbox 0.8.107.0.

| Experiment | Configuration | Result |
| --- | --- | --- |
| Host-to-guest TCP/HTTP | `Networking=Enable`, guest TCP `8080` | Request and response succeeded through the current session IP |
| Host-to-guest UDP | `Networking=Enable`, guest UDP `8081` | Unique payload completed a round trip |
| Guest name resolution | Automatically generated computer name | First session succeeded; the next session returned the previous IP, so the name was not usable as a fixed endpoint |
| Default Desktop folder mapping | `SandboxFolder` omitted from both `MappedFolder` entries | Bootstrap from `Desktop\guest` and state writes to `Desktop\runtime` succeeded |
| Disabled networking | `Networking=Disable` | No adapter, non-loopback IPv4 address, or default route; Internet and host TCP and UDP connections failed |
| Folder mapping with networking disabled | `Networking=Disable`, writable `runtime` mapping | State file transfer continued independently of the virtual network |
| `AF_UNIX` over an NTFS path | `Networking=Disable`, reparse point in a mapped folder | Guest-local round trip succeeded; host-to-guest connection failed with Winsock error `10061` |
| Protected Client functional compatibility | `Networking=Enable`, `ProtectedClient=Enable` | Folder mapping, Internet access, and host-to-guest TCP and UDP remained available |
| Protected Client outer-token observation | Standard and Protected Client comparison | The outer `WindowsSandboxRemoteSession` token did not expose the internal RDP AppContainer boundary |
| Guest-to-host TCP and UDP | Standard mode, host ports `18080` and `18081` | Both protocols succeeded through default gateway `172.26.160.1` |
| Guest-to-host TCP and UDP | Protected Client mode | Both protocols succeeded through the default gateway |
| Discovery without files or CLI | `Networking=Enable` | The guest could obtain the host IP from its default route; confirming other addresses and names required peer cooperation |

With `Networking=Disable`, network-based discovery and bidirectional socket communication are unavailable. Protected Client did not change the TCP or UDP results in these experiments. The sections below separate the configuration and observations for each experiment.

## Configuration files and execution flow

`SandboxHttp.wsb` enables networking and maps the following two host folders into the guest:

- `guest`: read-only bootstrap scripts mapped to the default Desktop location by omitting `SandboxFolder`
- `runtime`: a writable folder mapped to the default Desktop location by omitting `SandboxFolder`

The `.wsb` files in this repository specify `D:\Projects\SandboxNetworkTest` as the host path. If the repository is cloned elsewhere, update each `HostFolder` to the actual absolute path. The files avoid `SandboxFolder` and host-path environment variables to retain compatibility with older Windows Sandbox versions.

Microsoft's [`.wsb` configuration documentation](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) states that a shared folder without `SandboxFolder` is mapped to the container user's Desktop. Because the default user is `WDAGUtilityAccount`, the guest paths are `C:\Users\WDAGUtilityAccount\Desktop\guest` and `C:\Users\WDAGUtilityAccount\Desktop\runtime`.

`LogonCommand` runs `C:\Users\WDAGUtilityAccount\Desktop\guest\Start-HttpListener.ps1` immediately after sign-in. The guest script combines the Windows Desktop special-folder path with `runtime`. It writes the current IPv4 address, computer name, TCP port, and UDP port to `runtime\guest-status.json`. The host script `Start-Probe.ps1` opens the `.wsb` file directly, reads this status file, and tests TCP/HTTP, UDP, and the guest computer name. It does not use the Windows Sandbox CLI.

## Automated test

Run the following command to open the `.wsb` file directly and test communication:

```powershell
.\Start-Probe.ps1
```

If `SandboxHttp.wsb` is already open, run the following command to test the active session only:

```powershell
.\Start-Probe.ps1 -AttachOnly
```

Results are written to the console and `runtime\host-probe-result.json`. Guest startup state and request logs are available in `runtime\guest-status.json` and `runtime\guest-listener.log`. Close the Windows Sandbox window after the test.

For the UDP test, the host sends a unique string to UDP `8081`, and the guest returns the same string in a JSON datagram. `UdpRequest.Succeeded` and `UdpRequest.ResponseFrom` report round-trip success and the response address.

## Networking disabled comparison

`SandboxHttp-NoNetwork.wsb` retains the baseline `SandboxHttp.wsb` configuration and changes only `<Networking>Disable</Networking>`. The following command opens the network-disabled configuration directly and collects isolation observations from both the guest and host:

```powershell
.\Test-NetworkDisabled.ps1
```

The guest records non-loopback IPv4 addresses, default IPv4 routes, network adapters, and the result of connecting to public address `1.1.1.1:443`. The host probes TCP `8080` and UDP `8081` using the guest computer name. Mapped folders are separate from the virtual network, so the guest can still return test results through the shared folder when networking is disabled.

The test performed on August 31, 2026, produced the following results:

- Zero network adapters
- No non-loopback IPv4 address or default IPv4 route
- Guest connection to `1.1.1.1:443` failed with a network-unreachable socket error
- Host TCP `8080` connection failed
- Host received no UDP `8081` response
- Host received the guest status file through the mapped folder

`<Networking>Disable</Networking>` therefore does more than block external Internet access. It removes the Sandbox virtual network connection, so host-to-guest TCP and UDP are also unavailable. Redirection features such as mapped folders continue to work through a separate channel.

## AF_UNIX over an NTFS path

The Windows feature that creates a socket entry at an NTFS path is Winsock `AF_UNIX`, not a Windows named pipe. Microsoft [introduced AF_UNIX in Windows 10 Insider Build 17063](https://devblogs.microsoft.com/commandline/af_unix-comes-to-windows/). It was not part of Windows 10 version 1607, the Anniversary Update. Mapped to public build numbers, the feature is available from the version 1803 family.

An `AF_UNIX` `bind` creates a custom reparse point at the specified NTFS path rather than a user-data file. Windows named pipes instead use the [Named Pipe File System implemented by NPFS.SYS](https://learn.microsoft.com/sysinternals/downloads/pipelist) and follow the [`\\.\pipe\PipeName` naming form](https://learn.microsoft.com/windows/win32/ipc/pipe-names). Both mechanisms use file-like names, but their connection state and data do not reside in ordinary NTFS file contents.

`SandboxUnixSocket-NoNetwork.wsb` keeps `<Networking>Disable</Networking>` and uses the existing `guest` and `runtime` mappings. The following command opens an `AF_UNIX` server at `runtime\mapped-af-unix.sock` on the host and then launches the `.wsb` file directly:

```powershell
.\Test-UnixSocketNoNetwork.ps1
```

The guest performs two tests. It first starts a server and client at a guest-local temporary path to confirm that the operating system supports `AF_UNIX`. It then attempts to connect to `C:\Users\WDAGUtilityAccount\Desktop\runtime\mapped-af-unix.sock` to determine whether the endpoint crosses the host-to-Sandbox kernel boundary. The complete result is written to `runtime\af-unix-no-network-result.json`.

The test performed on August 31, 2026, produced the following results:

- Host socket entry had `Archive, ReparsePoint` attributes
- Guest-local `AF_UNIX` request and response succeeded
- Guest could see the mapped host reparse point
- Connection through the mapped path failed immediately with Winsock error `10061`
- Host `AF_UNIX` server received no request
- Guest had no network adapter, non-loopback IPv4 address, or default route

The mapped folder exposed the directory entry for the socket reparse point to the guest. The guest `AF_UNIX` provider still resolved the path within the guest kernel and could not reach the socket endpoint owned by the host kernel. Placing the socket in a mapped folder therefore does not provide a host-to-Sandbox stream while `Networking=Disable` remains in effect.

A file-based request and response queue can exchange messages through a mapped folder while networking is disabled. Such a queue uses file redirection as its protocol and does not share an `AF_UNIX` or named-pipe connection.

## Protected Client comparison

`SandboxHttp-ProtectedClient.wsb` retains networking and mapped folders and adds only `<ProtectedClient>Enable</ProtectedClient>`. The following command captures the active standard-session host-client token as a baseline, replaces that session with Protected Client, and compares the two:

```powershell
.\Test-ProtectedClient.ps1 -CaptureCurrentSessionAsBaseline
```

The test inspects whether the host `WindowsSandboxRemoteSession` process uses an AppContainer token. It then checks bootstrap from the read-only `guest` mapping, status writes to the writable `runtime` mapping, TCP `8080`, UDP `8081`, and guest outbound connectivity. Clipboard testing is excluded because it would modify the user's existing clipboard state.

The test performed on August 31, 2026, using Windows Sandbox 0.8.107.0 produced the following results:

- Outer `WindowsSandboxRemoteSession` token was not an AppContainer in either standard or Protected Client mode
- Bootstrap from the read-only `guest` mapping succeeded
- Status writes through the writable `runtime` mapping succeeded
- Guest network adapter, non-loopback IPv4 address, and default route remained available
- Guest outbound Internet connection succeeded
- Host TCP `8080` and UDP `8081` probes succeeded

Protected Client did not block networking or mapped folders. Microsoft documents an additional AppContainer isolation layer around the internal RDP client, but the outer `WindowsSandboxRemoteSession` token did not expose that internal boundary. The automated test therefore confirms functional compatibility and does not directly verify the documented security boundary.

## Reverse probe from Sandbox to host listeners

`SandboxHostListeners.wsb` and `SandboxHostListeners-ProtectedClient.wsb` compare whether Sandbox can reach host listeners on TCP `18080` and UDP `18081`. Both configurations use `<Networking>Enable</Networking>` and omit `SandboxFolder`. Only the second configuration adds `<ProtectedClient>Enable</ProtectedClient>`.

The following command runs standard mode and Protected Client mode in sequence:

```powershell
.\Test-GuestToHostListeners.ps1
```

The host listeners bind to `0.0.0.0`. The guest uses the `NextHop` from its first IPv4 default route as the host address. It sends a unique request over TCP and UDP, and the test succeeds only when the host returns the same string in each response. The script closes the first Sandbox before opening the Protected Client configuration, then closes the second Sandbox and both host listeners after the comparison.

The host account used for this experiment was not elevated. The script therefore does not create firewall rules. It first verifies existing Public-profile TCP and UDP inbound allow rules for `C:\Program Files\nodejs\node.exe`. On another host, the comparison stops before launching Sandbox if those allow rules are unavailable.

The test performed on August 31, 2026, produced the following results:

- Standard mode host address `172.26.160.1`, guest address `172.26.165.119`
- Standard mode TCP and UDP request and response succeeded
- Protected Client host address `172.26.160.1`, guest address `172.26.169.215`
- Protected Client TCP and UDP request and response succeeded
- In both modes, the remote address recorded by the host matched the guest's local endpoint address

With networking enabled, Sandbox can connect to TCP and UDP listeners on the host. Protected Client did not change this reverse-direction result. The guest IP changed between sessions, while the host gateway address remained the same in both experiments. Reusable code queries the current default route rather than assuming a fixed address.

The combined result is written to `runtime\guest-to-host-comparison.json`. Separate JSON files retain the guest observations and host-received values for standard and Protected Client modes.

## Host name limitations

Microsoft's published [`.wsb` configuration options](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file) do not include a computer-name or fixed-IP setting. This prototype includes the current guest computer name in responses and separately records whether the host can resolve it.

The current session address is delivered through the shared status file in this prototype. An application that requires a fixed URL could expose a stable host port and proxy it to the current Sandbox IP recorded in that status file.

## Results from August 31, 2026

The same `.wsb` file was opened directly twice on Windows 11 Pro build 26200 with Windows Sandbox 0.8.107.0.

- Session 1: computer name `C29C41A2-0C9C-4`, IPv4 `172.26.169.95`; both IP and name requests succeeded
- Session 2: computer name `C29C41A2-0C9C-4`, IPv4 `172.26.166.250`; IP request succeeded
- Session 2 name resolution returned previous address `172.26.169.95`, and the HTTP request timed out
- Default Desktop mapping: omitted `SandboxFolder` from `guest` and `runtime`; bootstrap from `C:\Users\WDAGUtilityAccount\Desktop\guest` and status write to `C:\Users\WDAGUtilityAccount\Desktop\runtime` succeeded; request to IPv4 `172.26.175.193` succeeded
- UDP round trip: host sent a unique payload to `172.26.166.27:8081`; Sandbox returned a JSON datagram containing the same payload from `172.26.166.27:8081`

The computer-name string remained the same across two sessions, but name resolution did not move to the new IP. The automatically generated computer name therefore cannot be treated as a fixed endpoint. Reading the current session IP from the shared status file succeeded in both sessions.

## License

This project is distributed under the [MIT License](LICENSE).
