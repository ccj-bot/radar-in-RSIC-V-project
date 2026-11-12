from pathlib import Path
import sys,json,collections
W=Path(__file__).resolve().parent;sys.path.insert(0,str(W/'deps'))
import onnx
from onnx import numpy_helper
records=[]
for mode in ['int8_sensitive','int8_decode']:
 path=W/('xslim_'+mode+'_real')/('yolo11_'+mode+'.onnx');m=onnx.load(path)
 const={v.name:numpy_helper.to_array(v) for v in m.graph.initializer};parents={o:n for n in m.graph.node for o in n.output}
 final=next(n for n in m.graph.node if n.name=='/model/model.23/Concat_3');score=next(n for n in m.graph.node if n.name=='/model/model.23/Sigmoid')
 row={'mode':mode,'nodes':len(m.graph.node),'final_concat_inputs':list(final.input),'score_output':list(score.output),'score_consumers':[]}
 for n in m.graph.node:
  if any(x in score.output for x in n.input):
   row['score_consumers'].append({'op':n.op_type,'name':n.name,'params':{k:const[k].tolist() for k in n.input[1:] if k in const}})
 for inp in final.input:
  n=parents.get(inp)
  if n and n.op_type=='DequantizeLinear':row.setdefault('concat_DQ',[]).append({'name':n.name,'params':{k:const[k].tolist() for k in n.input[1:] if k in const}})
 records.append(row)
(W/'quantization_root_cause.json').write_text(json.dumps(records,indent=2));print(json.dumps(records,indent=2))
