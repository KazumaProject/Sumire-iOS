#include "engine.hpp"
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <stdexcept>
#include <unistd.h>
using namespace sumire;
static void check(bool value) { if (!value) throw std::runtime_error("category resolution failed"); }
int main() {
  char pattern[] = "/tmp/sumire-release-categories-XXXXXX";
  const auto temp = mkdtemp(pattern);
  if (!temp) return 1;
  const std::string dir(temp);
  try {
    const auto legacy = category_names();
    check(legacy.size() == 30 && legacy[12] == "person");
    check(resolve_category_names(dir, legacy) == legacy);
    std::ofstream(dir + "/release-categories-v1.7.277") << "v1.7.277\n";
    auto person = resolve_category_names(dir, {"person", "actor"});
    check(person.size() == 29);
    check(std::find(person.begin(), person.end(), "actor") != person.end());
    check(std::find(person.begin(), person.end(), "surname_origin_foreign") != person.end());
    check(resolve_category_names(dir, {"facility"}).size() == 59);
    check(resolve_category_names(dir, {"term"}).size() == 15);
    check(resolve_category_names(dir, {"event"}).size() == 6);
    check(resolve_category_names(dir, {"character"}).size() == 9);
    check(resolve_category_names(dir, {"character"}, false) == std::vector<std::string>{"character"});
    check(resolve_category_names(dir, {"work_anime", "character"}).size() == 10);
    const std::set<std::string> demographic_leaves = {
        "media_demographic/audience/shonen",
        "media_demographic/audience/seinen",
        "media_demographic/audience/shojo",
        "media_demographic/audience/josei",
        "media_demographic/audience/kids",
        "media_demographic/audience/mixed",
        "media_demographic/audience/unspecified",
        "media_demographic/resolution/source_unverified",
    };
    for (const auto &family : legacy) {
      std::set<std::string> resolved_demographics;
      for (const auto &id : resolve_category_names(dir, {family})) {
        if (id.starts_with("media_demographic/")) resolved_demographics.insert(id);
      }
      const bool expands_demographics = family == "character" || family.starts_with("work_");
      check(resolved_demographics == (expands_demographics ? demographic_leaves : std::set<std::string>{}));
    }
    auto all = resolve_category_names(dir, legacy);
    auto release = release_category_names();
    std::sort(all.begin(), all.end()); std::sort(release.begin(), release.end());
    check(all == release && all.size() == 143);
    for (const auto &invalid : {"../system", "/system", "facility//religious/shrine", "facility/../system"}) {
      bool rejected = false;
      try { (void)resolve_category_names(dir, {invalid}); } catch (...) { rejected = true; }
      check(rejected);
    }
    std::filesystem::remove_all(dir);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << '\n';
    std::filesystem::remove_all(dir);
    return 1;
  }
}
