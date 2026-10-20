package com.kazumaproject.markdownhelperkeyboard.converter

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.kazumaproject.markdownhelperkeyboard.dictionary_override.*
import com.kazumaproject.markdownhelperkeyboard.repository.UserDictionaryRepository
import com.kazumaproject.markdownhelperkeyboard.converter.engine.EnglishEngine
import com.kazumaproject.markdownhelperkeyboard.converter.engine.PredictionConfig
import com.kazumaproject.markdownhelperkeyboard.converter.candidate.Candidate
import com.kazumaproject.markdownhelperkeyboard.converter.path_algorithm.FindPath
import com.kazumaproject.markdownhelperkeyboard.converter.ngram.SystemNgramAssetLoader
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.json.JSONObject
import org.json.JSONArray
import java.io.File
import java.util.Locale
import android.os.Looper
import android.widget.FrameLayout
import org.robolectric.Shadows.shadowOf
import com.kazumaproject.markdownhelperkeyboard.ime_service.candidate.CandidateDisplayMerger
import com.kazumaproject.markdownhelperkeyboard.ime_service.adapters.SuggestionAdapter

/** Separate real-English corpus. Never replaces the existing 25-input mock fixture. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "ja-rJP")
class SumireIOSRealEnglishBaselineTest {
    private fun candidates(values: List<Candidate>, input: String) = JSONArray(values.map { c -> JSONObject()
        .put("text", c.string).put("score", c.score).put("type", c.type.toInt())
        .put("lexical_length_utf16", c.length.toInt())
        .put("effective_commit_text", if (c.type.toInt() in setOf(9,11,12,13,14,28,30) || c.length.toInt() == input.length) c.string else c.commitText)
        .put("consumed_utf16", if (c.type.toInt() in setOf(9,11,12,13,14,15,28,30)) input.length else minOf(input.length, c.length.toInt())) })

    private fun bind(values: List<Candidate>, context: Context): JSONArray {
        val adapter = SuggestionAdapter()
        try {
            adapter.setShowCandidateYomiForLiveConversion(false)
            adapter.setShowDictionaryCandidateLabels(false)
            var committed = false
            adapter.onListUpdated = { committed = true }
            adapter.suggestions = values
            repeat(200) {
                shadowOf(Looper.getMainLooper()).idle()
                if (!committed) Thread.sleep(10)
            }
            assertTrue(committed)
            assertEquals(values, adapter.buildClickCandidatesForTesting())
            val holder = adapter.onCreateViewHolder(FrameLayout(context), SuggestionAdapter.VIEW_TYPE_SUGGESTION) as SuggestionAdapter.SuggestionViewHolder
            return JSONArray(values.indices.map { index ->
                adapter.onBindViewHolder(holder, index)
                JSONObject().put("text", holder.text.text.toString()).put("annotation", holder.typeText.text.toString())
            })
        } finally { adapter.release() }
    }

    @Test fun exportRealEnglishProvider() = runBlocking {
        val previous = Locale.getDefault()
        Locale.setDefault(Locale.JAPAN)
        try {
            val context = ApplicationProvider.getApplicationContext<Context>()
            val store = DictionaryOverrideStore(context, DictionaryOverrideValidator())
            val reader = DictionaryBinaryReader(DictionarySourceResolver(context, store), store)
            val english = EnglishEngine().apply { configureLazyDictionaryLoading(reader) }
            val ngram = SystemNgramAssetLoader.load(context)
            val engine = TestEngineFactory.create(findPath = FindPath(systemNgramDictionaryProvider = { ngram }),
                englishEngineOverride = english)
            engine.setDictionaryBinaryReader(reader)
            engine.initializeOptionalDictionaryStateFromCurrentSources()
            val repository = mock<UserDictionaryRepository>()
            whenever(repository.commonPrefixSearchInUserDict(any())).thenReturn(emptyList())
            val inputs = listOf("a", "A", "ab", "Ab", "AB", "app", "ApP", "APP", "iPh", "NASA",
                "zzzzq", "ａｂ", "Ａｂ", "ＡＢ", "＋", "　", "ａ＋ｂ", "a1", "a+b", "é", "123", "１２３")
            val output = File("build/reports/sumire-ios-real-english.jsonl")
            output.parentFile.mkdirs()
            output.bufferedWriter().use { writer ->
                for (input in inputs) {
                    val normalized = input.map { c -> when {
                        c == '　' -> ' '
                        c in '！'..'～' -> (c.code - 0xfee0).toChar()
                        else -> c
                    } }.joinToString("")
                    val eligible = input.all { it in 'a'..'z' || it in 'A'..'Z' } ||
                        (input.all { it == '　' || it in '！'..'～' } && !normalized.all { it in '0'..'9' })
                    val provider = if (eligible) english.getCandidates(normalized, false, true) else emptyList()
                    val original = engine.getCandidatesOriginal(input=input, n=20,
                        enabledDictionaryCategories=emptySet(), userDictionaryRepository=repository, learnRepository=null,
                        typoCorrectionOffsetScore=3000, omissionSearchOffsetScore=1900, beamWidth=20,
                        isOmissionSearchEnable=false, predictionConfig=PredictionConfig())
                    val dedicated = english.getCandidates(normalized, false, true)
                    // Corpus has no date/utility/NG/promoted-input triggers;
                    // the fixed OFF pipeline therefore reduces to this merger.
                    val projected = CandidateDisplayMerger.merge(original)
                    writer.appendLine(JSONObject().put("reading", input).put("provider_input", normalized)
                        .put("eligible", eligible).put("source_revision", "df1f38315bf56d860d32919a3eaed6a75499e91e")
                        .put("n", 20).put("beam_width", 20).put("typo_correction", false)
                        .put("provider", candidates(provider, input)).put("japanese_original", candidates(original, input))
                        .put("projected", candidates(projected, input)).put("adapter_items", bind(projected, context))
                        .put("dedicated_english", candidates(dedicated, normalized)).toString())
                }
            }
            assertTrue(english.getCandidates("app", false, true).size > 20)
        } finally { Locale.setDefault(previous) }
    }
}
