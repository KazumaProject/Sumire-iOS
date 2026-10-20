#include "c_api.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x)                                                               \
  do {                                                                         \
    if (!(x)) {                                                                \
      fprintf(stderr, "line %d: %s\n", __LINE__, #x);                          \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)
static int same_string(sumire_string a, sumire_string b) {
  return a.size == b.size && (!a.size || memcmp(a.data, b.data, a.size) == 0);
}
static void compare_results(sumire_result *actual, sumire_result *fresh) {
  sumire_metrics actual_metrics, fresh_metrics;
  CHECK(sumire_result_metrics(actual,&actual_metrics) == 0 && sumire_result_metrics(fresh,&fresh_metrics) == 0);
  CHECK(actual_metrics.complete == fresh_metrics.complete && actual_metrics.generation == fresh_metrics.generation);
  CHECK(sumire_result_count(actual) == sumire_result_count(fresh));
  for (size_t i = 0; i < sumire_result_count(actual); ++i) {
    sumire_candidate a, b;
    CHECK(sumire_result_candidate(actual, i, &a) == 0 && sumire_result_candidate(fresh, i, &b) == 0);
    CHECK(a.candidate_id == b.candidate_id && a.score == b.score && same_string(a.text,b.text));
    CHECK(a.start_utf16 == b.start_utf16 && a.length_utf16 == b.length_utf16 && a.segment_count == b.segment_count);
    for (size_t j = 0; j < a.segment_count; ++j) {
      sumire_segment x, y;
      CHECK(sumire_result_segment(actual,i,j,&x) == 0 && sumire_result_segment(fresh,i,j,&y) == 0);
      CHECK(same_string(x.text,y.text) && same_string(x.dictionary,y.dictionary) && x.start_utf16 == y.start_utf16 && x.length_utf16 == y.length_utf16);
    }
    size_t count = sumire_result_bunsetsu_count(actual,i);
    CHECK(count == sumire_result_bunsetsu_count(fresh,i));
    for (size_t j = 0; j < count; ++j) {
      uint32_t x,y;
      CHECK(sumire_result_bunsetsu_boundary(actual,i,j,&x) == 0 && sumire_result_bunsetsu_boundary(fresh,i,j,&y) == 0 && x == y);
    }
  }
}
static void test_edit_reuse(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *reused = NULL;
  CHECK(sumire_engine_open_with_dictionaries(directory,0,1,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&reused,error,sizeof error) == 0);
  const char *readings[] = {"あいあい", "あいあいあ", "あいあい", "あいあい", "あいあい", "hel", "あいあい", "😀あい", "😁あい", "があい", "かあい", "あいあい"};
  unsigned flags[] = {12,12,12,12,13,2,12,12,12,12,12,16};
  size_t hits = 0;
  for (size_t i = 0; i < sizeof flags / sizeof flags[0]; ++i) {
    sumire_session *fresh = NULL;
    sumire_result *a = NULL, *b = NULL;
    CHECK(sumire_session_create(engine,&fresh,error,sizeof error) == 0);
    // Production Swift replaces its learning overlay for each input. Identical
    // empty overlays must not turn every dictionary cache lookup into a miss.
    CHECK(sumire_session_set_learning(reused,NULL,0,error,sizeof error) == 0);
    CHECK(sumire_session_set_learning(fresh,NULL,0,error,sizeof error) == 0);
    sumire_request request = {i+1,readings[i],strlen(readings[i]),0,20,200000,flags[i]};
    CHECK(sumire_session_update(reused,&request,&a,error,sizeof error) == 0);
    CHECK(sumire_session_update(fresh,&request,&b,error,sizeof error) == 0);
    compare_results(a,b);
    if (i == 11) {
      sumire_metrics metrics;
      CHECK(sumire_result_metrics(a, &metrics) == 0);
      // Flag 16 selects the bunsetsu route; this fixture intentionally omits
      // the four auxiliary dictionaries, so that route must report incomplete.
      CHECK(metrics.complete == 0);
    }
    size_t reused_rows, searched_rows;
    CHECK(sumire_result_search_rows(a,&reused_rows,&searched_rows) == 0);
    hits += reused_rows;
    if (i == 6) CHECK(reused_rows == 0); // English transition invalidates.
    if (i == 3) CHECK(reused_rows > 0);
    sumire_result_destroy(a); sumire_result_destroy(b); sumire_session_destroy(fresh);
  }
  CHECK(hits > 0);
  sumire_session_destroy(reused); sumire_engine_close(engine);
}
static void test_category_prediction(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  sumire_result *result = NULL;
  CHECK(sumire_engine_open(directory, 1u << 9, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request request = {1, "かきく", strlen("かきく"), 0, 1, 200000, 8};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  sumire_session_destroy(session);
  sumire_engine_close(engine);
  int found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate candidate;
    CHECK(sumire_result_candidate(result, i, &candidate) == 0);
    if (candidate.text.size != strlen("CategoryABI") ||
        memcmp(candidate.text.data, "CategoryABI", candidate.text.size) != 0) continue;
    CHECK(candidate.score == 1600 && candidate.length_utf16 == 3);
    CHECK(sumire_result_category_count(result, i) == 1);
    sumire_string category;
    CHECK(sumire_result_category(result, i, 0, &category) == 0);
    CHECK(category.size == 7 && memcmp(category.data, "medical", 7) == 0);
    found = 1;
  }
  CHECK(found);
  int correction_found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate candidate;
    sumire_string raw, corrected;
    CHECK(sumire_result_candidate(result,i,&candidate) == 0);
    CHECK(sumire_result_reading_correction(result,i,&raw,&corrected) == 0);
    if (!raw.size) { CHECK(corrected.size == 0); continue; }
    CHECK(raw.size == strlen("訂正\tていせい") &&
          memcmp(raw.data,"訂正\tていせい",raw.size) == 0);
    CHECK(corrected.size == strlen("ていせい") &&
          memcmp(corrected.data,"ていせい",corrected.size) == 0);
    CHECK(candidate.text.size == strlen("訂正") &&
          memcmp(candidate.text.data,"訂正",candidate.text.size) == 0);
    CHECK(candidate.length_utf16 == 3 && candidate.score == 8200);
    correction_found = 1;
  }
  CHECK(correction_found);
  sumire_string unused;
  CHECK(sumire_result_reading_correction(NULL,0,&unused,&unused) == -1);
  CHECK(sumire_result_reading_correction(result,sumire_result_count(result),&unused,&unused) == -1);
  sumire_result_destroy(result);
}
static void test_pathless_kana_ranges(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  CHECK(sumire_engine_open(directory,0,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&session,error,sizeof error) == 0);
  const char *readings[] = {"が", "あ😀"};
  const char *outputs[] = {"ｶﾞ", "ｱ😀"};
  const uint32_t lengths[] = {1,3};
  for (size_t j = 0; j < 2; ++j) {
    sumire_request request = {j+1,readings[j],strlen(readings[j]),0,1,200000,12};
    sumire_result *result = NULL;
    CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
    int found = 0;
    size_t selected = 0;
    for (size_t i = 0; i < sumire_result_count(result); ++i) {
      sumire_candidate candidate;
      CHECK(sumire_result_candidate(result,i,&candidate) == 0);
      if (candidate.text.size != strlen(outputs[j]) ||
          memcmp(candidate.text.data,outputs[j],candidate.text.size) != 0) continue;
      CHECK(candidate.segment_count == 0 && candidate.score == 6000);
      CHECK(candidate.start_utf16 == 0 && candidate.length_utf16 == lengths[j]);
      CHECK(sumire_session_commit(session,j+1,candidate.candidate_id,error,sizeof error) == 0);
      selected = i;
      found = 1;
    }
    CHECK(found);
    // A reset/commit cannot change the independently owned result's range.
    sumire_session_reset(session);
    sumire_candidate retained;
    CHECK(sumire_result_candidate(result,selected,&retained) == 0);
    CHECK(retained.length_utf16 == lengths[j] && retained.start_utf16 == 0);
    CHECK(retained.text.size == strlen(outputs[j]) &&
          memcmp(retained.text.data,outputs[j],retained.text.size) == 0);
    sumire_result_destroy(result);
  }
  sumire_session_destroy(session); sumire_engine_close(engine);
}
int main(int argc, char **argv) {
  CHECK(argc == 2);
  test_edit_reuse(argv[1]);
  test_category_prediction(argv[1]);
  test_pathless_kana_ranges(argv[1]);
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  sumire_result *first = NULL, *second = NULL, *failed = NULL;
  CHECK(sumire_abi_version() == 1 && sumire_category_count() == 30);
  CHECK(sumire_category_name(30) == NULL);
  CHECK(sumire_engine_has_standalone_priority(NULL) == 0);
  CHECK(sumire_engine_open_with_dictionaries(argv[1], 0, 4, &engine, error, sizeof error) == 0);
  CHECK(sumire_engine_has_standalone_priority(engine) == 0);
  sumire_engine_close(engine); engine = NULL;
  // Exact origin labels remain owned by their result after the engine/session
  // are gone, and never manufacture extra selected-path segments.
  CHECK(sumire_engine_open(argv[1], (1u << 9) | (1u << 12), &engine, error, sizeof error) == 0);
  CHECK(sumire_engine_has_standalone_priority(engine) == 1);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request origins_request = {1, "あい", strlen("あい"), 0, 1, 200000, 0};
  sumire_result *origins = NULL;
  CHECK(sumire_session_update(session, &origins_request, &origins, error, sizeof error) == 0);
  CHECK(sumire_result_category_count(origins, 0) == 2);
  CHECK(sumire_result_category_count(NULL, 0) == 0);
  sumire_string origin;
  CHECK(sumire_result_category(origins, 0, 2, &origin) < 0);
  CHECK(sumire_result_category(origins, 0, 0, NULL) < 0);
  CHECK(sumire_result_category(origins, 0, 0, &origin) == 0 && origin.size == 7 && memcmp(origin.data, "medical", 7) == 0);
  sumire_session_destroy(session); sumire_engine_close(engine);
  CHECK(sumire_result_category(origins, 0, 1, &origin) == 0 && origin.size == 6 && memcmp(origin.data, "person", 6) == 0);
  sumire_result_destroy(origins); engine = NULL; session = NULL;
  CHECK(sumire_engine_open(argv[1], 0, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_engine_close(engine);
  sumire_request req = {1, "あい", strlen("あい"), 0, 10, 200000, 0};
  CHECK(sumire_session_update(session, &req, &first, error, sizeof error) == 0);
  sumire_candidate candidate;
  CHECK(sumire_result_candidate(first, 0, &candidate) == 0);
  CHECK(candidate.length_utf16 == 2 && candidate.text.size > 0);
  const char *saved = candidate.text.data;
  size_t saved_size = candidate.text.size;
  CHECK(sumire_session_update(session, &req, &failed, error, sizeof error) <
            0 &&
        failed == NULL);
  CHECK(sumire_session_commit(session, 0, 0, error, sizeof error) < 0);
  req.generation = 2;
  req.reading = "🦊";
  req.reading_bytes = strlen(req.reading);
  req.edit_start_utf16 = 1;
  CHECK(sumire_session_update(session, &req, &failed, error, sizeof error) < 0);
  CHECK(sumire_session_commit(session, 1, 0, error, sizeof error) == 0);
  req.edit_start_utf16 = 0;
  CHECK(sumire_session_update(session, &req, &second, error, sizeof error) ==
        0);
  CHECK(sumire_result_candidate(second, 0, &candidate) == 0);
  CHECK(candidate.length_utf16 == 2 && candidate.text.size == strlen("🦊"));
  CHECK(memcmp(candidate.text.data, "🦊", candidate.text.size) == 0);
  sumire_session_reset(session);
  CHECK(sumire_session_commit(session, 2, 0, error, sizeof error) < 0);
  CHECK(sumire_session_update(session, &req, &failed, error, sizeof error) < 0);
  CHECK(sumire_context_id_for_pos(0) == 1851);
  CHECK(sumire_context_id_for_pos(11) == 1);
  CHECK(sumire_context_id_for_pos(-1) == 1851);
  char user_text[] = "USER";
  sumire_personal_entry entries[] = {
      {{"あ", strlen("あ")}, {user_text, 4}, 1, -1000, 0},
      {{"あい", strlen("あい")}, {"TEMPLATE", 8}, 0, -2000, 1}};
  CHECK(sumire_session_set_personal(session, entries, 2, error, sizeof error) ==
        0);
  user_text[0] = 'Z'; // C strings were copied, not retained.
  req.generation = 3;
  req.reading = "あい";
  req.reading_bytes = strlen(req.reading);
  sumire_result *personal = NULL;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) ==
        0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.text.size == 8 &&
        memcmp(candidate.text.data, "TEMPLATE", 8) == 0);
  CHECK(candidate.score == -2000);
  sumire_segment segment;
  CHECK(sumire_result_segment(personal, 0, 0, &segment) == 0);
  CHECK(segment.dictionary.size == 8 &&
        memcmp(segment.dictionary.data, "template", 8) == 0);
  entries[0].context_id =
      3; // Outside the 3x3 fixture matrix: reject atomically.
  CHECK(sumire_session_set_personal(session, entries, 2, error, sizeof error) <
        0);
  CHECK(sumire_session_commit(session, 3, 0, error, sizeof error) == 0);
  sumire_result_destroy(personal);
  req.generation = 4;
  req.reading = "あいあ";
  req.reading_bytes = strlen(req.reading);
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) ==
        0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.text.size == 9 &&
        memcmp(candidate.text.data, "USERIUSER", 9) == 0);
  CHECK(candidate.score == -1920);
  for (size_t i = 0; i < sumire_result_count(personal); ++i) {
    CHECK(sumire_result_candidate(personal, i, &candidate) == 0);
    CHECK(strstr(candidate.text.data, "TEMPLATE") == NULL);
  }
  sumire_result_destroy(personal);
  CHECK(sumire_session_set_personal(session, NULL, 0, error, sizeof error) ==
        0);
  req.generation = 5;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) ==
        0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(strstr(candidate.text.data, "USER") == NULL);
  sumire_result_destroy(personal);
  sumire_personal_entry learned = {{"あいあ", strlen("あいあ")}, {"LEARNED", 7}, 0, -50000, 2};
  CHECK(sumire_session_set_learning(session, &learned, 1, error, sizeof error) == 0);
  req.generation = 6;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.text.size == 7 && memcmp(candidate.text.data, "LEARNED", 7) == 0);
  CHECK(candidate.score == -50000);
  CHECK(sumire_result_segment(personal, 0, 0, &segment) == 0);
  CHECK(segment.dictionary.size == 8 && memcmp(segment.dictionary.data, "learning", 8) == 0);
  learned.kind = 0;
  CHECK(sumire_session_set_learning(session, &learned, 1, error, sizeof error) < 0);
  CHECK(sumire_session_commit(session, 6, candidate.candidate_id, error, sizeof error) == 0);
  CHECK(sumire_session_set_learning(session, NULL, 0, error, sizeof error) == 0);
  sumire_result_destroy(personal);
  req.generation = 7;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.text.size != 7 || memcmp(candidate.text.data, "LEARNED", 7) != 0);
  size_t retained = sumire_session_cache_bytes(session);
  CHECK(retained > 0 && retained <= 4 * 1024 * 1024);
  sumire_session_purge_cache(session);
  CHECK(sumire_session_cache_bytes(session) == 0);
  CHECK(sumire_result_candidate(first, 0, &candidate) == 0);
  CHECK(candidate.text.data == saved && candidate.text.size == saved_size);
  sumire_result_destroy(personal);
  req.generation = 8;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_session_cache_bytes(session) > 0);
  sumire_result_destroy(personal);
  sumire_session_purge_cache(NULL);
  CHECK(sumire_session_cache_bytes(NULL) == 0);
  sumire_session_destroy(session);
  CHECK(sumire_result_candidate(first, 0, &candidate) == 0);
  CHECK(candidate.text.data == saved && candidate.text.size == saved_size);
  sumire_metrics metrics;
  CHECK(sumire_result_metrics(second, &metrics) == 0 &&
        metrics.generation == 2);
  sumire_result_destroy(first);
  sumire_result_destroy(second);
  engine = NULL;
  CHECK(sumire_engine_open_with_dictionaries(argv[1], 0, 8, &engine, error, sizeof error) < 0 && engine == NULL);
  CHECK(sumire_engine_open_with_dictionaries(argv[1], 0, 2, &engine, error, sizeof error) < 0 && engine == NULL);
  CHECK(sumire_engine_open_with_dictionaries(argv[1], 0, 1, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_engine_close(engine);
  req = (sumire_request){1, "hel", 3, 0, 10, 200000, 2};
  CHECK(sumire_session_update(session, &req, &first, error, sizeof error) == 0);
  CHECK(sumire_result_candidate(first, 0, &candidate) == 0);
  CHECK(candidate.text.size == 5 && memcmp(candidate.text.data, "hello", 5) == 0);
  CHECK(candidate.score == 123 && candidate.length_utf16 == 3);
  CHECK(sumire_result_metrics(first, &metrics) == 0 && metrics.generation == 1);
  req.generation = 2; req.flags = 3;
  CHECK(sumire_session_update(session, &req, &failed, error, sizeof error) < 0 && failed == NULL);
  CHECK(sumire_session_commit(session, 1, candidate.candidate_id, error, sizeof error) == 0);
  req.flags = 10; // English and Japanese prediction cannot be combined.
  CHECK(sumire_session_update(session, &req, &failed, error, sizeof error) < 0 && failed == NULL);
  req.flags = 8; req.reading = "あい"; req.reading_bytes = strlen(req.reading);
  CHECK(sumire_session_update(session, &req, &second, error, sizeof error) == 0);
  sumire_personal_entry english_entries[] = {
      {{"hello", 5}, {"MyHello", 7}, 0, -1000, 0},
      {{"hel", 3}, {"Greeting", 8}, 0, -2000, 1}};
  CHECK(sumire_session_set_personal(session, english_entries, 2, error, sizeof error) == 0);
  sumire_personal_entry english_learned = {{"hel", 3}, {"Remembered", 10}, 0, -3000, 2};
  CHECK(sumire_session_set_learning(session, &english_learned, 1, error, sizeof error) == 0);
  req = (sumire_request){3, "hel", 3, 0, 1, 200000, 2};
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_result_count(personal) == 1);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.score == -3000 && candidate.text.size == 10 && memcmp(candidate.text.data, "Remembered", 10) == 0);
  CHECK(sumire_result_segment(personal, 0, 0, &segment) == 0 && segment.dictionary.size == 8 && memcmp(segment.dictionary.data, "learning", 8) == 0);
  sumire_result_destroy(personal);
  CHECK(sumire_session_set_learning(session, NULL, 0, error, sizeof error) == 0);
  req.generation = 4;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.text.size == 8 && memcmp(candidate.text.data, "Greeting", 8) == 0);
  sumire_result_destroy(personal);
  req.generation = 5; req.reading = "he"; req.reading_bytes = 2;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.text.size == 7 && memcmp(candidate.text.data, "MyHello", 7) == 0);
  CHECK(candidate.length_utf16 == 2);
  CHECK(sumire_result_segment(personal, 0, 0, &segment) == 0 && segment.dictionary.size == 4 && memcmp(segment.dictionary.data, "user", 4) == 0);
  sumire_result_destroy(personal);
  CHECK(sumire_session_set_personal(session, NULL, 0, error, sizeof error) == 0);
  req.generation = 6;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_result_candidate(personal, 0, &candidate) == 0);
  CHECK(candidate.text.size == 5 && memcmp(candidate.text.data, "hello", 5) == 0);
  sumire_result_destroy(personal);
  req = (sumire_request){7, "あい", strlen("あい"), 0, 1, 200000, 4};
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  int found_prefix = 0;
  for (size_t i = 0; i < sumire_result_count(personal); ++i) {
    CHECK(sumire_result_candidate(personal, i, &candidate) == 0);
    if (candidate.text.size == 1 && memcmp(candidate.text.data, "A", 1) == 0) {
      CHECK(candidate.start_utf16 == 0 && candidate.length_utf16 == 1);
      found_prefix = 1;
    }
  }
  CHECK(found_prefix);
  sumire_result_destroy(personal);
  req = (sumire_request){8, "かきく", strlen("かきく"), 0, 1, 200000, 8};
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  int found_prediction = 0;
  uint64_t prediction_id = 0;
  for (size_t i = 0; i < sumire_result_count(personal); ++i) {
    CHECK(sumire_result_candidate(personal, i, &candidate) == 0);
    if (candidate.text.size == strlen("PredictionABI") &&
        memcmp(candidate.text.data, "PredictionABI", candidate.text.size) == 0) {
      CHECK(candidate.start_utf16 == 0 && candidate.length_utf16 == 3);
      CHECK(candidate.score == -2000);
      CHECK(sumire_result_bunsetsu_count(personal, i) == 0);
      CHECK(sumire_result_segment(personal, i, 0, &segment) == 0);
      CHECK(segment.start_utf16 == 0 && segment.length_utf16 == 3);
      prediction_id = candidate.candidate_id;
      found_prediction = 1;
    }
  }
  CHECK(found_prediction);
  CHECK(sumire_session_commit(session, 8, prediction_id, error, sizeof error) == 0);
  CHECK(sumire_session_commit(session, 8, prediction_id, error, sizeof error) < 0);
  sumire_result_destroy(personal);
  req.generation = 9;
  CHECK(sumire_session_update(session, &req, &personal, error, sizeof error) == 0);
  CHECK(sumire_session_commit(session, 8, prediction_id, error, sizeof error) < 0);
  sumire_result_destroy(personal);
  sumire_session_destroy(session);
  CHECK(sumire_result_candidate(first, 0, &candidate) == 0 && candidate.text.size == 5);
  sumire_result_destroy(first); sumire_result_destroy(second);
  return 0;
}
