#!/usr/bin/env python3
"""Build the offline symbol catalog from a fixed, hash-verified Android reference.

Usage: python3 Scripts/build_symbol_catalog.py --source /external/JapaneseKeyboard \
    --output /external/symbol-catalog-generation

Requires Python 3 standard library and Git. No network or Java runtime is used.
The output directory must be new and outside both source repositories. Copy the
reviewed runtime resources into Core/Sources/SumireCore/Resources when updating.
"""
import argparse
import array
import hashlib
import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import tempfile

REVISION = "9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93"
INPUT_HASHES = {
    "LICENSE": "92dee8c459ec7a90ff505414adba21b6bef2219f40b7d8d0d2183dea3f65df75",
    "app/src/main/assets/licenses/core.html": "6f1ffaad95692c8ae160200ce302f3b1f6af8759b3fa5e7b78de18b28a180674",
    "app/src/main/assets/emoji/tango_emoji.dat": "f05fcb3b56aaf683910847342a33e36009676ad9a5abc2d43d3620dbc07700a4",
    "app/src/main/assets/emoji/token_emoji.dat": "1c25ddcf25f61595915f3a37e1d76665a7eeff2110d2521322817618e0f535a5",
    "app/src/main/assets/emoticon/tango_emoticon.dat": "ec102a95f3a490587940d4035ebeedfad4438fa13eb1b37c54ac544059c6ff6a",
    "app/src/main/assets/emoticon/token_emoticon.dat": "c4c88e2f84342aa4f13b295d37947fa4d222b019325d32346333b71989c069c5",
    "app/src/main/assets/symbol/tango_symbol.dat": "5a8d615f4697533079d201da0049c0ed3b8eabcf5de536b35552a3afee78acca",
    "app/src/main/assets/symbol/token_symbol.dat": "22a13bdf86a6e88cb270e6f6dbadf444efd57bf451ed0d250b9c370bc1e31dcb",
    "symbol_keyboard/src/main/java/com/kazumaproject/domain/Emoji.kt": "ea8b8a7e1f343db193677e21139da5a9971582c8f5c83216d561d3195fbfc5fa",
    "symbol_keyboard/src/main/java/com/kazumaproject/domain/EmojiCategoryMetadata.kt": "901e51922551329b116e6b10ecf3cf13bca893a9e94a734aeef471585eb00fcf",
    "symbol_keyboard/src/main/java/com/kazumaproject/domain/EmojiSkinToneSupport.kt": "4c5d9345569d8e1b8f38250694c847a3f0c70c87bee42212117824cfa077cdfc",
    "symbol_keyboard/src/main/java/com/kazumaproject/symbol_keyboard/CustomSymbolKeyboardView.kt": "780a77c796cd6f9e8f248a467f4a8697540ebc7add8cf50eae711eec2f9135cc",
    "symbol_keyboard/src/main/java/com/kazumaproject/data/emoji/EmojiCategory.kt": "eeae1fbdd3e5ef68cc72d52ed628ec1b216c368cf1cea8efda6a6be7667cc845",
    "symbol_keyboard/src/main/java/com/kazumaproject/data/emoticon/EmoticonCategory.kt": "4ede9c3f580033b74e92a862935e9b324e8521070a10ef1a039fd382f8c3f640",
    "symbol_keyboard/src/main/java/com/kazumaproject/data/symbol/SymbolCategory.kt": "f746802cee52dffa6669a718be828df84e9db2596b64f856d09802a185024576"
}


