from pathlib import Path
import sys,time,json,statistics
from concurrent.futures import ThreadPoolExecutor
ROOT=Path('/root/radarbrain_k3_20261108');W=ROOT/'optimization_v3'
sys.path[:0]=[str(ROOT/'app'),str(ROOT/'optimization_v2/app')]
from PIL import Image
import numpy as np
import onnxruntime as ort
import spacemit_ort
from preprocess_native import preprocess
from nms_yolo11 import decode_horizontal
files=sorted(p for p in (ROOT/'input').iterdir() if p.suffix.lower() in {'.bmp','.png','.jpg'})
opt=ort.SessionOptions();opt.intra_op_num_threads=8;opt.inter_op_num_threads=1;opt.log_severity_level=3
s=ort.InferenceSession(str(W/'models/yolo11_attn32.onnx'),sess_options=opt,providers=['SpaceMITExecutionProvider','CPUExecutionProvider']);name=s.get_inputs()[0].name
def prepare(p):
 t=time.perf_counter();x,_=preprocess(Image.open(p).convert('RGB'));return x,(time.perf_counter()-t)*1000
def infer(x):
 raw=s.run(None,{name:x})[0]
 if not np.isfinite(raw).all():raise RuntimeError('Nonfinite output')
 return decode_horizontal(raw,'yolo11-attn32')
for _ in range(2):infer(prepare(files[0])[0])
records=[]
for mode in ['serial','overlapped']:
 rounds=[]
 for repeat in range(3):
  frames=files*6;counts=[];start=time.perf_counter()
  if mode=='serial':
   for p in frames:counts.append(len(infer(prepare(p)[0])))
  else:
   with ThreadPoolExecutor(max_workers=1) as pool:
    future=pool.submit(prepare,frames[0])
    for i,p in enumerate(frames):
     x,pre_ms=future.result()
     if i+1<len(frames):future=pool.submit(prepare,frames[i+1])
     counts.append(len(infer(x)))
  duration=time.perf_counter()-start
  assert counts==[5,2,5]*6,counts
  rounds.append({'frames':len(frames),'elapsed_s':duration,'throughput_fps':len(frames)/duration,'mean_interval_ms':duration*1000/len(frames),'counts':counts})
 records.append({'mode':mode,'rounds':rounds,'median_fps':statistics.median(r['throughput_fps'] for r in rounds)})
result={'input':'three fixed SAR files repeated six times per round; replay workload','rounds_per_mode':3,'timing_includes':'file read, native preprocess, network inference and horizontal NMS; excludes annotation drawing, file saving, SAR acquisition and imaging','results':records}
(W/'results/pipeline_benchmark.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
