// Clipboard audit metadata helpers.
//
// These helpers build *metadata-only* JSON summaries of clipboard transfers so
// the host can record clipboard history in the audit DB without ever touching,
// logging, or serializing the clipboard content itself.
//
// Privacy contract:
// - Never decode, log, hash, or serialize `Clipboard.content`
//   (text/html/rtf/svg/png/rgba bytes). Only its already-received byte length
//   may be counted as coarse transfer metadata.
// - On Windows, the clipboard owner's executable basename is used only for an
//   in-process allowlist lookup and is immediately discarded. Process IDs,
//   paths, basenames and window titles are never serialized or logged.
// - File clipboard transfers may record file names only, and we store the
//   basename instead of the full path to reduce exposure.

use hbb_common::message_proto::{
    Clipboard, ClipboardFormat, ClipboardSourceApplication as ProtoClipboardSourceApplication,
};
use hbb_common::protobuf::Enum;
use serde_derive::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Closed application categories accepted by the V2 clipboard audit API.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum ClipboardSourceApplication {
    Excel,
    Powerpoint,
    Word,
    Browser,
    FileManager,
    ImageEditor,
    PdfViewer,
    Other,
    #[default]
    Unknown,
}

impl ClipboardSourceApplication {
    pub fn as_api_str(self) -> &'static str {
        match self {
            Self::Excel => "EXCEL",
            Self::Powerpoint => "POWERPOINT",
            Self::Word => "WORD",
            Self::Browser => "BROWSER",
            Self::FileManager => "FILE_MANAGER",
            Self::ImageEditor => "IMAGE_EDITOR",
            Self::PdfViewer => "PDF_VIEWER",
            Self::Other => "OTHER",
            Self::Unknown => "UNKNOWN",
        }
    }

    pub fn to_proto(self) -> ProtoClipboardSourceApplication {
        match self {
            Self::Excel => ProtoClipboardSourceApplication::ClipboardSourceExcel,
            Self::Powerpoint => ProtoClipboardSourceApplication::ClipboardSourcePowerpoint,
            Self::Word => ProtoClipboardSourceApplication::ClipboardSourceWord,
            Self::Browser => ProtoClipboardSourceApplication::ClipboardSourceBrowser,
            Self::FileManager => ProtoClipboardSourceApplication::ClipboardSourceFileManager,
            Self::ImageEditor => ProtoClipboardSourceApplication::ClipboardSourceImageEditor,
            Self::PdfViewer => ProtoClipboardSourceApplication::ClipboardSourcePdfViewer,
            Self::Other => ProtoClipboardSourceApplication::ClipboardSourceOther,
            Self::Unknown => ProtoClipboardSourceApplication::ClipboardSourceUnknown,
        }
    }

    pub fn from_proto(value: ProtoClipboardSourceApplication) -> Self {
        match value {
            ProtoClipboardSourceApplication::ClipboardSourceExcel => Self::Excel,
            ProtoClipboardSourceApplication::ClipboardSourcePowerpoint => Self::Powerpoint,
            ProtoClipboardSourceApplication::ClipboardSourceWord => Self::Word,
            ProtoClipboardSourceApplication::ClipboardSourceBrowser => Self::Browser,
            ProtoClipboardSourceApplication::ClipboardSourceFileManager => Self::FileManager,
            ProtoClipboardSourceApplication::ClipboardSourceImageEditor => Self::ImageEditor,
            ProtoClipboardSourceApplication::ClipboardSourcePdfViewer => Self::PdfViewer,
            ProtoClipboardSourceApplication::ClipboardSourceOther => Self::Other,
            ProtoClipboardSourceApplication::ClipboardSourceUnknown => Self::Unknown,
        }
    }

    pub fn from_proto_i32(value: i32) -> Self {
        ProtoClipboardSourceApplication::from_i32(value)
            .map(Self::from_proto)
            .unwrap_or(Self::Unknown)
    }
}

