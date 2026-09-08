//! windows implementation
#![allow(dead_code)]
#![allow(non_camel_case_types)]
#![allow(unused_variables)]
#![allow(non_snake_case)]
#![allow(deref_nullptr)]

use crate::{
    send_data, ClipboardFile, CliprdrError, CliprdrServiceContext, ProgressPercent, ResultType,
    ERR_CODE_INVALID_PARAMETER, ERR_CODE_SEND_MSG, ERR_CODE_SERVER_FUNCTION_NONE, VEC_MSG_CHANNEL,
};
use hbb_common::{allow_err, log};
use std::{
    boxed::Box,
    ffi::{CStr, CString},
    result::Result,
};

extern "system" {
    fn GetClipboardSequenceNumber() -> u32;
    fn IsClipboardFormatAvailable(format: u32) -> i32;
    fn RegisterClipboardFormatA(name: *const u8) -> u32;
    fn GlobalAlloc(flags: u32, size: usize) -> *mut std::ffi::c_void;
    fn GlobalLock(memory: *mut std::ffi::c_void) -> *mut u8;
    fn GlobalUnlock(memory: *mut std::ffi::c_void) -> i32;
    fn GlobalFree(memory: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
}
#[link(name = "kernel32")]
extern "system" {
    fn FindFirstFileW(path: *const u16, data: *mut std::ffi::c_void) -> *mut std::ffi::c_void;
}

#[no_mangle]
pub unsafe extern "C" fn mdesk_clipboard_find_first_file(
    path: *const u16, data: *mut std::ffi::c_void,
) -> *mut std::ffi::c_void {
    let denied = -1isize as *mut std::ffi::c_void;
    if path.is_null() || data.is_null() { return denied; }
    hbb_common::fs::with_user_file_access(|| {
        let handle = FindFirstFileW(path, data);
        if handle == denied { return Err(std::io::Error::last_os_error().into()); }
        Ok(handle)
    }).unwrap_or(denied)
}
thread_local! { static METADATA_RESPONSE: std::cell::RefCell<Option<crate::file_stream::Frame>> = const { std::cell::RefCell::new(None) }; }

#[no_mangle]
pub unsafe extern "C" fn mdesk_clipboard_open_file_for_read(path: *const u16) -> *mut std::ffi::c_void {
    use std::os::windows::{ffi::OsStringExt, fs::OpenOptionsExt, io::IntoRawHandle};
    let denied = -1isize as *mut std::ffi::c_void;
    if path.is_null() { return denied; }
    let mut length = 0;
    while length < 32768 && *path.add(length) != 0 { length += 1; }
    if length == 32768 { return denied; }
    let path = std::ffi::OsString::from_wide(std::slice::from_raw_parts(path, length));
    hbb_common::fs::with_user_file_access(|| {
        Ok(std::fs::OpenOptions::new().read(true).share_mode(1)
            .custom_flags(0x02000000).open(std::path::Path::new(&path))?)
    }).map(|file| file.into_raw_handle()).unwrap_or(denied)
}

#[no_mangle]
pub unsafe extern "C" fn mdesk_clipboard_descriptors(
    conn: u32,
    generation: u64,
    format: u32,
    len: *mut usize,
) -> *mut std::ffi::c_void {
    if len.is_null() {
        return std::ptr::null_mut();
    }
    *len = 0;
    let Ok(data) = crate::file_stream::descriptors(conn as i32, generation, format) else {
        return std::ptr::null_mut();
    };
    let memory = GlobalAlloc(0x42, data.len());
    if memory.is_null() {
        return memory;
    }
    let output = GlobalLock(memory);
    if output.is_null() {
        GlobalFree(memory);
        return std::ptr::null_mut();
    }
    std::ptr::copy_nonoverlapping(data.as_ptr(), output, data.len());
    GlobalUnlock(memory);
    *len = data.len();
    memory
}

#[no_mangle]
pub extern "C" fn mdesk_clipboard_remote_generation(conn: u32) -> u64 {
    crate::file_stream::remote_generation(conn as i32)
}

#[no_mangle]
pub unsafe extern "C" fn mdesk_clipboard_stream_read(
    conn: u32,
    generation: u64,
    index: u32,
    size: u64,
    offset: u64,
    output: *mut u8,
    requested: u32,
    read: *mut u32,
    token: *mut u64,
) -> i32 {
    if output.is_null() || read.is_null() || token.is_null() {
        return -1;
    }
    *read = 0;
    match crate::file_stream::read(
        conn as i32,
        generation,
        index,
        size,
        offset,
        std::slice::from_raw_parts_mut(output, requested as usize),
        &mut *token,
    ) {
        Ok(n) => {
            *read = n as u32;
            0
        }
        Err(e) => {
            log::warn!("Native clipboard file read failed: {}", e);
            crate::file_stream::release(conn as i32, *token);
            *token = 0;
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn mdesk_clipboard_stream_release(conn: u32, token: u64) {
    crate::file_stream::release(conn as i32, token);
}

#[no_mangle]
pub unsafe extern "C" fn mdesk_clipboard_source_snapshot(
    sequence: u32,
    count: u32,
    paths: *const *const u16,
) {
    use std::os::windows::ffi::OsStringExt;
    if paths.is_null() || count > 16384 {
        return;
    }
    let paths = std::slice::from_raw_parts(paths, count as usize)
        .iter()
        .map(|p| {
            if p.is_null() {
                return None;
            }
            let mut len = 0;
            while len < 32768 && *p.add(len) != 0 {
                len += 1;
            }
            if len == 32768 {
                return None;
            }
            let path = std::path::PathBuf::from(std::ffi::OsString::from_wide(
                std::slice::from_raw_parts(*p, len),
            ));
            path.is_absolute().then_some(path)
        })
        .collect();
    crate::file_stream::snapshot(sequence, paths);
}

// only used error code will be recorded here
/// success
const CHANNEL_RC_OK: u32 = 0;
/// error code from WinError.h
/// success
const ERROR_SUCCESS: u32 = 0;
/// allocation failure
const CHANNEL_RC_NO_MEMORY: u32 = 12;
/// error code from WinError.h
/// used by FreeRDP to represent errors.
const ERROR_INTERNAL_ERROR: u32 = 0x54F;

pub type size_t = ::std::os::raw::c_ulonglong;
pub type __vcrt_bool = bool;
pub type wchar_t = ::std::os::raw::c_ushort;

pub type POINTER_64_INT = ::std::os::raw::c_ulonglong;
pub type INT8 = ::std::os::raw::c_schar;
pub type PINT8 = *mut ::std::os::raw::c_schar;
pub type INT16 = ::std::os::raw::c_short;
pub type PINT16 = *mut ::std::os::raw::c_short;
pub type INT32 = ::std::os::raw::c_int;
pub type PINT32 = *mut ::std::os::raw::c_int;
pub type INT64 = ::std::os::raw::c_longlong;
pub type PINT64 = *mut ::std::os::raw::c_longlong;
pub type UINT8 = ::std::os::raw::c_uchar;
pub type PUINT8 = *mut ::std::os::raw::c_uchar;
pub type UINT16 = ::std::os::raw::c_ushort;
pub type PUINT16 = *mut ::std::os::raw::c_ushort;
pub type UINT32 = ::std::os::raw::c_uint;
pub type PUINT32 = *mut ::std::os::raw::c_uint;
pub type UINT64 = ::std::os::raw::c_ulonglong;
pub type PUINT64 = *mut ::std::os::raw::c_ulonglong;
pub type LONG32 = ::std::os::raw::c_int;
pub type PLONG32 = *mut ::std::os::raw::c_int;
pub type ULONG32 = ::std::os::raw::c_uint;
pub type PULONG32 = *mut ::std::os::raw::c_uint;
pub type DWORD32 = ::std::os::raw::c_uint;
pub type PDWORD32 = *mut ::std::os::raw::c_uint;
pub type INT_PTR = ::std::os::raw::c_longlong;
pub type PINT_PTR = *mut ::std::os::raw::c_longlong;
pub type UINT_PTR = ::std::os::raw::c_ulonglong;
pub type PUINT_PTR = *mut ::std::os::raw::c_ulonglong;
pub type LONG_PTR = ::std::os::raw::c_longlong;
pub type PLONG_PTR = *mut ::std::os::raw::c_longlong;
pub type ULONG_PTR = ::std::os::raw::c_ulonglong;
pub type PULONG_PTR = *mut ::std::os::raw::c_ulonglong;
pub type SHANDLE_PTR = ::std::os::raw::c_longlong;
pub type HANDLE_PTR = ::std::os::raw::c_ulonglong;
pub type UHALF_PTR = ::std::os::raw::c_uint;
pub type PUHALF_PTR = *mut ::std::os::raw::c_uint;
pub type HALF_PTR = ::std::os::raw::c_int;
pub type PHALF_PTR = *mut ::std::os::raw::c_int;
pub type SIZE_T = ULONG_PTR;
pub type PSIZE_T = *mut ULONG_PTR;
pub type SSIZE_T = LONG_PTR;
pub type PSSIZE_T = *mut LONG_PTR;
pub type DWORD_PTR = ULONG_PTR;
pub type PDWORD_PTR = *mut ULONG_PTR;
pub type LONG64 = ::std::os::raw::c_longlong;
pub type PLONG64 = *mut ::std::os::raw::c_longlong;
pub type ULONG64 = ::std::os::raw::c_ulonglong;
pub type PULONG64 = *mut ::std::os::raw::c_ulonglong;
pub type DWORD64 = ::std::os::raw::c_ulonglong;
pub type PDWORD64 = *mut ::std::os::raw::c_ulonglong;
pub type KAFFINITY = ULONG_PTR;
pub type PKAFFINITY = *mut KAFFINITY;
pub type PVOID = *mut ::std::os::raw::c_void;
pub type CHAR = ::std::os::raw::c_char;
pub type SHORT = ::std::os::raw::c_short;
pub type LONG = ::std::os::raw::c_long;
pub type WCHAR = wchar_t;
pub type PWCHAR = *mut WCHAR;
pub type LPWCH = *mut WCHAR;
pub type PWCH = *mut WCHAR;
pub type LPCWCH = *const WCHAR;
pub type PCWCH = *const WCHAR;
pub type NWPSTR = *mut WCHAR;
pub type LPWSTR = *mut WCHAR;
pub type PWSTR = *mut WCHAR;
pub type PZPWSTR = *mut PWSTR;
pub type PCZPWSTR = *const PWSTR;
pub type LPUWSTR = *mut WCHAR;
pub type PUWSTR = *mut WCHAR;
pub type LPCWSTR = *const WCHAR;
pub type PCWSTR = *const WCHAR;
pub type PZPCWSTR = *mut PCWSTR;
pub type PCZPCWSTR = *const PCWSTR;
pub type LPCUWSTR = *const WCHAR;
pub type PCUWSTR = *const WCHAR;
pub type PZZWSTR = *mut WCHAR;
pub type PCZZWSTR = *const WCHAR;
pub type PUZZWSTR = *mut WCHAR;
pub type PCUZZWSTR = *const WCHAR;
pub type PNZWCH = *mut WCHAR;
pub type PCNZWCH = *const WCHAR;
pub type PUNZWCH = *mut WCHAR;
pub type PCUNZWCH = *const WCHAR;
pub type PCHAR = *mut CHAR;
pub type LPCH = *mut CHAR;
pub type PCH = *mut CHAR;
pub type LPCCH = *const CHAR;
pub type PCCH = *const CHAR;
pub type NPSTR = *mut CHAR;
pub type LPSTR = *mut CHAR;
pub type PSTR = *mut CHAR;
pub type PZPSTR = *mut PSTR;
pub type PCZPSTR = *const PSTR;
pub type LPCSTR = *const CHAR;
pub type PCSTR = *const CHAR;
pub type PZPCSTR = *mut PCSTR;
pub type PCZPCSTR = *const PCSTR;
pub type PZZSTR = *mut CHAR;
pub type PCZZSTR = *const CHAR;
pub type PNZCH = *mut CHAR;
pub type PCNZCH = *const CHAR;
pub type TCHAR = ::std::os::raw::c_char;
pub type PTCHAR = *mut ::std::os::raw::c_char;
pub type TBYTE = ::std::os::raw::c_uchar;
pub type PTBYTE = *mut ::std::os::raw::c_uchar;
pub type LPTCH = LPCH;
pub type PTCH = LPCH;
pub type LPCTCH = LPCCH;
pub type PCTCH = LPCCH;
pub type PTSTR = LPSTR;
pub type LPTSTR = LPSTR;
pub type PUTSTR = LPSTR;
pub type LPUTSTR = LPSTR;
pub type PCTSTR = LPCSTR;
pub type LPCTSTR = LPCSTR;
pub type PCUTSTR = LPCSTR;
pub type LPCUTSTR = LPCSTR;
pub type PZZTSTR = PZZSTR;
pub type PUZZTSTR = PZZSTR;
pub type PCZZTSTR = PCZZSTR;
pub type PCUZZTSTR = PCZZSTR;
pub type PZPTSTR = PZPSTR;
pub type PNZTCH = PNZCH;
pub type PUNZTCH = PNZCH;
pub type PCNZTCH = PCNZCH;
pub type PCUNZTCH = PCNZCH;
pub type PSHORT = *mut SHORT;
pub type PLONG = *mut LONG;
pub type ULONG = ::std::os::raw::c_ulong;
pub type PULONG = *mut ULONG;
pub type USHORT = ::std::os::raw::c_ushort;
pub type PUSHORT = *mut USHORT;
pub type UCHAR = ::std::os::raw::c_uchar;
pub type PUCHAR = *mut UCHAR;
pub type PSZ = *mut ::std::os::raw::c_char;
pub type DWORD = ::std::os::raw::c_ulong;
pub type BOOL = ::std::os::raw::c_int;
pub type BYTE = ::std::os::raw::c_uchar;
pub type WORD = ::std::os::raw::c_ushort;
pub type FLOAT = f32;
pub type PFLOAT = *mut FLOAT;
pub type PBOOL = *mut BOOL;
pub type LPBOOL = *mut BOOL;
pub type PBYTE = *mut BYTE;
pub type LPBYTE = *mut BYTE;
pub type PINT = *mut ::std::os::raw::c_int;
pub type LPINT = *mut ::std::os::raw::c_int;
pub type PWORD = *mut WORD;
pub type LPWORD = *mut WORD;
pub type LPLONG = *mut ::std::os::raw::c_long;
pub type PDWORD = *mut DWORD;
pub type LPDWORD = *mut DWORD;
pub type LPVOID = *mut ::std::os::raw::c_void;
pub type LPCVOID = *const ::std::os::raw::c_void;
pub type INT = ::std::os::raw::c_int;
pub type UINT = ::std::os::raw::c_uint;
pub type PUINT = *mut ::std::os::raw::c_uint;
pub type va_list = *mut ::std::os::raw::c_char;

pub const TRUE: ::std::os::raw::c_int = 1;
pub const FALSE: ::std::os::raw::c_int = 0;

#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_HEADER {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
}
pub type CLIPRDR_HEADER = _CLIPRDR_HEADER;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_CAPABILITY_SET {
    pub capabilitySetType: UINT16,
    pub capabilitySetLength: UINT16,
}
pub type CLIPRDR_CAPABILITY_SET = _CLIPRDR_CAPABILITY_SET;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_GENERAL_CAPABILITY_SET {
    pub capabilitySetType: UINT16,
    pub capabilitySetLength: UINT16,
    pub version: UINT32,
    pub generalFlags: UINT32,
}
pub type CLIPRDR_GENERAL_CAPABILITY_SET = _CLIPRDR_GENERAL_CAPABILITY_SET;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_CAPABILITIES {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub cCapabilitiesSets: UINT32,
    pub capabilitySets: *mut CLIPRDR_CAPABILITY_SET,
}
pub type CLIPRDR_CAPABILITIES = _CLIPRDR_CAPABILITIES;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_MONITOR_READY {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
}
pub type CLIPRDR_MONITOR_READY = _CLIPRDR_MONITOR_READY;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_TEMP_DIRECTORY {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub szTempDir: [::std::os::raw::c_char; 520usize],
}
pub type CLIPRDR_TEMP_DIRECTORY = _CLIPRDR_TEMP_DIRECTORY;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_FORMAT {
    pub formatId: UINT32,
    pub formatName: *mut ::std::os::raw::c_char,
}
pub type CLIPRDR_FORMAT = _CLIPRDR_FORMAT;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_FORMAT_LIST {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub numFormats: UINT32,
    pub formats: *mut CLIPRDR_FORMAT,
}
pub type CLIPRDR_FORMAT_LIST = _CLIPRDR_FORMAT_LIST;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_FORMAT_LIST_RESPONSE {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
}
pub type CLIPRDR_FORMAT_LIST_RESPONSE = _CLIPRDR_FORMAT_LIST_RESPONSE;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_LOCK_CLIPBOARD_DATA {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub clipDataId: UINT32,
}
pub type CLIPRDR_LOCK_CLIPBOARD_DATA = _CLIPRDR_LOCK_CLIPBOARD_DATA;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_UNLOCK_CLIPBOARD_DATA {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub clipDataId: UINT32,
}
pub type CLIPRDR_UNLOCK_CLIPBOARD_DATA = _CLIPRDR_UNLOCK_CLIPBOARD_DATA;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_FORMAT_DATA_REQUEST {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub requestedFormatId: UINT32,
}
pub type CLIPRDR_FORMAT_DATA_REQUEST = _CLIPRDR_FORMAT_DATA_REQUEST;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_FORMAT_DATA_RESPONSE {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub requestedFormatData: *const BYTE,
}
pub type CLIPRDR_FORMAT_DATA_RESPONSE = _CLIPRDR_FORMAT_DATA_RESPONSE;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_FILE_CONTENTS_REQUEST {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub streamId: UINT32,
    pub listIndex: UINT32,
    pub dwFlags: UINT32,
    pub nPositionLow: UINT32,
    pub nPositionHigh: UINT32,
    pub cbRequested: UINT32,
    pub haveClipDataId: BOOL,
    pub clipDataId: UINT32,
}
pub type CLIPRDR_FILE_CONTENTS_REQUEST = _CLIPRDR_FILE_CONTENTS_REQUEST;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _CLIPRDR_FILE_CONTENTS_RESPONSE {
    pub connID: UINT32,
    pub msgType: UINT16,
    pub msgFlags: UINT16,
    pub dataLen: UINT32,
    pub streamId: UINT32,
    pub cbRequested: UINT32,
    pub requestedData: *const BYTE,
}
pub type CLIPRDR_FILE_CONTENTS_RESPONSE = _CLIPRDR_FILE_CONTENTS_RESPONSE;
pub type CliprdrClientContext = _cliprdr_client_context;
#[repr(C)]
#[derive(Debug, Copy, Clone)]
pub struct _NOTIFICATION_MESSAGE {
    pub r#type: UINT32, // 0 - info, 1 - warning, 2 - error
    pub msg: *const BYTE,
    pub details: *const BYTE,
}
pub type NOTIFICATION_MESSAGE = _NOTIFICATION_MESSAGE;
pub type pcCliprdrServerCapabilities = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        capabilities: *const CLIPRDR_CAPABILITIES,
    ) -> UINT,
>;
pub type pcCliprdrClientCapabilities = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        capabilities: *const CLIPRDR_CAPABILITIES,
    ) -> UINT,
>;
pub type pcCliprdrMonitorReady = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        monitorReady: *const CLIPRDR_MONITOR_READY,
    ) -> UINT,
