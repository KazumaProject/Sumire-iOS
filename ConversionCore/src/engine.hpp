#pragma once
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace sumire {
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
};
struct Result {
  std::vector<Candidate> candidates;
  double elapsed_ms = 0;
  size_t lattice_nodes = 0, expanded_states = 0;
  bool complete = true;
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
  PersonalDictionary(std::vector<PersonalEntry>, size_t contexts);

public:
  ~PersonalDictionary() = default;
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
         const std::vector<std::string> &categories, bool english_reading = false, bool english_words = false);
  ~Engine();
  Result convert(const std::string &reading, size_t count = 10,
                 size_t state_limit = 200000, bool omission = false,
                 const PersonalDictionary *personal = nullptr,
                 const PersonalDictionary *learned = nullptr,
                 Workspace *workspace = nullptr, bool prefix_candidates = false, bool japanese_prediction = false) const;
  Result lookup(const std::string &reading, size_t count = 10) const;
  Result lookup_english_reading(const std::string &reading, size_t count = 10) const;
  Result lookup_english(const std::string &reading, size_t count = 10) const;
  Result predict_english(const std::string &reading, size_t count = 10, bool case_variants = false,
                         const PersonalDictionary *personal = nullptr,
                         const PersonalDictionary *learned = nullptr) const;
  size_t mapped_bytes() const;
  std::shared_ptr<const PersonalDictionary>
      personal_dictionary(std::vector<PersonalEntry>) const;
};
} // namespace sumire
