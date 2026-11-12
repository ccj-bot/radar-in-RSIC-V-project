from pathlib import Path
import ctypes
import numpy as np
_lib=None
def decode_horizontal(raw,kind,conf=.2,iou=.7,max_det=300):
 global _lib
 if _lib is None:
  _lib=ctypes.CDLL(str(Path(__file__).with_name('libnms_native.so')))
  _lib.nms_select.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_float,ctypes.c_double,ctypes.c_int,ctypes.c_void_p]
  _lib.nms_select.restype=ctypes.c_int
 from infer_k3 import XU_NAMES,polygon
 raw=np.ascontiguousarray(raw,dtype=np.float32)
 _,channels,n=raw.shape
 ids=np.empty(max_det,np.int32)
 count=_lib.nms_select(raw.ctypes.data,channels,n,conf,iou,max_det,ids.ctypes.data)
 result=[]
 for j in ids[:count]:
  cls=int(raw[0,4:,j].argmax())
  result.append({'class_id':cls,'class_name':XU_NAMES[cls],'confidence':float(raw[0,4+cls,j]),'polygon_input':polygon(*raw[0,:4,j],0).tolist()})
 return result
