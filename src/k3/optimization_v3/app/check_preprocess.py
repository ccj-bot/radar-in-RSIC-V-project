from pathlib import Path
import sys,json,time,statistics
ROOT=Path('/root/radarbrain_k3_20261108');W=ROOT/'optimization_v3'
sys.path[:0]=[str(ROOT/'app'),str(W/'app')]
from PIL import Image
import numpy as np
import infer_k3
from preprocess_native import preprocess
rows=[]
for p in sorted((ROOT/'input').iterdir()):
 if p.suffix.lower() not in {'.bmp','.png','.jpg'}:continue
 im=Image.open(p).convert('RGB')
 for rot in [0,90,180,270]:
  x,meta=infer_k3.preprocess(im,rot);y,meta2=preprocess(im,rot)
  assert meta==meta2
  diff=float(np.max(abs(x-y)));assert diff==0,(p.name,rot,diff)
 times={}
 for label,fn in [('previous',infer_k3.preprocess),('native',preprocess)]:
  for _ in range(2):fn(im,90)
  values=[]
  for _ in range(15):
   t=time.perf_counter();fn(im,90);values.append((time.perf_counter()-t)*1000)
  times[label]=values
 rows.append({'image':p.name,'rotations_tested':[0,90,180,270],'input_tensor_max_abs_difference':diff,'times_ms':times,'median_ms':{k:statistics.median(v) for k,v in times.items()}})
result={'images':rows,'all_exact':True};(W/'results/preprocess_validation.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
