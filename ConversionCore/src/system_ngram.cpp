#include "system_ngram.hpp"

#include "engine.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#include <zlib.h>

namespace sumire::detail {
namespace {
constexpr uint32_t kMagic = 0x4a4b4e47;
constexpr size_t kHeaderBytes = 80;
constexpr uint32_t kBlockSize = 16;
constexpr uint32_t kHashEntryBytes = 10;
constexpr uint32_t kWord = 1;
constexpr uint32_t kPos = 2;
constexpr uint32_t kAny = 3;
constexpr uint64_t kLow48 = 0x0000ffffffffffffULL;
constexpr size_t kMaxFileBytes = 64 * 1024 * 1024;
constexpr uint32_t kMaxRules = 1'000'000;
constexpr uint32_t kMaxContexts = 1'000'000;
constexpr uint32_t kMaxKeyBytes = 32768;

void check(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}

uint32_t read_u32(const unsigned char *p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
         (uint32_t(p[3]) << 24);
}

uint64_t read_u48(const unsigned char *p) {
  uint64_t value = 0;
  for (unsigned i = 0; i < 6; ++i)
    value |= uint64_t(p[i]) << (8 * i);
  return value;
}

uint64_t fnv_hash(std::span<const unsigned char> bytes) {
  uint64_t hash = 14695981039346656037ULL;
  for (unsigned char byte : bytes)
    hash = (hash ^ byte) * 1099511628211ULL;
  hash = (hash ^ (hash >> 33)) * uint64_t(-49064778989728563LL);
  hash = (hash ^ (hash >> 33)) * uint64_t(-4265267296055464877LL);
  return hash ^ (hash >> 33);
}

std::optional<int32_t> java_string_hash(std::string_view utf8) {
  uint32_t hash = 0;
  size_t i = 0;
  while (i < utf8.size()) {
    uint32_t codepoint = static_cast<unsigned char>(utf8[i++]);
    size_t continuation = 0;
    uint32_t minimum = 0;
    if (codepoint < 0x80) {
      continuation = 0;
    } else if (codepoint >= 0xc2 && codepoint <= 0xdf) {
      codepoint &= 0x1f;
      continuation = 1;
      minimum = 0x80;
    } else if (codepoint >= 0xe0 && codepoint <= 0xef) {
      codepoint &= 0x0f;
      continuation = 2;
      minimum = 0x800;
    } else if (codepoint >= 0xf0 && codepoint <= 0xf4) {
      codepoint &= 0x07;
      continuation = 3;
      minimum = 0x10000;
    } else {
      return std::nullopt;
    }
    if (continuation > utf8.size() - i)
      return std::nullopt;
    for (size_t j = 0; j < continuation; ++j) {
      uint32_t byte = static_cast<unsigned char>(utf8[i++]);
      if ((byte & 0xc0) != 0x80)
        return std::nullopt;
      codepoint = (codepoint << 6) | (byte & 0x3f);
    }
    if (codepoint < minimum || codepoint > 0x10ffff ||
        (codepoint >= 0xd800 && codepoint <= 0xdfff))
      return std::nullopt;
    if (codepoint < 0x10000) {
      hash = hash * 31 + codepoint;
    } else {
      const uint32_t adjusted = codepoint - 0x10000;
      hash = hash * 31 + (0xd800 | (adjusted >> 10));
      hash = hash * 31 + (0xdc00 | (adjusted & 0x3ff));
    }
  }
  return static_cast<int32_t>(hash);
}

struct Mapping {
  const unsigned char *bytes = nullptr;
  size_t size = 0;

  explicit Mapping(const std::string &path) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0)
      throw std::runtime_error("cannot open system n-gram asset: " + path);
    struct stat st {};
    if (fstat(fd, &st) != 0 || st.st_size < static_cast<off_t>(kHeaderBytes) ||
        uint64_t(st.st_size) > kMaxFileBytes) {
      close(fd);
      throw std::runtime_error("invalid system n-gram file size");
    }
    size = static_cast<size_t>(st.st_size);
    void *mapped = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    const int saved_errno = errno;
    close(fd);
    if (mapped == MAP_FAILED)
      throw std::runtime_error("system n-gram mmap failed: " +
                               std::string(std::strerror(saved_errno)));
    bytes = static_cast<const unsigned char *>(mapped);
  }

