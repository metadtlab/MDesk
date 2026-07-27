use hbb_common::{chrono, log};
use serde::Serialize;
use std::{
    fs::OpenOptions,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    thread,
    time::Duration,
};

const METADATA_RETRY_COUNT: usize = 20;
const METADATA_RETRY_DELAY: Duration = Duration::from_millis(250);
const INITIAL_FINALIZE_DELAY: Duration = Duration::from_millis(750);
const SEGMENT_ID: [u8; 4] = [0x18, 0x53, 0x80, 0x67];
const SEEK_HEAD_ID: [u8; 4] = [0x11, 0x4D, 0x9B, 0x74];
const SEEK_ID: [u8; 2] = [0x4D, 0xBB];
const SEEK_TARGET_ID: [u8; 2] = [0x53, 0xAB];
const SEEK_POSITION_ID: [u8; 2] = [0x53, 0xAC];
const INFO_ID: [u8; 4] = [0x15, 0x49, 0xA9, 0x66];
const TAGS_ID: [u8; 4] = [0x12, 0x54, 0xC3, 0x67];
const TITLE_ID: [u8; 2] = [0x7B, 0xA9];
const TARGETS_ID: [u8; 2] = [0x63, 0xC0];

#[derive(Clone, Debug)]
pub struct RecordingNoteContext {
    pub title: String,
    pub comment: String,
    pub peer_id: String,
    pub session_id: u64,
    pub role: &'static str,
}

pub struct RecordingNoteSaveResult {
    pub error: String,
    pub files: Vec<String>,
}

#[derive(Serialize)]
struct RecordingNoteFile<'a> {
    schema_version: u8,
    title: &'a str,
    comment: &'a str,
    peer_id: &'a str,
    session_id: u64,
    role: &'a str,
    video_file: String,
    saved_at: String,
    metadata_embedded: bool,
}

pub fn save_recording_notes(
    files: Vec<String>,
    context: RecordingNoteContext,
    completion: Option<std::sync::mpsc::Sender<RecordingNoteSaveResult>>,
) {
    if !contains_korean(&context.title) {
        if let Some(completion) = completion {
            completion
                .send(RecordingNoteSaveResult {
                    error: "영상 제목에 한글 명칭을 입력해 주세요.".to_owned(),
                    files,
                })
                .ok();
        }
        return;
    }
    if files.is_empty() {
        if let Some(completion) = completion {
            completion
                .send(RecordingNoteSaveResult {
                    error: "녹화 파일 경로를 찾을 수 없습니다.".to_owned(),
                    files: Vec::new(),
                })
                .ok();
        }
        return;
    }

    thread::spawn(move || {
        thread::sleep(INITIAL_FINALIZE_DELAY);
        let mut errors = Vec::new();
        let mut final_files = Vec::new();

        for file in files {
            let path = PathBuf::from(&file);
            if !wait_until_file_is_stable(&path) {
                let error = format!("녹화 파일 준비가 끝나지 않았습니다: {}", path.display());
                log::warn!("{error}");
                errors.push(error);
                final_files.push(file);
                continue;
            }

            final_files.push(path.to_string_lossy().to_string());

            let metadata_embedded =
                match set_video_metadata_with_retry(&path, &context.title, &context.comment) {
                    Ok(embedded) => embedded,
                    Err(err) => {
                        errors.push(format!(
                            "영상 속성 저장에 실패했습니다 ({}): {err}",
                            path.display()
                        ));
                        false
                    }
                };

            let note = RecordingNoteFile {
                schema_version: 1,
                title: &context.title,
                comment: &context.comment,
                peer_id: &context.peer_id,
                session_id: context.session_id,
                role: context.role,
                video_file: path
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.to_string_lossy().to_string()),
                saved_at: chrono::Local::now().to_rfc3339(),
                metadata_embedded,
            };
            let sidecar = path.with_extension("mdesk.json");
            match serde_json::to_vec_pretty(&note)
                .map_err(|err| err.to_string())
                .and_then(|data| std::fs::write(&sidecar, data).map_err(|err| err.to_string()))
            {
                Ok(()) => log::info!("Recording note saved: {}", sidecar.display()),
                Err(err) => {
                    let error = format!(
                        "작업내용 파일 저장에 실패했습니다 ({}): {err}",
                        sidecar.display()
                    );
                    log::error!("{error}");
                    errors.push(error);
                }
            }
        }

        if let Some(completion) = completion {
            completion
                .send(RecordingNoteSaveResult {
                    error: errors.join("\n"),
                    files: final_files,
                })
                .ok();
        }
    });
}

