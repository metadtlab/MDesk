# MDesk Linux 컴파일·배포 — 787.kr

## 평소에는 한 번만 실행

프로젝트 루트의 **`build_linux.bat`를 더블클릭**한다.

1. 현재 Windows 프로젝트 소스를 WSL 빌드 폴더에 동기화한다.
2. Rust와 Flutter를 릴리스 빌드하고 Ubuntu 24.04 amd64용 .deb를 만든다.
3. 서명 키를 자동 생성하거나 기존 키를 재사용한다.
4. 서명된 APT 저장소와 설치 안내 페이지를 준비한다.

업로드할 폴더는 항상 다음 위치다.

```text
D:\IMedix\Rust\rustdesk\dist\linux-publish\upload\linux
```

더블클릭 실행이 성공하면 결과 폴더도 자동으로 열린다. 이 폴더 **안의 내용**을 `https://787.kr/linux/`에 대응하는 서버 폴더에 올린다. 서버 업로드는 사용자가 처리한다.

`publish-linux.bat`만 더블클릭하면 **마지막으로 성공한 빌드**로 업로드 폴더를 다시 만든다. 성공한 빌드가 없으면 컴파일부터 수행한다. 소스를 수정하고 새 바이너리를 만들 때는 `build_linux.bat`를 실행한다. 파일 선택 창이나 수동 키 생성은 기본 흐름에 없다.

## 설정과 도구

처음 실행하면 `publish-linux.example.json`에서 Git에 포함되지 않는 `publish-linux.local.json`을 만들고, 자동 생성한 키의 지문도 저장한다. 현재 개발 PC는 WSL `Ubuntu`, 사용자 `owner`, Ubuntu 24.04를 사용한다.

- Rust: WSL에 설치된 `stable` 툴체인. 시스템의 기본 Rust 버전을 바꾸지 않는다.
- Flutter: `~/flutter_linux_3.41.9_sdk/flutter`.
- vcpkg: `~/vcpkg-rustdesk`.
- 빌드 폴더: `~/mdesk-builds/linux-release`.
- 컴파일 동시 작업 수: 6.
- 게시 도구: Python 3.11+, GnuPG, apt-utils. 빌드에는 기존 Linux 개발 도구와 rsync가 필요하다.

현재 PC의 준비된 도구를 사용한다. 다른 PC에서는 WSL/개발 도구를 먼저 준비하고 로컬 JSON의 경로를 맞춘다. 빌드 폴더는 `~/mdesk-builds/` 아래 전용 폴더만 사용하며, 다른 용도로 쓰던 폴더를 자동 덮어쓰지 않는다. Windows 원본 소스와 Windows 빌드 산출물은 동기화 대상으로 덮어쓰지 않는다.

빌드 캐시는 WSL에 남아 다음 빌드에서 재사용된다. Debian 버전은 `Cargo.toml` 버전 + `build_number.txt` + 빌드 시각으로 자동 생성한다. 예: `1.6.3.557+linux.20260927055052392758`. Windows의 빌드 번호 파일을 증가시키지는 않는다.

## 자동 서명 키

자동 생성 키는 **반복 암호 입력 없이 서명하도록 암호를 설정하지 않으며**, WSL의 `~/.local/share/mdesk-publish/gnupg`와 Linux 사용자 권한(디렉터리 700)으로 보호한다. 이 개발 PC에 접근 가능한 사용자는 서명 권한을 가질 수 있다. 개인키와 폐기 인증서는 웹 결과에 포함하지 않는다.

개인키는 별도로 안전하게 백업한다. WSL 삭제 시 키도 사라질 수 있다. `publish-linux.local.json`, 빌드/게시 상태도 유지한다. 기존 게시 키를 잃어버렸을 때 새 키로 조용히 교체하지 않고 중단한다.

키는 2년 만료로 생성한다. 만료 전에 기존 키 기간을 연장하고 공개키를 다시 게시해야 한다. 고객은 설치 스크립트를 다시 실행해 같은 지문의 공개키를 갱신할 수 있다. 매번 키를 새로 만들지 않는다.

이미 암호가 설정된 키를 로컬 JSON에 지정한 경우 그 키를 유지하며, GPG 에이전트에 따라 암호 입력이 필요할 수 있다. 수동 암호 키를 처음 만들고 싶은 경우에만 아래 고급 옵션을 쓴다.

## 선택 옵션

```bat
build_linux.bat -BuildOnly
publish-linux.bat "D:\release\mdesk.deb"
publish-linux.bat -Check
publish-linux.bat -InitKey
publish-linux.bat -Help
```

`-BuildOnly`는 .deb까지만 생성한다. 명시한 .deb는 패키지 이름/아키텍처/버전을 검증한 뒤 게시한다. `-InitKey`는 새 암호 보호 키를 수동 생성하는 선택 기능이며 자동 키가 이미 있으면 재생성하지 않는다.

사용자 설정은 `-Config "D:\settings\mdesk.json"`으로 지정한다. 상대 출력 경로는 JSON이 있는 폴더 기준이고, 설정 경로는 WSL 기준이다.

## 결과와 실패 처리

