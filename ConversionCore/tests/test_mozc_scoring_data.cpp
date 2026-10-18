#include "mozc_scoring_data.hpp"

#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>

int main(int argc, char **argv) {
  if (argc != 3 || (std::string(argv[1]) != "--fixture" &&
                    std::string(argv[1]) != "--real")) {
    std::cerr << "expected --fixture|--real dictionary-directory\n";
    return EXIT_FAILURE;
  }
  try {
    const bool real = std::string(argv[1]) == "--real";
    sumire::detail::MozcScoringData data(argv[2]);
    if (real) {
      if (data.mapped_bytes() != 21'592 + 10'700 ||
          data.prefix_penalty(100) != 2'001 ||
          data.suffix_penalty(1'851) != 300 ||
          data.attributes(16) != 1 || data.attributes(0) != 0)
        throw std::runtime_error("pinned Android Mozc asset values differ");
      std::cout << "loaded pinned Mozc scoring assets: "
                << data.mapped_bytes() << " mapped bytes\n";
    } else {
      if (data.mapped_bytes() != 32 + 3 * 2 + 3 * 2 + 1 + 8 * 2 +
                                    12 + 3 * 4 ||
          data.prefix_penalty(2) != 30 || data.suffix_penalty(2) != 31 ||
          data.attributes(1) != 1 || data.attributes(99) != 0)
        throw std::runtime_error("synthetic Mozc scoring values differ");
      std::cout << "synthetic Mozc scoring assets parsed\n";
    }
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}