/// Classifies the current clipboard owner locally. Unsupported platforms and
/// any Windows lookup failure deliberately fail closed to `UNKNOWN`. Audit
/// summaries may separately use an exact allowlisted clipboard format hint.
pub fn current_clipboard_source_application() -> ClipboardSourceApplication {
    #[cfg(target_os = "windows")]
    {
        return windows_clipboard_owner_process_basename()
            .as_deref()
            .map(classify_windows_process_basename)
            .unwrap_or(ClipboardSourceApplication::Unknown);
    }
    #[cfg(not(target_os = "windows"))]
    {
        ClipboardSourceApplication::Unknown
    }
}

/// Adds only the allowlisted enum to protocol clipboard items. No source
/// identifier is retained by this operation.
pub fn set_clipboard_source_application(
    clipboards: &mut [Clipboard],
    source_application: ClipboardSourceApplication,
) {
    let source_application = source_application.to_proto().into();
    for clipboard in clipboards {
        clipboard.source_application = source_application;
    }
}

fn source_application_from_clipboards(clipboards: &[Clipboard]) -> ClipboardSourceApplication {
    let mut accepted = None;
    let mut saw_unknown = false;
    for clipboard in clipboards {
        let value = clipboard
            .source_application
            .enum_value()
            .ok()
            .map(ClipboardSourceApplication::from_proto)
            .unwrap_or(ClipboardSourceApplication::Unknown);
        if value == ClipboardSourceApplication::Unknown {
            saw_unknown = true;
            continue;
        }
        if accepted.is_some_and(|current| current != value) {
            return ClipboardSourceApplication::Unknown;
        }
        accepted = Some(value);
    }
    if saw_unknown && accepted.is_some() {
        return ClipboardSourceApplication::Unknown;
    }
    if let Some(accepted) = accepted {
        return accepted;
    }

    // Exact, already-supported format marker only; the special payload and
    // special_name are never copied into audit JSON.
    if clipboards.iter().any(|clipboard| {
        clipboard.format.enum_value() == Ok(ClipboardFormat::Special)
            && clipboard.special_name == "XML Spreadsheet"
    }) {
        ClipboardSourceApplication::Excel
    } else {
        ClipboardSourceApplication::Unknown
    }
}

#[cfg(target_os = "windows")]
fn classify_windows_process_basename(basename: &str) -> ClipboardSourceApplication {
    match basename.to_ascii_lowercase().as_str() {
        "excel.exe" => ClipboardSourceApplication::Excel,
        "powerpnt.exe" => ClipboardSourceApplication::Powerpoint,
        "winword.exe" => ClipboardSourceApplication::Word,
        "chrome.exe" | "chromium.exe" | "msedge.exe" | "firefox.exe" | "waterfox.exe"
        | "brave.exe" | "opera.exe" | "opera_gx.exe" | "vivaldi.exe" | "iexplore.exe"
        | "arc.exe" | "whale.exe" => ClipboardSourceApplication::Browser,
        "explorer.exe"
        | "totalcmd.exe"
        | "totalcmd64.exe"
        | "freecommander.exe"
        | "freecommanderxe.exe"
        | "dopus.exe"
        | "directoryopus.exe" => ClipboardSourceApplication::FileManager,
        "mspaint.exe"
        | "photoshop.exe"
        | "photoshop_beta.exe"
        | "gimp.exe"
        | "gimp-2.10.exe"
        | "gimp-3.0.exe"
        | "paintdotnet.exe"
        | "krita.exe"
        | "affinityphoto2.exe"
        | "microsoft.photos.exe"
        | "photos.exe"
        | "snippingtool.exe"
        | "screenclippinghost.exe"
        | "i_view32.exe"
        | "i_view64.exe"
        | "irfanview.exe"
        | "xnviewmp.exe" => ClipboardSourceApplication::ImageEditor,
        "acrord32.exe" | "acrobat.exe" | "sumatrapdf.exe" | "foxitpdfreader.exe"
        | "foxitreader.exe" | "pdfxedit.exe" | "pdf24-reader.exe" => {
            ClipboardSourceApplication::PdfViewer
        }
        "applicationframehost.exe"
        | "textinputhost.exe"
        | "shellexperiencehost.exe"
        | "rdpclip.exe"
        | "mdesk.exe"
        | "mdeskmini.exe"
        | "rustdesk.exe" => ClipboardSourceApplication::Unknown,
        "" => ClipboardSourceApplication::Unknown,
        _ => ClipboardSourceApplication::Other,
    }
}