  ~Mapping() {
    if (bytes)
      munmap(const_cast<unsigned char *>(bytes), size);
  }
  Mapping(const Mapping &) = delete;
  Mapping &operator=(const Mapping &) = delete;
};

struct DecodedVarint {
  uint32_t value;
  size_t next;
};

DecodedVarint read_varint(std::span<const unsigned char> bytes, size_t pos,
                          size_t end) {
  uint32_t value = 0;
  unsigned shift = 0;
  size_t start = pos;
  while (pos < end && shift <= 28) {
    const unsigned byte = bytes[pos++];
    if (shift == 28 && (byte & 0xf0) != 0)
      throw std::runtime_error("system n-gram varint overflow");
    value |= uint32_t(byte & 0x7f) << shift;
    if ((byte & 0x80) == 0) {
      if (pos - start > 1 && byte == 0)
        throw std::runtime_error("noncanonical system n-gram varint");
      return {value, pos};
    }
    shift += 7;
  }
  throw std::runtime_error("truncated system n-gram varint");
}

void append_varint(std::vector<unsigned char> &out, uint32_t value) {
  while (value >= 0x80) {
    out.push_back(static_cast<unsigned char>((value & 0x7f) | 0x80));
    value >>= 7;
  }
  out.push_back(static_cast<unsigned char>(value));
}

uint64_t pair_key(int64_t first, int64_t second) {
  return (uint64_t(static_cast<uint32_t>(first)) << 32) |
         uint32_t(second);
}
} // namespace

struct PackedSystemNgram::Impl {
  struct HashEntry {
    uint64_t remainder;
    uint32_t record_id;
  };
  struct RuleFeature {
    uint32_t kind;
    int64_t value;
  };

  Mapping mapping;
  uint32_t version = 0;
  uint32_t rules = 0;
  uint32_t contexts = 0;
  uint32_t max_key_bytes = 0;
  uint32_t signature_count = 0;
  uint32_t bucket_count = 0;
  uint32_t bucket_bits = 0;
  uint32_t block_count = 0;
  uint32_t signatures_offset = 0;
  uint32_t contexts_offset = 0;
  uint32_t bucket_offsets_offset = 0;
  uint32_t hash_entries_offset = 0;
  uint32_t block_offsets_offset = 0;
  uint32_t records_offset = 0;
  std::unordered_set<uint32_t> signatures;
  std::array<std::unordered_set<int64_t>, 4> first_nodes;
  std::array<std::unordered_set<uint64_t>, 16> first_pairs;

  explicit Impl(const std::string &path, uint32_t expected_version)
      : mapping(path) {
    validate(expected_version);
    build_prefix_indexes();
  }

  uint32_t u32_at(size_t offset) const {
    check(offset <= mapping.size && mapping.size - offset >= 4,
          "system n-gram offset outside file");
    return read_u32(mapping.bytes + offset);
  }

  uint32_t bucket_start(uint32_t bucket) const {
    return u32_at(bucket_offsets_offset + size_t(bucket) * 4);
  }

  HashEntry hash_entry(uint32_t entry) const {
    const size_t offset = size_t(hash_entries_offset) +
                          size_t(entry) * kHashEntryBytes;
    return {read_u48(mapping.bytes + offset), read_u32(mapping.bytes + offset + 6)};
  }

  uint32_t block_offset(uint32_t block) const {
    return u32_at(block_offsets_offset + size_t(block) * 4);
  }

