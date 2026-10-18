#pragma once
#include <cstdint>
namespace sumire {
// Sumire dev 9506a0b FindPath.isIndependentWord. These POS ranges select
// display boundaries; they are not Mozc lattice boundary constraints.
constexpr bool is_bunsetsu_independent(uint16_t left_id) noexcept {
  return (left_id >= 12 && left_id <= 28) ||
         (left_id >= 2590 && left_id <= 2670) ||
         (left_id >= 577 && left_id <= 856) ||
         (left_id >= 2390 && left_id <= 2471) ||
         (left_id >= 1842 && left_id <= 2195 &&
          !(left_id >= 1937 && left_id <= 2040));
}
} // namespace sumire