fn wait_until_file_is_stable(path: &Path) -> bool {
    let mut previous_size = None;
    let mut stable_checks = 0;
    for _ in 0..METADATA_RETRY_COUNT {
        match path.metadata() {
            Ok(metadata) if metadata.is_file() => {
                let size = metadata.len();
                if previous_size == Some(size) && size > 0 {
                    stable_checks += 1;
                    if stable_checks >= 2 {
                        return true;
                    }
                } else {
                    stable_checks = 0;
                    previous_size = Some(size);
                }
            }
            _ => {
                previous_size = None;
                stable_checks = 0;
            }
        }
        thread::sleep(METADATA_RETRY_DELAY);
    }
    false
}

fn contains_korean(value: &str) -> bool {
    value.chars().any(|c| {
        matches!(
            c,
            '\u{1100}'..='\u{11FF}'
                | '\u{3130}'..='\u{318F}'
                | '\u{A960}'..='\u{A97F}'
                | '\u{AC00}'..='\u{D7AF}'
                | '\u{D7B0}'..='\u{D7FF}'
        )
    })
}

fn set_video_metadata_with_retry(path: &Path, title: &str, comment: &str) -> Result<bool, String> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    if !extension.eq_ignore_ascii_case("webm") && !extension.eq_ignore_ascii_case("mkv") {
        log::info!(
            "Recording metadata is stored in a sidecar for unsupported container: {}",
            path.display()
        );
        return Ok(false);
    }

    let mut last_error = String::new();
    for attempt in 0..METADATA_RETRY_COUNT {
        match append_webm_metadata(path, title, comment) {
            Ok(()) => return Ok(true),
            Err(err) if attempt + 1 < METADATA_RETRY_COUNT => {
                last_error = err.clone();
                log::trace!(
                    "Recording metadata is not ready yet '{}': {err}",
                    path.display()
                );
                thread::sleep(METADATA_RETRY_DELAY);
            }
            Err(err) => {
                last_error = err.clone();
                log::warn!(
                    "Failed to embed recording metadata '{}': {err}",
                    path.display()
                );
            }
        }
    }
    Err(last_error)
}

fn append_webm_metadata(path: &Path, title: &str, comment: &str) -> Result<(), String> {
    let tags = build_webm_tags(title, comment)?;
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .map_err(|err| err.to_string())?;
    let file_len = file.metadata().map_err(|err| err.to_string())?.len();
    if file_len < 12 {
        return Err("WebM 파일이 올바르지 않습니다.".to_owned());
    }

    let header_len = usize::try_from(file_len.min(1024 * 1024)).unwrap_or(1024 * 1024);
    let mut header = vec![0u8; header_len];
    file.read_exact(&mut header)
        .map_err(|err| err.to_string())?;
    let segment_id_pos = header
        .windows(SEGMENT_ID.len())
        .position(|bytes| bytes == SEGMENT_ID)
        .ok_or_else(|| "WebM Segment 정보를 찾을 수 없습니다.".to_owned())?;
    let size_pos = segment_id_pos + SEGMENT_ID.len();
    let (segment_size, size_width, size_is_unknown) = decode_ebml_size(&header[size_pos..])?;
    let payload_start = u64::try_from(size_pos + size_width).map_err(|err| err.to_string())?;
    if payload_start > file_len {
        return Err("WebM Segment 크기가 올바르지 않습니다.".to_owned());
    }

    let info = build_webm_info_with_title(
        &header,
        usize::try_from(payload_start).map_err(|err| err.to_string())?,
        title,
    )?;
    let mut metadata = Vec::with_capacity(info.len() + tags.len());
    metadata.extend_from_slice(&info);
    metadata.extend_from_slice(&tags);
    let metadata_len = u64::try_from(metadata.len()).map_err(|err| err.to_string())?;
    let already_appended = if file_len >= metadata_len {
        file.seek(SeekFrom::End(-(metadata_len as i64)))
            .map_err(|err| err.to_string())?;
        let mut tail = vec![0u8; metadata.len()];
        file.read_exact(&mut tail).map_err(|err| err.to_string())?;
        tail == metadata
    } else {
        false
    };

    let (info_position, final_file_len) = if already_appended {
        (file_len - metadata_len, file_len)
    } else {
        file.seek(SeekFrom::End(0)).map_err(|err| err.to_string())?;
        file.write_all(&metadata).map_err(|err| err.to_string())?;
        file.flush().map_err(|err| err.to_string())?;
        (file_len, file_len + metadata_len)
    };
    let tags_position = info_position + u64::try_from(info.len()).map_err(|err| err.to_string())?;

    rewrite_metadata_seek_positions(
        &mut file,
        &header,
        payload_start,
        info_position,
        tags_position,
    )?;

    if !size_is_unknown {
        let actual_segment_size = final_file_len - payload_start;
        if segment_size != actual_segment_size {
            let encoded_size = encode_ebml_size(actual_segment_size, Some(size_width))?;
            file.seek(SeekFrom::Start(
                u64::try_from(size_pos).map_err(|err| err.to_string())?,
            ))
            .map_err(|err| err.to_string())?;
            file.write_all(&encoded_size)
                .map_err(|err| err.to_string())?;
            file.flush().map_err(|err| err.to_string())?;
        }
    }
    Ok(())
}