  void validate(uint32_t expected_version) {
    const auto *b = mapping.bytes;
    const auto size = mapping.size;
    check(read_u32(b) == kMagic, "invalid system n-gram magic");
    version = read_u32(b + 4);
    check(version == expected_version && (version == 3 || version == 4),
          "unsupported system n-gram version");
    rules = read_u32(b + 8);
    contexts = read_u32(b + 12);
    const uint32_t pos_count = read_u32(b + 16);
    signature_count = read_u32(b + 20);
    max_key_bytes = read_u32(b + 24);
    const uint32_t block_size = read_u32(b + 28);
    signatures_offset = read_u32(b + 32);
    contexts_offset = read_u32(b + 36);
    bucket_offsets_offset = read_u32(b + 40);
    hash_entries_offset = read_u32(b + 44);
    block_offsets_offset = read_u32(b + 48);
    records_offset = read_u32(b + 52);
    const uint32_t file_size = read_u32(b + 56);
    bucket_count = read_u32(b + 64);
    block_count = read_u32(b + 68);

    check(file_size == size, "system n-gram file size mismatch");
    check(rules > 0 && rules <= kMaxRules && contexts > 0 &&
              contexts <= kMaxContexts && pos_count > 0 && pos_count <= 255,
          "invalid system n-gram dimensions");
    check(signature_count > 0 && signature_count <= rules &&
              max_key_bytes > 0 && max_key_bytes <= kMaxKeyBytes &&
              block_size == kBlockSize,
          "invalid system n-gram record parameters");
    check(bucket_count >= 256 && bucket_count <= 65536 &&
              (bucket_count & (bucket_count - 1)) == 0,
          "invalid system n-gram bucket count");
    const uint64_t expected_blocks = (uint64_t(rules) + block_size - 1) / block_size;
    check(block_count == expected_blocks, "invalid system n-gram block count");

    const uint64_t expected_contexts = uint64_t(kHeaderBytes) +
                                       uint64_t(signature_count) * 4;
    const uint64_t expected_buckets = (expected_contexts + contexts + 3) & ~uint64_t(3);
    const uint64_t expected_hashes = expected_buckets + uint64_t(bucket_count + 1) * 4;
    const uint64_t expected_block_offsets = expected_hashes + uint64_t(rules) * kHashEntryBytes;
    const uint64_t expected_records = expected_block_offsets + uint64_t(block_count + 1) * 4;
    check(signatures_offset == kHeaderBytes && contexts_offset == expected_contexts &&
              bucket_offsets_offset == expected_buckets &&
              hash_entries_offset == expected_hashes &&
              block_offsets_offset == expected_block_offsets &&
              records_offset == expected_records && records_offset <= size,
          "invalid system n-gram section offsets");
    for (size_t i = static_cast<size_t>(expected_contexts + contexts);
         i < bucket_offsets_offset; ++i)
      check(b[i] == 0, "invalid system n-gram context padding");

    const auto actual_crc = crc32(0, b + kHeaderBytes,
                                  static_cast<uInt>(size - kHeaderBytes));
    check(actual_crc == u32_at(60), "system n-gram checksum mismatch");
    bucket_bits = 0;
    for (uint32_t count = bucket_count; count > 1; count >>= 1)
      ++bucket_bits;

    signatures.reserve(signature_count);
    for (uint32_t i = 0; i < signature_count; ++i) {
      const uint32_t signature = u32_at(signatures_offset + size_t(i) * 4);
      const uint32_t order = signature & 7;
      check((signature >> 13) == 0 && signatures.insert(signature).second,
            "invalid system n-gram signature bits");
      if (version == 3)
        check(order >= 2 && order <= 5, "invalid system n-gram signature order");
      else
        check(order == 1 && ((signature >> 3) & 3) == kWord,
              "invalid system n-gram unigram signature");
      for (uint32_t feature = 0; feature < order; ++feature) {
        const uint32_t kind = (signature >> (3 + feature * 2)) & 3;
        check(kind >= kWord && kind <= kAny,
              "invalid system n-gram feature kind");
      }
    }
    for (uint32_t i = 0; i < contexts; ++i)
      check(b[contexts_offset + i] > 0 && b[contexts_offset + i] <= pos_count,
            "invalid system n-gram context POS");

    uint32_t previous = 0;
    for (uint32_t bucket = 0; bucket <= bucket_count; ++bucket) {
      const uint32_t next = bucket_start(bucket);
      check(next >= previous && next <= rules, "invalid system n-gram bucket offsets");
      if (bucket > 0) {
        uint64_t previous_remainder = 0;
        uint32_t previous_record = 0;
        bool first = true;
        for (uint32_t entry = previous; entry < next; ++entry) {
          const auto current = hash_entry(entry);
          check(current.record_id < rules, "invalid system n-gram record id");
          check(first || current.remainder > previous_remainder ||
                    (current.remainder == previous_remainder &&
                     current.record_id > previous_record),
                "unsorted system n-gram hash bucket");
          previous_remainder = current.remainder;
          previous_record = current.record_id;
          first = false;
        }
      }
      previous = next;
    }
    check(previous == rules, "invalid system n-gram hash entry count");

    previous = 0;
    for (uint32_t block = 0; block <= block_count; ++block) {
      const uint32_t next = block_offset(block);
      check(next >= previous && uint64_t(next) <= size - records_offset,
            "invalid system n-gram block offsets");
      if (block > 0)
        validate_record_block(block - 1, previous, next, signatures);
      previous = next;
    }
    check(uint64_t(records_offset) + previous == size,
          "invalid system n-gram records size");
  }

