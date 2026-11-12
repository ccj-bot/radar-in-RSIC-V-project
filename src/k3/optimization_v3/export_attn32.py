from pathlib import Path
import argparse,hashlib,json
import onnx
from onnxconverter_common import float16
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
m=onnx.load(a.input)
blocked=[n.name for n in m.graph.node if n.name.startswith('/model/model.10/m/m.0/attn/') or n.name.startswith('/model/model.23/dfl/')]
if len(blocked)!=25:raise RuntimeError('Expected inspected YOLO11s graph; audit new graph names before conversion')
m=float16.convert_float_to_float16(m,keep_io_types=True,op_block_list=['Resize','Softmax'],node_block_list=blocked)
onnx.checker.check_model(m);onnx.save(m,a.output)
print(hashlib.sha256(a.output.read_bytes()).hexdigest())
