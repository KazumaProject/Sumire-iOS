package com.kazumaproject.markdownhelperkeyboard.converter

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.kazumaproject.markdownhelperkeyboard.dictionary_override.*
import com.kazumaproject.markdownhelperkeyboard.repository.UserDictionaryRepository
import com.kazumaproject.markdownhelperkeyboard.converter.engine.PredictionConfig
import com.kazumaproject.markdownhelperkeyboard.converter.path_algorithm.FindPath
import com.kazumaproject.markdownhelperkeyboard.converter.ngram.SystemNgramAssetLoader
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.runner.RunWith
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import android.os.Looper
import android.widget.FrameLayout
import com.kazumaproject.markdownhelperkeyboard.converter.candidate.*
import com.kazumaproject.markdownhelperkeyboard.converter.date.*
import com.kazumaproject.markdownhelperkeyboard.converter.utility.*
import com.kazumaproject.markdownhelperkeyboard.ime_service.candidate.CandidateDisplayMerger
import com.kazumaproject.markdownhelperkeyboard.ime_service.adapters.SuggestionAdapter
import com.kazumaproject.markdownhelperkeyboard.ime_service.extensions.containsHentaigana
import com.kazumaproject.markdownhelperkeyboard.ime_service.extensions.correctReading
import com.kazumaproject.markdownhelperkeyboard.ng_word.NgWordMatcher
import org.robolectric.Shadows.shadowOf
import org.junit.Assert.*
import java.util.Locale
import java.util.TimeZone

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "ja-rJP")
class SumireIOSDisplayBaselineTest {
    @Test fun exportDisplayCandidates() = runBlocking {
        val oldLocale = Locale.getDefault()
        val oldZone = TimeZone.getDefault()
        Locale.setDefault(Locale.JAPAN)
        TimeZone.setDefault(TimeZone.getTimeZone("Asia/Tokyo"))
        try {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = DictionaryOverrideStore(context, DictionaryOverrideValidator())
        ClassifiedDictionaries.categories.forEach { store.setOptionalBundledEnabled(it, true) }
        val reader = DictionaryBinaryReader(DictionarySourceResolver(context, store), store)
        val systemNgram = SystemNgramAssetLoader.load(context)
        check(systemNgram.ruleCount > 0) { "bundled SystemNgram assets did not load" }
        val path = FindPath(systemNgramDictionaryProvider = { systemNgram })
        val engine = TestEngineFactory.create(findPath = path)
        engine.setDictionaryBinaryReader(reader)
        engine.initializeOptionalDictionaryStateFromCurrentSources()
        assertEquals(ClassifiedDictionaries.categories, engine.loadedClassifiedCategories())
        val repository = mock<UserDictionaryRepository>()
        whenever(repository.commonPrefixSearchInUserDict(any())).thenReturn(emptyList())
        val inputs = listOf("にほんご", "とうきょう", "あい", "はし", "かみ", "きしゃ", "しろ", "しろい", "しろくろ", "しろあり", "しろい", "みにゅうりょくじ", "にて", "ひを", "がっこう", "かつこう", "びょういん", "きょうはいいてんきですね", "わたしはにほんごをにゅうりょくします", "このあぷりのへんかんこうほをこうそくにしたい")
        val output = File("build/reports/sumire-ios-display-baseline.jsonl")
        output.parentFile.mkdirs()
        output.bufferedWriter().use { writer ->
            for (original in listOf(false, true)) for (all in listOf(false, true)) for (input in (inputs + listOf("にほん", "とうき", "かっこん", "あせん", "あめり", "りゅう")).distinct()) {
                val result = if (original) engine.getCandidatesOriginal(input=input, n=20,
                    enabledDictionaryCategories=if(all) ClassifiedDictionaries.categories else emptySet(),
                    userDictionaryRepository=repository, learnRepository=null,
                    typoCorrectionOffsetScore=3000, omissionSearchOffsetScore=1900,
                    beamWidth=20, isOmissionSearchEnable=false,
                    predictionConfig=PredictionConfig()
) else engine.getCandidates(input=input, n=20,
                    enabledDictionaryCategories=if(all) ClassifiedDictionaries.categories else emptySet(),
                    userDictionaryRepository=repository, learnRepository=null,
                    typoCorrectionOffsetScore=3000, omissionSearchOffsetScore=1900,
                    beamWidth=20, isOmissionSearchEnable=false,
                    predictionConfig=PredictionConfig()
)
                val row = JSONObject().put("schema_version", 1).put("platform", "Android").put("reading",input).put("categories",if(all) "all" else "none")
                    .put("source_revision","df1f38315bf56d860d32919a3eaed6a75499e91e")
                    .put("path",if(original) "KanaKanjiEngine.getCandidatesOriginal" else "KanaKanjiEngine.getCandidates")
                    .put("prediction",true).put("prediction_minimum_input",3).put("prediction_limit",4).put("prediction_lookahead",3).put("prediction_aggressiveness","standard")
                    .put("n",20).put("beam_width",20).put("omission",false)
                    .put("system_ngram_rule_count",systemNgram.ruleCount)
                    .put("system_ngram_storage_bytes",systemNgram.storageBytes)
                val projected = project(input, result)
                row.put("configuration", JSONObject()
                    .put("locale", "ja-JP").put("timezone", "Asia/Tokyo")
                    .put("tail", "").put("suppress_hentaigana", false)
                    .put("personal_learning_macros_ng_romaji_ai_utility_saved_order", "disabled")
                    .put("live_conversion", false).put("inline_suggestions", false)
                    .put("bunsetsu", false).put("incremental_session", false).put("dictionary_labels", false)
                    .put("date_formats", JSONArray(DateCandidateConfig.DEFAULT_ORDER.map { it.preferenceValue })))
                row.put("raw_candidates", JSONArray(result.mapIndexed { index, c -> metadata(c).put("raw_index", index) }))
                row.put("projected_candidates", JSONArray(projected.map { c -> metadata(c).put("raw_indices", JSONArray(result.indices.filter { index -> if(c.type == CANDIDATE_TYPE_TEXT_MACRO) result[index].type == c.type && result[index].sourceId == c.sourceId else result[index].type != CANDIDATE_TYPE_TEXT_MACRO && result[index].string == c.string })) }))
                row.put("adapter_items", bind(projected, context))
                writer.appendLine(row.toString())
            }
        }
        } finally {
            Locale.setDefault(oldLocale)
            TimeZone.setDefault(oldZone)
        }
    }

