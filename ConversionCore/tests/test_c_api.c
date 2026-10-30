#include "c_api.h"
#include "dictionary_browser.h"
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
static void test_bunsetsu_metadata_invalid_arguments(void) {
  uint32_t boundary = 1234;
  int has_pattern = 1234;
  CHECK(sumire_result_bunsetsu_split_pattern_count(NULL) == 0);
  CHECK(sumire_result_bunsetsu_split_pattern_boundary_count(NULL, 0) == 0);
  CHECK(sumire_result_bunsetsu_split_pattern_boundary(NULL, 0, 0, &boundary) == -1);
  CHECK(boundary == 1234);
  CHECK(sumire_result_primary_bunsetsu_boundary_count(NULL) == 0);
  CHECK(sumire_result_primary_bunsetsu_boundary(NULL, 0, &boundary) == -1);
  CHECK(boundary == 1234);
  CHECK(sumire_result_candidate_has_bunsetsu_split_pattern(NULL, 0, &has_pattern) == -1);
  CHECK(has_pattern == 1234);
  CHECK(sumire_result_candidate_has_bunsetsu_split_pattern(NULL, 0, NULL) == -1);
}
static void compare_results(sumire_result *actual, sumire_result *fresh) {
  sumire_metrics actual_metrics, fresh_metrics;
  CHECK(sumire_result_metrics(actual,&actual_metrics) == 0 && sumire_result_metrics(fresh,&fresh_metrics) == 0);
  CHECK(actual_metrics.complete == fresh_metrics.complete && actual_metrics.generation == fresh_metrics.generation);
  CHECK(sumire_result_count(actual) == sumire_result_count(fresh));
  size_t split_pattern_count = sumire_result_bunsetsu_split_pattern_count(actual);
  CHECK(split_pattern_count == sumire_result_bunsetsu_split_pattern_count(fresh));
  for (size_t i = 0; i < split_pattern_count; ++i) {
    size_t boundary_count = sumire_result_bunsetsu_split_pattern_boundary_count(actual, i);
    CHECK(boundary_count == sumire_result_bunsetsu_split_pattern_boundary_count(fresh, i));
    for (size_t j = 0; j < boundary_count; ++j) {
      uint32_t a, b;
      CHECK(sumire_result_bunsetsu_split_pattern_boundary(actual, i, j, &a) == 0);
      CHECK(sumire_result_bunsetsu_split_pattern_boundary(fresh, i, j, &b) == 0);
      CHECK(a == b);
    }
  }
  size_t primary_count = sumire_result_primary_bunsetsu_boundary_count(actual);
  CHECK(primary_count == sumire_result_primary_bunsetsu_boundary_count(fresh));
  for (size_t i = 0; i < primary_count; ++i) {
    uint32_t a, b;
    CHECK(sumire_result_primary_bunsetsu_boundary(actual, i, &a) == 0);
    CHECK(sumire_result_primary_bunsetsu_boundary(fresh, i, &b) == 0);
    CHECK(a == b);
  }
  uint32_t invalid_boundary = 1234;
  int invalid_mapping = 1234;
  CHECK(sumire_result_bunsetsu_split_pattern_boundary(actual, split_pattern_count, 0,
                                                      &invalid_boundary) == -1);
  CHECK(invalid_boundary == 1234);
  CHECK(sumire_result_primary_bunsetsu_boundary(actual, primary_count,
                                                &invalid_boundary) == -1);
  CHECK(invalid_boundary == 1234);
  CHECK(sumire_result_candidate_has_bunsetsu_split_pattern(
      actual, sumire_result_count(actual), &invalid_mapping) == -1);
  CHECK(invalid_mapping == 1234);
  for (size_t i = 0; i < sumire_result_count(actual); ++i) {
    uint32_t actual_flags, fresh_flags;
    CHECK(sumire_result_candidate_flags(actual,i,&actual_flags) == 0);
    CHECK(sumire_result_candidate_flags(fresh,i,&fresh_flags) == 0);
    CHECK(actual_flags == fresh_flags);
    uint32_t actual_kind, fresh_kind;
    CHECK(sumire_result_candidate_presentation_kind(actual,i,&actual_kind) == 0);
    CHECK(sumire_result_candidate_presentation_kind(fresh,i,&fresh_kind) == 0);
    CHECK(actual_kind == fresh_kind);
    int actual_has_pattern = -1, fresh_has_pattern = -1;
    CHECK(sumire_result_candidate_has_bunsetsu_split_pattern(actual, i,
                                                            &actual_has_pattern) == 0);
    CHECK(sumire_result_candidate_has_bunsetsu_split_pattern(fresh, i,
                                                            &fresh_has_pattern) == 0);
    CHECK(actual_has_pattern == fresh_has_pattern);
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
static void test_bunsetsu_snapshot_metadata(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  sumire_result *result = NULL;
  CHECK(sumire_engine_open_with_dictionaries(directory, 0, 1, &engine,
                                             error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request request = {1, "あい", strlen("あい"), 0, 20, 200000, 16};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);

  size_t pattern_count = sumire_result_bunsetsu_split_pattern_count(result);
  CHECK(pattern_count > 0);
  int found_empty_pattern = 0;
  for (size_t i = 0; i < pattern_count; ++i) {
    if (sumire_result_bunsetsu_split_pattern_boundary_count(result, i) == 0)
      found_empty_pattern = 1;
  }
  CHECK(found_empty_pattern);

  int found_whole_path_mapping = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate candidate;
    CHECK(sumire_result_candidate(result, i, &candidate) == 0);
    if (!same_string(candidate.text, (sumire_string){"Whole", 5})) continue;
    int has_pattern = 0;
    CHECK(sumire_result_candidate_has_bunsetsu_split_pattern(result, i,
                                                             &has_pattern) == 0);
    CHECK(has_pattern == 1);
    CHECK(sumire_result_bunsetsu_count(result, i) == 0);
    found_whole_path_mapping = 1;
  }
  CHECK(found_whole_path_mapping);
  CHECK(sumire_result_primary_bunsetsu_boundary_count(result) == 0);
  uint32_t untouched = 4321;
  CHECK(sumire_result_primary_bunsetsu_boundary(result, 0, &untouched) == -1);
  CHECK(untouched == 4321);

  sumire_result_destroy(result);
  sumire_session_destroy(session);
  sumire_engine_close(engine);
}
static void test_candidate_origin_flags(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  sumire_result *result = NULL;
  CHECK(sumire_engine_open(directory,0,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&session,error,sizeof error) == 0);
  sumire_request request = {1,"あい",strlen("あい"),0,1,200000,4};
  CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
  sumire_session_reset(session);
  sumire_session_destroy(session);
  sumire_engine_close(engine);
  int found_prefix = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    uint32_t flags = 99;
    CHECK(sumire_result_candidate_flags(result,i,&flags) == 0);
    if (!i) CHECK(flags == 0);
    if (flags == SUMIRE_CANDIDATE_READING_PREFIX) {
      sumire_candidate candidate;
      CHECK(sumire_result_candidate(result,i,&candidate) == 0);
      CHECK(candidate.length_utf16 < 2);
      found_prefix = 1;
    }
    CHECK((flags & ~SUMIRE_CANDIDATE_READING_PREFIX) == 0);
  }
  CHECK(found_prefix);
  uint32_t flags = 99;
  CHECK(sumire_result_candidate_flags(NULL,0,&flags) == -1 && flags == 99);
  CHECK(sumire_result_candidate_flags(result,sumire_result_count(result),&flags) == -1 && flags == 99);
  CHECK(sumire_result_candidate_flags(result,0,NULL) == -1);
  sumire_result_destroy(result);
}
static int64_t prediction_score(sumire_result *result, const char *text) {
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate candidate;
    CHECK(sumire_result_candidate(result, i, &candidate) == 0);
    if (candidate.text.size == strlen(text) && memcmp(candidate.text.data, text, candidate.text.size) == 0)
      return candidate.score;
  }
  return INT64_MAX;
}
static void test_bunsetsu_auxiliary_completion(const char *directory) {
  char error[256]; sumire_engine *engine = NULL; sumire_session *session = NULL;
  sumire_result *owned = NULL;
  CHECK(sumire_engine_open_with_dictionaries(directory, 0, 0, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  const uint32_t modes[] = {24, 16, 12};
  const char *names[] = {"EMOJI-COMP", "EMOTICON-COMP", "SYMBOL-COMP"};
  const int64_t scores[] = {1100, 1200, 1300};
  for (size_t m = 0; m < 3; ++m) {
    sumire_result *result = NULL;
    sumire_request request = {m + 1, "あいう", strlen("あいう"), 0, 20, 200000, modes[m]};
    CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
    for (size_t k = 0; k < 3; ++k) {
      CHECK(prediction_score(result, names[k]) == (modes[m] == 16 ? INT64_MAX : scores[k]));
    }
    for (size_t i = 0; i < sumire_result_count(result); ++i) {
      sumire_candidate row; CHECK(sumire_result_candidate(result, i, &row) == 0);
      if (!row.segment_count) continue;
      sumire_segment segment; CHECK(sumire_result_segment(result, i, 0, &segment) == 0);
      const int auxiliary = (segment.dictionary.size == 5 && !memcmp(segment.dictionary.data, "emoji", 5)) ||
        (segment.dictionary.size == 8 && !memcmp(segment.dictionary.data, "emoticon", 8)) ||
        (segment.dictionary.size == 6 && !memcmp(segment.dictionary.data, "symbol", 6));
      if (!auxiliary) continue;
      CHECK(row.start_utf16 == 0 && row.length_utf16 == 3 && row.segment_count == 1);
      CHECK(segment.start_utf16 == 0 && segment.length_utf16 == 3);
      uint16_t left = 99, right = 99; uint32_t flags = 99;
      CHECK(sumire_result_segment_context_ids(result, i, 0, &left, &right) == 0);
      CHECK(left == (modes[m] == 24 ? 1 : 0) && right == (modes[m] == 24 ? 1 : 0));
      CHECK(sumire_result_candidate_flags(result, i, &flags) == 0 && flags == 0);
    }
    if (m == 0) owned = result; else sumire_result_destroy(result);
  }
  sumire_session_destroy(session); sumire_engine_close(engine);
  CHECK(prediction_score(owned, "EMOJI-COMP") == 1100);
  sumire_result_destroy(owned);
}
static void test_bunsetsu_ascii_provider(const char *directory) {
  char error[256]; sumire_engine *engine = NULL; sumire_session *session = NULL;
  sumire_result *result = NULL, *owned = NULL;
  CHECK(sumire_engine_open_with_dictionaries(directory, 0, 3, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request request = {1, "ca", 2, 0, 20, 200000, 16};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "cat") == INT64_MAX); // Legacy 16 remains isolated.
  sumire_result_destroy(result); result = NULL;
  request.generation = 2; request.flags = 24;
  CHECK(sumire_session_update(session, &request, &owned, error, sizeof error) == 0);
  size_t word = SIZE_MAX;
  for (size_t i = 0; i < sumire_result_count(owned); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(owned, i, &c) == 0);
    uint32_t flags = 99; CHECK(sumire_result_candidate_flags(owned, i, &flags) == 0);
    if (c.text.size != 3 || memcmp(c.text.data, "cat", 3)) continue;
    word = i; CHECK(c.score == 100 && c.length_utf16 == 2 && c.segment_count == 0);
    CHECK(flags == SUMIRE_CANDIDATE_ENGLISH_PROVIDER);
    int known = 99; uint16_t left = 99, right = 99;
    CHECK(sumire_result_candidate_context_ids(owned, i, &known, &left, &right) == 0);
    CHECK(known == 0 && left == 0 && right == 0);
  }
  CHECK(word != SIZE_MAX);
  request.generation = 3; request.reading = "あ"; request.reading_bytes = strlen("あ");
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  int reading_found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(result, i, &c) == 0);
    if (c.text.size != 8 || memcmp(c.text.data, "ReadWord", 8)) continue;
    uint16_t left = 99, right = 99; uint32_t flags = 99;
    CHECK(c.segment_count == 1 && c.length_utf16 == 1);
    CHECK(sumire_result_segment_context_ids(result, i, 0, &left, &right) == 0 && left == 2 && right == 2);
    CHECK(sumire_result_candidate_flags(result, i, &flags) == 0 && flags == 0);
    reading_found = 1;
  }
  CHECK(reading_found); sumire_result_destroy(result); result = NULL;
  request.generation = 4; request.reading = "ca"; request.reading_bytes = 2; request.flags = 12;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  int normal_found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(result, i, &c) == 0);
    if (c.text.size != 3 || memcmp(c.text.data, "cat", 3)) continue;
    uint32_t flags = 99;
    CHECK(c.segment_count == 0 && c.length_utf16 == 2 && c.score == 100);
    CHECK(sumire_result_candidate_flags(result, i, &flags) == 0 && flags == SUMIRE_CANDIDATE_ENGLISH_PROVIDER);
    int has = 99; uint16_t left = 99, right = 99;
    CHECK(sumire_result_candidate_context_ids(result, i, &has, &left, &right) == 0 && has == 0 && left == 0 && right == 0);
    normal_found = 1;
  }
  CHECK(normal_found); sumire_result_destroy(result); result = NULL;
  request.generation = 5; request.reading = "あ"; request.reading_bytes = strlen(request.reading);
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  int normal_reading_found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate row; CHECK(sumire_result_candidate(result, i, &row) == 0);
    if (row.text.size != 8 || memcmp(row.text.data, "ReadWord", 8)) continue;
    uint16_t left = 0, right = 0;
    CHECK(row.segment_count == 1 && row.length_utf16 == 1 && row.score == 400);
    CHECK(sumire_result_segment_context_ids(result, i, 0, &left, &right) == 0 && left == 2 && right == 2);
    normal_reading_found = 1;
  }
  CHECK(normal_reading_found); sumire_result_destroy(result); result = NULL;
  request.generation = 6; request.reading = "ca"; request.reading_bytes = 2; request.flags = 2;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "cat") == 100);
  int english_only_found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate row; CHECK(sumire_result_candidate(result, i, &row) == 0);
    if (row.text.size != 3 || memcmp(row.text.data, "cat", 3)) continue;
    uint32_t flags = 99;
    CHECK(row.segment_count == 1 && sumire_result_candidate_flags(result, i, &flags) == 0 && flags == 0);
    english_only_found = 1;
  }
  CHECK(english_only_found); sumire_result_destroy(result); result = NULL;
  request.generation = 7; request.reading = "ｃａ"; request.reading_bytes = strlen(request.reading); request.flags = 12;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  int wide_found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate row; CHECK(sumire_result_candidate(result, i, &row) == 0);
    if (row.text.size != 3 || memcmp(row.text.data, "cat", 3)) continue;
    CHECK(row.segment_count == 0 && row.start_utf16 == 0 && row.length_utf16 == 2 && row.score == 100);
    wide_found = 1;
  }
  CHECK(wide_found);
  sumire_result_destroy(result); sumire_session_destroy(session); sumire_engine_close(engine);
  sumire_candidate c; uint32_t flags = 99;
  CHECK(sumire_result_candidate(owned, word, &c) == 0 && c.text.size == 3 && !memcmp(c.text.data, "cat", 3));
  CHECK(c.segment_count == 0 && c.length_utf16 == 2);
  CHECK(sumire_result_candidate_flags(owned, word, &flags) == 0 && flags == SUMIRE_CANDIDATE_ENGLISH_PROVIDER);
  sumire_result_destroy(owned);
}
static void test_bunsetsu_prediction_flags(const char *directory) {
  char error[256]; sumire_engine *engine = NULL; sumire_session *session = NULL;
  sumire_result *result = NULL, *owned = NULL;
  CHECK(sumire_engine_open(directory, 0, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request request = {1, "あいう", strlen("あいう"), 0, 20, 200000, 16};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "SYSTEM-COMPLETE") == INT64_MAX);
  CHECK(prediction_score(result, "PROVERB") == 16300); // Legacy 16 keeps its independent proverb route.
  sumire_result_destroy(result); result = NULL;
  request.generation = 2; request.flags = 24;
  CHECK(sumire_session_update(session, &request, &owned, error, sizeof error) == 0);
  CHECK(prediction_score(owned, "SYSTEM-COMPLETE") == 16100);
  CHECK(prediction_score(owned, "CORRECTION") == 16200);
  for (size_t i = 0; i < sumire_result_count(owned); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(owned, i, &c) == 0);
    if (c.text.size != strlen("SYSTEM-COMPLETE") || memcmp(c.text.data, "SYSTEM-COMPLETE", c.text.size)) continue;
    uint16_t left = 99, right = 99;
    CHECK(c.start_utf16 == 0 && c.length_utf16 == 3 && c.segment_count == 1);
    CHECK(sumire_result_segment_context_ids(owned, i, 0, &left, &right) == 0);
    CHECK(left == 1 && right == 1);
  }
  request.generation = 3; request.flags = 26;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) < 0 && result == NULL);
  request.flags = 64;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) < 0 && result == NULL);
  CHECK(sumire_session_commit(session, 2, 0, error, sizeof error) == 0); // Candidate 0 remains usable.
  CHECK(sumire_session_set_prediction_config(session, 2, SUMIRE_PREDICTION_AGGRESSIVENESS_AGGRESSIVE, error, sizeof error) == 0);
  CHECK(sumire_session_set_kotowaza_enabled(session, 0, error, sizeof error) == 0);
  request.flags = 24;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "SYSTEM-COMPLETE") == 8100);
  CHECK(prediction_score(result, "CORRECTION") == 8200);
  CHECK(prediction_score(result, "PROVERB") == INT64_MAX);
  sumire_result_destroy(result); result = NULL;
  request.generation = 4; request.reading = "1"; request.reading_bytes = 1;
  request.flags = 24 | SUMIRE_REQUEST_DISABLE_NUMERIC_SYMBOL_CANDIDATES;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "①") == INT64_MAX);
  sumire_result_destroy(result); result = NULL;
  request.generation = 5; request.flags = 24;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "①") != INT64_MAX);
  sumire_result_destroy(result); result = NULL;
  request.generation = 4;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) < 0 && result == NULL);
  sumire_session_destroy(session); sumire_engine_close(engine);
  CHECK(prediction_score(owned, "SYSTEM-COMPLETE") == 16100);
  sumire_result_destroy(owned);
}
static void test_kotowaza_settings(const char *directory) {
  char error[256]; sumire_engine *engine = NULL; sumire_session *session = NULL; sumire_result *result = NULL;
  CHECK(sumire_engine_open(directory, 0, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request request = {1, "あいう", strlen("あいう"), 0, 20, 200000, 8};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "PROVERB") == 16100);
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(result, i, &c) == 0);
    if (c.text.size != 7 || memcmp(c.text.data, "PROVERB", 7)) continue;
    CHECK(c.start_utf16 == 0 && c.length_utf16 == 3 && c.segment_count == 1);
    uint16_t left = 99, right = 99;
    CHECK(sumire_result_segment_context_ids(result, i, 0, &left, &right) == 0);
    CHECK(left == 2 && right == 2);
  }
  CHECK(sumire_session_set_kotowaza_enabled(NULL, 0, error, sizeof error) < 0);
  CHECK(sumire_session_set_kotowaza_enabled(session, 2, error, sizeof error) < 0);
  CHECK(sumire_session_set_kotowaza_enabled(session, 1, error, sizeof error) == 0);
  CHECK(sumire_session_commit(session, 1, 0, error, sizeof error) == 0);
  sumire_result_destroy(result); result = NULL;
  request.generation = 2;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(sumire_session_set_kotowaza_enabled(session, 0, error, sizeof error) == 0);
  CHECK(sumire_session_commit(session, 2, 0, error, sizeof error) < 0);
  CHECK(prediction_score(result, "PROVERB") == 16100); // Independently owned snapshot.
  sumire_result_destroy(result); result = NULL;
  request.generation = 3;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "PROVERB") == INT64_MAX);
  sumire_result_destroy(result); result = NULL;
  CHECK(sumire_session_set_kotowaza_enabled(session, 1, error, sizeof error) == 0);
  CHECK(sumire_session_set_prediction_config(session, 2, SUMIRE_PREDICTION_AGGRESSIVENESS_AGGRESSIVE, error, sizeof error) == 0);
  sumire_session_reset(session);
  request.generation = 4; request.flags = 8 | SUMIRE_REQUEST_DISABLE_NUMERIC_SYMBOL_CANDIDATES;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "PROVERB") == 8100); // Bit 32 remains numeric-only.
  sumire_result_destroy(result); result = NULL;
  CHECK(sumire_session_set_prediction_config(session, 1, SUMIRE_PREDICTION_AGGRESSIVENESS_STANDARD, error, sizeof error) == 0);
  request.generation = 5;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "PROVERB") == INT64_MAX);
  sumire_result_destroy(result); result = NULL;
  request.generation = 4;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) < 0 && result == NULL);
  sumire_session_destroy(session); sumire_engine_close(engine);
}
static void test_prediction_settings(const char *directory) {
  char error[256]; sumire_engine *engine = NULL; sumire_session *session = NULL; sumire_result *result = NULL;
  CHECK(sumire_engine_open(directory, 1u << 9, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request request = {1, "あいう", strlen("あいう"), 0, 20, 200000, 8};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "SYSTEM-PREDICT") == 16100);
  CHECK(sumire_session_set_prediction_config(NULL, 3, 1, error, sizeof error) < 0);
  CHECK(sumire_session_set_prediction_config(session, 0, 1, error, sizeof error) < 0);
  CHECK(sumire_session_set_prediction_config(session, 7, 1, error, sizeof error) < 0);
  CHECK(sumire_session_set_prediction_config(session, 3, 3, error, sizeof error) < 0);
  CHECK(sumire_session_set_prediction_config(session, 3, SUMIRE_PREDICTION_AGGRESSIVENESS_STANDARD, error, sizeof error) == 0);
  CHECK(sumire_session_commit(session, 1, 0, error, sizeof error) == 0); // Invalid/no-op setters retain selection.
  CHECK(prediction_score(result, "SYSTEM-PREDICT") == 16100);
  sumire_result_destroy(result); result = NULL;
  request.generation = 2;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(sumire_session_set_prediction_config(session, 2, SUMIRE_PREDICTION_AGGRESSIVENESS_AGGRESSIVE, error, sizeof error) == 0);
  CHECK(sumire_session_commit(session, 2, 0, error, sizeof error) < 0);
  CHECK(prediction_score(result, "SYSTEM-PREDICT") == 16100); // Owned snapshot remains immutable.
  sumire_result_destroy(result); result = NULL;
  request.generation = 3;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "SYSTEM-PREDICT") == 8100);
  CHECK(prediction_score(result, "CATEGORY-PREDICT") == 1600);
  CHECK(prediction_score(result, "訂正") == 8200);
  sumire_result_destroy(result); result = NULL;
  CHECK(sumire_session_set_prediction_config(session, 1, SUMIRE_PREDICTION_AGGRESSIVENESS_STANDARD, error, sizeof error) == 0);
  request.generation = 4;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "SYSTEM-PREDICT") == INT64_MAX);
  CHECK(prediction_score(result, "CATEGORY-PREDICT") == INT64_MAX);
  CHECK(prediction_score(result, "訂正") == INT64_MAX);
  sumire_result_destroy(result); result = NULL;
  request.generation = 3;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) < 0);
  CHECK(result == NULL); // Settings changes do not rewind request generations.
  CHECK(sumire_session_set_prediction_config(session, 2, SUMIRE_PREDICTION_AGGRESSIVENESS_STANDARD, error, sizeof error) == 0);
  sumire_session_reset(session);
  request.generation = 5;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(prediction_score(result, "SYSTEM-PREDICT") == 16100); // Reset retains configuration.
  sumire_session_destroy(session); sumire_engine_close(engine);
  CHECK(prediction_score(result, "CATEGORY-PREDICT") == 3100);
  sumire_result_destroy(result);
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
static void test_generated_ascii_fullwidth_ranges(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  CHECK(sumire_engine_open(directory,0,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&session,error,sizeof error) == 0);
  const char *inputs[] = {"a1", "+", "a b"};
  const uint32_t lengths[] = {2,1,3};
  for (size_t index = 0; index < 6; ++index) {
    size_t input = index % 3;
    sumire_request request = {index+1,inputs[input],strlen(inputs[input]),0,1,200000,index < 3 ? 12u : 13u};
    sumire_result *result = NULL;
    CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
    size_t generated = 0;
    for (size_t i = 0; i < sumire_result_count(result); ++i) {
      sumire_candidate candidate;
      CHECK(sumire_result_candidate(result,i,&candidate) == 0);
      if (candidate.score != 30000 || candidate.segment_count != 0) continue;
      uint32_t kind, flags;
      CHECK(sumire_result_candidate_presentation_kind(result,i,&kind) == 0 && kind == SUMIRE_PRESENTATION_FULL_WIDTH);
      CHECK(sumire_result_candidate_flags(result,i,&flags) == 0 && flags == 0);
      CHECK(candidate.start_utf16 == 0 && candidate.length_utf16 == lengths[input]);
      ++generated;
    }
    CHECK(generated == 2);
    sumire_result_destroy(result);
  }
  sumire_session_destroy(session); sumire_engine_close(engine);
}
static void test_generated_numeric_ranges(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  CHECK(sumire_engine_open(directory,0,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&session,error,sizeof error) == 0);
  const char *input = "1";
  sumire_request request = {1,input,strlen(input),0,100,200000,12};
  sumire_result *result = NULL;
  CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
  int full_width = 0, half_width = 0, numeric_symbol = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate candidate;
    CHECK(sumire_result_candidate(result,i,&candidate) == 0);
    if (candidate.segment_count != 0) continue;
    CHECK(candidate.start_utf16 == 0 && candidate.length_utf16 == 1);
    uint32_t kind = 99;
    CHECK(sumire_result_candidate_presentation_kind(result,i,&kind) == 0);
    if (candidate.text.size == strlen("１") && memcmp(candidate.text.data,"１",candidate.text.size) == 0) {
      CHECK(candidate.score == 8000 && kind == SUMIRE_PRESENTATION_FULL_WIDTH);
      full_width = 1;
    } else if (candidate.text.size == strlen("1") && memcmp(candidate.text.data,"1",candidate.text.size) == 0 && candidate.score == 8000) {
      CHECK(kind == SUMIRE_PRESENTATION_HALF_WIDTH);
      half_width = 1;
    } else if (candidate.text.size == strlen("①") && memcmp(candidate.text.data,"①",candidate.text.size) == 0) {
      CHECK(candidate.score == 8500 && kind == SUMIRE_PRESENTATION_NUMERIC_SYMBOL);
      numeric_symbol = 1;
    }
  }
  CHECK(full_width && half_width && numeric_symbol);
  sumire_result_destroy(result);
  request = (sumire_request){2,input,strlen(input),0,100,200000,
      SUMIRE_REQUEST_DISABLE_NUMERIC_SYMBOL_CANDIDATES};
  result = NULL;
  CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
  int disabled_full_width = 0, disabled_half_width = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate candidate;
    CHECK(sumire_result_candidate(result,i,&candidate) == 0);
    if (candidate.segment_count != 0) continue;
    uint32_t kind = 99;
    CHECK(sumire_result_candidate_presentation_kind(result,i,&kind) == 0);
    if (candidate.text.size == strlen("１") && memcmp(candidate.text.data,"１",candidate.text.size) == 0) {
      CHECK(kind == SUMIRE_PRESENTATION_FULL_WIDTH);
      disabled_full_width = 1;
    }
    if (candidate.text.size == strlen("1") && memcmp(candidate.text.data,"1",candidate.text.size) == 0 && candidate.score == 8000) {
      CHECK(kind == SUMIRE_PRESENTATION_HALF_WIDTH);
      disabled_half_width = 1;
    }
    CHECK(kind != SUMIRE_PRESENTATION_NUMERIC_SYMBOL);
  }
  CHECK(disabled_full_width && disabled_half_width);
  sumire_result_destroy(result);
  sumire_session_destroy(session);
  sumire_engine_close(engine);
}
static void test_primary_presentation(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  CHECK(sumire_engine_open(directory,0,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&session,error,sizeof error) == 0);
  const char *inputs[] = {"12", "１２", "123", "Ａ", "ｶﾞ"};
  const uint32_t expected[] = {SUMIRE_PRESENTATION_HALF_WIDTH, SUMIRE_PRESENTATION_FULL_WIDTH,
    SUMIRE_PRESENTATION_NONE, SUMIRE_PRESENTATION_NONE, SUMIRE_PRESENTATION_NONE};
  for (size_t j = 0; j < 5; ++j) {
    sumire_request request = {j+1,inputs[j],strlen(inputs[j]),0,20,200000,0};
    sumire_result *result = NULL;
    CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
    sumire_candidate candidate;
    CHECK(sumire_result_candidate(result,0,&candidate) == 0);
    CHECK(candidate.segment_count > 0);
    CHECK(candidate.text.size == strlen(inputs[j]) && memcmp(candidate.text.data,inputs[j],candidate.text.size) == 0);
    uint32_t kind = 99;
    CHECK(sumire_result_candidate_presentation_kind(result,0,&kind) == 0 && kind == expected[j]);
    sumire_result_destroy(result);
  }
  sumire_personal_entry entry = {{"あい",strlen("あい")},{"１",strlen("１")},1,-10000,0};
  CHECK(sumire_session_set_personal(session,&entry,1,error,sizeof error) == 0);
  sumire_request request = {6,"あい",strlen("あい"),0,20,200000,0};
  sumire_result *result = NULL;
  CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
  sumire_candidate candidate;
  CHECK(sumire_result_candidate(result,0,&candidate) == 0);
  CHECK(candidate.text.size == strlen("１") && memcmp(candidate.text.data,"１",candidate.text.size) == 0);
  uint32_t kind = 99;
  CHECK(sumire_result_candidate_presentation_kind(result,0,&kind) == 0 && kind == SUMIRE_PRESENTATION_NONE);
  sumire_result_destroy(result); sumire_session_destroy(session); sumire_engine_close(engine);
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
      uint32_t kind = 99;
      CHECK(sumire_result_candidate_presentation_kind(result,i,&kind) == 0);
      CHECK(kind == SUMIRE_PRESENTATION_HALF_WIDTH);
      CHECK(candidate.start_utf16 == 0 && candidate.length_utf16 == lengths[j]);
      CHECK(sumire_session_commit(session,j+1,candidate.candidate_id,error,sizeof error) == 0);
      selected = i;
      found = 1;
    }
    CHECK(found);
    uint32_t invalid_kind = 99;
    CHECK(sumire_result_candidate_presentation_kind(NULL,0,&invalid_kind) == -1 && invalid_kind == 99);
    CHECK(sumire_result_candidate_presentation_kind(result,sumire_result_count(result),&invalid_kind) == -1 && invalid_kind == 99);
    CHECK(sumire_result_candidate_presentation_kind(result,0,NULL) == -1);
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
static void test_auxiliary_completion_ranges(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  CHECK(sumire_engine_open_with_dictionaries(directory,0,2,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&session,error,sizeof error) == 0);
  const char *readings[] = {"あいう", "😀あ"};
  const char *texts[] = {"⚪️", "(^_^)", "㎥"};
  const char *dictionaries[] = {"emoji", "emoticon", "symbol"};
  const int64_t scores[] = {7000,5000,3000};
  for (size_t r = 0; r < 2; ++r) {
    sumire_result *result = NULL;
    sumire_request request = {r+1,readings[r],strlen(readings[r]),0,20,200000,12};
    CHECK(sumire_session_update(session,&request,&result,error,sizeof error) == 0);
    unsigned found = 0;
    size_t symbol_index = (size_t)-1, kana_index = (size_t)-1;
    uint64_t commit_id = 0;
    for (size_t i = 0; i < sumire_result_count(result); ++i) {
      sumire_candidate candidate;
      CHECK(sumire_result_candidate(result,i,&candidate) == 0);
      if (candidate.segment_count == 0 && candidate.text.size == strlen(readings[r]) &&
          memcmp(candidate.text.data,readings[r],candidate.text.size) == 0) kana_index = i;
      for (size_t k = 0; k < 3; ++k) {
        if (candidate.text.size != strlen(texts[k]) || memcmp(candidate.text.data,texts[k],candidate.text.size) != 0) continue;
        CHECK(candidate.start_utf16 == 0 && candidate.length_utf16 == 3);
        CHECK(candidate.score == scores[k] && candidate.segment_count == 1);
        sumire_segment segment;
        CHECK(sumire_result_segment(result,i,0,&segment) == 0);
        CHECK(segment.start_utf16 == 0 && segment.length_utf16 == 3);
        CHECK(segment.dictionary.size == strlen(dictionaries[k]) && memcmp(segment.dictionary.data,dictionaries[k],segment.dictionary.size) == 0);
        uint32_t flags = 99;
        CHECK(sumire_result_candidate_flags(result,i,&flags) == 0 && flags == 0);
        uint32_t kind = 99;
        CHECK(sumire_result_candidate_presentation_kind(result,i,&kind) == 0);
        CHECK(kind == (k == 2 ? SUMIRE_PRESENTATION_NUMERIC_SYMBOL : SUMIRE_PRESENTATION_NONE));
        CHECK(sumire_result_bunsetsu_count(result,i) == 0);
        if (k == 2) symbol_index = i;
        found |= 1u << k;
        commit_id = candidate.candidate_id;
      }
    }
    CHECK(found == 7);
    CHECK(symbol_index != (size_t)-1 && kana_index != (size_t)-1 && symbol_index < kana_index);
    CHECK(sumire_session_commit(session,r+1,commit_id,error,sizeof error) == 0);
    sumire_result_destroy(result);
  }
  sumire_session_destroy(session);
  sumire_engine_close(engine);
}

