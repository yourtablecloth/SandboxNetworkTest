# Windows Sandbox 호스트 및 게스트 네트워킹 프로토타입

Windows Sandbox와 호스트 사이의 TCP, UDP, 이름 해석, 네트워크 비활성화, Protected Client와 NTFS 경로 기반 `AF_UNIX` 동작을 시험합니다. 호스트에서 게스트로 향하는 통신과 게스트에서 호스트로 향하는 통신을 모두 다룹니다.

파일 및 폴더 매핑과 Windows Sandbox CLI를 제외한 호스트 및 게스트 주소 발견 범위는 [디스커버리 가능 범위](DISCOVERY.md)에 정리했습니다.

## 전체 실험 결과 요약

2026년 8월 31일 Windows 11 Pro 빌드 26200과 Windows Sandbox 0.8.107.0에서 다음 결과를 확인했습니다.

| 실험 | 구성 | 결과 |
| --- | --- | --- |
| 호스트에서 게스트 TCP/HTTP | `Networking=Enable`, 게스트 TCP `8080` | 현재 세션 IP로 요청 및 응답 성공 |
| 호스트에서 게스트 UDP | `Networking=Enable`, 게스트 UDP `8081` | 고유 페이로드 왕복 성공 |
| 게스트 이름 해석 | 자동 생성 컴퓨터 이름 사용 | 첫 세션 성공, 다음 세션에서 이전 IP가 반환되어 고정 엔드포인트로 사용 불가 |
| Desktop 기본 폴더 매핑 | 두 `MappedFolder`에서 `SandboxFolder` 생략 | `Desktop\guest` 부트스트랩과 `Desktop\runtime` 상태 기록 성공 |
| 네트워크 비활성화 | `Networking=Disable` | 어댑터, 비루프백 IPv4와 기본 경로 없음, 인터넷과 호스트 TCP 및 UDP 연결 실패 |
| 비활성화 상태의 폴더 매핑 | `Networking=Disable`, 쓰기 가능 `runtime` 매핑 | 네트워크와 별개로 상태 파일 전달 성공 |
| NTFS 경로 기반 `AF_UNIX` | `Networking=Disable`, 매핑 폴더의 재분석 지점 | 게스트 내부 왕복 성공, 호스트와 게스트 간 연결은 Winsock `10061`로 실패 |
| Protected Client 기능 호환성 | `Networking=Enable`, `ProtectedClient=Enable` | 폴더 매핑, 인터넷, 호스트에서 게스트로 향하는 TCP 및 UDP 유지 |
| Protected Client 외부 토큰 관측 | 일반 모드와 Protected Client 비교 | 외부 `WindowsSandboxRemoteSession` 토큰으로 내부 RDP AppContainer 경계 확인 불가 |
| 게스트에서 호스트 TCP 및 UDP | 일반 모드, 호스트 `18080`과 `18081` | 기본 게이트웨이 `172.26.160.1`을 대상으로 모두 성공 |
| 게스트에서 호스트 TCP 및 UDP | Protected Client 모드 | 기본 게이트웨이 대상 TCP와 UDP 모두 성공 |
| 파일 및 CLI 없는 디스커버리 | `Networking=Enable` | 게스트는 기본 경로에서 호스트 IP 확인 가능, 나머지 주소와 이름 확정에는 피어 협조 필요 |

`Networking=Disable`에서는 네트워크 기반 디스커버리와 양방향 소켓 통신을 사용할 수 없습니다. Protected Client는 이번 TCP 및 UDP 통신 결과를 바꾸지 않았습니다. 각 실험의 구성과 관측값은 아래 섹션에서 구분해 설명합니다.

## 구성 파일과 실행 흐름

`SandboxHttp.wsb`는 네트워킹을 활성화하고 다음 두 폴더를 게스트에 매핑합니다.

- `guest`: `SandboxFolder`를 생략하여 기본 Desktop 위치에 매핑되는 읽기 전용 부트스트랩 스크립트
- `runtime`: `SandboxFolder`를 생략하여 기본 Desktop 위치에 매핑되는 쓰기 가능 폴더

