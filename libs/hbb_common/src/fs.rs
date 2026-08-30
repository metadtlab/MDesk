#[cfg(windows)]
use std::os::windows::prelude::*;
use std::{
    collections::HashSet,
    convert::TryFrom,
    fmt::{Debug, Display},
    io::{Cursor, Read},
    path::{Path, PathBuf},
    sync::atomic::{AtomicI32, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_derive::{Deserialize, Serialize};
use serde_json::json;
use tokio::{
    fs::{File, OpenOptions},
    io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt, BufStream as TokioBufStream},
};

use crate::{anyhow::anyhow, bail, get_version_number, message_proto::*, ResultType, Stream};
// https://doc.rust-lang.org/std/os/windows/fs/trait.MetadataExt.html
use crate::{
    compress::{compress, decompress},
    config::Config,
};

static NEXT_JOB_ID: AtomicI32 = AtomicI32::new(1);
// Negative IDs are reserved for controlled-host initiated direct pushes. This
// avoids colliding with the controller's ordinary positive file-manager jobs
// on the same bidirectional stream.
static NEXT_DIRECT_JOB_ID: AtomicI32 = AtomicI32::new(-1);
pub const REMOTE_DROP_DOWNLOADS_PREFIX: &str = "mdesk-drop-downloads:";
pub const DIRECT_TRANSFER_MAX_ENTRIES: usize = 100_000;
pub const DIRECT_TRANSFER_MAX_METADATA_BYTES: usize = 8 * 1024 * 1024;
pub const DIRECT_TRANSFER_MAX_PATH_BYTES: usize = 4 * 1024;
pub const DIRECT_TRANSFER_MAX_DEPTH: usize = 64;
pub const DIRECT_TRANSFER_MAX_TOTAL_BYTES: u64 = 20 * 1024 * 1024 * 1024;
pub const DIRECT_TRANSFER_MAX_BLOCK_BYTES: usize = 128 * 1024;

#[derive(Debug)]
pub struct DirectTransferManifest {
    pub root_name: String,
    pub is_directory: bool,
    pub files: Vec<FileEntry>,
    pub empty_dirs: Vec<String>,
    pub total_size: u64,
    source_identities: Vec<DirectSourceIdentity>,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct DirectSourceIdentity {
    volume_serial: u64,
    file_index: u64,
    file_size: u64,
    last_write_time: u64,
}

#[cfg(windows)]
#[allow(non_snake_case)]
#[repr(C)]
#[derive(Default)]
struct DirectByHandleFileInformation {
    dwFileAttributes: u32,
    ftCreationTimeLow: u32,
    ftCreationTimeHigh: u32,
    ftLastAccessTimeLow: u32,
    ftLastAccessTimeHigh: u32,
    ftLastWriteTimeLow: u32,
    ftLastWriteTimeHigh: u32,
    dwVolumeSerialNumber: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    nNumberOfLinks: u32,
    nFileIndexHigh: u32,
    nFileIndexLow: u32,
}

#[cfg(windows)]
#[link(name = "kernel32")]
extern "system" {
    fn GetFileInformationByHandle(
        file: *mut std::ffi::c_void,
        information: *mut DirectByHandleFileInformation,
    ) -> i32;
}

pub fn get_next_job_id() -> i32 {
    NEXT_JOB_ID.fetch_add(1, Ordering::SeqCst)
}

pub fn get_next_direct_job_id() -> i32 {
    let id = NEXT_DIRECT_JOB_ID.fetch_sub(1, Ordering::SeqCst);
    if id == i32::MIN {
        NEXT_DIRECT_JOB_ID.store(-1, Ordering::SeqCst);
        -1
    } else {
        id
    }
}

pub fn update_next_job_id(id: i32) {
    NEXT_JOB_ID.store(id, Ordering::SeqCst);
}

pub fn read_dir(path: &Path, include_hidden: bool) -> ResultType<FileDirectory> {
    let mut dir = FileDirectory {
        path: get_string(path),
        ..Default::default()
    };
    #[cfg(windows)]
    if "/" == &get_string(path) {
        let drives = unsafe { winapi::um::fileapi::GetLogicalDrives() };
        for i in 0..32 {
            if drives & (1 << i) != 0 {
                let name = format!(
                    "{}:",
                    std::char::from_u32('A' as u32 + i as u32).unwrap_or('A')
                );
                dir.entries.push(FileEntry {
                    name,
                    entry_type: FileType::DirDrive.into(),
                    ..Default::default()
                });
            }
        }
        return Ok(dir);
    }
    for entry in path.read_dir()?.flatten() {
        let p = entry.path();
        let name = p
            .file_name()
            .map(|p| p.to_str().unwrap_or(""))
            .unwrap_or("")
            .to_owned();
        if name.is_empty() {
            continue;
        }
        let mut is_hidden = false;
        let meta;
        if let Ok(tmp) = std::fs::symlink_metadata(&p) {
            meta = tmp;
        } else {
            continue;
        }
        // docs.microsoft.com/en-us/windows/win32/fileio/file-attribute-constants
        #[cfg(windows)]
        if meta.file_attributes() & 0x2 != 0 {
            is_hidden = true;
        }
        #[cfg(not(windows))]
        if name.find('.').unwrap_or(usize::MAX) == 0 {
            is_hidden = true;
        }
        if is_hidden && !include_hidden {
            continue;
        }
        let (entry_type, size) = {
            if p.is_dir() {
                if meta.file_type().is_symlink() {
                    (FileType::DirLink.into(), 0)
                } else {
                    (FileType::Dir.into(), 0)
                }
            } else if meta.file_type().is_symlink() {
                (FileType::FileLink.into(), 0)
            } else {
                (FileType::File.into(), meta.len())
            }
        };
        let modified_time = meta
            .modified()
            .map(|x| {
                x.duration_since(std::time::SystemTime::UNIX_EPOCH)
                    .map(|x| x.as_secs())
                    .unwrap_or(0)
            })
            .unwrap_or(0);
        dir.entries.push(FileEntry {
            name: get_file_name(&p),
            entry_type,
            is_hidden,
            size,
            modified_time,
            ..Default::default()
        });
    }
    Ok(dir)
}

#[inline]
pub fn get_file_name(p: &Path) -> String {
    p.file_name()
        .map(|p| p.to_str().unwrap_or(""))
        .unwrap_or("")
        .to_owned()
}

#[inline]
pub fn get_string(path: &Path) -> String {
    path.to_str().unwrap_or("").to_owned()
}

#[inline]
pub fn get_path(path: &str) -> PathBuf {
    Path::new(path).to_path_buf()
}

#[inline]
pub fn get_home_as_string() -> String {
    get_string(&Config::get_home())
}

pub fn get_download_dir() -> PathBuf {
    dirs_next::download_dir()
        .or_else(|| {
            let home = Config::get_home();
            if home.as_os_str().is_empty() {
                None
            } else {
                Some(home.join("Downloads"))
            }
        })
        .unwrap_or_else(std::env::temp_dir)
}

/// Resolve the interactive user's Downloads folder without silently falling
/// back to a temporary directory. Direct host-to-controller transfers promise
/// the user that this is the destination, so an unresolved Downloads folder is
/// a hard failure.
pub fn get_download_dir_strict() -> ResultType<PathBuf> {
    let path =
        dirs_next::download_dir().ok_or_else(|| anyhow!("Downloads folder is unavailable"))?;
    if path.as_os_str().is_empty() {
        bail!("Downloads folder is unavailable");
    }
    if !path.exists() {
        std::fs::create_dir_all(&path)?;
    }
    let metadata = std::fs::metadata(&path)?;
    if !metadata.is_dir() {
        bail!("Downloads destination is not a directory");
    }
    Ok(path)
}

fn validate_direct_path_component(component: &str) -> ResultType<()> {
    if component.is_empty() || component == "." || component == ".." {
        bail!("invalid direct transfer path component");
    }
    if component.encode_utf16().count() > 255 {
        bail!("direct transfer path component is too long");
    }
    if component.chars().any(|c| {
        c == '/'
            || c == '\\'
            || c == '\0'
            || c.is_control()
            || matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*')
    }) {
        bail!("invalid direct transfer path component");
    }
    if component.ends_with(' ') || component.ends_with('.') {
        bail!("invalid direct transfer path component");
    }

    // Windows treats these basenames as devices even when an extension is
    // present. Reject them on every build so validation is protocol-stable.
    let stem = component.split('.').next().unwrap_or(component);
    let upper = stem.to_ascii_uppercase();
    if matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (upper.len() == 4
            && (upper.starts_with("COM") || upper.starts_with("LPT"))
            && upper.as_bytes()[3].is_ascii_digit()
            && upper.as_bytes()[3] != b'0')
    {
        bail!("reserved direct transfer path component");
    }
    Ok(())
}

fn decompress_direct_transfer_block(data: &[u8], limit: usize) -> ResultType<Vec<u8>> {
    let decoder = zstd::stream::read::Decoder::new(data)?;
    let read_limit = u64::try_from(limit)
        .unwrap_or(u64::MAX - 1)
        .saturating_add(1);
    let mut limited = decoder.take(read_limit);
    let mut output = Vec::with_capacity(limit.min(DIRECT_TRANSFER_MAX_BLOCK_BYTES));
    limited.read_to_end(&mut output)?;
    if output.len() > limit {
        bail!("direct transfer block exceeds declared size");
    }
    Ok(output)
}

fn direct_relative_components(path: &str) -> ResultType<Vec<&str>> {
    if path.is_empty() || path.starts_with('/') || path.starts_with('\\') {
        bail!("invalid direct transfer relative path");
    }
    let components = path.split(|c| c == '/' || c == '\\').collect::<Vec<_>>();
    if components.is_empty() {
        bail!("invalid direct transfer relative path");
    }
    for component in &components {
        validate_direct_path_component(component)?;
    }
    Ok(components)
}

fn normalized_direct_relative_path(path: &str) -> ResultType<String> {
    Ok(direct_relative_components(path)?.join("/"))
}

fn direct_collision_key(path: &str) -> String {
    // Direct Downloads is currently a Windows feature. Always folding here is
    // conservative and keeps sender/receiver validation protocol-stable.
    path.to_lowercase()
}

fn validate_direct_metadata_budget(paths: impl Iterator<Item = String>) -> ResultType<()> {
    let mut count = 0usize;
    let mut bytes = 0usize;
    for path in paths {
        count = count
            .checked_add(1)
            .ok_or_else(|| anyhow!("direct transfer entry count overflow"))?;
        bytes = bytes
            .checked_add(path.len())
            .ok_or_else(|| anyhow!("direct transfer metadata overflow"))?;
        if count > DIRECT_TRANSFER_MAX_ENTRIES || bytes > DIRECT_TRANSFER_MAX_METADATA_BYTES {
            bail!("direct transfer manifest is too large");
        }
        if path.len() > DIRECT_TRANSFER_MAX_PATH_BYTES
            || path.split('/').count() > DIRECT_TRANSFER_MAX_DEPTH
        {
            bail!("direct transfer path exceeds safety limits");
        }
    }
    Ok(())
}

/// Validate the metadata of an unsolicited host push before touching the
/// controller filesystem. Only regular files are accepted and all names are
/// relative to a separately validated root basename.
pub fn validate_direct_transfer_layout(
    root_name: &str,
    is_directory: bool,
    files: &[FileEntry],
    empty_dirs: &[String],
    declared_total_size: u64,
) -> ResultType<()> {
    validate_direct_path_component(root_name)?;
    if root_name.encode_utf16().count() > 255 {
        bail!("direct transfer root name is too long");
    }
    if files.len().saturating_add(empty_dirs.len()) > DIRECT_TRANSFER_MAX_ENTRIES {
        bail!("direct transfer manifest has too many entries");
    }
    let mut total_size = 0u64;
    let mut paths = HashSet::new();
    let mut file_paths = Vec::with_capacity(files.len());
    let mut directory_paths = Vec::with_capacity(empty_dirs.len());

    if !is_directory {
        if files.len() != 1 || !files[0].name.is_empty() || !empty_dirs.is_empty() {
            bail!("invalid direct file transfer layout");
        }
    }

    for file in files {
        if file.entry_type.enum_value() != Ok(FileType::File) {
            bail!("direct transfer accepts regular files only");
        }
        let normalized = if is_directory {
            normalized_direct_relative_path(&file.name)?
        } else {
            String::new()
        };
        let collision_key = direct_collision_key(&normalized);
        if !paths.insert(collision_key) {
            bail!("duplicate direct transfer file path");
        }
        file_paths.push(normalized);
        total_size = total_size
            .checked_add(file.size)
            .ok_or_else(|| anyhow!("direct transfer size overflow"))?;
    }

    if is_directory {
        for dir in empty_dirs {
            let normalized = normalized_direct_relative_path(dir)?;
            let collision_key = direct_collision_key(&normalized);
            if !paths.insert(collision_key) {
                bail!("duplicate direct transfer directory path");
            }
            directory_paths.push(normalized);
        }
    }

    validate_direct_metadata_budget(file_paths.iter().chain(directory_paths.iter()).cloned())?;

    let file_keys = file_paths
        .iter()
        .map(|path| direct_collision_key(path))
        .collect::<HashSet<_>>();
    let empty_dir_keys = directory_paths
        .iter()
        .map(|path| direct_collision_key(path))
        .collect::<HashSet<_>>();
    for path in file_keys.iter().chain(empty_dir_keys.iter()) {
        let mut ancestor = String::new();
        let components = path.split('/').collect::<Vec<_>>();
        for component in components.iter().take(components.len().saturating_sub(1)) {
            if !ancestor.is_empty() {
                ancestor.push('/');
            }
            ancestor.push_str(component);
            if file_keys.contains(&ancestor) || empty_dir_keys.contains(&ancestor) {
                bail!("conflicting direct transfer path hierarchy");
            }
        }
    }

    if total_size != declared_total_size {
        bail!("direct transfer size mismatch");
    }
    if total_size > DIRECT_TRANSFER_MAX_TOTAL_BYTES {
        bail!("direct transfer exceeds the unattended size limit");
    }
    Ok(())
}

#[cfg(windows)]
fn is_direct_transfer_reparse_point(metadata: &std::fs::Metadata) -> bool {
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(windows)]
fn direct_source_identity<T: std::os::windows::io::AsRawHandle>(
    file: &T,
) -> ResultType<DirectSourceIdentity> {
    let mut information = DirectByHandleFileInformation::default();
    let succeeded = unsafe {
        GetFileInformationByHandle(file.as_raw_handle() as _, &mut information as *mut _)
    };
    if succeeded == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    if information.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) != 0
    {
        bail!("direct transfer source handle is not a regular non-reparse file");
    }
    Ok(DirectSourceIdentity {
        volume_serial: information.dwVolumeSerialNumber as u64,
        file_index: ((information.nFileIndexHigh as u64) << 32) | information.nFileIndexLow as u64,
        file_size: ((information.nFileSizeHigh as u64) << 32) | information.nFileSizeLow as u64,
        last_write_time: ((information.ftLastWriteTimeHigh as u64) << 32)
            | information.ftLastWriteTimeLow as u64,
    })
}

#[cfg(not(windows))]
fn direct_source_identity(metadata: &std::fs::Metadata) -> ResultType<DirectSourceIdentity> {
    Ok(DirectSourceIdentity {
        file_size: metadata.len(),
        ..Default::default()
    })
}

#[cfg(windows)]
fn snapshot_direct_source_identity(
    path: &Path,
    metadata: &std::fs::Metadata,
) -> ResultType<DirectSourceIdentity> {
    let file = std::fs::File::open(path)?;
    let identity = direct_source_identity(&file)?;
    let current = std::fs::symlink_metadata(path)?;
    if current.file_type().is_symlink()
        || is_direct_transfer_reparse_point(&current)
        || !current.is_file()
        || current.file_size() != identity.file_size
        || current.last_write_time() != identity.last_write_time
        || metadata.file_size() != identity.file_size
        || metadata.last_write_time() != identity.last_write_time
    {
        bail!("direct transfer source changed while creating its manifest");
    }
    Ok(identity)
}

#[cfg(not(windows))]
fn snapshot_direct_source_identity(
    _path: &Path,
    metadata: &std::fs::Metadata,
) -> ResultType<DirectSourceIdentity> {
    direct_source_identity(metadata)
}

#[cfg(not(windows))]
fn is_direct_transfer_reparse_point(metadata: &std::fs::Metadata) -> bool {
    metadata.file_type().is_symlink()
}

fn validate_direct_source_file(base: &PathBuf, name: &str) -> ResultType<PathBuf> {
    let base_metadata = std::fs::symlink_metadata(base)?;
    if base_metadata.file_type().is_symlink() || is_direct_transfer_reparse_point(&base_metadata) {
        bail!("direct transfer source root became a link or reparse point");
    }

    let source = if name.is_empty() {
        base.clone()
    } else {
        let mut current = base.clone();
        for component in direct_relative_components(name)? {
            current.push(component);
            let metadata = std::fs::symlink_metadata(&current)?;
            if metadata.file_type().is_symlink() || is_direct_transfer_reparse_point(&metadata) {
                bail!("direct transfer source path became a link or reparse point");
            }
        }
        current
    };
    let source_metadata = std::fs::symlink_metadata(&source)?;
    if !source_metadata.is_file()
        || source_metadata.file_type().is_symlink()
        || is_direct_transfer_reparse_point(&source_metadata)
    {
        bail!("direct transfer source is no longer a regular file");
    }

    if !name.is_empty() {
        let canonical_base = std::fs::canonicalize(base)?;
        let canonical_source = std::fs::canonicalize(&source)?;
        if !canonical_source.starts_with(&canonical_base) {
            bail!("direct transfer source escaped its selected root");
        }
    }
    Ok(source)
}

fn collect_direct_transfer_directory(
    directory: &Path,
    relative: &Path,
    files: &mut Vec<FileEntry>,
    source_identities: &mut Vec<DirectSourceIdentity>,
    empty_dirs: &mut Vec<String>,
    metadata_bytes: &mut usize,
    total_size: &mut u64,
) -> ResultType<()> {
    if relative.components().count() > DIRECT_TRANSFER_MAX_DEPTH {
        bail!("direct transfer directory depth exceeds safety limit");
    }
    let mut child_count = 0usize;
    for entry_result in std::fs::read_dir(directory)? {
        let entry = entry_result?;
        child_count = child_count
            .checked_add(1)
            .ok_or_else(|| anyhow!("direct transfer entry count overflow"))?;
        let metadata = std::fs::symlink_metadata(entry.path())?;
        if metadata.file_type().is_symlink() || is_direct_transfer_reparse_point(&metadata) {
            bail!("symbolic links and reparse points are not allowed in direct transfer");
        }
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| anyhow!("direct transfer path is not valid UTF-8"))?;
        validate_direct_path_component(&name)?;
        let relative_path = relative.join(&name);
        let protocol_path = relative_path
            .components()
            .map(|component| component.as_os_str().to_string_lossy())
            .collect::<Vec<_>>()
            .join("/");
        if protocol_path.len() > DIRECT_TRANSFER_MAX_PATH_BYTES {
            bail!("direct transfer path exceeds safety limit");
        }

        if metadata.is_dir() {
            collect_direct_transfer_directory(
                &entry.path(),
                &relative_path,
                files,
                source_identities,
                empty_dirs,
                metadata_bytes,
                total_size,
            )?;
        } else if metadata.is_file() {
            *metadata_bytes = metadata_bytes
                .checked_add(protocol_path.len())
                .ok_or_else(|| anyhow!("direct transfer metadata overflow"))?;
            if files.len().saturating_add(empty_dirs.len()) >= DIRECT_TRANSFER_MAX_ENTRIES
                || *metadata_bytes > DIRECT_TRANSFER_MAX_METADATA_BYTES
            {
                bail!("direct transfer manifest is too large");
            }
            let modified_time = metadata
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map(|duration| duration.as_secs())
                .unwrap_or(0);
            *total_size = total_size
                .checked_add(metadata.len())
                .ok_or_else(|| anyhow!("direct transfer size overflow"))?;
            if *total_size > DIRECT_TRANSFER_MAX_TOTAL_BYTES {
                bail!("direct transfer exceeds the unattended size limit");
            }
            files.push(FileEntry {
                entry_type: FileType::File.into(),
                name: protocol_path,
                size: metadata.len(),
                modified_time,
                ..Default::default()
            });
            source_identities.push(snapshot_direct_source_identity(&entry.path(), &metadata)?);
        } else {
            bail!("unsupported direct transfer filesystem entry");
        }
    }

    if child_count == 0 && !relative.as_os_str().is_empty() {
        let protocol_path = relative
            .components()
            .map(|component| component.as_os_str().to_string_lossy())
            .collect::<Vec<_>>()
            .join("/");
        *metadata_bytes = metadata_bytes
            .checked_add(protocol_path.len())
            .ok_or_else(|| anyhow!("direct transfer metadata overflow"))?;
        if files.len().saturating_add(empty_dirs.len()) >= DIRECT_TRANSFER_MAX_ENTRIES
            || *metadata_bytes > DIRECT_TRANSFER_MAX_METADATA_BYTES
        {
            bail!("direct transfer manifest is too large");
        }
        empty_dirs.push(protocol_path);
    }
    Ok(())
}