    // This explicit harness follows the constrained OFF branches in IMEService;
    // it invokes production pure functions, not the private IMEService wrappers.
    private fun project(input: String, raw: List<Candidate>, suppress: Boolean = false): List<Candidate> {
        val session = DateCandidateComposer.compose(input, raw, DateCandidateConfig())
        val filtered = session.filter { !NgWordMatcher.matchesAny(input, it.string, emptyList()) }
            .filterNot { suppress && it.string.containsHentaigana() }
        val merged = CandidateDisplayMerger.merge(filtered)
        val ordered = ExactInputCandidatePromotionPolicy.promote(input,
            DateCandidateComposer.compose(input, merged, DateCandidateConfig()))
        val config = UtilityCandidateConfig(calculationEnabled=false, unitConversionEnabled=false, formulaCandidateEnabled=false)
        return UtilityCandidateComposer.compose(input, ordered, UtilityCandidateProvider().provide(input, config))
    }

    private fun metadata(c: Candidate): JSONObject = JSONObject()
        .put("text", c.string).put("text_utf16", JSONArray(c.string.map { it.code }))
        .put("commit_text", c.commitText)
        .put("effective_commit_text", if(c.type == 15.toByte()) c.string.correctReading().first else c.commitText)
        .put("correction_reading", if(c.type == 15.toByte()) c.string.correctReading().second else JSONObject.NULL)
        .put("score", c.score).put("length_utf16", c.length.toInt()).put("type", c.type.toInt())
        .put("yomi", c.yomi ?: JSONObject.NULL).put("left_id", c.leftId?.toInt() ?: JSONObject.NULL)
        .put("right_id", c.rightId?.toInt() ?: JSONObject.NULL).put("source_id", c.sourceId ?: JSONObject.NULL)
        .put("date_format", c.dateFormat?.preferenceValue ?: JSONObject.NULL)
        .put("dictionary_categories", JSONArray(c.dictionaryCategories.map { it.name }.sorted()))
        .put("standalone_unigram_matched", c.standaloneUnigramMatched)
        .put("conversion_segments", JSONArray(c.conversionSegments.map { segment -> JSONObject()
            .put("input_start", segment.inputStart).put("input_end", segment.inputEnd).put("output", segment.output) }))
        .put("presentation", JSONObject.NULL)
        .also { check(c.presentation == null) { "Formula presentation outside this fixed disabled-utility export scope" } }

