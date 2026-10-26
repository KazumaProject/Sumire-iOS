#ifndef SUMIRE_C_API_H
#define SUMIRE_C_API_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* ABI v1. UTF-8 strings carry byte lengths; all input ranges are UTF-16 units.
 * Engines own read-only mappings. Sessions retain engines after engine_close.
 * Use each session on one serial queue. Separate sessions may run concurrently.
 * Results are immutable, independently owned snapshots. String pointers remain
 * valid until result_destroy; callers must copy strings before releasing it.
 * Every function catches C++ exceptions. Zero means success, negative means
 * error.
 */
typedef struct sumire_engine sumire_engine;
typedef struct sumire_session sumire_session;
typedef struct sumire_result sumire_result;
typedef struct {
  const char *data;
  size_t size;
} sumire_string;
typedef struct {
  uint64_t generation;
  const char *reading;
  size_t reading_bytes;
  uint32_t edit_start_utf16;
  uint32_t candidate_count; /* N-best limit, not total result limit: exact category matches, Japanese predictions and auxiliaries may add results. */
  uint32_t max_states;
  /* Bit 3 enables Japanese system/category completion: defaults 3..16 input units,
   * lookahead 3, up to 4 system and 4 per enabled category candidates.
   * Also includes kana forms and optional reading-correction completions
   * (3..16 input units, lookahead 3, no four-candidate cap). All consume only
   * the typed input. Correction metadata is queried separately below. */
  uint32_t flags; /* bit 0: kana omission; bit 1: English candidates (exclusive); bit 2: system reading-prefix candidates; bit 4: bunsetsu n-gram candidate ranking. */
} sumire_request;
typedef struct {
  uint64_t candidate_id;
  sumire_string text;
  int64_t score;
  uint32_t start_utf16;
  /* Consumed input, not output length. Pathless kana auxiliaries consume the
   * whole snapshot reading; dictionary prefixes retain their shorter range. */
  uint32_t length_utf16;
  size_t segment_count;
} sumire_candidate;
typedef struct {
  sumire_string text;
  sumire_string dictionary;
  uint32_t start_utf16;
  uint32_t length_utf16;
} sumire_segment;
typedef struct {
  uint64_t generation;
  double conversion_ms;
  size_t lattice_nodes;
  size_t expanded_states;
  int complete;
} sumire_metrics;
typedef struct {
  sumire_string reading;
  sumire_string text;
  uint32_t context_id;
  int32_t score;
  uint32_t kind; /* 0=user word, 1=exact-input template, 2=learning-only API */
} sumire_personal_entry;
/* Matches the pinned Android user-dictionary PosMapper; unknown indices map to
 * noun. */
uint16_t sumire_context_id_for_pos(int32_t pos_index);
/* Copies and validates the entire set atomically. Failure preserves previous
 * data. Success invalidates the current selection, but not independently owned
 * results. Maximum 100000 entries, 16 MiB UTF-8 text total; no silent
 * truncation.
 */
/* Independent exact-input learned overlay; at most 100 entries, kind=2,
 * context_id=0. Copies input, atomically replaces only learned entries and
 * invalidates latest commit IDs on success; errors preserve previous state. */
int sumire_session_set_learning(sumire_session *session,
                                const sumire_personal_entry *entries,
                                size_t count, char *error, size_t error_size);
int sumire_session_set_personal(sumire_session *session,
                                const sumire_personal_entry *entries,
                                size_t count, char *error, size_t error_size);
uint32_t sumire_abi_version(void);
/* Category bit i corresponds to category_name(i); zero selects only system. */
size_t sumire_category_count(void);
const char *sumire_category_name(size_t index);
/* v1.7.277 leaf catalog; names have static lifetime. Legacy catalog/mask stays unchanged. */
size_t sumire_release_category_count(void);
const char *sumire_release_category_name(size_t index);
/* Select release leaf IDs, not filesystem paths. Duplicates are ignored.
 * count==0 accepts ids==NULL. Unknown/null IDs and unknown flags fail atomically. */
int sumire_engine_open_with_category_ids(const char *directory, const char *const *ids,
                                         size_t count, uint32_t flags,
                                         sumire_engine **out, char *error, size_t error_size);
int sumire_engine_open(const char *directory, uint32_t category_mask,
                       sumire_engine **out, char *error, size_t error_size);
/* Additive ABI v1 entry point. Dictionary flags: bit 0 loads English words,
 * bit 1 loads kana-to-English readings; bit 2 disables standalone priority.
 * Otherwise an optional standalone.sud is loaded when present. A corrupt
 * present file fails; older dictionaries without this file remain supported.
 * Missing/corrupt requested files fail
 * atomically. Zero has the same behavior as sumire_engine_open.
 * English mode uses locale-independent Unicode casing. User words match a
 * case-sensitive reading prefix; templates and learning require exact input.
 * Their stored surfaces and scores are preserved (no Japanese connection cost).
 */
