#!/usr/bin/env python3
"""Convert pinned Android assets; no Java runtime or general object deserialization.
Only primitive arrays and java.util.BitSet are accepted. Output is immutable.
"""
import argparse, array, collections, hashlib, json, math, pathlib, shutil, struct, subprocess, sys, tempfile, zipfile, zlib

REVISION = 'df1f38315bf56d860d32919a3eaed6a75499e91e'
RELEASE_TAG = 'v1.7.277'
RELEASE_REVISION = '13e391bc7a4a245f63aa0091c1e9c11db3dbd759'
RELEASE_SHA256 = {
    'archive': 'f2b1c1521a2dacd8fdfdf40a06cf9b7566db60a2592c14be78ea9ce7d5e26d63',
    'manifest': '946aa2d6be2cc4b4b285b2600789c7061a3356877251ad414c663f8dc3785d60',
    'licenses': '1002230bbdf760c6a00a81b6dd19d93299b9bba3a3e31815d2eff16bd1bd2ff2',
}

def unpack_release(archive, manifest_path, licenses_path, directory):
    """Accept only the reviewed release, with every member authenticated."""
    for role, path in [('archive', archive), ('manifest', manifest_path), ('licenses', licenses_path)]:
        if hashlib.sha256(path.read_bytes()).hexdigest() != RELEASE_SHA256[role]:
            raise ValueError('release ' + role + ' SHA-256 mismatch')
    manifest = json.loads(manifest_path.read_text())
    if manifest['schemaVersion'] != 1 or manifest['categoryCount'] != 143:
        raise ValueError('unexpected release catalog')
    expected = manifest['files']
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        if len(names) != len(set(names)) or set(names) != set(expected) | {'dictionary-distribution-manifest.json'}:
            raise ValueError('release archive member set differs from manifest')
        for info in z.infolist():
            path = pathlib.PurePosixPath(info.filename)
            if path.is_absolute() or '..' in path.parts or '\\' in info.filename or info.file_size > 256*1024*1024:
                raise ValueError('unsafe release archive member')
            raw = z.read(info)
            digest = RELEASE_SHA256['manifest'] if info.filename == 'dictionary-distribution-manifest.json' else expected[info.filename]
            if hashlib.sha256(raw).hexdigest() != digest:
                raise ValueError('release member SHA-256 mismatch: ' + info.filename)
            target = directory / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
    return manifest
CATEGORIES = 'address agreement award character event facility initiative kampo lineage medical mythological_figure organization person place product station term transport_route vehicle work_anime work_book work_film work_franchise work_game work_manga work_music work_other work_periodical work_program work_stage'.split()
AUXILIARY_DICTIONARIES = {
    'single_kanji': ('single_kanji', 'singleKanji'),
    'emoji': ('emoji', 'emoji'),
    'emoticon': ('emoticon', 'emoticon'),
    'symbol': ('symbol', 'symbol'),
    'reading_correction': ('reading_correction', 'reading_correction'),
}
AUXILIARY_ASSET_SHA256 = {
    'reading_correction/yomi_reading_correction.dat': 'e9d2348bd7caf264e14da611effba1bc524467ac211afe158243f794eb81432b',
    'reading_correction/tango_reading_correction.dat': '3f102aa7f31a51657473352fb3cb35f4c48fb0943efbe2b057ccecade2de08d6',
    'reading_correction/token_reading_correction.dat': '8cefa1af8298363347674221f6a1620494b328face07873e1296f3fce51f3720',
    'single_kanji/yomi_singleKanji.dat': 'a9d02f6e81ad2e48ec187bc5c03c57660de7178f34204149ba45482178e98f76',
    'single_kanji/tango_singleKanji.dat': '30f5a78cea54d6359a3591b741896674002b3e2bac580bc59269eb8c593f929b',
    'single_kanji/token_singleKanji.dat': '4d60dc524cfdffdb576102429a3a5a7c625f0c3581ba248a81fbc852eaa33166',
    'emoji/yomi_emoji.dat': 'cdd5f223ccfcb63f22a317b5a9aa97e240a98b28571fbf4905758d5205162950',
    'emoji/tango_emoji.dat': 'f05fcb3b56aaf683910847342a33e36009676ad9a5abc2d43d3620dbc07700a4',
    'emoji/token_emoji.dat': '1c25ddcf25f61595915f3a37e1d76665a7eeff2110d2521322817618e0f535a5',
    'emoticon/yomi_emoticon.dat': '15f32cda380dae4581abbeef1ae0a43f12d7980cf37b84408e1920b980e5318b',
    'emoticon/tango_emoticon.dat': 'ec102a95f3a490587940d4035ebeedfad4438fa13eb1b37c54ac544059c6ff6a',
    'emoticon/token_emoticon.dat': 'c4c88e2f84342aa4f13b295d37947fa4d222b019325d32346333b71989c069c5',
    'symbol/yomi_symbol.dat': '7ac99f6184ba6c20b8bad0bcf1f2386d10b45ff60138f166731b091459a93482',
    'symbol/tango_symbol.dat': '5a8d615f4697533079d201da0049c0ed3b8eabcf5de536b35552a3afee78acca',
    'symbol/token_symbol.dat': '22a13bdf86a6e88cb270e6f6dbadf444efd57bf451ed0d250b9c370bc1e31dcb',
}

