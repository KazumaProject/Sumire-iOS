#include "engine.hpp"
#include "dictionary_format.hpp"
#include "standalone_dictionary.hpp"
#include "bunsetsu.hpp"
#include "unicode_case.hpp"
#include <algorithm>
#include <bit>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <limits>
#include <numeric>
#include <queue>
#include <span>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#include <unordered_map>
#include <zlib.h>
namespace sumire {
namespace {
using detail::require;
using detail::File;
using detail::Bits;
using detail::Dictionary;
constexpr int64_t INF = std::numeric_limits<int64_t>::max() / 4;
struct Connection {
  File file;
  std::span<const uint16_t> left, right, ranks;
  std::span<const int16_t> defaults, values;
  std::span<const uint64_t> bits;
  std::span<const uint32_t> starts;
  size_t n, blocks;
  explicit Connection(const std::string &dir)
      : file(dir + "/connection.sud", 2, 7), left(file.array<uint16_t>(0)),
        right(file.array<uint16_t>(1)), ranks(file.array<uint16_t>(6)),
        defaults(file.array<int16_t>(2)), values(file.array<int16_t>(4)),
        bits(file.array<uint64_t>(3)), starts(file.array<uint32_t>(5)),
        n(file.dimension), blocks((n + 63) / 64) {
    require(n > 0 && n <= 65535 && left.size() == right.size() &&
                !left.empty() && defaults.size() == n &&
                bits.size() == n * blocks && ranks.size() == bits.size() &&
                starts.size() == n + 1,
            "invalid connection dimensions");
    require(starts.front() == 0 && starts.back() == values.size() &&
                std::is_sorted(starts.begin(), starts.end()),
            "invalid connection offsets");
    for (size_t i = 0; i < left.size(); ++i)
      require(left[i] < n && right[i] < n, "invalid POS ids");
    for (size_t row = 0; row < n; ++row) {
      size_t rank = 0;
      for (size_t b = 0; b < blocks; ++b) {
        require(ranks[row * blocks + b] == rank, "invalid connection rank");
        rank += std::popcount(bits[row * blocks + b]);
      }
      require(starts[row + 1] - starts[row] == rank,
              "invalid connection values");
    }
  }
  int cost(uint16_t rid, uint16_t lid) const {
    size_t b = rid * blocks + lid / 64;
    uint64_t word = bits[b], mask = uint64_t(1) << (lid % 64);
    if (!(word & mask))
      return defaults[rid];
    return values[starts[rid] + ranks[b] + std::popcount(word & (mask - 1))];
  }
};
} // namespace
std::u16string utf16(const std::string &s) {
  std::u16string out;
  for (size_t i = 0; i < s.size();) {
    uint32_t c = static_cast<unsigned char>(s[i++]);
    int count = 0;
    uint32_t min = 0;
    if (c < 0x80) {
    } else if (c >= 0xc2 && c <= 0xdf) {
      c &= 31;
      count = 1;
      min = 0x80;
    } else if (c >= 0xe0 && c <= 0xef) {
      c &= 15;
      count = 2;
      min = 0x800;
    } else if (c >= 0xf0 && c <= 0xf4) {
      c &= 7;
      count = 3;
      min = 0x10000;
    } else
      throw std::runtime_error("invalid UTF-8");
    while (count--) {
      require(i < s.size(), "truncated UTF-8");
      auto b = static_cast<unsigned char>(s[i++]);
      require((b & 0xc0) == 0x80, "invalid UTF-8 continuation");
      c = (c << 6) | (b & 63);
    }
    require(c >= min && c <= 0x10ffff && !(c >= 0xd800 && c <= 0xdfff),
            "invalid Unicode scalar");
    if (c < 0x10000)
      out.push_back(c);
    else {
      c -= 0x10000;
      out.push_back(0xd800 + (c >> 10));
      out.push_back(0xdc00 + (c & 1023));
    }
  }
  return out;
}
std::string utf8(const std::u16string &s) {
  std::string out;
  for (size_t i = 0; i < s.size(); ++i) {
    uint32_t c = s[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      require(i + 1 < s.size() && s[i + 1] >= 0xdc00 && s[i + 1] <= 0xdfff,
              "unpaired surrogate");
      c = 0x10000 + ((c - 0xd800) << 10) + (s[++i] - 0xdc00);
    } else
      require(c < 0xdc00 || c > 0xdfff, "unpaired surrogate");
    if (c < 0x80)
      out.push_back(c);
    else if (c < 0x800) {
      out.push_back(0xc0 | (c >> 6));
      out.push_back(0x80 | (c & 63));
    } else if (c < 0x10000) {
      out.push_back(0xe0 | (c >> 12));
      out.push_back(0x80 | ((c >> 6) & 63));
      out.push_back(0x80 | (c & 63));
    } else {
      out.push_back(0xf0 | (c >> 18));
      out.push_back(0x80 | ((c >> 12) & 63));
      out.push_back(0x80 | ((c >> 6) & 63));
      out.push_back(0x80 | (c & 63));
    }
  }
  return out;
}
std::vector<std::string> category_names() {
  return {"address",
          "agreement",
          "award",
          "character",
          "event",
          "facility",
          "initiative",
          "kampo",
          "lineage",
          "medical",
          "mythological_figure",
          "organization",
          "person",
          "place",
          "product",
          "station",
          "term",
          "transport_route",
          "vehicle",
          "work_anime",
          "work_book",
          "work_film",
          "work_franchise",
          "work_game",
          "work_manga",
          "work_music",
          "work_other",
          "work_periodical",
          "work_program",
          "work_stage"};
}
struct Engine::Impl {
  std::shared_ptr<int> identity = std::make_shared<int>(0);
  Connection connection;
  std::unique_ptr<Dictionary> english_reading, english_words;
  std::unique_ptr<detail::StandaloneDictionary> standalone;
  std::vector<std::unique_ptr<Dictionary>> dictionaries;
  Impl(const std::string &dir, const std::vector<std::string> &cats, bool english, bool words, bool standalone_priority)
      : connection(dir) {
    const auto path = dir + "/standalone.sud";
    if (standalone_priority && std::filesystem::exists(path))
      standalone = std::make_unique<detail::StandaloneDictionary>(path);
    if (words) english_words = std::make_unique<Dictionary>(dir, "english");
    if (english) english_reading = std::make_unique<Dictionary>(dir, "english_reading");
    if (english_reading)
      for (auto p : english_reading->pos)
        require(p < connection.left.size(), "English reading POS outside table");
    auto valid = category_names();
    std::unordered_set<std::string> used;
    for (const auto &n : cats)
      require(std::find(valid.begin(), valid.end(), n) != valid.end(),
              "unknown category");
    dictionaries.push_back(std::make_unique<Dictionary>(dir, "system"));
    for (const auto &n : cats)
      if (used.insert(n).second)
        dictionaries.push_back(std::make_unique<Dictionary>(dir, n));
    for (auto &d : dictionaries)
      for (auto p : d->pos)
        require(p < connection.left.size(), "token POS outside table");
  }
};
Engine::Engine(const std::string &dir, const std::vector<std::string> &c, bool english, bool words, bool standalone_priority)
    : impl(std::make_unique<Impl>(dir, c, english, words, standalone_priority)) {}
Engine::~Engine() = default;
bool Engine::standalone_priority_available() const { return impl->standalone != nullptr; }
size_t Engine::mapped_bytes() const {
  size_t n = impl->connection.file.size;
  if (impl->standalone) n += impl->standalone->file.size;
  if (impl->english_reading) n += impl->english_reading->file.size;
  if (impl->english_words) n += impl->english_words->file.size;
  for (auto &d : impl->dictionaries)
    n += d->file.size;
  return n;
}
Result Engine::lookup(const std::string &input, size_t count) const {
  auto started = std::chrono::steady_clock::now();
  require(count >= 1 && count <= 100, "invalid candidate count");
  auto reading = utf16(input);
  require(reading.size() <= 8192,
          "input exceeds CLI limit of 8192 UTF-16 units (not truncated)");
  Result r;
  const auto &conn = impl->connection;
  for (auto &d : impl->dictionaries)
    d->prefixes(reading, 0, [&](size_t end, uint32_t token) {
      if (end != reading.size())
        return;
      auto text = d->surface(token, reading, 0, end);
      auto pos = d->pos[token];
      r.candidates.push_back({text,
                              int64_t(d->costs[token]) +
                                  conn.cost(0, conn.left[pos]) +
                                  conn.cost(conn.right[pos], 0),
                              {{text, d->name, 0, uint32_t(end)}}});
    });
  std::stable_sort(
      r.candidates.begin(), r.candidates.end(),
      [](const auto &a, const auto &b) { return a.score < b.score; });
  r.lattice_nodes = r.candidates.size();
  if (r.candidates.size() > count)
    r.candidates.resize(count);
  r.elapsed_ms = std::chrono::duration<double, std::milli>(
                     std::chrono::steady_clock::now() - started)
                     .count();
  return r;
}
static Result lookup_word_dictionary(const Dictionary *dictionary, const std::string &input, size_t count) {
  auto started = std::chrono::steady_clock::now();
  require(dictionary != nullptr, "requested English dictionary is not enabled");
  require(count >= 1 && count <= 100, "invalid candidate count");
  auto reading = utf16(input);
  require(reading.size() <= 8192, "input exceeds 8192 UTF-16 units (not truncated)");
  Result r;
  const auto &d = *dictionary;
  d.prefixes(reading, 0, [&](size_t end, uint32_t token) {
    if (end != reading.size()) return;
    auto text = d.surface(token, reading, 0, end);
    r.candidates.push_back({text, d.costs[token], {{text, d.name, 0, uint32_t(end)}}});
  });
  std::stable_sort(r.candidates.begin(), r.candidates.end(),
      [](const auto &a, const auto &b) { return a.score < b.score; });
  r.lattice_nodes = r.candidates.size();
  if (r.candidates.size() > count) r.candidates.resize(count);
  r.elapsed_ms = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - started).count();
  return r;
}
Result Engine::lookup_english_reading(const std::string &input, size_t count) const {
  return lookup_word_dictionary(impl->english_reading.get(), input, count);
}
Result Engine::lookup_english(const std::string &input, size_t count) const {
  return lookup_word_dictionary(impl->english_words.get(), input, count);
}
Result Engine::predict_english(const std::string &input, size_t count, bool case_variants,
                               const PersonalDictionary *personal, const PersonalDictionary *learned) const {
  auto started = std::chrono::steady_clock::now();
  require(impl->english_words != nullptr, "English dictionary is not enabled");
  require(count >= 1 && count <= 100, "invalid candidate count");
  auto reading = utf16(input);
  require(reading.size() <= 8192, "input exceeds 8192 UTF-16 units (not truncated)");
  Result r;
  if (reading.empty()) return r;
  const auto inputLength = reading.size();
  reading = unicode_lower(reading);
  const auto &d = *impl->english_words;
  d.predictive(reading, inputLength <= 2 ? 6 : 12, [&](size_t node, uint32_t token) {
    auto text = d.surface(token, reading, 0, reading.size(), node);
    r.candidates.push_back({text, d.costs[token], {{text, d.name, 0, uint32_t(inputLength)}}});
  });
  if (case_variants) {
    const auto inputUnits = utf16(input);
    auto upper = [](const std::string &value) { return utf8(unicode_upper(utf16(value))); };
    auto capitalized = [](const std::string &value) {
      auto units = utf16(value);
      if (!units.empty()) units[0] = unicode_simple_upper(units[0]);
      return utf8(units);
    };
    auto allLettersUpper = [](const std::u16string &value) {
      bool anyLetter = false;
      for (auto c : value) if (unicode_is_letter(c)) {
        anyLetter = true;
        if (!unicode_is_upper(c)) return false;
      }
      return anyLetter;
    };
    auto startsIgnoringCase = [](const std::u16string &value, const std::u16string &prefix) {
      if (value.size() < prefix.size()) return false;
      for (size_t i = 0; i < prefix.size(); ++i) {
        auto a = unicode_simple_upper(value[i]), b = unicode_simple_upper(prefix[i]);
        if (a != b && unicode_simple_lower(a) != unicode_simple_lower(b)) return false;
      }
      return true;
    };
    bool hasUpper = std::any_of(inputUnits.begin(), inputUnits.end(), unicode_is_upper);
    bool allUpper = allLettersUpper(inputUnits);
    auto raw = std::move(r.candidates);
    std::vector<Candidate> expanded;
    auto add = [&](const std::string &text, int64_t score) {
      auto found = std::find_if(expanded.begin(), expanded.end(),
          [&](const auto &c) { return c.text == text; });
      if (found == expanded.end())
        expanded.push_back({text, score, {{text, "english", 0, uint32_t(inputLength)}}});
      else if (score < found->score) found->score = score;
    };
    if (raw.empty()) {
      auto fallback = [&](const std::string &text, int64_t score) {
        expanded.push_back({text, score, {{text, "english", 0, uint32_t(inputLength)}}});
      };
      fallback(input, 10000);
      fallback(capitalized(input), unicode_is_upper(inputUnits[0]) ? 8500 : 10001);
      fallback(upper(input), 10002);
    } else {
      add(input, 500);
      add(capitalized(input), inputLength <= 3 ? 9000 : inputLength <= 4 ? 12000 : 57000);
      add(upper(input), inputLength <= 3 ? 9001 : inputLength <= 4 ? 22001 : 57001);
      for (const auto &candidate : raw) {
        const auto &base = candidate.text;
        auto resolved = base;
        if (allUpper) resolved = upper(base);
        else {
          auto units = utf16(base);
          const bool storedCase = std::any_of(units.begin() + std::min(size_t(1), units.size()), units.end(), unicode_is_upper)
              || allLettersUpper(units);
          if (!storedCase && hasUpper && startsIgnoringCase(units, inputUnits))
            resolved = input + utf8(units.substr(inputUnits.size()));
        }
        // Per-entry distinctBy preserves the first case penalty, before the
        // cross-entry minimum-cost merge used by the reference.
        std::unordered_set<std::string> seen;
        auto variant = [&](const std::string &text, int penalty) {
          if (seen.insert(text).second) add(text, candidate.score + penalty);
        };
        variant(resolved, 0); variant(base, 500);
        variant(capitalized(base), 500); variant(upper(base), 2000);
      }
    }
    r.candidates = std::move(expanded);
  }
  std::stable_sort(r.candidates.begin(), r.candidates.end(),
      [](const auto &a, const auto &b) { return a.score < b.score; });
  r.lattice_nodes = r.candidates.size();
  if (r.candidates.size() > count) r.candidates.resize(count);
  // Overlay readings and surfaces are user-authored and remain case-sensitive.
  // Keep only the requested top count while merging, even for large dictionaries.
  const auto originalReading = utf16(input);
  for (const auto *overlay : {personal, learned}) {
    if (!overlay) continue;
    require(overlay->context_count == impl->connection.n, "personal dictionary belongs to another matrix");
    auto entry = std::lower_bound(overlay->entries.begin(), overlay->entries.end(), originalReading,
        [](const auto &stored, const auto &key) { return stored.reading < key; });
    for (; entry != overlay->entries.end() && entry->reading.starts_with(originalReading); ++entry) {
      const auto &word = entry->entry;
      if ((word.exact_only || word.learned) && entry->reading != originalReading) continue;
      ++r.lattice_nodes;
      auto existing = std::find_if(r.candidates.begin(), r.candidates.end(),
          [&](const auto &candidate) { return candidate.text == word.text; });
      if (existing != r.candidates.end() && existing->score <= word.score) continue;
      if (existing == r.candidates.end() && r.candidates.size() == count && r.candidates.back().score <= word.score) continue;
      std::erase_if(r.candidates, [&](const auto &candidate) { return candidate.text == word.text; });
      const auto source = word.learned ? "learning" : word.exact_only ? "template" : "user";
      r.candidates.push_back({word.text, word.score, {{word.text, source, 0, uint32_t(inputLength)}}});
      std::stable_sort(r.candidates.begin(), r.candidates.end(),
          [](const auto &left, const auto &right) { return left.score < right.score; });
      if (r.candidates.size() > count) r.candidates.resize(count);
    }
  }
  r.elapsed_ms = std::chrono::duration<double, std::milli>(
      std::chrono::steady_clock::now() - started).count();
  return r;
}
PersonalDictionary::PersonalDictionary(std::vector<PersonalEntry> source,
                                       size_t contexts)
    : context_count(contexts) {
  require(source.size() <= 100000, "too many personal entries");
  size_t bytes = 0;
  for (auto &entry : source) {
    require(entry.context_id < contexts,
            "personal context ID outside connection matrix");
    require(!entry.reading.empty() && !entry.text.empty(),
            "empty personal reading or text");
    require(entry.reading.size() <= 32768 && entry.text.size() <= 65536,
            "personal entry too long (not truncated)");
    bytes += entry.reading.size() + entry.text.size();
    require(bytes <= 16 * 1024 * 1024,
            "personal dictionary exceeds 16 MiB text budget");
    auto key = utf16(entry.reading);
    require(key.size() <= 8192, "personal reading exceeds input limit");
    (void)utf16(entry.text); // Strict UTF-8 validation, including templates.
    entries.push_back({std::move(entry), std::move(key)});
  }
  std::stable_sort(
      entries.begin(), entries.end(),
      [](const auto &a, const auto &b) { return a.reading < b.reading; });
}
std::shared_ptr<const PersonalDictionary>
Engine::personal_dictionary(std::vector<PersonalEntry> entries) const {
  return std::shared_ptr<const PersonalDictionary>(
      new PersonalDictionary(std::move(entries), impl->connection.n));
}
bool PersonalDictionary::equivalent(const PersonalDictionary &other) const {
  if (context_count != other.context_count || entries.size() != other.entries.size()) return false;
  for (size_t i = 0; i < entries.size(); ++i) {
    const auto &a = entries[i].entry, &b = other.entries[i].entry;
    if (a.reading != b.reading || a.text != b.text || a.context_id != b.context_id ||
        a.score != b.score || a.exact_only != b.exact_only || a.learned != b.learned) return false;
  }
  return true;
}
struct Workspace::Impl {
  struct Node {
    size_t start, end;
    const Dictionary *dict;
    uint32_t token;
    uint16_t left, right;
    int64_t cost;
    size_t correctedNode = 0;
    int64_t tail = INF;
    const PersonalEntry *personal = nullptr;
  };
  // Cache only immutable dictionary nodes. Overlay pointers and Viterbi tails
  // belong to the current request and are never stored here. horizon includes
  // the first failed lookup; EOF is represented by previous length + 1.
  struct SearchRow { std::vector<Node> nodes; size_t horizon = 0; };
  std::vector<SearchRow> search_rows;
  std::u16string previous_reading;
  std::weak_ptr<int> engine_identity;
  std::shared_ptr<int> personal_identity, learned_identity;
  size_t previous_count = 0, previous_limit = 0;
  bool previous_omission = false, previous_prefix = false, previous_prediction = false;
  bool cache_valid = false;
  std::vector<Node> nodes;
  std::vector<std::vector<size_t>> at;
  struct State {
    size_t node, parent;
    int64_t cost; // The bound is cost + nodes[node].tail; only the heap stores it.
  };
  std::vector<State> states;
  struct Item {
    int64_t bound;
    size_t index;
    bool operator>(const Item &b) const {
      return bound != b.bound ? bound > b.bound : index > b.index;
    }
  };
  std::vector<Item> heap;
  std::vector<size_t> path;
  std::vector<Dictionary::OmissionState> omission_pending;
  size_t bytes() const noexcept {
    size_t total = nodes.capacity() * sizeof(Node) + states.capacity() * sizeof(State) +
        heap.capacity() * sizeof(Item) + path.capacity() * sizeof(size_t) + at.capacity() * sizeof(at[0]) +
        omission_pending.capacity() * sizeof(Dictionary::OmissionState);
    for (const auto &row : at) total += row.capacity() * sizeof(size_t);
    total += search_rows.capacity() * sizeof(SearchRow);
    // String small-buffer capacity is inline storage, not retained allocation.
    if (previous_reading.capacity() > std::u16string().capacity())
      total += previous_reading.capacity() * sizeof(char16_t);
    for (const auto &row : search_rows) total += row.nodes.capacity() * sizeof(Node);
    return total;
  }
  void purge() noexcept {
    std::vector<SearchRow>().swap(search_rows);
    std::u16string().swap(previous_reading);
    engine_identity.reset(); personal_identity.reset(); learned_identity.reset();
    cache_valid = false;
    std::vector<Node>().swap(nodes);
    std::vector<State>().swap(states);
    std::vector<Item>().swap(heap);
    std::vector<size_t>().swap(path);
    std::vector<std::vector<size_t>>().swap(at);
    std::vector<Dictionary::OmissionState>().swap(omission_pending);
  }
  void finish() noexcept {
    nodes.clear(); states.clear(); heap.clear(); path.clear();
    omission_pending.clear();
    for (auto &row : at) row.clear();
    if (bytes() > 4 * 1024 * 1024) purge();
  }
};
Workspace::Workspace() : impl(std::make_unique<Impl>()) {}
Workspace::~Workspace() = default;
void Workspace::purge() noexcept { impl->purge(); }
size_t Workspace::retained_bytes() const noexcept { return impl->bytes(); }