fn rewrite_metadata_seek_positions(
    file: &mut std::fs::File,
    header: &[u8],
    segment_payload_start: u64,
    info_file_position: u64,
    tags_file_position: u64,
) -> Result<(), String> {
    let search_start = usize::try_from(segment_payload_start).map_err(|err| err.to_string())?;
    if search_start >= header.len() {
        return Err("WebM SeekHead를 찾을 수 없습니다.".to_owned());
    }
    let relative_seek_head = header[search_start..]
        .windows(SEEK_HEAD_ID.len())
        .position(|bytes| bytes == SEEK_HEAD_ID)
        .ok_or_else(|| "WebM SeekHead를 찾을 수 없습니다.".to_owned())?;
    let seek_head_start = search_start + relative_seek_head;
    let seek_head = parse_ebml_element(header, seek_head_start)?
        .ok_or_else(|| "WebM SeekHead가 올바르지 않습니다.".to_owned())?;
    let void = parse_ebml_element(header, seek_head.end)?
        .ok_or_else(|| "WebM 메타정보 색인을 추가할 여유 공간이 없습니다.".to_owned())?;
    if seek_head.id != SEEK_HEAD_ID || void.id != [0xEC] {
        return Err("WebM SeekHead 뒤의 예약 공간을 찾을 수 없습니다.".to_owned());
    }

    let info_position = info_file_position
        .checked_sub(segment_payload_start)
        .ok_or_else(|| "WebM Info 위치가 올바르지 않습니다.".to_owned())?;
    let tags_position = tags_file_position
        .checked_sub(segment_payload_start)
        .ok_or_else(|| "WebM Tags 위치가 올바르지 않습니다.".to_owned())?;
    let mut found_info = false;
    let mut found_tags = false;
    let mut new_payload = Vec::new();
    let mut cursor = seek_head.payload_start;
    while cursor < seek_head.payload_end {
        let seek_start = cursor;
        let Some(seek) = parse_ebml_element(header, cursor)? else {
            break;
        };
        cursor = seek.end;
        if seek.id != SEEK_ID {
            new_payload.extend_from_slice(&header[seek_start..seek.end]);
            continue;
        }

        let mut target_id = None;
        let mut child_cursor = seek.payload_start;
        while child_cursor < seek.payload_end {
            let Some(child) = parse_ebml_element(header, child_cursor)? else {
                break;
            };
            child_cursor = child.end;
            if child.id == SEEK_TARGET_ID {
                target_id = Some(&header[child.payload_start..child.payload_end]);
            }
        }

        if target_id == Some(INFO_ID.as_slice()) {
            new_payload.extend(build_seek_entry(&INFO_ID, info_position)?);
            found_info = true;
        } else if target_id == Some(TAGS_ID.as_slice()) {
            new_payload.extend(build_seek_entry(&TAGS_ID, tags_position)?);
            found_tags = true;
        } else {
            new_payload.extend_from_slice(&header[seek_start..seek.end]);
        }
    }
    if !found_info {
        new_payload.extend(build_seek_entry(&INFO_ID, info_position)?);
    }
    if !found_tags {
        new_payload.extend(build_seek_entry(&TAGS_ID, tags_position)?);
    }

    let available = (seek_head.payload_end - seek_head.payload_start) + (void.end - seek_head.end);
    if new_payload.len() > available {
        return Err("WebM 메타정보 색인을 추가할 예약 공간이 부족합니다.".to_owned());
    }
    let remainder = build_ebml_void(available - new_payload.len())?;
    let size_start = seek_head_start + SEEK_HEAD_ID.len();
    let (_, size_width, size_is_unknown) = decode_ebml_size(&header[size_start..])?;
    if size_is_unknown {
        return Err("WebM SeekHead 크기가 올바르지 않습니다.".to_owned());
    }
    let encoded_size = encode_ebml_size(new_payload.len() as u64, Some(size_width))?;

    file.seek(SeekFrom::Start(seek_head.payload_start as u64))
        .map_err(|err| err.to_string())?;
    file.write_all(&new_payload)
        .map_err(|err| err.to_string())?;
    file.write_all(&remainder).map_err(|err| err.to_string())?;
    file.flush().map_err(|err| err.to_string())?;
    file.seek(SeekFrom::Start(size_start as u64))
        .map_err(|err| err.to_string())?;
    file.write_all(&encoded_size)
        .map_err(|err| err.to_string())?;
    file.flush().map_err(|err| err.to_string())
}

