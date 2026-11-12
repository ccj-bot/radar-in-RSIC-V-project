from pathlib import Path
import os,sys
ROOT=Path('/root/radarbrain_k3_20261108')
os.environ.setdefault('SPACEMIT_EP_INTRA_THREAD_NUM','8');os.environ.setdefault('SPACEMIT_EP_INTER_THREAD_NUM','1')
sys.path.insert(0,str(ROOT/'app'))
import infer_k3
from nms_yolo11 import decode_horizontal
infer_k3.decode=decode_horizontal
mode=os.environ.get('YOLO11_PRECISION','fp16')
infer_k3.MODELS={'yolo11-'+mode:f'../optimization_v2/xu_yolo11s_{mode}.onnx'}
if '--model' not in sys.argv:sys.argv+=['--model','yolo11-'+mode]
if '--backend' not in sys.argv:sys.argv+=['--backend','spacemit']
if '--threads' not in sys.argv:sys.argv+=['--threads','8']
if '--output' not in sys.argv:sys.argv+=['--output',str(ROOT/('optimization_v2/results/yolo11_'+mode))]
infer_k3.main()
