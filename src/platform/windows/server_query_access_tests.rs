use super::*;
use windows::{
    core::PCWSTR,
    Win32::{
        Foundation::LUID,
        Security::{
            Authorization::*, GetSecurityDescriptorDacl, InitializeSecurityDescriptor,
            SetSecurityDescriptorDacl, SetSecurityDescriptorOwner, SECURITY_DESCRIPTOR,
        },
        System::Threading::{
            PROCESS_ALL_ACCESS, PROCESS_CREATE_THREAD, PROCESS_DUP_HANDLE, PROCESS_TERMINATE,
            PROCESS_VM_READ, PROCESS_VM_WRITE,
        },
    },
};

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(Some(0)).collect()
}

fn sid(value: &str) -> Sid {
    unsafe {
        let mut ptr = PSID::default();
        ConvertStringSidToSidW(PCWSTR(wide(value).as_ptr()), &mut ptr).unwrap();
        let _guard = LocalMemory(ptr.0);
        Sid::copy(ptr).unwrap()
    }
}

fn acl(sddl: &str) -> Vec<u32> {
    unsafe {
        let mut sd = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            PCWSTR(wide(sddl).as_ptr()),
            SDDL_REVISION_1,
            &mut sd,
            None,
        )
        .unwrap();
        let _guard = LocalMemory(sd.0);
        let mut present = BOOL::default();
        let mut defaulted = BOOL::default();
        let mut ptr = null_mut();
        GetSecurityDescriptorDacl(sd, &mut present, &mut ptr, &mut defaulted).unwrap();
        let bytes = (*ptr).AclSize as usize;
        let mut result = vec![0u32; (bytes + 3) / 4];
        std::ptr::copy_nonoverlapping(ptr.cast::<u8>(), result.as_mut_ptr().cast::<u8>(), bytes);
        result
    }
}

// Ask the Windows authorization engine about actual rights, not ACE layout.
fn allowed(acl: &[u32], sid: &Sid, mask: u32) -> bool {
    unsafe {
        let mut manager = AUTHZ_RESOURCE_MANAGER_HANDLE::default();
        AuthzInitializeResourceManager(
            AUTHZ_RM_FLAG_NO_AUDIT.0,
            None,
            None,
            None,
            PCWSTR::null(),
            &mut manager,
        )
        .unwrap();
        let mut context = AUTHZ_CLIENT_CONTEXT_HANDLE::default();
        AuthzInitializeContextFromSid(
            AUTHZ_SKIP_TOKEN_GROUPS,
            sid.as_psid(),
            manager,
            None,
            LUID::default(),
            None,
            &mut context,
        )
        .unwrap();
        let mut sd = SECURITY_DESCRIPTOR::default();
        let sd_ptr = PSECURITY_DESCRIPTOR((&mut sd as *mut SECURITY_DESCRIPTOR).cast());
        InitializeSecurityDescriptor(sd_ptr, 1).unwrap();
        let owner = super::tests::sid("S-1-5-18");
        SetSecurityDescriptorOwner(sd_ptr, Some(owner.as_psid()), false).unwrap();
        SetSecurityDescriptorDacl(sd_ptr, true, Some(acl.as_ptr().cast()), false).unwrap();
        let request = AUTHZ_ACCESS_REQUEST {
            DesiredAccess: mask,
            ..Default::default()
        };
        let mut granted = 0;
        let mut error = 0;
        let mut reply = AUTHZ_ACCESS_REPLY {
            ResultListLength: 1,
            GrantedAccessMask: &mut granted,
            Error: &mut error,
            ..Default::default()
        };
        let result = AuthzAccessCheck(
            AUTHZ_ACCESS_CHECK_FLAGS(0),
            context,
            &request,
            None,
            sd_ptr,
            None,
            &mut reply,
            None,
        );
        AuthzFreeContext(context).unwrap();
        AuthzFreeResourceManager(manager).unwrap();
        result.unwrap();
        error == 0 && granted & mask == mask
    }
}

