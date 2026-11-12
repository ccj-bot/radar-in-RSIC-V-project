from pathlib import Path
import sys,json,collections
W=Path(__file__).resolve().parent
sys.path.insert(0,str(W/'host_deps'))
import onnx,numpy as np,onnxruntime as ort
from onnxconverter_common import float16
SRC=W.parent/'host_reference/models/sar_v5_compact_decoded_fp32.onnx'
OUT=W/'models';OUT.mkdir(exist_ok=True)
opts=ort.SessionOptions();opts.graph_optimization_level=ort.GraphOptimizationLevel.ORT_ENABLE_BASIC;opts.optimized_model_filepath=str(OUT/'compact_static_fp32.onnx')
sess=ort.InferenceSession(str(SRC),opts,providers=['CPUExecutionProvider'])
model=onnx.load(OUT/'compact_static_fp32.onnx')
print('BASIC_NODE_COUNTS',collections.Counter(n.op_type for n in model.graph.node))
onnx.save(model,OUT/'compact_static_fp32.onnx')
f16=float16.convert_float_to_float16(model,keep_io_types=True,disable_shape_infer=False,
 op_block_list=['Cast','ArgMax','ReduceMax','Resize'])
onnx.checker.check_model(f16)
onnx.save(f16,OUT/'compact_static_fp16.onnx')
info={v.name:v for v in list(f16.graph.value_info)+list(f16.graph.input)+list(f16.graph.output)}
fixes=[]
for node in f16.graph.node:
 if node.op_type=='Cast' and node.output[0] in info:
  declared=info[node.output[0]].type.tensor_type.elem_type
  for attr in node.attribute:
   if attr.name=='to' and attr.i!=declared and declared in [1,10]:
    fixes.append({'node':node.name,'old_to':attr.i,'new_to':declared});attr.i=declared
onnx.checker.check_model(f16)
onnx.save(f16,OUT/'compact_static_fp16_fixed.onnx')
report={'fp32_nodes':dict(collections.Counter(n.op_type for n in model.graph.node)),'fp16_nodes':dict(collections.Counter(n.op_type for n in f16.graph.node)),'files':{p.name:p.stat().st_size for p in OUT.glob('*.onnx')}}
report['cast_type_fixes']=fixes
(OUT/'conversion.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
