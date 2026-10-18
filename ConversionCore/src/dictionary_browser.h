#ifndef SUMIRE_DICTIONARY_BROWSER_H
#define SUMIRE_DICTIONARY_BROWSER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Read-only browsing of one validated runtime .sud dictionary. All calls except
 * cancel are serial. cancel may run concurrently while the handle remains alive.
 * No connection matrix, conversion session, or editable dictionary is involved.
 * Text pointers returned by row remain valid until next step or close.
 * A page holds at most 100 rows. step examines at most 4096 trie nodes/tokens;
 * callers must continue on a background queue when count=0 and done=0.
 * mode 0: reading prefix (LOUDS indexed), 1: literal surface substring scan,
 * 2: reading or surface substring after NFKC, root lowercase, and kana folding.
 * UTF-8 query is bounded to 1024 bytes. Readings are limited to 1024 UTF-16
 * units and surfaces to 64 KiB; oversized records fail explicitly. Modes 0/1 do not normalize; mode 2 follows the reference dictionary browser.
 */
typedef struct sumire_dictionary_browser sumire_dictionary_browser;
typedef struct {
    const char *reading;
    size_t reading_bytes;
    const char *surface;
    size_t surface_bytes;
    uint32_t token_id;
    uint16_t context_id; /* Stored POS/context-table index, not a named POS. */
    int16_t word_cost;
} sumire_dictionary_row;
int sumire_dictionary_browser_open(const char *directory, const char *name,
                                   const char *query, uint32_t mode,
                                   sumire_dictionary_browser **out,
                                   char *error, size_t error_size);
void sumire_dictionary_browser_close(sumire_dictionary_browser *browser);
void sumire_dictionary_browser_cancel(sumire_dictionary_browser *browser);
int sumire_dictionary_browser_step(sumire_dictionary_browser *browser,
                                   size_t capacity, char *error, size_t error_size);
size_t sumire_dictionary_browser_count(const sumire_dictionary_browser *browser);
int sumire_dictionary_browser_row(const sumire_dictionary_browser *browser,
                                  size_t index, sumire_dictionary_row *out);
int sumire_dictionary_browser_done(const sumire_dictionary_browser *browser);
/* Number of rows reachable from reading terminals, distinct from raw token count. */
size_t sumire_dictionary_browser_entry_count(const sumire_dictionary_browser *browser);
size_t sumire_dictionary_browser_token_count(const sumire_dictionary_browser *browser);
size_t sumire_dictionary_browser_mapped_bytes(const sumire_dictionary_browser *browser);
#ifdef __cplusplus
}
#endif
#endif
