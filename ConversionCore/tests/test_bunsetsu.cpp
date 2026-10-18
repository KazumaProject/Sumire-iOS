#include "bunsetsu.hpp"
#include "c_api.h"
#include <cstdlib>
int main() {
  for (unsigned id = 0; id <= 65535; ++id) {
    bool expected = (12 <= id && id <= 28) || (2590 <= id && id <= 2670) ||
      (577 <= id && id <= 856) || (2390 <= id && id <= 2471) ||
      (1842 <= id && id <= 2195 && (id < 1937 || id > 2040));
    if (sumire::is_bunsetsu_independent(id) != expected) return EXIT_FAILURE;
  }
  uint32_t offset = 99;
  if (sumire_result_bunsetsu_count(nullptr, 0) != 0 ||
      sumire_result_bunsetsu_boundary(nullptr, 0, 0, &offset) != -1 || offset != 99)
    return EXIT_FAILURE;
}
