#include "system_ngram.hpp"

#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  if (argc == 3 && std::string(argv[1]) == "--real") {
    try {
      sumire::detail::SystemNgram dictionaries(argv[2]);
      if (!dictionaries.available() || dictionaries.rule_count() != 2187 ||
          dictionaries.mapped_bytes() != 57376 + 15207)
        throw std::runtime_error("pinned Android asset totals differ");
      std::cout << "loaded pinned Android v3/v4 assets: "
                << dictionaries.rule_count() << " rules, "
                << dictionaries.mapped_bytes() << " mapped bytes\n";
      return EXIT_SUCCESS;
    } catch (const std::exception &error) {
      std::cerr << error.what() << '\n';
      return EXIT_FAILURE;
    }
  }
  if (argc != 4) {
    std::cerr << "expected --real asset-directory or v3, v4, and corrupt fixture paths\n";
    return EXIT_FAILURE;
  }
  try {
    sumire::detail::PackedSystemNgram v3(argv[1], 3);
    sumire::detail::PackedSystemNgram v4(argv[2], 4);
    if (v3.rule_count() != 1 || v4.rule_count() != 1 ||
        v3.mapped_bytes() == 0 || v4.mapped_bytes() == 0)
      throw std::runtime_error("fixture header mismatch");

    const sumire::detail::NgramFeature neko{"猫", 0};
    const sumire::detail::NgramFeature suki{"好き", 0};
    const sumire::detail::NgramFeature taberu{"食べる", 0};
    const sumire::detail::NgramFeature other{"犬", 0};
    if (!v3.may_match_first_node(neko) ||
        !v3.may_match_first_pair(neko, suki) ||
        v3.may_match_first_pair(neko, other))
      throw std::runtime_error("v3 prefix index mismatch");
    if (!v4.may_match_first_node(taberu) ||
        v4.may_match_first_pair(taberu, neko))
      throw std::runtime_error("v4 prefix index mismatch");

    sumire::detail::NgramScratch scratch;
    const std::vector<sumire::detail::NgramFeature> path{other, neko, suki};
    const std::vector<sumire::detail::NgramFeature> v4_path{other, taberu};
    if (!v3.matches(path, scratch) || !v4.matches(v4_path, scratch) ||
        v3.matches(std::span<const sumire::detail::NgramFeature>(&other, 1), scratch))
      throw std::runtime_error("system n-gram exact match mismatch");

    bool rejected = false;
    try {
      sumire::detail::PackedSystemNgram corrupt(argv[3], 3);
    } catch (const std::exception &) {
      rejected = true;
    }
    if (!rejected)
      throw std::runtime_error("corrupt asset was accepted");

    std::cout << "v3/v4 fixtures, indexes, matching, and corruption checks passed\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}