fn build_seek_entry(target_id: &[u8], relative_position: u64) -> Result<Vec<u8>, String> {
    let mut seek_payload = Vec::new();
    seek_payload.extend(build_ebml_element(&SEEK_TARGET_ID, target_id)?);
    seek_payload.extend(build_ebml_element(
        &SEEK_POSITION_ID,
        &encode_ebml_uint(relative_position),
    )?);
    build_ebml_element(&SEEK_ID, &seek_payload)
}

fn encode_ebml_uint(value: u64) -> Vec<u8> {
    let bytes = value.to_be_bytes();
    let first = bytes
        .iter()
        .position(|byte| *byte != 0)
        .unwrap_or(bytes.len() - 1);
    bytes[first..].to_vec()
}

fn build_ebml_void(total_size: usize) -> Result<Vec<u8>, String> {
    if total_size == 0 {
        return Ok(Vec::new());
    }
    for size_width in 1..=8 {
        let header_size = 1 + size_width;
        if total_size < header_size {
            continue;
        }
        let payload_size = total_size - header_size;
        if let Ok(encoded_size) = encode_ebml_size(payload_size as u64, Some(size_width)) {
            let mut result = Vec::with_capacity(total_size);
            result.push(0xEC);
            result.extend(encoded_size);
            result.resize(total_size, 0);
            return Ok(result);
        }
    }
    Err("WebM 예약 공간의 크기를 맞출 수 없습니다.".to_owned())
}

struct EbmlElement {
    id: Vec<u8>,
    payload_start: usize,
    payload_end: usize,
    end: usize,
}

fn parse_ebml_element(bytes: &[u8], start: usize) -> Result<Option<EbmlElement>, String> {
    let Some(first_id_byte) = bytes.get(start).copied() else {
        return Ok(None);
    };
    if first_id_byte == 0 {
        return Err("EBML 요소 ID가 올바르지 않습니다.".to_owned());
    }
    let id_width = first_id_byte.leading_zeros() as usize + 1;
    if id_width > 4 || start + id_width >= bytes.len() {
        return Err("EBML 요소 ID가 잘렸습니다.".to_owned());
    }
    let size_start = start + id_width;
    let (payload_size, size_width, size_is_unknown) = decode_ebml_size(&bytes[size_start..])?;
    if size_is_unknown {
        return Ok(None);
    }
    let payload_start = size_start + size_width;
    let payload_end = payload_start
        .checked_add(usize::try_from(payload_size).map_err(|err| err.to_string())?)
        .ok_or_else(|| "EBML 요소 크기가 너무 큽니다.".to_owned())?;
    if payload_end > bytes.len() {
        return Ok(None);
    }
    Ok(Some(EbmlElement {
        id: bytes[start..size_start].to_vec(),
        payload_start,
        payload_end,
        end: payload_end,
    }))
}

fn build_webm_info_with_title(
    header: &[u8],
    segment_payload_start: usize,
    title: &str,
) -> Result<Vec<u8>, String> {
    let mut cursor = segment_payload_start;
    let mut info = None;
    while cursor < header.len() {
        let Some(element) = parse_ebml_element(header, cursor)? else {
            break;
        };
        cursor = element.end;
        if element.id == INFO_ID {
            info = Some(element);
            break;
        }
    }
    let info = info.ok_or_else(|| "WebM Info 정보를 찾을 수 없습니다.".to_owned())?;

    let mut payload = Vec::new();
    let mut child_cursor = info.payload_start;
    while child_cursor < info.payload_end {
        let child_start = child_cursor;
        let child = parse_ebml_element(header, child_cursor)?
            .ok_or_else(|| "WebM Info 항목이 올바르지 않습니다.".to_owned())?;
        child_cursor = child.end;
        if child.id != TITLE_ID {
            payload.extend_from_slice(&header[child_start..child.end]);
        }
    }
    payload.extend(build_ebml_element(&TITLE_ID, title.as_bytes())?);
    build_ebml_element(&INFO_ID, &payload)
}

