use std::{
    collections::HashMap,
    net::{IpAddr, Ipv6Addr},
    time::{Duration, Instant},
};

const INITIAL_FAILURE_LIMIT: u8 = 10;
const SUBSEQUENT_FAILURE_LIMIT: u8 = 5;
const LOCKOUT_MINUTES: [u64; 3] = [5, 10, 30];

#[derive(Debug, Eq, Hash, PartialEq)]
enum AttemptKey {
    Ip(String),
    Peer(String),
    Ipv6Prefix(Ipv6Addr, u8),
}

#[derive(Default)]
struct Failures {
    attempts: u8,
    lockouts: u8,
    locked_until: Option<Instant>,
}

impl Failures {
    fn remaining(&self, now: Instant) -> Option<Duration> {
        self.locked_until
            .and_then(|until| until.checked_duration_since(now))
            .filter(|remaining| !remaining.is_zero())
    }

    fn record(&mut self, initial_limit: u8, now: Instant) {
        let limit = if self.lockouts == 0 {
            initial_limit
        } else {
            SUBSEQUENT_FAILURE_LIMIT
        };
        self.attempts += 1;
        if self.attempts >= limit {
            let minutes = LOCKOUT_MINUTES[usize::from(self.lockouts)];
            self.locked_until = Some(now + Duration::from_secs(minutes * 60));
            self.lockouts = (self.lockouts + 1).min(2);
            self.attempts = 0;
        }
    }
}

/// Shared by all incoming connections. Call under one mutex so failures from
/// different connections cannot overwrite one another's counters.
#[derive(Default)]
pub(crate) struct PasswordAttemptLimiter {
    failures: HashMap<AttemptKey, Failures>,
}

impl PasswordAttemptLimiter {
    fn keys(ip: &str, peer: &str) -> Vec<(AttemptKey, u8)> {
        let mut keys = Vec::with_capacity(5);
        let ip = ip.split('%').next().unwrap_or(ip).trim();
        if !ip.is_empty() {
            let addr = ip.parse::<IpAddr>().ok().map(|addr| match addr {
                IpAddr::V6(v6) => v6
                    .to_ipv4_mapped()
                    .map(IpAddr::V4)
                    .unwrap_or(IpAddr::V6(v6)),
                v4 => v4,
            });
            keys.push((
                AttemptKey::Ip(addr.map_or_else(|| ip.to_owned(), |addr| addr.to_string())),
                INITIAL_FAILURE_LIMIT,
            ));
            // IPv6 addresses can be rotated cheaply. Preserve the existing
            // aggregate /64, /56 and /48 thresholds, with timed lockouts.
            if let Some(IpAddr::V6(addr)) = addr {
                for (prefix, limit) in [(64, 60), (56, 80), (48, 100)] {
                    let network = u128::from(addr) & (!0u128 << (128 - prefix));
                    keys.push((
                        AttemptKey::Ipv6Prefix(Ipv6Addr::from(network), prefix),
                        limit,
                    ));
                }
            }
        }
        // Missing IDs must not group otherwise unrelated remote clients.
        if !peer.is_empty() {
            keys.push((AttemptKey::Peer(peer.to_owned()), INITIAL_FAILURE_LIMIT));
        }
        keys
    }

    pub(crate) fn blocked_for(&self, ip: &str, peer: &str, now: Instant) -> Option<Duration> {
        Self::keys(ip, peer)
            .iter()
            .filter_map(|(key, _)| self.failures.get(key)?.remaining(now))
            .max()
    }

    pub(crate) fn record_failure(
        &mut self,
        ip: &str,
        peer: &str,
        now: Instant,
    ) -> Option<Duration> {
        if let Some(remaining) = self.blocked_for(ip, peer, now) {
            // Requests already in flight when a lockout began must not
            // escalate or extend it.
            return Some(remaining);
        }
        for (key, limit) in Self::keys(ip, peer) {
            self.failures.entry(key).or_default().record(limit, now);
        }
        self.blocked_for(ip, peer, now)
    }

    pub(crate) fn record_success(
        &mut self,
        ip: &str,
        peer: &str,
        now: Instant,
    ) -> Option<Duration> {
        if let Some(remaining) = self.blocked_for(ip, peer, now) {
            // A valid password checked concurrently with the threshold
            // failure cannot clear an active lockout.
            return Some(remaining);
        }
        for (key, _) in Self::keys(ip, peer) {
            // One successful client cannot clear an entire IPv6 network's
            // protection against attempts from other addresses.
            if !matches!(key, AttemptKey::Ipv6Prefix(..)) {
                self.failures.remove(&key);
            }
        }
        None
    }
}

