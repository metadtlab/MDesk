# MDeskMini

`MDeskMini` is a standalone host application beside `RustCLI`, built with the
shared MDesk engine. Mini's startup and UI live here; capture and codec code are
shared with the main application.

## Build (Windows 10/11 x64)

```powershell
cd D:\IMedix\Rust\rustdesk\MDeskMini
.\build_release.bat
```

- Default **B3** includes hardware H.264/H.265 codec support and the Windows VRAM path in the embedded MDesk engine.
- The build uses the root project's native dependency preflight, then explicitly targets `x86_64-pc-windows-msvc`. Missing GPU libraries are prepared under the repository's `.deps/vcpkg` rather than silently building without acceleration.
- Final UPX-compressed executable: `target\release\mdeskmini.exe`.
- Cargo's uncompressed executable is retained at `target\x86_64-pc-windows-msvc\release\mdeskmini.exe`. Each build copies it before packaging, so repeated builds do not repack an already compressed file.
- `build_release.bat --build-only` builds and verifies the executable without UPX compression.
- Both modes check the administrator manifest and the final executable's linked-engine capabilities. The capability probe uses the existing administrator manifest, so Windows may request UAC confirmation during verification.
- The final SHA256 and capabilities are written to `target\release\mdeskmini.exe.capabilities.json`.
- Sign the final executable **after** UPX packaging; rerun the capability verifier if a hash for the signed file is needed.

Select a comparison build in PowerShell:

```powershell
$env:MDESK_BUILD_VARIANT = 'B1' # software only
.\build_release.bat --build-only
$env:MDESK_BUILD_VARIANT = 'B2' # hardware codec, no VRAM path
.\build_release.bat --build-only
$env:MDESK_BUILD_VARIANT = 'B3' # hardware codec + VRAM (default)
.\build_release.bat
```

Plain `cargo build --release` and the separate Windows 7 scripts remain software-only for compatibility. The unified x86 script described below includes hardware codecs but only allows them on Windows 10+. For a manually prepared modern x64 toolchain, use `cargo build --release --target x86_64-pc-windows-msvc --features hwcodec,vram`. The batch script is recommended because it also prepares and verifies native dependencies. Mini's lockfile retains `system_shutdown 4.0.1` for Windows 7.

## Build (one 32-bit application for Windows 7 SP1 / 10 / 11)

```powershell
cd D:\IMedix\Rust\rustdesk\MDeskMini
# B2 is selected when MDESK_BUILD_VARIANT is not set.
.\build_release_32bit.bat
# Build and verify without creating the ZIP:
.\build_release_32bit.bat --build-only
```

