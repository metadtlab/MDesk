//! Explicit, fixed-target tool upload. Ordinary Downloads transfers never execute files.
use hbb_common::{anyhow::anyhow, bail, fs, message_proto::FileEntry, ResultType};
use std::path::{Path, PathBuf};

pub fn prepare(
    target: &str,
    id: i32,
    file_num: i32,
    files: &[(String, u64)],
    size: u64,
    conn_id: i32,
) -> ResultType<fs::TransferJob> {
    if !cfg!(windows) {
        bail!("DeviceRemote requires Windows");
    }
    if target != fs::DEVICE_REMOTE_TARGET
        || file_num != 0
        || files.len() != 1
        || !files[0].0.is_empty()
        || size == 0
        || size > 64 * 1024 * 1024
    {
        bail!("Invalid DeviceRemote upload");
    }
    let directory = fs::get_download_dir_strict()?;
    new_job(directory, id, files[0].1, size, conn_id)
}

fn new_job(
    directory: PathBuf,
    id: i32,
    modified: u64,
    size: u64,
    conn_id: i32,
) -> ResultType<fs::TransferJob> {
    check_target(&directory.join("DeviceRemote.exe"))?;
    // Unique staging prevents an interrupted upload from replacing an existing executable.
    let staging = directory.join(format!(".mdesk-device-remote-{}.exe", uuid::Uuid::new_v4()));
    let mut job = fs::TransferJob::new_write(
        id,
        fs::JobType::Generic,
        String::new(),
        fs::DataSource::FilePath(staging),
        0,
        false,
        false,
        false,
    )
    .with_files(vec![FileEntry {
        name: String::new(),
        size,
        modified_time: modified,
        ..Default::default()
    }])?;
    job.conn_id = conn_id;
    job.device_remote_launch = true;
    job.set_strict_direct_transfer(true);
    job.set_mtime_to_now(true);
    Ok(job)
}

fn check_target(path: &Path) -> ResultType<()> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    bail!("DeviceRemote target is a reparse point");
                }
            }
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                bail!("DeviceRemote target is not a regular file");
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error.into()),
    }
    Ok(())
}

/// Only invoke launch after complete, size-checked EOF and successful replacement.
pub async fn finish(
    job: &mut fs::TransferJob,
    launch: impl FnOnce(&Path) -> ResultType<()>,
) -> ResultType<()> {
    if !job.device_remote_launch || job.audit_error().is_some() {
        bail!("DeviceRemote transfer failed");
    }
    job.finalize_direct_write().await?;
    let fs::DataSource::FilePath(staging) = &job.data_source else {
        bail!("Invalid DeviceRemote staging path");
    };
    check_target(staging)?;
    let destination = staging
        .parent()
        .ok_or_else(|| anyhow!("Missing Downloads folder"))?
        .join("DeviceRemote.exe");
    check_target(&destination)?;
    std::fs::rename(staging, &destination).map_err(|error| {
        anyhow!(
            "DeviceRemote.exe 교체 실패. 실행 중인 디바이스 원격을 닫고 다시 시도해주세요: {error}"
        )
    })?;
    launch(&destination)
}

pub fn launch(path: &Path) -> ResultType<()> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // No Explorer, shell, elevation verb, or download window. The tool's own UI is visible.
        std::process::Command::new(path)
            .current_dir(
                path.parent()
                    .ok_or_else(|| anyhow!("Missing tool folder"))?,
            )
            .creation_flags(0x08000000)
            .spawn()
            .map_err(|error| anyhow!("DeviceRemote.exe 실행 실패: {error}"))?;
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        bail!("DeviceRemote requires Windows");
    }
}