>;
pub type pcCliprdrTempDirectory = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        tempDirectory: *const CLIPRDR_TEMP_DIRECTORY,
    ) -> UINT,
>;
pub type pcNotifyClipboardMsg = ::std::option::Option<
    unsafe extern "C" fn(connID: UINT32, msg: *const NOTIFICATION_MESSAGE) -> UINT,
>;
pub type pcHandleClipboardFiles = ::std::option::Option<
    unsafe extern "C" fn(connID: UINT32, nFiles: size_t, fileNames: *mut *mut WCHAR) -> UINT,
>;
pub type pcCliprdrClientFormatList = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatList: *const CLIPRDR_FORMAT_LIST,
    ) -> UINT,
>;
pub type pcCliprdrServerFormatList = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatList: *const CLIPRDR_FORMAT_LIST,
    ) -> UINT,
>;
pub type pcCliprdrClientFormatListResponse = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatListResponse: *const CLIPRDR_FORMAT_LIST_RESPONSE,
    ) -> UINT,
>;
pub type pcCliprdrServerFormatListResponse = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatListResponse: *const CLIPRDR_FORMAT_LIST_RESPONSE,
    ) -> UINT,
>;
pub type pcCliprdrClientLockClipboardData = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        lockClipboardData: *const CLIPRDR_LOCK_CLIPBOARD_DATA,
    ) -> UINT,