- The same EXE uses software codecs on Windows 7 and permits hardware codecs on Windows 10 or newer, subject to the GPU, driver, peer and saved settings.
- Default **B2** includes hardware codecs; VRAM is excluded. B1 remains available for software-only comparison. B3 is rejected by this unified x86 script.
- Target: `i686-win7-windows-msvc`, with Rust's standard library rebuilt for Win7 and PE minimum OS/subsystem `6.1`. This is not just a PE-header change. See [Rust's Win7 target documentation](https://doc.rust-lang.org/rustc/platform-support/win7-windows-msvc.html).
- Final EXE: `target\windows-x86\mdeskmini.exe`; capability report: `mdeskmini.exe.capabilities.json` beside it. Distribution ZIP: `target\windows-x86\MDeskMini-x86.zip`. Extract the ZIP before running the EXE.
- Cargo output: `target\i686-win7-windows-msvc\release\mdeskmini.exe`. Packaging retains the native EXE and verifies that both ZIP entries match the original EXE/report hashes.
- The old `target\win10-x86` artifacts were built with minimum Windows 10 and are not the corrected unified build.
- UPX is disabled for this x86 pipeline. The earlier Windows-10-only x86 build failed to load after UPX 5.1.1 compression (`0xC000007B`), despite passing UPX's integrity test. ZIP distribution avoids changing the executable structure. x64 packaging is unchanged.
- x86 native libraries use `.deps/vcpkg-x86`, independently of the x64 installation. A complete configured x86 native root can be used read-only.
- The existing dedicated Win7 build scripts remain separate software-only alternatives.

At every entry point, including portable-service and codec discovery children, Mini detects the Windows version before host initialization. Windows below 10, or an unknown version, disables GPU codec selection, cached GPU capabilities and discovery for that process. This does not write `enable-hwcodec=N` to saved settings. An explicit disabled preference remains respected on Windows 10+.

The capability report separates compiled support (`hwcodec`) from OS eligibility (`hwcodec_os_allowed`, `windows_version`). OS fields describe the PC where that report was generated. Neither field proves that a connected session uses the GPU. The information window describes the current PC's OS policy.

```powershell
.\win7\verify_win7_binary.ps1 -Path .\target\windows-x86\mdeskmini.exe -Architecture x86
.\verify_build_capabilities.ps1 -Path .\target\windows-x86\mdeskmini.exe -Variant B2 -Architecture x86 -MinimumSubsystemVersion 6.1 -RequireWindowsCodecPolicy
```

The loader check rejects known Windows 8/10-only static imports; it is not a substitute for testing on Windows 7 SP1 itself. A successful capability probe on the build PC does not establish compatibility across every OS/GPU combination.

Windows x64 can run x86 applications through WOW64, but GPU acceleration still requires compatible **32-bit driver components**. See [Microsoft: Running 32-bit Applications](https://learn.microsoft.com/en-us/windows/win32/winprog64/running-32-bit-applications). ARM64 acceleration is not validated here. Windows 12 support remains unconfirmed; it was not listed in the [official release-health overview](https://learn.microsoft.com/en-us/windows/release-health/) when checked on 2026-10-13.

### Checking hardware acceleration

- Open the tray icon's **Information / 정보** window to see whether hardware acceleration and VRAM support are included in this executable.
- Mini is the remote host: the main benefit is GPU-assisted screen encoding. The controller should also use the updated hardware-enabled MDesk build to use a matching decoding path.
- At host startup, Mini delegates `--check-hwcodec-config` to the shared engine so its child process can discover supported GPU codecs. The engine chooses a compatible codec automatically according to both peers, GPU/driver support and existing settings.
- This update retains an explicit `enable-hwcodec=N` preference; it does not force-enable acceleration against the user's setting. With no disabling preference, the engine permits hardware codecs by default.
- Mini normally starts a SYSTEM portable capture service. The shared engine currently disables the VRAM texture encoder for that portable-service capture path (and GDI capture), while retaining the regular RAM-input hardware encoder when the GPU and peer support it. VRAM inclusion therefore does not promise VRAM use in every Mini session.
- Unsupported GPUs, disabled DirectX capture, recording and image-quality choices can prevent a particular hardware/VRAM path. Including support in the build is not proof that a connected session uses it.
- When Mini hands off to an **installed MDesk**, that installed application's build and settings determine acceleration. Update it too when testing this path.

For a build-only report, use a new output filename each time:

```powershell
Start-Process -FilePath .\target\release\mdeskmini.exe -ArgumentList 'capabilities --output "C:\Temp\mini-capabilities.json"' -Wait
# Or verify the expected B3 features and save the current executable hash:
.\verify_build_capabilities.ps1 -Path .\target\release\mdeskmini.exe -Variant B3 -OutputJson .\target\release\verified.json
```

The `capabilities` command returns before host initialization, configuration, certificate access, logging, installed-host handoff or cleanup. It reports the linked engine's compiled features; GPU devices and remote sessions are not probed. Its output parent folder must exist, and an existing report file is rejected.

For actual performance validation, connect from another PC, keep resolution/quality/network conditions the same, and compare B1/B3 scrolling and window movement alongside the session codec/FPS and the host's CPU and GPU Video Encode usage. A hardware codec name alone does not prove the VRAM path is active. Two-PC GPU/session and speed testing is still required.

## Run

```powershell
cd D:\IMedix\Rust\rustdesk\MDeskMini

# default: use the clipboard certificate or ask for one, then accept after verification
cargo run --

# explicit serve: require a clipboard certificate
cargo run -- serve --approve-mode auto --api "https://admin.787.kr"

# explicit serve
cargo run -- serve

# serve without popup loop
cargo run -- serve --headless

# explicitly request manual approval or password validation
cargo run -- serve --approve-mode click
cargo run -- serve --approve-mode both
cargo run -- serve --approve-mode password --password "your-password"
cargo run -- serve --api "https://admin.787.kr"

# id and version
cargo run -- id
cargo run -- version
```

## Notes

- Default `auto` mode accepts pending connections without a popup after certificate verification. This restores Mini's original unattended acceptance while it is running; certificate bootstrap does not authenticate each incoming peer.
- Explicit `click` and `both` modes retain the Windows approval popup. `password` mode never auto-approves failed or missing passwords.
- Automatic acceptance is handled by Mini's portable connection monitor only. Installed-MDesk handoff retains the existing host approval flow.
- `--headless` disables the monitor, including both its automatic acceptance and popup handling.
- Launching without arguments uses clipboard text such as `certno: 12345` first, skipping the input dialog for codes copied from the website. It prompts only when no clipboard certificate is found. The selected code continues through the cert verify API (`/api/certno/verify`).
- Explicit `serve` keeps using the clipboard certificate without an input dialog.
- Missing or rejected certificate verification prevents startup. API calls require valid HTTPS certificates.
- After cert verification succeeds, it also calls `/api/agentnumupdate/{customer_id}/{mdesk_id}?agentid=0`.

## Portable Downloads cleanup (Windows)

- After an authorized remote session, the existing automatic exit countdown remains unchanged: all active and pending connections must be absent for 20 monitor ticks (roughly 6 seconds). A new active or pending connection resets the countdown.
- Only the running Mini executable directly in the current user's actual Windows Downloads known folder is eligible. Downloads subfolders and executables in Desktop, installed locations, or other folders are preserved. A moved/redirected Downloads known folder is supported.
- On this automatic exit only, a hidden system PowerShell helper waits for Mini to exit, then removes that exact executable. No download/Explorer/console window opens. Manual close, failed startup, never-authorized sessions, installed-MDesk handoff, and headless operation do not schedule cleanup.
- File and Downloads directory identities are captured before monitoring. The helper rechecks identities and deletes through the verified file handle, so a replacement file at the same name is preserved. It retries ordinary file locks for up to 10 seconds; policy restrictions, permissions, or persistent locks simply leave the executable. It never kills another process or schedules deletion at reboot.
- Only the executable is removed (not moved to the Recycle Bin); other Downloads files and folders are untouched. Download Mini again for a later session.
- Regression test: `powershell -NoProfile -File MDeskMini/test_self_cleanup.ps1` (disposable dummy files only).
