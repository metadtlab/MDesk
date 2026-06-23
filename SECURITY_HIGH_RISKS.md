# 높은 등급 보안 이슈 설명서

이 문서는 현재 프로젝트에서 확인된 높은 등급 보안 이슈 3가지를 초보자도 이해할 수 있도록 정리한 문서입니다.

실제 GitHub 토큰 값은 일부러 적지 않았습니다. 보안 문서에도 비밀값을 남기면 또 다른 유출 경로가 됩니다.

## 한눈에 보는 결론

| 번호 | 이슈 | 왜 위험한가 | 우선 조치 |
| --- | --- | --- | --- |
| 1 | GitHub PAT가 로컬 Git remote URL에 포함됨 | 토큰을 본 사람이 저장소에 접근하거나 코드를 바꿀 수 있음 | remote URL에서 제거, 노출 가능성이 있으면 토큰 폐기 |
| 2 | Flutter HTTP가 모든 TLS 인증서를 허용함 | 가짜 서버도 진짜 서버처럼 받아들여 토큰과 응답이 탈취될 수 있음 | `badCertificateCallback` 제거 |
| 3 | Rust HTTP/WebSocket이 인증서 실패 시 invalid cert를 자동 허용함 | 연결 실패가 보안 실패로 끝나지 않고, 검증 없는 연결로 바뀔 수 있음 | 자동 재시도와 `NoVerifier` 경로 제거 |

## 배경 지식: TLS 인증서는 무엇인가

앱이 `https://admin.787.kr` 같은 서버에 접속할 때 TLS 인증서는 서버의 신분증 역할을 합니다.

예를 들어 사용자가 은행에 들어갔는데, 입구에서 누군가 "제가 은행 직원입니다"라고 말한다고 생각하면 됩니다. 정상적인 앱은 그 사람의 신분증을 확인합니다. 그런데 현재 일부 코드는 신분증이 틀려도 "괜찮다"고 처리합니다.

이렇게 되면 공격자가 중간에서 가짜 서버를 세워도 앱이 속을 수 있습니다. 이것을 보통 MITM, 즉 중간자 공격이라고 부릅니다.

## 1. GitHub PAT가 로컬 Git remote URL에 포함됨

### 위치

- `.git/config` line 21
- `mdesk` remote URL에 `ghp_...` 형식의 GitHub Personal Access Token이 포함되어 있음

### 초보자용 설명

GitHub PAT는 비밀번호와 비슷합니다. 특히 저장소 권한이 있는 PAT라면, 그 토큰을 가진 사람은 GitHub에서 코드를 읽거나 수정하거나 푸시할 수 있습니다.

Git remote URL은 보통 다음처럼 생겨야 합니다.

```text
https://github.com/metadtlab/MDesk.git
```

그런데 여기에 토큰이 들어가면 다음과 같은 형태가 됩니다.

```text
https://<TOKEN>@github.com/metadtlab/MDesk.git
```

이 상태에서는 누군가가 로컬 파일, 터미널 로그, 화면 공유, 백업 파일, 진단 로그를 통해 remote URL을 보면 토큰도 같이 보게 됩니다.

### 공격 예시

1. 개발자가 문제를 해결하려고 터미널에서 remote URL을 출력합니다.
2. 출력 결과에 PAT가 포함됩니다.
3. 그 로그를 메신저, 이슈, 원격지원 화면, 캡처 이미지로 공유합니다.
4. 토큰을 본 공격자는 GitHub API나 Git 명령으로 저장소에 접근합니다.
5. 권한이 충분하면 악성 코드를 푸시하거나, 소스코드를 내려받거나, 릴리스 빌드에 영향을 줄 수 있습니다.

원격 데스크톱 앱에서는 이 위험이 더 큽니다. 공격자가 코드나 배포물에 손을 대면 사용자의 화면, 키보드 입력, 파일 전송 흐름까지 영향을 받을 수 있기 때문입니다.

### 바로 해야 할 조치

1. 로컬 remote URL에서 토큰을 제거합니다.

```powershell
git remote set-url mdesk https://github.com/metadtlab/MDesk.git
```

