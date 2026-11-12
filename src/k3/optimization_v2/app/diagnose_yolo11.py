from pathlib import Path
import sys,json,time
import numpy as np,onnxruntime as ort,spacemit_ort
ROOT=Path('/root/radarbrain_k3_20261108')
p=Path(sys.argv[1]);opts=ort.SessionOptions();opts.intra_op_num_threads=8;opts.inter_op_num_threads=1;opts.log_severity_level=3
x=np.load(ROOT/'results/cpu_cv/xu-int8/01_R35_SAR378_raw.npz')['input'];s=ort.InferenceSession(str(p),opts,providers=['SpaceMITExecutionProvider','CPUExecutionProvider']);names=[v.name for v in s.get_outputs()]
r=s.run(None,{'images':x});report=[]
for name,a in zip(names,r):
 finite=np.isfinite(a);report.append({'name':name,'shape':list(a.shape),'nan':int(np.isnan(a).sum()),'inf':int(np.isinf(a).sum()),'finite_abs_max':float(abs(a[finite]).max()) if finite.any() else None})
print(json.dumps(report,indent=2))
