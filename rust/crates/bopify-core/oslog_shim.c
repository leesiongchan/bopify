/*
 * Do not delete this file: it is not incidental C, it is the only way to
 * reach os_log from Rust.
 *
 * os_log_with_type is a preprocessor macro, not a linkable symbol -- it
 * expands to a compiler intrinsic that builds the format buffer at the call
 * site. Rust cannot call a macro, and open-coding the _os_log_impl buffer
 * layout would depend on undocumented ABI. One C function solves it.
 *
 * os_log_create, by contrast, is OS_EXPORT, so Rust declares that one
 * directly and it is deliberately absent here.
 */
#include <os/log.h>
#include <stdint.h>

void bopify_os_log_emit(void *log, uint8_t type, const char *message) {
    /* %{public}s: the message is already redacted on the Rust side, and a
     * log that prints <private> for every line is of no use when debugging. */
    os_log_with_type((os_log_t)log, (os_log_type_t)type, "%{public}s", message);
}
