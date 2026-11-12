from pathlib import Path
import sys,json,numpy as np,statistics,hashlib,argparse
W=Path(__file__).resolve().parent;ROOT=W.parents[1]
sys.path[:0]=[str(W/'deps'),str(ROOT/'work/k3_migration_20261108'),str(ROOT/'work/k3_migration_20261108/v2')]
import onnxruntime as ort
from nms_yolo11 import decode_horizontal
from infer_k3 import polygon_iou
from scipy.optimize import linear_sum_assignment
opt=ort.SessionOptions();opt.intra_op_num_threads=4
fp=ort.InferenceSession(str(ROOT/'work/k3_migration_20261108/v2/models/xu_yolo11s_fp32.onnx'),opt,providers=['CPUExecutionProvider'])
p=argparse.ArgumentParser();p.add_argument('--model',type=Path,default=W/'xslim_int8_decode_only_real/yolo11_int8_decode_only.onnx');p.add_argument('--label',default='int8_decode_only');a0=p.parse_args()
q=ort.InferenceSession(str(a0.model),opt,providers=['CPUExecutionProvider'])
manifest=json.loads((W/'calibration_real/manifest.json').read_text());rows=[]
refout=W/'holdout_inputs';refout.mkdir(exist_ok=True)
for item in manifest['records']:
 if item['role']!='holdout':continue
 x=np.load(W/'calibration_real'/item['input']);rawq=q.run(None,{'images':x})[0];rawf=fp.run(None,{'images':x})[0];a=decode_horizontal(rawq,'yolo11');b=decode_horizontal(rawf,'yolo11')
 matched=[]
 for cls in sorted({r['class_id'] for r in a+b}):
  aa=[v for v in a if v['class_id']==cls];bb=[v for v in b if v['class_id']==cls]
  if not aa or not bb:continue
  ious=np.array([[polygon_iou(v['polygon_input'],r['polygon_input']) for r in bb] for v in aa]);ia,ib=linear_sum_assignment(1-ious)
  for i,j in zip(ia,ib):matched.append({'class':aa[i]['class_name'],'IoU_to_float':float(ious[i,j]),'confidence_difference':abs(aa[i]['confidence']-bb[j]['confidence']),'max_corner_difference_input_px':float(np.max(abs(np.array(aa[i]['polygon_input'])-bb[j]['polygon_input'])))})
 row={'frame':item['frame'],'float_candidates':len(b),'quant_candidates':len(a),'float_cars':sum(v['class_name']=='car' for v in b),'quant_cars':sum(v['class_name']=='car' for v in a),'matched':matched};rows.append(row)
 np.savez_compressed(refout/(Path(item['input']).stem+'.npz'),input=x,reference=rawf,quantized_host=rawq)
cars=[v for r in rows for v in r['matched'] if v['class']=='car'];result={'kind':'11 unlabelled R35 frames excluded from 17-frame calibration; consistency to original floating model, not ground truth','rows':rows,'float_car_candidates':sum(r['float_cars'] for r in rows),'quant_car_candidates':sum(r['quant_cars'] for r in rows),'matched_cars':len(cars),'matched_car_IoU_median':statistics.median(v['IoU_to_float'] for v in cars),'matched_car_IoU_min':min(v['IoU_to_float'] for v in cars),'matched_car_conf_max_difference':max(v['confidence_difference'] for v in cars)}
(W/('holdout_'+a0.label+'.json')).write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
