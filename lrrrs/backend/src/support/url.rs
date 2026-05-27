//! URL validation for the download_url task enqueue path.
//!
//! Validates that a caller-supplied URL is safe to fetch server-side.
//! Rejects non-HTTP/S schemes and RFC-1918 / loopback / link-local / unspecified
//! addresses to prevent SSRF.
//!
//! TODO: revalidate after HTTP redirects when the task HTTP fetch is implemented.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, ToSocketAddrs};

#[derive(Debug)]
pub enum DownloadUrlError {
    Parse(String),
    BadScheme(String),
    NoHost,
    DnsFailure(String),
    BlockedAddress(String),
}

impl std::fmt::Display for DownloadUrlError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Parse(e) => write!(f, "invalid URL: {e}"),
            Self::BadScheme(s) => write!(f, "scheme not allowed: {s}"),
            Self::NoHost => write!(f, "URL has no host"),
            Self::DnsFailure(e) => write!(f, "DNS resolution failed: {e}"),
            Self::BlockedAddress(a) => write!(f, "blocked address: {a}"),
        }
    }
}

impl std::error::Error for DownloadUrlError {}

impl From<DownloadUrlError> for crate::error::PendingApiError {
    fn from(e: DownloadUrlError) -> Self {
        crate::error::PendingApiError::bad_request(e.to_string())
    }
}

fn is_blocked(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => is_blocked_v4(v4),
        IpAddr::V6(v6) => is_blocked_v6(v6),
    }
}

fn is_blocked_v4(ip: Ipv4Addr) -> bool {
    let o = ip.octets();
    // 127.0.0.0/8 — loopback
    if o[0] == 127 {
        return true;
    }
    // 10.0.0.0/8 — RFC-1918
    if o[0] == 10 {
        return true;
    }
    // 172.16.0.0/12 — RFC-1918
    if o[0] == 172 && (o[1] & 0xf0) == 16 {
        return true;
    }
    // 192.168.0.0/16 — RFC-1918
    if o[0] == 192 && o[1] == 168 {
        return true;
    }
    // 169.254.0.0/16 — link-local
    if o[0] == 169 && o[1] == 254 {
        return true;
    }
    // 0.0.0.0 — unspecified
    if ip == Ipv4Addr::UNSPECIFIED {
        return true;
    }
    false
}

fn is_blocked_v6(ip: Ipv6Addr) -> bool {
    // ::1 — loopback
    if ip == Ipv6Addr::LOCALHOST {
        return true;
    }
    // :: — unspecified
    if ip == Ipv6Addr::UNSPECIFIED {
        return true;
    }
    let segments = ip.segments();
    // fe80::/10 — link-local
    if (segments[0] & 0xffc0) == 0xfe80 {
        return true;
    }
    // fc00::/7 — unique-local
    if (segments[0] & 0xfe00) == 0xfc00 {
        return true;
    }
    false
}

/// Validates a URL for safe server-side fetching.
///
/// Checks:
/// 1. URL must parse successfully.
/// 2. Scheme must be `http` or `https`.
/// 3. Host must be present.
/// 4. Host must resolve via DNS.
/// 5. All resolved addresses must not be private/loopback/link-local/unspecified.
pub fn validate_download_url(raw: &str) -> Result<(), DownloadUrlError> {
    let parsed = url::Url::parse(raw).map_err(|e| DownloadUrlError::Parse(e.to_string()))?;

    let scheme = parsed.scheme();
    if scheme != "http" && scheme != "https" {
        return Err(DownloadUrlError::BadScheme(scheme.to_string()));
    }

    let host = parsed.host_str().ok_or(DownloadUrlError::NoHost)?;
    let port = parsed.port_or_known_default().unwrap_or(80);

    let addrs: Vec<IpAddr> = format!("{host}:{port}")
        .to_socket_addrs()
        .map_err(|e| DownloadUrlError::DnsFailure(e.to_string()))?
        .map(|sa| sa.ip())
        .collect();

    for addr in addrs {
        if is_blocked(addr) {
            return Err(DownloadUrlError::BlockedAddress(addr.to_string()));
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_file_scheme() {
        let err = validate_download_url("file:///etc/passwd").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BadScheme(_)));
    }

    #[test]
    fn rejects_ftp_scheme() {
        let err = validate_download_url("ftp://example.com/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BadScheme(_)));
    }

    #[test]
    fn rejects_loopback_v4() {
        let err = validate_download_url("http://127.0.0.1/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_loopback_localhost() {
        // localhost resolves to 127.0.0.1 or ::1; both are blocked.
        let err = validate_download_url("http://localhost/file.zip").unwrap_err();
        assert!(
            matches!(err, DownloadUrlError::BlockedAddress(_) | DownloadUrlError::DnsFailure(_)),
            "expected blocked or dns failure, got: {err}"
        );
    }

    #[test]
    fn rejects_rfc1918_10() {
        let err = validate_download_url("http://10.0.0.1/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_rfc1918_172_16() {
        let err = validate_download_url("http://172.16.0.1/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_rfc1918_192_168() {
        let err = validate_download_url("http://192.168.1.1/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_link_local_v4() {
        let err = validate_download_url("http://169.254.169.254/latest/meta-data/").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_loopback_v6() {
        let err = validate_download_url("http://[::1]/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_link_local_v6() {
        let err = validate_download_url("http://[fe80::1]/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_unique_local_v6() {
        let err = validate_download_url("http://[fc00::1]/file.zip").unwrap_err();
        assert!(matches!(err, DownloadUrlError::BlockedAddress(_)));
    }

    #[test]
    fn rejects_malformed_url() {
        let err = validate_download_url("not a url at all").unwrap_err();
        assert!(matches!(err, DownloadUrlError::Parse(_)));
    }

    /// Accept case: https://example.com resolves to a public IP.
    /// Requires network; skipped in offline environments.
    #[test]
    fn accepts_public_https_url() {
        // example.com resolves to 93.184.216.34, which is public.
        match validate_download_url("https://example.com/foo.zip") {
            Ok(()) => {}
            Err(DownloadUrlError::DnsFailure(_)) => {
                // No network in CI; treat as pass.
            }
            Err(e) => panic!("unexpected error for public URL: {e}"),
        }
    }
}
