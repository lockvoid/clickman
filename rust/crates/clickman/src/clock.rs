use std::sync::Arc;
use std::time::Duration;

use time::OffsetDateTime;

/// The device clock, in UTC.
pub(crate) type Clock = Arc<dyn Fn() -> OffsetDateTime + Send + Sync>;

pub(crate) fn system() -> Clock {
    Arc::new(OffsetDateTime::now_utc)
}

/// Milliseconds since the Unix epoch.
pub(crate) fn unix_millis(time: OffsetDateTime) -> i64 {
    (time.unix_timestamp_nanos() / 1_000_000) as i64
}

pub(crate) fn millis(duration: Duration) -> i64 {
    duration.as_millis().min(i64::MAX as u128) as i64
}

/// RFC 3339 with milliseconds, e.g. `2026-09-30T12:00:00.123Z`.
pub(crate) fn rfc3339_millis(time: OffsetDateTime) -> String {
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        time.year(),
        u8::from(time.month()),
        time.day(),
        time.hour(),
        time.minute(),
        time.second(),
        time.millisecond(),
    )
}