```text
dist/linux-build/
  MDesk-<자동버전>-ubuntu24.04-amd64.deb
  latest.json                        # 마지막 성공 빌드와 SHA256
dist/linux-publish/
  latest.json                        # 마지막 성공 서명 결과
  upload/
    UPLOAD.txt                       # 서버 업로드 안내
    linux/                           # 이 안의 내용만 공개
      index.html
      install-mdesk.sh
      mdesk.sources
      mdesk-archive-keyring.asc
      mdesk-archive-keyring.gpg
      SIGNING-KEY.txt
      SHA256SUMS
      SHA256SUMS.asc
      dists/noble/InRelease
      dists/noble/Release
      dists/noble/Release.gpg
      dists/noble/main/binary-amd64/Packages*
      dists/noble/main/binary-amd64/by-hash/...
      pool/main/m/mdesk/*.deb
  releases/<시간-고유번호>/...        # 보관용 완료 결과
```

빌드 실패 시 이전 빌드를 새 빌드로 게시하지 않는다. 최신 빌드 파일을 바꾸거나 삭제했으면 체크섬 오류로 중단한다. 같은 Debian 버전에 다른 내용을 덮어쓰거나 낮은 버전으로 게시하는 것도 거부한다.

업로드 폴더는 서명과 검증이 끝난 결과로 교체한다. 중간 `upload.next-*` 폴더를 올리지 않는다. 기존 패키지와 by-hash 색인은 새 결과에도 보존하므로 `dist/linux-publish`를 유지/백업한다. 자동 정리로 고객이 다운로드 중인 파일을 지우지 않는다.

## 서버에 올리기

첫 배포는 완성된 `upload/linux` 내용을 업로드한다. 업데이트에서는 패키지와 by-hash 파일을 먼저, 일반 색인과 공개 파일을 다음에, `Release`와 `Release.gpg`, **`InRelease`를 마지막에** 올린다. 마지막 파일은 임시 이름으로 올린 뒤 같은 폴더에서 이름을 바꿔 교체한다. 기존 pool/by-hash 파일은 삭제하지 않는다.

파일 관리자가 원자적 교체를 지원하지 않으면 완성된 전체 폴더를 별도 위치에 올린 다음 웹 경로를 전환한다. URL은 로그인 없이 정적 파일을 그대로 반환해야 한다. SPA의 HTML로 대체하면 안 된다. 서명 메타데이터/설치 스크립트/공개키에는 `Cache-Control: no-cache`, pool/by-hash에는 장기 캐시를 사용할 수 있다.

현재 메타데이터에는 `Valid-Until`을 두지 않는다. 오래 배포하지 않아도 설치할 수 있지만, 과거 메타데이터 재전송에 대한 시간 제한은 없다. 시간 제한이 필요하면 정기 재서명·게시 운영도 함께 추가해야 한다.

## 고객 설치·업데이트

서버에 업로드한 뒤 Ubuntu 24.04 또는 26.04 LTS amd64(x64)에서:

```bash
curl -fsSLo install-mdesk.sh https://787.kr/linux/install-mdesk.sh
sudo bash install-mdesk.sh
```

설치 스크립트는 공개키 지문을 확인하고 전용 `Signed-By` 키링으로 APT 저장소를 등록한 뒤 MDesk와 `rustdesk` 서비스를 설치/활성화한다. 최초 스크립트와 지문의 신뢰는 HTTPS 배포 경로에 의존한다.

패키지는 Ubuntu 24.04에서 빌드해 24.04와 26.04에 배포한다. MDesk 전용 저장소의 `noble` 이름은 이 빌드 기준을 나타내며 Ubuntu 시스템 저장소를 24.04로 바꾸지 않는다. 26.04의 패키지 의존성 설치·공유 라이브러리 로딩·버전 명령은 격리된 컨테이너에서 검증했다. GUI와 로그인 전 원격 연결은 실제 데스크톱에서 확인해야 한다. 지원하지 않는 버전이나 아키텍처이면 설치 스크립트가 감지한 OS 정보를 표시하고 중단한다.

```bash
sudo apt-get update
sudo apt-get install --only-upgrade mdesk
systemctl is-active rustdesk
```

저장소 등록만으로 무인 자동 업데이트를 설정하지 않는다. 기존 앱 내 업데이트 경로도 바뀌지 않는다. 로그인 전 원격의 디스플레이 매니저/X11 요구 사항은 별도다.

직접 받은 .deb의 로컬 설치는 APT 저장소 서명 검증 경로를 거치지 않는다. 수동 검증은 신뢰된 공개키로 `SHA256SUMS.asc`를 검증한 뒤 파일 해시를 비교한다. App Center의 로컬 .deb 경고가 사라진다는 의미는 아니다.

검증 도구 `tools/linux-publish/test_publish_linux.py`는 일회용 키/격리된 APT 경로를 사용한다. 시스템 패키지는 설치하지 않는다.

참고: [Debian apt-secure](https://manpages.debian.org/trixie/apt/apt-secure.8.en.html), [apt-ftparchive](https://manpages.debian.org/trixie/apt-utils/apt-ftparchive.1.en.html).
