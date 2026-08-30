# Windows Sandbox 호스트와 게스트 디스커버리 가능 범위

[English](DISCOVERY.md) | 한국어

2026년 8월 31일 기준으로 Windows Sandbox는 네트워킹을 활성화하면 Hyper-V 기본 스위치에 연결됩니다. Microsoft가 공개한 `.wsb` 구성 항목에는 Sandbox 컴퓨터 이름이나 고정 IP를 지정하고 조회하는 속성이 없습니다. 파일 및 폴더 매핑과 Windows Sandbox CLI를 제외하면 양방향 디스커버리 능력이 서로 다릅니다.

이 문서는 호스트에서 Sandbox의 IP 주소와 컴퓨터 이름을 찾는 경우, Sandbox에서 호스트의 IP 주소와 컴퓨터 이름을 찾는 경우를 구분합니다. 플랫폼 기능만 사용하는 직접 발견, 상대 프로세스의 응답을 받는 협조 기반 발견, 후보 주소만 제시하는 휴리스틱을 각각 판정합니다.

우선 판정 기준과 제외 범위를 정리하겠습니다. 이어서 방향별 결론, 호스트 측 발견, Sandbox 측 발견, 협조 기반 대안과 신뢰하기 어려운 수단을 다루겠습니다.

> 기준일: 2026년 8월 31일. 시험 환경은 Windows 11 Pro 빌드 26200과 Windows Sandbox 0.8.107.0입니다. Windows Sandbox 구현과 Hyper-V 기본 스위치의 주소 범위는 이후 버전에서 달라질 수 있습니다.

## 판정 기준과 제외 범위

Microsoft의 [Windows Sandbox 구성 문서](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)는 네트워킹을 활성화하면 호스트에 가상 스위치를 만들고 Sandbox를 가상 NIC로 연결한다고 설명합니다. 공개된 구성 항목에는 `ComputerName`, 고정 IP, DHCP 예약 또는 실행 중인 네트워크 신원을 반환하는 속성이 없습니다.

이 문서는 다음 조건을 적용합니다.

- `<Networking>Enable</Networking>` 상태
- Windows Sandbox CLI 제외
- 파일 및 폴더 매핑을 이용한 상태 파일 제외
- 클립보드와 사용자 수동 복사 제외
- 일반 모드와 Protected Client 모드 모두 포함
- 동일 호스트에서 동시에 실행하는 Windows Sandbox 한 개

`직접 가능`은 상대 프로세스가 신원을 전송하지 않아도 운영체제의 공개된 네트워크 정보만으로 대상을 특정할 수 있음을 뜻합니다. `협조 시 가능`은 상대가 알려진 포트에서 응답하거나 등록 메시지를 보내야 함을 뜻합니다. `휴리스틱`은 후보를 찾을 수 있지만 해당 주소가 Windows Sandbox임을 보장하지 못하는 경우에 사용합니다.

