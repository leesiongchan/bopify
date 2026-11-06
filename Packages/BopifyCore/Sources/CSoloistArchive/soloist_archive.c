#include "soloist_archive.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

/* macOS exports this stable libarchive 3 ABI but omits its headers from the SDK.
 * Declarations follow libarchive's public archive.h/archive_entry.h API. */
struct archive;
struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_gzip(struct archive *);
extern int archive_read_support_format_tar(struct archive *);
extern int archive_read_open_fd(struct archive *, int, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern int64_t archive_filter_bytes(struct archive *, int);
extern int archive_entry_xattr_reset(struct archive_entry *);
extern int archive_entry_xattr_next(struct archive_entry *, const char **, const void **, size_t *);

static const int64_t expanded_limit = 160LL * 1024 * 1024;

static int safe_path(const char *path) {
    if (!path || !*path || *path == '/' || strlen(path) > 4096 || strchr(path, '\\')) return 0;
    const char *part = path;
    while (*part) {
        const char *end = strchr(part, '/');
        size_t length = end ? (size_t)(end - part) : strlen(part);
        if (!length || (length == 2 && !strncmp(part, "..", 2))) return 0;
        if (!end) break;
        part = end + 1;
    }
    return 1;
}

int bopify_soloist_extract(const char *archive_path, const char *destination) {
    int result = -1, output = -1;
    int source = open(archive_path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int directory = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    struct archive *reader = archive_read_new();
    struct stat info;
    if (source < 0 || directory < 0 || !reader) goto done;
    if (fstat(source, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > 80LL * 1024 * 1024) goto done;
    if (fstat(directory, &info) || !S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 0777) != 0700) goto done;
    char quarantine[4096];
    ssize_t quarantine_size = fgetxattr(source, "com.apple.quarantine", quarantine, sizeof quarantine, 0, 0);
    if (quarantine_size < 0) {
        if (errno != ENOATTR) goto done;
        quarantine_size = 0;
    }
    if (archive_read_support_filter_gzip(reader) || archive_read_support_format_tar(reader) ||
        archive_read_open_fd(reader, source, 65536)) goto done;
    unsigned seen = 0, entries = 0;
    int64_t declared_total = 0, actual_total = 0;
    struct archive_entry *entry;
    int status;
    while ((status = archive_read_next_header(reader, &entry)) == 0) {
        if (++entries > 64 || archive_filter_bytes(reader, 0) > expanded_limit) goto done;
        const char *path = archive_entry_pathname(entry);
        mode_t type = archive_entry_filetype(entry);
        if (!safe_path(path) || archive_entry_symlink(entry) || archive_entry_hardlink(entry) ||
            (type != S_IFREG && type != S_IFDIR)) goto done;
        int64_t size = archive_entry_size(entry);
        if (size < 0 || size > expanded_limit - declared_total) goto done;
        declared_total += size;
        const char *name = strrchr(path, '/');
        name = name ? name + 1 : path;
        unsigned bit = !strcmp(name, "soloist") ? 1 : !strcmp(name, "THIRD_PARTY_LICENSES.txt") ? 2 : !strcmp(name, "CHANGELOG.md") ? 4 : 0;
        if (bit && type != S_IFREG) goto done;
        if (bit) {
            if (seen & bit) goto done;
            seen |= bit;
            output = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, bit == 1 ? 0700 : 0600);
            if (output < 0) goto done;
        }
        char buffer[65536];
        int64_t copied = 0;
        ssize_t count;
        while ((count = archive_read_data(reader, buffer, sizeof buffer)) > 0) {
            if (count > size - copied || count > expanded_limit - actual_total) goto done;
            copied += count;
            actual_total += count;
            if (archive_filter_bytes(reader, 0) > expanded_limit) goto done;
            if (output >= 0) {
                ssize_t offset = 0;
                while (offset < count) {
                    ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) goto done;
                    offset += written;
                }
            }
        }
        if (count < 0 || copied != size) goto done;
        if (output >= 0) {
            const void *tag = quarantine;
            size_t tag_size = (size_t)quarantine_size;
            if (!tag_size) {
                int attributes = archive_entry_xattr_reset(entry);
                if (attributes < 0 || attributes > 64) goto done;
                for (int index = 0; index < attributes; ++index) {
                    const char *attribute;
                    const void *value;
                    size_t length;
                    if (archive_entry_xattr_next(entry, &attribute, &value, &length)) goto done;
                    if (!strcmp(attribute, "com.apple.quarantine")) {
                        if (!length || length > sizeof quarantine) goto done;
                        tag = value;
                        tag_size = length;
                    }
                }
            }
            if (tag_size && fsetxattr(output, "com.apple.quarantine", tag, tag_size, 0, 0)) goto done;
            if (fsync(output)) goto done;
            close(output);
            output = -1;
        }
    }
    if (status == 1 && (seen & 1) && archive_filter_bytes(reader, 0) <= expanded_limit) result = 0;
done:
    if (output >= 0) close(output);
    if (reader) archive_read_free(reader);
    if (source >= 0) close(source);
    if (directory >= 0) close(directory);
    return result;
}