    private fun bind(candidates: List<Candidate>, context: Context): JSONArray {
        val adapter = SuggestionAdapter()
        try {
            adapter.setShowCandidateYomiForLiveConversion(false)
            adapter.setShowDictionaryCandidateLabels(false)
            var committed = false
            adapter.onListUpdated = { committed = true }
            adapter.suggestions = candidates
            repeat(200) {
                shadowOf(Looper.getMainLooper()).idle()
                if (!committed && candidates.isNotEmpty()) Thread.sleep(10)
            }
            assertTrue("Adapter list did not commit", committed || candidates.isEmpty())
            assertEquals(candidates.size, adapter.itemCount)
            assertEquals(candidates, adapter.buildClickCandidatesForTesting())
            val parent = FrameLayout(context)
            val holder = adapter.onCreateViewHolder(parent, SuggestionAdapter.VIEW_TYPE_SUGGESTION) as SuggestionAdapter.SuggestionViewHolder
            return JSONArray(candidates.indices.map { index ->
                adapter.onBindViewHolder(holder, index)
                JSONObject().put("candidate_index", index).put("text", holder.text.text.toString())
                    .put("type_label", holder.typeText.text.toString()).put("yomi_label", holder.yomiText.text.toString())
            })
        } finally { adapter.release() }
    }

    @Test fun productionProjectionRetainsMacroIdentityAndCorrectionMetadata() {
        val first = Candidate("同じ", 1, 2u, 10, dictionaryCategories=setOf(DictionaryCategory.CLASSIFIED_PERSON))
        val duplicate = first.copy(type=9, score=20, dictionaryCategories=setOf(DictionaryCategory.CLASSIFIED_PLACE))
        val macro = first.copy(type=CANDIDATE_TYPE_TEXT_MACRO, sourceId=1)
        val otherMacro = macro.copy(sourceId=2)
        val corrected = Candidate("同じ\tおなじ", 15, 2u, 5)
        val result = project("おなじ", listOf(first, duplicate, macro, otherMacro, corrected))
        assertEquals(4, result.size)
        assertEquals(10, result[0].score)
        assertEquals(first.dictionaryCategories + duplicate.dictionaryCategories, result[0].dictionaryCategories)
        assertEquals(listOf(1L, 2L), result.filter { it.type == CANDIDATE_TYPE_TEXT_MACRO }.map { it.sourceId })
        assertEquals("同じ", metadata(result.last()).getString("effective_commit_text"))
        assertEquals("おなじ", metadata(result.last()).getString("correction_reading"))
    }

    @Test fun productionProjectionPreservesRawUtf16AndFirstCommitIdentity() {
        val first = Candidate("同じ", 1, 2u, 10, commitText="最初", dictionaryCategories=setOf(DictionaryCategory.CLASSIFIED_PERSON))
        val second = first.copy(commitText="別", dictionaryCategories=setOf(DictionaryCategory.CLASSIFIED_PLACE))
        val result = project("おなじ", listOf(first, second))
        assertEquals(listOf(first), result)
        val precomposed = Candidate("é", 1, 1u, 1)
        val decomposed = precomposed.copy(string="e\u0301")
        assertEquals(2, project("え", listOf(precomposed, decomposed)).size)
        val exact = Candidate("え", 3, 1u, 9)
        assertEquals(exact, project("え", listOf(precomposed, exact)).first())
        val historic = Candidate(String(Character.toChars(0x1B005)), 13, 1u, 1)
        assertEquals(emptyList<Candidate>(), project("を", listOf(historic), suppress=true))
        assertEquals(listOf(historic), project("を", listOf(historic), suppress=false))
    }

    @Test fun actualAdapterBindsCorrectionAndPartialLabels() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val result = bind(listOf(Candidate("修正\tしゅうせい", 15, 4u, 1), Candidate("部分", 5, 2u, 2)), context)
        assertEquals("修正", result.getJSONObject(0).getString("text").trim())
        assertEquals("[読] しゅうせい", result.getJSONObject(0).getString("type_label"))
        assertEquals("[部]", result.getJSONObject(1).getString("type_label"))
    }
}