/// Walk a selected source exactly once, failing on every unreadable child and
/// refusing symlinks/reparse points. This prevents a partially enumerated
/// folder from later being reported as a completed direct transfer.
pub fn get_direct_transfer_manifest(source: &Path) -> ResultType<DirectTransferManifest> {
    let metadata = std::fs::symlink_metadata(source)?;
    if metadata.file_type().is_symlink() || is_direct_transfer_reparse_point(&metadata) {
        bail!("symbolic links and reparse points are not allowed in direct transfer");
    }
    let root_name = source
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("direct transfer source has no valid basename"))?
        .to_owned();
    validate_direct_path_component(&root_name)?;

    let mut files = Vec::new();
    let mut empty_dirs = Vec::new();
    let mut source_identities = Vec::new();
    let mut total_size = 0u64;
    if metadata.is_file() {
        total_size = metadata.len();
        let modified_time = metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_secs())
            .unwrap_or(0);
        files.push(FileEntry {
            entry_type: FileType::File.into(),
            size: metadata.len(),
            modified_time,
            ..Default::default()
        });
        source_identities.push(snapshot_direct_source_identity(source, &metadata)?);
    } else if metadata.is_dir() {
        let mut metadata_bytes = 0usize;
        collect_direct_transfer_directory(
            source,
            Path::new(""),
            &mut files,
            &mut source_identities,
            &mut empty_dirs,
            &mut metadata_bytes,
            &mut total_size,
        )?;
    } else {
        bail!("direct transfer source is not a regular file or directory");
    }

    validate_direct_transfer_layout(
        &root_name,
        metadata.is_dir(),
        &files,
        &empty_dirs,
        total_size,
    )?;
    Ok(DirectTransferManifest {
        root_name,
        is_directory: metadata.is_dir(),
        files,
        empty_dirs,
        total_size,
        source_identities,
    })
}

fn add_collision_suffix(root_name: &str, suffix: u32, is_directory: bool) -> String {
    if suffix == 0 {
        return root_name.to_owned();
    }
    if !is_directory {
        let path = Path::new(root_name);
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or(root_name);
        if let Some(extension) = path.extension().and_then(|s| s.to_str()) {
            return format!("{stem} ({suffix}).{extension}");
        }
    }
    format!("{root_name} ({suffix})")
}