2. 실제 유출 정황이 없고, 터미널 로그나 캡처 이미지에도 토큰이 노출된 적이 없다면 이 수정만으로 1차 조치는 충분할 수 있습니다.
3. 토큰이 화면 공유, 로그, 이슈, 메신저, 백업 파일 등에 노출되었거나 노출 여부가 불확실하면 GitHub에서 해당 PAT를 폐기하고 새로 발급합니다.
4. 새 PAT를 만들 경우 권한은 최소한으로 제한합니다.
5. GitHub CLI 또는 Git Credential Manager 같은 인증 저장소를 사용합니다.

```powershell
gh auth login
```

5. 토큰이 남아 있는지 확인합니다. 공유 로그에 실제 토큰이 찍히지 않도록 아래처럼 검사만 하는 방식을 권장합니다.

```powershell
$config = Get-Content -LiteralPath ".git\config"
if ($config -match "ghp_") { "PAT still exists" } else { "PAT not found" }
```

### 고친 뒤 기대 상태

`mdesk` remote URL은 토큰 없는 GitHub URL이어야 합니다.

```text
https://github.com/metadtlab/MDesk.git
```

## 2. Flutter HTTP가 모든 TLS 인증서를 허용함

### 위치

- `flutter/lib/utils/http_service.dart` line 51
- `flutter/lib/models/server_model.dart` line 67
- `flutter/lib/desktop/pages/simple_home_page.dart` line 618

### 현재 수정 상태

MDesk Flutter의 위 3곳은 플랫폼 기본 TLS 인증서 검증을 사용하도록 수정했습니다. 이 항목은 같은 문제가 왜 위험했는지와, 다시 생기지 않게 점검할 기준으로 남겨둡니다.

MDeskMini와 RustCLI의 `danger_accept_invalid_certs(true)` 사용은 Flutter의 `badCertificateCallback`과는 별도 코드 경로입니다. 한 번에 묶어 수정하기보다 별도 테스트 범위로 나누어 처리하는 것이 안전합니다.

문제 패턴은 아래와 같습니다.

```dart
badCertificateCallback = (X509Certificate cert, String host, int port) {
  return true;
};
```

### 초보자용 설명

`badCertificateCallback`은 서버 인증서가 이상할 때 호출됩니다. 정상적인 앱은 이 상황에서 연결을 끊어야 합니다.

그런데 `return true`는 "인증서가 이상해도 계속 연결해도 된다"는 뜻입니다.

비유하면 다음과 같습니다.

- 정상 처리: 신분증이 위조된 사람은 출입 금지
- 현재 처리: 신분증이 위조되어도 무조건 출입 허용

HTTPS를 사용해도 인증서 검증을 무시하면 HTTPS의 핵심 보호 기능이 사라집니다.

### 공격 예시

1. 사용자가 공용 와이파이에 접속합니다.
2. 공격자가 같은 네트워크에서 가짜 `admin.787.kr` 서버처럼 동작합니다.
3. 앱은 가짜 서버의 인증서를 보고 "이상하다"고 감지합니다.
4. 하지만 코드가 `return true`를 반환하므로 연결을 계속합니다.
5. 앱이 Bearer token, 사용자 정보, 장치 등록 정보, 응답 데이터를 가짜 서버와 주고받을 수 있습니다.
6. 공격자는 토큰을 훔치거나, 서버 응답을 바꿔 앱 동작을 조작할 수 있습니다.

### 특히 위험한 이유

이 프로젝트에는 Bearer token 기반 API 호출이 있습니다. 인증서 검증을 끄면 토큰이 안전한 HTTPS 터널 안에 있는 것이 아니라, 공격자가 만든 가짜 터널로 들어갈 수 있습니다.

토큰이 유출되면 공격자는 사용자인 척 API를 호출할 수 있습니다.

### 바로 해야 할 조치

1. 운영 코드에서 `badCertificateCallback`을 제거합니다.
2. 자체 서명 인증서가 필요한 개발 환경이라면 운영 빌드에서는 절대 켜지지 않도록 분리합니다.
3. 개발용 예외가 꼭 필요하면 다음 조건을 모두 만족해야 합니다.

- debug 빌드에서만 허용
- 특정 개발 서버 host에서만 허용
- 사용자 토큰이나 운영 계정 정보는 절대 사용하지 않음
- 로그에 경고를 남김

### 피해야 할 수정

아래처럼 단순히 주석만 바꾸거나 로그만 추가하는 것은 해결이 아닙니다.

```dart
return true;
```