>;
pub type pcCliprdrServerLockClipboardData = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        lockClipboardData: *const CLIPRDR_LOCK_CLIPBOARD_DATA,
    ) -> UINT,
>;
pub type pcCliprdrClientUnlockClipboardData = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        unlockClipboardData: *const CLIPRDR_UNLOCK_CLIPBOARD_DATA,
    ) -> UINT,
>;
pub type pcCliprdrServerUnlockClipboardData = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        unlockClipboardData: *const CLIPRDR_UNLOCK_CLIPBOARD_DATA,
    ) -> UINT,
>;
pub type pcCliprdrClientFormatDataRequest = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatDataRequest: *const CLIPRDR_FORMAT_DATA_REQUEST,
    ) -> UINT,
>;
pub type pcCliprdrServerFormatDataRequest = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatDataRequest: *const CLIPRDR_FORMAT_DATA_REQUEST,
    ) -> UINT,
>;
pub type pcCliprdrClientFormatDataResponse = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatDataResponse: *const CLIPRDR_FORMAT_DATA_RESPONSE,
    ) -> UINT,
>;
pub type pcCliprdrServerFormatDataResponse = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        formatDataResponse: *const CLIPRDR_FORMAT_DATA_RESPONSE,
    ) -> UINT,
>;
pub type pcCliprdrClientFileContentsRequest = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        fileContentsRequest: *const CLIPRDR_FILE_CONTENTS_REQUEST,
    ) -> UINT,
