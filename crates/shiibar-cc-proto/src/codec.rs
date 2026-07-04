//! NDJSON line codec. Deliberately transport-agnostic (no tokio / std::net
//! types here): shiibar-ccd drives it over `tokio::net::UnixStream`,
//! shiibar-cc over `std::os::unix::net::UnixStream`.

use serde::Serialize;
use serde::de::DeserializeOwned;

/// Serialize `value` as one JSON line, newline-terminated.
pub fn encode_line<T: Serialize>(value: &T) -> serde_json::Result<String> {
    let mut s = serde_json::to_string(value)?;
    s.push('\n');
    Ok(s)
}

/// Parse one NDJSON line (trailing newline/CR tolerated).
pub fn decode_line<T: DeserializeOwned>(line: &str) -> serde_json::Result<T> {
    serde_json::from_str(line.trim_end_matches(['\n', '\r']))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::AckResponse;

    #[test]
    fn encode_appends_single_newline() {
        let line = encode_line(&AckResponse::default()).unwrap();
        assert_eq!(line, "{\"ok\":true}\n");
    }

    #[test]
    fn decode_tolerates_trailing_crlf() {
        let v: AckResponse = decode_line("{\"ok\":true}\r\n").unwrap();
        assert_eq!(v, AckResponse::default());
    }
}