#[cfg(target_os = "windows")]
fn windows_clipboard_owner_process_basename() -> Option<String> {
    use std::{ffi::OsString, os::windows::ffi::OsStringExt};
    use winapi::{
        shared::minwindef::DWORD,
        um::winuser::{GetClipboardOwner, GetWindowThreadProcessId},
    };
    use windows::Win32::{
        Foundation::{CloseHandle, HANDLE},
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
    };

    let process_id = unsafe {
        let owner = GetClipboardOwner();
        if owner.is_null() {
            return None;
        }
        let mut process_id: DWORD = 0;
        GetWindowThreadProcessId(owner, &mut process_id);
        if process_id == 0 {
            return None;
        }
        process_id
    };

    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0).ok()?;
        if snapshot == HANDLE::default() {
            return None;
        }

        let result = (|| {
            let mut entry: PROCESSENTRY32W = std::mem::zeroed();
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
            Process32FirstW(snapshot, &mut entry).ok()?;
            loop {
                if entry.th32ProcessID == process_id {
                    let name_len = entry
                        .szExeFile
                        .iter()
                        .position(|unit| *unit == 0)
                        .unwrap_or(entry.szExeFile.len());
                    return OsString::from_wide(&entry.szExeFile[..name_len])
                        .into_string()
                        .ok();
                }
                if Process32NextW(snapshot, &mut entry).is_err() {
                    return None;
                }
            }
        })();

        let _ = CloseHandle(snapshot);
        result
    }
}

/// Direction of a clipboard transfer relative to the host (controlled side).
#[derive(Clone, Copy, Debug)]
pub enum ClipboardAuditDirection {
    /// Remote client copied something and it arrived on the host.
    ClientToHost,
    /// Host clipboard was sent out to the remote client.
    HostToClient,
}

impl ClipboardAuditDirection {
    pub fn as_str(&self) -> &'static str {
        match self {
            ClipboardAuditDirection::ClientToHost => "client_to_host",
            ClipboardAuditDirection::HostToClient => "host_to_client",
        }
    }
}

/// Map a clipboard format to a safe, content-free format string.
fn format_to_str(format: ClipboardFormat) -> &'static str {
    match format {
        ClipboardFormat::Text => "text",
        ClipboardFormat::Rtf => "rtf",
        ClipboardFormat::Html => "html",
        ClipboardFormat::ImageRgba => "image/rgba",
        ClipboardFormat::ImagePng => "image/png",
        ClipboardFormat::ImageSvg => "image/svg",
        ClipboardFormat::Special => "special",
    }
}

/// Coarse kind bucket used for filtering in the audit DB.
fn kind_of(format: ClipboardFormat) -> &'static str {
    match format {
        ClipboardFormat::Text | ClipboardFormat::Rtf | ClipboardFormat::Html => "text",
        ClipboardFormat::ImageRgba | ClipboardFormat::ImagePng | ClipboardFormat::ImageSvg => {
            "image"
        }
        ClipboardFormat::Special => "special",
    }
}

/// Extract the file basename from a path, stripping directories for privacy.
///
/// `C:\\Users\\user\\Desktop\\report.pdf` -> `report.pdf`
/// `/home/user/Pictures/image.png` -> `image.png`
fn basename(path: &str) -> String {
    let trimmed = path.trim_end_matches(['/', '\\']);
    trimmed
        .rsplit(|c| c == '/' || c == '\\')
        .next()
        .filter(|s| !s.is_empty())
        .unwrap_or(trimmed)
        .to_string()
}

