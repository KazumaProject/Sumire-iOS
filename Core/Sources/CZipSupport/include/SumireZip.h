#ifndef SUMIRE_ZIP_H
#define SUMIRE_ZIP_H
#include <stddef.h>
#include <stdint.h>
// Creates destination exclusively. On failure, removes only the file created
// by this call. Input must remain readable for the duration of the call.
int sumire_zip_extract(const uint8_t *input, size_t length, uint16_t method,
                       uint64_t expected_length, uint32_t expected_crc,
                       const char *destination);
int sumire_zip_validate(const uint8_t *input, size_t length, uint16_t method,
                        uint64_t expected_length, uint32_t expected_crc);
// Writes a validated SUMIRE01 container to a new file. The destination is
// created with O_EXCL|O_NOFOLLOW and removed only if this call created it and
// a later write or sync step fails. Section input buffers remain caller-owned.
int sumire_dictionary_write(const char *destination, uint32_t kind,
                            uint32_t dimension, uint32_t section_count,
                            const uint8_t *const *sections,
                            const uint64_t *section_lengths);
#endif
