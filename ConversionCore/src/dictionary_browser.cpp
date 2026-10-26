#include "dictionary_browser.h"
#include "dictionary_format.hpp"
#include "unicode_case.hpp"
#include <atomic>
#include <cstdio>

using sumire::detail::Dictionary;
using sumire::detail::require;
namespace {
std::u16string normalizedSearch(const std::u16string &value) {
    auto normalized = sumire::unicode_lower(sumire::unicode_nfkc(value));
    for (auto &c : normalized) if (c >= 0x30a1 && c <= 0x30f6) c -= 0x60;
    return normalized;
}
}

struct sumire_dictionary_browser {
    Dictionary dictionary;
    std::atomic<bool> cancelled{false};
    struct Frame { size_t node, child; };
    struct Row { std::string reading, surface; uint32_t token; uint16_t context; int16_t cost; };
    std::vector<Frame> stack;
    std::vector<Row> rows;
    std::string query;
    std::u16string normalizedQuery;
    uint32_t mode, token = 0, tokenEnd = 0;
    size_t current = 0, entryCount = 0;
    bool first = true, done = false;
    sumire_dictionary_browser(const char *dir, const char *name, const char *q, uint32_t m)
        : dictionary(dir, name), query(q), mode(m) {
        for (auto term : dictionary.terms)
            entryCount += dictionary.postings[term + 1] - dictionary.postings[term];
        if (mode == 2) normalizedQuery = normalizedSearch(sumire::utf16(query));
        size_t node = 0;
        if (!mode) for (auto c : sumire::utf16(query)) {
            auto child = dictionary.tree.select0(dictionary.tree.rank(node)) + 1;
            while (dictionary.tree.at(child)) {
                const auto index = dictionary.tree.rank(child);
                require(index < dictionary.labels.size(), "invalid label index");
                if (dictionary.labels[index] == c) break;
                ++child;
            }
            if (!dictionary.tree.at(child)) { done = true; return; }
            node = child;
        }
        current = node;
        stack.push_back({node, dictionary.tree.select0(dictionary.tree.rank(node)) + 1});
    }
    bool nextNode() {
        if (first) { first = false; return true; }
        while (!stack.empty()) {
            auto &frame = stack.back();
            if (!dictionary.tree.at(frame.child)) { stack.pop_back(); continue; }
            auto child = frame.child++;
            require(child > frame.node && dictionary.tree.rank(child) < dictionary.labels.size(), "invalid trie traversal");
            require(stack.size() < 1024, "dictionary reading exceeds browser depth limit");
            current = child;
            stack.push_back({child, dictionary.tree.select0(dictionary.tree.rank(child)) + 1});
            return true;
        }
        return false;
    }
    std::u16string reading() const {
        std::u16string result;
        for (auto node = current; node;) {
            require(result.size() < 1024, "dictionary reading exceeds browser depth limit");
            const auto index = dictionary.tree.rank(node);
            require(index < dictionary.labels.size(), "invalid label index");
            result.push_back(dictionary.labels[index]);
            auto parent = dictionary.tree.select1(node + 1 - dictionary.tree.rank(node));
            require(parent < node, "invalid trie parent");
            node = parent;
        }
        std::reverse(result.begin(), result.end());
        return result;
    }
};
namespace {
void errorText(char *out, size_t size, const char *text) {
    if (out && size) std::snprintf(out, size, "%s", text);
}
bool allowedName(const std::string &name) {
    if (name == "system" || name == "english" || name == "english_reading") return true;
    auto names = sumire::category_names();
    const auto release = sumire::release_category_names();
    names.insert(names.end(), release.begin(), release.end());
    return std::find(names.begin(), names.end(), name) != names.end();
}
}
extern "C" int sumire_dictionary_browser_open(const char *directory, const char *name,
 const char *query, uint32_t mode, sumire_dictionary_browser **out, char *error, size_t size) {
    if (out) *out = nullptr;
    try {
        require(out && directory && name && query && mode <= 2, "invalid browser request");
        require(std::strlen(query) <= 1024 && allowedName(name), "invalid dictionary name or query");
        (void)sumire::utf16(query);
        *out = new sumire_dictionary_browser(directory, name, query, mode);
        return 0;
    } catch (const std::exception &e) { errorText(error, size, e.what()); }
      catch (...) { errorText(error, size, "dictionary browser failed"); }
    return -1;
}
extern "C" void sumire_dictionary_browser_close(sumire_dictionary_browser *b) { delete b; }
extern "C" void sumire_dictionary_browser_cancel(sumire_dictionary_browser *b) { if (b) b->cancelled.store(true); }
extern "C" int sumire_dictionary_browser_step(sumire_dictionary_browser *b, size_t capacity, char *error, size_t size) {
    try {
        require(b && capacity > 0 && capacity <= 100, "invalid page capacity");
        b->rows.clear();
        for (size_t work = 0; work < 4096 && b->rows.size() < capacity && !b->done; ++work) {
            require(!b->cancelled.load(), "dictionary browsing cancelled");
            if (b->token < b->tokenEnd) {
                const auto token = b->token++;
                auto reading = b->reading();
                const auto ref = b->dictionary.refs[token];
                if (ref < 0xfffffffeU)
                    require(b->dictionary.offsets[ref + 1] - b->dictionary.offsets[ref] <= 65536,
                            "dictionary surface exceeds browser 64 KiB limit");
                auto surface = b->dictionary.surface(token, reading, 0, reading.size());
                if (b->mode == 1 && surface.find(b->query) == std::string::npos) continue;
                if (b->mode == 2 && !b->normalizedQuery.empty() &&
                    normalizedSearch(reading).find(b->normalizedQuery) == std::u16string::npos &&
                    normalizedSearch(sumire::utf16(surface)).find(b->normalizedQuery) == std::u16string::npos) continue;
                b->rows.push_back({sumire::utf8(reading), std::move(surface), token,
                                  b->dictionary.pos[token], b->dictionary.costs[token]});
            } else {
                if (!b->nextNode()) { b->done = true; break; }
                if (b->dictionary.leaf.at(b->current)) {
                    auto term = b->dictionary.terms[b->dictionary.leaf.rank(b->current) - 1];
                    b->token = b->dictionary.postings[term];
                    b->tokenEnd = b->dictionary.postings[term + 1];
                }
            }
        }
        return 0;
    } catch (const std::exception &e) { errorText(error, size, e.what()); }
      catch (...) { errorText(error, size, "dictionary browsing failed"); }
    if (b) { b->rows.clear(); b->done = true; }
    return -1;
}
extern "C" size_t sumire_dictionary_browser_count(const sumire_dictionary_browser *b) { return b ? b->rows.size() : 0; }
extern "C" int sumire_dictionary_browser_row(const sumire_dictionary_browser *b, size_t i, sumire_dictionary_row *out) {
    if (!b || !out || i >= b->rows.size()) return -1;
    const auto &r = b->rows[i];
    *out = {r.reading.data(), r.reading.size(), r.surface.data(), r.surface.size(), r.token, r.context, r.cost};
    return 0;
}
extern "C" int sumire_dictionary_browser_done(const sumire_dictionary_browser *b) { return !b || b->done; }
extern "C" size_t sumire_dictionary_browser_token_count(const sumire_dictionary_browser *b) { return b ? b->dictionary.pos.size() : 0; }
extern "C" size_t sumire_dictionary_browser_mapped_bytes(const sumire_dictionary_browser *b) { return b ? b->dictionary.file.size : 0; }

extern "C" size_t sumire_dictionary_browser_entry_count(const sumire_dictionary_browser *b) { return b ? b->entryCount : 0; }
