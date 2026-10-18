#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace sumire::detail {

// Read-only access to the pinned Android Mozc segmenter penalties and
// left-context attributes. Both files are mapped and structurally validated
// once when the dictionary generation is opened.
class MozcScoringData {
  struct Impl;
  std::unique_ptr<Impl> impl_;

public:
  explicit MozcScoringData(const std::string &dictionary_directory);
  ~MozcScoringData();
  MozcScoringData(const MozcScoringData &) = delete;
  MozcScoringData &operator=(const MozcScoringData &) = delete;

  int32_t prefix_penalty(uint16_t left_context) const;
  int32_t suffix_penalty(uint16_t right_context) const;
  uint32_t attributes(uint16_t left_context) const noexcept;
  size_t mapped_bytes() const noexcept;
};

} // namespace sumire::detail
