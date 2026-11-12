"""Reproduce the measured vendor INT8 recipe from the original FP32 graph."""
from pathlib import Path
import argparse,json,hashlib
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--calibration-list',type=Path,required=True);p.add_argument('--output-dir',type=Path,required=True);a=p.parse_args()
import xslim,onnx,torch
torch.set_num_threads(4);torch.backends.cuda.matmul.allow_tf32=False
m=onnx.load(a.input)
blocked=[n.name for n in m.graph.node if n.name.startswith('/model/model.23/') and not n.name.startswith(('/model/model.23/cv2.','/model/model.23/cv3.'))]
cfg={'model_parameters':{'onnx_model':str(a.input.resolve()),'working_dir':str(a.output_dir.resolve()),'output_prefix':'yolo11_int8_decode_only'},'calibration_parameters':{'calibration_device':'cuda' if torch.cuda.is_available() else 'cpu','calibration_type':'percentile','calibration_step':17,'input_parameters':[{'input_name':'images','input_shape':[1,3,640,640],'file_type':'npy','dtype':'float32','data_list_path':str(a.calibration_list.resolve())}]},'quantization_parameters':{'precision_level':0,'finetune_level':0,'analysis_enable':False,'ignore_op_names':blocked}}
a.output_dir.mkdir(parents=True,exist_ok=True);(a.output_dir/'config.json').write_text(json.dumps(cfg,indent=2),encoding='utf8');xslim.quantize_onnx_model(cfg)
out=a.output_dir/'yolo11_int8_decode_only.onnx';print('output_sha256',hashlib.sha256(out.read_bytes()).hexdigest())