/// Build a metadata-only summary for a set of (multi)clipboard items.
///
/// Content bytes are never inspected; only formats, item count and image
/// dimensions (when present) are reported.
pub fn summarize_multi_clipboards(
    direction: ClipboardAuditDirection,
    clipboards: &[Clipboard],
    ip: &str,
) -> Value {
    let source_application = source_application_from_clipboards(clipboards);
    let mut formats: Vec<&'static str> = Vec::new();
    let mut has_image = false;
    let mut has_text = false;
    let mut has_special = false;
    let mut image_width: Option<i32> = None;
    let mut image_height: Option<i32> = None;
    let mut size_bytes: u64 = 0;

    for c in clipboards {
        size_bytes = size_bytes.saturating_add(c.content.len() as u64);
        if let Ok(fmt) = c.format.enum_value() {
            let s = format_to_str(fmt);
            if !formats.contains(&s) {
                formats.push(s);
            }
            match kind_of(fmt) {
                "image" => {
                    has_image = true;
                    if c.width > 0 && c.height > 0 {
                        image_width = Some(c.width);
                        image_height = Some(c.height);
                    }
                }
                "text" => has_text = true,
                _ => has_special = true,
            }
        }
    }

    let kind = if has_image && has_text {
        "mixed"
    } else if has_image {
        "image"
    } else if has_text {
        "text"
    } else if has_special {
        "special"
    } else {
        "unknown"
    };

    let mut info = json!({
        "direction": direction.as_str(),
        "kind": kind,
        "formats": formats,
        "items": clipboards.len(),
        "item_count": clipboards.len(),
        "size_bytes": size_bytes,
        "source_application": source_application.as_api_str(),
        "ip": ip,
    });

    if let (Some(w), Some(h)) = (image_width, image_height) {
        info["image"] = json!({ "width": w, "height": h });
    }

    info
}

/// Build a metadata-only summary for a clipboard file transfer.
///
/// Only file basenames and sizes are recorded. Full paths and file content are
/// never included.
pub fn summarize_files(
    direction: ClipboardAuditDirection,
    files: &[(String, i64)],
    ip: &str,
) -> Value {
    summarize_files_with_source(direction, files, ClipboardSourceApplication::Unknown, ip)
}

