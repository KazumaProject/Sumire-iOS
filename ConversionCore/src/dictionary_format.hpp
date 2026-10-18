#pragma once
// Shared validated runtime dictionary mapping; conversion and browsing use identical decoding.
#include "engine.hpp"
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
namespace sumire::detail {
inline void require(bool b, const char *message) {
  if (!b)
    throw std::runtime_error(message);
}
inline uint32_t u32(const unsigned char *p) {
  uint32_t v;
  std::memcpy(&v, p, 4);
  return v;
}
inline uint64_t u64(const unsigned char *p) {
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
} // namespace sumire::detail
