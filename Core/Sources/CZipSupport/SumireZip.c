#include "SumireZip.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
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
static void store_u32(uint8_t *bytes, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) bytes[i] = (uint8_t)(value >> (i * 8));
}
static void store_u64(uint8_t *bytes, uint64_t value) {
    for (unsigned i = 0; i < 8; ++i) bytes[i] = (uint8_t)(value >> (i * 8));
}
static uint32_t section_crc(const uint8_t *bytes, uint64_t length) {
    uLong crc = crc32(0, Z_NULL, 0);
    uint64_t offset = 0;
    while (offset < length) {
        uInt count = (uInt)((length - offset) > 65536 ? 65536 : length - offset);
        crc = crc32(crc, bytes + offset, count);
        offset += count;
    }
    return (uint32_t)crc;
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

int sumire_dictionary_write(const char *destination, uint32_t kind,
                            uint32_t dimension, uint32_t section_count,
                            const uint8_t *const *sections,
                            const uint64_t *section_lengths) {
    if (!destination || !sections || !section_lengths || section_count > 16) return 1;
    uint32_t required_count = kind == 1 ? 10 : kind == 2 ? 7 : kind == 3 ? 2 : 0;
    if (!required_count || section_count != required_count ||
        ((kind == 1 || kind == 3) && dimension != 0) ||
        (kind == 2 && dimension == 0)) return 1;

    const uint64_t max_file_size = UINT64_C(1024) * 1024 * 1024;
    uint64_t offset = UINT64_C(24) + UINT64_C(24) * section_count;
    uint32_t *crcs = (uint32_t *)calloc(section_count, sizeof(uint32_t));
    if (!crcs) return 2;
    int result = 0, fd = -1, created = 0;
    for (uint32_t i = 0; i < section_count; ++i) {
        uint64_t length = section_lengths[i];
        if ((!sections[i] && length) || offset > UINT64_MAX - 7) { result = 1; goto done; }
        offset = (offset + 7) & ~UINT64_C(7);
        if (length > max_file_size - offset) { result = 1; goto done; }
        crcs[i] = section_crc(sections[i], length);
        offset += length;
    }
    if (offset > max_file_size) { result = 1; goto done; }

    fd = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { result = 3; goto done; }
    created = 1;

    uint8_t header[24] = {0};
    memcpy(header, "SUMIRE01", 8);
    store_u32(header + 8, 1);
    store_u32(header + 12, kind);
    store_u32(header + 16, section_count);
    store_u32(header + 20, dimension);
    if (!write_all(fd, header, sizeof(header))) { result = 4; goto done; }

    uint64_t descriptor_start = UINT64_C(24) + UINT64_C(24) * section_count;
    uint64_t next_offset = descriptor_start;
    for (uint32_t i = 0; i < section_count; ++i) {
        next_offset = (next_offset + 7) & ~UINT64_C(7);
        uint8_t descriptor[24] = {0};
        store_u64(descriptor, next_offset);
        store_u64(descriptor + 8, section_lengths[i]);
        store_u32(descriptor + 16, crcs[i]);
        if (!write_all(fd, descriptor, sizeof(descriptor))) { result = 4; goto done; }
        next_offset += section_lengths[i];
    }

    offset = descriptor_start;
    static const uint8_t zeros[8] = {0};
    for (uint32_t i = 0; i < section_count; ++i) {
        uint64_t aligned = (offset + 7) & ~UINT64_C(7);
        size_t padding = (size_t)(aligned - offset);
        if (padding && !write_all(fd, zeros, padding)) { result = 4; goto done; }
        if (section_lengths[i] > SIZE_MAX ||
            !write_all(fd, sections[i], (size_t)section_lengths[i])) { result = 4; goto done; }
        offset = aligned + section_lengths[i];
    }
    if (fsync(fd) != 0) { result = 4; goto done; }

done:
    free(crcs);
    if (fd >= 0 && close(fd) != 0 && !result) result = 4;
    if (result && created) unlink(destination);
    return result;
}