이 줄이 남아 있으면 인증서 검증은 여전히 꺼져 있습니다.

### 고친 뒤 기대 상태

운영 빌드에서는 인증서가 유효하지 않으면 연결이 실패해야 합니다.

```dart
HttpClient _createSecureHttpClient() {
  return HttpClient();
}
```

개발용 예외가 필요하면 운영 빌드와 분리된 명확한 조건문이 있어야 합니다.

## 3. Rust HTTP/WebSocket이 인증서 실패 시 invalid cert fallback을 사용할 수 있음

### 위치

- `src/hbbs_http/http_client.rs` line 155
- `src/hbbs_http/http_client.rs` line 166
- `libs/hbb_common/src/websocket.rs` line 116
- `libs/hbb_common/src/websocket.rs` line 127
- `libs/hbb_common/src/verifier.rs` line 251
- `libs/hbb_common/src/tls.rs` line 5

### 현재 수정 상태

공식 서비스 도메인에서는 invalid cert fallback이 적용되지 않도록 수정했습니다.

- `787.kr`
- `admin.787.kr`
- `mdesk.imedixerp.co.kr`
- 그 외 `787.kr`, `imedixerp.co.kr` 하위 도메인

사설 서버 호환성을 위해 `allow-insecure-tls-fallback` 옵션 자체는 유지했습니다. 즉, 개인이 자체 서명 인증서로 사설 중계서버를 운영하는 경우에는 기존 옵션을 사용할 수 있지만, MDesk 공식 서비스 도메인에서는 옵션이 켜져 있어도 인증서 검증 우회를 하지 않습니다.

문제 흐름은 다음과 같습니다.

1. Rustls로 정상 TLS 연결을 시도합니다.
2. 인증서 문제 등으로 연결이 실패합니다.
3. `allow-insecure-tls-fallback` 옵션이 켜진 경우, 실패를 보안 오류로 끝내지 않을 수 있습니다.
4. `Some(true)` 또는 `danger_accept_invalid_cert` 경로로 다시 시도할 수 있습니다.
5. `NoVerifier`를 사용하면 인증서 검증이 사실상 꺼집니다.

### 초보자용 설명

이 문제는 Flutter의 `return true` 문제와 비슷하지만 더 숨어 있습니다.

Flutter에서는 인증서가 이상해도 바로 허용합니다. Rust 쪽에서는 먼저 정상 연결을 시도한 뒤, 실패하면 "그럼 인증서 검증을 약하게 해서 다시 해보자"는 흐름이 있습니다.

보안 관점에서는 이 옵션을 공식 서비스에 적용하면 위험합니다. 인증서 실패는 단순한 네트워크 오류가 아니라 공격 신호일 수 있기 때문입니다.

### 공격 예시

1. 앱이 원격 서버와 WebSocket 또는 HTTP 연결을 시작합니다.
2. 공격자가 중간에서 TLS 인증서를 바꿔치기합니다.
3. 첫 번째 Rustls 연결은 실패합니다.
4. 사설 서버용 fallback 옵션이 공식 서비스에도 적용되면 invalid cert 허용 모드로 다시 시도합니다.
5. 두 번째 연결이 공격자의 가짜 인증서를 받아들일 수 있습니다.
6. 이후 통신이 공격자에게 노출되거나 조작될 수 있습니다.

원격 데스크톱 앱에서는 WebSocket이나 서버 연결이 화면, 입력, 세션 제어, 장치 등록 같은 민감한 기능과 연결될 수 있습니다. 따라서 인증서 검증 우회는 단순 API 앱보다 더 큰 위험입니다.

### `NoVerifier`가 위험한 이유

`NoVerifier`는 이름 그대로 서버 인증서를 검증하지 않는 역할입니다.

정상적인 TLS는 다음을 확인합니다.

- 이 서버가 내가 접속하려던 서버가 맞는지
- 인증서가 신뢰할 수 있는 기관에서 발급되었는지
- 인증서가 만료되지 않았는지
- 도메인 이름이 인증서와 일치하는지

`NoVerifier`를 사용하면 이 확인이 사라집니다. 그러면 공격자가 만든 인증서도 받아들일 수 있습니다.

### 바로 해야 할 조치