static void test_release_categories(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  CHECK(sumire_category_count() == 30 && strcmp(sumire_category_name(12), "person") == 0);
  CHECK(sumire_release_category_count() == 143);
  CHECK(sumire_release_category_name(143) == NULL);
  for (size_t i = 0; i < sumire_release_category_count(); ++i) {
    CHECK(sumire_release_category_name(i) != NULL);
    for (size_t j = 0; j < i; ++j)
      CHECK(strcmp(sumire_release_category_name(i), sumire_release_category_name(j)) != 0);
  }
  CHECK(sumire_engine_open_with_category_ids(directory, NULL, 0, 4, &engine, error, sizeof error) == 0);
  sumire_engine_close(engine);
  const char *ids[] = {"facility/religious/shrine", "actor", "facility/religious/shrine", "character"};
  CHECK(sumire_engine_open_with_category_ids(directory, ids, 4, 4, &engine, error, sizeof error) == 0);
  sumire_session *session = NULL;
  sumire_result *result = NULL;
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_request request = {1, "あい", strlen("あい"), 0, 20, 200000, 0};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  int found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate candidate;
    CHECK(sumire_result_candidate(result, i, &candidate) == 0);
    if (candidate.text.size == 6 && memcmp(candidate.text.data, "SHRINE", 6) == 0) {
      CHECK(sumire_result_category_count(result, i) == 1);
      sumire_string category;
      CHECK(sumire_result_category(result, i, 0, &category) == 0);
      CHECK(category.size == strlen(ids[0]) && memcmp(category.data, ids[0], category.size) == 0);
      found = 1;
    }
  }
  CHECK(found);
  sumire_result_destroy(result); sumire_session_destroy(session); sumire_engine_close(engine);
  sumire_dictionary_browser *browser = NULL;
  CHECK(sumire_dictionary_browser_open(directory, ids[0], "あ", 0, &browser, error, sizeof error) == 0);
  CHECK(sumire_dictionary_browser_step(browser, 100, error, sizeof error) == 0);
  CHECK(sumire_dictionary_browser_count(browser) == 1);
  sumire_dictionary_browser_close(browser);
  CHECK(sumire_dictionary_browser_open(directory, "../system", "", 0, &browser, error, sizeof error) < 0);
  CHECK(browser == NULL);
  const char *invalid[] = {"../system", "/system", "facility/../system", "person", "unknown", "facility/religious/shrine.sud", NULL};
  for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; ++i) {
    engine = (sumire_engine *)1;
    CHECK(sumire_engine_open_with_category_ids(directory, &invalid[i], 1, 0, &engine, error, sizeof error) < 0);
    CHECK(engine == NULL);
  }
  CHECK(sumire_engine_open_with_category_ids(directory, NULL, 1, 0, &engine, error, sizeof error) < 0);
  CHECK(sumire_engine_open_with_category_ids(directory, NULL, 0, 8, &engine, error, sizeof error) < 0);
  CHECK(sumire_engine_open_with_category_ids(NULL, NULL, 0, 0, &engine, error, sizeof error) < 0);
  CHECK(sumire_engine_open_with_category_ids(directory, NULL, 0, 0, NULL, error, sizeof error) < 0);
}
static size_t metadata_candidate(sumire_result *result, const char *text) {
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    sumire_candidate c;
    CHECK(sumire_result_candidate(result, i, &c) == 0);
    if (c.text.size == strlen(text) && !memcmp(c.text.data, text, c.text.size)) return i;
  }
  return (size_t)-1;
}
static void test_learning_metadata_overlay(const char *directory) {
  char error[256];
  sumire_engine *engine = NULL;
  sumire_session *session = NULL;
  sumire_result *owned = NULL, *result = NULL;
  CHECK(sumire_engine_open_with_dictionaries(directory, 0, 1, &engine, error, sizeof error) == 0);
  CHECK(sumire_session_create(engine, &session, error, sizeof error) == 0);
  sumire_personal_entry personal = {{"あいあ", strlen("あいあ")}, {"PERSONAL", 8}, 1, -1000, 0};
  CHECK(sumire_session_set_personal(session, &personal, 1, error, sizeof error) == 0);
  char reading[] = "あいあ", text[] = "META";
  sumire_learning_entry entry = {{reading, strlen(reading)}, {text, 4}, 1, 2, -50000};
  CHECK(sumire_session_set_learning_entries(session, &entry, 1, error, sizeof error) == 0);
  memset(reading, 'x', strlen(reading)); memset(text, 'x', 4); // Setter owns both strings.
  sumire_request request = {1, "あいあ", strlen("あいあ"), 0, 100, 200000, 0};
  CHECK(sumire_session_update(session, &request, &owned, error, sizeof error) == 0);
  size_t meta = metadata_candidate(owned, "META"); CHECK(meta != (size_t)-1);
  sumire_candidate c; sumire_segment segment;
  CHECK(sumire_result_candidate(owned, meta, &c) == 0 && c.length_utf16 == 3 && c.segment_count == 1);
  uint16_t left = 99, right = 99;
  CHECK(sumire_result_segment_context_ids(owned, meta, 0, &left, &right) == 0 && left == 1 && right == 2);
  sumire_learning_entry invalid = {{"あいあ", strlen("あいあ")}, {"BAD", 3}, 1851, 2, 100};
  CHECK(sumire_session_set_learning_entries(session, &invalid, 1, error, sizeof error) < 0);
  invalid.left_id = 1; invalid.right_id = 3;
  CHECK(sumire_session_set_learning_entries(session, &invalid, 1, error, sizeof error) < 0);
  CHECK(sumire_session_set_learning_entries(session, &invalid, 10001, error, sizeof error) < 0);
  CHECK(sumire_session_set_learning_entries(session, NULL, 1, error, sizeof error) < 0);
  invalid.left_id = 1; invalid.right_id = 2;
  invalid.reading = (sumire_string){"\xff", 1};
  CHECK(sumire_session_set_learning_entries(session, &invalid, 1, error, sizeof error) < 0);
  CHECK(sumire_session_commit(session, 1, c.candidate_id, error, sizeof error) == 0);

  sumire_learning_entry ranked[] = {
    {{"あいあ", strlen("あいあ")}, {"HIGH", 4}, 1, 2, 8000},
    {{"あいあ", strlen("あいあ")}, {"LOW", 3}, 1, 2, 100}
  };
  CHECK(sumire_session_set_learning_entries(session, ranked, 2, error, sizeof error) == 0);
  request.generation = 2;
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  size_t low = metadata_candidate(result, "LOW"), high = metadata_candidate(result, "HIGH");
  CHECK(low != (size_t)-1 && high != (size_t)-1 && low < high);
  sumire_candidate low_candidate, high_candidate;
  CHECK(sumire_result_candidate(result, low, &low_candidate) == 0);
  CHECK(sumire_result_candidate(result, high, &high_candidate) == 0);
  CHECK(high_candidate.score - low_candidate.score == 7900);
  CHECK(sumire_session_set_learning_entries(session, NULL, 0, error, sizeof error) == 0);
  CHECK(sumire_session_commit(session, 2, low_candidate.candidate_id, error, sizeof error) < 0);
  sumire_result_destroy(result); result = NULL;

  sumire_learning_entry middle = {{"😀い", strlen("😀い")}, {"顔伊", strlen("顔伊")}, 1, 2, -50000};
  CHECK(sumire_session_set_learning_entries(session, &middle, 1, error, sizeof error) == 0);
  request = (sumire_request){3, "あ😀いあ", strlen("あ😀いあ"), 0, 100, 200000, 0};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  int found = 0;
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    CHECK(sumire_result_candidate(result, i, &c) == 0);
    for (size_t j = 0; j < c.segment_count; ++j) {
      CHECK(sumire_result_segment(result, i, j, &segment) == 0);
      if (segment.dictionary.size == 8 && !memcmp(segment.dictionary.data, "learning", 8)) {
        CHECK(segment.start_utf16 == 1 && segment.length_utf16 == 3);
        CHECK(sumire_result_segment_context_ids(result, i, j, &left, &right) == 0 && left == 1 && right == 2);
        found = 1;
      }
    }
  }
  CHECK(found);
  left = 77; right = 88;
  CHECK(sumire_result_segment_context_ids(NULL, 0, 0, &left, &right) < 0 && left == 77 && right == 88);
  CHECK(sumire_result_segment_context_ids(result, sumire_result_count(result), 0, &left, &right) < 0 && left == 77 && right == 88);
  CHECK(sumire_result_segment_context_ids(result, 0, 999, &left, &right) < 0 && left == 77 && right == 88);
  CHECK(sumire_result_segment_context_ids(result, 0, 0, NULL, &right) < 0);
  sumire_result_destroy(result); result = NULL;

  sumire_learning_entry many[101];
  for (size_t i = 0; i < 101; ++i) many[i] = middle;
  CHECK(sumire_session_set_learning_entries(session, many, 101, error, sizeof error) == 0);

  // The old setter still replaces only learned rows, with exact-input matching.
  sumire_personal_entry legacy = {{"あい", strlen("あい")}, {"LEGACY", 6}, 0, -90000, 2};
  CHECK(sumire_session_set_learning(session, &legacy, 1, error, sizeof error) == 0);
  request = (sumire_request){4, "あいあ", strlen("あいあ"), 0, 100, 200000, 0};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(metadata_candidate(result, "LEGACY") == (size_t)-1);
  CHECK(metadata_candidate(result, "PERSONAL") != (size_t)-1);
  for (size_t i = 0; i < sumire_result_count(result); ++i) {
    CHECK(sumire_result_candidate(result, i, &c) == 0);
    for (size_t j = 0; j < c.segment_count; ++j) {
      CHECK(sumire_result_segment(result, i, j, &segment) == 0);
      CHECK(segment.dictionary.size != 8 || memcmp(segment.dictionary.data, "learning", 8));
    }
  }
  sumire_result_destroy(result); result = NULL;
  request = (sumire_request){5, "あい", strlen("あい"), 0, 100, 200000, 0};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(metadata_candidate(result, "LEGACY") != (size_t)-1);
  CHECK(sumire_session_set_learning(session, &legacy, 101, error, sizeof error) < 0);
  sumire_result_destroy(result); result = NULL;
  sumire_learning_entry english = {{"hello", 5}, {"SavedEnglish", 12}, 1, 2, 100};
  CHECK(sumire_session_set_learning_entries(session, &english, 1, error, sizeof error) == 0);
  request = (sumire_request){6, "hel", 3, 0, 100, 200000, 2};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  CHECK(metadata_candidate(result, "SavedEnglish") == (size_t)-1);
  sumire_result_destroy(result); result = NULL;
  request = (sumire_request){7, "hello", 5, 0, 100, 200000, 2};
  CHECK(sumire_session_update(session, &request, &result, error, sizeof error) == 0);
  size_t english_index = metadata_candidate(result, "SavedEnglish"); CHECK(english_index != (size_t)-1);
  CHECK(sumire_result_segment_context_ids(result, english_index, 0, &left, &right) == 0 && left == 1 && right == 2);
  CHECK(sumire_session_set_learning_entries(session, NULL, 0, error, sizeof error) == 0);
  sumire_result_destroy(result);
  sumire_session_destroy(session); sumire_engine_close(engine);
  // The original result owns text and endpoint metadata after every replacement and close.
  CHECK(sumire_result_candidate(owned, meta, &c) == 0 && c.text.size == 4 && !memcmp(c.text.data, "META", 4));
  CHECK(sumire_result_segment_context_ids(owned, meta, 0, &left, &right) == 0 && left == 1 && right == 2);
  sumire_result_destroy(owned);
}

