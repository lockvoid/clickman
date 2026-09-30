use regex::Regex;
use serde_json::{Map, Value};

pub const FILTERED: &str = "[FILTERED]";

pub const DEFAULT_FRAGMENTS: &[&str] = &[
    "passw",
    "email",
    "secret",
    "token",
    "_key",
    "crypt",
    "salt",
    "certificate",
    "otp",
    "ssn",
    "cvv",
    "cvc",
    "phone",
    "address",
    "first_name",
    "last_name",
    "full_name",
    "birth",
];

const EMAIL: &str = r"(?i)[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}";

const CARD_DIGITS: std::ops::RangeInclusive<usize> = 13..=19;
const PHONE_DIGITS: std::ops::RangeInclusive<usize> = 10..=15;

/// Removes personal data from flattened properties and context, as described in
/// docs/PROTOCOL.md: filtered keys and strings that carry an email, a card
/// number or an international phone number get [`FILTERED`].
pub struct Sanitizer {
    fragments: Vec<String>,
    email: Regex,
}

impl Sanitizer {
    pub fn new<S: AsRef<str>>(fragments: &[S]) -> Self {
        Self {
            fragments: fragments
                .iter()
                .map(|fragment| fragment.as_ref().to_lowercase())
                .collect(),
            email: Regex::new(EMAIL).expect("the email pattern compiles"),
        }
    }

    pub fn sanitize(&self, flat: &mut Map<String, Value>) {
        for (key, value) in flat.iter_mut() {
            let sensitive = self.filtered_key(key)
                || matches!(value, Value::String(text) if self.sensitive_text(text));

            if sensitive {
                *value = Value::String(FILTERED.to_owned());
            }
        }
    }

    fn filtered_key(&self, key: &str) -> bool {
        let last = key.rsplit('.').next().unwrap_or(key).to_lowercase();

        self.fragments
            .iter()
            .any(|fragment| last.contains(fragment.as_str()))
    }

    fn sensitive_text(&self, text: &str) -> bool {
        self.email.is_match(text) || contains_card(text) || contains_phone(text)
    }
}

impl Default for Sanitizer {
    fn default() -> Self {
        Self::new(DEFAULT_FRAGMENTS)
    }
}

fn contains_card(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();

    (0..chars.len()).any(|start| {
        chars[start].is_ascii_digit()
            && detached_before(&chars, start)
            && card_digits(&chars, start).is_some_and(|(digits, end)| {
                detached_after(&chars, end)
                    && CARD_DIGITS.contains(&digits.len())
                    && ('2'..='6').contains(&digits[0])
                    && luhn(&digits)
            })
    })
}

/// Digits from `start`, grouped by single spaces or dashes; returns the digits
/// and the index just past the last one.
fn card_digits(chars: &[char], start: usize) -> Option<(Vec<char>, usize)> {
    let mut digits = Vec::new();
    let mut index = start;

    while index < chars.len() {
        if chars[index].is_ascii_digit() {
            digits.push(chars[index]);
            index += 1;
        } else if matches!(chars[index], ' ' | '-')
            && chars.get(index + 1).is_some_and(char::is_ascii_digit)
        {
            index += 1;
        } else {
            break;
        }
    }

    (!digits.is_empty()).then_some((digits, index))
}

fn luhn(digits: &[char]) -> bool {
    let sum: u32 = digits
        .iter()
        .rev()
        .enumerate()
        .map(|(position, digit)| {
            let value = digit.to_digit(10).unwrap_or(0);
            if position % 2 == 1 {
                let doubled = value * 2;
                if doubled > 9 { doubled - 9 } else { doubled }
            } else {
                value
            }
        })
        .sum();

    sum.is_multiple_of(10)
}

fn contains_phone(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();

    (0..chars.len()).any(|start| {
        chars[start] == '+'
            && detached_before(&chars, start)
            && chars.get(start + 1).is_some_and(char::is_ascii_digit)
            && phone_end(&chars, start + 1).is_some_and(|(digits, end)| {
                PHONE_DIGITS.contains(&digits) && detached_after(&chars, end)
            })
    })
}

/// Counts digits from `start` across spaces, dashes, dots and parentheses;
/// returns the count and the index just past the last digit.
fn phone_end(chars: &[char], start: usize) -> Option<(usize, usize)> {
    let mut digits = 0;
    let mut end = start;

    for (index, &char) in chars.iter().enumerate().skip(start) {
        if char.is_ascii_digit() {
            digits += 1;
            end = index + 1;
        } else if !matches!(char, ' ' | '-' | '.' | '(' | ')') {
            break;
        }
    }

    (digits > 0).then_some((digits, end))
}

fn detached_before(chars: &[char], start: usize) -> bool {
    start == 0 || !chars[start - 1].is_alphanumeric()
}

fn detached_after(chars: &[char], end: usize) -> bool {
    chars.get(end).is_none_or(|char| !char.is_alphanumeric())
}
