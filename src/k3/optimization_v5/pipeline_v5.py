from pathlib import Path
import sys,time,json,statistics,argparse
from concurrent.futures import ThreadPoolExecutor
R=Path('/root/radarbrain_k3_20261108');W=R/'optimization_v5'
sys.path[:0]=[str(R/'app'),str(R/'optimization_v2/app'),str(R/'optimization_v3/app')]
import numpy as np
from PIL import Image
import onnxruntime as ort
import spacemit_ort
from preprocess_native import preprocess
from preprocess_file import prepare_file
from nms_native import decode_horizontal
from nms_yolo11 import decode_horizontal as old_decode
p=argparse.ArgumentParser();p.add_argument('--rounds',type=int,default=3);p.add_argument('--label',default='pipeline_v5');p.add_argument('--validate-holdout',action='store_true');a=p.parse_args()
files=sorted(p for p in (R/'input').iterdir() if p.suffix.lower() in {'.bmp','.png','.jpg'})
opt=ort.SessionOptions();opt.intra_op_num_threads=8;opt.inter_op_num_threads=1;opt.log_severity_level=3
s=ort.InferenceSession(str(R/'optimization_v4/models/yolo11_int8_percentile.onnx'),sess_options=opt,providers=['SpaceMITExecutionProvider','CPUExecutionProvider']);name=s.get_inputs()[0].name
validation=[]
if a.validate_holdout:
 for f in sorted((R/'optimization_v4/holdout').glob('*.npz')):
  raw=s.run(None,{name:np.load(f)['input']})[0]
  assert old_decode(raw,'yolo11')==decode_horizontal(raw,'yolo11'),f
  validation.append(f.name)
 assert len(validation)==11,len(validation)
for f in files:
 x,_,_=prepare_file(f);raw=s.run(None,{name:x})[0]
 assert old_decode(raw,'yolo11')==decode_horizontal(raw,'yolo11'),f
for _ in range(3):s.run(None,{name:x})
records=[]
for mode in ['previous_overlap','native_serial','native_overlap']:
 rounds=[]
 def prepare(f):
  if mode=='previous_overlap':return preprocess(Image.open(f).convert('RGB'))[0]
  return prepare_file(f)[0]
 def process(x):
  raw=s.run(None,{name:x})[0]
  if not np.isfinite(raw).all():raise RuntimeError('Nonfinite output')
  return (old_decode if mode=='previous_overlap' else decode_horizontal)(raw,'yolo11')
 for _ in range(a.rounds):
  frames=files*6;counts=[];start=time.perf_counter()
  if mode=='native_serial':
   for f in frames:counts.append(len(process(prepare(f))))
  else:
   with ThreadPoolExecutor(max_workers=1) as pool:
    future=pool.submit(prepare,frames[0])
    for i,f in enumerate(frames):
     x=future.result()
     if i+1<len(frames):future=pool.submit(prepare,frames[i+1])
     counts.append(len(process(x)))
  elapsed=time.perf_counter()-start
  assert counts==[5,2,5]*6,counts
  rounds.append({'frames':len(frames),'elapsed_s':elapsed,'fps':len(frames)/elapsed,'counts':counts})
 records.append({'mode':mode,'rounds':rounds,'median_fps':statistics.median(v['fps'] for v in rounds)})
result={'model_sha256':'cb243c62ce53e01e5bc592e3acb17f47cb5af466a62b308db2232af005bfa549','threads':8,'input':'3 fixed files repeated six times per round','timing_includes':'read, preprocess, inference, finite check and NMS; excludes acquisition, imaging, drawing and saving','native_nms_holdout_exact':validation,'results':records}
(W/(a.label+'.json')).write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