>;
pub type pcCliprdrServerFileContentsRequest = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        fileContentsRequest: *const CLIPRDR_FILE_CONTENTS_REQUEST,
    ) -> UINT,
>;
pub type pcCliprdrClientFileContentsResponse = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        fileContentsResponse: *const CLIPRDR_FILE_CONTENTS_RESPONSE,
    ) -> UINT,
>;
pub type pcCliprdrServerFileContentsResponse = ::std::option::Option<
    unsafe extern "C" fn(
        context: *mut CliprdrClientContext,
        fileContentsResponse: *const CLIPRDR_FILE_CONTENTS_RESPONSE,
    ) -> UINT,
>;

// TODO: hide more members of clipboard context
#[repr(C)]
#[derive(Debug, Clone)]
pub struct _cliprdr_client_context {
    pub Custom: *mut ::std::os::raw::c_void,
    pub EnableFiles: BOOL,
    pub EnableOthers: BOOL,
    pub IsStopped: BOOL,
    pub ResponseWaitTimeoutSecs: UINT32,
    pub ServerCapabilities: pcCliprdrServerCapabilities,
    pub ClientCapabilities: pcCliprdrClientCapabilities,
    pub MonitorReady: pcCliprdrMonitorReady,
    pub TempDirectory: pcCliprdrTempDirectory,
    pub NotifyClipboardMsg: pcNotifyClipboardMsg,
    pub HandleClipboardFiles: pcHandleClipboardFiles,
    pub ClientFormatList: pcCliprdrClientFormatList,
    pub ServerFormatList: pcCliprdrServerFormatList,
    pub ClientFormatListResponse: pcCliprdrClientFormatListResponse,
    pub ServerFormatListResponse: pcCliprdrServerFormatListResponse,
    pub ClientLockClipboardData: pcCliprdrClientLockClipboardData,
    pub ServerLockClipboardData: pcCliprdrServerLockClipboardData,
    pub ClientUnlockClipboardData: pcCliprdrClientUnlockClipboardData,
    pub ServerUnlockClipboardData: pcCliprdrServerUnlockClipboardData,
    pub ClientFormatDataRequest: pcCliprdrClientFormatDataRequest,
    pub ServerFormatDataRequest: pcCliprdrServerFormatDataRequest,
    pub ClientFormatDataResponse: pcCliprdrClientFormatDataResponse,
    pub ServerFormatDataResponse: pcCliprdrServerFormatDataResponse,
    pub ClientFileContentsRequest: pcCliprdrClientFileContentsRequest,
    pub ServerFileContentsRequest: pcCliprdrServerFileContentsRequest,
    pub ClientFileContentsResponse: pcCliprdrClientFileContentsResponse,
    pub ServerFileContentsResponse: pcCliprdrServerFileContentsResponse,
    pub LastRequestedFormatId: UINT32,
}

// #[link(name = "user32")]
// #[link(name = "ole32")]
extern "C" {
    pub(crate) fn init_cliprdr(context: *mut CliprdrClientContext) -> BOOL;
    pub(crate) fn uninit_cliprdr(context: *mut CliprdrClientContext) -> BOOL;
    pub(crate) fn empty_cliprdr(context: *mut CliprdrClientContext, connID: UINT32) -> BOOL;
}

unsafe impl Send for CliprdrClientContext {}

unsafe impl Sync for CliprdrClientContext {}