  std::vector<unsigned char> decode_block_record(
      std::span<const unsigned char> bytes, size_t &position, size_t end,
      std::vector<unsigned char> &previous, bool first) const {
    if (first) {
      const auto decoded = read_varint(bytes, position, end);
      position = decoded.next;
      check(decoded.value > 0 && decoded.value <= max_key_bytes &&
                decoded.value <= end - position,
            "invalid system n-gram first record");
      std::vector<unsigned char> record(bytes.begin() + position,
                                        bytes.begin() + position + decoded.value);
      position += decoded.value;
      return record;
    }
    auto prefix = read_varint(bytes, position, end);
    position = prefix.next;
    auto suffix = read_varint(bytes, position, end);
    position = suffix.next;
    const uint64_t length = uint64_t(prefix.value) + suffix.value;
    check(prefix.value <= previous.size() && length > 0 &&
              length <= max_key_bytes && suffix.value <= end - position,
          "invalid system n-gram front-coded record");
    std::vector<unsigned char> record;
    record.reserve(static_cast<size_t>(length));
    record.insert(record.end(), previous.begin(),
                  previous.begin() + prefix.value);
    record.insert(record.end(), bytes.begin() + position,
                  bytes.begin() + position + suffix.value);
    position += suffix.value;
    return record;
  }

  std::vector<RuleFeature> parse_record(
      std::span<const unsigned char> record,
      const std::unordered_set<uint32_t> &signature_set) const {
    check(record.size() >= 2, "truncated system n-gram rule");
    const uint32_t signature = uint32_t(record[0]) | (uint32_t(record[1]) << 8);
    check(signature_set.contains(signature), "unknown system n-gram record signature");
    const uint32_t order = signature & 7;
    std::vector<RuleFeature> features;
    features.reserve(order);
    size_t position = 2;
    for (uint32_t i = 0; i < order; ++i) {
      const uint32_t kind = (signature >> (3 + i * 2)) & 3;
      if (kind == kWord) {
        const auto length = read_varint(record, position, record.size());
        position = length.next;
        check(length.value > 0 && length.value <= record.size() - position,
              "invalid system n-gram word feature length");
        const std::string_view word(
            reinterpret_cast<const char *>(record.data() + position), length.value);
        const auto hash = java_string_hash(word);
        check(hash.has_value(), "invalid UTF-8 in system n-gram word feature");
        features.push_back({kind, *hash});
        position += length.value;
      } else if (kind == kPos) {
        check(position < record.size(), "truncated system n-gram POS feature");
        features.push_back({kind, record[position++]});
      } else if (kind == kAny) {
        features.push_back({kind, 0});
      } else {
        throw std::runtime_error("unsupported system n-gram feature kind");
      }
    }
    check(position == record.size(), "trailing system n-gram rule bytes");
    return features;
  }

  void validate_record_block(uint32_t block, uint32_t start, uint32_t end,
                             const std::unordered_set<uint32_t> &signatures) {
    const auto bytes = std::span<const unsigned char>(mapping.bytes, mapping.size);
    size_t position = size_t(records_offset) + start;
    const size_t limit = size_t(records_offset) + end;
    const uint32_t count = std::min(kBlockSize, rules - block * kBlockSize);
    std::vector<unsigned char> previous_record;
    for (uint32_t i = 0; i < count; ++i) {
      auto record = decode_block_record(bytes, position, limit, previous_record, i == 0);
      const auto features = parse_record(record, signatures);
      check(!features.empty(), "empty system n-gram rule");
      if (i == 0)
        previous_record = record;
      else
        previous_record = std::move(record);
    }
    check(position == limit, "invalid system n-gram block length");
  }

