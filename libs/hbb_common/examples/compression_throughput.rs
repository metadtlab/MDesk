//! Compare bounded CPU compression before considering acceleration dependencies.
use hbb_common::{
    rand::{rngs::StdRng, RngCore, SeedableRng},
    ResultType,
};
use std::time::Instant;

fn main() -> ResultType<()> {
    const BLOCK: usize = 128 * 1024;
    const BLOCKS: usize = 1024; // 128 MiB, exactly the production frame size.
    let mut rng = StdRng::seed_from_u64(20261001);
    let mut random = vec![0; BLOCK];
    rng.fill_bytes(&mut random);
    let mut logs = Vec::with_capacity(BLOCK);
    while logs.len() < BLOCK {
        let row = format!("2026-10-02 request={} customer={} device={} event=file_transfer bytes={} status=success\n", rng.next_u32(), rng.next_u32() % 1000, rng.next_u32() % 100, rng.next_u32());
        logs.extend_from_slice(row.as_bytes());
    }
    logs.truncate(BLOCK);
    println!("case,level,threads,mib_per_second,wire_ratio,roundtrip_ok");
    for (name, data) in [("random", random), ("varied-logs", logs)] {
        for level in [1, 3, 6] {
            for threads in [1, 2, 4] {
                let start = Instant::now();
                let bytes = std::thread::scope(|scope| {
                    let workers = (0..threads)
                        .map(|_| {
                            let data = &data;
                            scope.spawn(move || -> ResultType<usize> {
                                let mut compressor = zstd::bulk::Compressor::new(level)?;
                                let first = compressor.compress(data)?;
                                assert_eq!(zstd::decode_all(first.as_slice())?, *data);
                                let mut bytes = first.len();
                                for _ in 1..BLOCKS / threads {
                                    bytes += compressor.compress(data)?.len();
                                }
                                Ok(bytes)
                            })
                        })
                        .collect::<Vec<_>>();
                    workers.into_iter().try_fold(0usize, |sum, worker| {
                        Ok::<_, hbb_common::anyhow::Error>(sum + worker.join().unwrap()?)
                    })
                })?;
                println!(
                    "{name},{level},{threads},{:.3},{:.6},true",
                    128.0 / start.elapsed().as_secs_f64(),
                    bytes as f64 / (BLOCK * BLOCKS) as f64
                );
            }
        }
    }
    Ok(())
}