static void rank_primary(std::vector<Candidate> &candidates,
                         size_t limit = std::numeric_limits<size_t>::max()) {
  std::vector<std::u16string> surfaces;
  surfaces.reserve(candidates.size());
  for (const auto &candidate : candidates) surfaces.push_back(utf16(candidate.text));
  std::vector<size_t> order(candidates.size());
  std::iota(order.begin(), order.end(), 0);
  const auto less = [&](size_t a, size_t b) {
    if (candidates[a].standalone_unigram_matched != candidates[b].standalone_unigram_matched)
      return candidates[a].standalone_unigram_matched;
    if (candidates[a].score != candidates[b].score) return candidates[a].score < candidates[b].score;
    if (surfaces[a] != surfaces[b])
      return surfaces[a] < surfaces[b]; // Kotlin String.compareTo uses UTF-16.
    // Reproduce stable_sort's original-order behavior if two entries compare
    // equal, while making the comparator total for nth_element.
    return a < b;
  };
  if (limit < order.size()) {
    std::nth_element(order.begin(), order.begin() + limit, order.end(), less);
    order.resize(limit);
  }
  std::sort(order.begin(), order.end(), less);
  std::vector<Candidate> ranked;
  ranked.reserve(order.size());
  for (auto index : order) ranked.push_back(std::move(candidates[index]));
  candidates = std::move(ranked);
}