저장소의 `.wsb` 파일은 호스트 경로를 `D:\Projects\SandboxNetworkTest`로 지정합니다. 다른 위치에 복제한 경우에는 각 `HostFolder`를 실제 절대 경로로 변경하면 됩니다. 낮은 버전의 Windows Sandbox도 고려하므로 `SandboxFolder`와 호스트 경로 환경 변수에 의존하지 않습니다.

Microsoft의 [`.wsb` 구성 문서](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)는 `SandboxFolder`를 생략한 공유 폴더를 컨테이너 사용자 Desktop에 매핑한다고 설명합니다. 기본 사용자가 `WDAGUtilityAccount`이므로 게스트 경로는 각각 `C:\Users\WDAGUtilityAccount\Desktop\guest`와 `C:\Users\WDAGUtilityAccount\Desktop\runtime`입니다.

`LogonCommand`는 로그인 직후 `C:\Users\WDAGUtilityAccount\Desktop\guest\Start-HttpListener.ps1`을 실행합니다. 게스트 스크립트는 Windows의 Desktop 특수 폴더 경로에 `runtime`을 결합합니다. 게스트는 현재 IPv4 주소와 컴퓨터 이름, TCP와 UDP 포트를 `runtime\guest-status.json`에 기록합니다. 호스트의 `Start-Probe.ps1`은 `.wsb` 파일을 직접 열고 이 상태 파일을 읽은 후 TCP/HTTP, UDP 요청과 게스트 컴퓨터 이름을 각각 시험합니다. Windows Sandbox CLI는 사용하지 않습니다.

## 자동 시험

다음 명령은 `.wsb` 파일을 직접 열고 통신을 시험합니다.

```powershell
.\Start-Probe.ps1
```

`SandboxHttp.wsb`를 탐색기에서 먼저 연 경우에는 다음 명령으로 실행 중인 세션만 시험할 수 있습니다.

```powershell
.\Start-Probe.ps1 -AttachOnly
```

실행 결과는 콘솔과 `runtime\host-probe-result.json`에 기록됩니다. 게스트의 시작 상태와 요청 로그는 각각 `runtime\guest-status.json`, `runtime\guest-listener.log`에서 확인할 수 있습니다. 시험을 마치면 Windows Sandbox 창을 직접 닫습니다.

UDP 시험은 호스트가 고유 문자열을 UDP `8081`로 보내고 게스트가 같은 문자열을 JSON 응답에 담아 돌려주는 방식입니다. `UdpRequest.Succeeded`와 `UdpRequest.ResponseFrom`에서 왕복 성공 여부와 응답 주소를 확인할 수 있습니다.

## 네트워킹 비활성화 비교 시험

`SandboxHttp-NoNetwork.wsb`는 비교 기준인 `SandboxHttp.wsb`를 유지하면서 `<Networking>Disable</Networking>`만 적용합니다. 다음 명령은 네트워크 비활성화 구성을 직접 열고 게스트와 호스트 양쪽의 차단 상태를 수집합니다.

```powershell
.\Test-NetworkDisabled.ps1
```

게스트는 비루프백 IPv4 주소, 기본 IPv4 경로, 네트워크 어댑터와 공인 IP `1.1.1.1:443` 연결 결과를 공유 상태 파일에 기록합니다. 호스트는 게스트 컴퓨터 이름을 대상으로 TCP `8080`과 UDP `8081` 응답을 각각 시험합니다. 매핑 폴더는 가상 네트워크와 별개의 공유 통로이므로 `Networking`이 비활성화된 상태에서도 시험 결과를 호스트로 전달합니다.

2026년 8월 31일 실제 시험에서는 다음 결과를 확인했습니다.

- 네트워크 어댑터 0개
- 비루프백 IPv4 주소와 기본 IPv4 경로 없음
- 게스트의 `1.1.1.1:443` 연결 실패, `연결할 수 없는 네트워크` 소켓 오류
- 호스트의 TCP `8080` 연결 실패
- 호스트의 UDP `8081` 응답 없음
- 매핑 폴더를 통한 게스트 상태 파일 수신 성공

