/// What a response does to its batch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// The server has the events: the batch leaves the queue.
    Delivered,
    /// The server will never take the batch: it leaves the queue.
    Refused,
    /// The batch stays for another attempt after a delay.
    Retry,
}

impl Outcome {
    /// The outcome of a response status, 0 being no response at all (outcomes.json).
    pub(crate) fn of(status: u16) -> Self {
        match status {
            200..=299 => Self::Delivered,
            400 | 413 | 415 => Self::Refused,
            _ => Self::Retry,
        }
    }
}
