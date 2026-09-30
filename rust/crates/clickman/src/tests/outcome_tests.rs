use crate::outcome::Outcome;

#[test]
fn every_success_is_delivered() {
    for status in [200, 201, 202, 204, 299] {
        assert_eq!(Outcome::of(status), Outcome::Delivered, "{status}");
    }
}

#[test]
fn only_malformed_too_large_and_unsupported_encoding_are_refused() {
    for status in [400, 413, 415] {
        assert_eq!(Outcome::of(status), Outcome::Refused, "{status}");
    }
    for status in [401, 402, 403, 404, 405, 408, 409, 411, 422, 429, 431] {
        assert_eq!(Outcome::of(status), Outcome::Retry, "{status}");
    }
}

#[test]
fn informational_redirect_server_and_missing_answers_retry() {
    for status in [0, 100, 199, 300, 302, 304, 500, 502, 504, 599, u16::MAX] {
        assert_eq!(Outcome::of(status), Outcome::Retry, "{status}");
    }
}
