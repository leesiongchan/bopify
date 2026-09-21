/*
 * Do not delete this file: it is not incidental C, it is the only way to
 * reach os_log from Rust.
 *
 * os_log_with_type is a preprocessor macro, not a linkable symbol -- it
 * expands to a compiler intrinsic that builds the format buffer at the call
 * site, and the format string has to be a literal there. Rust cannot call a
 * macro, and open-coding the _os_log_impl buffer layout would depend on
 * undocumented ABI. Two C functions solve it.
 *
 * os_log_create, by contrast, is OS_EXPORT, so Rust declares that one
 * directly and it is deliberately absent here.
 *
 * Two functions rather than one with a flag because the format string
 * cannot be a variable: each qualifier needs its own literal call site.
 */
#include <os/log.h>
#include <stdint.h>

/* For lines this project writes. We control and have audited them, and they
 * carry no token and no Spotify user id. */
void bopify_os_log_emit_public(void *log, uint8_t type, const char *message) {
    os_log_with_type((os_log_t)log, (os_log_type_t)type, "%{public}s", message);
}

/* For lines a dependency writes. We cannot audit what a future librespot
 * decides to interpolate, so these are redacted in collected logs and in
 * sysdiagnose, whatever level they are enabled at. */
void bopify_os_log_emit_private(void *log, uint8_t type, const char *message) {
    os_log_with_type((os_log_t)log, (os_log_type_t)type, "%{private}s", message);
}