Result Engine::convert(const std::string &input, size_t count, size_t limit,
                       bool omission,
                       const PersonalDictionary *personal,
                       const PersonalDictionary *learned, Workspace *workspace, bool prefix_candidates, bool japanese_prediction) const {
  auto started = std::chrono::steady_clock::now();
  require(count >= 1 && count <= 100 && limit >= 1 && limit <= 2000000,
          "invalid search limits");
  auto reading = utf16(input);
  require(reading.size() <= 8192,
          "input exceeds CLI limit of 8192 UTF-16 units (not truncated)");
  Result result;
  std::unique_ptr<Workspace> temporary;
  if (!workspace) { temporary = std::make_unique<Workspace>(); workspace = temporary.get(); }
  auto &work = *workspace->impl;
  struct Cleanup {
    Workspace::Impl &work;
    bool active = true;
    ~Cleanup() { if (active) { work.cache_valid = false; work.finish(); } }
  } cleanup{work};
  using Node = Workspace::Impl::Node;
  auto &nodes = work.nodes;
  auto &at = work.at;
  std::vector<size_t> exactCategoryNodes;
  at.resize(reading.size() + 1);
  const auto &conn = impl->connection;
  require((!personal || personal->context_count == conn.n) &&
              (!learned || learned->context_count == conn.n),
          "personal dictionary belongs to another matrix");
  const auto personalIdentity = personal ? personal->identity : std::shared_ptr<int>();
  const auto learnedIdentity = learned ? learned->identity : std::shared_ptr<int>();
  const bool compatible = work.cache_valid && work.engine_identity.lock() == impl->identity &&
      work.personal_identity == personalIdentity && work.learned_identity == learnedIdentity &&
      work.previous_count == count && work.previous_limit == limit &&
      work.previous_omission == omission && work.previous_prefix == prefix_candidates &&
      work.previous_prediction == japanese_prediction;
  size_t common = 0;
  if (compatible)
    while (common < reading.size() && common < work.previous_reading.size() &&
           reading[common] == work.previous_reading[common]) ++common;
  const bool same = compatible && reading == work.previous_reading;
  if (!compatible) work.search_rows.clear();
  work.search_rows.resize(reading.size());
  for (size_t i = 0; i < reading.size(); ++i) {
    if (reading[i] >= 0xdc00 && reading[i] <= 0xdfff)
      continue;
    auto add = [&](Node node) {
      require(nodes.size() < 2000000,
              "lattice limit exceeded (input not truncated)");
      const size_t id = nodes.size();
      at[i].push_back(id);
      nodes.push_back(node);
      if (node.start == 0 && node.end == reading.size() && node.dict &&
          node.dict != impl->dictionaries.front().get() && !node.correctedNode)
        exactCategoryNodes.push_back(id);
    };
    auto &cached = work.search_rows[i];
    if (compatible && cached.horizon && (same || cached.horizon <= common)) {
      ++result.reused_search_rows;
      for (const auto &node : cached.nodes) add(node);
    } else {
      ++result.searched_rows;
      cached.nodes.clear(); cached.horizon = 0;
      for (auto &d : impl->dictionaries) {
        auto matched = [&](size_t end, uint32_t token, size_t correctedNode) {
          if (end < reading.size() && reading[end] >= 0xdc00 &&
              reading[end] <= 0xdfff)
            return;
          auto p = d->pos[token];
          Node node{i, end, d.get(), token, conn.left[p], conn.right[p],
                    d->costs[token] + (correctedNode ? 1900 : 0), correctedNode};
          cached.nodes.push_back(node);
          add(node);
        };
        if (omission)
          cached.horizon = std::max(cached.horizon, d->omissionPrefixes(reading, i, work.omission_pending, matched));
        else
          cached.horizon = std::max(cached.horizon, d->prefixes(reading, i, [&](size_t end, uint32_t token) {
            matched(end, token, 0);
          }));
      }
    }
    for (const auto *overlay : {personal, learned}) {
      if (!overlay) continue;
      auto first = overlay->entries.begin(), last = overlay->entries.end();
      for (size_t j = i; j < reading.size() && first != last; ++j) {
        const size_t depth = j - i;
        auto label = [depth](const auto &entry) {
          return entry.reading.size() > depth ? int(entry.reading[depth]) : -1;
        };
        first = std::lower_bound(
            first, last, int(reading[j]),
            [&](const auto &entry, int c) { return label(entry) < c; });
        last = std::upper_bound(
            first, last, int(reading[j]),
            [&](int c, const auto &entry) { return c < label(entry); });
        auto terminal =
            std::partition_point(first, last, [depth](const auto &entry) {
              return entry.reading.size() == depth + 1;
            });
        for (auto it = first; it != terminal; ++it) {
          const auto &entry = it->entry;
          if (entry.exact_only && (i != 0 || j + 1 != reading.size()))
            continue;
          uint16_t context = entry.exact_only ? 0 : entry.context_id;
          int64_t cost = entry.score;
          if (entry.exact_only)
            cost -= 2LL * conn.cost(0, 0);
          Node node{i, j + 1, nullptr, 0, context, context, cost};
          node.personal = &entry;
          add(node);
        }
        first = terminal;
      }
    }
    size_t end = i + ((reading[i] >= 0xd800 && reading[i] <= 0xdbff) ? 2 : 1);
    add({i, end, nullptr, 0, 0, 0, 16000});
  }
  // Backward Viterbi gives the exact best remaining cost for each token.
  // The lattice is acyclic, so negative word/connection costs are supported.
  for (size_t i = reading.size(); i-- > 0;)
    for (size_t id : at[i]) {
      auto &node = nodes[id];
      if (node.end == reading.size())
        node.tail = conn.cost(node.right, 0);
      else
        for (size_t next : at[node.end]) {
          auto &n = nodes[next];
          node.tail =
              std::min(node.tail, int64_t(conn.cost(node.right, n.left)) +
                                      n.cost + n.tail);
        }
    }
  // A* enumerates complete paths in score order using the exact tail bound.
  // Strings are materialized only at EOS; equivalent surfaces are deduplicated.
  auto &states = work.states;
  auto &heap = work.heap;
  constexpr size_t none = std::numeric_limits<size_t>::max();
  auto push = [&](size_t id, size_t parent, int64_t cost) {
    if (states.size() >= limit) {
      result.complete = false;
      return;
    }
    size_t index = states.size();
    states.push_back({id, parent, cost});
    heap.push_back({cost + nodes[id].tail, index});
    std::push_heap(heap.begin(), heap.end(), std::greater<Workspace::Impl::Item>());
  };
  for (auto id : at[0])
    push(id, none, int64_t(conn.cost(0, nodes[id].left)) + nodes[id].cost);
  auto literal = [&](const Node &node) {
    if (node.start != 0 || node.end != reading.size() || node.correctedNode) return false;
    return node.personal ? node.personal->text == input
        : node.dict ? node.dict->surface(node.token, reading, 0, reading.size()) == input
        : true;
  };
  const bool standaloneMayMatch = impl->standalone && impl->standalone->contains(input) &&
      std::any_of(at[0].begin(), at[0].end(), [&](size_t i) { return literal(nodes[i]); });
  // Preserve N even when callers request more than Android's safety window.
  const size_t searchCount = standaloneMayMatch ? std::max(count, std::min(size_t(64), std::max(count * 4, size_t(32)))) : count;
  bool standaloneFound = false;
  std::unordered_set<std::string> seen;
  while (!heap.empty() && result.candidates.size() < searchCount) {
    auto index = heap.front().index;
    std::pop_heap(heap.begin(), heap.end(), std::greater<Workspace::Impl::Item>());
    heap.pop_back();
    auto state = states[index];
    auto &node = nodes[state.node];
    ++result.expanded_states;
    if (node.end == reading.size()) {
      Candidate c;
      c.score = state.cost + node.tail;
      auto &path = work.path;
      path.clear();
      for (size_t p = index; p != none; p = states[p].parent)
        path.push_back(states[p].node);
      for (auto it = path.rbegin(); it != path.rend(); ++it) {
        auto &n = nodes[*it];
        auto s = n.personal ? n.personal->text
                 : n.dict   ? n.dict->surface(n.token, reading, n.start, n.end,
                                              n.correctedNode)
                            : utf8(reading.substr(n.start, n.end - n.start));
        if (n.start > 0 && is_bunsetsu_independent(n.left))
          c.bunsetsu_boundaries.push_back(uint32_t(n.start));
        c.text += s;
        c.segments.push_back(
            {s,
             n.personal ? (n.personal->learned ? "learning" : (n.personal->exact_only ? "template" : "user"))
             : n.dict   ? n.dict->name
                        : "unknown",
             uint32_t(n.start), uint32_t(n.end - n.start)});
        if (n.dict && n.dict != impl->dictionaries.front().get() &&
            std::find(c.classified_categories.begin(), c.classified_categories.end(), n.dict->name) == c.classified_categories.end())
          c.classified_categories.push_back(n.dict->name);
      }
      c.standalone_unigram_matched = standaloneMayMatch && path.size() == 1 && literal(nodes[path.front()]);
      if (c.standalone_unigram_matched) {
        standaloneFound = true;
        // A later single-node path can promote an earlier cheaper duplicate.
        for (auto &existing : result.candidates)
          if (existing.text == c.text) existing.standalone_unigram_matched = true;
      }
      if (seen.insert(c.text).second)
        result.candidates.push_back(std::move(c));
      if (standaloneFound && result.candidates.size() >= count) break;
    } else
      for (size_t id : at[node.end])
        push(id, index,
             state.cost + conn.cost(node.right, nodes[id].left) +
                 nodes[id].cost);
  }
  if (result.candidates.size() > count) {
    rank_primary(result.candidates, count);
  }
  seen.clear();
  std::unordered_map<std::string, size_t> primary;
  for (size_t i = 0; i < result.candidates.size(); ++i) primary.emplace(result.candidates[i].text, i);
  // Category exact matches are independent of the N-best search limit. Keep
  // every homophone, but merge duplicate origins without fabricating segments.
  for (size_t id : exactCategoryNodes) {
    const auto &node = nodes[id];
    Candidate exact;
    exact.text = node.dict->surface(node.token, reading, 0, reading.size());
    exact.score = conn.cost(0, node.left) + int64_t(node.cost) + conn.cost(node.right, 0);
    exact.segments.push_back({exact.text, node.dict->name, 0, uint32_t(reading.size())});
    exact.standalone_unigram_matched = impl->standalone && impl->standalone->contains(input) && literal(node);
    const bool exactMatched = exact.standalone_unigram_matched;
    auto [position, inserted] = primary.emplace(exact.text, result.candidates.size());
    if (inserted) result.candidates.push_back(std::move(exact));
    auto &winner = result.candidates[position->second];
    const bool matched = winner.standalone_unigram_matched || exactMatched;
    if (!inserted && exact.score < winner.score) {
      exact.classified_categories = std::move(winner.classified_categories);
      winner = std::move(exact);
    }
    winner.standalone_unigram_matched = matched;
    if (std::find(winner.classified_categories.begin(), winner.classified_categories.end(), node.dict->name) == winner.classified_categories.end())
      winner.classified_categories.push_back(node.dict->name);
  }
  for (const auto &candidate : result.candidates) seen.insert(candidate.text);
  if (japanese_prediction && reading.size() >= 3 && reading.size() <= 16) {
    // PredictionConfig defaults in Sumire dev 9506a0b: lookahead 3, limit 4.
    // Retain token references only; materialize surfaces after top-k selection.
    const auto &d = *impl->dictionaries.front();
    struct Prediction { size_t node; uint32_t token; int64_t score; };
    std::vector<Prediction> best;
    const bool complete = d.completion(reading, 3, limit, [&](size_t node, uint32_t token, size_t extra) {
      const int64_t score = d.costs[token] + (reading.size() <= 5 ? int64_t(extra) * 8000 : 6000);
      const auto at = std::upper_bound(best.begin(), best.end(), score,
          [](int64_t value, const Prediction &entry) { return value < entry.score; });
      if (best.size() == 4 && at == best.end()) return;
      best.insert(at, {node, token, score});
      if (best.size() > 4) best.pop_back();
    });
    result.complete = result.complete && complete;
    for (const auto &prediction : best) {
      auto text = d.surface(prediction.token, reading, 0, reading.size(), prediction.node);
      if (seen.insert(text).second)
        result.candidates.push_back({text, prediction.score,
            {{text, d.name, 0, uint32_t(reading.size())}}});
    }
  }
  rank_primary(result.candidates);
  if (impl->english_reading && !reading.empty()) {
    const auto &d = *impl->english_reading;
    auto add = [&](const std::string &text, int64_t score) {
      if (seen.insert(text).second)
        result.candidates.push_back({text, score, {{text, d.name, 0, uint32_t(reading.size())}}});
    };
    d.prefixes(reading, 0, [&](size_t end, uint32_t token) {
      if (end != reading.size()) return;
      auto text = d.surface(token, reading, 0, end);
      add(text, d.costs[token]);
      const bool letters = std::any_of(text.begin(), text.end(), [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
      });
      if (!letters) return;
      auto lower = unicode_lower(utf16(text));
      add(utf8(lower), d.costs[token]);
      auto capitalized = unicode_upper(lower.substr(0, 1)) + lower.substr(1);
      add(utf8(capitalized), int64_t(d.costs[token]) + 1500);
      add(utf8(unicode_upper(lower)), int64_t(d.costs[token]) + 3000);
    });
  }
  // Reference dev 9506a0b yomiPartList: longest matching reading first,
  // dictionary token order within a reading; input lengths 2...16 only.
  if (prefix_candidates && reading.size() > 1 && reading.size() <= 16) {
    const auto &d = *impl->dictionaries.front();
    std::vector<std::pair<size_t, uint32_t>> matches;
    d.prefixes(reading, 0, [&](size_t end, uint32_t token) { matches.emplace_back(end, token); });
    std::stable_sort(matches.begin(), matches.end(), [](auto a, auto b) { return a.first > b.first; });
    for (auto [end, token] : matches) {
      auto text = d.surface(token, reading, 0, end);
      if (seen.insert(text).second)
        result.candidates.push_back({text, d.costs[token], {{text, d.name, 0, uint32_t(end)}}});
    }
  }
  if (reading.empty())
    result.candidates.push_back({"", 0, {}});
  result.lattice_nodes = nodes.size();
  work.previous_reading = reading;
  work.engine_identity = impl->identity;
  work.personal_identity = personalIdentity; work.learned_identity = learnedIdentity;
  work.previous_count = count; work.previous_limit = limit;
  work.previous_omission = omission; work.previous_prefix = prefix_candidates;
  work.previous_prediction = japanese_prediction; work.cache_valid = true;
  work.finish();
  cleanup.active = false;
  result.elapsed_ms = std::chrono::duration<double, std::milli>(
                          std::chrono::steady_clock::now() - started)
                          .count();
  return result;
}
} // namespace sumire
