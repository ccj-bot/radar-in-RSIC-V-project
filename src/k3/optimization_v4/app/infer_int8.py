from pathlib import Path
import sys
ROOT=Path('/root/radarbrain_k3_20261108')
sys.path[:0]=[str(ROOT/'app'),str(ROOT/'optimization_v2/app'),str(ROOT/'optimization_v3/app')]
import infer_k3
from preprocess_native import preprocess
from nms_yolo11 import decode_horizontal
infer_k3.preprocess=preprocess;infer_k3.decode=decode_horizontal
infer_k3.MODELS={'yolo11-xslim-int8':'../optimization_v4/models/yolo11_int8_percentile.onnx'}
defaults={'--model':'yolo11-xslim-int8','--backend':'spacemit','--threads':'8','--repeat':'10','--warmup':'3','--output':str(ROOT/'optimization_v4/results/release')}
for k,v in defaults.items():
 if k not in sys.argv:sys.argv.extend([k,v])
infer_k3.main()
