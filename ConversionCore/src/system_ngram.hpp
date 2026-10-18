#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace sumire::detail {

struct NgramFeature {
  std::string_view surface;
  uint16_t left_context;
};

struct NgramScratch {
  std::vector<unsigned char> query;
  std::vector<unsigned char> record;
};

// Read-only reader for the pinned Android GNKG v3/v4 rule assets. Files remain
// memory-mapped; only the small first-feature indexes are retained in memory.
class PackedSystemNgram {
  struct Impl;
  std::unique_ptr<Impl> impl_;

public:
  PackedSystemNgram(const std::string &path, uint32_t expected_version);
  ~PackedSystemNgram();
  PackedSystemNgram(const PackedSystemNgram &) = delete;
  PackedSystemNgram &operator=(const PackedSystemNgram &) = delete;

  uint32_t rule_count() const noexcept;
  size_t mapped_bytes() const noexcept;
  bool may_match_first_node(const NgramFeature &node) const;
  bool may_match_first_pair(const NgramFeature &first,
                           const NgramFeature &second) const;
  bool matches(std::span<const NgramFeature> nodes, NgramScratch &scratch) const;
};

class SystemNgram {
  std::unique_ptr<PackedSystemNgram> bigram_to_fivegram_;
  std::unique_ptr<PackedSystemNgram> unigram_;

public:
  explicit SystemNgram(const std::string &dictionary_directory);
  bool available() const noexcept;
  uint32_t rule_count() const noexcept;
  size_t mapped_bytes() const noexcept;
  bool may_match_first_node(const NgramFeature &node) const;
  bool may_match_first_pair(const NgramFeature &first,
                           const NgramFeature &second) const;
  bool matches(std::span<const NgramFeature> nodes, NgramScratch &scratch) const;
};

} // namespace sumire::detail
