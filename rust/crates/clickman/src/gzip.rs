use std::io::{self, Write};

use flate2::Compression;
use flate2::write::GzEncoder;

pub(crate) fn compress(data: &[u8]) -> io::Result<Vec<u8>> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(data)?;
    encoder.finish()
}