static void test_typed_dictionary_sources(const char *directory) {
  const sumire_dictionary_source unique[] = {
      {SUMIRE_DICTIONARY_SOURCE_RELEASE_LEAF, "character"},
      {SUMIRE_DICTIONARY_SOURCE_LEGACY_AGGREGATE, "character"}};
  const sumire_dictionary_source duplicate[] = {unique[0], unique[1], unique[0], unique[1]};
  char error[1024]; sumire_engine *a = NULL, *b = NULL;
  CHECK(sumire_engine_open_with_sources(directory, duplicate, 4, 0, &a, error, sizeof error) == 0);
  CHECK(sumire_engine_open_with_sources(directory, unique, 2, 0, &b, error, sizeof error) == 0);
  sumire_session *sa = NULL, *sb = NULL;
  CHECK(sumire_session_create(a, &sa, error, sizeof error) == 0);
  CHECK(sumire_session_create(b, &sb, error, sizeof error) == 0);
  sumire_request request = {1, "あい", 6, 0, 20, 10000, 0};
  sumire_result *ra = NULL, *rb = NULL;
  CHECK(sumire_session_update(sa, &request, &ra, error, sizeof error) == 0);
  CHECK(sumire_session_update(sb, &request, &rb, error, sizeof error) == 0);
  compare_results(ra, rb);
  const size_t leaf = metadata_candidate(ra, "SOURCE-LEAF"), aggregate = metadata_candidate(ra, "SOURCE-AGG");
  CHECK(leaf != (size_t)-1 && aggregate != (size_t)-1);
  sumire_segment ls, ag;
  CHECK(sumire_result_segment(ra, leaf, 0, &ls) == 0);
  CHECK(sumire_result_segment(ra, aggregate, 0, &ag) == 0);
  CHECK(ls.dictionary.size == strlen("character") && memcmp(ls.dictionary.data, "character", ls.dictionary.size) == 0);
  CHECK(ag.dictionary.size == strlen("legacy_aggregates/character") && memcmp(ag.dictionary.data, "legacy_aggregates/character", ag.dictionary.size) == 0);
  sumire_result_destroy(ra); sumire_result_destroy(rb);
  sumire_session_destroy(sa); sumire_session_destroy(sb); sumire_engine_close(a); sumire_engine_close(b);
  const sumire_dictionary_source invalid[] = {
      {9, "character"}, {SUMIRE_DICTIONARY_SOURCE_RELEASE_LEAF, "../character"},
      {SUMIRE_DICTIONARY_SOURCE_LEGACY_AGGREGATE, "unknown"},
      {SUMIRE_DICTIONARY_SOURCE_LEGACY_AGGREGATE, "legacy_aggregates/character"},
      {SUMIRE_DICTIONARY_SOURCE_RELEASE_LEAF, NULL}};
  for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; ++i) {
    a = (sumire_engine *)1;
    CHECK(sumire_engine_open_with_sources(directory, invalid + i, 1, 0, &a, error, sizeof error) != 0 && a == NULL);
  }
  CHECK(sumire_engine_open_with_sources(directory, unique, 100001, 0, &a, error, sizeof error) != 0 && a == NULL);
  CHECK(sumire_engine_open_with_sources(directory, NULL, 1, 0, &a, error, sizeof error) != 0 && a == NULL);
  CHECK(sumire_engine_open_with_sources(directory, unique, 2, 8, &a, error, sizeof error) != 0 && a == NULL);
  char marker[4096], hidden[4096];
  CHECK(snprintf(marker, sizeof marker, "%s/release-categories-v1.7.277", directory) > 0);
  CHECK(snprintf(hidden, sizeof hidden, "%s/marker.saved", directory) > 0);
  CHECK(rename(marker, hidden) == 0);
  CHECK(sumire_engine_open_with_sources(directory, unique, 2, 0, &a, error, sizeof error) != 0 && a == NULL);
  CHECK(rename(hidden, marker) == 0);
}
static void test_numeric_candidate_contexts(const char *directory) {
  CHECK(sumire_abi_version() == 1);
  if (sizeof(void *) == 8) {
    CHECK(sizeof(sumire_request) == 40 && sizeof(sumire_candidate) == 48 && sizeof(sumire_segment) == 40);
  }
  char error[256]; sumire_engine *engine = NULL; sumire_session *session = NULL;
  CHECK(sumire_engine_open(directory,0,&engine,error,sizeof error) == 0);
  CHECK(sumire_session_create(engine,&session,error,sizeof error) == 0);
  sumire_request request = {1,"1",1,0,100,200000,12};
  sumire_result *one = NULL, *time = NULL, *kana = NULL;
  CHECK(sumire_session_update(session,&request,&one,error,sizeof error) == 0);
  size_t superscript = (size_t)-1; int raw_absent = 0, generated = 0;
  for (size_t i = 0; i < sumire_result_count(one); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(one,i,&c) == 0);
    int known = 77; uint16_t left = 88, right = 99;
    CHECK(sumire_result_candidate_context_ids(one,i,&known,&left,&right) == 0);
    if (c.segment_count == 0) {
      CHECK(known == 1 && left == 2040 && right == 2040);
      CHECK(c.start_utf16 == 0 && c.length_utf16 == 1 && sumire_result_category_count(one,i) == 0);
      uint32_t flags = 99; CHECK(sumire_result_candidate_flags(one,i,&flags) == 0 && flags == 0);
      uint32_t kind = 99; CHECK(sumire_result_candidate_presentation_kind(one,i,&kind) == 0);
      if (c.text.size == strlen("１") && !memcmp(c.text.data,"１",c.text.size)) CHECK(kind == SUMIRE_PRESENTATION_FULL_WIDTH);
      if (c.text.size == 1 && c.text.data[0] == '1' && c.score == 8000) CHECK(kind == SUMIRE_PRESENTATION_HALF_WIDTH);
      if (c.text.size == strlen("①") && !memcmp(c.text.data,"①",c.text.size)) CHECK(kind == SUMIRE_PRESENTATION_NUMERIC_SYMBOL);
      if (c.text.size == strlen("¹") && !memcmp(c.text.data,"¹",c.text.size)) superscript = i;
      ++generated;
    } else if (c.score == 4000 && c.text.size == 1 && c.text.data[0] == '1') {
      CHECK(known == 0 && left == 0 && right == 0);
      CHECK(sumire_result_segment_context_ids(one,i,0,&left,&right) == 0);
      CHECK(left == 0 && right == 0); raw_absent = 1; // Existing segment contract remains unchanged.
    }
  }
  CHECK(generated > 8 && raw_absent && superscript != (size_t)-1);
  int known = 77; uint16_t left = 88, right = 99;
  CHECK(sumire_result_candidate_context_ids(NULL,0,&known,&left,&right) == -1 && known == 77 && left == 88 && right == 99);
  CHECK(sumire_result_candidate_context_ids(one,sumire_result_count(one),&known,&left,&right) == -1 && known == 77 && left == 88 && right == 99);
  CHECK(sumire_result_candidate_context_ids(one,0,NULL,&left,&right) == -1 && left == 88 && right == 99);
  CHECK(sumire_result_candidate_context_ids(one,0,&known,NULL,&right) == -1 && known == 77 && right == 99);
  CHECK(sumire_result_candidate_context_ids(one,0,&known,&left,NULL) == -1 && known == 77 && left == 88);
  request = (sumire_request){2,"0101",4,0,100,200000,12};
  CHECK(sumire_session_update(session,&request,&time,error,sizeof error) == 0);
  size_t time_index = (size_t)-1; int dated = 0;
  for (size_t i = 0; i < sumire_result_count(time); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(time,i,&c) == 0);
    if (c.segment_count != 0) continue;
    CHECK(sumire_result_candidate_context_ids(time,i,&known,&left,&right) == 0 && known == 1);
    int temporal = (c.text.size == strlen("01:01") && !memcmp(c.text.data,"01:01",c.text.size)) ||
      (c.text.size == strlen("01時01分") && !memcmp(c.text.data,"01時01分",c.text.size)) ||
      (c.text.size == strlen("1月1日") && !memcmp(c.text.data,"1月1日",c.text.size));
    CHECK(left == (temporal ? 1851 : 2040) && right == left);
    CHECK(c.start_utf16 == 0 && c.length_utf16 == 4 && c.segment_count == 0);
    if (temporal) { ++dated; time_index = i; }
  }
  CHECK(dated == 3 && time_index != (size_t)-1);
  request = (sumire_request){3,"あ",strlen("あ"),0,100,200000,12};
  CHECK(sumire_session_update(session,&request,&kana,error,sizeof error) == 0);
  int nil_utility = 0;
  for (size_t i = 0; i < sumire_result_count(kana); ++i) {
    sumire_candidate c; CHECK(sumire_result_candidate(kana,i,&c) == 0);
    if (!c.segment_count && c.score == 6000) {
      CHECK(sumire_result_candidate_context_ids(kana,i,&known,&left,&right) == 0 && known == 0 && left == 0 && right == 0);
      nil_utility = 1;
    }
  }
  CHECK(nil_utility);
  sumire_session_reset(session); sumire_session_destroy(session); sumire_engine_close(engine);
  CHECK(sumire_result_candidate_context_ids(one,superscript,&known,&left,&right) == 0 && known == 1 && left == 2040 && right == 2040);
  CHECK(sumire_result_candidate_context_ids(time,time_index,&known,&left,&right) == 0 && known == 1 && left == 1851 && right == 1851);
  sumire_candidate retained; uint32_t kind = 99;
  CHECK(sumire_result_candidate(one,superscript,&retained) == 0 && retained.segment_count == 0 && retained.length_utf16 == 1);
  CHECK(sumire_result_candidate_presentation_kind(one,superscript,&kind) == 0 && kind == SUMIRE_PRESENTATION_NONE);
  sumire_result_destroy(one); sumire_result_destroy(time); sumire_result_destroy(kana);
}

