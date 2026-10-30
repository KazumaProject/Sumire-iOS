#include "engine.hpp"
#include <cstdlib>
#include <iostream>
#include <stdexcept>
using namespace sumire;
void check(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
void equal(const Result &a, const Result &b) {
  check(a.complete == b.complete && a.lattice_nodes == b.lattice_nodes &&
        a.expanded_states == b.expanded_states, "search metrics changed");
  check(a.candidates.size() == b.candidates.size(), "candidate count changed");
  for (size_t i = 0; i < a.candidates.size(); ++i) {
    const auto &x = a.candidates[i], &y = b.candidates[i];
    check(x.text == y.text && x.score == y.score && x.bunsetsu_boundaries == y.bunsetsu_boundaries &&
          x.standalone_unigram_matched == y.standalone_unigram_matched &&
          x.is_reading_prefix == y.is_reading_prefix &&
          x.presentation_kind == y.presentation_kind &&
          x.system_ngram_matched == y.system_ngram_matched && x.classified_categories == y.classified_categories &&
          x.segments.size() == y.segments.size(), "candidate order/surface/score/path changed");
    for (size_t j = 0; j < x.segments.size(); ++j) {
      const auto &p = x.segments[j], &q = y.segments[j];
      check(p.text == q.text && p.dictionary == q.dictionary && p.start == q.start && p.length == q.length &&
            p.left_context_id == q.left_context_id && p.right_context_id == q.right_context_id,
            "candidate UTF16 range/dictionary changed");
    }
  }
}
void learning_metadata(const Engine &engine) {
  auto a = engine.personal_dictionary({{"あいあ", "AIA", 0, -50000, false, true, 1, 2}});
  auto b = engine.personal_dictionary({{"あいあ", "AIA", 0, -50000, false, true, 2, 2}});
  check(!a->equivalent(*b), "endpoint-only changes must replace the overlay");
  auto copied = engine.personal_dictionary({{"あいあ", "AIA", 0, -50000, false, true, 1, 2}});
  check(a->equivalent(*copied), "identical metadata overlay not equivalent");
  Workspace workspace;
  auto result = engine.convert("あいあ", 100, 200000, false, nullptr, a.get(), &workspace);
  check(!result.candidates.empty() && result.candidates.front().text == "AIA", "lower-cost learned duplicate did not win");
  const auto &segments = result.candidates.front().segments;
  check(segments.size() == 1 && segments[0].dictionary == "learning" &&
        segments[0].left_context_id == 1 && segments[0].right_context_id == 2,
        "learned duplicate path lost endpoint metadata");
  auto changed = engine.convert("あいあ", 100, 200000, false, nullptr, b.get(), &workspace);
  equal(changed, engine.convert("あいあ", 100, 200000, false, nullptr, b.get()));
  check(changed.reused_search_rows == 0, "endpoint-only change reused stale graph rows");
  // Fixture MATRIX[0][2] + MATRIX[2][0] is 60, versus 50 for l=1/r=2.
  check(changed.candidates.front().score - result.candidates.front().score == 10,
        "independent endpoint IDs did not affect connection cost");
  auto costlier = engine.personal_dictionary({{"あいあ", "AIA", 0, 50000, false, true, 1, 2}});
  auto ordinary = engine.convert("あいあ", 100, 200000, false, nullptr, costlier.get());
  bool found = false;
  for (const auto &candidate : ordinary.candidates) if (candidate.text == "AIA") {
    check(candidate.score < 50000 && candidate.segments.front().dictionary != "learning",
          "costlier learned row overrode the lower-cost graph path");
    found = true;
  }
  check(found, "ordinary duplicate candidate missing");
  bool rejected = false;
  try { engine.personal_dictionary({{"あ", "bad", 0, 1, false, true, 1, 3}}); }
  catch (const std::exception &) { rejected = true; }
  check(rejected, "out-of-matrix metadata endpoint accepted");
}
int main(int argc, char **argv) {
 try {
  if (argc == 3 && std::string(argv[2]) == "--typed-sources") {
    Engine unique(argv[1], {"character"}, false, false, true, false, {"character"});
    Engine duplicate(argv[1], {"character", "character"}, false, false, true, false, {"character", "character"});
    equal(unique.convert("あい", 20), duplicate.convert("あい", 20));
    check(unique.mapped_bytes() == duplicate.mapped_bytes(), "duplicate typed source was mapped twice");
    const auto result = unique.convert("あい", 20);
    bool leaf = false, aggregate = false;
    for (const auto &candidate : result.candidates) {
      if (candidate.text == "SOURCE-LEAF") leaf = candidate.segments.front().dictionary == "character";
      if (candidate.text == "SOURCE-AGG") aggregate = candidate.segments.front().dictionary == "legacy_aggregates/character";
    }
    check(leaf && aggregate, "overlapping raw IDs lost their typed identity");
    bool rejected = false;
    try { Engine invalid(argv[1], {}, false, false, true, false, {"../character"}); }
    catch (...) { rejected = true; }
    check(rejected, "invalid typed aggregate ID accepted");
    return 0;
  }
  check(argc == 2, "dictionary directory required");
  Engine engine(argv[1], {});
  learning_metadata(engine);
  Workspace workspace;
  size_t hits = 0;
  auto run = [&](const std::string &reading, bool omission, bool prefix, bool prediction,
                 size_t count, size_t limit, const PersonalDictionary *personal = nullptr,
                 const PersonalDictionary *learning = nullptr) {
    auto actual = engine.convert(reading,count,limit,omission,personal,learning,&workspace,prefix,prediction);
    auto fresh = engine.convert(reading,count,limit,omission,personal,learning,nullptr,prefix,prediction);
    equal(actual,fresh);
    hits += actual.reused_search_rows;
    check(workspace.retained_bytes() <= 4 * 1024 * 1024, "retained cache budget exceeded");
    return actual;
  };
  auto kana = run("が",false,true,true,20,200000);
  bool half_found = false;
  for (const auto &candidate : kana.candidates) {
    if (candidate.text == "ｶﾞ" && candidate.segments.empty()) {
      check(candidate.presentation_kind == CandidatePresentationKind::half_width,
            "half-width kana origin lost");
      half_found = true;
    }
  }
  check(half_found, "half-width kana candidate missing");
  for (bool omission : {false,true}) {
    for (const std::string &s : {"あ", "あい", "あいあ", "あいあい", "あいあいあ", "あいあい", "あいあ", "あああ", "あああ",
                               "😀あいあい", "😁あいあい", "があい", "かあい", "👩‍💻あい", "👩‍💻あ",
                               "し", "しろ", "しろい", "しろ", ""})
      run(s,omission,true,true,20,200000);
  }
  check(hits > 0, "no dictionary search rows reused");
  run("あいあい",false,true,true,20,200000);
  check(run("あいあい",false,true,true,20,200000).reused_search_rows > 0,"identical input not reused");
  check(run("あいあい",true,true,true,20,200000).reused_search_rows == 0,"omission not invalidated");
  check(run("あいあい",true,false,true,20,200000).reused_search_rows == 0,"prefix not invalidated");
  check(run("あいあい",true,false,false,20,200000).reused_search_rows == 0,"prediction not invalidated");
  check(run("あいあい",true,false,false,10,200000).reused_search_rows == 0,"count not invalidated");
  check(run("あいあい",true,false,false,10,1).reused_search_rows == 0,"budget not invalidated");
  auto user = engine.personal_dictionary({{"あい","Custom",1,-5000}});
  check(run("あいあい",false,true,true,20,200000,user.get()).reused_search_rows == 0,"overlay not invalidated");
  run("あいあいあ",false,true,true,20,200000,user.get());
  auto learned = engine.personal_dictionary({{"あいあいあ","Learned",0,-20000,true,true}});
  check(run("あいあいあ",false,true,true,20,200000,user.get(),learned.get()).reused_search_rows == 0,"learning not invalidated");
  user.reset(); learned.reset();
  check(run("あいあいあ",false,true,true,20,200000).reused_search_rows == 0,"removed overlay not invalidated");
  workspace.purge();
  check(workspace.retained_bytes() == 0,"purge did not release cache");
  check(run("あいあいあ",false,true,true,20,200000).reused_search_rows == 0,"purged cache reused");
  Engine other(argv[1], {"medical"});
  auto changed = other.convert("あいあいあ",20,200000,false,nullptr,nullptr,&workspace,true,true);
  equal(changed, other.convert("あいあいあ",20,200000,false,nullptr,nullptr,nullptr,true,true));
  check(changed.reused_search_rows == 0,"dictionary generation not invalidated");
  std::cout << "reused_search_rows=" << hits << '\n';
 } catch (const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
