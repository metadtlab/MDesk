use crate::{bail, platform::windows::RAIIHandle, ResultType};
use std::{io, mem, ptr::null_mut};
use winapi::{
    shared::{minwindef::FALSE, winerror::ERROR_NO_TOKEN},
    um::{
        processthreadsapi::{
            GetCurrentProcess, GetCurrentProcessId, GetCurrentThread, OpenProcessToken,
            OpenThreadToken, ProcessIdToSessionId, SetThreadToken,
        },
        securitybaseapi::{
            CreateRestrictedToken, GetTokenInformation, ImpersonateLoggedOnUser, IsWellKnownSid,
            RevertToSelf,
        },
        winnt::{
            TokenElevation, TokenLinkedToken, TokenUser, WinLocalSystemSid, HANDLE,
            TOKEN_DUPLICATE, TOKEN_ELEVATION, TOKEN_IMPERSONATE, TOKEN_LINKED_TOKEN, TOKEN_QUERY,
            TOKEN_USER,
        },
        wtsapi32::WTSQueryUserToken,
    },
};

fn token_info<T: Default>(token: HANDLE, class: u32) -> ResultType<T> {
    let mut value = T::default();
    let mut written = 0;
    if unsafe {
        GetTokenInformation(
            token,
            class,
            &mut value as *mut _ as _,
            mem::size_of::<T>() as _,
            &mut written,
        )
    } == FALSE
    {
        return Err(io::Error::last_os_error().into());
    }
    Ok(value)
}

fn is_system(token: HANDLE) -> ResultType<bool> {
    let mut size = 0;
    unsafe {
        GetTokenInformation(token, TokenUser, null_mut(), 0, &mut size);
    }
    if size < mem::size_of::<TOKEN_USER>() as u32 {
        bail!("Cannot resolve file-access identity");
    }
    let mut buffer =
        vec![0usize; (size as usize + mem::size_of::<usize>() - 1) / mem::size_of::<usize>()];
    if unsafe { GetTokenInformation(token, TokenUser, buffer.as_mut_ptr() as _, size, &mut size) }
        == FALSE
    {
        return Err(io::Error::last_os_error().into());
    }
    let user = unsafe { &*(buffer.as_ptr() as *const TOKEN_USER) };
    Ok(unsafe { IsWellKnownSid(user.User.Sid, WinLocalSystemSid) } != FALSE)
}

fn elevated(token: HANDLE) -> ResultType<bool> {
    Ok(token_info::<TOKEN_ELEVATION>(token, TokenElevation)?.TokenIsElevated != 0)
}

// This guard never leaves a synchronous scope. Never hold it across .await or
// return lazy filesystem iterators that perform work after the guard is dropped.
pub(super) struct FileAccessGuard {
    previous: Option<RAIIHandle>,
    changed: bool,
}

impl FileAccessGuard {
    pub(super) fn enter() -> ResultType<Self> {
        let mut thread_token = null_mut();
        let previous = if unsafe {
            OpenThreadToken(
                GetCurrentThread(),
                TOKEN_QUERY | TOKEN_IMPERSONATE | TOKEN_DUPLICATE,
                1,
                &mut thread_token,
            )
        } != FALSE
        {
            Some(RAIIHandle(thread_token))
        } else {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(ERROR_NO_TOKEN as i32) {
                return Err(error.into());
            }
            None
        };
        let mut process_token = null_mut();
        if unsafe {
            OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY | TOKEN_DUPLICATE,
                &mut process_token,
            )
        } == FALSE
        {
            return Err(io::Error::last_os_error().into());
        }
        let process_token = RAIIHandle(process_token);
        let effective = previous.as_ref().unwrap_or(&process_token).0;
        let system = is_system(effective)?;
        if !system && !elevated(effective)? {
            return Ok(Self {
                previous,
                changed: false,
            });
        }
        let session_user;
        let user = if system {
            let mut session = 0;
            if unsafe { ProcessIdToSessionId(GetCurrentProcessId(), &mut session) } == FALSE
                || session == 0
            {
                bail!("File access requires a logged-on user session");
            }
            let mut token = null_mut();
            if unsafe { WTSQueryUserToken(session, &mut token) } == FALSE {
                return Err(io::Error::last_os_error().into());
            }
            session_user = RAIIHandle(token);
            session_user.0
        } else {
            effective
        };
        let linked;
        let limited = if elevated(user)? {
            linked = match token_info::<TOKEN_LINKED_TOKEN>(user, TokenLinkedToken) {
                Ok(token) => RAIIHandle(token.LinkedToken),
                Err(_) => {
                    // UAC-disabled/network logons may have no linked token. LUA_TOKEN
                    // removes administrator SIDs; DISABLE_MAX_PRIVILEGE removes all
                    // privileges except traversal. Never retry as the original token.
                    let mut token = null_mut();
                    if unsafe {
                        CreateRestrictedToken(
                            user,
                            0x1 | 0x4,
                            0,
                            null_mut(),
                            0,
                            null_mut(),
                            0,
                            null_mut(),
                            &mut token,
                        )
                    } == FALSE
                    {
                        return Err(io::Error::last_os_error().into());
                    }
                    RAIIHandle(token)
                }
            };
            linked.0
        } else {
            user
        };
        if is_system(limited)? || elevated(limited)? {
            bail!("Refusing privileged file access without a limited user token");
        }
        if unsafe { ImpersonateLoggedOnUser(limited) } == FALSE {
            return Err(io::Error::last_os_error().into());
        }
        Ok(Self {
            previous,
            changed: true,
        })
    }
}