1. 공식 서비스 도메인에서는 인증서 실패 시 invalid cert 허용 모드로 재시도하지 않습니다.
2. 공식 서비스 도메인에서는 `NoVerifier` 경로가 호출되지 않게 막습니다.
3. 사설 인증서가 꼭 필요한 서버라면 다음 중 하나를 사용합니다.

- 서버 인증서를 정상 CA에서 발급
- 사내 CA를 클라이언트 신뢰 저장소에 등록
- 인증서 fingerprint pinning 적용
- 사용자가 명시적으로 확인한 fingerprint만 저장

4. 사용자의 명시 동의가 필요한 경우에도 다음 조건을 지켜야 합니다.

- 어떤 서버의 어떤 fingerprint를 신뢰하는지 화면에 표시
- 한 번의 네트워크 실패만으로 자동 동의하지 않음
- 운영 서버 기본값은 항상 거부
- 동의 내역을 설정에서 삭제할 수 있게 함

### 피해야 할 수정

아래 방식은 보안 문제를 그대로 남깁니다.

- 로그 메시지만 바꾸기
- 함수 이름만 안전해 보이게 변경하기
- `danger_accept_invalid_cert` 기본값을 다른 곳에서 다시 `true`로 설정하기
- 인증서 검증 실패를 일반 연결 실패처럼 조용히 무시하기

### 고친 뒤 기대 상태

인증서 검증 실패는 기본적으로 연결 실패로 끝나야 합니다.

```text
TLS certificate validation failed -> connection rejected
```

예외가 필요하다면 자동 예외가 아니라 명시적이고 기록 가능한 예외여야 합니다.

## 수정 우선순위

1. GitHub PAT를 remote URL에서 제거하고, 노출 가능성이 있으면 폐기
2. Flutter의 `badCertificateCallback return true` 제거
3. 공식 서비스 도메인에서 Rust HTTP/WebSocket의 invalid cert fallback 차단
4. 공식 서비스 도메인에서 `NoVerifier`가 사용되지 않도록 차단
5. 인증서 예외가 정말 필요한 개발 환경은 별도 설정으로 분리

## 점검 체크리스트

### GitHub PAT

- [ ] `.git/config`에서 PAT를 제거했다.
- [ ] 토큰이 외부에 노출된 정황이 없음을 확인했다.
- [ ] 노출 가능성이 있거나 확신할 수 없다면 기존 PAT를 GitHub에서 폐기했다.
- [ ] 새 PAT를 만들었다면 권한을 최소화했다.
- [ ] `.git/config`에 `ghp_`가 남아 있지 않다.
- [ ] remote URL이 토큰 없는 URL이다.
- [ ] 팀 문서, 이슈, 로그, 캡처 이미지에 토큰이 노출되지 않았는지 확인했다.

### Flutter TLS

- [ ] 운영 코드에 `badCertificateCallback`이 남아 있지 않다.
- [ ] `return true`로 모든 인증서를 허용하는 코드가 없다.
- [ ] 개발용 자체 서명 인증서 예외는 debug 전용이다.
- [ ] Bearer token을 보내는 API 호출은 정상 인증서 검증을 통과해야만 실행된다.

### Rust TLS

- [ ] 공식 서비스 도메인에서는 인증서 실패 시 `Some(true)`로 재시도하지 않는다.
- [ ] 공식 서비스 도메인에서는 `NoVerifier`가 운영 경로에서 호출되지 않는다.
- [ ] 공식 서비스 도메인에서는 `danger_accept_invalid_cert` 값이 `true`로 캐시되지 않는다.
- [ ] 사설 인증서가 필요하면 pinning 또는 신뢰 저장소 방식으로 처리한다.
- [ ] 사설 서버용 insecure fallback 옵션은 기본값이 꺼져 있다.

## 짧은 요약

이 세 이슈는 모두 "신뢰하면 안 되는 것을 신뢰한다"는 공통점이 있습니다.

- PAT 노출: 코드를 바꿀 수 있는 비밀 열쇠를 remote URL에 둔 상태
- Flutter TLS 우회: 가짜 서버의 신분증도 무조건 받아주는 상태
- Rust TLS 우회: 사설 서버용 fallback이 공식 서비스에도 적용될 수 있던 상태

가장 먼저 토큰을 remote URL에서 제거하고, 그 다음 공식 서비스 통신에서 인증서 검증 우회를 제거하는 것이 안전합니다.
