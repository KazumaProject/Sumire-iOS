#include "unicode_case.hpp"
#include <algorithm>
#include <stdexcept>
#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <memory>
#else
#include <unicode/ustring.h>
#include <unicode/uchar.h>
#include <unicode/unorm2.h>
#endif

namespace sumire {
static std::u16string transform_case(const std::u16string &value, bool uppercase, bool title = false);
bool unicode_is_upper(char16_t value) {
  if (value < 128) return value >= u'A' && value <= u'Z';
#ifdef __APPLE__
  if (CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetCapitalizedLetter), value)) return false;
  return CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetUppercaseLetter), value)
      || (unicode_simple_upper(value) == value && unicode_simple_lower(value) != value);
#else
  return u_isUUppercase(value);
#endif
}
bool unicode_is_letter(char16_t value) {
  if (value < 128) return (value >= u'A' && value <= u'Z') || (value >= u'a' && value <= u'z');
#ifdef __APPLE__
  return CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetLetter), value)
      && !CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetNonBase), value);
#else
  return u_isalpha(value);
#endif
}
bool unicode_is_digit(char16_t value) {
  if (value < 128) return value >= u'0' && value <= u'9';
#ifdef __APPLE__
  return CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetDecimalDigit), value);
#else
  return u_isdigit(value);
#endif
}
char16_t unicode_simple_upper(char16_t value) {
  if (value < 128) return value >= u'a' && value <= u'z' ? value - (u'a' - u'A') : value;
#ifdef __APPLE__
  auto result = unicode_upper(std::u16string(1, value));
  if (result.size() == 1) return result[0];
  // Greek letters with prosgegrammeni have an expanding full uppercase but
  // a one-unit simple uppercase represented by their titlecase form.
  result = transform_case(std::u16string(1, value), true, true);
  return result.size() == 1 ? result[0] : value;
#else
  auto result = u_toupper(value);
  return result <= 0xffff ? char16_t(result) : value;
#endif
}
char16_t unicode_simple_lower(char16_t value) {
  if (value < 128) return value >= u'A' && value <= u'Z' ? value + (u'a' - u'A') : value;
#ifdef __APPLE__
  if (value == 0x0130) return u'i'; // Simple mapping differs from full i + dot.
  auto result = unicode_lower(std::u16string(1, value));
  return result.size() == 1 ? result[0] : value;
#else
  auto result = u_tolower(value);
  return result <= 0xffff ? char16_t(result) : value;
#endif
}
static std::u16string transform_case(const std::u16string &value, bool uppercase, bool title) {
  if (std::all_of(value.begin(), value.end(), [](char16_t c) { return c < 128; })) {
    auto result = value;
    for (auto &c : result) {
      if (uppercase && c >= u'a' && c <= u'z') c -= u'a' - u'A';
      else if (!uppercase && c >= u'A' && c <= u'Z') c += u'a' - u'A';
    }
    return result;
  }
#ifdef __APPLE__
  auto release = [](auto p) { if (p) CFRelease(p); };
  std::unique_ptr<__CFString, decltype(release)> text(
      CFStringCreateMutable(kCFAllocatorDefault, 0), release);
  if (!text) throw std::bad_alloc();
  CFStringAppendCharacters(text.get(), reinterpret_cast<const UniChar *>(value.data()), value.size());
  // Empty locale identifier selects root Unicode casing, not the user's locale.
  std::unique_ptr<const __CFLocale, decltype(release)> locale(
      CFLocaleCreate(kCFAllocatorDefault, CFSTR("")), release);
  if (!locale) throw std::bad_alloc();
  if (title) CFStringCapitalize(text.get(), locale.get());
  else if (uppercase) CFStringUppercase(text.get(), locale.get());
  else CFStringLowercase(text.get(), locale.get());
  std::u16string result(CFStringGetLength(text.get()), u'\0');
  CFStringGetCharacters(text.get(), CFRangeMake(0, result.size()), reinterpret_cast<UniChar *>(result.data()));
  return result;
#else
  UErrorCode status = U_ZERO_ERROR;
  auto transform = uppercase ? u_strToUpper : u_strToLower;
  auto length = transform(nullptr, 0, reinterpret_cast<const UChar *>(value.data()), value.size(), "", &status);
  if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status)) throw std::runtime_error("Unicode case conversion failed");
  status = U_ZERO_ERROR;
  std::u16string result(length, u'\0');
  transform(reinterpret_cast<UChar *>(result.data()), length, reinterpret_cast<const UChar *>(value.data()), value.size(), "", &status);
  if (U_FAILURE(status)) throw std::runtime_error("Unicode case conversion failed");
  return result;
#endif
}
std::u16string unicode_nfkc(const std::u16string &value) {
  if (std::all_of(value.begin(), value.end(), [](char16_t c) { return c < 128; })) return value;
#ifdef __APPLE__
  auto release = [](auto p) { if (p) CFRelease(p); };
  std::unique_ptr<__CFString, decltype(release)> text(
      CFStringCreateMutable(kCFAllocatorDefault, 0), release);
  if (!text) throw std::bad_alloc();
  CFStringAppendCharacters(text.get(), reinterpret_cast<const UniChar *>(value.data()), value.size());
  CFStringNormalize(text.get(), kCFStringNormalizationFormKC);
  // Compose combining marks produced by compatibility expansion (half-width kana).
  CFStringNormalize(text.get(), kCFStringNormalizationFormC);
  std::u16string result(CFStringGetLength(text.get()), u'\0');
  CFStringGetCharacters(text.get(), CFRangeMake(0, result.size()), reinterpret_cast<UniChar *>(result.data()));
  return result;
#else
  UErrorCode status = U_ZERO_ERROR;
  const auto *normalizer = unorm2_getNFKCInstance(&status);
  if (U_FAILURE(status)) throw std::runtime_error("Unicode normalization unavailable");
  auto length = unorm2_normalize(normalizer, reinterpret_cast<const UChar *>(value.data()),
                                 value.size(), nullptr, 0, &status);
  if (status != U_BUFFER_OVERFLOW_ERROR && U_FAILURE(status))
    throw std::runtime_error("Unicode normalization failed");
  status = U_ZERO_ERROR;
  std::u16string result(length, u'\0');
  unorm2_normalize(normalizer, reinterpret_cast<const UChar *>(value.data()), value.size(),
                   reinterpret_cast<UChar *>(result.data()), length, &status);
  if (U_FAILURE(status)) throw std::runtime_error("Unicode normalization failed");
  return result;
#endif
}
std::u16string unicode_lower(const std::u16string &value) { return transform_case(value, false); }
std::u16string unicode_upper(const std::u16string &value) { return transform_case(value, true); }
}
