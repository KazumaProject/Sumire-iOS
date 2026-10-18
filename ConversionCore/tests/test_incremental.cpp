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
          x.standalone_unigram_matched == y.standalone_unigram_matched && x.classified_categories == y.classified_categories &&
          x.segments.size() == y.segments.size(), "candidate order/surface/score/path changed");
    for (size_t j = 0; j < x.segments.size(); ++j) {
      const auto &p = x.segments[j], &q = y.segments[j];
      check(p.text == q.text && p.dictionary == q.dictionary && p.start == q.start && p.length == q.length,
            "candidate UTF16 range/dictionary changed");
    }
  }
}
int main(int argc, char **argv) {
 try {
  check(argc == 2, "dictionary directory required");
  Engine engine(argv[1], {});
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
