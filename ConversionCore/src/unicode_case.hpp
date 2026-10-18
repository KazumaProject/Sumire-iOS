#pragma once
#include <string>
namespace sumire {
// Locale-independent Unicode lowercase. Does not normalize or remove accents.
// NFKC compatibility normalization; locale-independent.
std::u16string unicode_nfkc(const std::u16string &value);
std::u16string unicode_lower(const std::u16string &value);
std::u16string unicode_upper(const std::u16string &value);
bool unicode_is_upper(char16_t value);
bool unicode_is_letter(char16_t value);
char16_t unicode_simple_upper(char16_t value);
char16_t unicode_simple_lower(char16_t value);
}
