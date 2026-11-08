//! C ABI for authenticated Spotify metadata services used by the Bopify macOS app.

mod artist;
mod error;
mod event;
mod ffi;
/// cbindgen:ignore
// Imports C symbols without exporting ABI types.
mod logging;
mod lyrics;
mod metadata;
mod radio;
mod services;
