use super::{load_application_icon, to_wide, VERSION};
use windows::core::{Result, PCWSTR};
use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontIndirectW, DeleteObject, GetStockObject, GetSysColorBrush, COLOR_WINDOW,
    DEFAULT_CHARSET, DEFAULT_GUI_FONT, HGDIOBJ, LOGFONTW,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::ShellExecuteW;
use windows::Win32::UI::WindowsAndMessaging::*;

const SOURCE_URL: &str = "https://github.com/metadtlab/MDesk";
const UPSTREAM_URL: &str = "https://github.com/rustdesk/rustdesk";
const LICENSE: &str = include_str!("../../LICENCE");
const HEADER_ID: i32 = 201;
const NOTICE_ID: i32 = 202;
const SOURCE_ID: i32 = 203;
const UPSTREAM_ID: i32 = 204;
const CLOSE_ID: i32 = 2;

fn notice_text() -> String {
    format!(
        "MDeskMini는 RustDesk 기반으로 수정한 원격지원 프로그램입니다.\n\
         Copyright (c) 2025 MetaDataLab.\n\
         Portions Copyright (c) Purslane Ltd.\n\
         기타 기여자의 저작권과 라이선스 고지는 유지됩니다.\n\n\
         GNU Affero General Public License v3 (AGPLv3)\n\
         라이선스 조건에 따라 이용, 복사, 수정 및 재배포할 수 있습니다.\n\
         법률이나 별도 약정에서 요구하는 경우를 제외하고 보증 없이 제공됩니다.\n\n\
         수정 프로젝트 소스: {SOURCE_URL}\n\
         원본 RustDesk: {UPSTREAM_URL}\n\
         소스 제공 안내: 저장소의 SOURCE_CODE.txt 및 README.md\n\
         공개 저장소의 최신 코드가 이 실행 파일의 대응 소스라고 보증하지는 않습니다.\n\n\
         아래는 AGPLv3 원문입니다. 제3자 구성 요소에는 각자의 라이선스가 적용됩니다.\n\n\
         {LICENSE}"
    )
    .replace("\r\n", "\n")
    .replace('\n', "\r\n")
}

fn current(owner: HWND) -> Option<HWND> {
    let hwnd = HWND(unsafe { GetWindowLongPtrW(owner, GWLP_USERDATA) } as *mut _);
    (!hwnd.0.is_null() && unsafe { IsWindow(Some(hwnd)).as_bool() }).then_some(hwnd)
}

pub(super) fn handle_dialog_message(owner: HWND, msg: &MSG) -> bool {
    current(owner).is_some_and(|hwnd| unsafe { IsDialogMessageW(hwnd, msg).as_bool() })
}

pub(super) fn close(owner: HWND) {
    if let Some(hwnd) = current(owner) {
        unsafe {
            let _ = DestroyWindow(hwnd);
        }
    }
}

pub(super) fn show(owner: HWND) -> Result<()> {
    if let Some(hwnd) = current(owner) {
        unsafe {
            let _ = ShowWindow(hwnd, SW_RESTORE);
            let _ = SetForegroundWindow(hwnd);
        }
        return Ok(());
    }
    let instance = HINSTANCE(unsafe { GetModuleHandleW(None)? }.0);
    let class_name = to_wide("MDeskMiniAboutClass");
    let class = WNDCLASSW {
        lpfnWndProc: Some(window_proc),
        hInstance: instance,
        hIcon: load_application_icon()?,
        hCursor: unsafe { LoadCursorW(None, IDC_ARROW)? },
        hbrBackground: unsafe { GetSysColorBrush(COLOR_WINDOW) },
        lpszClassName: PCWSTR(class_name.as_ptr()),
        ..Default::default()
    };
    unsafe {
        // The class remains registered when the information window is reopened.
        let _ = RegisterClassW(&class);
    }
    let title = to_wide("MDeskMini 정보 - 오픈소스 라이선스");
    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_CONTROLPARENT,
            PCWSTR(class_name.as_ptr()),
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPEDWINDOW & !WS_MINIMIZEBOX,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            680,
            600,
            Some(owner),
            None,
            Some(instance),
            None,
        )?
    };
    unsafe {
        SetWindowLongPtrW(owner, GWLP_USERDATA, hwnd.0 as _);
    }
    let result = populate(hwnd);
    if let Err(err) = result {
        unsafe {
            let _ = DestroyWindow(hwnd);
        }
        return Err(err);
    }
    layout(hwnd);
    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        if let Ok(button) = GetDlgItem(Some(hwnd), SOURCE_ID) {
            SendMessageW(
                hwnd,
                WM_NEXTDLGCTL,
                Some(WPARAM(button.0 as usize)),
                Some(LPARAM(1)),
            );
        }
    }
    Ok(())
}