def read_pinned_asset(assets, name):
    raw = (assets / name).read_bytes()
    expected = AUXILIARY_ASSET_SHA256.get(name)
    if expected is not None and hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('pinned auxiliary asset hash mismatch: ' + name)
    return raw

class JavaArrays:
    def __init__(self, data):
        self.data, self.p, self.refs = data, 0, []
        if self.take(4) != b'\xac\xed\x00\x05': raise ValueError('not a Java array stream')
    def take(self, n):
        if n < 0 or n > len(self.data)-self.p: raise ValueError('truncated stream')
        b=self.data[self.p:self.p+n]; self.p+=n; return b
    def num(self, f): return struct.unpack('>'+f, self.take(struct.calcsize('>'+f)))[0]
    def utf(self): return self.take(self.num('H')).decode('utf-8')
    def ref(self):
        n=self.num('I')-0x7e0000
        if not 0 <= n < len(self.refs): raise ValueError('invalid handle')
        return self.refs[n]
    def desc(self):
        t=self.num('B')
        if t==0x70: return None
        if t==0x71: return self.ref()
        if t!=0x72: raise ValueError('unsupported class descriptor')
        name=self.utf(); self.take(8)
        if name not in ('[S','[I','[J','[C','java.util.BitSet'): raise ValueError('unsupported class '+name)
        d={'name':name};self.refs.append(d)
        flags=self.num('B'); count=self.num('H'); fields=[]
        for _ in range(count):
            typ=chr(self.num('B')); field=self.utf()
            if typ in '[L': self.obj()
            fields.append((typ,field))
        if self.num('B')!=0x78 or self.desc() is not None: raise ValueError('unsupported class annotations/superclass')
        if name=='java.util.BitSet':
            if flags!=3 or fields!=[('[','bits')]: raise ValueError('invalid BitSet descriptor')
        elif flags!=2 or fields: raise ValueError('invalid array descriptor')
        return d
    def obj(self):
        t=self.num('B')
        if t==0x71: return self.ref()
        if t==0x74:
            s=self.utf()
            if s!='[J': raise ValueError('unsupported string')
            self.refs.append(s); return s
        if t==0x75:
            d=self.desc();i=len(self.refs);self.refs.append(None);n=self.num('i')
            code={'[S':'h','[I':'i','[J':'q','[C':'H'}[d['name']]
            a=array.array(code); a.frombytes(self.take(n*a.itemsize))
            if sys.byteorder=='little':a.byteswap()
            self.refs[i]=a;return a
        if t==0x73:
            d=self.desc()
            if d['name']!='java.util.BitSet':raise ValueError('only BitSet objects supported')
            i=len(self.refs);self.refs.append(None);a=self.obj()
            if not isinstance(a,array.array) or a.typecode!='q' or self.num('B')!=0x78:raise ValueError('invalid BitSet')
            self.refs[i]=a;return a
        raise ValueError('unsupported serialization tag '+hex(t))
    def all(self,n):
        values=[self.obj() for _ in range(n)]
        if self.p!=len(self.data):raise ValueError('trailing serialization data')
        return values