/// Atomically reserve a collision-free root below Downloads. Directory roots
/// are created immediately; file roots reserve their `.download` staging file.
pub fn reserve_direct_download_destination(
    root_name: &str,
    is_directory: bool,
) -> ResultType<PathBuf> {
    validate_direct_path_component(root_name)?;
    let downloads = get_download_dir_strict()?;
    for suffix in 0..10_000 {
        let candidate = downloads.join(add_collision_suffix(root_name, suffix, is_directory));
        if is_directory {
            match std::fs::create_dir(&candidate) {
                Ok(()) => return Ok(candidate),
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(err) => return Err(err.into()),
            }
        } else {
            if candidate.exists() {
                continue;
            }
            let staging = PathBuf::from(format!("{}.download", candidate.to_string_lossy()));
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&staging)
            {
                Ok(_) => return Ok(candidate),
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(err) => return Err(err.into()),
            }
        }
    }
    bail!("unable to reserve a unique Downloads destination")
}

pub fn create_direct_empty_directories(base: &PathBuf, empty_dirs: &[String]) -> ResultType<()> {
    for dir in empty_dirs {
        let components = direct_relative_components(dir)?;
        let mut target = base.clone();
        for component in components {
            target.push(component);
            match std::fs::symlink_metadata(&target) {
                Ok(metadata) => {
                    if metadata.file_type().is_symlink() || !metadata.is_dir() {
                        bail!("unsafe direct transfer directory component");
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                    std::fs::create_dir(&target)?;
                }
                Err(err) => return Err(err.into()),
            }
        }
    }
    Ok(())
}

/// Release only artifacts reserved by `reserve_direct_download_destination`.
/// A directory is removed only when still empty, so partially received user
/// data is never recursively deleted during error handling.
pub fn release_direct_download_reservation(destination: &PathBuf, is_directory: bool) {
    if is_directory {
        // Empty-directory manifests may have materialized several nested
        // folders before a later validation/write failure. Remove only empty
        // directories; never recursively delete a partially received file.
        let _ = remove_all_empty_dir(destination);
    } else {
        let staging = PathBuf::from(format!("{}.download", destination.to_string_lossy()));
        let digest = PathBuf::from(format!("{}.digest", destination.to_string_lossy()));
        let _ = std::fs::remove_file(staging);
        let _ = std::fs::remove_file(digest);
    }
}

pub fn is_remote_drop_downloads_path(path: &str) -> bool {
    path.starts_with(REMOTE_DROP_DOWNLOADS_PREFIX)
}

pub fn resolve_remote_drop_downloads_path(path: &str) -> Result<Option<PathBuf>, String> {
    let Some(relative) = path.strip_prefix(REMOTE_DROP_DOWNLOADS_PREFIX) else {
        return Ok(None);
    };
    if relative.is_empty() {
        return Err("Invalid remote drop target".to_string());
    }

    let mut target = get_download_dir();
    for encoded in relative.split('/') {
        let decoded = decode_remote_drop_component(encoded)?;
        validate_remote_drop_component(&decoded)?;
        target.push(decoded);
    }
    Ok(Some(target))
}

fn decode_remote_drop_component(component: &str) -> Result<String, String> {
    if component.is_empty() {
        return Err("Invalid remote drop target".to_string());
    }

    let bytes = component.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err("Invalid remote drop target encoding".to_string());
            }
            let hi = hex_value(bytes[i + 1])
                .ok_or_else(|| "Invalid remote drop target encoding".to_string())?;
            let lo = hex_value(bytes[i + 2])
                .ok_or_else(|| "Invalid remote drop target encoding".to_string())?;
            decoded.push((hi << 4) | lo);
            i += 3;
        } else {
            decoded.push(bytes[i]);
            i += 1;
        }
    }

    String::from_utf8(decoded).map_err(|_| "Invalid remote drop target encoding".to_string())
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn validate_remote_drop_component(component: &str) -> Result<(), String> {
    if component.is_empty() || component == "." || component == ".." {
        return Err("Invalid remote drop target".to_string());
    }
    if component
        .chars()
        .any(|c| c == '/' || c == '\\' || c == '\0')
    {
        return Err("Invalid remote drop target".to_string());
    }
    #[cfg(windows)]
    if component
        .chars()
        .any(|c| c.is_control() || matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*'))
    {
        return Err("Invalid remote drop target".to_string());
    }
    Ok(())
}

fn read_dir_recursive(
    path: &Path,
    prefix: &Path,
    include_hidden: bool,
) -> ResultType<Vec<FileEntry>> {
    let mut files = Vec::new();
    if path.is_dir() {
        // to-do: symbol link handling, cp the link rather than the content
        // to-do: file mode, for unix
        let fd = read_dir(path, include_hidden)?;
        for entry in fd.entries.iter() {
            match entry.entry_type.enum_value() {
                Ok(FileType::File) => {
                    let mut entry = entry.clone();
                    entry.name = get_string(&prefix.join(entry.name));
                    files.push(entry);
                }
                Ok(FileType::Dir) => {
                    if let Ok(mut tmp) = read_dir_recursive(
                        &path.join(&entry.name),
                        &prefix.join(&entry.name),
                        include_hidden,
                    ) {
                        for entry in tmp.drain(0..) {
                            files.push(entry);
                        }
                    }
                }
                _ => {}
            }
        }
        Ok(files)
    } else if path.is_file() {
        let (size, modified_time) = if let Ok(meta) = std::fs::metadata(path) {
            (
                meta.len(),
                meta.modified()
                    .map(|x| {
                        x.duration_since(std::time::SystemTime::UNIX_EPOCH)
                            .map(|x| x.as_secs())
                            .unwrap_or(0)
                    })
                    .unwrap_or(0),
            )
        } else {
            (0, 0)
        };
        files.push(FileEntry {
            entry_type: FileType::File.into(),
            size,
            modified_time,
            ..Default::default()
        });
        Ok(files)
    } else {
        bail!("Not exists");
    }
}

pub fn get_recursive_files(path: &str, include_hidden: bool) -> ResultType<Vec<FileEntry>> {
    read_dir_recursive(&get_path(path), &get_path(""), include_hidden)
}

fn read_empty_dirs_recursive(
    path: &Path,
    prefix: &Path,
    include_hidden: bool,
) -> ResultType<Vec<FileDirectory>> {
    let mut dirs = Vec::new();
    if path.is_dir() {
        // to-do: symbol link handling, cp the link rather than the content
        // to-do: file mode, for unix
        let fd = read_dir(path, include_hidden)?;
        if fd.entries.is_empty() {
            dirs.push(fd);
        } else {
            for entry in fd.entries.iter() {
                match entry.entry_type.enum_value() {
                    Ok(FileType::Dir) => {
                        if let Ok(mut tmp) = read_empty_dirs_recursive(
                            &path.join(&entry.name),
                            &prefix.join(&entry.name),
                            include_hidden,
                        ) {
                            for entry in tmp.drain(0..) {
                                dirs.push(entry);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        Ok(dirs)
    } else if path.is_file() {
        Ok(dirs)
    } else {
        bail!("Not exists");
    }
}

pub fn get_empty_dirs_recursive(
    path: &str,
    include_hidden: bool,
) -> ResultType<Vec<FileDirectory>> {
    read_empty_dirs_recursive(&get_path(path), &get_path(""), include_hidden)
}

#[inline]
pub fn is_file_exists(file_path: &str) -> bool {
    return Path::new(file_path).exists();
}

#[inline]
pub fn can_enable_overwrite_detection(version: i64) -> bool {
    version >= get_version_number("1.1.10")
}

#[repr(i32)]
#[derive(Copy, Clone, Serialize, Debug, PartialEq)]
pub enum JobType {
    Generic = 0,
    Printer = 1,
}

impl Default for JobType {
    fn default() -> Self {
        JobType::Generic
    }
}

impl From<JobType> for file_transfer_send_request::FileType {
    fn from(t: JobType) -> Self {
        match t {
            JobType::Generic => file_transfer_send_request::FileType::Generic,
            JobType::Printer => file_transfer_send_request::FileType::Printer,
        }
    }
}

impl From<i32> for JobType {
    fn from(value: i32) -> Self {
        match value {
            0 => JobType::Generic,
            1 => JobType::Printer,
            _ => JobType::Generic,
        }
    }
}

impl Into<i32> for JobType {
    fn into(self) -> i32 {
        self as i32
    }
}

impl JobType {
    pub fn from_proto(t: ::protobuf::EnumOrUnknown<file_transfer_send_request::FileType>) -> Self {
        match t.enum_value() {
            Ok(file_transfer_send_request::FileType::Generic) => JobType::Generic,
            Ok(file_transfer_send_request::FileType::Printer) => JobType::Printer,
            _ => JobType::Generic,
        }
    }
}

#[derive(Debug)]
pub enum DataSource {
    FilePath(PathBuf),
    MemoryCursor(Cursor<Vec<u8>>),
}

impl Default for DataSource {
    fn default() -> Self {
        DataSource::FilePath(PathBuf::new())
    }
}

impl serde::Serialize for DataSource {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        match self {
            DataSource::FilePath(p) => serializer.serialize_str(p.to_str().unwrap_or("")),
            DataSource::MemoryCursor(_) => serializer.serialize_str(""),
        }
    }
}

impl Display for DataSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataSource::FilePath(p) => write!(f, "File: {}", p.to_string_lossy().to_string()),
            DataSource::MemoryCursor(_) => write!(f, "Bytes"),
        }
    }
}

impl DataSource {
    fn to_meta(&self) -> String {
        match self {
            DataSource::FilePath(p) => p.to_string_lossy().to_string(),
            DataSource::MemoryCursor(_) => "".to_string(),
        }
    }
}

enum DataStream {
    FileStream(File),
    BufStream(TokioBufStream<Cursor<Vec<u8>>>),
}

impl Debug for DataStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataStream::FileStream(fs) => write!(f, "{:?}", fs),
            DataStream::BufStream(_) => write!(f, "BufStream"),
        }
    }
}

impl DataStream {
    async fn write_all(&mut self, buf: &[u8]) -> ResultType<()> {
        match self {
            DataStream::FileStream(fs) => fs.write_all(buf).await?,
            DataStream::BufStream(bs) => bs.write_all(buf).await?,
        }
        Ok(())
    }

    async fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            DataStream::FileStream(fs) => fs.read(buf).await,
            DataStream::BufStream(bs) => bs.read(buf).await,
        }
    }
}

#[derive(Default, Serialize, Deserialize, Debug)]
pub struct FileDigest {
    pub size: u64,
    pub modified: u64,
}

