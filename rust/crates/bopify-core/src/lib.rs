//! C-ABI wrapper around librespot's Spirc for the Bopify macOS app.

pub mod engine;
pub mod error;
pub mod event;
pub mod ffi;
/// cbindgen:ignore
/// Nothing in here is part of the published C ABI -- it only *imports* C
/// symbols -- so the header generator must skip the whole module.
mod logging;
mod queue;
mod radio;
mod remote;
mod terminal;
mod recovery;
