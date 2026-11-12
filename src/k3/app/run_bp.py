"""Complex echo -> IFFT range compression -> C++ scalar/RVV spherical BP."""
from pathlib import Path
import argparse,ctypes,json,time
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]

def main():
 p=argparse.ArgumentParser();p.add_argument('--threads',type=int,default=4);p.add_argument('--repeat',type=int,default=3);p.add_argument('--output',type=Path,default=ROOT/'results/bp');a=p.parse_args()
 a.output.mkdir(parents=True,exist_ok=True)
 lib=ctypes.CDLL(str(ROOT/'app/libbp_k3.so'));lib.rvv_bits.restype=ctypes.c_size_t
 ptrd=np.ctypeslib.ndpointer(dtype=np.float64,flags='C_CONTIGUOUS');ptrf=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS')
 types=[ptrd,ptrd,ctypes.c_int,ptrd,ctypes.c_int,ptrf,ptrf,ctypes.c_int,ctypes.c_double,ctypes.c_double,ptrd,ptrd,ctypes.c_int]
 for name in ['bp_scalar','bp_rvv']:getattr(lib,name).argtypes=types;getattr(lib,name).restype=None
 points=np.array([[-.6,10.],[0.,10.],[.6,10.]])
 nr=256;nfft=8192;nm=1000;df=3e9/nr;first=77e9;fref=first+(nr-1)*df/2
 apx=np.ascontiguousarray((np.arange(nm)-(nm-1)/2)*3/10000)
 frequencies=first+df*np.arange(nr)
 t=time.perf_counter();echo=np.zeros((nm,nr),np.complex128)
 for px,py in points:
  ranges=np.sqrt((apx-px)**2+py**2)
  echo+=np.exp(-1j*4*np.pi/3e8*ranges[:,None]*frequencies[None,:])
 h=np.fft.ifft(echo,n=nfft,axis=1)*(nfft/nr)
 h*=np.exp(-1j*2*np.pi*(nr-1)/2*np.arange(nfft)/nfft)[None,:]
 h=h.astype(np.complex64);hr=np.ascontiguousarray(h.real);hi=np.ascontiguousarray(h.imag)
 prepare_ms=(time.perf_counter()-t)*1000
 x=np.linspace(-1.1,1.1,221);y=np.linspace(9.65,10.35,101);xx,yy=np.meshgrid(x,y)
 qx=np.ascontiguousarray(xx.ravel());qy=np.ascontiguousarray(yy.ravel());dr=3e8/(2*nfft*df)
 outputs={};timings={}
 for name in ['bp_scalar','bp_rvv']:
  real=np.empty(len(qx));imag=np.empty(len(qx));fn=getattr(lib,name)
  # Warm-up a small output slice, then time complete BP calls.
  fn(qx[:32].copy(),qy[:32].copy(),32,apx,nm,hr,hi,nfft,dr,fref,np.empty(32),np.empty(32),a.threads)
  times=[]
  for _ in range(a.repeat):
   t=time.perf_counter();fn(qx,qy,len(qx),apx,nm,hr,hi,nfft,dr,fref,real,imag,a.threads);times.append((time.perf_counter()-t)*1000)
  z=(real+1j*imag).reshape(xx.shape);outputs[name]=z;timings[name]=times
  db=20*np.log10(np.maximum(np.abs(z)/np.abs(z).max(),1e-8));picture=np.uint8(np.clip((db+40)/40,0,1)*255)
  Image.fromarray(picture[::-1]).save(a.output/(name+'.png'))
  print(name,round(float(np.median(times)),2),'ms',flush=True)
 z=outputs['bp_rvv'];peaks=[]
 for px,py in points:
  m=(abs(xx-px)<.15)&(abs(yy-py)<.12);iy,ix=np.unravel_index(np.argmax(np.where(m,abs(z),-1)),z.shape)
  peaks.append({'input_xy_m':[float(px),float(py)],'peak_xy_m':[float(x[ix]),float(y[iy])],'error_m':float(np.hypot(x[ix]-px,y[iy]-py))})
 delta=float(np.max(np.abs(z-outputs['bp_scalar'])));relative=delta/max(float(np.max(np.abs(outputs['bp_scalar']))),1e-12)
 result={'kind':'synthetic_complex_echo_BP','chirps':nm,'PRF_Hz':10000,'speed_m_s':3,'output_shape':list(xx.shape),'rvv_bits':lib.rvv_bits(),'threads':a.threads,
         'prepare_echo_and_compress_ms':prepare_ms,'bp_times_ms':timings,'scalar_median_ms':float(np.median(timings['bp_scalar'])),'rvv_median_ms':float(np.median(timings['bp_rvv'])),
         'speedup':float(np.median(timings['bp_scalar'])/np.median(timings['bp_rvv'])),'max_complex_absolute_difference':delta,'max_complex_relative_difference':relative,'peaks':peaks,
         'scope':'RVV range calculation and complex accumulation; scalar trigonometry and indexing; timings cover BP only'}
 result['check']='PASS' if np.isfinite(z).all() and relative<1e-7 and all(v['error_m']<.04 for v in peaks) else 'FAIL'
 np.savez_compressed(a.output/'bp_complex.npz',scalar=outputs['bp_scalar'],rvv=z,x=x,y=y,points=points)
 (a.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8');print(json.dumps(result,ensure_ascii=False),flush=True)
 if result['check']!='PASS':raise RuntimeError('BP check failed')
if __name__=='__main__':main()
