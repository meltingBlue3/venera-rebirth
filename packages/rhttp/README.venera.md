# Venera ECH patch to rhttp 0.15.1

Base: the published [rhttp 0.15.1](https://pub.dev/packages/rhttp/versions/0.15.1)
archive (SHA-256 `b111638045b730f825a85cb045017b5bd3dfb47b38e98eb293b0519ee6050f2e`).
Upstream MIT license is retained in [LICENSE](LICENSE); bundled Cargokit retains
its own [license](cargokit/LICENSE). Examples and upstream tests are omitted.
Trailing whitespace in vendored and generated files is normalized.

The only network API extension is `TlsSettings.echConfigList` (wire bytes).
When supplied, `rust/src/utils/ech.rs` builds a rustls 0.23.35 TLS 1.3
configuration with AWS-LC HPKE and WebPKI roots. ECH rejection fails the
handshake; neither Dart nor Rust retries with cleartext SNI. Certificate
verification and SNI must be enabled. This mode is intended for the PicACG
policy's default trust roots, without custom certificates or client identity.
When omitted, the original rhttp TLS configuration path is used.

`Cargo.lock` records the added AWS-LC dependencies. Upstream Cargokit reads
the project Rust toolchain when discovered (otherwise stable) and supplies `--cfg reqwest_unstable` for upstream
HTTP/3. Windows builds need Visual Studio C++ tools and CMake; Android uses
the project's NDK. Do not reuse an upstream rhttp binary with this bridge ABI.

To regenerate the checked-in bridge (requires flutter_rust_bridge_codegen
2.11.1 and cargo-expand), run in this directory with stable Rust selected and
`RUSTFLAGS="--cfg reqwest_unstable"`:

```sh
flutter_rust_bridge_codegen generate --no-build-runner --no-deps-check --no-dart-fix --no-auto-upgrade-dependency
```

Run Rust tests with the same RUSTFLAGS:

```sh
cargo +stable test --manifest-path rust/Cargo.toml --locked --lib
```

This local package is selected explicitly in the root pubspec, so source and
native binaries are rebuilt together on every supported native platform.