#[derive(Default, Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TransferJob {
    pub id: i32,
    pub r#type: JobType,
    pub remote: String,
    pub data_source: DataSource,
    pub show_hidden: bool,
    pub is_remote: bool,
    pub is_last_job: bool,
    pub is_resume: bool,
    pub file_num: i32,
    #[serde(skip_serializing)]
    pub files: Vec<FileEntry>,
    pub conn_id: i32, // server only

    #[serde(skip_serializing)]
    data_stream: Option<DataStream>,
    pub total_size: u64,
    finished_size: u64,
    transferred: u64,
    enable_overwrite_detection: bool,
    file_confirmed: bool,
    // indicating the last file is skipped
    file_skipped: bool,
    file_is_waiting: bool,
    default_overwrite_strategy: Option<bool>,
    #[serde(skip_serializing)]
    set_mtime_to_now: bool,
    #[serde(skip_serializing)]
    open_folder_on_done: bool,
    #[serde(skip_serializing)]
    digest: FileDigest,
    // Preserve any source open/read failure until the whole multi-file job
    // terminates. Otherwise a later successful EOF can incorrectly turn a
    // partially failed transfer into a COMPLETED audit outcome.
    #[serde(skip_serializing)]
    transfer_error: Option<String>,
    #[serde(skip_serializing)]
    audit_had_skipped_file: bool,
    #[serde(skip)]
    never_overwrite_destination: bool,
    #[serde(skip)]
    strict_direct_transfer: bool,
    #[serde(skip)]
    direct_current_file_bytes: u64,
    #[serde(skip)]
    direct_current_file_eof_seen: bool,
    // Local-only snapshot identities for direct-send sources. These are never
    // serialized or put on the peer wire; they bind each opened handle back to
    // the file seen by the strict manifest walk.
    #[serde(skip)]
    direct_source_identities: Vec<DirectSourceIdentity>,
}

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct TransferJobMeta {
    #[serde(default)]
    pub id: i32,
    #[serde(default)]
    pub remote: String,
    #[serde(default)]
    pub to: String,
    #[serde(default)]
    pub show_hidden: bool,
    #[serde(default)]
    pub file_num: i32,
    #[serde(default)]
    pub is_remote: bool,
}

/// Terminal outcome reported by the read side after all file blocks have been
/// sent. Consumers that need transfer auditing can correlate this with their
/// own job metadata without parsing the UI-oriented JSON progress log.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub struct ReadJobOutcome {
    pub id: i32,
    pub succeeded: bool,
}

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct RemoveJobMeta {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub is_remote: bool,
    #[serde(default)]
    pub no_confirm: bool,
}

#[inline]
fn get_ext(name: &str) -> &str {
    if let Some(i) = name.rfind('.') {
        return &name[i + 1..];
    }
    ""
}

#[inline]
fn is_compressed_file(name: &str) -> bool {
    let compressed_exts = ["xz", "gz", "zip", "7z", "rar", "bz2", "tgz", "png", "jpg"];
    let ext = get_ext(name);
    compressed_exts.contains(&ext)
}

pub fn validate_file_name_no_traversal(name: &str) -> ResultType<()> {
    if name.bytes().any(|b| b == 0) {
        bail!("file name contains null bytes");
    }
    let has_traversal = name
        .split(|c: char| c == '/' || (cfg!(windows) && c == '\\'))
        .filter(|s| !s.is_empty())
        .any(|s| s == "..");
    if has_traversal {
        bail!("path traversal detected in file name");
    }
    #[cfg(windows)]
    {
        if name.len() >= 2 {
            let bytes = name.as_bytes();
            if bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
                bail!("absolute path detected in file name");
            }
        }
        if name.starts_with('/') || name.starts_with('\\') {
            bail!("absolute path detected in file name");
        }
    }
    #[cfg(not(windows))]
    if name.starts_with('/') {
        bail!("absolute path detected in file name");
    }
    Ok(())
}

fn validate_transfer_file_names(files: &[FileEntry]) -> ResultType<()> {
    // Single-file transfer may use an empty relative name, because the
    // destination file path is carried by transfer metadata.
    if files.len() == 1 && files.first().map_or(false, |f| f.name.is_empty()) {
        return Ok(());
    }
    for file in files {
        if file.name.is_empty() {
            bail!("empty file name in multi-file transfer");
        }
        validate_file_name_no_traversal(&file.name)?;
    }
    Ok(())
}

#[inline]
fn validate_fs_path_argument(path: &str, arg_name: &str) -> ResultType<()> {
    if path.is_empty() {
        bail!("{arg_name} cannot be empty");
    }
    if path.bytes().any(|b| b == 0) {
        bail!("{arg_name} contains null bytes");
    }
    Ok(())
}

fn validate_no_symlink_components(base: &PathBuf, name: &str) -> ResultType<()> {
    if name.is_empty() {
        return Ok(());
    }
    let mut current = base.clone();
    for component in Path::new(name).components() {
        match component {
            std::path::Component::Normal(seg) => {
                current.push(seg);
                // Best-effort guard. A later filesystem change can still race
                // this check; handle-based no-follow open would be stronger.
                match std::fs::symlink_metadata(&current) {
                    Ok(meta) => {
                        if meta.file_type().is_symlink() {
                            bail!("symlink path component is not allowed");
                        }
                    }
                    Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                    Err(err) => {
                        bail!(
                            "failed to validate path component '{}': {}",
                            current.display(),
                            err
                        );
                    }
                }
            }
            std::path::Component::CurDir => {}
            _ => bail!("invalid file name component"),
        }
    }
    Ok(())
}

fn join_validated_path(base: &PathBuf, name: &str) -> ResultType<PathBuf> {
    validate_file_name_no_traversal(name)?;
    validate_no_symlink_components(base, name)?;
    Ok(TransferJob::join(base, name))
}

impl TransferJob {
    #[allow(clippy::too_many_arguments)]
    pub fn new_write(
        id: i32,
        r#type: JobType,
        remote: String,
        data_source: DataSource,
        file_num: i32,
        show_hidden: bool,
        is_remote: bool,
        enable_overwrite_detection: bool,
    ) -> Self {
        log::info!("new write {}", data_source);
        Self {
            id,
            r#type,
            remote,
            data_source,
            file_num,
            show_hidden,
            is_remote,
            files: Vec::new(),
            total_size: 0,
            enable_overwrite_detection,
            ..Default::default()
        }
    }

    pub fn with_files(mut self, files: Vec<FileEntry>) -> ResultType<Self> {
        self.set_files(files)?;
        Ok(self)
    }

    pub fn new_read(
        id: i32,
        r#type: JobType,
        remote: String,
        data_source: DataSource,
        file_num: i32,
        show_hidden: bool,
        is_remote: bool,
        enable_overwrite_detection: bool,
    ) -> ResultType<Self> {
        log::info!("new read {}", data_source);
        let (files, total_size) = match &data_source {
            DataSource::FilePath(p) => {
                let p = p.to_str().ok_or(anyhow!("Invalid path"))?;
                let files = get_recursive_files(p, show_hidden)?;
                let total_size = files.iter().map(|x| x.size).sum();
                (files, total_size)
            }
            DataSource::MemoryCursor(c) => (Vec::new(), c.get_ref().len() as u64),
        };
        Ok(Self {
            id,
            r#type,
            remote,
            data_source,
            file_num,
            show_hidden,
            is_remote,
            files,
            total_size,
            enable_overwrite_detection,
            ..Default::default()
        })
    }

    pub fn new_direct_read(
        id: i32,
        source: PathBuf,
        manifest: &DirectTransferManifest,
    ) -> ResultType<Self> {
        validate_direct_transfer_layout(
            &manifest.root_name,
            manifest.is_directory,
            &manifest.files,
            &manifest.empty_dirs,
            manifest.total_size,
        )?;
        if manifest.source_identities.len() != manifest.files.len()
            || manifest
                .source_identities
                .iter()
                .zip(&manifest.files)
                .any(|(identity, file)| identity.file_size != file.size)
        {
            bail!("direct transfer source snapshot is inconsistent");
        }
        Ok(Self {
            id,
            r#type: JobType::Generic,
            remote: "Downloads".to_owned(),
            data_source: DataSource::FilePath(source),
            file_num: 0,
            show_hidden: true,
            is_remote: true,
            files: manifest.files.clone(),
            total_size: manifest.total_size,
            // The receiver atomically reserves a unique destination, so this
            // direct path never opens an overwrite-confirmation UI.
            enable_overwrite_detection: false,
            strict_direct_transfer: true,
            direct_source_identities: manifest.source_identities.clone(),
            ..Default::default()
        })
    }

    pub async fn get_buf_data(self) -> ResultType<Option<Vec<u8>>> {
        match self.data_stream {
            Some(DataStream::BufStream(mut bs)) => {
                bs.flush().await?;
                Ok(Some(bs.into_inner().into_inner()))
            }
            _ => Ok(None),
        }
    }

    #[inline]
    pub fn files(&self) -> &Vec<FileEntry> {
        &self.files
    }

    #[inline]
    pub fn set_files(&mut self, files: Vec<FileEntry>) -> ResultType<()> {
        validate_transfer_file_names(&files)?;
        if let DataSource::FilePath(base) = &self.data_source {
            for file in &files {
                validate_no_symlink_components(base, &file.name)?;
            }
        }
        self.total_size = files.iter().map(|x| x.size).sum();
        self.files = files;
        Ok(())
    }

    #[inline]
    pub fn set_digest(&mut self, size: u64, modified: u64) {
        self.digest.size = size;
        self.digest.modified = modified;
    }

    #[inline]
    pub fn set_mtime_to_now(&mut self, enabled: bool) {
        self.set_mtime_to_now = enabled;
    }

    #[inline]
    pub fn set_open_folder_on_done(&mut self, enabled: bool) {
        self.open_folder_on_done = enabled;
    }

    pub fn set_never_overwrite_destination(&mut self, enabled: bool) {
        self.never_overwrite_destination = enabled;
    }

    pub fn set_strict_direct_transfer(&mut self, enabled: bool) {
        self.strict_direct_transfer = enabled;
    }

    #[inline]
    pub fn folder_to_open_on_done(&self) -> Option<PathBuf> {
        if !self.open_folder_on_done {
            return None;
        }
        match &self.data_source {
            DataSource::FilePath(p) => {
                if self.files.len() == 1 && self.files[0].name.is_empty() {
                    Some(
                        p.parent()
                            .map(Path::to_path_buf)
                            .unwrap_or_else(|| p.clone()),
                    )
                } else {
                    Some(p.clone())
                }
            }
            DataSource::MemoryCursor(_) => None,
        }
    }

    #[inline]
    pub fn id(&self) -> i32 {
        self.id
    }

    #[inline]
    pub fn total_size(&self) -> u64 {
        self.total_size
    }

    #[inline]
    pub fn finished_size(&self) -> u64 {
        self.finished_size
    }

    #[inline]
    pub fn transferred(&self) -> u64 {
        self.transferred
    }

    #[inline]
    pub fn file_num(&self) -> i32 {
        self.file_num
    }

