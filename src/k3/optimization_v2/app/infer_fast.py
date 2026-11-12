"""Use the validated static FP16 graph with the existing detector pipeline."""
from pathlib import Path
import os,sys
ROOT=Path('/root/radarbrain_k3_20261108')
os.environ.setdefault('SPACEMIT_EP_INTRA_THREAD_NUM','8')
os.environ.setdefault('SPACEMIT_EP_INTER_THREAD_NUM','1')
sys.path.insert(0,str(ROOT/'app'))
import infer_k3
infer_k3.MODELS={'compact-fp16':'../optimization_v2/compact_static_fp16_fixed.onnx'}
if '--model' not in sys.argv:sys.argv+=['--model','compact-fp16']
if '--backend' not in sys.argv:sys.argv+=['--backend','spacemit']
if '--output' not in sys.argv:sys.argv+=['--output',str(ROOT/'optimization_v2/results/fast_detection')]
if '--threads' not in sys.argv:sys.argv+=['--threads','8']
infer_k3.main()
