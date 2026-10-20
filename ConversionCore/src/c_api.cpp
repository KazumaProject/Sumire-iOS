#include "c_api.h"
#include "engine.hpp"
#include <algorithm>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>

struct Snapshot {
  sumire::Result value;
  uint64_t generation;
  uint32_t length;
};
struct sumire_engine {
  std::shared_ptr<sumire::Engine> value;
};
struct sumire_session {
  sumire::Workspace workspace;
  std::shared_ptr<sumire::Engine> engine;
  std::shared_ptr<const Snapshot> latest;
  std::shared_ptr<const sumire::PersonalDictionary> personal;
  std::shared_ptr<const sumire::PersonalDictionary> learned;
  uint64_t generation = 0;
  bool has_generation = false;
};
struct sumire_result {
  std::shared_ptr<const Snapshot> snapshot;
};
namespace {
void check(bool condition, const char *message) {
  if (!condition)
    throw std::invalid_argument(message);
}
void message(char *error, size_t size, const char *text) noexcept {
  if (error && size) {
    size_t n = std::min(size - 1, std::strlen(text));
    std::memcpy(error, text, n);
    error[n] = 0;
  }
}
template <class F> int guarded(char *error, size_t size, F f) noexcept {
  message(error, size, "");
  try {
    f();
    return 0;
  } catch (const std::exception &e) {
    message(error, size, e.what());
    return -1;
  } catch (...) {
    message(error, size, "unknown core error");
    return -1;
  }
}
sumire_string string(const std::string &s) { return {s.data(), s.size()}; }
} // namespace
extern "C" {
uint16_t sumire_context_id_for_pos(int32_t index) {
  static constexpr uint16_t ids[] = {1851, 578,  2194, 12,   29,   433,
                                     2589, 2591, 2594, 2642, 2657, 1};
  return index >= 0 && index < 12 ? ids[index] : ids[0];
}
int sumire_session_set_personal(sumire_session *session,
                                const sumire_personal_entry *entries,
                                size_t count, char *error, size_t size) {
  return guarded(error, size, [&] {
    check(session && (entries || count == 0),
          "null personal dictionary argument");
    check(count <= 100000, "too many personal entries");
    std::vector<sumire::PersonalEntry> words;
    size_t total = 0;
    for (size_t i = 0; i < count; ++i) {
      const auto &e = entries[i];
      check(e.kind <= 1 && e.context_id <= 65535,
            "invalid personal entry kind or context");
      check(e.reading.data && e.text.data, "null personal text");
      check(e.reading.size <= 32768 && e.text.size <= 65536,
            "personal entry too long");
      total += e.reading.size + e.text.size;
      check(total <= 16 * 1024 * 1024, "personal text budget exceeded");
      words.push_back({std::string(e.reading.data, e.reading.size),
                       std::string(e.text.data, e.text.size),
                       uint16_t(e.context_id), e.score, e.kind == 1});
    }
    auto replacement = session->engine->personal_dictionary(std::move(words));
    if (!session->personal || !session->personal->equivalent(*replacement))
      session->personal = std::move(replacement);
    session->latest.reset();
  });
}
int sumire_session_set_learning(sumire_session *session,
                                const sumire_personal_entry *entries,
                                size_t count, char *error, size_t size) {
  return guarded(error, size, [&] {
    check(session && (entries || count == 0),
          "null personal dictionary argument");
    check(count <= 100, "too many personal entries");
    std::vector<sumire::PersonalEntry> words;
    size_t total = 0;
    for (size_t i = 0; i < count; ++i) {
      const auto &e = entries[i];
      check(e.kind == 2 && e.context_id == 0,
            "invalid personal entry kind or context");
      check(e.reading.data && e.text.data, "null personal text");
      check(e.reading.size <= 32768 && e.text.size <= 65536,
            "personal entry too long");
      total += e.reading.size + e.text.size;
      check(total <= 16 * 1024 * 1024, "personal text budget exceeded");
      words.push_back({std::string(e.reading.data, e.reading.size),
                       std::string(e.text.data, e.text.size),
                       uint16_t(e.context_id), e.score, true, true});
    }
    auto replacement = session->engine->personal_dictionary(std::move(words));
    if (!session->learned || !session->learned->equivalent(*replacement))
      session->learned = std::move(replacement);
    session->latest.reset();
  });
}
uint32_t sumire_abi_version(void) { return 1; }
size_t sumire_category_count(void) { return 30; }
const char *sumire_category_name(size_t index) {
  try {
    static const auto names = sumire::category_names();
    return index < names.size() ? names[index].c_str() : nullptr;
  } catch (...) {
    return nullptr;
  }
}
int sumire_engine_open(const char *directory, uint32_t mask,
                       sumire_engine **out, char *error, size_t size) {
  return sumire_engine_open_with_dictionaries(directory, mask, 0, out, error, size);
}
int sumire_engine_open_with_dictionaries(const char *directory, uint32_t mask,
                                        uint32_t flags, sumire_engine **out,
                                        char *error, size_t size) {
  if (out) *out = nullptr;
  return guarded(error, size, [&] {
    check(out && directory, "null engine argument");
    check((flags & ~uint32_t(7)) == 0, "unknown dictionary flags");
    check((mask >> 30) == 0, "unknown category mask");
    std::vector<std::string> categories;
    auto names = sumire::category_names();
    for (size_t i = 0; i < names.size(); ++i)
      if (mask & (uint32_t(1) << i))
        categories.push_back(names[i]);
    auto e = std::make_unique<sumire_engine>();
    e->value = std::make_shared<sumire::Engine>(directory, categories, (flags & 2) != 0, (flags & 1) != 0, (flags & 4) == 0);
    *out = e.release();
  });
}
void sumire_engine_close(sumire_engine *engine) { delete engine; }
int sumire_engine_has_standalone_priority(const sumire_engine *engine) {
  return engine && engine->value->standalone_priority_available() ? 1 : 0;
}
int sumire_session_create(sumire_engine *engine, sumire_session **out,
                          char *error, size_t size) {
  if (out)
    *out = nullptr;
  return guarded(error, size, [&] {
    check(out && engine, "null session argument");
    auto s = std::make_unique<sumire_session>();
    s->engine = engine->value;
    *out = s.release();
  });
}
void sumire_session_destroy(sumire_session *session) { delete session; }
int sumire_session_update(sumire_session *session,
                          const sumire_request *request, sumire_result **out,
                          char *error, size_t size) {
  if (out)
    *out = nullptr;
  return guarded(error, size, [&] {
    check(out && session && request, "null update argument");
    check(request->reading || request->reading_bytes == 0, "null reading");
    check((request->flags & ~uint32_t(31)) == 0 &&
          ((request->flags & 16) == 0 || (request->flags & 8) == 0) &&
          ((request->flags & 2) == 0 || request->flags == 2), "unsupported or incompatible conversion flags");
    check(!session->has_generation || request->generation > session->generation,
          "stale generation");
    check(request->reading_bytes <= 32768,
          "reading byte limit exceeded (not truncated)");
    std::string reading(request->reading ? request->reading : "",
                        request->reading_bytes);
    auto units = sumire::utf16(reading);
    check(request->edit_start_utf16 <= units.size(),
          "edit start outside reading");
    if (request->edit_start_utf16 < units.size())
      check(units[request->edit_start_utf16] < 0xdc00 ||
                units[request->edit_start_utf16] > 0xdfff,
            "edit start splits surrogate pair");
    if ((request->flags & 2) != 0) session->workspace.purge();
    auto snapshot = std::make_shared<Snapshot>();
    snapshot->value = (request->flags & 2) != 0
        ? session->engine->predict_english(reading, request->candidate_count, true, session->personal.get(), session->learned.get())
        : session->engine->convert(
        reading, request->candidate_count, request->max_states,
        (request->flags & 1) != 0, session->personal.get(), session->learned.get(), &session->workspace, (request->flags & 4) != 0, (request->flags & 8) != 0, (request->flags & 16) != 0);
    snapshot->generation = request->generation;
    snapshot->length = uint32_t(units.size());
    auto result = std::make_unique<sumire_result>();
    result->snapshot = snapshot;
    session->latest = std::move(snapshot);
    session->generation = request->generation;
    session->has_generation = true;
    *out = result.release();
  });
}
void sumire_result_destroy(sumire_result *result) { delete result; }
size_t sumire_result_count(const sumire_result *result) {
  return result ? result->snapshot->value.candidates.size() : 0;
}
int sumire_result_candidate(const sumire_result *result, size_t index,
                            sumire_candidate *out) {
  if (!result || !out || index >= sumire_result_count(result))
    return -1;
  const auto &c = result->snapshot->value.candidates[index];
  // Kana auxiliaries have no dictionary path, but replace the complete typed
  // reading. Keep their range independent of output width (e.g. ガ -> ｶﾞ).
  uint32_t consumed = c.segments.empty() ? result->snapshot->length : 0;
  for (const auto &segment : c.segments)
    consumed = std::max(consumed, segment.start + segment.length);
  *out = {index, string(c.text), c.score,
          0, consumed, c.segments.size()};
  return 0;
}
int sumire_result_segment(const sumire_result *result, size_t candidate,
                          size_t index, sumire_segment *out) {
  if (!result || !out || candidate >= sumire_result_count(result))
    return -1;
  const auto &segments = result->snapshot->value.candidates[candidate].segments;
  if (index >= segments.size())
    return -1;
  const auto &s = segments[index];
  *out = {string(s.text), string(s.dictionary), s.start, s.length};
  return 0;
}
size_t sumire_result_category_count(const sumire_result *result, size_t candidate) {
  return result && candidate < sumire_result_count(result)
      ? result->snapshot->value.candidates[candidate].classified_categories.size() : 0;
}
int sumire_result_category(const sumire_result *result, size_t candidate,
                           size_t index, sumire_string *out) {
  if (!out || index >= sumire_result_category_count(result, candidate)) return -1;
  *out = string(result->snapshot->value.candidates[candidate].classified_categories[index]);
  return 0;
}
size_t sumire_result_bunsetsu_count(const sumire_result *result, size_t candidate) {
  return result && candidate < sumire_result_count(result)
      ? result->snapshot->value.candidates[candidate].bunsetsu_boundaries.size() : 0;
}
int sumire_result_bunsetsu_boundary(const sumire_result *result, size_t candidate,
                                   size_t index, uint32_t *out_utf16) {
  if (!out_utf16 || index >= sumire_result_bunsetsu_count(result, candidate)) return -1;
  *out_utf16 = result->snapshot->value.candidates[candidate].bunsetsu_boundaries[index];
  return 0;
}
int sumire_result_search_rows(const sumire_result *result, size_t *reused, size_t *searched) {
  if (!result || !reused || !searched) return -1;
  *reused = result->snapshot->value.reused_search_rows;
  *searched = result->snapshot->value.searched_rows;
  return 0;
}
int sumire_result_metrics(const sumire_result *result, sumire_metrics *out) {
  if (!result || !out)
    return -1;
  const auto &s = *result->snapshot;
  *out = {s.generation, s.value.elapsed_ms, s.value.lattice_nodes,
          s.value.expanded_states, s.value.complete ? 1 : 0};
  return 0;
}
int sumire_session_commit(sumire_session *session, uint64_t generation,
                          uint64_t candidate, char *error, size_t size) {
  return guarded(error, size, [&] {
    check(session && session->latest, "no current result");
    check(generation == session->latest->generation, "stale commit");
    check(candidate < session->latest->value.candidates.size(),
          "unknown candidate ID");
    session->latest.reset();
  });
}
void sumire_session_reset(sumire_session *session) {
  if (session)
    session->latest.reset();
}
size_t sumire_session_cache_bytes(const sumire_session *session) {
  return session ? session->workspace.retained_bytes() : 0;
}
void sumire_session_purge_cache(sumire_session *session) {
  if (session) session->workspace.purge();
}
}
