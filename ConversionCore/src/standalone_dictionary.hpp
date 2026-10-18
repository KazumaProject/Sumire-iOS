#pragma once
#include "dictionary_format.hpp"
#include <string_view>

namespace sumire::detail {
// Build-time decoded v5 standalone rules, with original values preserved.
// The small immutable word table is mapped, not retained in the session cache.
struct StandaloneDictionary {
  File file;
  std::span<const uint32_t> offsets;
  std::span<const unsigned char> text;
  explicit StandaloneDictionary(const std::string &path)
      : file(path, 3, 2), offsets(file.array<uint32_t>(0)), text(file.sections[1]) {
    require(file.size <= 4 * 1024 * 1024 && file.dimension > 0 &&
                offsets.size() == uint64_t(file.dimension) + 1 &&
                offsets.front() == 0 && offsets.back() == text.size() &&
                std::is_sorted(offsets.begin(), offsets.end()),
            "invalid standalone word table");
    for (size_t i = 0; i < file.dimension; ++i) {
      auto word = at(i);
      require(!word.empty() && word.size() <= 32768, "invalid standalone word length");
      (void)utf16(std::string(word));
      require(i == 0 || at(i - 1) < word, "unsorted standalone words");
    }
  }
  std::string_view at(size_t i) const {
    return {reinterpret_cast<const char *>(text.data() + offsets[i]), offsets[i + 1] - offsets[i]};
  }
  bool contains(std::string_view word) const {
    size_t first = 0, last = file.dimension;
    while (first < last) {
      const auto middle = first + (last - first) / 2;
      if (at(middle) < word) first = middle + 1;
      else last = middle;
    }
    return first < file.dimension && at(first) == word;
  }
};
}