`<Networking>Disable</Networking>` 상태에서는 게스트 네트워크 어댑터와 기본 경로가 사라졌습니다. 따라서 이 문서의 네트워크 디스커버리 방법을 적용할 수 없습니다. [네트워크 비활성화 시험 결과](README.ko.md#네트워킹-비활성화-비교-시험)

## 방향별 가능 여부

방향과 식별 대상에 따른 판정은 다음과 같습니다.

| 방향 | 식별 대상 | 피어 협조 없음 | 피어 협조 있음 | 판정 |
| --- | --- | --- | --- | --- |
| 호스트에서 Sandbox | IP 주소 | 이웃 캐시와 포트 스캔으로 후보 탐색 | 게스트 등록 연결의 원격 주소 확인 | 협조 시 가능, 무협조 시 휴리스틱 |
| 호스트에서 Sandbox | 컴퓨터 이름 | `.wsb` 조회 속성 없음, 이름 자체도 미확정 | 게스트가 `$env:COMPUTERNAME` 전송 | 협조 시 가능 |
| Sandbox에서 호스트 | IP 주소 | 기본 IPv4 경로의 `NextHop` 조회 | 같은 주소의 호스트 서비스 응답 확인 | 현재 구현에서 직접 가능 |
| Sandbox에서 호스트 | 컴퓨터 이름 | 게이트웨이 주소에 이름 정보 없음 | 호스트 응답에 컴퓨터 이름 포함 | 협조 시 가능 |

Windows Sandbox는 Hyper-V 기본 스위치를 사용하며 Protected Client는 RDP 세션의 보안 경계를 강화하는 별도 설정입니다. [Microsoft의 Windows Sandbox 기본 구성](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)과 [양방향 TCP 및 UDP 시험 결과](README.ko.md#sandbox에서-호스트-리스너로-향하는-역방향-시험)를 함께 보면 Protected Client 설정이 위 판정을 바꾸지 않았습니다.

## 호스트에서 Sandbox를 찾는 경로

호스트에는 실행 중인 Windows Sandbox의 현재 IP 주소를 반환하는 공개 `.wsb` 속성이 없습니다. Sandbox 컴퓨터 이름도 구성 파일에서 지정하거나 읽을 수 없습니다. 따라서 호스트가 아무런 게스트 협조 없이 정확한 Sandbox 엔드포인트를 얻는 일반적인 방법은 확인되지 않았습니다.

호스트의 IPv4 이웃 캐시는 주소 후보를 제시할 수 있습니다. Microsoft의 [`Get-NetNeighbor` 문서](https://learn.microsoft.com/powershell/module/nettcpip/get-netneighbor)는 이 명령이 IPv4 ARP 캐시의 IP 주소와 링크 계층 주소를 반환한다고 설명합니다. 다음 조회는 가상 네트워크에서 통신한 주소를 찾는 데 사용할 수 있습니다.

```powershell
Get-NetNeighbor -AddressFamily IPv4 |
    Where-Object State -in Reachable, Stale |
    Select-Object InterfaceAlias, IPAddress, LinkLayerAddress, State
```

이웃 캐시 항목은 트래픽 발생 여부와 캐시 상태에 의존합니다. Hyper-V VM, WSL, 컨테이너 등 다른 가상 엔드포인트가 같은 호스트에 있으면 해당 주소가 Windows Sandbox인지 구분하지 못합니다. 따라서 ARP 또는 이웃 캐시 조회는 디스커버리 완료가 아니라 후보 수집으로 판정합니다.

알려진 게스트 포트를 서브넷에서 스캔하고 애플리케이션 고유 응답을 검증하면 IP 주소를 찾을 수 있습니다. 게스트 리스너, 인바운드 방화벽 허용과 고유한 응답 표식이 모두 필요하므로 협조 기반 방법에 해당합니다. 열린 포트만 찾고 신원 표식을 검증하지 않으면 다른 가상 엔드포인트를 Sandbox로 오인할 수 있습니다.

컴퓨터 이름을 이미 알고 있을 때 DNS, LLMNR 또는 NetBIOS 이름 해석을 시도할 수 있습니다. 그러나 이름을 먼저 알아내는 기능이 아니며 세션의 현재 IP를 보장하지도 않습니다. 기존 시험에서는 같은 자동 생성 이름이 두 세션에 나타났지만 두 번째 세션에서 이전 IP가 반환되어 연결이 실패했습니다. [세션별 이름 해석 시험 기록](README.ko.md#2026년-8월-31일-시험-결과)

## Sandbox에서 호스트를 찾는 경로

Sandbox는 자체 라우팅 테이블에서 기본 IPv4 경로의 다음 홉을 읽을 수 있습니다. Microsoft의 [`Get-NetRoute` 문서](https://learn.microsoft.com/powershell/module/nettcpip/get-netroute)는 `0.0.0.0/0` 경로의 `NextHop`이 기본 게이트웨이라고 설명합니다. 다음 조회는 우선순위가 가장 높은 기본 게이트웨이를 선택합니다.

```powershell
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
    Where-Object NextHop -ne '0.0.0.0' |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1 -ExpandProperty NextHop
```

현재 시험에서는 일반 모드와 Protected Client 모드 모두 `172.26.160.1`을 반환했습니다. Sandbox는 이 주소의 호스트 TCP `18080`과 UDP `18081` 리스너에 접속했으며 호스트가 요청을 수신했습니다. [Sandbox에서 호스트로 향한 비교 결과](README.ko.md#sandbox에서-호스트-리스너로-향하는-역방향-시험)

Microsoft 문서는 Windows Sandbox가 Hyper-V 기본 스위치를 사용한다고 설명하지만 기본 경로의 다음 홉을 영구적인 Windows Sandbox 호스트 API로 규정하지 않습니다. 따라서 특정 주소를 고정값으로 저장하지 않고 세션마다 라우팅 테이블을 조회하는 방식으로 한정합니다. Hyper-V NAT는 내부 가상 스위치의 게이트웨이를 통해 VM을 호스트 네트워크에 연결합니다. [Microsoft Hyper-V NAT 설명](https://learn.microsoft.com/windows-server/virtualization/hyper-v/setup-nat-network)

기본 게이트웨이는 IP 주소만 제공합니다. PTR 레코드, DNS 접미사 또는 호스트 컴퓨터 이름을 제공한다는 보장은 없습니다. 게스트가 호스트 이름까지 요구하는 경우에는 알려진 포트의 호스트 서비스가 응답 데이터로 이름을 전달할 수 있습니다. 이번 역방향 시험에서는 호스트가 `rkttu-surface`를 응답에 포함했고 게스트가 이를 수신했습니다.

## 상호 협조가 있는 디스커버리

호스트가 Sandbox를 찾아야 할 때에는 게스트 시작 후 등록 연결을 보내는 방식이 가장 적은 가정을 사용합니다. 게스트는 기본 게이트웨이의 사전 합의된 TCP 또는 UDP 포트로 접속합니다. 호스트는 연결의 원격 주소에서 게스트 IP를 얻고 요청 본문에서 게스트 컴퓨터 이름과 프로토콜 버전을 받습니다.

Sandbox가 호스트를 찾아야 할 때에는 기본 게이트웨이 주소와 사전 합의된 포트를 사용합니다. 호스트는 응답에 컴퓨터 이름과 서비스 식별자를 포함합니다. 이로써 게스트는 DNS 역방향 조회 없이 호스트 신원을 확인할 수 있습니다.

이 방식은 파일 및 폴더 매핑을 사용하지 않습니다. 이 문서는 양쪽 프로세스를 시작하는 부트스트랩 방식을 범위에서 제외합니다. 게스트 쪽 등록 코드는 사용자가 직접 실행하거나 `.wsb`의 단일 `LogonCommand`에 내장하거나 네트워크에서 가져올 수 있습니다. Microsoft 문서는 `LogonCommand`가 Sandbox 로그인 후 명령 하나를 실행한다고 규정합니다. [Windows Sandbox LogonCommand 설명](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file#logon-command)

등록 메시지는 Sandbox의 자체 보고 이름만 신뢰하지 않고 세션별 임의 값과 애플리케이션 식별자를 함께 검증할 수 있습니다. 호스트가 관측한 원격 IP를 연결 주소로 사용하면 게스트가 잘못된 자체 IP를 보고하는 문제도 피할 수 있습니다.

## 발견 수단별 제약

이름과 주소 관련 수단을 다음과 같이 구분할 수 있습니다.

| 수단 | 얻을 수 있는 정보 | 한계 | 판정 |
| --- | --- | --- | --- |
| `.wsb` 구성 조회 | 네트워킹 활성화 여부 | 실행 중 IP와 컴퓨터 이름 속성 없음 | 불가능 |
| 게스트 기본 경로 | 호스트 측 게이트웨이 IP | 구현 변화 가능성, 이름 없음 | 현재 구현에서 가능 |
| 호스트 이웃 캐시 | 최근 통신한 IP와 MAC 후보 | Sandbox 신원 구분 불가 | 휴리스틱 |
| 알려진 포트 스캔 | 응답하는 게스트 IP 후보 | 리스너와 방화벽 허용 필요 | 협조 시 가능 |
| DNS, LLMNR, NetBIOS | 이미 알고 있는 이름의 주소 | 최초 이름 발견 불가, 캐시와 등록 상태 의존 | 보조 수단 |
| 게스트의 등록 연결 | 게스트 원격 IP와 자체 보고 이름 | 게스트 코드와 호스트 리스너 필요 | 협조 시 가능 |
| 호스트 서비스 응답 | 호스트 이름과 서비스 신원 | 알려진 게이트웨이 포트 필요 | 협조 시 가능 |
| HNS 또는 Hyper-V 내부 상태 | 내부 엔드포인트 후보 | Windows Sandbox용 공개 계약으로 확인되지 않음 | 비지원 구현 의존 |

Windows 이름 해석에는 DNS 외에도 LLMNR, WINS와 NetBIOS 계열이 포함됩니다. 이 프로토콜들은 이미 주어진 이름을 주소로 해석하는 기능이며 임의의 Windows Sandbox 이름을 열거하는 API로 작동하지 않습니다. [Microsoft Windows 이름 해석 개요](https://learn.microsoft.com/openspecs/windows_protocols/ms-wpo/f00add7f-a321-4a5f-a5d8-1748e748cd44)

DNS 클라이언트는 이전 질의 응답을 TTL 동안 캐시합니다. 이 동작 때문에 이름이 같고 IP가 바뀌는 짧은 수명 게스트에서는 이전 주소가 남을 수 있습니다. [Microsoft DNS 캐시 설명](https://learn.microsoft.com/windows-server/networking/dns/queries-lookups#dns-client-service-resolver)과 이번 세션별 시험이 같은 위험을 보여 줍니다.

## 자동 발견이 남기는 경계

여기까지 정리하면 파일 매핑과 Windows Sandbox CLI를 제외했을 때 Sandbox는 기본 경로를 통해 호스트 IP를 찾을 수 있습니다. 호스트 이름은 호스트 서비스가 응답에 포함할 때 얻을 수 있습니다. 반대 방향에서는 호스트가 게스트의 등록 연결을 받아야 IP와 컴퓨터 이름을 함께 확정할 수 있습니다.

피어 협조가 전혀 없으면 호스트는 이웃 캐시와 포트 스캔으로 게스트 IP 후보만 찾을 수 있으며 Sandbox 신원까지 보장하지 못합니다. DNS와 자동 생성 컴퓨터 이름도 세션 간 캐시 정합성을 보장하지 않습니다. 따라서 무협조 조건에서 직접 가능하다고 판정할 수 있는 범위는 Sandbox가 현재 기본 게이트웨이 IP를 읽는 경우로 좁혀집니다.

Protected Client 설정은 이 결론을 바꾸지 않았습니다. 네트워킹을 비활성화하면 기본 경로와 양방향 TCP 및 UDP 연결이 모두 사라지므로 네트워크 기반 디스커버리도 사용할 수 없습니다.
