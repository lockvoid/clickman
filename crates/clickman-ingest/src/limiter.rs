use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::settings::RateLimit;

const PRUNE_ABOVE: usize = 100_000;
const IDLE: Duration = Duration::from_secs(600);

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allowed,
    Limited { retry_after: Duration },
}

/// A token bucket per client: `burst` requests at once, refilled at
/// `per_second`.
#[derive(Default)]
pub struct RateLimiter {
    buckets: Mutex<HashMap<String, Bucket>>,
}

struct Bucket {
    tokens: f64,
    refreshed: Instant,
}

impl RateLimiter {
    pub fn check(&self, client: &str, limit: RateLimit, now: Instant) -> Decision {
        let mut buckets = self
            .buckets
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        if buckets.len() > PRUNE_ABOVE {
            buckets.retain(|_, bucket| now.duration_since(bucket.refreshed) < IDLE);
        }

        let bucket = buckets.entry(client.to_owned()).or_insert(Bucket {
            tokens: limit.burst,
            refreshed: now,
        });
        let elapsed = now.duration_since(bucket.refreshed).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * limit.per_second).min(limit.burst);
        bucket.refreshed = now;

        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            Decision::Allowed
        } else {
            let seconds = ((1.0 - bucket.tokens) / limit.per_second).ceil().max(1.0);
            Decision::Limited {
                retry_after: Duration::from_secs_f64(seconds),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMIT: RateLimit = RateLimit {
        per_second: 2.0,
        burst: 3.0,
    };

    #[test]
    fn a_burst_is_allowed_then_the_client_waits_for_a_refill() {
        let limiter = RateLimiter::default();
        let start = Instant::now();

        for _ in 0..3 {
            assert_eq!(limiter.check("a", LIMIT, start), Decision::Allowed);
        }
        assert_eq!(
            limiter.check("a", LIMIT, start),
            Decision::Limited {
                retry_after: Duration::from_secs(1)
            }
        );
        assert_eq!(
            limiter.check("a", LIMIT, start + Duration::from_millis(500)),
            Decision::Allowed
        );
    }

    #[test]
    fn clients_have_their_own_buckets() {
        let limiter = RateLimiter::default();
        let now = Instant::now();

        for _ in 0..3 {
            limiter.check("a", LIMIT, now);
        }

        assert_eq!(limiter.check("b", LIMIT, now), Decision::Allowed);
    }

    #[test]
    fn a_bucket_never_holds_more_than_the_burst() {
        let limiter = RateLimiter::default();
        let now = Instant::now();
        limiter.check("a", LIMIT, now);

        let later = now + Duration::from_secs(60);
        for _ in 0..3 {
            assert_eq!(limiter.check("a", LIMIT, later), Decision::Allowed);
        }
        assert!(matches!(
            limiter.check("a", LIMIT, later),
            Decision::Limited { .. }
        ));
    }
}