  std::vector<unsigned char> decode_record(uint32_t record_id) const {
    const uint32_t block = record_id / kBlockSize;
    const uint32_t within = record_id % kBlockSize;
    const auto bytes = std::span<const unsigned char>(mapping.bytes, mapping.size);
    size_t position = size_t(records_offset) + block_offset(block);
    const size_t limit = size_t(records_offset) + block_offset(block + 1);
    std::vector<unsigned char> previous_record;
    for (uint32_t i = 0; i <= within; ++i) {
      auto record = decode_block_record(bytes, position, limit, previous_record, i == 0);
      previous_record = std::move(record);
    }
    return previous_record;
  }

  void build_prefix_indexes() {
    for (uint32_t record_id = 0; record_id < rules; ++record_id) {
      const auto record = decode_record(record_id);
      const auto features = parse_record(record, signatures);
      check(!features.empty(), "invalid system n-gram record while indexing");
      first_nodes[features[0].kind].insert(features[0].value);
      if (version == 3)
        first_pairs[(features[0].kind << 2) | features[1].kind].insert(
            pair_key(features[0].value, features[1].value));
    }

    // Verify the sorted lookup index points to each encoded rule before runtime queries use it.
    for (uint32_t record_id = 0; record_id < rules; ++record_id) {
      const auto record = decode_record(record_id);
      const uint64_t hash = fnv_hash(record);
      const uint32_t bucket = static_cast<uint32_t>(hash >> (64 - bucket_bits));
      const uint64_t remainder = hash & kLow48;
      uint32_t low = bucket_start(bucket), high = bucket_start(bucket + 1);
      bool found = false;
      while (low < high) {
        const uint32_t middle = low + (high - low) / 2;
        const auto entry = hash_entry(middle);
        if (entry.remainder < remainder ||
            (entry.remainder == remainder && entry.record_id < record_id))
          low = middle + 1;
        else
          high = middle;
      }
      for (uint32_t entry_id = low; entry_id < bucket_start(bucket + 1); ++entry_id) {
        const auto entry = hash_entry(entry_id);
        if (entry.remainder != remainder)
          break;
        if (entry.record_id == record_id) {
          found = true;
          break;
        }
      }
      check(found, "unreachable system n-gram record");
    }
  }

  std::optional<int64_t> query_feature(uint32_t kind,
                                       const NgramFeature &feature) const {
    if (kind == kWord) {
      const auto hash = java_string_hash(feature.surface);
      if (!hash)
        return std::nullopt;
      return *hash;
    }
    if (kind == kPos) {
      if (feature.left_context >= contexts)
        return std::nullopt;
      return mapping.bytes[contexts_offset + feature.left_context];
    }
    if (kind == kAny)
      return 0;
    return std::nullopt;
  }

  bool encode_query(uint32_t signature, std::span<const NgramFeature> nodes,
                    size_t start, std::vector<unsigned char> &query) const {
    const uint32_t order = signature & 7;
    if (order > nodes.size() - start)
      return false;
    query.clear();
    query.push_back(static_cast<unsigned char>(signature));
    query.push_back(static_cast<unsigned char>(signature >> 8));
    for (uint32_t i = 0; i < order; ++i) {
      const uint32_t kind = (signature >> (3 + i * 2)) & 3;
      const auto &node = nodes[start + i];
      if (kind == kWord) {
        if (node.surface.empty() || node.surface.size() > max_key_bytes)
          return false;
        append_varint(query, static_cast<uint32_t>(node.surface.size()));
        query.insert(query.end(), node.surface.begin(), node.surface.end());
      } else if (kind == kPos) {
        if (node.left_context >= contexts)
          return false;
        query.push_back(mapping.bytes[contexts_offset + node.left_context]);
      } else if (kind != kAny) {
        return false;
      }
      if (query.size() > max_key_bytes)
        return false;
    }
    return true;
  }

  bool contains(std::span<const unsigned char> query,
                std::vector<unsigned char> &record_buffer) const {
    const uint64_t hash = fnv_hash(query);
    const uint32_t bucket = static_cast<uint32_t>(hash >> (64 - bucket_bits));
    const uint64_t wanted = hash & kLow48;
    uint32_t low = bucket_start(bucket), high = bucket_start(bucket + 1);
    while (low < high) {
      const uint32_t middle = low + (high - low) / 2;
      if (hash_entry(middle).remainder < wanted)
        low = middle + 1;
      else
        high = middle;
    }
    for (uint32_t i = low; i < bucket_start(bucket + 1); ++i) {
      const auto entry = hash_entry(i);
      if (entry.remainder != wanted)
        break;
      record_buffer = decode_record(entry.record_id);
      if (record_buffer.size() == query.size() &&
          std::equal(query.begin(), query.end(), record_buffer.begin()))
        return true;
    }
    return false;
  }