pub fn cleanup(job: &fs::TransferJob) {
    if !job.device_remote_launch {
        return;
    }
    job.remove_download_file();
    if let fs::DataSource::FilePath(staging) = &job.data_source {
        // Generated staging path only; never remove DeviceRemote.exe or its containing directory.
        if staging
            .file_name()
            .and_then(|name| name.to_str())
            .map_or(false, |name| name.starts_with(".mdesk-device-remote-"))
        {
            let _ = std::fs::remove_file(staging);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::{message_proto::FileTransferBlock, tokio};
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("mdesk-device-test-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn target(&self) -> PathBuf {
            self.0.join("DeviceRemote.exe")
        }
        fn job(&self) -> fs::TransferJob {
            new_job(self.0.clone(), 7, 0, 5, 1).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            // Only this test's UUID directory; never touch real Downloads.
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    async fn block(job: &mut fs::TransferJob, bytes: &[u8]) {
        job.write(FileTransferBlock {
            id: 7,
            file_num: 0,
            data: bytes.to_vec().into(),
            ..Default::default()
        })
        .await
        .unwrap();
    }
    #[tokio::test]
    async fn completed_upload_replaces_and_launches_only_fixed_target_without_explorer() {
        for old in [None, Some(b"older".as_slice()), Some(b"newer".as_slice())] {
            let fixture = Fixture::new();
            if let Some(old) = old {
                std::fs::write(fixture.target(), old).unwrap();
            }
            let mut job = fixture.job();
            assert!(job.folder_to_open_on_done().is_none());
            block(&mut job, b"newer").await;
            assert_eq!(std::fs::read(fixture.target()).ok().as_deref(), old);
            block(&mut job, b"").await;
            let mut launches = 0;
            finish(&mut job, |path| {
                launches += 1;
                assert_eq!(path, fixture.target());
                assert_eq!(std::fs::read(path).unwrap(), b"newer");
                Ok(())
            })
            .await
            .unwrap();
            assert_eq!(launches, 1);
            cleanup(&job);
            assert_eq!(std::fs::read_dir(&fixture.0).unwrap().count(), 1);
        }
    }
    #[tokio::test]
    async fn premature_done_or_missing_eof_preserves_existing_file_and_never_launches() {
        for send_data in [false, true] {
            let fixture = Fixture::new();
            std::fs::write(fixture.target(), b"older").unwrap();
            let mut job = fixture.job();
            if send_data {
                block(&mut job, b"newer").await;
            }
            assert!(
                finish(&mut job, |_| panic!("must not launch incomplete upload"))
                    .await
                    .is_err()
            );
            cleanup(&job);
            drop(job);
            assert_eq!(std::fs::read(fixture.target()).unwrap(), b"older");
        }
    }
    #[tokio::test]
    async fn wrong_size_block_is_rejected_and_cancellation_keeps_old_file() {
        let fixture = Fixture::new();
        std::fs::write(fixture.target(), b"older").unwrap();
        let mut job = fixture.job();
        assert!(job
            .write(FileTransferBlock {
                id: 7,
                file_num: 0,
                data: b"bad".to_vec().into(),
                ..Default::default()
            })
            .await
            .is_err());
        cleanup(&job);
        assert_eq!(std::fs::read(fixture.target()).unwrap(), b"older");
    }
    #[tokio::test]
    async fn launch_failure_is_reported_after_successful_replacement() {
        let fixture = Fixture::new();
        let mut job = fixture.job();
        block(&mut job, b"newer").await;
        block(&mut job, b"").await;
        assert!(finish(&mut job, |_| Err(anyhow!("launch refused")))
            .await
            .unwrap_err()
            .to_string()
            .contains("launch refused"));
        assert_eq!(std::fs::read(fixture.target()).unwrap(), b"newer");
    }
    #[cfg(windows)]
    #[tokio::test]
    async fn locked_existing_file_is_not_killed_or_executed() {
        use std::os::windows::fs::OpenOptionsExt;
        let fixture = Fixture::new();
        std::fs::write(fixture.target(), b"older").unwrap();
        let locked = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(0)
            .open(fixture.target())
            .unwrap();
        let mut job = fixture.job();
        block(&mut job, b"newer").await;
        block(&mut job, b"").await;
        assert!(
            finish(&mut job, |_| panic!("must not launch old executable"))
                .await
                .is_err()
        );
        drop(locked);
        cleanup(&job);
        assert_eq!(std::fs::read(fixture.target()).unwrap(), b"older");
    }
    #[test]
    fn rejects_nonfixed_targets_directories_resume_empty_and_oversize_manifests() {
        for target in [
            "mdesk-device-remote:other.exe",
            "mdesk-device-remote:../DeviceRemote.exe",
            "mdesk-drop-downloads:DeviceRemote.exe",
        ] {
            assert!(prepare(target, 7, 0, &[(String::new(), 0)], 5, 1).is_err());
        }
        for (offset, files, size) in [
            (1, vec![(String::new(), 0)], 5),
            (0, vec![("other.exe".into(), 0)], 5),
            (0, vec![], 5),
            (0, vec![(String::new(), 0)], 0),
            (0, vec![(String::new(), 0)], 64 * 1024 * 1024 + 1),
        ] {
            assert!(prepare(fs::DEVICE_REMOTE_TARGET, 7, offset, &files, size, 1).is_err());
        }
        let fixture = Fixture::new();
        std::fs::create_dir(fixture.target()).unwrap();
        assert!(new_job(fixture.0.clone(), 7, 0, 5, 1).is_err());
    }
}
