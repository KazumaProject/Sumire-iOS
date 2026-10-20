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

/** Deterministic type29/type30 subset only; TestEngineFactory's EnglishEngine
 * is mocked empty, so this does not establish whole Latin candidate parity. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "ja-rJP")
class SumireIOSAsciiGeneratedBaselineTest {
    @Test fun exportGeneratedAsciiSubset() = runBlocking {
        val oldLocale = Locale.getDefault()
        Locale.setDefault(Locale.JAPAN)
        try {
            val context = ApplicationProvider.getApplicationContext<Context>()
            val store = DictionaryOverrideStore(context, DictionaryOverrideValidator())
            ClassifiedDictionaries.categories.forEach { store.setOptionalBundledEnabled(it, true) }
            val reader = DictionaryBinaryReader(DictionarySourceResolver(context, store), store)
            val ngram = SystemNgramAssetLoader.load(context)
            val engine = TestEngineFactory.create(findPath = FindPath(systemNgramDictionaryProvider = { ngram }))
            engine.setDictionaryBinaryReader(reader)
            engine.initializeOptionalDictionaryStateFromCurrentSources()
            assertEquals(ClassifiedDictionaries.categories, engine.loadedClassifiedCategories())
            val repository = mock<UserDictionaryRepository>()
            whenever(repository.commonPrefixSearchInUserDict(any())).thenReturn(emptyList())
            val inputs = listOf("a", "Ab", "ABC", "a1", "A1", "AB12", "+", "a+b", "a b", " ", "あ", "aあ", "é", "ＡＢ")
            val file = File("build/reports/sumire-ios-ascii-generated-baseline.jsonl")
            file.parentFile.mkdirs()
            file.bufferedWriter().use { writer ->
                for(all in listOf(false, true)) for(input in inputs) {
                    val result = engine.getCandidatesOriginal(input=input, n=20,
                        enabledDictionaryCategories=if(all) ClassifiedDictionaries.categories else emptySet(),
                        userDictionaryRepository=repository, learnRepository=null,
                        typoCorrectionOffsetScore=3000, omissionSearchOffsetScore=1900,
                        beamWidth=20, isOmissionSearchEnable=false, predictionConfig=PredictionConfig())
                    val generated = result.mapIndexedNotNull { index, c ->
                        if(c.type.toInt() !in listOf(29, 30)) null else JSONObject()
                            .put("raw_index", index).put("text", c.string).put("score", c.score)
                            .put("type", c.type.toInt()).put("length_utf16", c.length.toInt())
                            .put("commit_text", c.commitText)
                    }
                    writer.appendLine(JSONObject().put("reading", input).put("categories", if(all) "all" else "none")
                        .put("source_revision", "df1f38315bf56d860d32919a3eaed6a75499e91e")
                        .put("path", "KanaKanjiEngine.getCandidatesOriginal").put("n",20).put("beam_width",20)
                        .put("english_engine", "mocked empty; only deterministic generated subset compared")
                        .put("generated_candidates", JSONArray(generated))
                        .put("raw_candidates", JSONArray(result.map { c -> JSONObject().put("text",c.string)
                            .put("type",c.type.toInt()).put("score",c.score).put("length_utf16",c.length.toInt()) })).toString())
                }
            }
        } finally { Locale.setDefault(oldLocale) }
    }
}
