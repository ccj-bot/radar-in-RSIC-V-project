from pathlib import Path
import os,sys,json,time,statistics,argparse,hashlib
ROOT=Path('/root/radarbrain_k3_20261108');W=ROOT/'optimization_v4'
sys.path[:0]=[str(ROOT/'app'),str(ROOT/'optimization_v2/app')]
import numpy as np
import onnxruntime as ort
import spacemit_ort
from nms_yolo11 import decode_horizontal
p=argparse.ArgumentParser();p.add_argument('--model',required=True);p.add_argument('--label',required=True);p.add_argument('--repeat',type=int,default=5);p.add_argument('--profile',action='store_true');a=p.parse_args()
opt=ort.SessionOptions();opt.intra_op_num_threads=8;opt.inter_op_num_threads=1;opt.log_severity_level=3
opt.enable_profiling=a.profile
if a.profile:opt.profile_file_prefix=str(W/'results'/(a.label+'_ort'))
start=time.perf_counter();sess=ort.InferenceSession(a.model,sess_options=opt,providers=['SpaceMITExecutionProvider','CPUExecutionProvider']);load_ms=(time.perf_counter()-start)*1000;name=sess.get_inputs()[0].name
rows=[]
for file in sorted((ROOT/'optimization_v3/results/release/yolo11-attn32').glob('*_raw.npz')):
 data=np.load(file);x=data['input'];ref=data['raw']
 for _ in range(2):outputs=sess.run(None,{name:x})
 times=[]
 for _ in range(a.repeat):
  start=time.perf_counter();outputs=sess.run(None,{name:x});times.append((time.perf_counter()-start)*1000)
 raw=outputs[0];finite=bool(np.isfinite(raw).all())
 row={'image':file.name,'times_ms':times,'median_ms':statistics.median(times),'finite':finite,'shape':list(raw.shape)}
 if finite and raw.shape==ref.shape:
  d=decode_horizontal(raw,'yolo11');b=decode_horizontal(ref,'yolo11');same=len(d)==len(b) and [v['class_id'] for v in d]==[v['class_id'] for v in b]
  row.update(count=len(d),same_count_classes=same,confidence_max_difference=max([abs(x['confidence']-y['confidence']) for x,y in zip(d,b)]+[0]),box_input_max_difference=max([float(np.max(abs(np.array(x['polygon_input'])-y['polygon_input']))) for x,y in zip(d,b)]+[0]) if same else None)
 rows.append(row);np.savez_compressed(W/'results'/(a.label+'_'+file.name),raw=raw)
print('MEASUREMENT_COMPLETE',flush=True)
record={'label':a.label,'model':a.model,'sha256':hashlib.sha256(Path(a.model).read_bytes()).hexdigest(),'load_ms':load_ms,'median_ms':statistics.median(r['median_ms'] for r in rows),'env':{k:v for k,v in os.environ.items() if k.startswith('SPACEMIT')},'images':rows,'providers':sess.get_providers()}
if a.profile:record['ort_profile']=sess.end_profiling()
(W/'results'/(a.label+'.json')).write_text(json.dumps(record,indent=2));print(json.dumps(record),flush=True)
