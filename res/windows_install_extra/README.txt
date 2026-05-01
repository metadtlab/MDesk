[MDesk Windows 추가 설치 파일]

이 폴더에 넣은 파일·하위폴더는 빌드 시
  flutter\build\windows\x64\runner\Release\
로 복사됩니다(하위 구조 유지).

DeviceRemote.exe 는 반드시 다음에 두세요.
  res\windows_install_extra\tools\DeviceRemote.exe
→ 설치 후 경로: C:\Program Files\MDesk\tools\DeviceRemote.exe

MSI 설치(preprocess + 빌드) 또는 포터블 패커가 Release 폴더 전체를 묶습니다.
MSI 전처리 시 입력 폴더는 반드시 Flutter Release 출력이어야 하며,
build.py 의 build_msi 기본값은 저장소 기준 flutter/build/windows/x64/runner/Release 입니다.

※ 저장소에 바이너리를 올리지 않을 경우, 로컬에서만 이 폴더에 파일을 두고 빌드하세요.
