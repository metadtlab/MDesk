//! Let the interactive GUI verify its SYSTEM server without elevating the GUI.
//! Only the service-owned server handle is changed; IPC peer validation stays intact.

use std::{
    ffi::c_void,
    mem::size_of,
    ptr::null_mut,
    time::{Duration, Instant},
};
use windows::{
    core::{Error, Result, BOOL},
    Win32::{
        Foundation::{
            CloseHandle, DuplicateHandle, LocalFree, DUPLICATE_SAME_ACCESS, ERROR_INVALID_ACL,
            ERROR_INVALID_SID, ERROR_NO_TOKEN, HANDLE, HLOCAL,
        },
        Security::{
            AddAccessAllowedAceEx, AddAce,
            Authorization::{GetSecurityInfo, SetSecurityInfo, SE_KERNEL_OBJECT},
            CopySid, EqualSid, GetAce, GetLengthSid, GetTokenInformation, InitializeAcl,
            IsValidSid, TokenLogonSid, ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, ACL_REVISION_DS,
            DACL_SECURITY_INFORMATION, NO_INHERITANCE, PSECURITY_DESCRIPTOR, PSID, TOKEN_GROUPS,
        },
        System::Threading::{GetCurrentProcess, GetProcessId, PROCESS_QUERY_LIMITED_INFORMATION},
    },
};

#[link(name = "Wtsapi32")]
extern "system" {
    fn WTSQueryUserToken(session_id: u32, token: *mut HANDLE) -> BOOL;
}

struct OwnedHandle(HANDLE);
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

struct LocalMemory(*mut c_void);
impl Drop for LocalMemory {
    fn drop(&mut self) {
        unsafe {
            let _ = LocalFree(Some(HLOCAL(self.0)));
        }
    }
}

// u32 storage keeps SIDs and ACLs DWORD-aligned; token data needs pointer alignment.
#[derive(Clone, PartialEq, Eq)]
struct Sid(Vec<u32>);
impl Sid {
    fn as_psid(&self) -> PSID {
        PSID(self.0.as_ptr() as *mut c_void)
    }

    unsafe fn copy(sid: PSID) -> Result<Self> {
        if !IsValidSid(sid).as_bool() {
            return Err(ERROR_INVALID_SID.into());
        }
        let length = GetLengthSid(sid);
        let mut copy = Self(vec![0; (length as usize + 3) / 4]);
        CopySid(length, PSID(copy.0.as_mut_ptr().cast()), sid)?;
        Ok(copy)
    }
}

fn session_logon_sid(session_id: u32) -> Result<Option<Sid>> {
    let mut token = HANDLE::default();
    unsafe {
        if !WTSQueryUserToken(session_id, &mut token).as_bool() {
            let error = Error::from_win32();
            // Before login/after logout there is no GUI to grant access to.
            return if error.code() == ERROR_NO_TOKEN.to_hresult() {
                Ok(None)
            } else {
                Err(error)
            };
        }
        let token = OwnedHandle(token);
        token_logon_sid(token.0).map(Some)
    }
}

fn token_logon_sid(token: HANDLE) -> Result<Sid> {
    unsafe {
        let mut length = 0;
        let _ = GetTokenInformation(token, TokenLogonSid, None, 0, &mut length);
        if length < size_of::<TOKEN_GROUPS>() as u32 {
            return Err(Error::from_win32());
        }
        let mut buffer =
            vec![0usize; (length as usize + size_of::<usize>() - 1) / size_of::<usize>()];
        GetTokenInformation(
            token,
            TokenLogonSid,
            Some(buffer.as_mut_ptr().cast()),
            length,
            &mut length,
        )?;
        let groups = &*buffer.as_ptr().cast::<TOKEN_GROUPS>();
        // SE_GROUP_LOGON_ID: this login only, not the account's other sessions.
        if groups.GroupCount != 1 || groups.Groups[0].Attributes & 0xc0000000 != 0xc0000000 {
            return Err(ERROR_INVALID_SID.into());
        }
        Sid::copy(groups.Groups[0].Sid)
    }
}