def le(a):
    b=array.array(a.typecode,a)
    if sys.byteorder!='little':b.byteswap()
    return b.tobytes()

def decode_surface_utf16(code_units):
    """Return strict UTF-8, replacing lone UTF-16 surrogates with U+FFFD.

    Some pinned single-kanji tokens reference a lone surrogate. Such a value
    cannot be represented by the C ABI's UTF-8 strings; replacement keeps the
    candidate well-formed instead of failing the whole dictionary generation.
    """
    return le(array.array('H',code_units)).decode('utf-16-le',errors='replace').encode('utf-8')

def pack_file(path,kind,dimension,sections):
    header=struct.pack('<8sIIII',b'SUMIRE01',1,kind,len(sections),dimension)
    offset=24+24*len(sections);payload=bytearray();desc=[]
    for s in sections:
        padding=(-offset)%8;payload.extend(bytes(padding));offset+=padding
        desc.append(struct.pack('<QQII',offset,len(s),zlib.crc32(s),0));payload.extend(s);offset+=len(s)
    path.write_bytes(header+b''.join(desc)+payload)

def standalone_words(data):
    """Validate/decode fixed GNKJ v5; no Java objects or runtime hash table.

    Binary contract: Android PackedSystemNgramDictionary, fixed source revision.
    Only the whole-input word signature is accepted. Values are not inferred
    from stale tests or duplicated as hard-coded vocabulary.
    """
    if not 80 <= len(data) <= 1024*1024: raise ValueError('invalid standalone size')
    h=struct.unpack_from('<20I',data)
    magic,version,count,contexts,pos_count,signatures,max_key,block_size,sig_off,ctx_off,bucket_off,hash_off,block_off,record_off,total,crc,buckets,blocks,*_=h
    if magic!=0x4a4b4e47 or version!=5 or total!=len(data) or crc!=zlib.crc32(data[80:]):raise ValueError('invalid standalone header/checksum')
    if not (0<count<=100000 and 0<contexts<=100000 and 1<=pos_count<=255 and 1<=signatures<=count and 1<=max_key<=32768 and block_size==16):raise ValueError('invalid standalone dimensions')
    if not (256<=buckets<=65536 and buckets&(buckets-1)==0 and blocks==(count+15)//16):raise ValueError('invalid standalone index dimensions')
    expected_ctx=80+4*signatures;expected_bucket=(expected_ctx+contexts+3)&~3
    if (sig_off,ctx_off,bucket_off,hash_off,block_off,record_off)!=(80,expected_ctx,expected_bucket,expected_bucket+4*(buckets+1),expected_bucket+4*(buckets+1)+10*count,expected_bucket+4*(buckets+1)+10*count+4*(blocks+1)) or record_off>len(data):raise ValueError('invalid standalone sections')
    sigs=struct.unpack_from('<'+'I'*signatures,data,sig_off)
    if any(s!=9 for s in sigs) or len(set(sigs))!=len(sigs):raise ValueError('unsupported standalone signature')
    if any(not 1<=p<=pos_count for p in data[ctx_off:ctx_off+contexts]):raise ValueError('invalid standalone POS')
    starts=struct.unpack_from('<'+'I'*(buckets+1),data,bucket_off)
    offsets=struct.unpack_from('<'+'I'*(blocks+1),data,block_off)
    if starts[0]!=0 or starts[-1]!=count or any(a>b for a,b in zip(starts,starts[1:])):raise ValueError('invalid standalone buckets')
    if offsets[0]!=0 or offsets[-1]!=len(data)-record_off or any(a>b for a,b in zip(offsets,offsets[1:])):raise ValueError('invalid standalone blocks')
    def var(position,end):
        value=0
        for shift in range(0,35,7):
            if position>=end:raise ValueError('truncated standalone varint')
            byte=data[position];position+=1;value|=(byte&127)<<shift
            if not byte&128:
                if shift==28 and byte>15:raise ValueError('standalone varint overflow')
                return value,position
        raise ValueError('standalone varint overflow')
    records=[];words=[];decoded_bytes=0
    for block in range(blocks):
        at=record_off+offsets[block];end=record_off+offsets[block+1];previous=b''
        for i in range(min(16,count-16*block)):
            if i==0:prefix=0
            else:prefix,at=var(at,end)
            size,at=var(at,end)
            if prefix>len(previous) or not 1<=prefix+size<=max_key or size>end-at:raise ValueError('invalid standalone record')
            record=previous[:prefix]+data[at:at+size];at+=size;previous=record
            decoded_bytes+=len(record)
            if decoded_bytes>4*1024*1024:raise ValueError('standalone decoded limit exceeded')
            if record[:2]!=b'\x09\x00':raise ValueError('invalid standalone word signature')
            # The key's word length is another unsigned varint.
            value=shift=0;position=2
            while position<len(record) and shift<=28:
                byte=record[position];position+=1;value|=(byte&127)<<shift
                if not byte&128:break
                shift+=7
            else:raise ValueError('invalid standalone word length')
            if position>3 and record[position-1]==0:raise ValueError('noncanonical standalone word length')
            word=record[position:]
            if value!=len(word) or not word:raise ValueError('invalid standalone word length')
            word.decode('utf-8')
            records.append(record);words.append(word)
        if at!=end:raise ValueError('trailing standalone block data')
    # Check every decoded record is reachable through the original hash index.
    mask=(1<<64)-1;entries=set()
    for bucket in range(buckets):
        previous=(-1,-1)
        for entry in range(starts[bucket],starts[bucket+1]):
            at=hash_off+10*entry;remainder=int.from_bytes(data[at:at+6],'little');record_id=struct.unpack_from('<I',data,at+6)[0]
            if record_id>=count or (remainder,record_id)<=previous:raise ValueError('invalid standalone hash entry')
            previous=(remainder,record_id);entries.add((bucket,remainder,record_id))
    for record_id,record in enumerate(records):
        value=(-3750763034362895579)&mask
        for byte in record:value=((value^byte)*1099511628211)&mask
        value=((value^(value>>33))*(-49064778989728563))&mask
        value=((value^(value>>33))*(-4265267296055464877))&mask;value^=value>>33
        if (value>>(64-(buckets.bit_length()-1)),value&((1<<48)-1),record_id) not in entries:raise ValueError('unreachable standalone record')
    if len(set(words))!=count:raise ValueError('duplicate standalone words')
    return sorted(words)

def pack_standalone(path,data):
    words=standalone_words(data);offsets=array.array('I',[0]);text=bytearray()
    for word in words:text.extend(word);offsets.append(len(text))
    pack_file(path,3,len(words),[le(offsets),bytes(text)])
    return len(words)

class Bits:
    def __init__(self,a):
        self.a=[x & ((1<<64)-1) for x in a];self.prefix=[0]
        for x in self.a:self.prefix.append(self.prefix[-1]+x.bit_count())
    def rank(self,p):
        if p<0:return 0
        w,b=divmod(p,64)
        if w>=len(self.a):return self.prefix[-1]
        return self.prefix[w]+(self.a[w]&((1<<(b+1))-1)).bit_count()
    def ones(self):
        for i,x in enumerate(self.a):
            while x:
                low=x&-x;yield i*64+low.bit_length()-1;x^=low

def build(source,output,english_reading=False,english=False,release=None):
    if output.exists():raise ValueError('output already exists; choose a new generation directory')
    assets=source/'app/src/main/assets'
    revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    if revision!=REVISION:raise ValueError('reference revision differs from pinned revision')
    reference_assets = assets
    categories = CATEGORIES
    if release is not None:
        assets, release_manifest, release_licenses = release
        categories = [item['id'] for item in release_manifest['categories']]
    archive_sources={'system':'system', **{c:'categories/'+c for c in categories}}
    if release is not None:
        # Person IDs are intentionally independent from their archive directory
        # (for example actor is stored under categories/person/actor).
        for item in release_manifest['categories']:
            directories = {str(pathlib.PurePosixPath(p).parent).removeprefix('app/src/main/assets/') for p in item['assetPaths']}
            if len(directories) != 1:
                raise ValueError('inconsistent release category paths: ' + item['id'])
            archive_sources[item['id']] = directories.pop()
    dictionary_sources=dict(archive_sources)
    dictionary_sources.update({name: directory for name, (directory, _) in AUXILIARY_DICTIONARIES.items()})
    if english_reading:
        archive_sources['english_reading']='english_reading'
        dictionary_sources['english_reading']='english_reading'
    paths=['pos_table.dat','connectionId.dat.zip','ngram/system_ngram.dat','ngram/system_ngram_unigram.dat','ngram/system_ngram_standalone_unigram.dat','mozc/segmenter.dat','mozc/node_attribute_by_lid.dat']+[f'{d}/{f}.dat.zip' for d in archive_sources.values() for f in ['yomi','tango','token']]
    paths += list(AUXILIARY_ASSET_SHA256)
    if english:
        dictionary_sources['english']='english'
        paths += ['english/reading.dat.zip','english/word.dat','english/token.dat.zip']
    # Refuse locally modified shipped assets, even when HEAD still matches.
    subprocess.run(['git','-C',str(source),'diff','--exit-code','HEAD','--']+['app/src/main/assets/'+p for p in paths],check=True,stdout=subprocess.DEVNULL)
    hashes={}
    supplements={}
    def read(name):
        origin = assets if (assets / name).is_file() else reference_assets
        raw = (origin / name).read_bytes() if release is not None and origin == assets else read_pinned_asset(origin,name)
        hashes[name]=hashlib.sha256(raw).hexdigest()
        if release is not None and origin == reference_assets:
            supplements[name] = hashes[name]
        if not name.endswith('.zip'):return raw
        with zipfile.ZipFile(origin/name) as z:
            files=z.infolist()
            if name in ('english/reading.dat.zip','english/token.dat.zip'):
                expected=pathlib.PurePosixPath(name).name.removesuffix('.zip')
                allowed={expected,'__MACOSX/._'+expected}
                if len({f.filename for f in files})!=len(files) or any(f.filename not in allowed or f.file_size>256*1024*1024 for f in files):raise ValueError('invalid English archive')
                files=[f for f in files if f.filename==expected]
            if len(files)!=1 or files[0].file_size>256*1024*1024:raise ValueError('invalid archive')
            return z.read(files[0])
    left,right=JavaArrays(read('pos_table.dat')).all(2)
    matrix=array.array('h');matrix.frombytes(read('connectionId.dat.zip'))
    if sys.byteorder=='little':matrix.byteswap()
    n=math.isqrt(len(matrix))
    if n*n!=len(matrix) or len(left)!=len(right) or any(v<0 or v>=n for v in left+right):raise ValueError('invalid POS/matrix')
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent,prefix='.sumire-') as tmp:
        dest=pathlib.Path(tmp);defaults=array.array('h');bits=array.array('Q');values=array.array('h');starts=array.array('I',[0]);ranks=array.array('H')
        for row in range(n):
            costs=matrix[row*n:(row+1)*n];default=collections.Counter(costs).most_common(1)[0][0];defaults.append(default);rank=0
            for start in range(0,n,64):
                ranks.append(rank);word=0
                for j,v in enumerate(costs[start:start+64]):
                    if v!=default:word|=1<<j;values.append(v);rank+=1
                bits.append(word)
            starts.append(len(values))
        pack_file(dest/'connection.sud',2,n,[le(a) for a in [left,right,defaults,bits,values,starts,ranks]])
        summary={}
        for name,prefix in dictionary_sources.items():
            if name=='english':
                lbs,leaf,labels,terms=JavaArrays(read('english/reading.dat.zip')).all(4)
                tlbs,tleaf,tlabels=JavaArrays(read('english/word.dat')).all(3)
                cost,node,post=JavaArrays(read('english/token.dat.zip')).all(3)
                # English has no Japanese POS. This placeholder is never used for
                # connection scoring; English lookups use the stored word cost.
                pos=array.array('h',[0])*len(cost)
                if any(p < -1 for p in node):raise ValueError('invalid English surface sentinel')
                node=array.array('i',(-2 if p==-1 else p for p in node))
            elif name in AUXILIARY_DICTIONARIES:
                directory,stem=AUXILIARY_DICTIONARIES[name]
                lbs,leaf,labels,terms=JavaArrays(read(f'{directory}/yomi_{stem}.dat')).all(4)
                tlbs,tleaf,tlabels=JavaArrays(read(f'{directory}/tango_{stem}.dat')).all(3)
                pos,cost,node,post=JavaArrays(read(f'{directory}/token_{stem}.dat')).all(4)
            else:
                lbs,leaf,labels,terms=JavaArrays(read(prefix+'/yomi.dat.zip')).all(4)
                tlbs,tleaf,tlabels=JavaArrays(read(prefix+'/tango.dat.zip')).all(3)
                pos,cost,node,post=JavaArrays(read(prefix+'/token.dat.zip')).all(4)
            if not len(pos)==len(cost)==len(node) or any(p<0 or p>=len(left) for p in pos):raise ValueError('invalid tokens')
            tb=Bits(tlbs);parent=array.array('I',[0])*len(tlabels)
            for index,p in enumerate(tb.ones(),1):
                if index>=len(parent):raise ValueError('invalid surface trie')
                parent[index]=p+1-index
            cache={};surface_ids={};offsets=array.array('I',[0]);blob=bytearray();refs=array.array('I')
            for p in node:
                if p in (-1,-2):refs.append(p&0xffffffff);continue
                if p<0 or tb.rank(p)==tb.rank(p-1):raise ValueError('invalid surface node')
                if p not in cache:
                    i=tb.rank(p);chars=[]
                    while i>1:
                        chars.append(tlabels[i]);previous=parent[i]
                        if previous>=i:raise ValueError('surface cycle')
                        i=previous
                    s=decode_surface_utf16(reversed(chars))
                    if s not in surface_ids:surface_ids[s]=len(offsets)-1;blob.extend(s);offsets.append(len(blob))
                    cache[p]=surface_ids[s]
                refs.append(cache[p])
            # Term IDs are one-based indexes into zero-delimited postings.
            pb=Bits(post);postings=array.array('I',[0]);ones=0
            for p in range(len(post)*64):
                if (pb.a[p//64]>>(p%64))&1:ones+=1
                else:postings.append(ones)
                if ones==len(pos):break
            postings.append(ones)
            if min(terms,default=1)<1 or max(terms,default=0)+1>=len(postings):raise ValueError('invalid term IDs')
            if Bits(leaf).prefix[-1]!=len(terms) or Bits(lbs).prefix[-1]+1!=len(labels):raise ValueError('invalid reading trie')
            (dest/(name+'.sud')).parent.mkdir(parents=True,exist_ok=True)
            pack_file(dest/(name+'.sud'),1,0,[le(a) for a in [lbs,labels,leaf,terms,postings,pos,cost,refs,offsets]]+[bytes(blob)])
            summary[name]={'entries':len(pos),'readings':len(terms),'bytes':(dest/(name+'.sud')).stat().st_size}
            print(name,summary[name],file=sys.stderr,flush=True)
        standalone_count=pack_standalone(dest/'standalone.sud',read('ngram/system_ngram_standalone_unigram.dat'))
        summary['standalone']={'rules':standalone_count,'bytes':(dest/'standalone.sud').stat().st_size}
        ngram_summary={}
        for asset in ('ngram/system_ngram.dat','ngram/system_ngram_unigram.dat'):
            payload=read(asset)
            name=pathlib.PurePosixPath(asset).name
            (dest/name).write_bytes(payload)
            ngram_summary[name]={'bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest()}
        summary['system_ngram_assets']=ngram_summary
        mozc_summary={}
        for asset in ('mozc/segmenter.dat','mozc/node_attribute_by_lid.dat'):
            payload=read(asset)
            target=dest/asset
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(payload)
            mozc_summary[pathlib.PurePosixPath(asset).name]={'bytes':len(payload),'sha256':hashlib.sha256(payload).hexdigest()}
        summary['mozc_assets']=mozc_summary
        shutil.copytree(reference_assets/'licenses',dest/'licenses')
        shutil.copy2(source/'LICENSE',dest/'SOURCE-LICENSE')
        manifest={'format':1,'source_revision':revision,'asset_sha256':hashes,'dictionaries':summary,'matrix_dimension':n,'modification':'Array encoding and connection costs are preserved. Surface paths are re-encoded as UTF-8; lone UTF-16 surrogates in pinned source tokens are replaced with U+FFFD so returned strings are valid Unicode. See copied licenses for data terms.'}
        if release is not None:
            (dest/'release-categories-v1.7.277').write_text(RELEASE_TAG+'\n')
            shutil.copy2(release_licenses,dest/'licenses'/'DICTIONARY-LICENSES-v1.7.277.txt')
            manifest.update(source_revision=RELEASE_REVISION, source_release=RELEASE_TAG,
                            release_sha256=RELEASE_SHA256, categories=release_manifest['categories'],
                            supplemental_source_revision=REVISION, supplemental_asset_sha256=supplements)
        manifest['output_sha256']={p.relative_to(dest).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in dest.rglob('*') if p.is_file() and (p.suffix=='.sud' or p.name.startswith(('system_ngram','release-categories-')) or p.parent==dest/'mozc')}
        (dest/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
        # Rename a complete generation only; never replace an existing generation.
        dest.rename(output)

if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--source',type=pathlib.Path,default=pathlib.Path(__file__).resolve().parents[1]/'.reference/JapaneseKeyboard');ap.add_argument('--output',type=pathlib.Path,required=True)
    ap.add_argument('--english-reading',action='store_true',help='Include the optional kana-to-English dictionary (separate from the 30 categories)')
    ap.add_argument('--english',action='store_true',help='Include the optional English word dictionary')
    ap.add_argument('--release-archive',type=pathlib.Path,help='Verified v1.7.277 release ZIP')
    ap.add_argument('--release-manifest',type=pathlib.Path)
    ap.add_argument('--release-licenses',type=pathlib.Path)
    args=ap.parse_args()
    try:
        if any([args.release_archive,args.release_manifest,args.release_licenses]):
            if not all([args.release_archive,args.release_manifest,args.release_licenses]):
                raise ValueError('release archive, manifest, and licenses are all required')
            with tempfile.TemporaryDirectory(prefix='sumire-release-') as tmp:
                directory=pathlib.Path(tmp)
                manifest=unpack_release(args.release_archive,args.release_manifest,args.release_licenses,directory)
                build(args.source.resolve(),args.output.resolve(),args.english_reading,args.english,
                      (directory/'app/src/main/assets',manifest,args.release_licenses))
        else:
            build(args.source.resolve(),args.output.resolve(),args.english_reading,args.english)
    except (ValueError,OSError,subprocess.CalledProcessError,zipfile.BadZipFile) as e:ap.exit(1,str(e)+'\n')
