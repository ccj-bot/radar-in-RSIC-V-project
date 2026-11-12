from pathlib import Path
import sys,json,time,statistics
ROOT=Path('/root/radarbrain_k3_20261108');W=ROOT/'optimization_v4'
sys.path[:0]=[str(ROOT/'app'),str(ROOT/'optimization_v2/app')]
import numpy as np,onnxruntime as ort,spacemit_ort
from nms_yolo11 import decode_horizontal
from infer_k3 import polygon_iou
p=Path(sys.argv[1]) if len(sys.argv)>1 else W/'models/yolo11_int8_decode_only.onnx';label=sys.argv[2] if len(sys.argv)>2 else 'decode_only'
o=ort.SessionOptions();o.intra_op_num_threads=8;o.inter_op_num_threads=1;o.log_severity_level=3;s=ort.InferenceSession(str(p),o,providers=['SpaceMITExecutionProvider','CPUExecutionProvider'])
rows=[]
for file in sorted((W/'holdout').glob('*.npz')):
 z=np.load(file);x=z['input'];t=time.perf_counter();r=s.run(None,{'images':x})[0];ms=(time.perf_counter()-t)*1000
 ref=decode_horizontal(z['reference'],'yolo11');det=decode_horizontal(r,'yolo11');matched=[]
 for cls in sorted({d['class_id'] for d in ref+det}):
  aa=[d for d in det if d['class_id']==cls];bb=[d for d in ref if d['class_id']==cls];pairs=sorted([(polygon_iou(a['polygon_input'],b['polygon_input']),i,j) for i,a in enumerate(aa) for j,b in enumerate(bb)],reverse=True);useda=set();usedb=set()
  for iou,i,j in pairs:
   if i in useda or j in usedb:continue
   useda.add(i);usedb.add(j);matched.append({'class':aa[i]['class_name'],'IoU_to_float':iou,'confidence_difference':abs(aa[i]['confidence']-bb[j]['confidence'])})
 rows.append({'image':file.name,'inference_ms_including_initial_call':ms,'float_cars':sum(d['class_name']=='car' for d in ref),'quant_cars':sum(d['class_name']=='car' for d in det),'matched':matched,'host_quant_raw_max_abs_difference':float(np.max(abs(r-z['quantized_host']))) if label=='decode_only' else None})
cars=[v for r in rows for v in r['matched'] if v['class']=='car'];result={'label':label,'model':str(p),'images':rows,'float_car_candidates':sum(r['float_cars'] for r in rows),'quant_car_candidates':sum(r['quant_cars'] for r in rows),'matched_cars':len(cars),'matched_car_IoU_median':statistics.median(r['IoU_to_float'] for r in cars),'matched_car_IoU_min':min(r['IoU_to_float'] for r in cars),'scope':'11 unlabelled frames excluded from 17-frame calibration; consistency to original floating model, not ground truth; first execution includes compile cost'}
(W/'results'/('holdout_'+label+'.json')).write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='images'}),flush=True)