def verify_source(source):
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise ValueError("reference revision differs from pinned revision")
    for name, expected in INPUT_HASHES.items():
        actual = hashlib.sha256((source / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError("reference asset checksum mismatch: " + name)


def generate(ref, out, repo):
    src=ref/'symbol_keyboard/src/main/java/com/kazumaproject'
    spec=importlib.util.spec_from_file_location('b',repo/'Scripts/build_dictionary.py');b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
    meta=(src/'domain/EmojiCategoryMetadata.kt').read_text(); code=dict(re.findall(r'"([A-Z])" -> EmojiCategory\.(\w+)',meta)); index={};normalized={}
    for i,(c,h) in enumerate(re.findall(r'^([A-Z]):([0-9A-F ]+)$',meta,re.M)):
     s=''.join(chr(int(v,16)) for v in h.split()); index.setdefault(s,(code[c],i)); normalized.setdefault(s.replace('\ufe0e','').replace('\ufe0f',''),(code[c],i))
    text=(src/'domain/Emoji.kt').read_text(); maps={}
    for k,t in [('emoticon','Emoticon'),('symbol','Symbol')]:
     maps[k]={json.loads('"'+v.replace('\\$','$')+'"'):c for v,c in re.findall(r'"((?:\\.|[^"\\])*)" to '+t+r'Category\.(\w+)',text)}
    ui=(src/'symbol_keyboard/CustomSymbolKeyboardView.kt').read_text(); titles=dict(re.findall(r'(?:Emoticon|Symbol)Category\.(\w+) -> "([^"]+)"',ui))
    emojiTitles=['顔文字、気分','人々','動物、自然','食品、飲料','移動、場所','活動、イベント','物','記号','旗','その他']; result=[]; hashes={}
    for k,enum in [('emoji','Emoji'),('emoticon','Emoticon'),('symbol','Symbol')]:
     enumtext=(src/('data/'+k+'/'+enum+'Category.kt')).read_text(); cats=re.findall(r'^\s{4}(\w+),?\s*$',enumtext,re.M)
     paths=[ref/('app/src/main/assets/'+k+'/'+f+'_'+k+'.dat') for f in ['tango','token']]
     for p in paths:hashes[str(p.relative_to(ref))]=hashlib.sha256(p.read_bytes()).hexdigest()
     bits,leaf,labels=b.JavaArrays(paths[0].read_bytes()).all(3);_,_,nodes,_=b.JavaArrays(paths[1].read_bytes()).all(4);tb=b.Bits(bits);parent=[0]*len(labels)
     for idx,pos in enumerate(tb.ones(),1):parent[idx]=pos+1-idx
     values=[]
     for node in nodes:
      if node<0:continue
      idx=tb.rank(node); chars=[]
      while idx>1:chars.append(labels[idx]);idx=parent[idx]
      s=b.le(array.array('H',reversed(chars))).decode('utf-16-le')
      if s.strip() and s not in values:values.append(s)
     if k=='emoji':
      def lookup(s):return index.get(s,normalized.get(s.replace('\ufe0e','').replace('\ufe0f',''),('UNKNOWN',2147483647)))
      values.sort(key=lambda s:(cats.index(lookup(s)[0]),lookup(s)[1],s.encode('utf-16-be')))
     groups={c:[] for c in cats}
     for s in values:groups[lookup(s)[0] if k=='emoji' else maps[k].get(s,'UNKNOWN' if k=='emoticon' else 'GENERAL')].append(s)
     for i,c in enumerate(cats):
      if groups[c]:result.append(dict(mode=k,id=c,title=emojiTitles[i] if k=='emoji' else titles[c],symbols=groups[c]))
     print(k,len(values),len([v for v in groups.values() if v]))
    (out/'SymbolCatalog.json').write_text(json.dumps(result,ensure_ascii=False,separators=(',',':')))
    for f in ['domain/Emoji.kt','domain/EmojiCategoryMetadata.kt','symbol_keyboard/CustomSymbolKeyboardView.kt']:
     p=src/f;hashes[str(p.relative_to(ref))]=hashlib.sha256(p.read_bytes()).hexdigest()
    notice='Symbol keyboard catalog\nSource: KazumaProject/JapaneseKeyboard\nRevision: 9506a0baa7f2b56a74f85f2e3e776fe22f6b6e93\n\nChanges: decoded token surface nodes, stable deduplication, category grouping and emoji ordering following KanaKanjiEngine.getSymbol*Candidates. Stored as UTF-8 JSON for offline UIKit display. Android version-specific hentaigana filtering is not applied.\nUnicode category metadata identifies Unicode Emoji 17.0. Underlying data acquisition revision and per-entry attribution are unconfirmed in the preserved upstream notices. Source code MIT does not replace data terms. See SymbolDataLicenses.html.\n\nSource SHA-256:\n'+json.dumps(hashes,indent=2)+'\n\n'+(ref/'LICENSE').read_text()
    (out/'SymbolCatalogNotice.txt').write_text(notice);(out/'SymbolDataLicenses.html').write_bytes((ref/'app/src/main/assets/licenses/core.html').read_bytes())

    # Use only the upstream single-base algorithm, then require the result to exist
    # in the pinned Unicode metadata. Multi-person mixed-tone sequences are omitted.
    skin_source = (src / "domain/EmojiSkinToneSupport.kt").read_text()
    base_clause = skin_source.split("private fun isSkinToneBase", 1)[1]
    bases = set()
    for low, high in re.findall(r"in 0x([0-9A-F]+)\.\.0x([0-9A-F]+)", base_clause):
        bases.update(range(int(low, 16), int(high, 16) + 1))
    for value in re.findall(r"^\s+0x([0-9A-F]+),?\s*$", base_clause, re.M):
        bases.add(int(value, 16))
    def strip_tones(value):
        return ''.join(c for c in value if not 0x1F3FB <= ord(c) <= 0x1F3FF)
    def strip_selectors(value):
        return value.replace('\ufe0e', '').replace('\ufe0f', '')
    variants = {}
    for category in result:
        if category['mode'] != 'emoji':
            continue
        for symbol in category['symbols']:
            base = strip_tones(symbol)
            if sum(ord(c) in bases for c in base) != 1:
                continue
            position = next(i for i, c in enumerate(base) if ord(c) in bases)
            suffix = base[position + 1:]
            if suffix.startswith('\ufe0f'):
                suffix = suffix[1:]
            choices = [base]
            for tone in range(0x1F3FB, 0x1F400):
                candidate = base[:position + 1] + chr(tone) + suffix
                if candidate in index or strip_selectors(candidate) in normalized:
                    choices.append(candidate)
            if len(choices) > 1:
                variants[base] = choices
    (out / 'SymbolSkinTones.json').write_text(json.dumps(variants, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    (out / 'SymbolSkinToneNotice.txt').write_text(
        'Emoji skin-tone variant table\nSource revision: ' + REVISION +
        '\nGenerated from the pinned EmojiSkinToneSupport single-base rules, retaining only variants present in EmojiCategoryMetadata Unicode 17.0 data. Multi-base and absent sequences are not synthesized.\n' +
        '\nVerified inputs (SHA-256):\n' + json.dumps(INPUT_HASHES, indent=2) +
        '\n\nSee SymbolCatalogNotice.txt and SymbolDataLicenses.html for preserved copyright and license notices.\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parents[1]
    source = args.source.resolve()
    output = args.output.resolve()
    if output.exists():
        parser.error("output already exists; choose a new generation directory")
    if output.is_relative_to(repo) or output.is_relative_to(source):
        parser.error("output must be outside the app and Android source repositories")
    verify_source(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    sys.dont_write_bytecode = True
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".sumire-symbol-") as temporary:
        stage = pathlib.Path(temporary) / "resources"
        stage.mkdir()
        generate(source, stage, repo)
        stage.rename(output)


if __name__ == "__main__":
    main()