int main(int argc, char **argv) {
  test_bunsetsu_metadata_invalid_arguments();
  if (argc == 3 && strcmp(argv[2],"--numeric-contexts") == 0) {
    test_numeric_candidate_contexts(argv[1]); return 0;
  }
  if (argc == 3 && strcmp(argv[2], "--typed-sources") == 0) {
    test_typed_dictionary_sources(argv[1]); return 0;
  }
  if (argc == 3 && strcmp(argv[2], "--release-categories") == 0) {
    test_release_categories(argv[1]); return 0;
  }
  if (argc == 3 && strcmp(argv[2],"--ascii-generated") == 0) {
    test_generated_ascii_fullwidth_ranges(argv[1]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[2],"--numeric-generated") == 0) {
    test_generated_numeric_ranges(argv[1]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[2],"--aux-completion") == 0) {
    test_auxiliary_completion_ranges(argv[1]);
    return 0;
  }
  if (argc == 3 && strcmp(argv[2], "--prediction-settings") == 0) {
    test_prediction_settings(argv[1]); return 0;
  }
  if (argc == 3 && strcmp(argv[2], "--kotowaza-settings") == 0) {
    test_kotowaza_settings(argv[1]); return 0;
  }
  if (argc == 3 && strcmp(argv[2], "--bunsetsu-prediction") == 0) {
    test_bunsetsu_prediction_flags(argv[1]); return 0;
  }
  if (argc == 3 && strcmp(argv[2], "--bunsetsu-auxiliary-completion") == 0) {
    test_bunsetsu_auxiliary_completion(argv[1]); return 0;
  }
  if (argc == 3 && strcmp(argv[2], "--bunsetsu-ascii-provider") == 0) {
    test_bunsetsu_ascii_provider(argv[1]); return 0;
  }
  CHECK(argc == 2);
  test_learning_metadata_overlay(argv[1]);
  test_edit_reuse(argv[1]);
  test_bunsetsu_snapshot_metadata(argv[1]);
  test_candidate_origin_flags(argv[1]);
  test_category_prediction(argv[1]);
  test_pathless_kana_ranges(argv[1]);
  test_primary_presentation(argv[1]);
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
