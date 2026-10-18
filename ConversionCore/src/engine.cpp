#include "engine.hpp"
#include "bunsetsu.hpp"
#include "unicode_case.hpp"
#include <algorithm>
#include <bit>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <queue>
#include <span>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#include <zlib.h>
namespace sumire {
namespace {
void require(bool b, const char *message) {
  if (!b)
    throw std::runtime_error(message);
}
constexpr int64_t INF = std::numeric_limits<int64_t>::max() / 4;
uint32_t u32(const unsigned char *p) {
  uint32_t v;
  std::memcpy(&v, p, 4);
  return v;
}
uint64_t u64(const unsigned char *p) {
  uint64_t v;
  std::memcpy(&v, p, 8);
  return v;
}
struct File {
  File(const File &) = delete;
  File &operator=(const File &) = delete;
  const unsigned char *p = nullptr;
  size_t size = 0;
  uint32_t dimension = 0;
  std::vector<std::span<const unsigned char>> sections;
  File(const std::string &path, uint32_t kind, size_t count) {
    static_assert(std::endian::native == std::endian::little);
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0)
      throw std::runtime_error("cannot open " + path);
    struct stat st{};
    if (fstat(fd, &st) != 0 || st.st_size < 24 ||
        st.st_size > 1024LL * 1024 * 1024) {
      close(fd);
      throw std::runtime_error("invalid dictionary size");
    }
    size = static_cast<size_t>(st.st_size);
    void *map = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    require(map != MAP_FAILED, "mmap failed");
    p = static_cast<const unsigned char *>(map);
    try {
      require(std::memcmp(p, "SUMIRE01", 8) == 0 && u32(p + 8) == 1 &&
                  u32(p + 12) == kind && u32(p + 16) == count,
              "unsupported dictionary header");
      dimension = u32(p + 20);
      size_t end = 24 + 24 * count;
      require(end <= size, "truncated directory");
      for (size_t i = 0; i < count; ++i) {
        const auto *d = p + 24 + i * 24;
        uint64_t off = u64(d), len = u64(d + 8);
        require(off % 8 == 0 && off >= end && off <= size &&
                    len <= size - off && u32(d + 20) == 0,
                "invalid section range");
        require(crc32(0, p + off, static_cast<uInt>(len)) == u32(d + 16),
                "dictionary checksum mismatch");
        sections.emplace_back(p + off, len);
        end = off + len;
      }
      require(end == size, "trailing dictionary data");
    } catch (...) {
      munmap(const_cast<unsigned char *>(p), size);
      p = nullptr;
      throw;
    }
  }
  ~File() {
    if (p)
      munmap(const_cast<unsigned char *>(p), size);
  }
  template <class T> std::span<const T> array(size_t i) const {
    auto s = sections.at(i);
    require(s.size() % sizeof(T) == 0, "invalid array length");
    return {reinterpret_cast<const T *>(s.data()), s.size() / sizeof(T)};
  }
};
struct Bits {
  std::span<const uint64_t> words;
  std::vector<uint32_t> ranks;
  explicit Bits(std::span<const uint64_t> w) : words(w), ranks(w.size() + 1) {
    for (size_t i = 0; i < w.size(); ++i)
      ranks[i + 1] = ranks[i] + std::popcount(w[i]);
  }
  bool at(size_t p) const {
    return p / 64 < words.size() && ((words[p / 64] >> (p % 64)) & 1);
  }
  uint32_t rank(size_t p) const {
    if (p / 64 >= words.size())
      return ranks.back();
    unsigned b = p % 64;
    uint64_t mask = ~uint64_t(0) >> (63 - b);
    return ranks[p / 64] + std::popcount(words[p / 64] & mask);
  }
  size_t select1(size_t nth) const {
    require(nth > 0 && nth <= ranks.back(), "invalid one rank");
    auto word = size_t(std::lower_bound(ranks.begin() + 1, ranks.end(), nth) -
                       ranks.begin() - 1);
    uint64_t bits = words[word];
    size_t remaining = nth - ranks[word];
    while (--remaining)
      bits &= bits - 1;
    return word * 64 + std::countr_zero(bits);
  }
  size_t select0(size_t nth) const {
    require(nth > 0 && nth <= words.size() * 64 - ranks.back(),
            "invalid zero rank");
    size_t lo = 0, hi = words.size();
    while (lo < hi) {
      size_t mid = (lo + hi) / 2;
      if ((mid + 1) * 64 - ranks[mid + 1] < nth)
        lo = mid + 1;
      else
        hi = mid;
    }
    uint64_t x = ~words[lo];
    size_t remaining = nth - (lo * 64 - ranks[lo]);
    while (--remaining)
      x &= x - 1;
    return lo * 64 + std::countr_zero(x);
  }
};
struct Dictionary {
  std::string name;
  File file;
  Bits tree, leaf;
  std::span<const uint16_t> labels, pos;
  std::span<const int16_t> costs;
  std::span<const uint32_t> terms, postings, refs, offsets;
  std::span<const unsigned char> strings;
  Dictionary(const std::string &dir, const std::string &n)
      : name(n), file(dir + "/" + n + ".sud", 1, 10),
        tree(file.array<uint64_t>(0)), leaf(file.array<uint64_t>(2)),
        labels(file.array<uint16_t>(1)), pos(file.array<uint16_t>(5)),
        costs(file.array<int16_t>(6)), terms(file.array<uint32_t>(3)),
        postings(file.array<uint32_t>(4)), refs(file.array<uint32_t>(7)),
        offsets(file.array<uint32_t>(8)), strings(file.sections[9]) {
    require(file.dimension == 0 && labels.size() >= 2 &&
                tree.ranks.back() + 1 == labels.size() && tree.at(0) &&
                !tree.at(1),
            "invalid LOUDS labels");
    require(leaf.ranks.back() == terms.size() && pos.size() == costs.size() &&
                refs.size() == pos.size(),
            "invalid token columns");
    require(postings.size() >= 2 && postings.front() == 0 &&
                postings.back() == pos.size() &&
                std::is_sorted(postings.begin(), postings.end()),
            "invalid postings");
    require(!offsets.empty() && offsets.front() == 0 &&
                offsets.back() == strings.size() &&
                std::is_sorted(offsets.begin(), offsets.end()),
            "invalid strings");
    for (auto t : terms)
      require(t > 0 && uint64_t(t) + 1 < postings.size(),
              "term outside postings");
    for (auto r : refs)
      require(r >= 0xfffffffeU || uint64_t(r) + 1 < offsets.size(),
              "invalid surface reference");
    for (size_t w = 0; w < leaf.words.size(); ++w)
      require((leaf.words[w] & ~(w < tree.words.size() ? tree.words[w] : 0)) ==
                  0,
              "terminal outside trie");
    require(tree.words.size() * 64 - tree.ranks.back() >= labels.size() - 1,
            "invalid LOUDS shape");
  }
  template <class F>
  size_t prefixes(const std::u16string &reading, size_t start, F callback) const {
    size_t node = 0;
    for (size_t j = start; j < reading.size(); ++j) {
      size_t child = tree.select0(tree.rank(node)) + 1;
      bool found = false;
      for (; tree.at(child); ++child) {
        auto index = tree.rank(child);
        require(index < labels.size(), "invalid label index");
        if (labels[index] == reading[j]) {
          node = child;
          found = true;
          break;
        }
      }
      if (!found)
        return j + 1;
      if (leaf.at(node)) {
        auto term = terms[leaf.rank(node) - 1];
        for (uint32_t t = postings[term]; t < postings[term + 1]; ++t)
          callback(j + 1, t);
      }
    }
    return reading.size() + 1; // EOF is a dependency on the input length.
  }
  template <class F>
  void predictive(const std::u16string &prefix, size_t limit, F callback) const {
    size_t node = 0;
    for (auto c : prefix) {
      size_t child = tree.select0(tree.rank(node)) + 1;
      for (; tree.at(child); ++child)
        if (labels[tree.rank(child)] == c) break;
      if (!tree.at(child)) return;
      node = child;
    }
    // Iterative preorder matches the reference's recursive child order.
    std::vector<size_t> pending{node};
    size_t words = 0;
    while (!pending.empty() && words < limit) {
      node = pending.back(); pending.pop_back();
      if (leaf.at(node)) {
        ++words;
        auto term = terms[leaf.rank(node) - 1];
        for (uint32_t token = postings[term]; token < postings[term + 1]; ++token)
          callback(node, token);
      }
      if (words == limit) break;
      size_t first = tree.select0(tree.rank(node)) + 1, end = first;
      while (tree.at(end)) ++end;
      while (end > first) pending.push_back(--end);
    }
  }
  // Depth-bounded DFS in reference trie order. Keep no dictionary subtree
  // strings; callback sees terminals only. False reports node/token-budget exhaustion.
  template <class F>
  bool completion(const std::u16string &prefix, size_t lookahead,
                  size_t budget, F callback) const {
    size_t node = 0;
    for (auto c : prefix) {
      size_t child = tree.select0(tree.rank(node)) + 1;
      for (; tree.at(child); ++child)
        if (labels[tree.rank(child)] == c) break;
      if (!tree.at(child)) return true;
      node = child;
    }
    struct Frame { size_t node, depth, next; bool visited; };
    std::vector<Frame> stack{{node, 0, 0, false}};
    size_t visited = 0;
    while (!stack.empty()) {
      auto &frame = stack.back();
      if (!frame.visited) {
        if (visited == budget) return false;
        ++visited;
        frame.visited = true;
        if (frame.depth && leaf.at(frame.node)) {
          auto term = terms[leaf.rank(frame.node) - 1];
          for (uint32_t token = postings[term]; token < postings[term + 1]; ++token) {
            if (visited == budget) return false;
            ++visited;
            callback(frame.node, token, frame.depth);
          }
        }
        frame.next = tree.select0(tree.rank(frame.node)) + 1;
      }
      if (frame.depth == lookahead || !tree.at(frame.next)) {
        stack.pop_back();
      } else {
        const auto child = frame.next++;
        const auto depth = frame.depth + 1;
        stack.push_back({child, depth, 0, false});
      }
    }
    return true;
  }
  // Same directional kana variations as the pinned Android LOUDS search.
  // Follow only existing trie edges; never enumerate all possible input
  // strings.
  static bool variation(char16_t from, char16_t to) {
    if (from == to)
      return true;
    constexpr std::u16string_view voiced = u"かきくけこさしすせそたちつてと";
    if (voiced.find(from) != std::u16string_view::npos && to == from + 1)
      return true;
    constexpr std::u16string_view h = u"はひふへほ";
    if (h.find(from) != std::u16string_view::npos &&
        (to == from + 1 || to == from + 2))
      return true;
    constexpr std::u16string_view small = u"あいうえおつやゆよ";
    return small.find(from) != std::u16string_view::npos && to == from - 1;
  }
  struct OmissionState {
    size_t node, position;
    bool changed;
  };
  template <class F>
  size_t omissionPrefixes(const std::u16string &reading, size_t start,
                        std::vector<OmissionState> &pending, F callback) const {
    pending.clear();
    pending.push_back({0, start, false});
    size_t visited = 0, horizon = start;
    while (!pending.empty()) {
      auto state = pending.back();
      pending.pop_back();
      require(++visited <= 2000000,
              "omission traversal limit exceeded (input not truncated)");
      horizon = std::max(horizon, state.position + 1);
      if (state.position == reading.size())
        continue;
      size_t child = tree.select0(tree.rank(state.node)) + 1;
      for (; tree.at(child); ++child) {
        auto index = tree.rank(child);
        require(index < labels.size(), "invalid label index");
        auto label = labels[index];
        if (!variation(reading[state.position], label))
          continue;
        bool changed = state.changed || reading[state.position] != label;
        size_t end = state.position + 1;
        if (leaf.at(child)) {
          auto term = terms[leaf.rank(child) - 1];
          for (uint32_t token = postings[term]; token < postings[term + 1];
               ++token)
            callback(end, token, changed ? child : 0);
        }
        pending.push_back({child, end, changed});
      }
    }
    return horizon;
  }
  std::u16string nodeReading(size_t node) const {
    std::u16string value;
    while (node != 0) {
      value.push_back(labels[tree.rank(node)]);
      node = tree.select1(node + 1 - tree.rank(node));
    }
    std::reverse(value.begin(), value.end());
    return value;
  }
  std::string surface(uint32_t token, const std::u16string &reading,
                      size_t start, size_t end,
                      size_t correctedNode = 0) const {
    uint32_t ref = refs[token];
    if (ref >= 0xfffffffeU) {
      auto s = correctedNode ? nodeReading(correctedNode)
                             : reading.substr(start, end - start);
      if (ref == 0xffffffffU)
        for (auto &c : s)
          if (c >= 0x3041 && c <= 0x3096)
            c += 0x60;
      return utf8(s);
    }
    return std::string(
        reinterpret_cast<const char *>(strings.data() + offsets[ref]),
        offsets[ref + 1] - offsets[ref]);
  }
};
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
  std::vector<std::unique_ptr<Dictionary>> dictionaries;
  Impl(const std::string &dir, const std::vector<std::string> &cats, bool english, bool words)
      : connection(dir) {
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
Engine::Engine(const std::string &dir, const std::vector<std::string> &c, bool english, bool words)
    : impl(std::make_unique<Impl>(dir, c, english, words)) {}
Engine::~Engine() = default;
size_t Engine::mapped_bytes() const {
  size_t n = impl->connection.file.size;
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
      at[i].push_back(nodes.size());
      nodes.push_back(node);
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
  std::unordered_set<std::string> seen;
  while (!heap.empty() && result.candidates.size() < count) {
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
      }
      if (seen.insert(c.text).second)
        result.candidates.push_back(std::move(c));
    } else
      for (size_t id : at[node.end])
        push(id, index,
             state.cost + conn.cost(node.right, nodes[id].left) +
                 nodes[id].cost);
  }
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
    const size_t full_count = result.candidates.size();
    for (const auto &prediction : best) {
      auto text = d.surface(prediction.token, reading, 0, reading.size(), prediction.node);
      if (seen.insert(text).second)
        result.candidates.push_back({text, prediction.score,
            {{text, d.name, 0, uint32_t(reading.size())}}});
    }
    std::inplace_merge(result.candidates.begin(), result.candidates.begin() + full_count,
                       result.candidates.end(), [](const Candidate &a, const Candidate &b) { return a.score < b.score; });
  }
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
