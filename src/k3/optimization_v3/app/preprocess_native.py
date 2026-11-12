from pathlib import Path
import ctypes
import numpy as np
LIB=None
def preprocess(image,rotation=90,size=640):
 global LIB
 if LIB is None:
  LIB=ctypes.CDLL(str(Path(__file__).with_name('libpreprocess_native.so')))
  LIB.preprocess_rgb.argtypes=[ctypes.c_void_p]+[ctypes.c_int]*8+[ctypes.c_void_p]
  LIB.preprocess_rgb.restype=ctypes.c_int
 w,h=image.size
 rw,rh=(h,w) if rotation in (90,270) else (w,h)
 ratio=min(size/rh,size/rw);nw,nh=round(rw*ratio),round(rh*ratio)
 left,top=round((size-nw)/2-.1),round((size-nh)/2-.1)
 pixels=np.ascontiguousarray(np.asarray(image));out=np.empty((1,3,size,size),np.float32)
 status=LIB.preprocess_rgb(pixels.ctypes.data,h,w,rotation,nw,nh,left,top,size,out.ctypes.data)
 if status:raise RuntimeError('Native RGB preprocessing failed')
 return out,(ratio,left,top)
