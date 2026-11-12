from pathlib import Path
import sys,json,time,hashlib,argparse
W=Path(__file__).resolve().parent;ROOT=W.parents[1]
sys.path[:0]=[str(W/'deps'),str(W/'vendor_source/xslim-main/src')]
import numpy as np,onnx,torch,xslim
torch.set_num_threads(4)
torch.backends.cuda.matmul.allow_tf32=False
p=argparse.ArgumentParser();p.add_argument('--mode',choices=['int8','int8_sensitive','int8_decode','int8_decode_only','int8_head','fp16_fused'],default='int8');p.add_argument('--calibration',default='minmax');p.add_argument('--real',action='store_true');p.add_argument('--tune',type=int,default=0);p.add_argument('--tag',default='');a=p.parse_args()
C=W/'calibration';C.mkdir(exist_ok=True);paths=[]
for f in sorted((ROOT/'work/optimization_submission_20261108/board/optimization_v3/results/release/yolo11-attn32').glob('*_raw.npz')):
 x=np.load(f)['input'];dest=C/(f.stem+'.npy');np.save(dest,x);paths.append(dest.name)
(C/'inputs.txt').write_text('\n'.join(paths),encoding='utf8')
if a.real:
 C=W/'calibration_real';paths=(C/'calibration.txt').read_text().splitlines()
list_path=C/('calibration.txt' if a.real else 'inputs.txt')
source=ROOT/'work/k3_migration_20261108/v2/models/xu_yolo11s_fp32.onnx'
model=onnx.load(source)
blocked=[n.name for n in model.graph.node if n.name.startswith('/model/model.10/m/m.0/attn/') or n.name.startswith('/model/model.23/dfl/')]
if a.mode in ('int8_decode','int8_head'):
 blocked += [n.name for n in model.graph.node if n.name.startswith('/model/model.23/') and (a.mode=='int8_head' or not n.name.startswith(('/model/model.23/cv2.','/model/model.23/cv3.')))]
if a.mode=='int8_decode_only':blocked=[n.name for n in model.graph.node if n.name.startswith('/model/model.23/') and not n.name.startswith(('/model/model.23/cv2.','/model/model.23/cv3.'))]
out=W/('xslim_'+a.mode+('_real' if a.real else '')+('_'+a.tag if a.tag else ''));out.mkdir(exist_ok=True)
precision=4 if a.mode=='fp16_fused' else 0
q={'precision_level':precision,'finetune_level':a.tune,'analysis_enable':False}
if a.mode!='int8':q['ignore_op_names']=blocked
config={'model_parameters':{'onnx_model':str(source),'working_dir':str(out),'output_prefix':'yolo11_'+a.mode},'calibration_parameters':{'calibration_device':'cuda','calibration_type':a.calibration,'calibration_step':max(10,len(paths)),'input_parameters':[{'input_name':'images','input_shape':[1,3,640,640],'file_type':'npy','dtype':'float32','data_list_path':str(list_path)}]},'quantization_parameters':q}
(out/'config.json').write_text(json.dumps(config,indent=2),encoding='utf8')
print(json.dumps({'mode':a.mode,'device':torch.cuda.get_device_name(0),'calibration_unique_inputs':len(paths),'scope':'initial quantization feasibility on three fixed inputs; labelled accuracy not evaluated'}),flush=True)
t=time.perf_counter();quant=xslim.quantize_onnx_model(config)
dest=out/('yolo11_'+a.mode+'.onnx');onnx.checker.check_model(quant)
summary={'elapsed_s':time.perf_counter()-t,'path':str(dest),'sha256':hashlib.sha256(dest.read_bytes()).hexdigest(),'nodes':len(quant.graph.node),'functions':[f.domain+'.'+f.name for f in quant.functions]}
(out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary),flush=True)
