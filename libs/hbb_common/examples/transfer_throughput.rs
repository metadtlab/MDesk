//! Reproducible local end-to-end benchmark: real TransferJob, encrypted TCP,
//! destination finalization and SHA-256 verification. No production connections.
use hbb_common::{
    fs::{self, DataSource, JobType, TransferJob},
    message_proto::{file_response, message, Message},
    protobuf::Message as _,
    rand::{rngs::StdRng, RngCore, SeedableRng},
    sodiumoxide::crypto::secretbox::Key,
    tokio::{
        self,
        net::{TcpListener, TcpStream},
        time,
    },
    ResultType, Stream,
};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::Path,
    task::Poll,
    time::{Duration, Instant},
};

// Mirror src/common.rs::ThrottledInterval, including missed-tick throttling.
async fn transfer_tick(timer: &mut time::Interval, next: &mut Instant) {
    hbb_common::futures::future::poll_fn(|cx| match timer.poll_tick(cx) {
        Poll::Ready(_) if *next <= Instant::now() => {
            *next = Instant::now() + Duration::from_micros(900);
            Poll::Ready(())
        }
        Poll::Ready(_) => {
            cx.waker().wake_by_ref();
            Poll::Pending
        }
        Poll::Pending => Poll::Pending,
    })
    .await
}

fn hash(path: &Path) -> ResultType<Vec<u8>> {
    let mut file = std::fs::File::open(path)?;
    let mut buf = vec![0; 1024 * 1024];
    let mut digest = Sha256::new();
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        digest.update(&buf[..n]);
    }
    Ok(digest.finalize().to_vec())
}

async fn transfer(source: &Path, destination: &Path, paced: bool) -> ResultType<(f64, u64, u64)> {
    let read = TransferJob::new_read(
        7,
        JobType::Generic,
        String::new(),
        DataSource::FilePath(source.into()),
        0,
        true,
        false,
        false,
    )?;
    let total = read.total_size;
    let entries = read.files.clone();
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let local = listener.local_addr()?;
    let (client, accepted) = tokio::join!(TcpStream::connect(local), listener.accept());
    let client = client?;
    let (host, host_addr) = accepted?;
    client.set_nodelay(true)?;
    host.set_nodelay(true)?;
    let mut sender = Stream::from(client, local);
    let mut receiver = Stream::from(host, host_addr);
    sender.set_key(Key([17; 32]));
    receiver.set_key(Key([17; 32]));
    sender.set_send_timeout(30_000);
    let mut write = TransferJob::new_write(
        7,
        JobType::Generic,
        String::new(),
        DataSource::FilePath(destination.into()),
        0,
        true,
        true,
        false,
    )
    .with_files(entries)?;
    let receive = tokio::spawn(async move {
        let mut wire_bytes = 0u64;
        let mut blocks = 0u64;
        while let Some(bytes) = receiver.next().await {
            let msg = Message::parse_from_bytes(&bytes?)?;
            if let Some(message::Union::FileResponse(response)) = msg.union {
                match response.union {
                    Some(file_response::Union::Block(block)) => {
                        wire_bytes += block.data.len() as u64;
                        blocks += 1;
                        write.write(block).await?;
                    }
                    Some(file_response::Union::Done(_)) => {
                        write.finalize_write().await?;
                        return Ok::<_, hbb_common::anyhow::Error>((wire_bytes, blocks));
                    }
                    Some(file_response::Union::Error(err)) => hbb_common::bail!(err.error),
                    _ => {}
                }
            }
        }
        hbb_common::bail!("stream ended before completion")
    });
    let mut jobs = vec![read];
    let mut ticks = time::interval(Duration::from_millis(1));
    let mut next_tick = Instant::now();
    let started = Instant::now();
    while !jobs.is_empty() {
        if paced {
            transfer_tick(&mut ticks, &mut next_tick).await;
        }
        fs::handle_read_jobs(&mut jobs, &mut sender).await?;
    }
    let (wire, blocks) = receive.await??;
    let elapsed = started.elapsed().as_secs_f64();
    if source.is_dir() {
        for entry in std::fs::read_dir(source)? {
            let entry = entry?;
            assert_eq!(
                hash(&entry.path())?,
                hash(&destination.join(entry.file_name()))?
            );
        }
    } else {
        assert_eq!(hash(source)?, hash(destination)?);
    }
    Ok((total as f64 / (1024.0 * 1024.0) / elapsed, wire, blocks))
}

#[tokio::main(flavor = "multi_thread", worker_threads = 2)]
async fn main() -> ResultType<()> {
    let args = std::env::args().collect::<Vec<_>>();
    let label = args.get(1).map(String::as_str).unwrap_or("current");
    let mib = args
        .get(2)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(128)
        .clamp(1, 1024);
    let runs = args
        .get(3)
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(3)
        .clamp(1, 10);
    let root = std::env::temp_dir().join(format!(
        "mdesk-throughput-{}",
        hbb_common::uuid::Uuid::new_v4()
    ));
    std::fs::create_dir(&root)?;
    let mut rng = StdRng::seed_from_u64(20261001);
    let mut random = vec![0; 1024 * 1024];
    rng.fill_bytes(&mut random);
    let text = b"2026-10-01 MDesk file transfer compression and integrity benchmark\n";
    let compressible = text
        .iter()
        .copied()
        .cycle()
        .take(random.len())
        .collect::<Vec<_>>();
    println!("label,case,mode,run,mib,mib_per_second,wire_payload_bytes,blocks,sha256_ok");
    for case in ["random.bin", "random.mp4", "text.log", "small-files"] {
        let source = root.join(case);
        if case == "small-files" {
            std::fs::create_dir(&source)?;
            for i in 0..128 {
                std::fs::write(source.join(format!("{i:04}.bin")), &random[..4096])?;
            }
        } else {
            let mut file = std::fs::File::create(&source)?;
            for _ in 0..mib {
                file.write_all(if case == "text.log" {
                    &compressible
                } else {
                    &random
                })?;
            }
        }
        for paced in [true, false] {
            for run in 1..=runs {
                let destination = root.join(format!("destination-{case}-{paced}-{run}"));
                let (speed, wire, blocks) = transfer(&source, &destination, paced).await?;
                println!(
                    "{label},{case},{},{run},{},{speed:.3},{wire},{blocks},true",
                    if paced {
                        "production-timer"
                    } else {
                        "continuous"
                    },
                    if case == "small-files" {
                        0.5
                    } else {
                        mib as f64
                    }
                );
            }
        }
    }
    // Only the freshly created, uniquely named benchmark directory is removed.
    assert!(
        root.starts_with(std::env::temp_dir())
            && root
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("mdesk-throughput-")
    );
    std::fs::remove_dir_all(root)?;
    Ok(())
}