fn populate(hwnd: HWND) -> Result<()> {
    let mut font = LOGFONTW {
        lfHeight: -16,
        lfWeight: 400,
        lfCharSet: DEFAULT_CHARSET,
        ..Default::default()
    };
    let face = to_wide("Segoe UI");
    font.lfFaceName[..face.len()].copy_from_slice(&face);
    unsafe {
        let font = CreateFontIndirectW(&font);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, font.0 as _);
    }
    add_control(
        hwnd,
        "STATIC",
        &format!(
            "MDeskMini {}  |  MDesk 엔진 {VERSION}",
            env!("CARGO_PKG_VERSION")
        ),
        HEADER_ID,
        WINDOW_STYLE::default(),
    )?;
    add_control(
        hwnd,
        "EDIT",
        &notice_text(),
        NOTICE_ID,
        WS_BORDER
            | WS_VSCROLL
            | WS_TABSTOP
            | WINDOW_STYLE((ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL) as u32),
    )?;
    add_control(hwnd, "BUTTON", "소스 코드(&S)", SOURCE_ID, WS_TABSTOP)?;
    add_control(hwnd, "BUTTON", "RustDesk(&R)", UPSTREAM_ID, WS_TABSTOP)?;
    add_control(hwnd, "BUTTON", "닫기", CLOSE_ID, WS_TABSTOP)?;
    Ok(())
}

fn add_control(parent: HWND, class: &str, text: &str, id: i32, style: WINDOW_STYLE) -> Result<()> {
    let class = to_wide(class);
    let text = to_wide(text);
    let hwnd = unsafe {
        CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            PCWSTR(class.as_ptr()),
            PCWSTR(text.as_ptr()),
            WS_CHILD | WS_VISIBLE | style,
            0,
            0,
            0,
            0,
            Some(parent),
            Some(HMENU(id as *mut _)),
            None,
            None,
        )?
    };
    unsafe {
        let font = GetWindowLongPtrW(parent, GWLP_USERDATA) as usize;
        SendMessageW(
            hwnd,
            WM_SETFONT,
            Some(WPARAM(if font == 0 {
                GetStockObject(DEFAULT_GUI_FONT).0 as usize
            } else {
                font
            })),
            Some(LPARAM(1)),
        );
    }
    Ok(())
}

fn layout(hwnd: HWND) {
    let mut rect = RECT::default();
    if unsafe { GetClientRect(hwnd, &mut rect) }.is_err() {
        return;
    }
    let width = rect.right;
    let height = rect.bottom;
    let controls = [
        (HEADER_ID, 16, 16, width - 32, 28),
        (NOTICE_ID, 16, 52, width - 32, (height - 112).max(40)),
        (SOURCE_ID, 16, height - 44, 124, 28),
        (UPSTREAM_ID, 148, height - 44, 112, 28),
        (CLOSE_ID, width - 108, height - 44, 92, 28),
    ];
    for (id, x, y, w, h) in controls {
        if let Ok(child) = unsafe { GetDlgItem(Some(hwnd), id) } {
            unsafe {
                let _ = MoveWindow(child, x, y, w, h, true);
            }
        }
    }
}

fn open_link(hwnd: HWND, url: &str) {
    let operation = to_wide("open");
    let link = to_wide(url);
    let result = unsafe {
        ShellExecuteW(
            Some(hwnd),
            PCWSTR(operation.as_ptr()),
            PCWSTR(link.as_ptr()),
            None,
            None,
            SW_SHOWNORMAL,
        )
    };
    if result.0 as isize <= 32 {
        let message = to_wide(&format!("브라우저를 열지 못했습니다.\n{url}"));
        unsafe {
            MessageBoxW(
                Some(hwnd),
                PCWSTR(message.as_ptr()),
                PCWSTR(to_wide("MDeskMini").as_ptr()),
                MB_OK | MB_ICONERROR,
            );
        }
    }
}

