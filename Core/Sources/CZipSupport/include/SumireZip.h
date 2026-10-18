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
#endif
