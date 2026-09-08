//! Android text compatibility for the legacy ANSI Toad editor. Unlike
//! VK_PACKET/WM_CHAR, native Korean two-set key strokes work in this control.
//! Keep the editor in Hangul mode, as for ordinary physical keyboard input.

use super::ENIGO_INPUT_EXTRA_VALUE;
use std::{mem::size_of, ptr::null_mut};
use winapi::{shared::windef::HWND, um::winuser::*};

const LEADS: [&str; 19] = [
    "r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g",
];
const VOWELS: [&str; 21] = [
    "k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b",
    "m", "ml", "l",
];
const TAILS: [&str; 28] = [
    "", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a",
    "q", "qt", "t", "T", "d", "w", "c", "z", "x", "v", "g",
];

fn hangul_keys(c: char) -> Option<String> {
    let cp = c as usize;
    if (0xac00..=0xd7a3).contains(&cp) {
        // Unicode Hangul syllable decomposition: 19 leads, 21 vowels, 28 tails.
        let index = cp - 0xac00;
        return Some(format!(
            "{}{}{}",
            LEADS[index / 588],
            VOWELS[index / 28 % 21],
            TAILS[index % 28]
        ));
    }
    // Standalone compound consonants/vowels cannot always be reproduced as
    // one character by an IME without a syllable lead. Leave them, archaic
    // Hangul, and conjoining jamo on the existing Unicode path.
    let key = match c {
        'ㄱ' => 'r',
        'ㄲ' => 'R',
        'ㄴ' => 's',
        'ㄷ' => 'e',
        'ㄸ' => 'E',
        'ㄹ' => 'f',
        'ㅁ' => 'a',
        'ㅂ' => 'q',
        'ㅃ' => 'Q',
        'ㅅ' => 't',
        'ㅆ' => 'T',
        'ㅇ' => 'd',
        'ㅈ' => 'w',
        'ㅉ' => 'W',
        'ㅊ' => 'c',
        'ㅋ' => 'z',
        'ㅌ' => 'x',
        'ㅍ' => 'v',
        'ㅎ' => 'g',
        'ㅏ' => 'k',
        'ㅐ' => 'o',
        'ㅑ' => 'i',
        'ㅒ' => 'O',
        'ㅓ' => 'j',
        'ㅔ' => 'p',
        'ㅕ' => 'u',
        'ㅖ' => 'P',
        'ㅗ' => 'h',
        'ㅛ' => 'y',
        'ㅜ' => 'n',
        'ㅠ' => 'b',
        'ㅡ' => 'm',
        'ㅣ' => 'l',
        _ => return None,
    };
    Some(key.to_string())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Stroke {
    scan: u16,
    flags: u32,
}

impl Stroke {
    fn input(self) -> INPUT {
        let mut input: INPUT = unsafe { std::mem::zeroed() };
        input.type_ = INPUT_KEYBOARD;
        unsafe {
            *input.u.ki_mut() = KEYBDINPUT {
                wVk: 0,
                wScan: self.scan,
                dwFlags: self.flags,
                time: 0,
                dwExtraInfo: ENIGO_INPUT_EXTRA_VALUE,
            };
        }
        input
    }
}

fn stroke(out: &mut Vec<Stroke>, scan: u16, up: bool) {
    out.push(Stroke {
        scan,
        flags: KEYEVENTF_SCANCODE | if up { KEYEVENTF_KEYUP } else { 0 },
    });
}

fn click(out: &mut Vec<Stroke>, scan: u16) {
    stroke(out, scan, false);
    stroke(out, scan, true);
}

fn append_character(out: &mut Vec<Stroke>, c: char) {
    if let Some(keys) = hangul_keys(c) {
        for key in keys.bytes() {
            let scan = match key.to_ascii_lowercase() {
                b'q' => 0x10,
                b'w' => 0x11,
                b'e' => 0x12,
                b'r' => 0x13,
                b't' => 0x14,
                b'y' => 0x15,
                b'u' => 0x16,
                b'i' => 0x17,
                b'o' => 0x18,
                b'p' => 0x19,
                b'a' => 0x1e,
                b's' => 0x1f,
                b'd' => 0x20,
                b'f' => 0x21,
                b'g' => 0x22,
                b'h' => 0x23,
                b'j' => 0x24,
                b'k' => 0x25,
                b'l' => 0x26,
                b'z' => 0x2c,
                b'x' => 0x2d,
                b'c' => 0x2e,
                b'v' => 0x2f,
                b'b' => 0x30,
                b'n' => 0x31,
                b'm' => 0x32,
                _ => unreachable!("Hangul tables contain only two-set letter keys"),
            };
            if key.is_ascii_uppercase() {
                stroke(out, 0x2a, false);
            }
            click(out, scan);
            if key.is_ascii_uppercase() {
                stroke(out, 0x2a, true);
            }
        }
        // Verified on the user's TAdvToadSyntaxMemo. Commit the IME syllable
        // with Space, then remove only that space. The next Android Backspace
        // must delete a whole committed character, not just its last jamo.
        // Keep these events in the same SendInput batch; no sleeps/WM_CHAR.
        click(out, 0x39);
        click(out, 0x0e);
    } else {
        let mut utf16 = [0; 2];
        for unit in c.encode_utf16(&mut utf16) {
            out.push(Stroke {
                scan: *unit,
                flags: KEYEVENTF_UNICODE,
            });
            out.push(Stroke {
                scan: *unit,
                flags: KEYEVENTF_UNICODE | KEYEVENTF_KEYUP,
            });
        }
    }
}

fn pending_releases(accepted: &[Stroke]) -> Vec<Stroke> {
    let mut down = Vec::<Stroke>::new();
    for event in accepted {
        let mut key = *event;
        key.flags &= !KEYEVENTF_KEYUP;
        if event.flags & KEYEVENTF_KEYUP != 0 {
            if let Some(index) = down.iter().rposition(|pressed| *pressed == key) {
                down.remove(index);
            }
        } else {
            down.push(key);
        }
    }
    down.into_iter()
        .rev()
        .map(|mut key| {
            key.flags |= KEYEVENTF_KEYUP;
            key
        })
        .collect()
}

fn send_batch(events: &[Stroke]) -> bool {
    let mut inputs: Vec<_> = events.iter().map(|event| event.input()).collect();
    let sent = unsafe {
        SendInput(
            inputs.len() as u32,
            inputs.as_mut_ptr(),
            size_of::<INPUT>() as i32,
        )
    } as usize;
    if sent == inputs.len() {
        return true;
    }
    let error = unsafe { super::win_impl::GetLastError() };
    // A partial batch may end between Shift down/up. Release only the keys
    // accepted from this batch and never replay its text on the Unicode path.
    let mut release: Vec<_> = pending_releases(&events[..sent.min(events.len())])
        .iter()
        .map(|event| event.input())
        .collect();
    if !release.is_empty() {
        unsafe {
            SendInput(
                release.len() as u32,
                release.as_mut_ptr(),
                size_of::<INPUT>() as i32,
            );
        }
    }
    log::warn!(
        "Toad native Hangul input: accepted {}/{} events, error {}",
        sent,
        inputs.len(),
        error
    );
    false
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct Target {
    foreground: HWND,
    focus: HWND,
}

fn target() -> Option<Target> {
    unsafe {
        let foreground = GetForegroundWindow();
        if foreground.is_null() {
            return None;
        }
        let thread = GetWindowThreadProcessId(foreground, null_mut());
        let mut info: GUITHREADINFO = std::mem::zeroed();
        info.cbSize = size_of::<GUITHREADINFO>() as u32;
        if thread == 0
            || GetGUIThreadInfo(thread, &mut info) == 0
            || info.hwndFocus.is_null()
            || IsWindowUnicode(info.hwndFocus) != 0
        {
            return None;
        }
        let mut name = [0u16; 64];
        let len = GetClassNameW(info.hwndFocus, name.as_mut_ptr(), name.len() as i32);
        if len <= 0
            || !name[..len as usize]
                .iter()
                .copied()
                .eq("TAdvToadSyntaxMemo".encode_utf16())
        {
            return None;
        }
        let focus_thread = GetWindowThreadProcessId(info.hwndFocus, null_mut());
        if GetKeyboardLayout(focus_thread) as usize & 0xffff != 0x0412 {
            return None;
        }
        Some(Target {
            foreground,
            focus: info.hwndFocus,
        })
    }
}

/// Sends an Android printable ASCII character literally in the legacy Toad
/// editor, so the editor can remain in Hangul mode for native Korean input.
/// Call only for Android Legacy Chr events without shortcut modifiers.
/// A down event sends a complete Unicode click; its separate up is consumed.
pub fn try_toad_ascii_input(chr: u32, down: bool) -> bool {
    if !(0x21..=0x7e).contains(&chr) || target().is_none() {
        return false;
    }
    if down {
        let mut events = Vec::new();
        append_character(&mut events, char::from_u32(chr).unwrap());
        send_batch(&events);
    }
    true
}

/// Tries the native two-set Hangul path for the focused legacy ANSI Toad editor.
/// Call only for Android legacy text events without shortcut modifiers. The
/// editor must be in Hangul mode with Caps Lock off (as for the verified native
/// keyboard probe). No clipboard or IME/language settings are changed.
/// Returns true once input was attempted, including partial failure, so callers
/// must not replay the same text. Other windows/text return false untouched.
pub fn try_native_hangul_input(text: &str) -> bool {
    if !text.chars().any(|c| hangul_keys(c).is_some()) {
        return false;
    }
    let expected = match target() {
        Some(target) => target,
        None => return false,
    };
    unsafe {
        if [VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN]
            .iter()
            .any(|key| GetAsyncKeyState(*key) as u16 & 0x8000 != 0)
            || GetKeyState(VK_CAPITAL) & 1 != 0
        {
            return false;
        }
    }
    let mut events = Vec::new();
    let mut attempted = false;
    for c in text.chars() {
        append_character(&mut events, c);
        // Bound allocation/one input batch even for a large text message.
        // Flush only after a complete committed character, never mid-Shift.
        if events.len() >= 1024 {
            if target() != Some(expected) {
                return true;
            }
            attempted = true;
            if !send_batch(&events) {
                return true;
            }
            events.clear();
        }
    }
    if !events.is_empty() {
        if target() != Some(expected) {
            return true;
        }
        send_batch(&events);
        attempted = true;
    }
    attempted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_hangul_matches_successful_toad_probe() {
        let mut actual = Vec::new();
        append_character(&mut actual, '한');
        append_character(&mut actual, '글');
        click(&mut actual, 0x39);
        append_character(&mut actual, 'ㅎ');
        click(&mut actual, 0x0e);
        append_character(&mut actual, '하');
        click(&mut actual, 0x0e);
        append_character(&mut actual, '한');
        click(&mut actual, 0x39);
        let scans = [
            0x22, 0x25, 0x1f, 0x39, 0x0e, 0x13, 0x32, 0x21, 0x39, 0x0e, 0x39, 0x22, 0x39, 0x0e,
            0x0e, 0x22, 0x25, 0x39, 0x0e, 0x0e, 0x22, 0x25, 0x1f, 0x39, 0x0e, 0x39,
        ];
        let mut expected = Vec::new();
        for scan in scans {
            click(&mut expected, scan);
        }
        assert_eq!(actual, expected); // Exactly the 52 events verified on Toad.
    }

    #[test]
    fn native_hangul_maps_compound_syllables_and_standalone_jamo() {
        for (character, keys) in [
            ('가', "rk"),
            ('까', "Rk"),
            ('꽤', "Rho"),
            ('값', "rkqt"),
            ('닭', "ekfr"),
            ('앉', "dksw"),
            ('않', "dksg"),
            ('읽', "dlfr"),
            ('왜', "dho"),
            ('뭐', "anj"),
            ('웩', "dnpr"),
            ('의', "dml"),
            ('했', "goT"),
            ('힣', "glg"),
            ('ㅎ', "g"),
            ('ㅆ', "T"),
            ('ㅖ', "P"),
        ] {
            assert_eq!(hangul_keys(character).as_deref(), Some(keys), "{character}");
        }
        for character in ['A', '1', '😀', '漢', 'ㄳ', 'ㅘ', '\u{1100}'] {
            assert_eq!(hangul_keys(character), None);
        }
    }

    #[test]
    fn native_hangul_partial_send_releases_our_shift_and_letter() {
        let mut events = Vec::new();
        append_character(&mut events, '꽤');
        assert_eq!(
            pending_releases(&events[..1]),
            vec![Stroke {
                scan: 0x2a,
                flags: 10
            }]
        );
        assert_eq!(
            pending_releases(&events[..2]),
            vec![
                Stroke {
                    scan: 0x13,
                    flags: 10
                },
                Stroke {
                    scan: 0x2a,
                    flags: 10
                }
            ]
        );
        assert!(pending_releases(&events).is_empty());
        for prefix in 0..=events.len() {
            let mut repaired = events[..prefix].to_vec();
            repaired.extend(pending_releases(&repaired));
            assert!(pending_releases(&repaired).is_empty());
        }
    }

    #[test]
    fn native_hangul_keeps_other_text_as_unicode_and_never_commits_with_enter() {
        let mut events = Vec::new();
        for c in "A한😀".chars() {
            append_character(&mut events, c);
        }
        let unicode: Vec<_> = events
            .iter()
            .filter(|event| event.flags == KEYEVENTF_UNICODE)
            .map(|event| event.scan)
            .collect();
        assert_eq!(unicode, vec![0x41, 0xd83d, 0xde00]);
        assert!(events
            .iter()
            .all(|event| event.flags & KEYEVENTF_SCANCODE == 0 || event.scan != 0x1c));
        assert!(pending_releases(&events).is_empty());
        assert!(!try_native_hangul_input("plain ASCII")); // No window access needed.
        assert!(!try_native_hangul_input(""));
    }
}
