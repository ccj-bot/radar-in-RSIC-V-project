"""Prepare the tested YOLO11 mixed precision graph from the original FP32 ONNX."""
from pathlib import Path
import argparse,hashlib,json
import onnx
from onnxconverter_common import float16
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
model=onnx.load(a.input)
blocked=[n.name for n in model.graph.node if n.name.startswith('/model/model.10/') or n.name.startswith('/model/model.23/dfl/')]
if len(blocked)!=39:raise RuntimeError('This export recipe expects the inspected YOLO11 graph; re-audit changed node names')
converted=float16.convert_float_to_float16(model,keep_io_types=True,op_block_list=['Resize','Softmax'],node_block_list=blocked)
onnx.checker.check_model(converted);onnx.save(converted,a.output)
a.output.with_suffix('.conversion.json').write_text(json.dumps({'source_sha256':hashlib.sha256(a.input.read_bytes()).hexdigest(),'output_sha256':hashlib.sha256(a.output.read_bytes()).hexdigest(),'FP32_nodes':blocked,'note':'FP32 PSA attention block and DFL decode, other eligible nodes FP16; float32 input/output; no training'},indent=2))