pub(crate) fn lockout_message(remaining: Duration) -> String {
    let minutes = (remaining.as_secs() / 60
        + u64::from(remaining.as_secs() % 60 != 0 || remaining.subsec_nanos() != 0))
    .max(1);
    format!("Too many wrong password attempts. Please try again in {{{minutes}}} minutes.")
}

#[cfg(test)]
mod tests {
    use super::*;

    const IP: &str = "192.0.2.1";
    const PEER: &str = "remote-1";

    fn fail(
        limiter: &mut PasswordAttemptLimiter,
        ip: &str,
        peer: &str,
        count: usize,
        now: Instant,
    ) -> Option<Duration> {
        for _ in 1..count {
            assert_eq!(limiter.record_failure(ip, peer, now), None);
        }
        limiter.record_failure(ip, peer, now)
    }

    #[test]
    fn locks_on_tenth_then_every_fifth_failure_and_caps_at_thirty_minutes() {
        let mut limiter = PasswordAttemptLimiter::default();
        let mut now = Instant::now();
        for (attempts, minutes) in [(10, 5), (5, 10), (5, 30), (5, 30), (5, 30)] {
            let duration = Duration::from_secs(minutes * 60);
            assert_eq!(fail(&mut limiter, IP, PEER, attempts, now), Some(duration));
            assert_eq!(limiter.blocked_for(IP, PEER, now), Some(duration));
            assert_eq!(
                limiter.blocked_for(IP, PEER, now + duration - Duration::from_nanos(1)),
                Some(Duration::from_nanos(1))
            );
            now += duration;
            assert_eq!(limiter.blocked_for(IP, PEER, now), None);
        }
    }

    #[test]
    fn slow_failures_still_count_across_minutes_and_connections() {
        let mut limiter = PasswordAttemptLimiter::default();
        let start = Instant::now();
        for attempt in 0..9 {
            assert_eq!(
                limiter.record_failure(IP, PEER, start + Duration::from_secs(attempt * 120)),
                None
            );
        }
        assert_eq!(
            limiter.record_failure(IP, PEER, start + Duration::from_secs(9 * 120)),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn retries_do_not_extend_lockout_or_advance_next_stage() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        fail(&mut limiter, IP, PEER, 10, now);
        for _ in 0..100 {
            assert_eq!(
                limiter.record_failure(IP, PEER, now + Duration::from_secs(299)),
                Some(Duration::from_secs(1))
            );
        }
        assert_eq!(
            fail(&mut limiter, IP, PEER, 5, now + Duration::from_secs(300)),
            Some(Duration::from_secs(600))
        );
    }

    #[test]
    fn changing_peer_id_does_not_bypass_ip_counter_or_lockout() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        for i in 0..9 {
            assert_eq!(limiter.record_failure(IP, &format!("peer-{i}"), now), None);
        }
        assert_eq!(
            limiter.record_failure(IP, "new-peer", now),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            limiter.blocked_for(IP, "another-peer", now),
            Some(Duration::from_secs(300))
        );
        assert_eq!(limiter.blocked_for("192.0.2.2", "another-peer", now), None);
    }