impl CliprdrClientContext {
    pub fn create(
        enable_files: bool,
        enable_others: bool,
        response_wait_timeout_secs: u32,
        notify_callback: pcNotifyClipboardMsg,
        handle_clipboard_files: pcHandleClipboardFiles,
        client_format_list: pcCliprdrClientFormatList,
        client_format_list_response: pcCliprdrClientFormatListResponse,
        client_format_data_request: pcCliprdrClientFormatDataRequest,
        client_format_data_response: pcCliprdrClientFormatDataResponse,
        client_file_contents_request: pcCliprdrClientFileContentsRequest,
        client_file_contents_response: pcCliprdrClientFileContentsResponse,
    ) -> Result<Box<Self>, CliprdrError> {
        let context = CliprdrClientContext {
            Custom: 0 as *mut _,
            EnableFiles: if enable_files { TRUE } else { FALSE },
            EnableOthers: if enable_others { TRUE } else { FALSE },
            IsStopped: FALSE,
            ResponseWaitTimeoutSecs: response_wait_timeout_secs,
            ServerCapabilities: None,
            ClientCapabilities: None,
            MonitorReady: None,
            TempDirectory: None,
            NotifyClipboardMsg: notify_callback,
            HandleClipboardFiles: handle_clipboard_files,
            ClientFormatList: client_format_list,
            ServerFormatList: None,
            ClientFormatListResponse: client_format_list_response,
            ServerFormatListResponse: None,
            ClientLockClipboardData: None,
            ServerLockClipboardData: None,
            ClientUnlockClipboardData: None,
            ServerUnlockClipboardData: None,
            ClientFormatDataRequest: client_format_data_request,
            ServerFormatDataRequest: None,
            ClientFormatDataResponse: client_format_data_response,
            ServerFormatDataResponse: None,
            ClientFileContentsRequest: client_file_contents_request,
            ServerFileContentsRequest: None,
            ClientFileContentsResponse: client_file_contents_response,
            ServerFileContentsResponse: None,
            LastRequestedFormatId: 0,
        };
        let mut context = Box::new(context);
        unsafe {
            if FALSE == init_cliprdr(&mut (*context)) {
                println!("Failed to init cliprdr");
                Err(CliprdrError::CliprdrInit)
            } else {
                Ok(context)
            }
        }
    }
}

impl Drop for CliprdrClientContext {
    fn drop(&mut self) {
        unsafe {
            if FALSE == uninit_cliprdr(&mut *self) {
                println!("Failed to uninit cliprdr");
            } else {
                println!("Succeeded to uninit cliprdr");
            }
        }
    }
}

impl CliprdrServiceContext for CliprdrClientContext {
    fn set_is_stopped(&mut self) -> Result<(), CliprdrError> {
        self.IsStopped = TRUE;
        Ok(())
    }

    fn empty_clipboard(&mut self, conn_id: i32) -> Result<bool, CliprdrError> {
        Ok(empty_clipboard(self, conn_id))
    }

    fn server_clip_file(&mut self, conn_id: i32, msg: ClipboardFile) -> Result<(), CliprdrError> {
        let ret = server_clip_file(self, conn_id, msg);
        ret_to_result(ret)
    }

    fn get_progress_percent(&self) -> Option<ProgressPercent> {
        None
    }

    fn cancel(&mut self) {}
}

fn ret_to_result(ret: u32) -> Result<(), CliprdrError> {
    match ret {
        #[allow(unreachable_patterns)]
        // CHANNEL_RC_OK is unreachable, but ignore it
        ERROR_SUCCESS | CHANNEL_RC_OK => Ok(()),
        CHANNEL_RC_NO_MEMORY => Err(CliprdrError::CliprdrOutOfMemory),
        ERROR_INTERNAL_ERROR => Err(CliprdrError::ClipboardInternalError),
        e => Err(CliprdrError::Unknown(e)),
    }
}

pub fn empty_clipboard(context: &mut CliprdrClientContext, conn_id: i32) -> bool {
    unsafe { TRUE == empty_cliprdr(context, conn_id as u32) }
}

pub fn server_clip_file(
    context: &mut CliprdrClientContext,
    conn_id: i32,
    msg: ClipboardFile,
) -> u32 {
    let mut ret = 0;
    match msg {
        ClipboardFile::FileStream(frame) => {
            let sequence = unsafe { GetClipboardSequenceNumber() };
            if frame.kind == crate::file_stream::DESCRIPTORS_REQUEST {
                if frame.request_id == 0
                    || frame.generation == 0
                    || !frame.data.is_empty()
                    || frame.compressed
                    || frame.index
                        != unsafe { RegisterClipboardFormatA(b"FileGroupDescriptorW\0".as_ptr()) }
                {
                    crate::file_stream::reject(conn_id, &ClipboardFile::FileStream(frame));
                    return 0;
                }
                if let Some(data) = crate::file_stream::cached_metadata(conn_id, frame.generation) {
                    let _ = send_data(
                        conn_id,
                        ClipboardFile::FileStream(crate::file_stream::Frame {
                            kind: crate::file_stream::DESCRIPTORS_RESPONSE,
                            data,
                            compressed: false,
                            ..frame
                        }),
                    );
                    return 0;
                }
                if !crate::file_stream::source_is_current(frame.generation, sequence) {
                    let _ = send_data(
                        conn_id,
                        ClipboardFile::FileStream(crate::file_stream::Frame {
                            kind: crate::file_stream::ERROR,
                            data: vec![],
                            ..frame
                        }),
                    );
                } else {
                    METADATA_RESPONSE.with(|s| *s.borrow_mut() = Some(frame.clone()));
                    ret = server_format_data_request(context, conn_id, frame.index as i32);
                    METADATA_RESPONSE.with(|s| s.borrow_mut().take());
                }
            } else {
                crate::file_stream::handle(conn_id, frame, sequence);
            }
        }
        ClipboardFile::NotifyCallback { .. } => {
            // unreachable
        }
        ClipboardFile::MonitorReady => {
            log::debug!("server_monitor_ready called");
            ret = server_monitor_ready(context, conn_id);
            log::debug!(
                "server_monitor_ready called, conn_id {}, return {}",
                conn_id,
                ret
            );
        }
        ClipboardFile::FormatList { mut format_list } => {
            crate::file_stream::set_remote_generation(
                conn_id,
                crate::file_stream::generation(&format_list),
            );
            format_list.retain(|(_, name)| !name.starts_with(crate::file_stream::FORMAT_PREFIX));
            log::debug!(
                "server_format_list called, conn_id {}, format_list: {:?}",
                conn_id,
                &format_list
            );
            // A different peer may still be consuming the previous copy. Its
            // transfer owns that generation until IStream::Release/cancel.
            ret = server_format_list(context, conn_id, format_list);
            log::debug!(
                "server_format_list called, conn_id {}, return {}",
                conn_id,
                ret
            );
        }
        ClipboardFile::FormatListResponse { msg_flags } => {
            log::debug!("server_format_list_response called");
            ret = server_format_list_response(context, conn_id, msg_flags);
            log::debug!(
                "server_format_list_response called, conn_id {}, msg_flags {}, return {}",
                conn_id,
                msg_flags,
                ret
            );
        }
        ClipboardFile::FormatDataRequest {
            requested_format_id,
        } => {
            log::debug!("server_format_data_request called");
            ret = server_format_data_request(context, conn_id, requested_format_id);
            log::debug!(
                "server_format_data_request called, conn_id {}, requested_format_id {}, return {}",
                conn_id,
                requested_format_id,
                ret
            );
        }
        ClipboardFile::FormatDataResponse {
            msg_flags,
            format_data,
        } => {
            log::debug!("server_format_data_response called");
            ret = server_format_data_response(context, conn_id, msg_flags, format_data);
            log::debug!(
                "server_format_data_response called, conn_id {}, msg_flags: {}, return {}",
                conn_id,
                msg_flags,
                ret
            );
        }
        ClipboardFile::FileContentsRequest {
            stream_id,
            list_index,
            dw_flags,
            n_position_low,
            n_position_high,
            cb_requested,
            have_clip_data_id,
            clip_data_id,
        } => {
            log::debug!("server_file_contents_request called");
            ret = server_file_contents_request(
                context,
                conn_id,
                stream_id,
                list_index,
                dw_flags,
                n_position_low,
                n_position_high,
                cb_requested,
                have_clip_data_id,
                clip_data_id,
            );
            log::debug!("server_file_contents_request called, conn_id {}, stream_id: {}, list_index {}, dw_flags {}, n_position_low {}, n_position_high {}, cb_requested {}, have_clip_data_id {}, clip_data_id {}, return {}",                 conn_id,
                stream_id,
                list_index,
                dw_flags,
                n_position_low,
                n_position_high,
                cb_requested,
                have_clip_data_id,
                clip_data_id,
                ret
            );
        }
        ClipboardFile::FileContentsResponse {
            msg_flags,
            stream_id,
            requested_data,
        } => {
            log::debug!("server_file_contents_response called");
            ret = server_file_contents_response(
                context,
                conn_id,
                msg_flags,
                stream_id,
                requested_data,
            );
            log::debug!("server_file_contents_response called, conn_id {}, msg_flags {}, stream_id {}, return {}",
                conn_id,
                msg_flags,
                stream_id,
                ret
            );
        }
        ClipboardFile::TryEmpty => {
            log::debug!("empty_clipboard called");
            let ret = empty_clipboard(context, conn_id);
            log::debug!(
                "empty_clipboard called, conn_id {}, return {}",
                conn_id,
                ret
            );
        }
        ClipboardFile::Files { .. } => {
            // unreachable
        }
    }
    ret
}

