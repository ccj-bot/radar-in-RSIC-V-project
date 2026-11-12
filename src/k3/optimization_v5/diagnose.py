from pathlib import Path
import sys,os,time,json,statistics,argparse
ROOT=Path('/root/radarbrain_k3_20261108')
sys.path[:0]=[str(ROOT/'app'),str(ROOT/'optimization_v2/app'),str(ROOT/'optimization_v3/app')]
import numpy as np
from PIL import Image
import onnxruntime as ort
import spacemit_ort
from preprocess_native import preprocess
from nms_yolo11 import decode_horizontal
p=argparse.ArgumentParser();p.add_argument('--threads',type=int,default=8);p.add_argument('--label',default='diagnosis');a=p.parse_args()
opt=ort.SessionOptions();opt.intra_op_num_threads=a.threads;opt.inter_op_num_threads=1;opt.log_severity_level=3
s=ort.InferenceSession(str(ROOT/'optimization_v4/models/yolo11_int8_percentile.onnx'),sess_options=opt,providers=['SpaceMITExecutionProvider','CPUExecutionProvider'])
name=s.get_inputs()[0].name
files=sorted((ROOT/'input').glob('*'))
files=[p for p in files if p.suffix.lower() in {'.bmp','.jpg','.png'}]
x,_=preprocess(Image.open(files[0]).convert('RGB'))
for _ in range(3):s.run(None,{name:x})
rows=[]
for p in files:
 stages={k:[] for k in ['read','preprocess','inference','nms','iobinding']}
 for _ in range(8):
  t=time.perf_counter();im=Image.open(p).convert('RGB');stages['read'].append((time.perf_counter()-t)*1000)
  t=time.perf_counter();x,_=preprocess(im);stages['preprocess'].append((time.perf_counter()-t)*1000)
  t=time.perf_counter();raw=s.run(None,{name:x})[0];stages['inference'].append((time.perf_counter()-t)*1000)
  t=time.perf_counter();det=decode_horizontal(raw,'yolo11');stages['nms'].append((time.perf_counter()-t)*1000)
 binding=s.io_binding();binding.bind_cpu_input(name,x)
 for out in s.get_outputs():binding.bind_output(out.name,'cpu')
 for _ in range(8):
  t=time.perf_counter();s.run_with_iobinding(binding);binding.copy_outputs_to_cpu();stages['iobinding'].append((time.perf_counter()-t)*1000)
 rows.append({'image':p.name,'count':len(det),'median_ms':{k:statistics.median(v) for k,v in stages.items()},'raw':stages})
result={'ort_threads':a.threads,'env':{k:v for k,v in os.environ.items() if k.startswith('SPACEMIT')},'rows':rows}
(ROOT/'optimization_v5'/f'{a.label}.json').write_text(json.dumps(result,indent=2));print(json.dumps({'threads':a.threads,'rows':[{k:v for k,v in r.items() if k!='raw'} for r in rows]}),flush=True)