따라서 `<Networking>Disable</Networking>`은 외부 인터넷만 차단하지 않습니다. Sandbox의 가상 네트워크 연결 자체를 제거하므로 호스트에서 게스트로 향하는 TCP와 UDP 통신도 사용할 수 없습니다. 다만 매핑 폴더와 같은 리디렉션 기능은 네트워크와 별개의 통로로 계속 동작합니다.

## NTFS 경로 기반 AF_UNIX 비교 시험

Windows에서 NTFS 경로에 소켓 항목을 만드는 기능은 명명 파이프가 아니라 Winsock의 `AF_UNIX`입니다. Microsoft는 [Windows 10 Insider Build 17063에서 AF_UNIX를 처음 공개](https://devblogs.microsoft.com/commandline/af_unix-comes-to-windows/)했습니다. 따라서 Windows 10 1주년 업데이트인 version 1607을 기준선으로 잡을 수 없습니다. 공개 빌드 번호를 기준으로 환산하면 version 1803 계열부터 해당 기능을 사용할 수 있습니다.

`AF_UNIX`의 `bind`는 지정한 NTFS 경로에 사용자 데이터 파일이 아닌 사용자 지정 재분석 지점을 만듭니다. 반면 Windows 명명 파이프는 [NPFS.SYS가 구현하는 Named Pipe File System](https://learn.microsoft.com/sysinternals/downloads/pipelist)을 사용하며 이름도 [`\\.\pipe\PipeName` 형식](https://learn.microsoft.com/windows/win32/ipc/pipe-names)을 따릅니다. 두 방식 모두 파일처럼 보이는 이름을 사용하지만 통신 데이터와 연결 상태는 일반 NTFS 파일 내용에 저장되지 않습니다.

`SandboxUnixSocket-NoNetwork.wsb`는 `<Networking>Disable</Networking>`을 유지하고 기존 `guest`, `runtime` 매핑을 그대로 사용합니다. 다음 명령은 호스트가 `runtime\mapped-af-unix.sock`에 `AF_UNIX` 서버를 연 뒤 `.wsb` 파일을 직접 실행합니다.

```powershell
.\Test-UnixSocketNoNetwork.ps1
```

게스트는 두 차례의 시험을 수행합니다. 먼저 게스트의 로컬 임시 경로에서 서버와 클라이언트를 함께 실행해 `AF_UNIX` 자체의 지원 여부를 확인합니다. 이어서 `C:\Users\WDAGUtilityAccount\Desktop\runtime\mapped-af-unix.sock`으로 연결해 호스트와 Sandbox 사이의 커널 경계를 통과할 수 있는지 시험합니다. 전체 결과는 `runtime\af-unix-no-network-result.json`에 기록합니다.

2026년 8월 31일 실제 시험에서는 다음 결과를 확인했습니다.

- 호스트 소켓 항목의 `Archive, ReparsePoint` 특성
- 게스트 로컬 `AF_UNIX` 요청과 응답 성공
- 게스트에서 매핑된 호스트 재분석 지점 확인 성공
- 매핑 경로 연결 실패, Winsock 오류 `10061`, 연결 거부
- 호스트 `AF_UNIX` 서버의 요청 수신 없음
- 게스트 네트워크 어댑터, 비루프백 IPv4 주소와 기본 경로 없음

매핑 폴더는 소켓 재분석 지점의 디렉터리 항목을 게스트에 노출했습니다. 그러나 게스트의 `AF_UNIX` 공급자는 해당 경로를 게스트 커널 안에서 해석하므로 호스트 커널이 소유한 소켓 엔드포인트에 연결하지 못했습니다. 따라서 NTFS 경로 기반 소켓을 매핑 폴더에 두어도 `Networking=Disable` 상태의 호스트와 Sandbox 사이에서 스트림 통신을 만들 수 없습니다.

네트워크 비활성화 상태에서 양방향 메시지를 교환하려면 매핑 폴더에 요청 파일과 응답 파일을 쓰고 원자적으로 이름을 바꾸는 파일 기반 큐를 사용할 수 있습니다. 이 방식은 파일 리디렉션을 통신 규약으로 사용하며 `AF_UNIX` 또는 명명 파이프 연결을 공유하지 않습니다.

## Protected Client 비교 시험

`SandboxHttp-ProtectedClient.wsb`는 네트워킹과 매핑 폴더 구성을 유지하면서 `<ProtectedClient>Enable</ProtectedClient>`만 추가합니다. 다음 명령은 현재 일반 모드 세션의 호스트 클라이언트 토큰을 기준값으로 저장하고 Protected Client 세션으로 교체해 비교합니다.

```powershell
.\Test-ProtectedClient.ps1 -CaptureCurrentSessionAsBaseline
```

시험 스크립트는 호스트의 `WindowsSandboxRemoteSession` 프로세스가 AppContainer 토큰을 사용하는지 확인합니다. 이어서 읽기 전용 `guest` 매핑의 부트스트랩, 쓰기 가능한 `runtime` 상태 기록, TCP `8080`, UDP `8081`, 게스트 아웃바운드 연결을 검사합니다. 사용자 클립보드의 기존 형식을 훼손할 수 있으므로 클립보드 복사와 붙여넣기는 자동 시험에서 제외합니다.

2026년 8월 31일 Windows Sandbox 0.8.107.0 시험에서는 다음 결과를 확인했습니다.

- 일반 모드와 Protected Client 모드의 외부 `WindowsSandboxRemoteSession` 토큰 모두 AppContainer 아님
- 읽기 전용 `guest` 매핑에서 부트스트랩 성공
- 쓰기 가능한 `runtime` 매핑으로 상태 기록 성공
- 게스트 네트워크 어댑터, 비루프백 IPv4와 기본 경로 유지
- 게스트 외부 인터넷 연결 성공
- 호스트 TCP `8080`과 UDP `8081` 프로브 성공

Protected Client는 네트워킹이나 매핑 폴더를 차단하는 설정으로 작용하지 않았습니다. Microsoft 문서는 내부 RDP 클라이언트에 AppContainer 격리 계층을 추가한다고 설명하지만 외부 `WindowsSandboxRemoteSession` 토큰은 이 내부 경계를 드러내지 않았습니다. 따라서 이번 자동 시험은 기능 호환성을 확인했으며 보안 경계 자체를 직접 검증했다고 해석하지 않습니다.

## Sandbox에서 호스트 리스너로 향하는 역방향 시험

`SandboxHostListeners.wsb`와 `SandboxHostListeners-ProtectedClient.wsb`는 호스트가 TCP `18080`과 UDP `18081`에서 대기할 때 Sandbox가 호스트로 연결할 수 있는지 비교합니다. 두 구성 모두 `<Networking>Enable</Networking>`을 사용하며 `SandboxFolder` 요소를 생략합니다. 두 번째 구성에만 `<ProtectedClient>Enable</ProtectedClient>`을 추가했습니다.

다음 명령은 일반 모드와 Protected Client 모드를 차례로 직접 실행합니다.

```powershell
.\Test-GuestToHostListeners.ps1
```

호스트 리스너는 `0.0.0.0`에 바인딩합니다. 게스트는 첫 번째 IPv4 기본 경로의 `NextHop`을 현재 세션의 호스트 주소로 사용합니다. TCP와 UDP 모두 고유한 요청 문자열을 보내며 호스트가 같은 문자열을 응답에 포함했을 때 성공으로 판정합니다. 시험 스크립트는 첫 번째 Sandbox를 종료한 뒤 Protected Client 구성을 열고, 두 번째 시험 후에도 Sandbox와 호스트 리스너를 종료합니다.

현재 호스트 계정은 관리자 권한으로 실행되지 않았습니다. 따라서 시험 스크립트는 새 방화벽 규칙을 만들지 않으며 기존 `C:\Program Files\nodejs\node.exe`의 Public 프로필 TCP 및 UDP 인바운드 허용 규칙을 사전 검증합니다. 다른 호스트에서 해당 허용 규칙을 찾지 못하면 비교 시험을 시작하지 않습니다.

2026년 8월 31일 실제 시험에서는 다음 결과를 확인했습니다.

- 일반 모드 호스트 주소 `172.26.160.1`, 게스트 주소 `172.26.165.119`
- 일반 모드 TCP와 UDP 요청 및 응답 성공
- Protected Client 모드 호스트 주소 `172.26.160.1`, 게스트 주소 `172.26.169.215`
- Protected Client 모드 TCP와 UDP 요청 및 응답 성공
- 두 모드에서 호스트가 기록한 원격 주소와 게스트 로컬 엔드포인트 주소 일치

따라서 네트워킹을 활성화하면 Sandbox에서 호스트의 TCP 및 UDP 리스너로 연결할 수 있습니다. Protected Client 설정은 이번 역방향 통신 결과를 바꾸지 않았습니다. 게스트 IP는 세션마다 바뀌었지만 기본 경로의 호스트 주소는 두 시험에서 같았습니다. 재사용 시에는 고정 주소를 가정하지 않고 게스트의 현재 기본 경로를 조회합니다.

통합 결과는 `runtime\guest-to-host-comparison.json`에 기록합니다. 일반 모드와 Protected Client 모드의 게스트 관측값 및 호스트 수신값도 각각 별도 JSON 파일로 남깁니다.

## 호스트 이름의 범위

Microsoft가 공개한 [`.wsb` 구성 항목](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)에는 컴퓨터 이름이나 고정 IP를 지정하는 속성이 없습니다. 이 프로토타입은 실제 게스트 컴퓨터 이름을 응답에 포함하고 호스트에서 해당 이름을 해석할 수 있는지도 별도로 기록합니다.

세션마다 바뀔 수 있는 게스트 주소는 공유 상태 파일로 전달합니다. 애플리케이션이 고정 URL을 요구한다면 호스트의 고정 포트에서 상태 파일에 기록된 현재 Sandbox IP로 전달하는 프록시를 별도로 두는 구성이 적합합니다.

## 2026년 8월 31일 시험 결과

Windows 11 Pro 빌드 26200과 Windows Sandbox 0.8.107.0에서 동일한 `.wsb` 파일을 두 차례 직접 열어 시험했습니다.

- 1차 세션: 컴퓨터 이름 `C29C41A2-0C9C-4`, IPv4 `172.26.169.95`, IP 요청과 이름 요청 성공
- 2차 세션: 컴퓨터 이름 `C29C41A2-0C9C-4`, IPv4 `172.26.166.250`, IP 요청 성공
- 2차 이름 해석: 이전 세션 주소 `172.26.169.95` 반환, HTTP 요청 시간 초과
- Desktop 기본 매핑 검증: `guest`와 `runtime`에서 `SandboxFolder` 생략, `C:\Users\WDAGUtilityAccount\Desktop\guest` 부트스트랩과 `C:\Users\WDAGUtilityAccount\Desktop\runtime` 상태 기록 성공, IPv4 `172.26.175.193` 요청 성공
- UDP 왕복 검증: 호스트에서 `172.26.166.27:8081`로 고유 페이로드 송신, Sandbox가 동일한 페이로드를 포함한 JSON 데이터그램 반환, 응답 송신 주소 `172.26.166.27:8081`

컴퓨터 이름 문자열은 두 세션에서 같았지만 이름 해석 결과가 새 IP로 전환되지 않았습니다. 따라서 자동 생성 컴퓨터 이름을 고정 엔드포인트로 간주할 수 없습니다. 현재 세션의 IP를 공유 상태 파일에서 읽는 방식은 두 차례 모두 성공했습니다.

## 라이선스

이 프로젝트는 [MIT License](LICENSE)에 따라 배포합니다.
