use crate::api::error::RhttpError;
use rustls::client::EchConfig;
use rustls::crypto::aws_lc_rs::{default_provider, hpke::ALL_SUPPORTED_SUITES};
use rustls::pki_types::EchConfigListBytes;

/// A real ECH configuration makes rustls abort on rejection; never retry with
/// cleartext SNI. with_ech also restricts the connection to TLS 1.3.
pub fn config(bytes: &[u8]) -> Result<rustls::ClientConfig, RhttpError> {
    let error = |e: rustls::Error| RhttpError::RhttpUnknownError(format!("ECH: {e}"));
    let ech =
        EchConfig::new(EchConfigListBytes::from(bytes), ALL_SUPPORTED_SUITES).map_err(error)?;
    Ok(
        rustls::ClientConfig::builder_with_provider(default_provider().into())
            .with_ech(ech.into())
            .map_err(error)?
            .with_root_certificates(rustls::RootCertStore {
                roots: webpki_roots::TLS_SERVER_ROOTS.into(),
            })
            .with_no_client_auth(),
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn rejects_empty_and_malformed_configs() {
        for bytes in [&[][..], &[0, 0], &[0, 5, 1, 2]] {
            assert!(super::config(bytes).is_err());
        }
    }
}
