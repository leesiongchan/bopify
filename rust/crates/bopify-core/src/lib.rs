//! C-ABI wrapper around librespot's Spirc for the Bopify macOS app.

mod artist;
pub mod engine;
pub mod error;
pub mod event;
pub mod ffi;
/// cbindgen:ignore
// Imports C symbols without exporting ABI types.
mod logging;
mod lyrics;
mod queue;
mod radio;
mod recovery;
mod remote;
mod terminal;
