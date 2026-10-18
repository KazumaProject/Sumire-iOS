#!/usr/bin/env python3
"""Verify shipped-asset samples for system + all 30 categories and every matrix cell.
Usage: test_real_assets.py CLI GENERATED_DIR ANDROID_REFERENCE
This is data/CLI verification, not Android application candidate parity.
"""
import array, hashlib, importlib.util, json, pathlib, struct, subprocess, sys, zipfile
sys.dont_write_bytecode = True
spec=importlib.util.spec_from_file_location('builder',pathlib.Path(__file__).resolve().parents[2]/'Scripts/build_dictionary.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
cli,data,source=sys.argv[1:];data=pathlib.Path(data);source=pathlib.Path(source);assets=source/'app/src/main/assets'
manifest=json.loads((data/'manifest.json').read_text())
revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
assert revision==b.REVISION==manifest['source_revision'], (revision,b.REVISION,manifest['source_revision'])
source_files=['pos_table.dat','connectionId.dat.zip']+[f'{directory}/{filename}.dat.zip' for directory in ['system']+['categories/'+name for name in b.CATEGORIES] for filename in ['yomi','tango','token']]
for name in source_files:
    actual=hashlib.sha256((assets/name).read_bytes()).hexdigest()
    assert manifest['asset_sha256'].get(name)==actual, name
def raw(path):
    with zipfile.ZipFile(path) as z:return z.read(z.namelist()[0])
def tree_parent(lbs,labels):
    bits=b.Bits(lbs);parents=array.array('I',[0])*len(labels)
    for i,p in enumerate(bits.ones(),1):parents[i]=p+1-i
    return bits,parents
def decode(index,parents,labels):
    chars=[]
    while index>1:chars.append(labels[index]);index=parents[index]
    return b.le(array.array('H',reversed(chars))).decode('utf-16-le')
samples=[]
for name in ['system']+b.CATEGORIES:
    folder=assets/('system' if name=='system' else 'categories/'+name)
    lbs,leaf,labels,terms=b.JavaArrays(raw(folder/'yomi.dat.zip')).all(4)
    tlbs,_,tlabels=b.JavaArrays(raw(folder/'tango.dat.zip')).all(3)
    pos,cost,node,post=b.JavaArrays(raw(folder/'token.dat.zip')).all(4)
    ybits,parents=tree_parent(lbs,labels);tbits,tparents=tree_parent(tlbs,tlabels)
    posting=b.Bits(post);starts=[0];ones=0
    for p in range(len(post)*64):
        if posting.a[p//64]>>(p%64)&1:ones+=1
        else:starts.append(ones)
        if ones==len(pos):break
    starts.append(ones)
    candidates=[]
    for idx,p in enumerate(b.Bits(leaf).ones()):
        reading=decode(ybits.rank(p),parents,labels)
        if not 6<=len(reading)<=32:continue
        term=terms[idx]
        for token in range(starts[term],starts[term+1]):
            if node[token]>=0:
                text=decode(tbits.rank(node[token]),tparents,tlabels)
                candidates.append((cost[token],reading,text))
        if len(candidates)>=64:break
    if not candidates:raise AssertionError('no sample '+name)
    _,reading,text=min(candidates)
    samples.append({'dictionary':name,'reading':reading,'text':text,'source_entries':len(pos)})
proc=subprocess.run([cli,'--data',str(data),'--categories','all','--lookup','--nbest','100','--stdin'],input='\n'.join(s['reading'] for s in samples)+'\n',text=True,capture_output=True,check=True)
results=[json.loads(line) for line in proc.stdout.splitlines()]
assert len(results)==31
for sample,result in zip(samples,results):
    assert any(c['text']==sample['text'] and c['segments'][0]['dictionary']==sample['dictionary'] for c in result['candidates']), (sample,result)
# Decode the new connection representation independently and compare all cells.
f=(data/'connection.sud').read_bytes();sections=[]
for i in range(7):
    off,size=struct.unpack_from('<QQ',f,24+i*24);sections.append(f[off:off+size])
n=struct.unpack_from('<I',f,20)[0];defaults=struct.unpack('<'+'h'*n,sections[2]);words=struct.unpack('<'+'Q'*(len(sections[3])//8),sections[3]);values=struct.unpack('<'+'h'*(len(sections[4])//2),sections[4]);starts=struct.unpack('<'+'I'*(n+1),sections[5]);matrix=array.array('h');matrix.frombytes(raw(assets/'connectionId.dat.zip'))
if sys.byteorder=='little':matrix.byteswap()
blocks=(n+63)//64
for row in range(n):
    decoded=array.array('h',[defaults[row]])*n;v=starts[row]
    for block in range(blocks):
        word=words[row*blocks+block]
        while word:
            bit=word&-word;column=block*64+bit.bit_length()-1
            assert column<n;decoded[column]=values[v];v+=1;word^=bit
    assert v==starts[row+1] and decoded==matrix[row*n:(row+1)*n],row
print(json.dumps({'verified_dictionaries':31,'verified_matrix_cells':n*n,'samples':samples},ensure_ascii=False,indent=2))
