use std::time::Duration;

use crate::backoff::{delay, retry_after};

#[test]
fn retry_after_is_integer_seconds() {
    assert_eq!(retry_after(Some("30")), Some(Duration::from_secs(30)));
    assert_eq!(retry_after(Some(" 7 ")), Some(Duration::from_secs(7)));
    assert_eq!(retry_after(Some("0")), Some(Duration::ZERO));
}

#[test]
fn any_other_retry_after_is_no_advice() {
    assert_eq!(retry_after(None), None);
    for header in [
        "",
        " ",
        "1.5",
        "-1",
        "+3",
        "Wed, 21 Oct 2026 07:28:00 GMT",
        "soon",
    ] {
        assert_eq!(retry_after(Some(header)), None, "{header:?}");
    }
}

#[test]
fn an_absurd_retry_after_saturates() {
    assert_eq!(
        retry_after(Some("99999999999999999999999")),
        Some(Duration::from_secs(u64::MAX))
    );
}

#[test]
fn the_factor_runs_from_0_8_to_1_2() {
    assert_eq!(delay(1, None, 0.0), Duration::from_secs(4));
    assert_eq!(delay(1, None, 0.5), Duration::from_secs(5));
    let highest = delay(1, None, 1.0 - f64::EPSILON);
    assert!(
        (Duration::from_millis(5_999)..=Duration::from_secs(6)).contains(&highest),
        "{highest:?}"
    );
}

#[test]
fn the_cap_holds_for_any_number_of_failures() {
    assert_eq!(delay(8, None, 0.5), Duration::from_secs(600));
    assert_eq!(delay(u32::MAX, None, 0.5), Duration::from_secs(600));
}

#[test]
fn a_retry_after_past_the_cap_still_wins() {
    let day = Duration::from_secs(86_400);
    assert_eq!(delay(40, Some(day), 0.5), day);
}

#[test]
fn the_system_random_keeps_the_delay_within_the_jitter() {
    for _ in 0..1_000 {
        let delay = delay(1, None, fastrand::f64());
        assert!(
            (Duration::from_secs(4)..=Duration::from_secs(6)).contains(&delay),
            "{delay:?}"
        );
    }
}