pub fn server_monitor_ready(context: &mut CliprdrClientContext, conn_id: i32) -> u32 {
    unsafe {
        let monitor_ready = CLIPRDR_MONITOR_READY {
            connID: conn_id as UINT32,
            msgType: 0 as UINT16,
            msgFlags: 0 as UINT16,
            dataLen: 0 as UINT32,
        };
        if let Some(f) = context.MonitorReady {
            let ret = f(context, &monitor_ready);
            ret as u32
        } else {
            ERR_CODE_SERVER_FUNCTION_NONE
        }
    }
}

pub fn server_format_list(
    context: &mut CliprdrClientContext,
    conn_id: i32,
    format_list: Vec<(i32, String)>,
) -> u32 {
    unsafe {
        let num_formats = format_list.len() as UINT32;
        let mut formats = format_list
            .into_iter()
            .map(|format| {
                if format.1.is_empty() {
                    CLIPRDR_FORMAT {
                        formatId: format.0 as UINT32,
                        formatName: 0 as *mut _,
                    }
                } else {
                    let n = match CString::new(format.1) {
                        Ok(n) => n,
                        Err(_) => CString::new("").unwrap_or_default(),
                    };
                    CLIPRDR_FORMAT {
                        formatId: format.0 as UINT32,
                        formatName: n.into_raw(),
                    }
                }
            })
            .collect::<Vec<CLIPRDR_FORMAT>>();

        let format_list = CLIPRDR_FORMAT_LIST {
            connID: conn_id as UINT32,
            msgType: 0 as UINT16,
            msgFlags: 0 as UINT16,
            dataLen: 0 as UINT32,
            numFormats: num_formats,
            formats: formats.as_mut_ptr(),
        };

        let ret = if let Some(f) = context.ServerFormatList {
            f(context, &format_list)
        } else {
            ERR_CODE_SERVER_FUNCTION_NONE
        };

        for f in formats {
            if !f.formatName.is_null() {
                // retake pointer to free memory
                let _ = CString::from_raw(f.formatName);
            }
        }

        ret as u32
    }
}

pub fn server_format_list_response(
    context: &mut CliprdrClientContext,
    conn_id: i32,
    msg_flags: i32,
) -> u32 {
    unsafe {
        let format_list_response = CLIPRDR_FORMAT_LIST_RESPONSE {
            connID: conn_id as UINT32,
            msgType: 0 as UINT16,
            msgFlags: msg_flags as UINT16,
            dataLen: 0 as UINT32,
        };

        if let Some(f) = context.ServerFormatListResponse {
            f(context, &format_list_response)
        } else {
            ERR_CODE_SERVER_FUNCTION_NONE
        }
    }
}

pub fn server_format_data_request(
    context: &mut CliprdrClientContext,
    conn_id: i32,
    requested_format_id: i32,
) -> u32 {
    unsafe {
        let format_data_request = CLIPRDR_FORMAT_DATA_REQUEST {
            connID: conn_id as UINT32,
            msgType: 0 as UINT16,
            msgFlags: 0 as UINT16,
            dataLen: 0 as UINT32,
            requestedFormatId: requested_format_id as UINT32,
        };
        if let Some(f) = context.ServerFormatDataRequest {
            f(context, &format_data_request)
        } else {
            ERR_CODE_SERVER_FUNCTION_NONE
        }
    }
}

pub fn server_format_data_response(
    context: &mut CliprdrClientContext,
    conn_id: i32,
    msg_flags: i32,
    mut format_data: Vec<u8>,
) -> u32 {
    unsafe {
        let format_data_response = CLIPRDR_FORMAT_DATA_RESPONSE {
            connID: conn_id as UINT32,
            msgType: 0 as UINT16,
            msgFlags: msg_flags as UINT16,
            dataLen: format_data.len() as UINT32,
            requestedFormatData: format_data.as_mut_ptr(),
        };
        if let Some(f) = context.ServerFormatDataResponse {
            f(context, &format_data_response)
        } else {
            ERR_CODE_SERVER_FUNCTION_NONE
        }
    }
}

pub fn server_file_contents_request(
    context: &mut CliprdrClientContext,
    conn_id: i32,
    stream_id: i32,
    list_index: i32,
    dw_flags: i32,
    n_position_low: i32,
    n_position_high: i32,
    cb_requested: i32,
    have_clip_data_id: bool,
    clip_data_id: i32,
) -> u32 {
    unsafe {
        let file_contents_request = CLIPRDR_FILE_CONTENTS_REQUEST {
            connID: conn_id as UINT32,
            msgType: 0 as UINT16,
            msgFlags: 0 as UINT16,
            dataLen: 0 as UINT32,
            streamId: stream_id as UINT32,
            listIndex: list_index as UINT32,
            dwFlags: dw_flags as UINT32,
            nPositionLow: n_position_low as UINT32,
            nPositionHigh: n_position_high as UINT32,
            cbRequested: cb_requested as UINT32,
            haveClipDataId: if have_clip_data_id { TRUE } else { FALSE },
            clipDataId: clip_data_id as UINT32,
        };
        if let Some(f) = context.ServerFileContentsRequest {
            f(context, &file_contents_request)
        } else {
            ERR_CODE_SERVER_FUNCTION_NONE
        }
    }
}

