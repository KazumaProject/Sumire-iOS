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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class SumireIOSPredictionBaselineTest {
    @Test fun exportProductionCandidates() = runBlocking {
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
        val output = File("build/reports/sumire-ios-prediction-baseline.jsonl")
        output.parentFile.mkdirs()
        output.bufferedWriter().use { writer ->
            for (original in listOf(false, true)) for (all in listOf(false, true)) for (input in (inputs + listOf("にほん", "とうき", "かっこん", "あせん", "あめり", "りゅう")).distinct()) {
                val result = if (original) engine.getCandidatesOriginal(input=input, n=10,
                    enabledDictionaryCategories=if(all) ClassifiedDictionaries.categories else emptySet(),
                    userDictionaryRepository=repository, learnRepository=null,
                    typoCorrectionOffsetScore=3000, omissionSearchOffsetScore=1900,
                    beamWidth=20, isOmissionSearchEnable=false,
                    predictionConfig=PredictionConfig()
) else engine.getCandidates(input=input, n=10,
                    enabledDictionaryCategories=if(all) ClassifiedDictionaries.categories else emptySet(),
                    userDictionaryRepository=repository, learnRepository=null,
                    typoCorrectionOffsetScore=3000, omissionSearchOffsetScore=1900,
                    beamWidth=20, isOmissionSearchEnable=false,
                    predictionConfig=PredictionConfig()
)
                val row = JSONObject().put("reading",input).put("categories",if(all) "all" else "none")
                    .put("source_revision","df1f38315bf56d860d32919a3eaed6a75499e91e")
                    .put("path",if(original) "KanaKanjiEngine.getCandidatesOriginal" else "KanaKanjiEngine.getCandidates")
                    .put("prediction",true).put("prediction_minimum_input",3).put("prediction_limit",4).put("prediction_lookahead",3).put("prediction_aggressiveness","standard")
                    .put("n",10).put("beam_width",20).put("omission",false)
                    .put("system_ngram_rule_count",systemNgram.ruleCount)
                    .put("system_ngram_storage_bytes",systemNgram.storageBytes)
                row.put("candidates", JSONArray(result.map { c -> JSONObject().put("text",c.string).put("score",c.score).put("length_utf16",c.length.toInt()).put("type",c.type.toInt()) }))
                writer.appendLine(row.toString())
            }
        }
    }
}
