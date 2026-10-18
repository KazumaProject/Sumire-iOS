#include "SumireZip.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <zlib.h>

static int write_all(int fd, const uint8_t *bytes, size_t count) {
    if (fd < 0) return 1; // Validation-only path: no output is retained.
    while (count) {
        ssize_t n = write(fd, bytes, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        bytes += n; count -= (size_t)n;
    }
    return 1;
}
static int process(const uint8_t *input, size_t length, uint16_t method,
                   uint64_t expected_length, uint32_t expected_crc, int fd) {
    if ((!input && length) || (method != 0 && method != 8)) return 1;
    int result = 0;
    uLong crc = crc32(0, Z_NULL, 0);
    uint64_t written = 0;
    if (method == 0) {
        if (length != expected_length) result = 3;
        for (size_t offset = 0; !result && offset < length;) {
            uInt n = (uInt)((length - offset) > 65536 ? 65536 : length - offset);
            crc = crc32(crc, input + offset, n);
            if (!write_all(fd, input + offset, n)) result = 4;
            offset += n;
        }
        written = length;
    } else {
        z_stream stream = {0};
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) result = 5;
        else {
            uint8_t output[65536];
            size_t supplied = 0;
            int status = Z_OK;
            while (!result && status != Z_STREAM_END) {
                if (!stream.avail_in && supplied < length) {
                    uInt n = (uInt)((length - supplied) > 65536 ? 65536 : length - supplied);
                    stream.next_in = (Bytef *)(input + supplied);
                    stream.avail_in = n; supplied += n;
                }
                uInt before = stream.avail_in;
                stream.next_out = output; stream.avail_out = sizeof(output);
                status = inflate(&stream, Z_NO_FLUSH);
                size_t n = sizeof(output) - stream.avail_out;
                if (n > expected_length - written) { result = 3; break; }
                written += n;
                crc = crc32(crc, output, (uInt)n);
                if (!write_all(fd, output, n)) result = 4;
                if ((status != Z_OK && status != Z_STREAM_END) ||
                    (status == Z_OK && !n && before == stream.avail_in)) result = 5;
            }
            if (!result && (written != expected_length || supplied - stream.avail_in != length)) result = 3;
            inflateEnd(&stream);
        }
    }
    if (!result && (written != expected_length || (uint32_t)crc != expected_crc)) result = 6;
    return result;
}
int sumire_zip_validate(const uint8_t *input, size_t length, uint16_t method,
                        uint64_t expected_length, uint32_t expected_crc) {
    return process(input, length, method, expected_length, expected_crc, -1);
}
int sumire_zip_extract(const uint8_t *input, size_t length, uint16_t method,
                       uint64_t expected_length, uint32_t expected_crc,
                       const char *destination) {
    if ((!input && length) || !destination || (method != 0 && method != 8)) return 1;
    int fd = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return 2;
    int result = process(input, length, method, expected_length, expected_crc, fd);
    if (!result && fsync(fd) != 0) result = 4;
    if (close(fd) != 0 && !result) result = 4;
    if (result) unlink(destination);
    return result;
}