    #[test]
    fn changing_ip_does_not_bypass_peer_counter_or_lockout() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        for i in 1..10 {
            assert_eq!(
                limiter.record_failure(&format!("192.0.2.{i}"), PEER, now),
                None
            );
        }
        assert_eq!(
            limiter.record_failure("192.0.2.10", PEER, now),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            limiter.blocked_for("192.0.2.11", PEER, now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn uses_longest_lock_when_ip_and_peer_have_different_stages() {
        let mut limiter = PasswordAttemptLimiter::default();
        let start = Instant::now();
        fail(&mut limiter, IP, PEER, 10, start);
        let now = start + Duration::from_secs(300);
        fail(&mut limiter, IP, PEER, 5, now);
        fail(&mut limiter, "192.0.2.2", "remote-2", 10, now);
        assert_eq!(
            limiter.blocked_for(IP, "remote-2", now),
            Some(Duration::from_secs(600))
        );
    }

    #[test]
    fn successful_authentication_resets_current_ip_and_peer_after_expiry() {
        let mut limiter = PasswordAttemptLimiter::default();
        let start = Instant::now();
        fail(&mut limiter, IP, PEER, 10, start);
        let now = start + Duration::from_secs(300);
        assert_eq!(limiter.record_success(IP, PEER, now), None);
        assert_eq!(
            fail(&mut limiter, IP, PEER, 10, now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn success_before_threshold_resets_failures() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        assert_eq!(fail(&mut limiter, IP, PEER, 9, now), None);
        assert_eq!(limiter.record_success(IP, PEER, now), None);
        assert_eq!(
            fail(&mut limiter, IP, PEER, 10, now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn valid_password_cannot_reset_an_active_lockout() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        fail(&mut limiter, IP, PEER, 10, now);
        assert_eq!(
            limiter.record_success(IP, PEER, now),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            limiter.record_success(IP, "other-peer", now),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            limiter.record_success("192.0.2.2", PEER, now),
            Some(Duration::from_secs(300))
        );
        assert_eq!(
            limiter.blocked_for(IP, PEER, now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn successful_unrelated_client_does_not_reset_another_client() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        fail(&mut limiter, IP, PEER, 10, now);
        assert_eq!(limiter.record_success("192.0.2.2", "remote-2", now), None);
        assert_eq!(
            limiter.blocked_for(IP, PEER, now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn empty_peer_ids_do_not_share_counters_across_ips() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        fail(&mut limiter, IP, "", 10, now);
        assert_eq!(limiter.blocked_for("192.0.2.2", "", now), None);
        assert_eq!(
            limiter.blocked_for(IP, "", now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn ipv4_mapped_ipv6_cannot_bypass_the_ipv4_lock() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        fail(&mut limiter, IP, "", 10, now);
        assert_eq!(
            limiter.blocked_for("::ffff:192.0.2.1", "", now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn equivalent_ipv6_addresses_and_zone_ids_share_the_ip_counter() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        fail(&mut limiter, "2001:db8::1", "", 10, now);
        assert_eq!(
            limiter.blocked_for("2001:0db8:0:0:0:0:0:1%eth0", "", now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn rotating_ipv6_addresses_is_limited_by_each_network_prefix() {
        for (prefix, limit) in [(64, 60), (56, 80), (48, 100)] {
            let mut limiter = PasswordAttemptLimiter::default();
            let now = Instant::now();
            let address = |i: usize| match prefix {
                64 => format!("2001:db8:1:1::{i:x}"),
                56 => format!("2001:db8:1:{i:x}::1"),
                _ => format!("2001:db8:1:{:x}::1", i << 8),
            };
            for i in 1..limit {
                assert_eq!(limiter.record_failure(&address(i), "", now), None);
            }
            assert_eq!(
                limiter.record_failure(&address(limit), "", now),
                Some(Duration::from_secs(300))
            );
            assert_eq!(
                limiter.blocked_for(&address(limit + 1), "", now),
                Some(Duration::from_secs(300))
            );
            assert_eq!(limiter.blocked_for("2001:db8:2::1", "", now), None);
            assert_eq!(
                limiter.blocked_for(&address(limit + 1), "", now + Duration::from_secs(300)),
                None
            );
        }
    }

    #[test]
    fn one_ipv6_success_does_not_clear_other_addresses_failures() {
        let mut limiter = PasswordAttemptLimiter::default();
        let now = Instant::now();
        for i in 1..60 {
            assert_eq!(
                limiter.record_failure(&format!("2001:db8::{i:x}"), "", now),
                None
            );
        }
        assert_eq!(
            limiter.record_success("2001:db8::ff", "remote-ok", now),
            None
        );
        assert_eq!(
            limiter.record_failure("2001:db8::100", "", now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn concurrent_failures_are_counted_without_losing_updates() {
        use std::sync::{Arc, Barrier, Mutex};
        let limiter = Arc::new(Mutex::new(PasswordAttemptLimiter::default()));
        let barrier = Arc::new(Barrier::new(10));
        let now = Instant::now();
        let mut threads = Vec::new();
        for _ in 0..10 {
            let limiter = limiter.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                limiter.lock().unwrap().record_failure(IP, PEER, now)
            }));
        }
        let locked_responses = threads
            .into_iter()
            .filter_map(|thread| thread.join().unwrap())
            .count();
        assert_eq!(locked_responses, 1);
        assert_eq!(
            limiter.lock().unwrap().blocked_for(IP, PEER, now),
            Some(Duration::from_secs(300))
        );
    }

    #[test]
    fn reports_remaining_time_rounded_up_to_at_least_one_minute() {
        for (duration, minutes) in [
            (Duration::from_secs(300), 5),
            (Duration::from_secs(61), 2),
            (Duration::from_secs(60), 1),
            (Duration::from_millis(60_001), 2),
            (Duration::from_millis(1), 1),
        ] {
            assert_eq!(
                lockout_message(duration),
                format!(
                    "Too many wrong password attempts. Please try again in {{{minutes}}} minutes."
                )
            );
        }
    }
}
