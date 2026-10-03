//! Compare the crypto library's default and initialized CPU implementations.
//! Synthetic public key/data only; validates unchanged secretbox wire output.
use hbb_common::{
    bytes::BytesMut,
    sodiumoxide::crypto::secretbox::{self, Key, Nonce},
    tcp::Encrypt,
};
use std::time::Instant;

fn throughput(data: &[u8], key: &Key) -> f64 {
    let start = Instant::now();
    for sequence in 1..=1024u64 {
        let mut nonce = Nonce([0; secretbox::NONCEBYTES]);
        nonce.0[..8].copy_from_slice(&sequence.to_le_bytes());
        std::hint::black_box(secretbox::seal(data, &nonce, key));
    }
    128.0 / start.elapsed().as_secs_f64()
}

fn main() {
    let data = vec![0xA5; 128 * 1024];
    let key = Key([17; secretbox::KEYBYTES]);
    let mut nonce = Nonce([0; secretbox::NONCEBYTES]);
    nonce.0[..8].copy_from_slice(&1u64.to_le_bytes());
    let before = secretbox::seal(&data, &nonce, &key);
    let default_speed = throughput(&data, &key);
    let mut sender = Encrypt::new(key.clone());
    let initialized_speed = throughput(&data, &key);
    let after = sender.enc(&data);
    assert_eq!(
        before, after,
        "initialization must preserve ciphertext framing"
    );
    let mut receiver = Encrypt::new(key);
    let mut frame = BytesMut::from(after.as_slice());
    receiver.dec(&mut frame).unwrap();
    assert_eq!(frame.as_ref(), data);
    let mut damaged = sender.enc(&data);
    damaged[32] ^= 1;
    assert!(receiver
        .dec(&mut BytesMut::from(damaged.as_slice()))
        .is_err());
    println!("implementation,mib_per_second,wire_compatible,tamper_rejected");
    println!("default,{default_speed:.3},true,true");
    println!("initialized,{initialized_speed:.3},true,true");
}
