// Compiles the one C function that lets Rust reach os_log. See
// oslog_shim.c for why it cannot be done in Rust.
fn main() {
    println!("cargo::rerun-if-changed=oslog_shim.c");
    cc::Build::new()
        .file("oslog_shim.c")
        .compile("bopify_oslog_shim");
}
