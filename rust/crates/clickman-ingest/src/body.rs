use std::borrow::Cow;
use std::io::Read;

use flate2::read::GzDecoder;

pub const MAX_WIRE_BYTES: usize = 1024 * 1024;
pub const MAX_DECOMPRESSED_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum BodyError {
    TooLarge,
    UnsupportedEncoding,
    Malformed(String),
}

/// Undoes the `Content-Encoding` of a batch, refusing anything that expands
/// past [`MAX_DECOMPRESSED_BYTES`].
pub fn decode<'a>(encoding: Option<&str>, bytes: &'a [u8]) -> Result<Cow<'a, [u8]>, BodyError> {
    match encoding.map(|encoding| encoding.trim().to_ascii_lowercase()) {
        None => Ok(Cow::Borrowed(bytes)),
        Some(encoding) if encoding.is_empty() || encoding == "identity" => Ok(Cow::Borrowed(bytes)),
        Some(encoding) if encoding == "gzip" || encoding == "x-gzip" => {
            let mut decoded = Vec::new();
            GzDecoder::new(bytes)
                .take(MAX_DECOMPRESSED_BYTES as u64 + 1)
                .read_to_end(&mut decoded)
                .map_err(|error| {
                    BodyError::Malformed(format!("the gzip body is broken: {error}"))
                })?;

            if decoded.len() > MAX_DECOMPRESSED_BYTES {
                Err(BodyError::TooLarge)
            } else {
                Ok(Cow::Owned(decoded))
            }
        }
        Some(_) => Err(BodyError::UnsupportedEncoding),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use flate2::Compression;
    use flate2::write::GzEncoder;

    use super::*;

    fn gzip(bytes: &[u8]) -> Vec<u8> {
        let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
        encoder.write_all(bytes).unwrap();
        encoder.finish().unwrap()
    }

    #[test]
    fn identity_passes_through() {
        assert_eq!(decode(None, b"{}").unwrap().as_ref(), b"{}");
        assert_eq!(decode(Some("identity"), b"{}").unwrap().as_ref(), b"{}");
    }

    #[test]
    fn gzip_is_undone() {
        assert_eq!(decode(Some("gzip"), &gzip(b"{}")).unwrap().as_ref(), b"{}");
        assert_eq!(
            decode(Some(" GZIP "), &gzip(b"{}")).unwrap().as_ref(),
            b"{}"
        );
    }

    #[test]
    fn exactly_the_limit_is_accepted_and_one_byte_more_is_not() {
        let at_limit = gzip(&vec![b' '; MAX_DECOMPRESSED_BYTES]);
        let over = gzip(&vec![b' '; MAX_DECOMPRESSED_BYTES + 1]);

        assert_eq!(
            decode(Some("gzip"), &at_limit).unwrap().len(),
            MAX_DECOMPRESSED_BYTES
        );
        assert_eq!(decode(Some("gzip"), &over), Err(BodyError::TooLarge));
    }

    #[test]
    fn a_broken_gzip_body_is_malformed() {
        assert!(matches!(
            decode(Some("gzip"), b"not gzip"),
            Err(BodyError::Malformed(_))
        ));
    }

    #[test]
    fn other_encodings_are_unsupported() {
        assert_eq!(
            decode(Some("br"), b"{}"),
            Err(BodyError::UnsupportedEncoding)
        );
    }
}