extern "system" fn window_proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        WM_SIZE => {
            layout(hwnd);
            LRESULT(0)
        }
        WM_GETMINMAXINFO => {
            let info = unsafe { &mut *(lparam.0 as *mut MINMAXINFO) };
            info.ptMinTrackSize.x = 460;
            info.ptMinTrackSize.y = 360;
            LRESULT(0)
        }
        WM_COMMAND => {
            match (wparam.0 & 0xffff) as i32 {
                SOURCE_ID => open_link(hwnd, SOURCE_URL),
                UPSTREAM_ID => open_link(hwnd, UPSTREAM_URL),
                CLOSE_ID => unsafe {
                    let _ = DestroyWindow(hwnd);
                },
                _ => {}
            }
            LRESULT(0)
        }
        WM_NCDESTROY => {
            // Child controls are already destroyed, so their font can be released.
            let font = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) };
            if font != 0 {
                unsafe {
                    let _ = DeleteObject(HGDIOBJ(font as *mut _));
                }
            }
            if let Ok(owner) = unsafe { GetWindow(hwnd, GW_OWNER) } {
                unsafe {
                    SetWindowLongPtrW(owner, GWLP_USERDATA, 0);
                }
            }
            unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
        }
        _ => unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notice_contains_license_rights_and_source() {
        let text = notice_text();
        assert!(text.contains("GNU AFFERO GENERAL PUBLIC LICENSE"));
        assert!(text.contains("END OF TERMS AND CONDITIONS"));
        assert!(text.contains("Purslane Ltd."));
        assert!(text.contains(SOURCE_URL));
        assert!(text.contains(UPSTREAM_URL));
        assert!(!text.replace("\r\n", "").contains('\n'));
    }

    #[test]
    fn modeless_window_reopens_and_closes_without_quitting_owner() {
        unsafe {
            let class = to_wide("STATIC");
            let owner = CreateWindowExW(
                WINDOW_EX_STYLE::default(),
                PCWSTR(class.as_ptr()),
                PCWSTR::null(),
                WINDOW_STYLE::default(),
                0,
                0,
                0,
                0,
                None,
                None,
                None,
                None,
            )
            .unwrap();
            show(owner).unwrap();
            let first = current(owner).unwrap();
            show(owner).unwrap();
            assert_eq!(current(owner), Some(first));
            let edit = GetDlgItem(Some(first), NOTICE_ID).unwrap();
            let expected = to_wide(&notice_text());
            assert_eq!(GetWindowTextLengthW(edit) as usize, expected.len() - 1);
            let mut displayed = vec![0u16; expected.len()];
            GetWindowTextW(edit, &mut displayed);
            assert_eq!(displayed, expected);
            assert_ne!(
                GetWindowLongW(edit, GWL_STYLE) as u32 & ES_READONLY as u32,
                0
            );
            for (width, height) in [(460, 360), (680, 600), (1000, 800)] {
                MoveWindow(first, 0, 0, width, height, true).unwrap();
                let bounds = |id| {
                    let mut rect = RECT::default();
                    GetWindowRect(GetDlgItem(Some(first), id).unwrap(), &mut rect).unwrap();
                    rect
                };
                assert!(bounds(HEADER_ID).bottom <= bounds(NOTICE_ID).top);
                assert!(bounds(NOTICE_ID).bottom <= bounds(SOURCE_ID).top);
                assert!(bounds(SOURCE_ID).right <= bounds(UPSTREAM_ID).left);
                assert!(bounds(UPSTREAM_ID).right <= bounds(CLOSE_ID).left);
            }
            SendMessageW(first, WM_COMMAND, Some(WPARAM(CLOSE_ID as usize)), None);
            assert!(current(owner).is_none());
            assert!(IsWindow(Some(owner)).as_bool());
            show(owner).unwrap();
            let second = current(owner).unwrap();
            SendMessageW(second, WM_CLOSE, None, None);
            assert!(current(owner).is_none());
            show(owner).unwrap();
            close(owner);
            assert!(current(owner).is_none());
            show(owner).unwrap();
            let escape = MSG {
                hwnd: current(owner).unwrap(),
                message: WM_KEYDOWN,
                wParam: WPARAM(0x1b),
                ..Default::default()
            };
            assert!(handle_dialog_message(owner, &escape));
            assert!(current(owner).is_none());
            let mut msg = MSG::default();
            assert!(!PeekMessageW(&mut msg, None, WM_QUIT, WM_QUIT, PM_NOREMOVE).as_bool());
            show(owner).unwrap();
            let owned = current(owner).unwrap();
            DestroyWindow(owner).unwrap();
            assert!(!IsWindow(Some(owned)).as_bool());
        }
    }
}
