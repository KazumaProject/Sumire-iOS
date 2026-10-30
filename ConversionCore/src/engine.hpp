#pragma once
#include <cstdint>
#include <cstddef>
#include <memory>
#include <optional>
#include <string>
#include <vector>
namespace sumire {
enum class CandidatePresentationKind : uint32_t {
  none = 0, half_width = 1, full_width = 2, numeric_symbol = 3
};
struct Segment {
  std::string text, dictionary;
  uint32_t start, length;
  uint16_t left_context_id = 0, right_context_id = 0;
};
struct Candidate {
  std::string text;
  int64_t score;
  std::vector<Segment> segments;
  // Interior reading offsets (UTF-16), from the selected complete path.
  std::vector<uint32_t> bunsetsu_boundaries{};
  bool standalone_unigram_matched = false;
  // Origin labels do not replace the selected path's segment boundaries.
  std::vector<std::string> classified_categories{};
  bool system_ngram_matched = false;
  // Reading-correction source payload is surface<TAB>corrected reading. The
  // display/commit text above never contains this metadata delimiter.
  std::string raw_text{};
  std::string corrected_reading{};
  // Reference type 5: a yomiPartList match shorter than the input (type 2 otherwise).
  bool is_reading_prefix = false;
  CandidatePresentationKind presentation_kind = CandidatePresentationKind::none;
};
struct CandidateSplitPattern {
  std::string surface;
  std::vector<uint32_t> positions;
};
struct Result {
  std::vector<Candidate> candidates;
  // Candidate surfaces promoted by the bunsetsu-only Android system n-gram route.
  std::vector<std::string> system_ngram_matched_candidates;
  // At most four distinct UTF-16 reading-boundary patterns from bunsetsu paths.
  std::vector<std::vector<uint32_t>> bunsetsu_split_patterns;
  std::vector<uint32_t> primary_bunsetsu_split_positions;
  // Split positions for every primary path surface discovered by the
  // bunsetsu search, including paths outside the visible N-best list.
  std::vector<CandidateSplitPattern> split_pattern_by_candidate;
  double elapsed_ms = 0;
  size_t lattice_nodes = 0, expanded_states = 0;
  bool complete = true;
  size_t reused_search_rows = 0, searched_rows = 0;
};
std::u16string utf16(const std::string &);
std::string utf8(const std::u16string &);
std::vector<std::string> category_names();
std::vector<std::string> release_category_names();
// Resolve legacy families only for explicitly marked release generations.
std::vector<std::string> resolve_category_names(const std::string &directory,
                                              const std::vector<std::string> &requested,
                                              bool expand_legacy_categories = true);
struct PersonalEntry {
  std::string reading, text;
  uint16_t context_id;
  int32_t score;
  bool exact_only = false; // Templates match the complete input only.
  bool learned = false;
  // Independent endpoints for metadata-aware learned entries.
  uint16_t left_context_id = 0, right_context_id = 0;
};
class PersonalDictionary {
  friend class Engine;
  struct Stored {
    PersonalEntry entry;
    std::u16string reading;
  };
  std::vector<Stored> entries;
  size_t context_count;
  std::shared_ptr<int> identity = std::make_shared<int>(0);
  PersonalDictionary(std::vector<PersonalEntry>, size_t contexts);

public:
  ~PersonalDictionary() = default;
  bool equivalent(const PersonalDictionary &) const;
};
// One workspace per serial conversion session. Returned results own their data.
class Workspace {
  friend class Engine;
  struct Impl;
  std::unique_ptr<Impl> impl;
public:
  Workspace();
  ~Workspace();
  void purge() noexcept;
  size_t retained_bytes() const noexcept;
};
enum class PredictionAggressiveness : uint32_t {
  conservative = 0, standard = 1, aggressive = 2
};
struct PredictionConfig {
  size_t lookahead_character_count = 3;
  PredictionAggressiveness aggressiveness = PredictionAggressiveness::standard;

  int64_t completion_penalty(size_t input_length, size_t reading_length,
                             int64_t penalty_per_character = 8000,
                             std::optional<int64_t> long_input_flat_penalty = 6000) const {
    const size_t extra = reading_length > input_length ? reading_length - input_length : 0;
    if (!extra) return 0;
    const int64_t standard = input_length <= 5 || !long_input_flat_penalty
        ? penalty_per_character * static_cast<int64_t>(extra)
        : *long_input_flat_penalty;
    switch (aggressiveness) {
    case PredictionAggressiveness::conservative: return standard * 3 / 2;
    case PredictionAggressiveness::aggressive: return standard / 2;
    case PredictionAggressiveness::standard: return standard;
    }
    return standard;
  }
};
class Engine {
  struct Impl;
  std::unique_ptr<Impl> impl;

public:
  Engine(const std::string &directory,
         const std::vector<std::string> &categories, bool english_reading = false, bool english_words = false,
         bool standalone_priority = true, bool expand_legacy_categories = true,
         const std::vector<std::string> &legacy_aggregate_ids = {});
  ~Engine();
  Result convert(const std::string &reading, size_t count = 10,
                 size_t state_limit = 200000, bool omission = false,
                 const PersonalDictionary *personal = nullptr,
                 const PersonalDictionary *learned = nullptr,
                 Workspace *workspace = nullptr, bool prefix_candidates = false,
                 bool japanese_prediction = false, bool bunsetsu_search = false,
                 const PredictionConfig &prediction_config = {},
                 bool numeric_symbol_candidates = true) const;
  Result lookup(const std::string &reading, size_t count = 10) const;
  Result lookup_english_reading(const std::string &reading, size_t count = 10) const;
  Result lookup_english(const std::string &reading, size_t count = 10) const;
  Result predict_english(const std::string &reading, size_t count = 10, bool case_variants = false,
                         const PersonalDictionary *personal = nullptr,
                         const PersonalDictionary *learned = nullptr) const;
  size_t mapped_bytes() const;
  bool standalone_priority_available() const;
  std::shared_ptr<const PersonalDictionary>
      personal_dictionary(std::vector<PersonalEntry>) const;
};
} // namespace sumire