pub fn server_file_contents_response(
    context: &mut CliprdrClientContext,
    conn_id: i32,
    msg_flags: i32,
    stream_id: i32,
    mut requested_data: Vec<u8>,
) -> u32 {
    unsafe {
        let file_contents_response = CLIPRDR_FILE_CONTENTS_RESPONSE {
            connID: conn_id as UINT32,
            msgType: 0 as UINT16,
            msgFlags: msg_flags as UINT16,
            dataLen: 4 + requested_data.len() as UINT32,
            streamId: stream_id as UINT32,
            cbRequested: requested_data.len() as UINT32,
            requestedData: requested_data.as_mut_ptr(),
        };
        if let Some(f) = context.ServerFileContentsResponse {
            f(context, &file_contents_response)
        } else {
            ERR_CODE_SERVER_FUNCTION_NONE
        }
    }
}

pub fn create_cliprdr_context(
    enable_files: bool,
    enable_others: bool,
    response_wait_timeout_secs: u32,
) -> ResultType<Box<CliprdrClientContext>> {
    Ok(CliprdrClientContext::create(
        enable_files,
        enable_others,
        response_wait_timeout_secs,
        Some(notify_callback),
        Some(handle_clipboard_files),
        Some(client_format_list),
        Some(client_format_list_response),
        Some(client_format_data_request),
        Some(client_format_data_response),
        Some(client_file_contents_request),
        Some(client_file_contents_response),
    )?)
}

extern "C" fn notify_callback(conn_id: UINT32, msg: *const NOTIFICATION_MESSAGE) -> UINT {
    log::debug!("notify_callback called");
    let data = unsafe {
        let msg = &*msg;
        let details = if msg.details.is_null() {
            Ok("")
        } else {
            CStr::from_ptr(msg.details as _).to_str()
        };
        match (CStr::from_ptr(msg.msg as _).to_str(), details) {
            (Ok(m), Ok(d)) => {
                let msgtype = format!(
                    "custom-{}-nocancel-nook-hasclose",
                    if msg.r#type == 0 {
                        "info"
                    } else if msg.r#type == 1 {
                        "warn"
                    } else {
                        "error"
                    }
                );
                let title = "Clipboard";
                let text = if d.is_empty() {
                    m.to_string()
                } else {
                    format!("{} {}", m, d)
                };
                ClipboardFile::NotifyCallback {
                    r#type: msgtype,
                    title: title.to_string(),
                    text,
                }
            }
            _ => {
                log::error!("notify_callback: failed to convert msg");
                return ERR_CODE_INVALID_PARAMETER;
            }
        }
    };
    // no need to handle result here
    allow_err!(send_data(conn_id as _, data));

    0
}

extern "C" fn handle_clipboard_files(
    conn_id: UINT32,
    n_files: size_t,
    file_names: *mut *mut WCHAR,
) -> UINT {
    if n_files == 0 {
        return 0;
    }

    let data = unsafe {
        let mut files = Vec::new();
        use std::ffi::OsString;
        use std::os::windows::ffi::OsStringExt;
        for i in 0..n_files {
            let file_name_ptr = *file_names.offset(i as isize);
            if !file_name_ptr.is_null() {
                let mut len = 0;
                while *file_name_ptr.offset(len) != 0 {
                    len += 1;
                }
                let slice = std::slice::from_raw_parts(file_name_ptr, len as usize);
                let os_string = OsString::from_wide(slice);
                match os_string.to_str() {
                    Some(n) => match std::fs::metadata(n) {
                        Ok(meta) => {
                            if meta.is_file() {
                                files.push((n.to_owned(), meta.len()));
                            }
                        }
                        Err(_e) => {
                            // File may be a virtual/RDP clipboard file (not a local path).
                            // Include it with size 0 so the UI can still show the file name.
                            log::debug!(
                                "handle_clipboard_files: '{}' is not a local file (possibly RDP virtual file), including with size 0",
                                n,
                            );
                            files.push((n.to_owned(), 0));
                        }
                    },
                    None => {
                        log::warn!("handle_clipboard_files: Failed to convert file name to UTF-8");
                    }
                };
            }
        }
        if files.is_empty() {
            return 0;
        }

        ClipboardFile::Files {
            files,
            source_application: 0,
        }
    };
    // no need to handle result here
    allow_err!(send_data(conn_id as _, data));

    0
}

extern "C" fn client_format_list(
    _context: *mut CliprdrClientContext,
    clip_format_list: *const CLIPRDR_FORMAT_LIST,
) -> UINT {
    let conn_id;
    let mut format_list: Vec<(i32, String)> = Vec::new();
    unsafe {
        let mut i = 0u32;
        while i < (*clip_format_list).numFormats {
            let format_data = &(*(*clip_format_list).formats.offset(i as isize));
            if format_data.formatName.is_null() {
                format_list.push((format_data.formatId as i32, "".to_owned()));
            } else {
                let format_name = CStr::from_ptr(format_data.formatName).to_str();
                let format_name = match format_name {
                    Ok(n) => n.to_owned(),
                    Err(_) => {
                        log::warn!("failed to get format name");
                        "".to_owned()
                    }
                };
                format_list.push((format_data.formatId as i32, format_name));
            }
            // log::debug!("format list item {}: format id: {}, format name: {}", i, format_data.formatId, &format_name);
            i += 1;
        }
        conn_id = (*clip_format_list).connID as i32;
    }
    log::debug!(
        "client_format_list called, client id: {}, format_list: {:?}",
        conn_id,
        &format_list
    );
    let generation =
        crate::file_stream::announce(unsafe { GetClipboardSequenceNumber() }, unsafe {
            IsClipboardFormatAvailable(15) != 0
        });
    if generation != 0 {
        format_list.push((
            0,
            format!("{}{:016x}", crate::file_stream::FORMAT_PREFIX, generation),
        ));
    }
    let data = ClipboardFile::FormatList { format_list };
    // no need to handle result here
    if conn_id == 0 {
        // msg_channel is used for debug, VEC_MSG_CHANNEL cannot be inspected by the debugger.
        let msg_channel = VEC_MSG_CHANNEL.read().unwrap();
        msg_channel
            .iter()
            .for_each(|msg_channel| allow_err!(msg_channel.sender.send(data.clone())));
    } else {
        match send_data(conn_id, data) {
            Ok(_) => {}
            Err(e) => {
                log::error!("failed to send format list: {:?}", e);
                return ERR_CODE_SEND_MSG;
            }
        }
    }

    0
}

