use super::{load_application_icon, to_wide};
use windows::core::{Error, Result, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::Controls::{EM_SETLIMITTEXT, EM_SETSEL};
use windows::Win32::UI::WindowsAndMessaging::*;

// Keep these IDs in sync with cert_prompt.rc.
const DIALOG_ID: usize = 101;
const CERT_EDIT_ID: i32 = 1001;
const ERROR_LABEL_ID: i32 = 1002;
const MAX_CERT_LENGTH: usize = 128;

#[derive(Default)]
struct PromptState {
    certnum: Option<String>,
}

pub(super) fn show() -> Result<Option<String>> {
    let mut state = PromptState::default();
    // DialogBoxParamW keeps this stack state alive until the modal dialog closes.
    let result = unsafe {
        DialogBoxParamW(
            None,
            PCWSTR(DIALOG_ID as *const u16),
            None,
            Some(dialog_proc),
            LPARAM(&mut state as *mut PromptState as isize),
        )
    };
    if result == -1 {
        Err(Error::from_win32())
    } else {
        Ok(state.certnum)
    }
}

fn parse_certnum(text: &str) -> Option<String> {
    let text = text.trim();
    (!text.is_empty() && text.bytes().all(|ch| ch.is_ascii_digit())).then(|| text.to_owned())
}

unsafe extern "system" fn dialog_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> isize {
    match msg {
        WM_INITDIALOG => {
            // On x86 this binding aliases SetWindowLongW (i32); on x64 it takes isize.
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, lparam.0 as _);
            if let Ok(edit) = GetDlgItem(Some(hwnd), CERT_EDIT_ID) {
                SendMessageW(edit, EM_SETLIMITTEXT, Some(WPARAM(MAX_CERT_LENGTH)), None);
            }
            if let Ok(icon) = load_application_icon() {
                SendMessageW(
                    hwnd,
                    WM_SETICON,
                    Some(WPARAM(ICON_SMALL as usize)),
                    Some(LPARAM(icon.0 as isize)),
                );
            }
            1 // Let the dialog manager focus the first input control.
        }
        WM_COMMAND => {
            let command = (wparam.0 & 0xffff) as i32;
            if command == IDOK.0 {
                let mut text = [0u16; MAX_CERT_LENGTH + 1];
                let len = GetDlgItemTextW(hwnd, CERT_EDIT_ID, &mut text) as usize;
                if let Some(certnum) = parse_certnum(&String::from_utf16_lossy(&text[..len])) {
                    let state = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut PromptState;
                    if let Some(state) = state.as_mut() {
                        state.certnum = Some(certnum);
                        let _ = EndDialog(hwnd, IDOK.0 as isize);
                    }
                } else {
                    let message = to_wide("인증번호를 숫자로 입력해 주세요.");
                    let _ = SetDlgItemTextW(hwnd, ERROR_LABEL_ID, PCWSTR(message.as_ptr()));
                    if let Ok(edit) = GetDlgItem(Some(hwnd), CERT_EDIT_ID) {
                        SendMessageW(
                            hwnd,
                            WM_NEXTDLGCTL,
                            Some(WPARAM(edit.0 as usize)),
                            Some(LPARAM(1)),
                        );
                        SendMessageW(edit, EM_SETSEL, Some(WPARAM(0)), Some(LPARAM(-1)));
                    }
                }
                1
            } else if command == IDCANCEL.0 {
                let _ = EndDialog(hwnd, IDCANCEL.0 as isize);
                1
            } else {
                0
            }
        }
        WM_CLOSE => {
            let _ = EndDialog(hwnd, IDCANCEL.0 as isize);
            1
        }
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_input_without_losing_leading_zeroes() {
        assert_eq!(parse_certnum(" 001234 \r\n"), Some("001234".to_owned()));
        for invalid in ["", " \t", "12 34", "123a", "１２３４", "-123"] {
            assert_eq!(parse_certnum(invalid), None, "{invalid:?}");
        }
    }

    // Drive the real resource and dialog procedure before it becomes visible.
    // No server, clipboard, elevation, or live certificate API is involved.
    unsafe extern "system" fn submit_test_proc(
        hwnd: HWND,
        msg: u32,
        wp: WPARAM,
        lp: LPARAM,
    ) -> isize {
        let result = dialog_proc(hwnd, msg, wp, lp);
        if msg == WM_INITDIALOG {
            SendMessageW(hwnd, WM_COMMAND, Some(WPARAM(IDOK.0 as usize)), None);
            let mut error = [0u16; 128];
            let error_len = GetDlgItemTextW(hwnd, ERROR_LABEL_ID, &mut error);
            let state = &*(lp.0 as *const PromptState);
            // Return failure to the test instead of panicking across the Win32 ABI.
            if error_len == 0 || state.certnum.is_some() {
                let _ = EndDialog(hwnd, -2);
                return 1;
            }
            let code = to_wide(" 001234 ");
            let _ = SetDlgItemTextW(hwnd, CERT_EDIT_ID, PCWSTR(code.as_ptr()));
            let enter = MSG {
                hwnd: GetDlgItem(Some(hwnd), CERT_EDIT_ID).unwrap_or_default(),
                message: WM_KEYDOWN,
                wParam: WPARAM(0x0d),
                ..Default::default()
            };
            if !IsDialogMessageW(hwnd, &enter).as_bool() {
                let _ = EndDialog(hwnd, -3);
            }
        }
        result
    }

    unsafe extern "system" fn cancel_test_proc(
        hwnd: HWND,
        msg: u32,
        wp: WPARAM,
        lp: LPARAM,
    ) -> isize {
        let result = dialog_proc(hwnd, msg, wp, lp);
        if msg == WM_INITDIALOG {
            SendMessageW(hwnd, WM_COMMAND, Some(WPARAM(IDCANCEL.0 as usize)), None);
        }
        result
    }

    unsafe extern "system" fn close_test_proc(
        hwnd: HWND,
        msg: u32,
        wp: WPARAM,
        lp: LPARAM,
    ) -> isize {
        let result = dialog_proc(hwnd, msg, wp, lp);
        if msg == WM_INITDIALOG {
            SendMessageW(hwnd, WM_CLOSE, None, None);
        }
        result
    }

    unsafe extern "system" fn escape_test_proc(
        hwnd: HWND,
        msg: u32,
        wp: WPARAM,
        lp: LPARAM,
    ) -> isize {
        let result = dialog_proc(hwnd, msg, wp, lp);
        if msg == WM_INITDIALOG {
            let escape = MSG {
                hwnd,
                message: WM_KEYDOWN,
                wParam: WPARAM(0x1b),
                ..Default::default()
            };
            if !IsDialogMessageW(hwnd, &escape).as_bool() {
                let _ = EndDialog(hwnd, -3);
            }
        }
        result
    }

    #[test]
    fn native_dialog_submits_or_cancels_without_quitting_startup_thread() {
        for (proc, expected_result, expected_code) in [
            (
                Some(submit_test_proc as unsafe extern "system" fn(_, _, _, _) -> _),
                IDOK.0,
                Some("001234"),
            ),
            (Some(cancel_test_proc), IDCANCEL.0, None),
            (Some(close_test_proc), IDCANCEL.0, None),
            (Some(escape_test_proc), IDCANCEL.0, None),
        ] {
            let mut state = PromptState::default();
            let result = unsafe {
                DialogBoxParamW(
                    None,
                    PCWSTR(DIALOG_ID as *const u16),
                    None,
                    proc,
                    LPARAM(&mut state as *mut PromptState as isize),
                )
            };
            assert_eq!(
                result,
                expected_result as isize,
                "dialog result: {:?}",
                Error::from_win32()
            );
            assert_eq!(state.certnum.as_deref(), expected_code);
            let mut msg = MSG::default();
            assert!(!unsafe {
                PeekMessageW(&mut msg, None, WM_QUIT, WM_QUIT, PM_NOREMOVE).as_bool()
            });
        }
    }
}