pub fn summarize_files_with_source(
    direction: ClipboardAuditDirection,
    files: &[(String, i64)],
    source_application: ClipboardSourceApplication,
    ip: &str,
) -> Value {
    let names: Vec<Value> = files
        .iter()
        .map(|(name, size)| json!([basename(name), size]))
        .collect();
    let total_size: i64 = files.iter().map(|(_, s)| *s).sum();

    json!({
        "direction": direction.as_str(),
        "kind": "file",
        "files": names,
        "file_count": files.len(),
        "item_count": files.len(),
        "total_size": total_size,
        "size_bytes": total_size.max(0),
        "source_application": source_application.as_api_str(),
        "ip": ip,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basename() {
        assert_eq!(
            basename("C:\\Users\\user\\Desktop\\report.pdf"),
            "report.pdf"
        );
        assert_eq!(basename("/home/user/Pictures/image.png"), "image.png");
        assert_eq!(basename("plain.txt"), "plain.txt");
        assert_eq!(basename("/trailing/slash/"), "slash");
    }

    #[test]
    fn test_summarize_files() {
        let files = vec![
            ("C:\\a\\report.pdf".to_string(), 100i64),
            ("/b/image.png".to_string(), 200i64),
        ];
        let v = summarize_files(ClipboardAuditDirection::ClientToHost, &files, "1.2.3.4");
        assert_eq!(v["kind"], "file");
        assert_eq!(v["direction"], "client_to_host");
        assert_eq!(v["file_count"], 2);
        assert_eq!(v["total_size"], 300);
        assert_eq!(v["size_bytes"], 300);
        assert_eq!(v["item_count"], 2);
        assert_eq!(v["source_application"], "UNKNOWN");
        assert_eq!(v["files"][0][0], "report.pdf");
        assert_eq!(v["files"][1][0], "image.png");
        assert_eq!(v["ip"], "1.2.3.4");
    }

    #[test]
    fn file_summary_keeps_file_content_type_separate_from_source_application() {
        let value = summarize_files_with_source(
            ClipboardAuditDirection::HostToClient,
            &[("C:\\private\\report.pdf".to_owned(), 100)],
            ClipboardSourceApplication::FileManager,
            "1.2.3.4",
        );

        assert_eq!(value["kind"], "file");
        assert_eq!(value["source_application"], "FILE_MANAGER");
        assert!(!value.to_string().contains("C:\\private"));
    }

    #[test]
    fn text_summary_counts_bytes_without_exposing_content() {
        let secret = "do-not-store-this-secret";
        let clipboard = Clipboard {
            content: secret.as_bytes().to_vec().into(),
            format: ClipboardFormat::Text.into(),
            ..Default::default()
        };

        let value = summarize_multi_clipboards(
            ClipboardAuditDirection::HostToClient,
            &[clipboard],
            "1.2.3.4",
        );

        assert_eq!(value["kind"], "text");
        assert_eq!(value["item_count"], 1);
        assert_eq!(value["size_bytes"], secret.len());
        assert_eq!(value["source_application"], "UNKNOWN");
        assert!(!value.to_string().contains(secret));
    }

    #[test]
    fn mixed_text_and_image_remains_separate_from_the_source_application() {
        let mut clipboards = vec![
            Clipboard {
                content: b"worksheet".to_vec().into(),
                format: ClipboardFormat::Html.into(),
                ..Default::default()
            },
            Clipboard {
                content: vec![0_u8; 4].into(),
                format: ClipboardFormat::ImagePng.into(),
                ..Default::default()
            },
        ];
        set_clipboard_source_application(&mut clipboards, ClipboardSourceApplication::Excel);

        let value = summarize_multi_clipboards(
            ClipboardAuditDirection::HostToClient,
            &clipboards,
            "1.2.3.4",
        );

        assert_eq!(value["kind"], "mixed");
        assert_eq!(value["source_application"], "EXCEL");
        assert!(!value.to_string().contains("excel.exe"));
    }

    #[test]
    fn inconsistent_or_partially_unknown_source_categories_fail_closed() {
        let mut clipboards = vec![
            Clipboard {
                format: ClipboardFormat::Text.into(),
                ..Default::default()
            },
            Clipboard {
                format: ClipboardFormat::Html.into(),
                ..Default::default()
            },
        ];
        clipboards[0].source_application = ClipboardSourceApplication::Excel.to_proto().into();
        clipboards[1].source_application = ClipboardSourceApplication::Browser.to_proto().into();
        assert_eq!(
            source_application_from_clipboards(&clipboards),
            ClipboardSourceApplication::Unknown
        );

        clipboards[1].source_application = ClipboardSourceApplication::Unknown.to_proto().into();
        assert_eq!(
            source_application_from_clipboards(&clipboards),
            ClipboardSourceApplication::Unknown
        );
    }

    #[test]
    fn exact_excel_special_format_is_a_content_free_fallback() {
        let clipboard = Clipboard {
            format: ClipboardFormat::Special.into(),
            special_name: "XML Spreadsheet".to_owned(),
            ..Default::default()
        };

        let value = summarize_multi_clipboards(
            ClipboardAuditDirection::HostToClient,
            &[clipboard],
            "1.2.3.4",
        );

        assert_eq!(value["source_application"], "EXCEL");
        assert!(!value.to_string().contains("XML Spreadsheet"));
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_process_mapping_returns_only_closed_categories() {
        for (basename, expected) in [
            ("EXCEL.EXE", ClipboardSourceApplication::Excel),
            ("powerpnt.exe", ClipboardSourceApplication::Powerpoint),
            ("winword.exe", ClipboardSourceApplication::Word),
            ("chromium.exe", ClipboardSourceApplication::Browser),
            ("whale.exe", ClipboardSourceApplication::Browser),
            (
                "freecommanderxe.exe",
                ClipboardSourceApplication::FileManager,
            ),
            ("snippingtool.exe", ClipboardSourceApplication::ImageEditor),
            ("pdf24-reader.exe", ClipboardSourceApplication::PdfViewer),
            ("rdpclip.exe", ClipboardSourceApplication::Unknown),
            ("MDesk.exe", ClipboardSourceApplication::Unknown),
            ("private-app-name.exe", ClipboardSourceApplication::Other),
            ("", ClipboardSourceApplication::Unknown),
        ] {
            assert_eq!(classify_windows_process_basename(basename), expected);
        }
    }
}
