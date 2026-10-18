#include "engine.hpp"
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

std::string json(const std::string &s) {
  static const char hex[] = "0123456789abcdef";
  std::string out = "\"";
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (c < 32) {
      out += "\\u00";
      out += hex[c >> 4];
      out += hex[c & 15];
    } else
      out += c;
  }
  return out + '"';
}
size_t number(const std::string &s) {
  size_t used = 0;
  if (s.empty() || s[0] == '-')
    throw std::runtime_error("invalid positive integer");
  auto n = std::stoull(s, &used);
  if (used != s.size())
    throw std::runtime_error("invalid integer");
  return n;
}
void usage() {
  std::cout << "Sumire C++20 offline conversion CLI\n"
               "  sumire-cli --data DIR [--categories all|none|name,name] "
               "[--nbest 10] READING\n"
               "  sumire-cli --data DIR [options] --stdin < readings.txt\n"
               "  sumire-cli --list-categories\n\n"
               "Each UTF-8 input line produces one JSON object. System "
               "dictionary is always enabled.\n"
               "Categories default to none. Scores include BOS/EOS connection "
               "costs; lower is better.\n"
               "UTF-16 segment ranges refer to the input reading. No network "
               "or Java runtime.\n"
               "--max-states N bounds N-best states (default 200000); "
               "complete=false reports exhaustion.\n"
               "--predict-japanese appends up to 4 system completions (3..16 UTF-16 input, lookahead 3).\n"
               "--prefix-candidates appends system reading-prefix matches with consumed UTF-16 ranges and word costs.\n"
               "--omission enables directional kana modifier omission (default "
               "OFF).\n"
               "--english-reading appends exact kana-to-English entries after Japanese N-best.\n"
               "--english adds input and case variants; casing uses locale-independent Unicode rules.\n"
               "--predict-english returns raw prefix matches (Unicode lowercase, "
               "6/12 readings in trie order, then word-cost sorting; no case variants).\n"
               "--lookup-english returns raw exact English entries; input is case-sensitive.\n"
               "--lookup-english-reading returns raw exact kana-to-English entries, "
               "ranked by word cost; no case variants. Requires english_reading.sud.\n"
               "--lookup returns exact dictionary entries only, retaining "
               "duplicate surfaces/POS.\n"
               "Maximum input: 8192 UTF-16 units; longer input is rejected, "
               "never truncated.\n";
}
int main(int argc, char **argv) {
  try {
    std::string dir;
    std::vector<std::string> categories, readings;
    bool prefix_candidates = false;
    bool japanese_prediction = false;
    bool stream = false, list = false, lookup = false, omission = false, english = false, english_words = false, predict_english = false, english_candidates = false, include_english_reading = false;
    size_t count = 10, limit = 200000;
    for (int i = 1; i < argc; ++i) {
      std::string a = argv[i];
      auto value = [&]() {
        if (i + 1 >= argc)
          throw std::runtime_error("missing value for " + a);
        return std::string(argv[++i]);
      };
      if (a == "--help" || a == "-h") {
        usage();
        return 0;
      } else if (a == "--data")
        dir = value();
      else if (a == "--categories") {
        auto v = value();
        categories.clear();
        if (v == "all")
          categories = sumire::category_names();
        else if (v != "none") {
          std::istringstream in(v);
          std::string n;
          while (std::getline(in, n, ',')) {
            if (n.empty())
              throw std::runtime_error("empty category");
            categories.push_back(n);
          }
          if (v.empty() || v.back() == ',')
            throw std::runtime_error("empty category");
        }
      } else if (a == "--nbest")
        count = number(value());
      else if (a == "--max-states")
        limit = number(value());
      else if (a == "--predict-japanese")
        japanese_prediction = true;
      else if (a == "--prefix-candidates")
        prefix_candidates = true;
      else if (a == "--omission")
        omission = true;
      else if (a == "--english-reading")
        include_english_reading = true;
      else if (a == "--english")
        english_candidates = true;
      else if (a == "--predict-english")
        predict_english = true;
      else if (a == "--lookup-english")
        english_words = true;
      else if (a == "--lookup-english-reading")
        english = true;
      else if (a == "--lookup")
        lookup = true;
      else if (a == "--stdin")
        stream = true;
      else if (a == "--list-categories")
        list = true;
      else if (a == "--") {
        while (++i < argc)
          readings.emplace_back(argv[i]);
        break;
      } else if (a.starts_with("--"))
        throw std::runtime_error("unknown option " + a);
      else
        readings.push_back(a);
    }
    if (list) {
      auto names = sumire::category_names();
      std::cout << "{\"categories\":[";
      for (size_t i = 0; i < names.size(); ++i) {
        if (i)
          std::cout << ',';
        std::cout << json(names[i]);
      }
      std::cout << "]}\n";
      return 0;
    }
    if (english_candidates && predict_english)
      throw std::runtime_error("--english and --predict-english are mutually exclusive");
    if ((predict_english || english_candidates) && (lookup || omission || english || english_words))
      throw std::runtime_error("--predict-english cannot be combined with lookup modes or --omission");
    if (english_words && (lookup || omission || english))
      throw std::runtime_error("--lookup-english cannot be combined with other lookup modes or --omission");
    if (english && (lookup || omission))
      throw std::runtime_error("--lookup-english-reading cannot be combined with --lookup or --omission");
    if (lookup && omission)
      throw std::runtime_error(
          "--omission applies to conversion, not --lookup");
    if (dir.empty())
      throw std::runtime_error("--data DIR is required");
    if (!stream && readings.empty())
      throw std::runtime_error("provide READING or --stdin");
    if (count < 1 || count > 100 || limit < 1 || limit > 2000000)
      throw std::runtime_error("invalid search limits");
    auto start = std::chrono::steady_clock::now();
    sumire::Engine engine(dir, categories, english || include_english_reading, english_words || predict_english || english_candidates);
    sumire::Workspace workspace;
    double load = std::chrono::duration<double, std::milli>(
                      std::chrono::steady_clock::now() - start)
                      .count();
    bool failed = false;
    auto run = [&](const std::string &reading) {
      try {
        auto r = (predict_english || english_candidates) ? engine.predict_english(reading, count, english_candidates) : english_words ? engine.lookup_english(reading, count) : english ? engine.lookup_english_reading(reading, count) : lookup ? engine.lookup(reading, count)
                        : engine.convert(reading, count, limit, omission, nullptr, nullptr, &workspace, prefix_candidates, japanese_prediction);
        std::cout << "{\"reading\":" << json(reading)
                  << ",\"mode\":" << json(english_candidates ? "english" : predict_english ? "english-predict" : english_words ? "english-lookup" : english ? "english-reading-lookup" : lookup ? "lookup" : "convert")
                  << ",\"complete\":" << (r.complete ? "true" : "false")
                  << ",\"load_ms\":" << load
                  << ",\"conversion_ms\":" << r.elapsed_ms
                  << ",\"mapped_bytes\":" << engine.mapped_bytes()
                  << ",\"workspace_cache_bytes\":" << workspace.retained_bytes()
                  << ",\"lattice_nodes\":" << r.lattice_nodes
                  << ",\"expanded_states\":" << r.expanded_states
                  << ",\"candidates\":[";
        for (size_t i = 0; i < r.candidates.size(); ++i) {
          if (i)
            std::cout << ',';
          auto &c = r.candidates[i];
          std::cout << "{\"id\":" << i << ",\"text\":" << json(c.text)
                    << ",\"score\":" << c.score << ",\"segments\":[";
          for (size_t j = 0; j < c.segments.size(); ++j) {
            if (j)
              std::cout << ',';
            auto &s = c.segments[j];
            std::cout << "{\"text\":" << json(s.text)
                      << ",\"dictionary\":" << json(s.dictionary)
                      << ",\"start_utf16\":" << s.start
                      << ",\"length_utf16\":" << s.length << '}';
          }
          std::cout << "],\"bunsetsu_boundaries_utf16\":[";
          for (size_t j = 0; j < c.bunsetsu_boundaries.size(); ++j) {
            if (j) std::cout << ',';
            std::cout << c.bunsetsu_boundaries[j];
          }
          std::cout << "]}";
        }
        std::cout << "]}\n";
      } catch (const std::exception &e) {
        failed = true;
        std::cout << "{\"error\":" << json(e.what()) << "}\n";
      }
      std::cout.flush();
    };
    for (auto &s : readings)
      run(s);
    if (stream) {
      std::string line;
      while (std::getline(std::cin, line)) {
        if (!line.empty() && line.back() == '\r')
          line.pop_back();
        run(line);
      }
      if (std::cin.bad())
        throw std::runtime_error("stdin read failed");
    }
    return failed ? 1 : 0;
  } catch (const std::exception &e) {
    std::cerr << "sumire-cli: " << e.what() << '\n';
    return 1;
  }
}
