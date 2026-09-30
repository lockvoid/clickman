use std::time::Duration;

const FIRST_DELAY: Duration = Duration::from_secs(5);
const MAX_DELAY: Duration = Duration::from_secs(600);

/// The wait before the next attempt after `failures` consecutive failures: 5 s
/// doubled per failure up to 600 s, times a factor in [0.8, 1.2] drawn from
/// `random` in [0, 1), or `retry_after` when that is longer (backoff.json).
pub(crate) fn delay(failures: u32, retry_after: Option<Duration>, random: f64) -> Duration {
    let doubled = FIRST_DELAY
        .saturating_mul(2u32.saturating_pow(failures.saturating_sub(1)))
        .min(MAX_DELAY);
    let jittered =
        Duration::from_millis((doubled.as_millis() as f64 * (0.8 + 0.4 * random)) as u64);
    retry_after.map_or(jittered, |advice| advice.max(jittered))
}

/// A `Retry-After` of integer seconds; any other form is no advice.
pub(crate) fn retry_after(header: Option<&str>) -> Option<Duration> {
    let digits = header?.trim();
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let seconds = digits.bytes().fold(0u64, |seconds, digit| {
        seconds
            .saturating_mul(10)
            .saturating_add(u64::from(digit - b'0'))
    });
    Some(Duration::from_secs(seconds))
}