fn build_webm_tags(title: &str, comment: &str) -> Result<Vec<u8>, String> {
    let mut tag_payload = Vec::new();
    tag_payload.extend(build_ebml_element(&TARGETS_ID, &[])?);
    tag_payload.extend(build_simple_tag("TITLE", title)?);
    tag_payload.extend(build_simple_tag("COMMENT", comment)?);
    let tag = build_ebml_element(&[0x73, 0x73], &tag_payload)?;
    build_ebml_element(&[0x12, 0x54, 0xC3, 0x67], &tag)
}

fn build_simple_tag(name: &str, value: &str) -> Result<Vec<u8>, String> {
    let mut payload = Vec::new();
    payload.extend(build_ebml_element(&[0x45, 0xA3], name.as_bytes())?);
    payload.extend(build_ebml_element(&[0x44, 0x87], value.as_bytes())?);
    build_ebml_element(&[0x67, 0xC8], &payload)
}

fn build_ebml_element(id: &[u8], payload: &[u8]) -> Result<Vec<u8>, String> {
    let mut result = Vec::with_capacity(id.len() + 8 + payload.len());
    result.extend_from_slice(id);
    result.extend(encode_ebml_size(
        u64::try_from(payload.len()).map_err(|err| err.to_string())?,
        None,
    )?);
    result.extend_from_slice(payload);
    Ok(result)
}

fn decode_ebml_size(bytes: &[u8]) -> Result<(u64, usize, bool), String> {
    let first = *bytes
        .first()
        .ok_or_else(|| "EBML 크기 정보가 없습니다.".to_owned())?;
    if first == 0 {
        return Err("EBML 크기 정보가 올바르지 않습니다.".to_owned());
    }
    let width = first.leading_zeros() as usize + 1;
    if width > 8 || bytes.len() < width {
        return Err("EBML 크기 정보가 잘렸습니다.".to_owned());
    }

    let value_mask = if width == 8 { 0 } else { 0xFF >> width };
    let mut value = u64::from(first & value_mask);
    for byte in &bytes[1..width] {
        value = (value << 8) | u64::from(*byte);
    }
    let unknown_value = (1u64 << (7 * width)) - 1;
    Ok((value, width, value == unknown_value))
}

fn encode_ebml_size(value: u64, requested_width: Option<usize>) -> Result<Vec<u8>, String> {
    let width = if let Some(width) = requested_width {
        width
    } else {
        (1..=8)
            .find(|width| value < (1u64 << (7 * width)) - 1)
            .ok_or_else(|| "EBML 데이터가 너무 큽니다.".to_owned())?
    };
    if !(1..=8).contains(&width) || value >= (1u64 << (7 * width)) - 1 {
        return Err("기존 WebM Segment 크기 영역에 메타정보를 추가할 수 없습니다.".to_owned());
    }

    let mut encoded = value.to_be_bytes()[8 - width..].to_vec();
    encoded[0] |= 1 << (8 - width);
    Ok(encoded)
}

#[cfg(test)]
mod tests {
    use super::{build_webm_tags, contains_korean, decode_ebml_size, encode_ebml_size};

    #[test]
    fn recording_note_title_requires_korean() {
        assert!(contains_korean("고객사 2026-07-25"));
        assert!(!contains_korean("customer 2026-07-25"));
    }

    #[test]
    fn ebml_sizes_round_trip() {
        for value in [0, 126, 127, 16_382, 16_383, 1_000_000] {
            let encoded = encode_ebml_size(value, None).unwrap();
            let (decoded, width, unknown) = decode_ebml_size(&encoded).unwrap();
            assert_eq!(decoded, value);
            assert_eq!(width, encoded.len());
            assert!(!unknown);
        }
    }

    #[test]
    fn webm_tags_contain_utf8_title_and_comment() {
        let tags = build_webm_tags("한글 작업 제목", "원격 작업내용").unwrap();
        assert!(tags
            .windows("한글 작업 제목".len())
            .any(|part| part == "한글 작업 제목".as_bytes()));
        assert!(tags
            .windows("원격 작업내용".len())
            .any(|part| part == "원격 작업내용".as_bytes()));
    }
}
