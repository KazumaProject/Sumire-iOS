#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace sumire {
enum class CandidatePresentationKind : uint32_t {
  none = 0, half_width = 1, full_width = 2, numeric_symbol = 3
};
struct Segment {
  std::string text, dictionary;
  uint32_t start, length;
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
struct PersonalEntry {
  std::string reading, text;
  uint16_t context_id;
  int32_t score;
  bool exact_only = false; // Templates match the complete input only.
  bool learned = false;
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
class Engine {
  struct Impl;
  std::unique_ptr<Impl> impl;

public:
  Engine(const std::string &directory,
         const std::vector<std::string> &categories, bool english_reading = false, bool english_words = false,
         bool standalone_priority = true);
  ~Engine();
  Result convert(const std::string &reading, size_t count = 10,
                 size_t state_limit = 200000, bool omission = false,
                 const PersonalDictionary *personal = nullptr,
                 const PersonalDictionary *learned = nullptr,
                 Workspace *workspace = nullptr, bool prefix_candidates = false,
                 bool japanese_prediction = false, bool bunsetsu_search = false,
                 bool kotowaza_enabled = true) const;
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