  bool matches(std::span<const NgramFeature> nodes, NgramScratch &scratch) const {
    if (nodes.empty())
      return false;
    if (scratch.query.capacity() < max_key_bytes)
      scratch.query.reserve(max_key_bytes);
    for (size_t start = 0; start < nodes.size(); ++start) {
      for (uint32_t i = 0; i < signature_count; ++i) {
        const uint32_t signature = u32_at(signatures_offset + size_t(i) * 4);
        if (encode_query(signature, nodes, start, scratch.query) &&
            contains(scratch.query, scratch.record))
          return true;
      }
    }
    return false;
  }
};

PackedSystemNgram::PackedSystemNgram(const std::string &path,
                                   uint32_t expected_version)
    : impl_(std::make_unique<Impl>(path, expected_version)) {}
PackedSystemNgram::~PackedSystemNgram() = default;
uint32_t PackedSystemNgram::rule_count() const noexcept { return impl_->rules; }
size_t PackedSystemNgram::mapped_bytes() const noexcept { return impl_->mapping.size; }
bool PackedSystemNgram::may_match_first_node(const NgramFeature &node) const {
  for (uint32_t kind = kWord; kind <= kAny; ++kind) {
    const auto value = impl_->query_feature(kind, node);
    if (value && impl_->first_nodes[kind].contains(*value))
      return true;
  }
  return false;
}
bool PackedSystemNgram::may_match_first_pair(const NgramFeature &first,
                                             const NgramFeature &second) const {
  if (impl_->version != 3)
    return false;
  for (uint32_t first_kind = kWord; first_kind <= kAny; ++first_kind) {
    const auto first_value = impl_->query_feature(first_kind, first);
    if (!first_value)
      continue;
    for (uint32_t second_kind = kWord; second_kind <= kAny; ++second_kind) {
      const auto second_value = impl_->query_feature(second_kind, second);
      if (!second_value)
        continue;
      const auto key = (first_kind << 2) | second_kind;
      if (impl_->first_pairs[key].contains(pair_key(*first_value, *second_value)))
        return true;
    }
  }
  return false;
}
bool PackedSystemNgram::matches(std::span<const NgramFeature> nodes,
                               NgramScratch &scratch) const {
  return impl_->matches(nodes, scratch);
}

SystemNgram::SystemNgram(const std::string &directory) {
  const auto bigram_path = directory + "/system_ngram.dat";
  const auto unigram_path = directory + "/system_ngram_unigram.dat";
  if (std::filesystem::exists(bigram_path))
    bigram_to_fivegram_ = std::make_unique<PackedSystemNgram>(bigram_path, 3);
  if (std::filesystem::exists(unigram_path))
    unigram_ = std::make_unique<PackedSystemNgram>(unigram_path, 4);
}
bool SystemNgram::available() const noexcept {
  return bigram_to_fivegram_ || unigram_;
}
uint32_t SystemNgram::rule_count() const noexcept {
  return (bigram_to_fivegram_ ? bigram_to_fivegram_->rule_count() : 0) +
         (unigram_ ? unigram_->rule_count() : 0);
}
size_t SystemNgram::mapped_bytes() const noexcept {
  return (bigram_to_fivegram_ ? bigram_to_fivegram_->mapped_bytes() : 0) +
         (unigram_ ? unigram_->mapped_bytes() : 0);
}
bool SystemNgram::may_match_first_node(const NgramFeature &node) const {
  return (bigram_to_fivegram_ && bigram_to_fivegram_->may_match_first_node(node)) ||
         (unigram_ && unigram_->may_match_first_node(node));
}
bool SystemNgram::may_match_first_pair(const NgramFeature &first,
                                       const NgramFeature &second) const {
  return bigram_to_fivegram_ &&
         bigram_to_fivegram_->may_match_first_pair(first, second);
}
bool SystemNgram::matches(std::span<const NgramFeature> nodes,
                          NgramScratch &scratch) const {
  return (bigram_to_fivegram_ && bigram_to_fivegram_->matches(nodes, scratch)) ||
         (unigram_ && unigram_->matches(nodes, scratch));
}
} // namespace sumire::detail