extern "C" fn client_format_list_response(
    _context: *mut CliprdrClientContext,
    format_list_response: *const CLIPRDR_FORMAT_LIST_RESPONSE,
) -> UINT {
    let conn_id;
    let msg_flags;
    unsafe {
        conn_id = (*format_list_response).connID as i32;
        msg_flags = (*format_list_response).msgFlags as i32;
    }
    log::debug!(
        "client_format_list_response called, client id: {}, msg_flags: {}",
        conn_id,
        msg_flags
    );
    let data = ClipboardFile::FormatListResponse { msg_flags };
    match send_data(conn_id, data) {
        Ok(_) => 0,
        Err(e) => {
            log::error!("failed to send format list response: {:?}", e);
            ERR_CODE_SEND_MSG
        }
    }
}

extern "C" fn client_format_data_request(
    _context: *mut CliprdrClientContext,
    format_data_request: *const CLIPRDR_FORMAT_DATA_REQUEST,
) -> UINT {
    let conn_id;
    let requested_format_id;
    unsafe {
        conn_id = (*format_data_request).connID as i32;
        requested_format_id = (*format_data_request).requestedFormatId as i32;
    }
    let data = ClipboardFile::FormatDataRequest {
        requested_format_id,
    };
    log::debug!(
        "client_format_data_request called, conn_id: {}, requested_format_id: {}",
        conn_id,
        requested_format_id
    );
    match send_data(conn_id, data) {
        Ok(_) => 0,
        Err(e) => {
            log::error!("failed to send format data request: {:?}", e);
            ERR_CODE_SEND_MSG
        }
    }
}

extern "C" fn client_format_data_response(
    _context: *mut CliprdrClientContext,
    format_data_response: *const CLIPRDR_FORMAT_DATA_RESPONSE,
) -> UINT {
    let conn_id;
    let msg_flags;
    let format_data;
    unsafe {
        conn_id = (*format_data_response).connID as i32;
        msg_flags = (*format_data_response).msgFlags as i32;
        if (*format_data_response).requestedFormatData.is_null() {
            format_data = Vec::new();
        } else {
            format_data = std::slice::from_raw_parts(
                (*format_data_response).requestedFormatData,
                (*format_data_response).dataLen as usize,
            )
            .to_vec();
        }
    }
    log::debug!(
        "client_format_data_response called, client id: {}, msg_flags: {}",
        conn_id,
        msg_flags
    );
    if let Some(frame) = METADATA_RESPONSE.with(|s| s.borrow_mut().take()) {
        if msg_flags == 1 {
            crate::file_stream::remember_metadata(conn_id, frame.generation, &format_data);
        }
        return match send_data(
            conn_id,
            ClipboardFile::FileStream(crate::file_stream::Frame {
                kind: if msg_flags == 1 {
                    crate::file_stream::DESCRIPTORS_RESPONSE
                } else {
                    crate::file_stream::ERROR
                },
                data: format_data,
                ..frame
            }),
        ) {
            Ok(()) => 0,
            Err(_) => ERR_CODE_SEND_MSG,
        };
    }
    let data = ClipboardFile::FormatDataResponse {
        msg_flags,
        format_data,
    };
    match send_data(conn_id, data) {
        Ok(_) => 0,
        Err(e) => {
            log::error!("failed to send format data response: {:?}", e);
            ERR_CODE_SEND_MSG
        }
    }
}

extern "C" fn client_file_contents_request(
    _context: *mut CliprdrClientContext,
    file_contents_request: *const CLIPRDR_FILE_CONTENTS_REQUEST,
) -> UINT {
    // TODO: support huge file?
    // if (!cliprdr->hasHugeFileSupport)
    // {
    // 	if (((UINT64)fileContentsRequest->cbRequested + fileContentsRequest->nPositionLow) >
    // 	    UINT32_MAX)
    // 		return ERROR_INVALID_PARAMETER;
    // 	if (fileContentsRequest->nPositionHigh != 0)
    // 		return ERROR_INVALID_PARAMETER;
    // }

    let conn_id;
    let stream_id;
    let list_index;
    let dw_flags;
    let n_position_low;
    let n_position_high;
    let cb_requested;
    let have_clip_data_id;
    let clip_data_id;
    unsafe {
        conn_id = (*file_contents_request).connID as i32;
        stream_id = (*file_contents_request).streamId as i32;
        list_index = (*file_contents_request).listIndex as i32;
        dw_flags = (*file_contents_request).dwFlags as i32;
        n_position_low = (*file_contents_request).nPositionLow as i32;
        n_position_high = (*file_contents_request).nPositionHigh as i32;
        cb_requested = (*file_contents_request).cbRequested as i32;
        have_clip_data_id = (*file_contents_request).haveClipDataId == TRUE;
        clip_data_id = (*file_contents_request).clipDataId as i32;
    }
    let data = ClipboardFile::FileContentsRequest {
        stream_id,
        list_index,
        dw_flags,
        n_position_low,
        n_position_high,
        cb_requested,
        have_clip_data_id,
        clip_data_id,
    };
    log::debug!("client_file_contents_request called, data: {:?}", &data);
    match send_data(conn_id, data) {
        Ok(_) => 0,
        Err(e) => {
            log::error!("failed to send file contents request: {:?}", e);
            ERR_CODE_SEND_MSG
        }
    }
}

extern "C" fn client_file_contents_response(
    _context: *mut CliprdrClientContext,
    file_contents_response: *const CLIPRDR_FILE_CONTENTS_RESPONSE,
) -> UINT {
    let conn_id;
    let msg_flags;
    let stream_id;
    let requested_data;
    unsafe {
        conn_id = (*file_contents_response).connID as i32;
        msg_flags = (*file_contents_response).msgFlags as i32;
        stream_id = (*file_contents_response).streamId as i32;
        if (*file_contents_response).requestedData.is_null() {
            requested_data = Vec::new();
        } else {
            requested_data = std::slice::from_raw_parts(
                (*file_contents_response).requestedData,
                (*file_contents_response).cbRequested as usize,
            )
            .to_vec();
        }
    }
    let data = ClipboardFile::FileContentsResponse {
        msg_flags,
        stream_id,
        requested_data,
    };
    log::debug!(
        "client_file_contents_response called, conn_id: {}, msg_flags: {}, stream_id: {}",
        conn_id,
        msg_flags,
        stream_id
    );
    match send_data(conn_id, data) {
        Ok(_) => 0,
        Err(e) => {
            log::error!("failed to send file contents response: {:?}", e);
            ERR_CODE_SEND_MSG
        }
    }
}
