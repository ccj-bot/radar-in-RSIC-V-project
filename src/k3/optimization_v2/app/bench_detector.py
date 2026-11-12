from pathlib import Path
import argparse,os,json,time,sys,statistics
p=argparse.ArgumentParser();p.add_argument('--label',required=True);p.add_argument('--epthreads',type=int);p.add_argument('--affinity');p.add_argument('--provider',default='vendor');p.add_argument('--model');p.add_argument('--repeat',type=int,default=5);p.add_argument('--profile',action='store_true');a=p.parse_args()
ROOT=Path('/root/radarbrain_k3_20261108');OUT=ROOT/'optimization_v2/results';OUT.mkdir(exist_ok=True)
if a.epthreads:
 os.environ['SPACEMIT_EP_INTRA_THREAD_NUM']=str(a.epthreads)
 os.environ['SPACEMIT_EP_INTER_THREAD_NUM']='1'
if a.affinity:os.sched_setaffinity(0,{int(x) for x in a.affinity.split(',')})
sys.path.insert(0,str(ROOT/'app'))
import numpy as np
import onnxruntime as ort
if a.provider=='vendor':import spacemit_ort
from infer_k3 import decode,original_coordinates
baseline=ROOT/'results/cpu_cv/compact-fp32/01_R35_SAR378_raw.npz';ref=np.load(baseline);x=ref['input']
model=Path(a.model) if a.model else ROOT/'models/sar_v5_compact_decoded_fp32.onnx'
options=ort.SessionOptions();options.intra_op_num_threads=a.epthreads or 4;options.inter_op_num_threads=1;options.log_severity_level=3
if a.profile:options.enable_profiling=True;options.profile_file_prefix=str(OUT/(a.label+'_profile'))
providers=['SpaceMITExecutionProvider','CPUExecutionProvider'] if a.provider=='vendor' else ['CPUExecutionProvider']
t=time.perf_counter();s=ort.InferenceSession(str(model),sess_options=options,providers=providers);load=time.perf_counter()-t
name=s.get_inputs()[0].name
for _ in range(2):raw=s.run(None,{name:x})[0]
times=[];cpu=[]
for _ in range(a.repeat):
 c=time.process_time();t=time.perf_counter();raw=s.run(None,{name:x})[0];times.append((time.perf_counter()-t)*1000);cpu.append((time.process_time()-c)*1000)
d=decode(raw,'compact-fp32');rd=decode(ref['raw'],'compact-fp32')
correct=len(d)==len(rd) and [v['class_id'] for v in d]==[v['class_id'] for v in rd]
result={'label':a.label,'epthreads':a.epthreads,'affinity':sorted(os.sched_getaffinity(0)),'env':{k:v for k,v in os.environ.items() if k.startswith(('SPACEMIT','SPERT','OMP'))},'runtime':ort.__version__,'providers':s.get_providers(),'load_s':load,'times_ms':times,'median_ms':statistics.median(times),'process_cpu_ms':cpu,'cpu_parallelism':sum(cpu)/sum(times),'process_threads':len(list(Path('/proc/self/task').iterdir())),'candidates_equal':correct,'confidence_max_diff':max([abs(v['confidence']-r['confidence']) for v,r in zip(d,rd)]+[0]),'candidate_poly_input_max_diff':max([float(np.max(abs(np.array(v['polygon_input'])-np.array(r['polygon_input'])))) for v,r in zip(d,rd)]+[0]),'model':str(model)}
if a.profile:
 profile=s.end_profiling();result['profile']=profile
np.savez_compressed(OUT/(a.label+'_raw.npz'),raw=raw)
(OUT/(a.label+'.json')).write_text(json.dumps(result,indent=2))
print(json.dumps({k:result[k] for k in ['label','median_ms','cpu_parallelism','process_threads','candidates_equal','confidence_max_diff']}),flush=True)
