from pathlib import Path
import ctypes,os,numpy as np
NAME=os.environ.get('RDA_FFT_BACKEND','numpy')
THREADS=int(os.environ.get('RDA_FFT_THREADS','4'))
_lib=None;_plans={}

def transform(a,axis,inverse=False,n=None):
 if NAME=='numpy':return (np.fft.ifft if inverse else np.fft.fft)(a,n=n,axis=axis)
 global _lib
 if _lib is None:
  _lib=ctypes.CDLL(str(Path(__file__).resolve().parent/'libfftw_bridge.so'))
  _lib.make_fft_plan.argtypes=[ctypes.c_int]*5;_lib.make_fft_plan.restype=ctypes.c_void_p
  _lib.apply_fft.argtypes=[ctypes.c_void_p]*3;_lib.apply_fft.restype=None
 a=np.ascontiguousarray(a,dtype=np.complex64)
 if n is not None and n!=a.shape[axis]:
  shape=list(a.shape);shape[axis]=n;b=np.zeros(shape,np.complex64);slices=[slice(None)]*2;slices[axis]=slice(0,min(n,a.shape[axis]));b[tuple(slices)]=a[tuple(slices)];a=b
 key=(a.shape,axis,inverse)
 if key not in _plans:
  _plans[key]=_lib.make_fft_plan(*a.shape,axis,1 if inverse else -1,THREADS)
  if not _plans[key]:raise RuntimeError('FFTW planning failed')
 output=np.empty_like(a)
 _lib.apply_fft(_plans[key],a.ctypes.data,output.ctypes.data)
 if inverse:output/=a.shape[axis]
 return output

def fft(a,n=None,axis=-1):return transform(a,axis%a.ndim,False,n)
def ifft(a,n=None,axis=-1):return transform(a,axis%a.ndim,True,n)