/// Copy every existing ACE verbatim. Remove at most the exact ACE previously
/// appended by us, then append a non-inheritable, limited-query-only grant.
/// Explicit denies remain ahead of this allow entry and are never bypassed.
unsafe fn query_acl(
    old: *const ACL,
    previous: Option<&Sid>,
    next: Option<&Sid>,
) -> Result<Vec<u32>> {
    if old.is_null() {
        return Err(ERROR_INVALID_ACL.into());
    }
    let extra = next.map_or(0, |sid| 8 + GetLengthSid(sid.as_psid()) as usize);
    let length = (*old).AclSize as usize + extra;
    if length > u16::MAX as usize {
        return Err(ERROR_INVALID_ACL.into());
    }
    let mut result = vec![0u32; (length + 3) / 4];
    let acl = result.as_mut_ptr().cast::<ACL>();
    InitializeAcl(acl, length as u32, ACL_REVISION_DS)?;
    let mut removed = false;
    let mut used = size_of::<ACL>();
    for index in 0..(*old).AceCount as u32 {
        let mut ace = null_mut();
        GetAce(old, index, &mut ace)?;
        let header = &*ace.cast::<ACE_HEADER>();
        if !removed && header.AceType == 0 && header.AceFlags == 0 {
            // ACCESS_ALLOWED_ACE_TYPE = 0. The SID begins at SidStart.
            let allowed = &*ace.cast::<ACCESS_ALLOWED_ACE>();
            if allowed.Mask == PROCESS_QUERY_LIMITED_INFORMATION.0
                && previous.is_some_and(|sid| {
                    EqualSid(
                        PSID((&allowed.SidStart as *const u32) as *mut c_void),
                        sid.as_psid(),
                    )
                    .is_ok()
                })
            {
                removed = true;
                continue;
            }
        }
        AddAce(acl, ACL_REVISION_DS, u32::MAX, ace, header.AceSize as u32)?;
        used += header.AceSize as usize;
    }
    if let Some(sid) = next {
        AddAccessAllowedAceEx(
            acl,
            ACL_REVISION_DS,
            NO_INHERITANCE,
            PROCESS_QUERY_LIMITED_INFORMATION.0,
            sid.as_psid(),
        )?;
        used += extra;
    }
    // Do not accumulate unused space on every logon/logout transition.
    (*acl).AclSize = used as u16;
    result.truncate((used + 3) / 4);
    Ok(result)
}

unsafe fn update_process_acl(
    process: HANDLE,
    previous: Option<&Sid>,
    next: Option<&Sid>,
) -> Result<()> {
    let mut old = null_mut();
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    GetSecurityInfo(
        process,
        SE_KERNEL_OBJECT,
        DACL_SECURITY_INFORMATION,
        None,
        None,
        Some(&mut old),
        None,
        Some(&mut descriptor),
    )
    .ok()?;
    let _descriptor = LocalMemory(descriptor.0);
    // A NULL DACL already allows query. Do not replace it with a restrictive ACL
    // that could break SYSTEM/service access, and do not record a grant we didn't add.
    if old.is_null() {
        return Err(ERROR_INVALID_ACL.into());
    }
    let acl = query_acl(old, previous, next)?;
    SetSecurityInfo(
        process,
        SE_KERNEL_OBJECT,
        DACL_SECURITY_INFORMATION,
        None,
        None,
        Some(acl.as_ptr().cast()),
        None,
    )
    .ok()
}

/// Kept by run_service, never by the GUI or by updater launches. A duplicate
/// handle keeps the cached PID valid even after the service replaces its handle.
#[derive(Default)]
pub(super) struct ServerQueryAccess {
    process: Option<OwnedHandle>,
    granted: Option<Sid>,
    next_check: Option<Instant>,
    last_error: Option<String>,
}

impl ServerQueryAccess {
    pub(super) fn refresh(&mut self, process: *mut c_void, session_id: u32) {
        if process.is_null() {
            return;
        }
        let process = HANDLE(process);
        let changed = self.process.as_ref().map_or(true, |old| unsafe {
            GetProcessId(old.0) != GetProcessId(process)
        });
        if !changed && self.next_check.is_some_and(|time| Instant::now() < time) {
            return;
        }
        self.next_check = Some(Instant::now() + Duration::from_secs(1));
        let result = self.refresh_inner(process, session_id, changed);
        match result {
            Ok(()) => {
                self.last_error = None;
            }
            Err(error) => {
                let message = format!(
                    "Server process query permission update failed (session {session_id}): {error}"
                );
                if self.last_error.as_ref() != Some(&message) {
                    hbb_common::log::warn!("{message}");
                    self.last_error = Some(message);
                }
            }
        }
    }

    fn refresh_inner(&mut self, process: HANDLE, session_id: u32, changed: bool) -> Result<()> {
        if changed {
            let mut duplicate = HANDLE::default();
            unsafe {
                DuplicateHandle(
                    GetCurrentProcess(),
                    process,
                    GetCurrentProcess(),
                    &mut duplicate,
                    0,
                    false,
                    DUPLICATE_SAME_ACCESS,
                )?;
            }
            self.process = Some(OwnedHandle(duplicate));
            self.granted = None;
        }
        let next = session_logon_sid(session_id)?;
        if self.granted != next {
            unsafe {
                update_process_acl(process, self.granted.as_ref(), next.as_ref())?;
            }
            self.granted = next;
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "server_query_access_tests.rs"]
mod tests;