impl Drop for FileAccessGuard {
    fn drop(&mut self) {
        if !self.changed {
            return;
        }
        let restored = unsafe {
            match self.previous.as_ref() {
                Some(previous) => SetThreadToken(null_mut(), previous.0),
                None => RevertToSelf(),
            }
        };
        if restored == FALSE {
            // Continuing on a thread with the wrong security identity is unsafe.
            std::process::abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn effective_identity() -> (bool, bool, bool) {
        let mut token = null_mut();
        let has_thread =
            unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) } != FALSE;
        if !has_thread {
            assert_eq!(
                io::Error::last_os_error().raw_os_error(),
                Some(ERROR_NO_TOKEN as i32)
            );
            assert_ne!(
                unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
                FALSE
            );
        }
        let token = RAIIHandle(token);
        (
            has_thread,
            is_system(token.0).unwrap(),
            elevated(token.0).unwrap(),
        )
    }

    #[test]
    fn file_access_scope_is_unprivileged_and_restores_thread() {
        let before = effective_identity();
        let _outer = FileAccessGuard::enter().unwrap();
        let mut token = null_mut();
        let has_thread =
            unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) } != FALSE;
        if !has_thread {
            assert_ne!(
                unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) },
                FALSE
            );
        }
        let token = RAIIHandle(token);
        assert!(!is_system(token.0).unwrap());
        assert!(!elevated(token.0).unwrap());
        let nested = FileAccessGuard::enter().unwrap();
        drop(nested);
        assert!(!effective_identity().2);
        drop(_outer);
        assert_eq!(effective_identity(), before);
    }

    #[test]
    fn user_file_access_denies_admin_only_file_and_restores_after_error() {
        use std::{fs, os::windows::ffi::OsStrExt};
        use winapi::shared::sddl::ConvertStringSecurityDescriptorToSecurityDescriptorW;
        use winapi::um::{
            securitybaseapi::SetFileSecurityW,
            winbase::LocalFree,
            winnt::{DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION},
        };
        let directory =
            std::env::temp_dir().join(format!("mdesk_file_acl_{}", crate::uuid::Uuid::new_v4()));
        fs::create_dir(&directory).unwrap();
        let public_file = directory.join("normal.txt");
        let protected_file = directory.join("admin-only.txt");
        fs::write(&public_file, b"normal").unwrap();
        fs::write(&protected_file, b"fixture, not a system file").unwrap();
        let sddl: Vec<u16> = "D:P(A;;FA;;;BA)(A;;FA;;;SY)"
            .encode_utf16()
            .chain(Some(0))
            .collect();
        let path: Vec<u16> = protected_file
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        let mut descriptor = null_mut();
        assert_ne!(
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    1,
                    &mut descriptor,
                    null_mut(),
                )
            },
            FALSE
        );
        let changed = unsafe {
            SetFileSecurityW(
                path.as_ptr(),
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                descriptor,
            )
        };
        unsafe {
            LocalFree(descriptor as _);
        }
        assert_ne!(changed, FALSE, "{}", io::Error::last_os_error());
        let before = effective_identity();
        assert!(super::super::open_file_for_read(&public_file).is_ok());
        assert!(super::super::open_file_for_read(&protected_file).is_err());
        assert_eq!(effective_identity(), before);
        if before.2 {
            assert!(
                fs::File::open(&protected_file).is_ok(),
                "original administrator identity must be restored"
            );
        }
        fs::remove_file(public_file).unwrap();
        fs::remove_file(protected_file).unwrap();
        fs::remove_dir(directory).unwrap();
    }
}
