from pathlib import Path
import sys,json
W=Path(__file__).resolve().parent;ROOT=W.parents[1];V2=ROOT/'work/k3_migration_20261108/v2'
sys.path.insert(0,str(V2/'host_deps'))
import onnx
from onnx import helper
from onnxconverter_common import float16
m=onnx.load(V2/'models/xu_yolo11s_fp32.onnx')
blocked=[n.name for n in m.graph.node if n.name.startswith('/model/model.23/dfl/')]
converted=float16.convert_float_to_float16(m,keep_io_types=True,op_block_list=['Resize','Softmax'],node_block_list=blocked)
onnx.checker.check_model(converted);onnx.save(converted,W/'yolo11_dfl32.onnx')
nodes=[]
for n in converted.graph.node:
 if n.name=='/model/model.10/m/m.0/attn/MatMul_1':
  left,right=n.input;out=n.output[0]
  nodes += [helper.make_node('Transpose',[left],[left+'_v4t'],perm=[0,1,3,2],name=n.name+'_transpose_v'),helper.make_node('Transpose',[right],[right+'_v4t'],perm=[0,1,3,2],name=n.name+'_transpose_a'),helper.make_node('MatMul',[right+'_v4t',left+'_v4t'],[out+'_v4t'],name=n.name+'_alternate'),helper.make_node('Transpose',[out+'_v4t'],[out],perm=[0,1,3,2],name=n.name+'_transpose_output')]
 else:nodes.append(n)
del converted.graph.node[:];converted.graph.node.extend(nodes);onnx.checker.check_model(converted);onnx.save(converted,W/'yolo11_attn_transposed.onnx')
print('Created DFL FP32 and algebraically transposed attention variants')
