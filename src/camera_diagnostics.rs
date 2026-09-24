//! Synchronous milestones for diagnosing native camera/process aborts.
use hbb_common::log;
use std::{fmt, sync::Once};

pub const BUILD: &str = "camera-diag-20260919-1";

pub fn checkpoint(session: u64, stage: &str, detail: fmt::Arguments<'_>) {
    log::info!(
        "[CameraSession] pid={} session={} stage={} {}",
        std::process::id(),
        session,
        stage,
        detail
    );
    log::logger().flush();
}

pub fn initialize(process_role: &str) {
    log::info!(
        "[ProcessDiag] pid={} role={} build={} version={}",
        std::process::id(),
        process_role,
        BUILD,
        crate::VERSION
    );
    #[cfg(windows)]
    log::info!(
        "[ProcessDiag] pid={} windows_session={:?}",
        std::process::id(),
        crate::platform::get_current_process_session_id()
    );
    log::logger().flush();
    static HOOK: Once = Once::new();
    HOOK.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            // Arbitrary panic payloads may contain credentials or response bodies.
            // Record only code location and backtrace, preserving the existing hook.
            log::error!(
                "[ProcessDiag] pid={} event=rust_panic location={:?} backtrace={:?}",
                std::process::id(),
                info.location(),
                std::backtrace::Backtrace::force_capture()
            );
            log::logger().flush();
            previous(info);
        }));
    });
}

pub fn login_error_reason(error: &str) -> &'static str {
    match error {
        crate::client::LOGIN_MSG_PASSWORD_EMPTY => "password_empty",
        crate::client::LOGIN_MSG_PASSWORD_WRONG => "password_wrong",
        crate::client::REQUIRE_2FA => "two_factor_required",
        crate::client::LOGIN_MSG_2FA_WRONG => "two_factor_wrong",
        _ => crate::connection_diagnostics::error_kind(error),
    }
}