#[test]
fn only_target_login_gains_limited_query() {
    let base = acl("D:(A;;0x1fffff;;;SY)(A;;0x1fffff;;;BA)");
    let login = sid("S-1-5-5-123-456");
    let other_login = sid("S-1-5-5-123-457");
    let updated = unsafe { query_acl(base.as_ptr().cast(), None, Some(&login)).unwrap() };
    assert!(!allowed(&base, &login, PROCESS_QUERY_LIMITED_INFORMATION.0));
    assert!(allowed(
        &updated,
        &login,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
    assert!(!allowed(
        &updated,
        &other_login,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
    for mask in [
        PROCESS_TERMINATE.0,
        PROCESS_VM_READ.0,
        PROCESS_VM_WRITE.0,
        PROCESS_CREATE_THREAD.0,
        PROCESS_DUP_HANDLE.0,
        0x40000, /* WRITE_DAC */
    ] {
        assert!(
            !allowed(&updated, &login, mask),
            "unexpected access: {mask:x}"
        );
    }
    assert!(allowed(&updated, &sid("S-1-5-18"), PROCESS_ALL_ACCESS.0));
    assert!(allowed(
        &updated,
        &sid("S-1-5-32-544"),
        PROCESS_ALL_ACCESS.0
    ));
}

#[test]
fn login_change_and_logout_remove_only_our_grant() {
    let first = sid("S-1-5-5-123-456");
    let second = sid("S-1-5-5-123-457");
    // Existing unrelated read access is preserved across login transitions.
    let base = acl("D:(A;;0x1fffff;;;SY)(A;;0x10;;;S-1-5-5-123-456)");
    let first_acl = unsafe { query_acl(base.as_ptr().cast(), None, Some(&first)).unwrap() };
    let second_acl =
        unsafe { query_acl(first_acl.as_ptr().cast(), Some(&first), Some(&second)).unwrap() };
    assert!(!allowed(
        &second_acl,
        &first,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
    assert!(allowed(&second_acl, &first, PROCESS_VM_READ.0));
    assert!(allowed(
        &second_acl,
        &second,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
    let logout = unsafe { query_acl(second_acl.as_ptr().cast(), Some(&second), None).unwrap() };
    assert!(!allowed(
        &logout,
        &second,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
    assert!(allowed(&logout, &sid("S-1-5-18"), PROCESS_ALL_ACCESS.0));
}

#[test]
fn existing_query_grant_survives_removing_our_duplicate() {
    let login = sid("S-1-5-5-123-456");
    let base = acl("D:(A;;0x1fffff;;;SY)(A;;0x1000;;;S-1-5-5-123-456)");
    let updated = unsafe { query_acl(base.as_ptr().cast(), None, Some(&login)).unwrap() };
    let restored = unsafe { query_acl(updated.as_ptr().cast(), Some(&login), None).unwrap() };
    assert!(allowed(
        &restored,
        &login,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
}

#[test]
fn explicit_deny_is_not_bypassed() {
    let login = sid("S-1-5-5-123-456");
    let base = acl("D:(D;;0x1000;;;S-1-5-5-123-456)(A;;0x1fffff;;;SY)");
    let updated = unsafe { query_acl(base.as_ptr().cast(), None, Some(&login)).unwrap() };
    assert!(!allowed(
        &updated,
        &login,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
}

#[test]
fn null_dacl_is_not_replaced_with_query_only_dacl() {
    let login = sid("S-1-5-5-123-456");
    assert!(unsafe { query_acl(std::ptr::null(), None, Some(&login)) }.is_err());
}

#[test]
fn repeated_login_changes_do_not_grow_the_acl() {
    let login = sid("S-1-5-5-123-456");
    let base = acl("D:(A;;0x1fffff;;;SY)");
    let mut current = base.clone();
    for _ in 0..3000 {
        current = unsafe { query_acl(current.as_ptr().cast(), None, Some(&login)).unwrap() };
        current = unsafe { query_acl(current.as_ptr().cast(), Some(&login), None).unwrap() };
    }
    assert!(allowed(&current, &sid("S-1-5-18"), PROCESS_ALL_ACCESS.0));
    assert!(!allowed(
        &current,
        &login,
        PROCESS_QUERY_LIMITED_INFORMATION.0
    ));
    assert_eq!(current.len(), base.len());
}

#[test]
#[ignore = "child process used only by kernel_process_query_recovers"]
fn query_access_test_child() {
    assert_eq!(
        std::env::var("MDESK_QUERY_ACCESS_TEST_CHILD").as_deref(),
        Ok("1")
    );
    std::thread::sleep(Duration::from_secs(60));
}

#[test]
fn kernel_process_query_recovers() {
    use std::os::windows::{io::AsRawHandle, process::CommandExt};
    use windows::Win32::{
        Security::{
            CreateRestrictedToken, ImpersonateLoggedOnUser, RevertToSelf, DISABLE_MAX_PRIVILEGE,
            TOKEN_ALL_ACCESS,
        },
        System::Threading::{
            OpenProcess, OpenProcessToken, QueryFullProcessImageNameW, CREATE_NO_WINDOW,
            PROCESS_NAME_WIN32,
        },
    };

    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    struct Impersonation;
    impl Drop for Impersonation {
        fn drop(&mut self) {
            unsafe {
                RevertToSelf().unwrap();
            }
        }
    }
    let child = Child(
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--ignored", "query_access_test_child"])
            // The actual test path differs between the product and isolated harness.
            .env("MDESK_QUERY_ACCESS_TEST_CHILD", "1")
            .creation_flags(CREATE_NO_WINDOW.0)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap(),
    );
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &mut token).unwrap();
        let token = OwnedHandle(token);
        let login = token_logon_sid(token.0).unwrap();
        let mut restricted = HANDLE::default();
        CreateRestrictedToken(
            token.0,
            DISABLE_MAX_PRIVILEGE,
            None,
            None,
            None,
            &mut restricted,
        )
        .unwrap();
        let restricted = OwnedHandle(restricted);
        let process = HANDLE(child.0.as_raw_handle());
        let base = acl("D:(A;;0x1fffff;;;SY)");
        SetSecurityInfo(
            process,
            SE_KERNEL_OBJECT,
            DACL_SECURITY_INFORMATION,
            None,
            None,
            Some(base.as_ptr().cast()),
            None,
        )
        .ok()
        .unwrap();
        // Disable debug privilege: the access check must use the DACL.
        ImpersonateLoggedOnUser(restricted.0).unwrap();
        {
            let _guard = Impersonation;
            assert!(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, child.0.id()).is_err());
        }
        update_process_acl(process, None, Some(&login)).unwrap();
        ImpersonateLoggedOnUser(restricted.0).unwrap();
        {
            let _guard = Impersonation;
            let query = OwnedHandle(
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, child.0.id()).unwrap(),
            );
            let mut path = vec![0u16; 32768];
            let mut length = path.len() as u32;
            QueryFullProcessImageNameW(
                query.0,
                PROCESS_NAME_WIN32,
                windows::core::PWSTR(path.as_mut_ptr()),
                &mut length,
            )
            .unwrap();
            assert!(length > 0);
            assert!(OpenProcess(PROCESS_TERMINATE, false, child.0.id()).is_err());
            assert!(OpenProcess(PROCESS_VM_READ, false, child.0.id()).is_err());
        }
    }
}
