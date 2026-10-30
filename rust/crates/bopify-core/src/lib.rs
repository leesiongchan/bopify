//! C-ABI wrapper around librespot's Spirc for the Bopify macOS app.

mod artist;
mod engine;
mod error;
mod event;
mod ffi;
/// cbindgen:ignore
// Imports C symbols without exporting ABI types.
mod logging;
mod lyrics;
mod queue;
mod radio;
mod recovery;
mod remote;
mod terminal;
