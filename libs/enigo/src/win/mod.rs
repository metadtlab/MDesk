mod win_impl;
mod ansi_input;
mod native_hangul;

pub use self::ansi_input::prepare_hangul_input;
pub use self::native_hangul::{try_native_hangul_input, try_toad_ascii_input};

pub mod keycodes;
pub use self::win_impl::{Enigo, ENIGO_INPUT_EXTRA_VALUE};
