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
int main(int argc, char **argv) {
  CHECK(argc == 2);
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  sumire_result *first = NULL, *second = NULL, *failed = NULL;
  CHECK(sumire_abi_version() == 1 && sumire_category_count() == 30);
  CHECK(sumire_category_name(30) == NULL);
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
  CHECK(sumire_engine_open_with_dictionaries(argv[1], 0, 4, &engine, error, sizeof error) < 0 && engine == NULL);
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
