from pathlib import Path
import ctypes
import numpy as np
_lib=None
def prepare_file(path,rotation=90,size=640):
 global _lib
 if _lib is None:
  _lib=ctypes.CDLL(str(Path(__file__).with_name('libpreprocess_file.so')))
  _lib.preprocess_file.argtypes=[ctypes.c_char_p,ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_void_p]
  _lib.preprocess_file.restype=ctypes.c_int
 out=np.empty((1,3,size,size),np.float32);meta=np.empty(5,np.float64)
 rc=_lib.preprocess_file(str(path).encode('utf8'),rotation,size,out.ctypes.data,meta.ctypes.data)
 if rc:
  # The native decoder covers the measured BMP/PNG formats. Other formats
  # retain the established Pillow route and the same numeric preprocessing.
  from PIL import Image
  from preprocess_native import preprocess
  image=Image.open(path).convert('RGB')
  tensor,pre=preprocess(image,rotation,size)
  return tensor,pre,image.size
 return out,tuple(meta[:3]),(int(meta[3]),int(meta[4]))