    fn resolve_entry_path(&self, base: &PathBuf, name: &str) -> Option<PathBuf> {
        if self.r#type == JobType::Printer {
            Some(Self::join(base, name))
        } else {
            match join_validated_path(base, name) {
                Ok(path) => Some(path),
                Err(err) => {
                    log::error!("Invalid file name in transfer job {}: {}", self.id, err);
                    None
                }
            }
        }
    }

    fn finalize_current_file(&self) -> ResultType<()> {
        if self.r#type == JobType::Printer {
            return Ok(());
        }
        if let DataSource::FilePath(p) = &self.data_source {
            let file_num = self.file_num as usize;
            if file_num < self.files.len() {
                let entry = &self.files[file_num];
                let Some(path) = self.resolve_entry_path(p, &entry.name) else {
                    bail!("invalid destination path");
                };
                let download_path = format!("{}.download", get_string(&path));
                let digest_path = format!("{}.digest", get_string(&path));
                std::fs::remove_file(digest_path).ok();
                if self.never_overwrite_destination && path.exists() {
                    bail!("direct transfer destination already exists");
                }
                std::fs::rename(download_path, &path)?;
                let mtime = if self.set_mtime_to_now {
                    filetime::FileTime::from_system_time(SystemTime::now())
                } else {
                    filetime::FileTime::from_unix_time(entry.modified_time as _, 0)
                };
                filetime::set_file_mtime(&path, mtime)?;
            }
        }
        Ok(())
    }

    /// Flush and durably finalize the current destination file before a Done
    /// acknowledgement is emitted. The file handle is dropped before rename so
    /// Windows does not report success while leaving only a `.download` file.
    pub async fn finalize_write(&mut self) -> ResultType<()> {
        match self.data_stream.as_mut() {
            Some(DataStream::FileStream(file)) => file.sync_all().await?,
            Some(DataStream::BufStream(stream)) => stream.flush().await?,
            None => return Ok(()),
        }
        if self.r#type != JobType::Printer {
            self.data_stream.take();
            self.finalize_current_file()?;
        }
        Ok(())
    }

    /// Finalize a direct Downloads write and verify every declared file before
    /// the receiver sends its terminal acknowledgement. This also materializes
    /// zero-byte files after their single explicit EOF block.
    pub async fn finalize_direct_write(&mut self) -> ResultType<()> {
        if let Some(entry) = usize::try_from(self.file_num)
            .ok()
            .and_then(|index| self.files.get(index))
        {
            if self.direct_current_file_bytes != entry.size || !self.direct_current_file_eof_seen {
                bail!("direct transfer file ended before declared size");
            }
        }
        self.finalize_write().await?;
        if self.finished_size != self.total_size {
            bail!("direct transfer ended before declared total size");
        }
        let DataSource::FilePath(base) = &self.data_source else {
            bail!("direct transfer requires a filesystem destination");
        };

        for entry in &self.files {
            let path = join_validated_path(base, &entry.name)?;
            if entry.size == 0 && !path.exists() {
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let staging = PathBuf::from(format!("{}.download", path.to_string_lossy()));
                let file = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&staging)
                    .or_else(|err| {
                        if err.kind() == std::io::ErrorKind::AlreadyExists {
                            std::fs::OpenOptions::new().write(true).open(&staging)
                        } else {
                            Err(err)
                        }
                    })?;
                file.sync_all()?;
                drop(file);
                if self.never_overwrite_destination && path.exists() {
                    bail!("direct transfer destination already exists");
                }
                std::fs::rename(&staging, &path)?;
                let mtime = filetime::FileTime::from_unix_time(entry.modified_time as _, 0);
                filetime::set_file_mtime(&path, mtime)?;
            }

            let metadata = std::fs::symlink_metadata(&path)?;
            if metadata.file_type().is_symlink() || !metadata.is_file() {
                bail!("direct transfer destination is not a regular file");
            }
            if metadata.len() != entry.size {
                bail!("direct transfer file size mismatch");
            }
        }
        Ok(())
    }

    pub fn remove_download_file(&self) {
        if self.r#type == JobType::Printer {
            return;
        }
        if let DataSource::FilePath(p) = &self.data_source {
            let file_num = self.file_num as usize;
            if file_num < self.files.len() {
                let entry = &self.files[file_num];
                let Some(path) = self.resolve_entry_path(p, &entry.name) else {
                    return;
                };
                let download_path = format!("{}.download", get_string(&path));
                let digest_path = format!("{}.digest", get_string(&path));
                std::fs::remove_file(download_path).ok();
                std::fs::remove_file(digest_path).ok();
            }
        }
    }

    #[inline]
    pub fn set_finished_size_on_resume(&mut self) {
        if self.is_resume && self.file_num > 0 {
            let finished_size: u64 = self
                .files
                .iter()
                .take(self.file_num as usize)
                .map(|file| file.size)
                .sum();
            self.finished_size = finished_size;
        }
    }

    pub async fn write(&mut self, block: FileTransferBlock) -> ResultType<()> {
        if block.id != self.id {
            bail!("Wrong id");
        }
        let file_num = usize::try_from(block.file_num).map_err(|_| anyhow!("Wrong file number"))?;
        if matches!(&self.data_source, DataSource::FilePath(_)) && file_num >= self.files.len() {
            bail!("Wrong file number");
        }
        if self.strict_direct_transfer && block.data.len() > DIRECT_TRANSFER_MAX_BLOCK_BYTES {
            bail!("direct transfer wire block exceeds protocol limit");
        }

        let decoded = if block.compressed {
            if self.strict_direct_transfer {
                let remaining =
                    self.files[file_num]
                        .size
                        .saturating_sub(if block.file_num == self.file_num {
                            self.direct_current_file_bytes
                        } else {
                            0
                        });
                let limit = usize::try_from(remaining)
                    .unwrap_or(usize::MAX)
                    .min(DIRECT_TRANSFER_MAX_BLOCK_BYTES);
                Some(decompress_direct_transfer_block(&block.data, limit)?)
            } else {
                Some(decompress(&block.data))
            }
        } else {
            None
        };
        let write_data: &[u8] = decoded.as_deref().unwrap_or(&block.data);

        if self.strict_direct_transfer {
            if write_data.len() > DIRECT_TRANSFER_MAX_BLOCK_BYTES {
                bail!("direct transfer block exceeds protocol limit");
            }
            if block.file_num < self.file_num {
                bail!("direct transfer file number moved backwards");
            }
            if block.file_num > self.file_num {
                if block.file_num != self.file_num.saturating_add(1)
                    || self.data_stream.is_none()
                    || !self.direct_current_file_eof_seen
                    || self.direct_current_file_bytes != self.files[self.file_num as usize].size
                {
                    bail!("direct transfer file sequence is incomplete");
                }
                self.direct_current_file_bytes = 0;
                self.direct_current_file_eof_seen = false;
            }
            let remaining = self.files[file_num]
                .size
                .checked_sub(self.direct_current_file_bytes)
                .ok_or_else(|| anyhow!("direct transfer file size underflow"))?;
            let expected_block_size =
                remaining.min(DIRECT_TRANSFER_MAX_BLOCK_BYTES as u64) as usize;
            if expected_block_size == 0 {
                if !write_data.is_empty() || self.direct_current_file_eof_seen {
                    bail!("direct transfer emitted an invalid or duplicate EOF block");
                }
                self.direct_current_file_eof_seen = true;
            } else if self.direct_current_file_eof_seen || write_data.len() != expected_block_size {
                bail!("direct transfer block does not match declared chunk size");
            }
            let next_file_bytes = self
                .direct_current_file_bytes
                .checked_add(write_data.len() as u64)
                .ok_or_else(|| anyhow!("direct transfer file size overflow"))?;
            if next_file_bytes > self.files[file_num].size {
                bail!("direct transfer exceeds declared file size");
            }
            let next_total = self
                .finished_size
                .checked_add(write_data.len() as u64)
                .ok_or_else(|| anyhow!("direct transfer total size overflow"))?;
            if next_total > self.total_size {
                bail!("direct transfer exceeds declared total size");
            }
            self.direct_current_file_bytes = next_file_bytes;
        }
        match &self.data_source {
            DataSource::FilePath(p) => {
                let base_path = p.clone();
                if file_num != self.file_num as usize || self.data_stream.is_none() {
                    if self.data_stream.is_some() {
                        self.finalize_write().await?;
                    }
                    self.file_num = block.file_num;
                    let entry = &self.files[file_num];
                    let (path, digest_path) = if self.r#type == JobType::Printer {
                        (base_path.to_string_lossy().to_string(), None)
                    } else {
                        let path = join_validated_path(&base_path, &entry.name)?;
                        if let Some(pp) = path.parent() {
                            std::fs::create_dir_all(pp).ok();
                        }
                        let file_path = get_string(&path);
                        (
                            format!("{}.download", &file_path),
                            Some(format!("{}.digest", &file_path)),
                        )
                    };
                    if let Some(dp) = digest_path.as_ref() {
                        if Path::new(dp).exists() {
                            std::fs::remove_file(dp)?;
                        }
                    }
                    self.data_stream = Some(DataStream::FileStream(File::create(&path).await?));
                    if let Some(dp) = digest_path.as_ref() {
                        std::fs::write(dp, json!(self.digest).to_string()).ok();
                    }
                }
            }
            DataSource::MemoryCursor(c) => {
                if self.data_stream.is_none() {
                    self.data_stream = Some(DataStream::BufStream(TokioBufStream::new(c.clone())));
                }
            }
        }
        self.data_stream
            .as_mut()
            .ok_or(anyhow!("file is None"))?
            .write_all(write_data)
            .await?;
        self.finished_size += write_data.len() as u64;
        self.transferred += block.data.len() as u64;
        Ok(())
    }

    #[inline]
    pub fn join(p: &PathBuf, name: &str) -> PathBuf {
        if name.is_empty() {
            p.clone()
        } else {
            p.join(name)
        }
    }

    /// Open the data stream for the current file.
    /// Returns Ok(true) if job is done, Ok(false) otherwise.
    async fn open_data_stream(&mut self) -> ResultType<bool> {
        let file_num = self.file_num as usize;
        let direct_file_name = self.files.get(file_num).map(|file| file.name.clone());
        let direct_expected_identity = self.direct_source_identities.get(file_num).copied();
        let direct_file_count = self.files.len();
        match &mut self.data_source {
            DataSource::FilePath(p) => {
                if file_num >= self.files.len() {
                    // job done
                    self.data_stream.take();
                    return Ok(true);
                };
                if self.data_stream.is_none() {
                    let source_path = if self.strict_direct_transfer {
                        let file_name = direct_file_name
                            .as_deref()
                            .ok_or_else(|| anyhow!("direct transfer source entry is missing"))?;
                        match validate_direct_source_file(p, file_name) {
                            Ok(path) => path,
                            Err(err) => {
                                self.transfer_error = Some(err.to_string());
                                self.file_num = direct_file_count as i32;
                                self.file_confirmed = false;
                                self.file_is_waiting = false;
                                return Err(err);
                            }
                        }
                    } else {
                        Self::join(p, &self.files[file_num].name)
                    };
                    match File::open(&source_path).await {
                        Ok(file) => {
                            if self.strict_direct_transfer {
                                let validation: ResultType<()> = async {
                                    // Revalidate the named path after open, then
                                    // validate the opened handle itself. A path
                                    // swap cannot make a different file pass the
                                    // manifest identity comparison.
                                    validate_direct_source_file(
                                        p,
                                        direct_file_name.as_deref().ok_or_else(|| {
                                            anyhow!("direct transfer source entry is missing")
                                        })?,
                                    )?;
                                    #[cfg(windows)]
                                    let actual = direct_source_identity(&file)?;
                                    #[cfg(not(windows))]
                                    let actual = direct_source_identity(&file.metadata().await?)?;
                                    let expected = direct_expected_identity.ok_or_else(|| {
                                        anyhow!("direct transfer source identity is missing")
                                    })?;
                                    if actual != expected {
                                        bail!("direct transfer source identity changed");
                                    }
                                    Ok(())
                                }
                                .await;
                                if let Err(err) = validation {
                                    self.transfer_error = Some(err.to_string());
                                    self.file_num = direct_file_count as i32;
                                    self.file_confirmed = false;
                                    self.file_is_waiting = false;
                                    return Err(err);
                                }
                            }
                            self.data_stream = Some(DataStream::FileStream(file));
                            self.file_confirmed = false;
                            self.file_is_waiting = false;
                        }
                        // On open error, behave the same as validation failure: advance
                        // to next file and return the error.
                        Err(err) => {
                            self.transfer_error = Some(err.to_string());
                            self.file_num += 1;
                            self.file_confirmed = false;
                            self.file_is_waiting = false;
                            return Err(err.into());
                        }
                    }
                }
            }
            DataSource::MemoryCursor(c) => {
                if self.data_stream.is_none() {
                    let mut t = std::io::Cursor::new(Vec::new());
                    std::mem::swap(&mut t, c);
                    self.data_stream = Some(DataStream::BufStream(TokioBufStream::new(t)));
                }
            }
        }
        Ok(false)
    }

    /// Get current file's digest (last_modified, file_size) for overwrite detection.
    async fn get_current_digest(&self) -> ResultType<(u64, u64)> {
        let meta = match self.data_stream.as_ref().ok_or(anyhow!("file is None"))? {
            DataStream::FileStream(file) => file.metadata().await?,
            DataStream::BufStream(_) => bail!("No digest for buf stream"),
        };
        let last_modified = meta
            .modified()?
            .duration_since(SystemTime::UNIX_EPOCH)?
            .as_secs();
        Ok((last_modified, meta.len()))
    }

    async fn init_data_stream(&mut self, stream: &mut crate::Stream) -> ResultType<()> {
        if self.open_data_stream().await? {
            return Ok(());
        }
        if self.r#type == JobType::Generic
            && self.enable_overwrite_detection
            && !self.file_confirmed()
            && !self.file_is_waiting()
        {
            self.send_current_digest(stream).await?;
            self.set_file_is_waiting(true);
        }
        Ok(())
    }

    /// Initialize data stream for CM (Connection Manager) scenario.
    /// Returns digest info (last_modified, file_size) if overwrite detection is enabled,
    /// so caller can send it via IPC instead of network stream.
    /// Returns Ok(None) if job is done or already initialized.
    pub async fn init_data_stream_for_cm(&mut self) -> ResultType<Option<(u64, u64)>> {
        if self.open_data_stream().await? {
            return Ok(None);
        }
        // For overwrite detection, return digest info instead of sending via stream
        if self.r#type == JobType::Generic
            && self.enable_overwrite_detection
            && !self.file_confirmed()
            && !self.file_is_waiting()
        {
            let digest = self.get_current_digest().await?;
            self.set_file_is_waiting(true);
            return Ok(Some(digest));
        }
        Ok(None)
    }

    pub async fn read(&mut self) -> ResultType<Option<FileTransferBlock>> {
        if self.r#type == JobType::Generic {
            if self.enable_overwrite_detection && !self.file_confirmed() {
                return Ok(None);
            }
        }

        let file_num = self.file_num as usize;
        let name = match &self.data_source {
            DataSource::FilePath(p) => {
                if file_num >= self.files.len() {
                    self.data_stream.take();
                    return Ok(None);
                };
                if self.files.len() == 1 && self.files[file_num].name.is_empty() {
                    p.file_name()
                        .map(|p| p.to_str().unwrap_or(""))
                        .unwrap_or("")
                } else {
                    &self.files[file_num].name
                }
            }
            DataSource::MemoryCursor(..) => "",
        };
        const BUF_SIZE: usize = 128 * 1024;
        let mut buf: Vec<u8> = vec![0; BUF_SIZE];
        let mut compressed = false;
        let mut offset: usize = 0;
        loop {
            match self
                .data_stream
                .as_mut()
                .ok_or(anyhow!("data stream is None"))?
                .read(&mut buf[offset..])
                .await
            {
                Err(err) => {
                    self.transfer_error = Some(err.to_string());
                    self.file_num += 1;
                    self.data_stream = None;
                    self.file_confirmed = false;
                    self.file_is_waiting = false;
                    return Err(err.into());
                }
                Ok(n) => {
                    offset += n;
                    if n == 0 || offset == BUF_SIZE {
                        break;
                    }
                }
            }
        }
        unsafe { buf.set_len(offset) };
        if offset == 0 {
            if matches!(self.data_source, DataSource::MemoryCursor(_)) {
                self.data_stream.take();
                return Ok(None);
            }
            self.file_num += 1;
            self.data_stream = None;
            self.file_confirmed = false;
            self.file_is_waiting = false;
        } else {
            self.finished_size += offset as u64;
            if matches!(self.data_source, DataSource::FilePath(_)) && !is_compressed_file(name) {
                let tmp = compress(&buf);
                if tmp.len() < buf.len() {
                    buf = tmp;
                    compressed = true;
                }
            }
            self.transferred += buf.len() as u64;
        }
        Ok(Some(FileTransferBlock {
            id: self.id,
            file_num: file_num as _,
            data: buf.into(),
            compressed,
            ..Default::default()
        }))
    }

    // Only for generic job and file stream
    async fn send_current_digest(&mut self, stream: &mut Stream) -> ResultType<()> {
        let (last_modified, file_size) = self.get_current_digest().await?;
        let mut msg = Message::new();
        let mut resp = FileResponse::new();
        resp.set_digest(FileTransferDigest {
            id: self.id,
            file_num: self.file_num,
            last_modified,
            file_size,
            is_resume: self.is_resume,
            ..Default::default()
        });
        msg.set_file_response(resp);
        stream.send(&msg).await?;
        log::info!(
            "id: {}, file_num: {}, digest message is sent. waiting for confirm. msg: {:?}",
            self.id,
            self.file_num,
            msg
        );
        Ok(())
    }

    pub fn set_overwrite_strategy(&mut self, overwrite_strategy: Option<bool>) {
        self.default_overwrite_strategy = overwrite_strategy;
    }

    pub fn default_overwrite_strategy(&self) -> Option<bool> {
        self.default_overwrite_strategy
    }

    pub fn set_file_confirmed(&mut self, file_confirmed: bool) {
        log::info!("id: {}, file_confirmed: {}", self.id, file_confirmed);
        self.file_confirmed = file_confirmed;
        self.file_skipped = false;
    }

    pub fn set_file_is_waiting(&mut self, file_is_waiting: bool) {
        self.file_is_waiting = file_is_waiting;
    }

    #[inline]
    pub fn file_is_waiting(&self) -> bool {
        self.file_is_waiting
    }

    #[inline]
    pub fn file_confirmed(&self) -> bool {
        self.file_confirmed
    }

    /// Indicating whether the last file is skipped
    #[inline]
    pub fn file_skipped(&self) -> bool {
        self.file_skipped
    }

    /// Indicating whether the whole task is skipped
    #[inline]
    pub fn job_skipped(&self) -> bool {
        self.file_skipped() && self.files.len() == 1
    }

    /// Check whether the job is completed after `read` returns `None`
    /// This is a helper function which gives additional lifecycle when the job reads `None`.
    /// If returns `true`, it means we can delete the job automatically. `False` otherwise.
    ///
    /// [`Note`]
    /// Conditions:
    /// 1. Files are not waiting for confirmation by peers.
    #[inline]
    pub fn job_completed(&self) -> bool {
        // has no error, Condition 2
        !self.enable_overwrite_detection || (!self.file_confirmed && !self.file_is_waiting)
    }

    /// Get job error message, useful for getting status when job had finished
    pub fn job_error(&self) -> Option<String> {
        if self.job_skipped() {
            return Some("skipped".to_string());
        }
        self.transfer_error.clone()
    }

    /// Conservative terminal status for immutable audit records. A partial
    /// multi-file transfer with any skipped or unreadable item must not be
    /// represented as if every requested file was completed.
    pub fn audit_error(&self) -> Option<String> {
        if self.audit_had_skipped_file {
            return Some("one or more files were skipped".to_owned());
        }
        self.transfer_error.clone()
    }

    pub fn mark_audit_file_skipped(&mut self) {
        self.audit_had_skipped_file = true;
    }

    pub fn set_file_skipped(&mut self) -> bool {
        log::debug!("skip file {} in job {}", self.file_num, self.id);
        self.mark_audit_file_skipped();
        self.data_stream.take();
        self.set_file_confirmed(false);
        self.set_file_is_waiting(false);
        self.file_num += 1;
        self.file_skipped = true;
        true
    }

    async fn set_stream_offset(&mut self, file_num: usize, offset: u64) {
        if let DataSource::FilePath(p) = &self.data_source {
            let entry = &self.files[file_num];
            let Some(path) = self.resolve_entry_path(p, &entry.name) else {
                return;
            };
            let file_path = get_string(&path);
            let download_path = format!("{}.download", &file_path);
            let digest_path = format!("{}.digest", &file_path);

            let mut f = if Path::new(&download_path).exists() && Path::new(&digest_path).exists() {
                // If both download and digest files exist, seek (writer) to the offset
                match OpenOptions::new()
                    .create(true)
                    .write(true)
                    .open(&download_path)
                    .await
                {
                    Ok(f) => f,
                    Err(e) => {
                        log::warn!("Failed to open file {}: {}", download_path, e);
                        return;
                    }
                }
            } else if Path::new(&file_path).exists() {
                // If `file_path` exists, seek (reader) to the offset
                match File::open(&file_path).await {
                    Ok(f) => f,
                    Err(e) => {
                        log::warn!("Failed to open file {}: {}", file_path, e);
                        return;
                    }
                }
            } else {
                log::warn!(
                    "File {} not found, cannot seek to offset {}",
                    file_path,
                    offset
                );
                return;
            };
            if f.seek(std::io::SeekFrom::Start(offset)).await.is_ok() {
                self.data_stream = Some(DataStream::FileStream(f));
                self.transferred += offset;
                self.finished_size += offset;
            }
        }
    }

    pub async fn confirm(&mut self, r: &FileTransferSendConfirmRequest) -> bool {
        if self.file_num() != r.file_num {
            // This branch will always be hit if:
            // 1. `confirm()` is called in `ui_cm_interface.rs`
            // 2. Not resuming
            //
            // It is ok. Because `confirm()` in `ui_cm_interface.rs` is only used for resuming.
            log::info!("file num truncated, ignoring");
        } else {
            match r.union {
                Some(file_transfer_send_confirm_request::Union::Skip(s)) => {
                    if s {
                        self.set_file_skipped();
                    } else {
                        self.set_file_confirmed(true);
                    }
                }
                Some(file_transfer_send_confirm_request::Union::OffsetBlk(offset)) => {
                    self.set_file_confirmed(true);
                    // If offset is greater than 0, we need to seek to the offset
                    if offset > 0 {
                        self.set_stream_offset(r.file_num as usize, offset as u64)
                            .await;
                    }
                }
                _ => {}
            }
        }
        true
    }

    #[inline]
    pub fn gen_meta(&self) -> TransferJobMeta {
        TransferJobMeta {
            id: self.id,
            remote: self.remote.to_string(),
            to: self.data_source.to_meta(),
            file_num: self.file_num,
            show_hidden: self.show_hidden,
            is_remote: self.is_remote,
        }
    }
}

