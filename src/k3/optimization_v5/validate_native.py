from pathlib import Path
import sys,time,json,statistics
R=Path('/root/radarbrain_k3_20261108');W=R/'optimization_v5'
sys.path[:0]=[str(R/'app'),str(R/'optimization_v2/app'),str(R/'optimization_v3/app')]
from PIL import Image
import numpy as np
from preprocess_native import preprocess
from preprocess_file import prepare_file
from nms_yolo11 import decode_horizontal as old_decode
from nms_native import decode_horizontal as new_decode
rows=[]
for p in sorted((R/'input').iterdir()):
 if p.suffix.lower() not in {'.bmp','.png','.jpg'}:continue
 for rotation in [0,90,180,270]:
  old,meta=preprocess(Image.open(p).convert('RGB'),rotation)
  new,new_meta,shape=prepare_file(p,rotation)
  diff=float(np.max(np.abs(new-old)))
  assert np.array_equal(old,new),(p.name,rotation,diff)
  assert meta==new_meta,(meta,new_meta)
  rows.append({'image':p.name,'rotation':rotation,'exact':True,'maximum_difference':diff})
post=[]
for p in sorted((R/'optimization_v4/results/percentile_release/yolo11-xslim-int8').glob('*_raw.npz')):
 raw=np.load(p)['raw'];old=old_decode(raw,'yolo11');new=new_decode(raw,'yolo11')
 assert old==new,(p.name,old,new)
 times={}
 for label,fn in [('numpy',old_decode),('native',new_decode)]:
  seq=[]
  for _ in range(20):
   t=time.perf_counter();fn(raw,'yolo11');seq.append((time.perf_counter()-t)*1000)
  times[label]=statistics.median(seq)
 post.append({'image':p.name,'exact':True,'count':len(old),'median_ms':times})
read=[]
for p in sorted((R/'input').iterdir()):
 if p.suffix.lower() not in {'.bmp','.png','.jpg'}:continue
 times={}
 for label,fn in [('pillow_native',lambda:preprocess(Image.open(p).convert('RGB'))),('native_file',lambda:prepare_file(p))]:
  seq=[]
  for _ in range(15):
   t=time.perf_counter();fn();seq.append((time.perf_counter()-t)*1000)
  times[label]=statistics.median(seq)
 read.append({'image':p.name,'median_ms':times})
result={'preprocess':rows,'nms':post,'read_and_preprocess':read}
(W/'native_validation.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
