"""Controlled broadside FMCW-equivalent echo: RDA with RCMC versus spherical BP.

RDA uses the stationary-phase narrow-relative-bandwidth approximation.
Both algorithms use identical complex echoes and the same final image grid.
No real-data trajectory is invented by this experiment.
"""
from pathlib import Path
import argparse,ctypes,json,time,platform
import numpy as np
from PIL import Image
from fft_backend import fft,ifft,NAME as FFT_NAME,THREADS as FFT_THREADS
C=3e8

def synthesize(points,apx,first,df,nr):
 f=first+df*np.arange(nr);echo=np.zeros((len(apx),nr),np.complex128)
 for px,py in points:
  r=np.hypot(apx-px,py)
  echo+=np.exp(-1j*4*np.pi/C*r[:,None]*f[None,:])
 return echo.astype(np.complex64)

def compress(echo,nfft):
 nr=echo.shape[1];z=ifft(echo,n=nfft,axis=1)*(nfft/nr)
 z*=np.exp(-1j*2*np.pi*(nr-1)/2*np.arange(nfft)/nfft)[None,:]
 return np.ascontiguousarray(z.astype(np.complex64))

def make_rda_plan(nm,naz,nfft,dr,dx,fc,x,y):
 # Keep a range strip sufficient for RCMC over the physically propagating spectrum.
 fx=np.fft.fftfreq(naz,d=dx);ratio=(C/fc)*fx/2
 # The scene/antenna is broadside; preserve Doppler up to 3x the aperture/ROI extent.
 fmax=(max(abs(x.min()),abs(x.max()))+nm*dx/2)/y.min()*2*fc/C
 valid=(abs(ratio)<.95)&(abs(fx)<fmax*1.5)
 d=np.sqrt(np.maximum(1-ratio*ratio,1e-12))
 indices=np.flatnonzero(valid);dv=d[indices]
 start=max(0,int(np.floor(y.min()/dr))-4);stop=min(nfft,int(np.ceil(y.max()/dv.min()/dr))+6)
 ranges=np.arange(start,stop)*dr
 # h_RD(fx, r=R0/D) is resampled to ground broadside range R0.
 target=y[None,:]/dv[:,None]/dr-start
 lower=np.floor(target).astype(np.int32);fraction=(target-lower).astype(np.float32)
 mask=(lower>=0)&(lower+1<len(ranges));lower=np.clip(lower,0,len(ranges)-2)
 phase=np.exp(1j*4*np.pi*fc/C*dv[:,None]*y[None,:]).astype(np.complex64)
 x_native=(np.arange(naz)-naz//2)*dx
 ix=np.floor((x-x_native[0])/dx).astype(int);wx=((x-x_native[0])/dx-ix).astype(np.float32)
 ix=np.clip(ix,0,naz-2)
 return {'indices':indices,'start':start,'stop':stop,'lower':lower,'fraction':fraction,'mask':mask,'phase':phase,'ix':ix,'wx':wx,'naz':naz,'nm':nm,'metadata':{'azimuth_fft':naz,'range_strip_bins':stop-start,'used_doppler_bins':len(indices),'RCMC':'linear interpolation at r=R0/D','azimuth_filter':'exp(+j4pi fc R0 D/c)','doppler_support_cycles_per_m':float(fmax*1.5)}}

def rda_from_compressed(h,plan):
 strip=h[:,plan['start']:plan['stop']];naz=plan['naz'];nm=plan['nm']
 padded=np.zeros((naz,strip.shape[1]),np.complex64);offset=naz//2-nm//2;padded[offset:offset+nm]=strip
 spectrum=fft(np.fft.ifftshift(padded,axes=0),axis=0)
 selected=spectrum[plan['indices']];rows=np.arange(len(selected))[:,None];j=plan['lower'];w=plan['fraction']
 corrected=(selected[rows,j]*(1-w)+selected[rows,j+1]*w)*plan['phase']*plan['mask']
 filtered=np.zeros((naz,corrected.shape[1]),np.complex64);filtered[plan['indices']]=corrected
 focused=np.fft.fftshift(ifft(filtered,axis=0),axes=0)
 ix=plan['ix'];wx=plan['wx'][:,None]
 return ((1-wx)*focused[ix]+wx*focused[ix+1]).T

def bp_reference(h,qx,qy,apx,dr,fc,libpath,threads):
 lib=ctypes.CDLL(str(libpath));fn=lib.bp_rvv
 pd=np.ctypeslib.ndpointer(dtype=np.float64,flags='C_CONTIGUOUS');pf=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS')
 fn.argtypes=[pd,pd,ctypes.c_int,pd,ctypes.c_int,pf,pf,ctypes.c_int,ctypes.c_double,ctypes.c_double,pd,pd,ctypes.c_int];fn.restype=None
 hr=np.ascontiguousarray(h.real);hi=np.ascontiguousarray(h.imag);re=np.empty(len(qx));im=np.empty(len(qx))
 def run():fn(qx,qy,len(qx),apx,len(apx),hr,hi,h.shape[1],dr,fc,re,im,threads);return re+1j*im
 return run

def metrics(z,x,y,points):
 xx,yy=np.meshgrid(x,y);power=abs(z)**2;results=[]
 for px,py in points:
  mask=(abs(xx-px)<.10)&(abs(yy-py)<.10);iy,ix=np.unravel_index(np.argmax(np.where(mask,power,-1)),power.shape)
  cut=power[iy,:];peak=cut[ix];support=cut>=peak*.5;left=ix;right=ix
  while left>0 and support[left-1]:left-=1
  while right<len(x)-1 and support[right+1]:right+=1
  results.append({'input_xy_m':[float(px),float(py)],'peak_xy_m':[float(x[ix]),float(y[iy])],'error_m':float(np.hypot(x[ix]-px,y[iy]-py)),'azimuth_fwhm_grid_m':float(x[right]-x[left])})
 return results

def save_image(z,p):
 db=20*np.log10(np.maximum(abs(z)/max(float(abs(z).max()),1e-12),1e-8));Image.fromarray(np.uint8(np.clip((db+40)/40,0,1)*255)[::-1]).save(p)

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--lib',type=Path);p.add_argument('--threads',type=int,default=4);p.add_argument('--repeat',type=int,default=3);p.add_argument('--range-fft',type=int,default=2048);p.add_argument('--scenario',choices=['narrow','original'],default='narrow');a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 nm=1000;nr=256;nfft=a.range_fft;naz=2048 if a.scenario=='narrow' else 8192;prf=10000;speed=3;dx=speed/prf;df=3e9/nr;first=77e9;fc=first+(nr-1)*df/2;dr=C/(2*nfft*df)
 apx=np.ascontiguousarray((np.arange(nm)-nm//2)*dx)
 points=np.array([[-.08,9.8],[0,10],[.08,10.2]])
 x=np.linspace(-.14,.14,141);y=np.linspace(9.6,10.4,161)
 if a.scenario=='original':points=np.array([[-.6,10.],[0.,10.],[.6,10.]]);x=np.linspace(-1.1,1.1,221);y=np.linspace(9.65,10.35,101)
 xx,yy=np.meshgrid(x,y);qx=np.ascontiguousarray(xx.ravel());qy=np.ascontiguousarray(yy.ravel())
 t=time.perf_counter();echo=synthesize(points,apx,first,df,nr);synth_ms=(time.perf_counter()-t)*1000
 compress_times=[]
 for _ in range(a.repeat):t=time.perf_counter();h=compress(echo,nfft);compress_times.append((time.perf_counter()-t)*1000)
 t=time.perf_counter();plan=make_rda_plan(nm,naz,nfft,dr,dx,fc,x,y);plan_ms=(time.perf_counter()-t)*1000
 _=rda_from_compressed(h,plan);times=[]
 for _ in range(a.repeat):t=time.perf_counter();rda=rda_from_compressed(h,plan);times.append((time.perf_counter()-t)*1000)
 # RD visualization has Doppler on one axis, not the RDA spatial output.
 rd=np.fft.fftshift(np.fft.fft(h[:,plan['start']:plan['stop']],axis=0),axes=0).T
 save_image(rda,a.output/'rda.png');save_image(rd,a.output/'range_doppler.png')
 rm=metrics(rda,x,y,points)
 result={'mode':'broadside_synthetic_SAR_RDA','scenario':a.scenario,'machine':platform.machine(),'range_fft':nfft,'input_shape':[nm,nr],'output_shape':list(rda.shape),'PRF_Hz':prf,'speed_m_s':speed,'frequency_reference_hz':fc,'range_compression_ms':compress_times,'synthesis_ms':synth_ms,'RDA_plan_ms':plan_ms,'RDA_ms':times,'RDA_median_ms':float(np.median(times)),'RDA_peaks':rm,'plan':plan['metadata'],'normalization':'Each visualization normalized to own maximum; retained complex outputs support numerical inspection','scope':'Stationary-phase RDA with range-cell migration correction, broadside angular scene, identical input and final grid as BP'}
 result['fft_backend']=FFT_NAME;result['fft_threads_requested']=FFT_THREADS
 arrays={'rda':rda,'x':x,'y':y,'points':points}
 if a.lib:
  fn=bp_reference(h,qx,qy,apx,dr,fc,a.lib,a.threads);bt=[]
  for _ in range(a.repeat):t=time.perf_counter();bp=fn().reshape(xx.shape);bt.append((time.perf_counter()-t)*1000)
  result.update({'BP_ms':bt,'BP_median_ms':float(np.median(bt)),'BP_peaks':metrics(bp,x,y,points),'BP_over_RDA_speedup':float(np.median(bt)/np.median(times)),'BP_threads':a.threads})
  arrays['bp']=bp;save_image(bp,a.output/'bp.png')
  result['RDA_peak_to_BP_max_difference_m']=max(float(np.linalg.norm(np.array(b['peak_xy_m'])-np.array(r['peak_xy_m']))) for b,r in zip(result['BP_peaks'],rm))
  result['normalized_magnitude_correlation']=float(np.corrcoef(abs(bp).ravel(),abs(rda).ravel())[0,1])
 np.savez_compressed(a.output/'complex_results.npz',**arrays)
 result['focus_check']='PASS' if all(r['error_m']<=.04 for r in rm) else 'FAIL'
 (a.output/'result.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result),flush=True)
 if result['focus_check']!='PASS':raise RuntimeError('RDA focus check failed')

if __name__=='__main__':main()
