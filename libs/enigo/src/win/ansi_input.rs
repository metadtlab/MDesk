//! ANSI windows translate VK_PACKET using their input language's code page.
//! An English layout turns Hangul into '?' even on a Korean Windows install.
//! Select an already loaded Korean layout before queuing Hangul keystrokes.

use std::{mem::size_of, ptr::null_mut};
use winapi::{shared::windef::HWND, um::winuser::*};

const KOREAN_LANG_ID: usize = 0x0412;

fn contains_hangul(text: &str) -> bool {
    text.chars().any(|c| {
        matches!(c as u32, 0x1100..=0x11ff | 0x3130..=0x318f |
            0xa960..=0xa97f | 0xac00..=0xd7ff)
    })
}

/// Selects a loaded Korean input language for a focused ANSI window receiving
/// Hangul. Call only for Android legacy text input; ordinary desktop keyboard
/// handling must continue to use the user's selected layout.
pub fn prepare_hangul_input(text: &str) {
    if !contains_hangul(text) {
        return;
    }
    unsafe {
        let foreground = GetForegroundWindow();
        if foreground.is_null() {
            return;
        }
        let thread_id = GetWindowThreadProcessId(foreground, null_mut());
        let mut info: GUITHREADINFO = std::mem::zeroed();
        info.cbSize = size_of::<GUITHREADINFO>() as u32;
        if thread_id != 0 && GetGUIThreadInfo(thread_id, &mut info) != 0 {
            prepare_window(info.hwndFocus, text);
        }
    }
}

fn prepare_window(focus: HWND, text: &str) {
    if focus.is_null() || !contains_hangul(text) {
        return;
    }
    unsafe {
        if IsWindowUnicode(focus) != 0 {
            return;
        }
        let thread_id = GetWindowThreadProcessId(focus, null_mut());
        if thread_id == 0 || GetKeyboardLayout(thread_id) as usize & 0xffff == KOREAN_LANG_ID {
            return;
        }
        let count = GetKeyboardLayoutList(0, null_mut());
        if count <= 0 {
            return;
        }
        let mut layouts = vec![null_mut(); count as usize];
        let copied = GetKeyboardLayoutList(count, layouts.as_mut_ptr());
        let korean = layouts
            .iter()
            .take(copied.max(0) as usize)
            .copied()
            .find(|layout| *layout as usize & 0xffff == KOREAN_LANG_ID);
        if let Some(layout) = korean {
            // Wait for the target thread to apply the layout before SendInput.
            // A posted request can race the queued keystrokes. Bound the wait
            // because the remote application may be unresponsive.
            let mut result = 0;
            let delivered = SendMessageTimeoutW(
                focus,
                WM_INPUTLANGCHANGEREQUEST,
                0,
                layout as isize,
                SMTO_ABORTIFHUNG | SMTO_BLOCK,
                200,
                &mut result,
            );
            if delivered == 0 || GetKeyboardLayout(thread_id) as usize & 0xffff != KOREAN_LANG_ID {
                log::debug!("ANSI Hangul input: target did not accept Korean input language");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, sync::Mutex};
    use winapi::{shared::minwindef::*, um::libloaderapi::GetModuleHandleW};

    static TEST_LOCK: Mutex<()> = Mutex::new(());
    thread_local! { static RECEIVED: RefCell<Vec<usize>> = RefCell::new(Vec::new()); }

    unsafe extern "system" fn window_proc(
        hwnd: HWND,
        msg: UINT,
        wp: WPARAM,
        lp: LPARAM,
    ) -> LRESULT {
        if msg == WM_CHAR {
            RECEIVED.with(|chars| chars.borrow_mut().push(wp));
            return 0;
        }
        if IsWindowUnicode(hwnd) != 0 {
            DefWindowProcW(hwnd, msg, wp, lp)
        } else {
            DefWindowProcA(hwnd, msg, wp, lp)
        }
    }

    #[test]
    fn ansi_hangul_uses_korean_code_page_without_changing_unicode_or_ascii_input() {
        let _guard = TEST_LOCK.lock().unwrap();
        unsafe {
            let previous = GetKeyboardLayout(0);
            let english_id: Vec<u16> = "00000409\0".encode_utf16().collect();
            let korean_id: Vec<u16> = "00000412\0".encode_utf16().collect();
            let english = LoadKeyboardLayoutW(english_id.as_ptr(), 0);
            let korean = LoadKeyboardLayoutW(korean_id.as_ptr(), 0);
            assert!(!english.is_null() && !korean.is_null());
            let name = b"MDeskAnsiHangulTest\0";
            let mut class: WNDCLASSA = std::mem::zeroed();
            class.lpfnWndProc = Some(window_proc);
            class.hInstance = GetModuleHandleW(null_mut());
            class.lpszClassName = name.as_ptr() as _;
            assert_ne!(RegisterClassA(&class), 0);
            let ansi = CreateWindowExA(
                0,
                class.lpszClassName,
                name.as_ptr() as _,
                0,
                0,
                0,
                0,
                0,
                null_mut(),
                null_mut(),
                class.hInstance,
                null_mut(),
            );
            assert!(!ansi.is_null());
            let unicode_class: Vec<u16> = "EDIT\0".encode_utf16().collect();
            let unicode = CreateWindowExW(
                0,
                unicode_class.as_ptr(),
                null_mut(),
                0,
                0,
                0,
                0,
                0,
                null_mut(),
                null_mut(),
                class.hInstance,
                null_mut(),
            );
            assert!(!unicode.is_null());

            ActivateKeyboardLayout(english, 0);
            RECEIVED.with(|chars| chars.borrow_mut().clear());
            SendMessageW(ansi, WM_CHAR, '한' as usize, 1);
            let broken = RECEIVED.with(|chars| chars.borrow().clone());

            prepare_window(unicode, "한");
            let unicode_layout = GetKeyboardLayout(0);
            prepare_window(ansi, "abc");
            let ascii_layout = GetKeyboardLayout(0);
            prepare_window(ansi, "한");
            let corrected_layout = GetKeyboardLayout(0);
            RECEIVED.with(|chars| chars.borrow_mut().clear());
            SendMessageW(ansi, WM_CHAR, '한' as usize, 1);
            let corrected = RECEIVED.with(|chars| chars.borrow().clone());

            DestroyWindow(ansi);
            DestroyWindow(unicode);
            UnregisterClassA(class.lpszClassName, class.hInstance);
            ActivateKeyboardLayout(previous, 0);
            assert_eq!(broken, vec![b'?' as usize]);
            assert_eq!(unicode_layout, english);
            assert_eq!(ascii_layout, english);
            assert_eq!(corrected_layout as usize & 0xffff, KOREAN_LANG_ID);
            assert_eq!(corrected, vec![0xc7, 0xd1]); // CP949: 한
        }
    }
}
