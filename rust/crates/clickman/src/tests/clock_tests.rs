use std::time::Duration;

use time::macros::datetime;
use time::{OffsetDateTime, UtcOffset};

use crate::clock::{millis, rfc3339_millis, system, unix_millis};

#[test]
fn rfc3339_carries_milliseconds_in_utc() {
    assert_eq!(
        rfc3339_millis(datetime!(2026-09-30 12:00:00.123 UTC)),
        "2026-09-30T12:00:00.123Z"
    );
}

#[test]
fn rfc3339_pads_every_field() {
    assert_eq!(
        rfc3339_millis(datetime!(2026-01-02 03:04:05.006 UTC)),
        "2026-01-02T03:04:05.006Z"
    );
    assert_eq!(
        rfc3339_millis(datetime!(2026-01-02 03:04:05 UTC)),
        "2026-01-02T03:04:05.000Z"
    );
}

#[test]
fn sub_milliseconds_are_cut_not_rounded() {
    let time = datetime!(2026-09-30 12:00:00.123_999 UTC);
    assert_eq!(rfc3339_millis(time), "2026-09-30T12:00:00.123Z");
    assert_eq!(
        unix_millis(time),
        unix_millis(datetime!(2026-09-30 12:00:00.123 UTC))
    );
}

#[test]
fn unix_millis_counts_from_the_epoch() {
    assert_eq!(unix_millis(datetime!(1970-01-01 00:00:01.5 UTC)), 1_500);
}

#[test]
fn durations_count_in_milliseconds_and_saturate() {
    assert_eq!(millis(Duration::from_micros(1_500_999)), 1_500);
    assert_eq!(millis(Duration::MAX), i64::MAX);
}

#[test]
fn the_system_clock_is_now_in_utc() {
    let before = OffsetDateTime::now_utc();
    let now = system()();
    assert_eq!(now.offset(), UtcOffset::UTC);
    assert!(before <= now && now <= OffsetDateTime::now_utc());
}
