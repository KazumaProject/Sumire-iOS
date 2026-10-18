#include "mozc_scoring_data.hpp"

#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace sumire::detail {
namespace {
constexpr size_t kMaxAssetBytes = 16 * 1024 * 1024;
constexpr uint32_t kMaxElements = 1'000'000;

void check(bool condition, const char *message) {
  if (!condition)
    throw std::runtime_error(message);
}

uint16_t read_u16(const unsigned char *bytes) {
  return uint16_t(bytes[0]) | (uint16_t(bytes[1]) << 8);
}

uint32_t read_u32(const unsigned char *bytes) {
  return uint32_t(bytes[0]) | (uint32_t(bytes[1]) << 8) |
         (uint32_t(bytes[2]) << 16) | (uint32_t(bytes[3]) << 24);
}

class Mapping {
public:
  const unsigned char *bytes = nullptr;
  size_t size = 0;

  Mapping(const std::string &path, size_t minimum_size) {
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0)
      throw std::runtime_error("cannot open Mozc data asset: " + path);
    struct stat st {};
    if (fstat(fd, &st) != 0 || st.st_size < static_cast<off_t>(minimum_size) ||
        uint64_t(st.st_size) > kMaxAssetBytes) {
      close(fd);
      throw std::runtime_error("invalid Mozc data asset size");
    }
    size = static_cast<size_t>(st.st_size);
    void *mapped = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
    const int saved_errno = errno;
    close(fd);
    if (mapped == MAP_FAILED)
      throw std::runtime_error("Mozc data mmap failed: " +
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

} // namespace

struct MozcScoringData::Impl {
  Mapping segmenter;
  Mapping node_attributes;
  uint32_t left_context_count = 0;
  uint32_t right_context_count = 0;
  uint32_t left_table_size = 0;
  uint32_t right_table_size = 0;
  uint32_t bit_array_size = 0;
  uint32_t boundary_data_size = 0;
  uint32_t attribute_count = 0;
  size_t left_table_offset = 32;
  size_t right_table_offset = 0;
  size_t bit_array_offset = 0;
  size_t boundary_data_offset = 0;
  size_t attribute_data_offset = 12;

  explicit Impl(const std::string &directory)
      : segmenter(directory + "/mozc/segmenter.dat", 32),
        node_attributes(directory + "/mozc/node_attribute_by_lid.dat", 12) {
    validate_segmenter();
    validate_attributes();
  }

  void validate_segmenter() {
    const auto *bytes = segmenter.bytes;
    check(std::memcmp(bytes, "MSGM", 4) == 0, "invalid Mozc segmenter magic");
    check(read_u32(bytes + 4) == 1, "unsupported Mozc segmenter version");
    left_context_count = read_u32(bytes + 8);
    right_context_count = read_u32(bytes + 12);
    left_table_size = read_u32(bytes + 16);
    right_table_size = read_u32(bytes + 20);
    bit_array_size = read_u32(bytes + 24);
    boundary_data_size = read_u32(bytes + 28);
    check(left_context_count > 0 && left_context_count <= kMaxElements &&
              right_context_count > 0 && right_context_count <= kMaxElements &&
              left_table_size > 0 && left_table_size <= kMaxElements &&
              right_table_size > 0 && right_table_size <= kMaxElements &&
              bit_array_size > 0 && bit_array_size <= kMaxAssetBytes &&
              boundary_data_size > 0 && boundary_data_size <= kMaxElements,
          "invalid Mozc segmenter dimensions");

    right_table_offset = left_table_offset + uint64_t(left_table_size) * 2;
    bit_array_offset = right_table_offset + uint64_t(right_table_size) * 2;
    boundary_data_offset = bit_array_offset + bit_array_size;
    const uint64_t expected_size = boundary_data_offset +
                                   uint64_t(boundary_data_size) * 2;
    check(expected_size == segmenter.size,
          "Mozc segmenter length differs from its header");
    check(uint64_t(left_context_count) * right_context_count <=
              uint64_t(bit_array_size) * 8,
          "Mozc segmenter boundary matrix is truncated");

    for (uint32_t i = 0; i < left_table_size; ++i)
      check(read_u16(bytes + left_table_offset + size_t(i) * 2) <
                left_context_count,
            "Mozc segmenter left table value is out of range");
    for (uint32_t i = 0; i < right_table_size; ++i)
      check(read_u16(bytes + right_table_offset + size_t(i) * 2) <
                right_context_count,
            "Mozc segmenter right table value is out of range");
  }

  void validate_attributes() {
    const auto *bytes = node_attributes.bytes;
    check(std::memcmp(bytes, "MNAT", 4) == 0,
          "invalid Mozc node-attribute magic");
    check(read_u32(bytes + 4) == 1,
          "unsupported Mozc node-attribute version");
    attribute_count = read_u32(bytes + 8);
    check(attribute_count > 0 && attribute_count <= kMaxElements,
          "invalid Mozc node-attribute dimensions");
    check(12ULL + uint64_t(attribute_count) * 4 == node_attributes.size,
          "Mozc node-attribute length differs from its header");
  }

  int32_t prefix_penalty(uint16_t left_context) const {
    const uint64_t index = uint64_t(left_context) * 2;
    check(index < boundary_data_size,
          "Mozc prefix-penalty context is out of range");
    return read_u16(segmenter.bytes + boundary_data_offset + size_t(index) * 2);
  }

  int32_t suffix_penalty(uint16_t right_context) const {
    const uint64_t index = uint64_t(right_context) * 2 + 1;
    check(index < boundary_data_size,
          "Mozc suffix-penalty context is out of range");
    return read_u16(segmenter.bytes + boundary_data_offset + size_t(index) * 2);
  }
};

MozcScoringData::MozcScoringData(const std::string &directory)
    : impl_(std::make_unique<Impl>(directory)) {}
MozcScoringData::~MozcScoringData() = default;

int32_t MozcScoringData::prefix_penalty(uint16_t left_context) const {
  return impl_->prefix_penalty(left_context);
}

int32_t MozcScoringData::suffix_penalty(uint16_t right_context) const {
  return impl_->suffix_penalty(right_context);
}

uint32_t MozcScoringData::attributes(uint16_t left_context) const noexcept {
  if (left_context >= impl_->attribute_count)
    return 0;
  return read_u32(impl_->node_attributes.bytes + impl_->attribute_data_offset +
                  size_t(left_context) * 4);
}

size_t MozcScoringData::mapped_bytes() const noexcept {
  return impl_->segmenter.size + impl_->node_attributes.size;
}

} // namespace sumire::detail