int sumire_engine_open_with_dictionaries(const char *directory, uint32_t category_mask,
                                        uint32_t dictionary_flags, sumire_engine **out,
                                        char *error, size_t error_size);
void sumire_engine_close(sumire_engine *engine);
/* 1 if the optional standalone table was loaded and enabled, otherwise 0. */
int sumire_engine_has_standalone_priority(const sumire_engine *engine);
int sumire_session_create(sumire_engine *engine, sumire_session **out,
                          char *error, size_t error_size);
void sumire_session_destroy(sumire_session *session);
/* Reuses bounded dictionary search rows when their inspected UTF-16 prefix
 * is unchanged. Viterbi costs and A* are recalculated for the whole lattice.
 * edit_start is validated; actual common prefix is verified from both readings. After the first request, generation must strictly
 * increase, including across resets. A failed request does not replace the
 * previous valid session result.
 */
int sumire_session_update(sumire_session *session,
                          const sumire_request *request, sumire_result **out,
                          char *error, size_t error_size);
void sumire_result_destroy(sumire_result *result);
size_t sumire_result_count(const sumire_result *result);
int sumire_result_candidate(const sumire_result *result, size_t index,
                            sumire_candidate *out);
/* Additive ABI v1 origin flags. Reading-prefix denotes reference type 5:
 * a yomiPartList match consuming strictly less than the complete reading.
 * Returns 0 on success, -1 for invalid result/index/output. */
#define SUMIRE_CANDIDATE_READING_PREFIX (1u << 0)
int sumire_result_candidate_flags(const sumire_result *result, size_t index,
                                   uint32_t *out);
/* Additive presentation metadata; never infer origin from the visible surface.
 * 0=none, 1=half width, 2=full width, 3=symbol with short numeric-width badge. */
enum {
  SUMIRE_PRESENTATION_NONE = 0, SUMIRE_PRESENTATION_HALF_WIDTH = 1,
  SUMIRE_PRESENTATION_FULL_WIDTH = 2, SUMIRE_PRESENTATION_NUMERIC_SYMBOL = 3
};
int sumire_result_candidate_presentation_kind(const sumire_result *result,
                                             size_t index, uint32_t *out);
/* Optional reading-correction metadata, owned by the result. Non-correction
 * candidates return empty strings. Display/commit only candidate.text; raw
 * payload may contain a TAB delimiter. Returns -1 for invalid arguments. */
int sumire_result_reading_correction(const sumire_result *result, size_t index,
                                     sumire_string *raw, sumire_string *reading);
int sumire_result_segment(const sumire_result *result, size_t candidate_index,
                          size_t segment_index, sumire_segment *out);
/* Interior UTF-16 reading offsets from this candidate's own path. No
 * boundaries for single-word / prediction candidates. Additive ABI v1 API;
 * existing structs are unchanged. Invalid result/candidate returns count 0.
 */
size_t sumire_result_bunsetsu_count(const sumire_result *result, size_t candidate_index);
/* Category origins from selected paths and exact duplicates, separate from segments.
 * Strings retain result lifetime. Existing ABI structs remain unchanged. */
size_t sumire_result_category_count(const sumire_result *result, size_t candidate_index);
int sumire_result_category(const sumire_result *result, size_t candidate_index,
                          size_t category_index, sumire_string *out);
/* Returns 0 on success, -1 for invalid arguments/index. Copies an offset. */
int sumire_result_bunsetsu_boundary(const sumire_result *result, size_t candidate_index,
                                   size_t boundary_index, uint32_t *out_utf16);
/* Diagnostics: immutable dictionary-search rows only, not Viterbi/A* reuse. */
int sumire_result_search_rows(const sumire_result *result, size_t *reused, size_t *searched);
int sumire_result_metrics(const sumire_result *result, sumire_metrics *out);
/* Commit only the most recent successful generation. Result snapshots remain
 * valid. On success clears the session selection; committed text is in the
 * caller's snapshot. Learning persistence is not yet implemented by this ABI.
 */
int sumire_session_commit(sumire_session *session, uint64_t generation,
                          uint64_t candidate_id, char *error,
                          size_t error_size);
void sumire_session_reset(sumire_session *session);
// Serial-session calls. Purging does not invalidate retained result handles.
// This reports retained workspace capacity, not peak conversion or process memory.
size_t sumire_session_cache_bytes(const sumire_session *session);
void sumire_session_purge_cache(sumire_session *session);
#ifdef __cplusplus
}
#endif
#endif
