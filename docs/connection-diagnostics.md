# 접속 지연 진단 로그

원격자 MDesk, 피원격자 MDesk/MDeskMini, 포터블 런처에서 자동 기록한다. 연결 정책과 준비 판정은 변경하지 않는다. 양쪽에 이 변경이 포함된 빌드를 배포해야 한다.

## 저장 및 수집

- Windows: `%LOCALAPPDATA%\MDesk\diagnostics`
- LOCALAPPDATA가 없는 환경: 시스템 임시 폴더 아래 `MDesk/diagnostics`
- Rust: `mdesk-diag-<실행시각>-<PID>.jsonl`
- Flutter UI: `mdesk-ui-diag-<실행시각>-<PID>.jsonl`
- 프로세스별 최대 2 MiB 파일 3개(현재 + 이전 2개). 새 실행에서 7일 이상 된 해당 형식의 파일을 정리한다. 여러 실행의 총량은 실행 횟수에 따라 늘 수 있다.
- 일반 Mini 로그와 달리 종료 후에도 유지된다. 비정상 종료 직전 비동기 큐에 남은 기록은 유실될 수 있다. 큐가 가득 차면 연결 처리를 막지 않고 버리며 다음 이벤트의 `dropped`로 알린다.
- SYSTEM/다른 계정으로 실행한 서비스의 로그는 해당 계정의 LOCALAPPDATA에 기록된다. 수집 도구는 지정한 한 폴더만 읽는다. 서비스 쪽 기록까지 필요하면 관리자 권한으로 해당 계정의 폴더를 별도 지정한다.

각 PC에서 PowerShell로 실행:

```powershell
.\RustCLI\collect_connection_diagnostics.ps1
```

기본으로 바탕화면에 ZIP을 만든다. `-LogDirectory`와 `-OutputPath`로 위치를 지정할 수 있다. 파일이 많거나 연결 중 순환되는 경우 원격 종료 후 수집하면 된다. 실행 중 수집한 파일의 마지막 JSON 행이 미완성이면 그 행만 제외한다.

기존 `MDeskMini_diagnostic.log`나 일반 앱 로그는 별도이며 민감한 값이 포함될 수 있다. 이 도구는 새 진단 JSONL만 수집한다. 새 진단 로그에는 원격 ID, 세션 ID, 서버 호스트/포트가 포함된다. 비밀번호·인증번호·접속 토큰·API 본문·원본 오류 문구·화면·키보드/클립보드 내용은 기록하지 않는다.

## 첫 실행/재실행 비교

1. 양쪽 시스템 시간을 맞추고 빌드 버전, 재부팅 여부를 기록한다.
2. 같은 실행 파일, 같은 인증번호 발급/복사 절차로 느린 첫 실행을 재현한다.
3. Mini를 완전히 종료한 뒤 빠른 재실행을 재현한다. 양쪽 ZIP을 각각 수집한다.
4. 하루 이틀 뒤 느린 현상이 재발했을 때도 같은 방법으로 수집한다. 7일 정리 또는 파일 순환 전에 보관한다.

`epoch_ms`는 UTC 기준 Unix 밀리초로 양쪽 타임라인을 맞출 때 사용한다. PC 시계 차이가 있으면 단방향 네트워크 시간을 이 값의 단순 차이로 계산하지 않는다. `process_ms`와 `duration_ms`는 각 프로세스 내 단조 시계 기반 경과 시간이다. `run`, `pid`, `version`으로 실행을 구분한다. Mini 자체 패키지 버전은 `mini process.version`의 `build`에 있다. UI 기록의 버전은 같은 PC의 Rust 기록을 참고한다.

`session`은 이벤트 문맥에 따라 접속 세션 ID, 릴레이 UUID, 호스트 내부 연결 번호, 화면 번호다. `controller`의 `connect`/`login`/`video`와 `host`의 `login`/`video`는 로그인 프로토콜의 같은 세션 ID로 묶는다. `host login.received.local_id`가 호스트 내부 연결 번호를 연결한다. 릴레이는 양쪽의 UUID로 묶고, 호스트의 `relay.socket_ready.local_port`와 `transport.accepted.local_port`로 같은 프로세스의 보안 협상 기록을 연결한다. `secure_handshake` 원격자 이벤트의 session은 대상 peer ID다. UI 클릭은 원격 ID와 시각으로 Rust 접속 이벤트와 비교한다.

## 단계별 해석

| 로그 | 확인할 지연 |
|---|---|
| launcher `unpack.begin/end`, `unpack.cache`, `child.spawn` | 패키지 초기화/해시 확인/압축 해제와 자식 실행. 운영체제가 런처를 시작하기 전 지연은 기록할 수 없으므로 클릭 시각을 따로 기록한다. |
| mini `runtime.*`, `cert.clipboard.*`, `cert.verify.*` | 초기화와 인증 API. 재실행 때 인증번호가 없어 단계를 건너뛰는지 확인한다. |
| mini `portable_service.*`, `server.spawn` | SYSTEM 서비스 준비가 서버 시작을 얼마나 지연시키는지 확인한다. |
| host `registration.*`, mini `rendezvous.*` | 등록 시작/성공, 공개키 재요청, UDP timeout, 등록 대기. 서버 선택과 등록 방식도 기록된다. |
| mini `readiness.http_*`, `readiness.ready_*` | 준비 완료 API 요청·응답, 상태 코드·재시도. 해당 단계가 제공하는 소요 시간을 기록한다. |
| mini `startup.progress`의 `progress`, `registered` | 진행률 100% 표시 당시에도 `registered=false`인지 확인한다. 화면 문구/본문은 복사하지 않는다. |
| controller_ui `readiness.poll.*`, `ready_dialog.*`, `connect.clicked/dispatched` | API 폴링 지연, 표시/클릭 시 준비 상태, 자동/수동 경로 차이. |
| controller `server.lookup`, `network.prepare`, `id_server.connect`, `rendezvous.*`, `relay.*` | 서버 조회, 네트워크 준비, 직접 연결·릴레이 전환과 오프라인 재시도. |
| 양쪽 `secure_handshake`, controller `intent.prepare`, `login.send`, host `login.received/authorized/response/rejected` | 보안 협상, 감사 API, 인증/승인 및 로그인 응답 준비. |
| host `capture.initialize`, `encoder.initialize/ready`, `video.first_queued/first_sent` | 화면 캡처·인코더 준비, 최초 송신. 화면 번호 단위이며 여러 세션에서 공유될 수 있다. |
| controller `video.first_received/first_decoded` | 최초 영상 도착과 디코딩 완료. 실제 모니터에 표시된 시각을 측정하는 것은 아니다. |
| 10초마다 `video.sample` | 원격자: 수신 byte/s, 화면별 실제 FPS, decode_fps, 큐 길이, 코덱. 피원격자: 기존 프로토콜의 delay_ms, QoS 목표 FPS, bitrate. 실제 FPS와 목표 FPS는 구분한다. |

`*.end.result=incomplete`는 오류, 조기 반환 또는 취소로 성공 지점에 도달하지 못한 단계다. `ended`는 수명 관찰 구간 종료이며 성공을 뜻하지 않는다. 오류는 `reason`의 제한된 분류로 남긴다. 정보가 부족한 오류를 알아내기 위해 원본 오류/응답을 이 로그에 추가하지 않는다.

이 로그는 네트워크 패킷 캡처나 서버 부하 지표를 대신하지 않는다. 백신 검사, 서버 API/DB 내부 처리, hbbr 대역폭 제한은 해당 구간의 지연을 찾은 뒤 별도 측정한다.
