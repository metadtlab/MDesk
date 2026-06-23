// Clipboard audit metadata helpers.
//
// These helpers build *metadata-only* JSON summaries of clipboard transfers so
// the host can record clipboard history in the audit DB without ever touching,
// logging, or serializing the clipboard content itself.
//
// Privacy contract:
// - Never read or serialize `Clipboard.content` (text/html/rtf/svg/png/rgba bytes).
// - File clipboard transfers may record file names only, and we store the
//   basename instead of the full path to reduce exposure.

use hbb_common::message_proto::{Clipboard, ClipboardFormat};
use serde_json::{json, Value};

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
    let mut formats: Vec<&'static str> = Vec::new();
    let mut has_image = false;
    let mut has_text = false;
    let mut has_special = false;
    let mut image_width: Option<i32> = None;
    let mut image_height: Option<i32> = None;

    for c in clipboards {
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

    let kind = if has_image {
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
        "total_size": total_size,
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
        assert_eq!(v["files"][0][0], "report.pdf");
        assert_eq!(v["files"][1][0], "image.png");
        assert_eq!(v["ip"], "1.2.3.4");
    }
}
