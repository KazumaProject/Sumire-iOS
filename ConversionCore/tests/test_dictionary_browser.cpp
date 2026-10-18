#include "dictionary_browser.h"
#include <cstdlib>
#include <iostream>
#include <string>
// Assertions disappear with NDEBUG; these checks must also execute ABI calls
// in Release CI builds.
static void check(bool condition, const char *expression, int line) {
    if (!condition) {
        std::cerr << "browser check failed at line " << line << ": " << expression << '\n';
        std::exit(EXIT_FAILURE);
    }
}
#define CHECK(expression) check((expression), #expression, __LINE__)

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    sumire_dictionary_browser *browser = nullptr;
    char error[512]{};
    if (sumire_dictionary_browser_open(argv[1], argv[2], argv[3], std::stoul(argv[4]), &browser, error, sizeof error)) {
        std::cerr << error << '\n'; return 1;
    }
    const bool quiet = argc > 5;
    const auto total = sumire_dictionary_browser_token_count(browser);
    if (argc > 5 && std::string(argv[5]) == "bounded") {
        CHECK(sumire_dictionary_browser_step(browser, 100, error, sizeof error) == 0);
        CHECK(sumire_dictionary_browser_count(browser) == 0);
        CHECK(sumire_dictionary_browser_done(browser) == 0);
        sumire_dictionary_browser_close(browser);
        return 0;
    }
    size_t count = 0;
    while (!sumire_dictionary_browser_done(browser)) {
        if (sumire_dictionary_browser_step(browser, 3, error, sizeof error)) {
            std::cerr << error << '\n'; sumire_dictionary_browser_close(browser); return 1;
        }
        const auto size = sumire_dictionary_browser_count(browser);
        CHECK(size <= 3);
        for (size_t i = 0; i < size; ++i) {
            sumire_dictionary_row row{};
            CHECK(sumire_dictionary_browser_row(browser, i, &row) == 0);
            if (!quiet) std::cout << row.token_id << '\t' << row.context_id << '\t' << row.word_cost << '\t'
                << std::string(row.reading, row.reading_bytes) << '\t' << std::string(row.surface, row.surface_bytes) << '\n';
            ++count;
        }
        sumire_dictionary_row invalid{};
        CHECK(sumire_dictionary_browser_row(browser, size, &invalid) == -1);
    }
    if (quiet) std::cout << count << '\t' << total << '\t' << sumire_dictionary_browser_mapped_bytes(browser) << '\t' << sumire_dictionary_browser_entry_count(browser) << '\n';
    sumire_dictionary_browser_close(browser);
    // Cancellation of a live traversal must return an error and no partial page.
    CHECK(sumire_dictionary_browser_open(argv[1], argv[2], "", 0, &browser, error, sizeof error) == 0);
    sumire_dictionary_browser_cancel(browser);
    CHECK(sumire_dictionary_browser_step(browser, 100, error, sizeof error) == -1);
    CHECK(sumire_dictionary_browser_count(browser) == 0);
    sumire_dictionary_browser_close(browser);
}