#[inline]
pub fn new_error<T: std::string::ToString>(id: i32, err: T, file_num: i32) -> Message {
    let mut resp = FileResponse::new();
    resp.set_error(FileTransferError {
        id,
        error: err.to_string(),
        file_num,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn new_dir(id: i32, path: String, files: Vec<FileEntry>) -> Message {
    let mut resp = FileResponse::new();
    resp.set_dir(FileDirectory {
        id,
        path,
        entries: files,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn new_block(block: FileTransferBlock) -> Message {
    let mut resp = FileResponse::new();
    resp.set_block(block);
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn new_send_confirm(r: FileTransferSendConfirmRequest) -> Message {
    let mut msg_out = Message::new();
    let mut action = FileAction::new();
    action.set_send_confirm(r);
    msg_out.set_file_action(action);
    msg_out
}

#[inline]
pub fn new_receive(
    id: i32,
    path: String,
    file_num: i32,
    files: Vec<FileEntry>,
    total_size: u64,
) -> Message {
    let mut action = FileAction::new();
    action.set_receive(FileTransferReceiveRequest {
        id,
        path,
        files,
        file_num,
        total_size,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_action(action);
    msg_out
}

#[inline]
pub fn new_direct_receive(id: i32, manifest: &DirectTransferManifest) -> Message {
    let mut action = FileAction::new();
    action.set_direct_receive(DirectFileTransferReceiveRequest {
        id,
        destination: direct_file_transfer_receive_request::Destination::Downloads.into(),
        root_name: manifest.root_name.clone(),
        is_directory: manifest.is_directory,
        files: manifest.files.clone(),
        empty_dirs: manifest.empty_dirs.clone(),
        total_size: manifest.total_size,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_action(action);
    msg_out
}

#[inline]
pub fn new_send(
    id: i32,
    r#type: JobType,
    path: String,
    file_num: i32,
    include_hidden: bool,
) -> Message {
    log::info!("new send: {}, id: {}", path, id);
    let mut action = FileAction::new();
    let t: file_transfer_send_request::FileType = r#type.into();
    action.set_send(FileTransferSendRequest {
        id,
        path,
        include_hidden,
        file_num,
        file_type: t.into(),
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_action(action);
    msg_out
}

#[inline]
pub fn new_done(id: i32, file_num: i32) -> Message {
    let mut resp = FileResponse::new();
    resp.set_done(FileTransferDone {
        id,
        file_num,
        ..Default::default()
    });
    let mut msg_out = Message::new();
    msg_out.set_file_response(resp);
    msg_out
}

#[inline]
pub fn remove_job(id: i32, jobs: &mut Vec<TransferJob>) -> Option<TransferJob> {
    jobs.iter()
        .position(|x| x.id() == id)
        .map(|index| jobs.remove(index))
}

#[inline]
pub fn get_job(id: i32, jobs: &mut [TransferJob]) -> Option<&mut TransferJob> {
    jobs.iter_mut().find(|x| x.id() == id)
}

#[inline]
pub fn get_job_immutable(id: i32, jobs: &[TransferJob]) -> Option<&TransferJob> {
    jobs.iter().find(|x| x.id() == id)
}

async fn init_jobs(jobs: &mut Vec<TransferJob>, stream: &mut crate::Stream) -> ResultType<()> {
    for job in jobs.iter_mut() {
        if job.is_last_job {
            continue;
        }
        if let Err(err) = job.init_data_stream(stream).await {
            stream
                .send(&new_error(job.id(), err, job.file_num()))
                .await?;
        }
    }
    Ok(())
}

pub async fn handle_read_jobs(
    jobs: &mut Vec<TransferJob>,
    stream: &mut crate::Stream,
) -> ResultType<(String, Vec<ReadJobOutcome>)> {
    init_jobs(jobs, stream).await?;

    let mut job_log = Default::default();
    let mut finished = Vec::new();
    let mut outcomes = Vec::new();
    for job in jobs.iter_mut() {
        if job.is_last_job {
            continue;
        }
        match job.read().await {
            Err(err) => {
                stream
                    .send(&new_error(job.id(), err, job.file_num()))
                    .await?;
            }
            Ok(Some(block)) => {
                stream.send(&new_block(block)).await?;
            }
            Ok(None) => {
                if job.job_completed() {
                    job_log = serialize_transfer_job(job, true, false, "");
                    finished.push(job.id());
                    let audit_error = job.audit_error();
                    outcomes.push(ReadJobOutcome {
                        id: job.id(),
                        succeeded: audit_error.is_none(),
                    });
                    let job_error = job.job_error();
                    match job_error {
                        Some(err) => {
                            job_log = serialize_transfer_job(job, false, false, &err);
                            stream
                                .send(&new_error(job.id(), err, job.file_num()))
                                .await?
                        }
                        None => stream.send(&new_done(job.id(), job.file_num())).await?,
                    }
                } else {
                    // waiting confirmation.
                }
            }
        }
        // Break to handle jobs one by one.
        break;
    }
    for id in finished {
        let _ = remove_job(id, jobs);
    }
    Ok((job_log, outcomes))
}

pub fn remove_all_empty_dir(path: &Path) -> ResultType<()> {
    let fd = read_dir(path, true)?;
    for entry in fd.entries.iter() {
        match entry.entry_type.enum_value() {
            Ok(FileType::Dir) => {
                remove_all_empty_dir(&path.join(&entry.name)).ok();
            }
            Ok(FileType::DirLink) | Ok(FileType::FileLink) => {
                std::fs::remove_file(path.join(&entry.name)).ok();
            }
            _ => {}
        }
    }
    std::fs::remove_dir(path).ok();
    Ok(())
}

#[inline]
pub fn remove_file(file: &str) -> ResultType<()> {
    validate_fs_path_argument(file, "file path")?;
    std::fs::remove_file(get_path(file))?;
    Ok(())
}

#[inline]
pub fn create_dir(dir: &str) -> ResultType<()> {
    validate_fs_path_argument(dir, "directory path")?;
    std::fs::create_dir_all(get_path(dir))?;
    Ok(())
}

#[inline]
pub fn rename_file(path: &str, new_name: &str) -> ResultType<()> {
    validate_fs_path_argument(path, "path")?;
    if new_name.is_empty() {
        bail!("new file name cannot be empty");
    }
    validate_file_name_no_traversal(new_name)?;
    let path = std::path::Path::new(&path);
    if path.exists() {
        let dir = path
            .parent()
            .ok_or(anyhow!("Parent directoy of {path:?} not exists"))?;
        let new_path = dir.join(&new_name);
        std::fs::rename(&path, &new_path)?;
        Ok(())
    } else {
        bail!("{path:?} not exists");
    }
}

#[inline]
pub fn transform_windows_path(entries: &mut Vec<FileEntry>) {
    for entry in entries {
        entry.name = entry.name.replace('\\', "/");
    }
}

pub enum DigestCheckResult {
    IsSame,
    NeedConfirm(FileTransferDigest),
    NoSuchFile,
}

#[inline]
pub fn is_write_need_confirmation(
    is_resume: bool,
    file_path: &str,
    digest: &FileTransferDigest,
) -> ResultType<DigestCheckResult> {
    let path = Path::new(file_path);
    let digest_file = format!("{}.digest", file_path);
    let download_file = format!("{}.download", file_path);
    if is_resume && Path::new(&digest_file).exists() && Path::new(&download_file).exists() {
        // If the digest file exists, it means the file was transferred before.
        // We can use the digest file to check whether the file is the same.
        if let Ok(content) = std::fs::read_to_string(digest_file) {
            if let Ok(local_digest) = serde_json::from_str::<FileDigest>(&content) {
                let is_identical = local_digest.modified == digest.last_modified
                    && local_digest.size == digest.file_size;
                if is_identical {
                    if let Ok(download_metadata) = std::fs::metadata(download_file) {
                        // Get the file size of the local file
                        // Only send confirmation if the file is not empty.
                        let transferred_size = download_metadata.len();
                        if transferred_size > 0 {
                            return Ok(DigestCheckResult::NeedConfirm(FileTransferDigest {
                                id: digest.id,
                                file_num: digest.file_num,
                                last_modified: digest.last_modified,
                                file_size: digest.file_size,
                                is_identical,
                                transferred_size,
                                ..Default::default()
                            }));
                        }
                    }
                }
            }
        }
    }

    if path.exists() && path.is_file() {
        let metadata = std::fs::metadata(path)?;
        let modified_time = metadata.modified()?;
        let remote_mt = Duration::from_secs(digest.last_modified);
        let local_mt = modified_time.duration_since(UNIX_EPOCH)?;
        // [Note]
        // We decide to give the decision whether to override the existing file to users,
        // which obey the behavior of the file manager in our system.
        let mut is_identical = false;
        if remote_mt == local_mt && digest.file_size == metadata.len() {
            is_identical = true;
        }
        Ok(DigestCheckResult::NeedConfirm(FileTransferDigest {
            id: digest.id,
            file_num: digest.file_num,
            last_modified: local_mt.as_secs(),
            file_size: metadata.len(),
            is_identical,
            ..Default::default()
        }))
    } else {
        // If the file does not exist, or the digest file and download file do not exist, we return NoSuchFile.
        Ok(DigestCheckResult::NoSuchFile)
    }
}

pub fn serialize_transfer_jobs(jobs: &[TransferJob]) -> String {
    let mut v = vec![];
    for job in jobs {
        let value = serde_json::to_value(job).unwrap_or_default();
        v.push(value);
    }
    serde_json::to_string(&v).unwrap_or_default()
}

pub fn serialize_transfer_job(job: &TransferJob, done: bool, cancel: bool, error: &str) -> String {
    let mut value = serde_json::to_value(job).unwrap_or_default();
    value["done"] = json!(done);
    value["cancel"] = json!(cancel);
    value["error"] = json!(error);
    serde_json::to_string(&value).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_entry(name: &str) -> FileEntry {
        FileEntry {
            name: name.to_string(),
            ..Default::default()
        }
    }

    fn direct_file_entry(name: &str, size: u64) -> FileEntry {
        FileEntry {
            entry_type: FileType::File.into(),
            name: name.to_owned(),
            size,
            ..Default::default()
        }
    }

    fn validation_job() -> TransferJob {
        TransferJob::new_write(
            1,
            JobType::Generic,
            String::new(),
            DataSource::FilePath(std::env::temp_dir()),
            0,
            false,
            false,
            false,
        )
    }

    #[test]
    fn validate_file_name_rejects_traversal_and_null() {
        assert!(validate_file_name_no_traversal("../payload.txt").is_err());
        assert!(validate_file_name_no_traversal("dir/../payload.txt").is_err());
        assert!(validate_file_name_no_traversal("bad\0name.txt").is_err());
    }

    #[test]
    fn validate_file_name_rejects_absolute_path() {
        #[cfg(windows)]
        {
            assert!(validate_file_name_no_traversal("C:\\Windows\\Temp\\payload.txt").is_err());
            assert!(validate_file_name_no_traversal("\\\\server\\share\\payload.txt").is_err());
        }
        #[cfg(not(windows))]
        assert!(validate_file_name_no_traversal("/tmp/payload.txt").is_err());
    }

    #[test]
    fn set_files_allows_single_empty_name() {
        let mut job = validation_job();
        assert!(job.set_files(vec![file_entry("")]).is_ok());
    }

    #[test]
    fn set_files_rejects_empty_name_in_multi_file_transfer() {
        let mut job = validation_job();
        assert!(job
            .set_files(vec![file_entry(""), file_entry("ok.txt")])
            .is_err());
    }

    #[test]
    fn set_files_rejects_mixed_entries_when_one_is_traversal() {
        let mut job = validation_job();
        assert!(job
            .set_files(vec![file_entry("safe.txt"), file_entry("../../escape.txt")])
            .is_err());
    }

    #[test]
    fn direct_layout_accepts_only_bounded_relative_regular_files() {
        let files = vec![
            direct_file_entry("report.xlsx", 7),
            direct_file_entry("nested/image.png", 11),
        ];
        assert!(validate_direct_transfer_layout(
            "Selected folder",
            true,
            &files,
            &["empty/subfolder".to_owned()],
            18,
        )
        .is_ok());

        for invalid in [
            "../escape.txt",
            "/absolute.txt",
            r"C:\absolute.txt",
            "folder//empty-component.txt",
        ] {
            assert!(validate_direct_transfer_layout(
                "Selected folder",
                true,
                &[direct_file_entry(invalid, 1)],
                &[],
                1,
            )
            .is_err());
        }
    }

    #[test]
    fn direct_layout_rejects_duplicate_and_conflicting_hierarchies() {
        assert!(validate_direct_transfer_layout(
            "folder",
            true,
            &[direct_file_entry("A.txt", 1), direct_file_entry("a.TXT", 1),],
            &[],
            2,
        )
        .is_err());
        assert!(validate_direct_transfer_layout(
            "folder",
            true,
            &[
                direct_file_entry("node", 1),
                direct_file_entry("node/child.txt", 1),
            ],
            &[],
            2,
        )
        .is_err());
        assert!(validate_direct_transfer_layout(
            "folder",
            true,
            &[direct_file_entry("empty/child.txt", 1)],
            &["empty".to_owned()],
            1,
        )
        .is_err());
    }

    #[test]
    fn direct_layout_rejects_wrong_total_and_unattended_size_over_limit() {
        assert!(validate_direct_transfer_layout(
            "report.bin",
            false,
            &[direct_file_entry("", 10)],
            &[],
            9,
        )
        .is_err());
        assert!(validate_direct_transfer_layout(
            "report.bin",
            false,
            &[direct_file_entry("", DIRECT_TRANSFER_MAX_TOTAL_BYTES + 1)],
            &[],
            DIRECT_TRANSFER_MAX_TOTAL_BYTES + 1,
        )
        .is_err());
    }

    #[test]
    fn strict_manifest_preserves_files_and_empty_directories() {
        let test_dir =
            std::env::temp_dir().join(format!("mdesk-direct-manifest-{}", uuid::Uuid::new_v4()));
        let selected = test_dir.join("selected");
        std::fs::create_dir_all(selected.join("nested/empty")).unwrap();
        std::fs::write(selected.join("report.txt"), b"report").unwrap();
        std::fs::write(selected.join("nested/image.bin"), b"image").unwrap();

        let manifest = get_direct_transfer_manifest(&selected).unwrap();
        assert_eq!(manifest.root_name, "selected");
        assert!(manifest.is_directory);
        assert_eq!(manifest.total_size, 11);
        assert!(manifest.files.iter().any(|file| file.name == "report.txt"));
        assert!(manifest
            .files
            .iter()
            .any(|file| file.name == "nested/image.bin"));
        assert_eq!(manifest.empty_dirs, vec!["nested/empty"]);

        std::fs::remove_dir_all(test_dir).unwrap();
    }

    #[test]
    fn transfer_error_is_preserved_for_terminal_outcome() {
        let mut job = validation_job();
        job.transfer_error = Some("source read failed".to_owned());

        assert_eq!(job.job_error().as_deref(), Some("source read failed"));
    }

    #[test]
    fn audit_does_not_mark_partially_skipped_multi_file_job_complete() {
        let mut job = validation_job();
        job.set_files(vec![file_entry("keep.txt"), file_entry("skip.txt")])
            .unwrap();
        job.set_file_skipped();
        // Starting/confirming a later file resets the legacy "last file"
        // marker, but the immutable audit accumulator must remain set.
        job.set_file_confirmed(true);

        assert!(job.job_error().is_none());
        assert_eq!(
            job.audit_error().as_deref(),
            Some("one or more files were skipped")
        );
    }

    #[tokio::test]
    async fn finalize_write_flushes_and_renames_download_file() {
        let test_dir =
            std::env::temp_dir().join(format!("mdesk-finalize-write-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&test_dir).unwrap();
        let destination = test_dir.join("audit.txt");
        let mut job = TransferJob::new_write(
            7,
            JobType::Generic,
            String::new(),
            DataSource::FilePath(destination.clone()),
            0,
            false,
            false,
            false,
        )
        .with_files(vec![FileEntry {
            name: String::new(),
            size: 5,
            modified_time: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs(),
            ..Default::default()
        }])
        .unwrap();

        job.write(FileTransferBlock {
            id: 7,
            file_num: 0,
            data: b"audit".to_vec().into(),
            ..Default::default()
        })
        .await
        .unwrap();
        job.finalize_write().await.unwrap();

        assert_eq!(std::fs::read(&destination).unwrap(), b"audit");
        assert!(!PathBuf::from(format!("{}.download", destination.display())).exists());

        std::fs::remove_file(&destination).unwrap();
        std::fs::remove_dir(&test_dir).unwrap();
    }

    #[tokio::test]
    async fn printer_memory_job_accepts_blocks_without_a_file_manifest() {
        let mut job = TransferJob::new_write(
            8,
            JobType::Printer,
            "printer".to_owned(),
            DataSource::MemoryCursor(Cursor::new(Vec::new())),
            0,
            false,
            true,
            false,
        );
        job.write(FileTransferBlock {
            id: 8,
            file_num: 0,
            data: b"print-data".to_vec().into(),
            ..Default::default()
        })
        .await
        .unwrap();

        assert_eq!(job.get_buf_data().await.unwrap().unwrap(), b"print-data");
    }

    #[tokio::test]
    async fn direct_write_rejects_blocks_beyond_declared_file_size() {
        let test_dir =
            std::env::temp_dir().join(format!("mdesk-direct-limit-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&test_dir).unwrap();
        let destination = test_dir.join("bounded.bin");
        let mut job = TransferJob::new_write(
            -7,
            JobType::Generic,
            "bounded.bin".to_owned(),
            DataSource::FilePath(destination),
            0,
            false,
            true,
            false,
        )
        .with_files(vec![direct_file_entry("", 3)])
        .unwrap();
        job.set_strict_direct_transfer(true);
        job.set_never_overwrite_destination(true);

        let err = job
            .write(FileTransferBlock {
                id: -7,
                file_num: 0,
                data: b"four".to_vec().into(),
                ..Default::default()
            })
            .await
            .unwrap_err();
        assert!(err.to_string().contains("declared chunk size"));
        assert!(!test_dir.join("bounded.bin.download").exists());
        std::fs::remove_dir(test_dir).unwrap();
    }

    #[tokio::test]
    async fn direct_write_bounds_decompressed_bytes_and_file_sequence() {
        let test_dir = std::env::temp_dir().join(format!(
            "mdesk-direct-decompressed-limit-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&test_dir).unwrap();
        let destination = test_dir.join("bounded");
        let mut compressed_job = TransferJob::new_write(
            -9,
            JobType::Generic,
            "bounded".to_owned(),
            DataSource::FilePath(destination.clone()),
            0,
            false,
            true,
            false,
        )
        .with_files(vec![direct_file_entry("first.bin", 3)])
        .unwrap();
        compressed_job.set_strict_direct_transfer(true);
        let err = compressed_job
            .write(FileTransferBlock {
                id: -9,
                file_num: 0,
                data: compress(b"four").into(),
                compressed: true,
                ..Default::default()
            })
            .await
            .unwrap_err();
        assert!(err.to_string().contains("declared size"));
        assert!(!destination.join("first.bin.download").exists());

        let mut short_block_job = TransferJob::new_write(
            -12,
            JobType::Generic,
            "bounded".to_owned(),
            DataSource::FilePath(destination.clone()),
            0,
            false,
            true,
            false,
        )
        .with_files(vec![direct_file_entry("short.bin", 3)])
        .unwrap();
        short_block_job.set_strict_direct_transfer(true);
        let err = short_block_job
            .write(FileTransferBlock {
                id: -12,
                file_num: 0,
                data: b"x".to_vec().into(),
                ..Default::default()
            })
            .await
            .unwrap_err();
        assert!(err.to_string().contains("declared chunk size"));

        let mut oversized_wire_job = TransferJob::new_write(
            -13,
            JobType::Generic,
            "bounded".to_owned(),
            DataSource::FilePath(destination.clone()),
            0,
            false,
            true,
            false,
        )
        .with_files(vec![direct_file_entry(
            "wire.bin",
            DIRECT_TRANSFER_MAX_BLOCK_BYTES as u64,
        )])
        .unwrap();
        oversized_wire_job.set_strict_direct_transfer(true);
        let err = oversized_wire_job
            .write(FileTransferBlock {
                id: -13,
                file_num: 0,
                data: vec![0; DIRECT_TRANSFER_MAX_BLOCK_BYTES + 1].into(),
                compressed: true,
                ..Default::default()
            })
            .await
            .unwrap_err();
        assert!(err.to_string().contains("wire block"));

        let mut sequence_job = TransferJob::new_write(
            -10,
            JobType::Generic,
            "bounded".to_owned(),
            DataSource::FilePath(destination.clone()),
            0,
            false,
            true,
            false,
        )
        .with_files(vec![
            direct_file_entry("first.bin", 1),
            direct_file_entry("second.bin", 1),
        ])
        .unwrap();
        sequence_job.set_strict_direct_transfer(true);
        let err = sequence_job
            .write(FileTransferBlock {
                id: -10,
                file_num: 1,
                data: b"x".to_vec().into(),
                ..Default::default()
            })
            .await
            .unwrap_err();
        assert!(err.to_string().contains("sequence is incomplete"));
        assert!(!destination.join("second.bin.download").exists());

        std::fs::remove_dir(test_dir).unwrap();
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn direct_read_rejects_a_source_replaced_after_manifest() {
        let test_dir = std::env::temp_dir().join(format!(
            "mdesk-direct-source-identity-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&test_dir).unwrap();
        let source = test_dir.join("source.bin");
        std::fs::write(&source, b"first").unwrap();
        let manifest = get_direct_transfer_manifest(&source).unwrap();
        std::fs::remove_file(&source).unwrap();
        std::fs::write(&source, b"other").unwrap();

        let mut job = TransferJob::new_direct_read(-11, source, &manifest).unwrap();
        let err = job.open_data_stream().await.unwrap_err();
        assert!(err.to_string().contains("identity changed"));
        assert_eq!(job.file_num(), job.files().len() as i32);

        std::fs::remove_dir_all(test_dir).unwrap();
    }

    #[tokio::test]
    async fn direct_finalize_materializes_a_zero_byte_file() {
        let test_dir =
            std::env::temp_dir().join(format!("mdesk-direct-zero-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&test_dir).unwrap();
        let source = test_dir.join("source-zero.txt");
        let destination = test_dir.join("received-zero.txt");
        std::fs::write(&source, Vec::<u8>::new()).unwrap();
        let manifest = get_direct_transfer_manifest(&source).unwrap();
        let mut source_job = TransferJob::new_direct_read(-8, source, &manifest).unwrap();
        let mut receiver_job = TransferJob::new_write(
            -8,
            JobType::Generic,
            manifest.root_name.clone(),
            DataSource::FilePath(destination.clone()),
            0,
            false,
            true,
            false,
        )
        .with_files(manifest.files.clone())
        .unwrap();
        receiver_job.set_strict_direct_transfer(true);
        receiver_job.set_never_overwrite_destination(true);

        assert!(!source_job.open_data_stream().await.unwrap());
        let eof = source_job.read().await.unwrap().unwrap();
        assert!(eof.data.is_empty());
        receiver_job.write(eof).await.unwrap();
        assert!(source_job.open_data_stream().await.unwrap());
        receiver_job.finalize_direct_write().await.unwrap();

        assert_eq!(std::fs::metadata(&destination).unwrap().len(), 0);
        std::fs::remove_dir_all(test_dir).unwrap();
    }

    #[tokio::test]
    async fn strict_source_and_receiver_complete_data_and_single_eof_block() {
        let test_dir = std::env::temp_dir().join(format!(
            "mdesk-direct-source-receiver-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&test_dir).unwrap();
        let source = test_dir.join("source.bin");
        let destination = test_dir.join("received.bin");
        std::fs::write(&source, b"payload").unwrap();
        let manifest = get_direct_transfer_manifest(&source).unwrap();
        let mut source_job = TransferJob::new_direct_read(-14, source, &manifest).unwrap();
        let mut receiver_job = TransferJob::new_write(
            -14,
            JobType::Generic,
            manifest.root_name.clone(),
            DataSource::FilePath(destination.clone()),
            0,
            false,
            true,
            false,
        )
        .with_files(manifest.files.clone())
        .unwrap();
        receiver_job.set_strict_direct_transfer(true);
        receiver_job.set_never_overwrite_destination(true);

        let mut saw_eof = false;
        loop {
            if source_job.open_data_stream().await.unwrap() {
                break;
            }
            let block = source_job.read().await.unwrap().unwrap();
            if block.data.is_empty() {
                saw_eof = true;
            }
            receiver_job.write(block).await.unwrap();
        }
        assert!(saw_eof);
        let duplicate_eof = receiver_job
            .write(FileTransferBlock {
                id: -14,
                file_num: 0,
                data: Vec::new().into(),
                ..Default::default()
            })
            .await
            .unwrap_err();
        assert!(duplicate_eof.to_string().contains("duplicate EOF"));

        receiver_job.finalize_direct_write().await.unwrap();
        assert_eq!(std::fs::read(destination).unwrap(), b"payload");
        std::fs::remove_dir_all(test_dir).unwrap();
    }
}
