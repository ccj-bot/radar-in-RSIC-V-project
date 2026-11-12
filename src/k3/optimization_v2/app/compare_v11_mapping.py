"""Floating point algorithm-level v1.1 FFT/magnitude/mapping reference, not RTL simulation."""
from pathlib import Path
import argparse,time,json
import numpy as np
from compare_rda_bp import synthesize,compress,make_rda_plan,rda_from_compressed,bp_reference,metrics,save_image,C

def main():
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--lib',type=Path,required=True);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 nm=512;nr=1024;prf=10000;speed=3.;dx=speed/prf;fc=76e9;bandwidth=3e9;df=bandwidth/nr;first=fc-(nr-1)*df/2;nfft=1024
 apx=np.ascontiguousarray((np.arange(nm)-nm//2)*dx);points=np.array([[-.6,10],[0,10],[.6,10]])
 x=np.linspace(-1.1,1.1,221);y=np.linspace(9.65,10.35,101);xx,yy=np.meshgrid(x,y);qx=np.ascontiguousarray(xx.ravel());qy=np.ascontiguousarray(yy.ravel());dr=C/(2*nfft*df)
 echo=synthesize(points,apx,first,df,nr);h=compress(echo,nfft)
 ranges=np.hypot(xx,yy);sin_theta=xx/ranges
 # Echo sign is exp(-j4pi fR/c): azimuth peak spatial frequency +2 sin(theta)/lambda.
 az_index=nm/2+sin_theta*(nm*2*speed)/(prf*(C/fc));range_index=ranges/dr
 j=np.floor(az_index).astype(int);k=np.floor(range_index).astype(int);wa=az_index-j;wr=range_index-k
 valid=(j>=0)&(j+1<nm)&(k>=0)&(k+1<nfft);j=np.clip(j,0,nm-2);k=np.clip(k,0,nfft-2)
 def mapped():
  magnitude=abs(np.fft.fftshift(np.fft.fft(h,axis=0),axes=0))
  return ((1-wa)*(1-wr)*magnitude[j,k]+(1-wa)*wr*magnitude[j,k+1]+wa*(1-wr)*magnitude[j+1,k]+wa*wr*magnitude[j+1,k+1])*valid
 times=[]
 for _ in range(3):t=time.perf_counter();image=mapped();times.append((time.perf_counter()-t)*1000)
 fn=bp_reference(h,qx,qy,apx,dr,fc,a.lib,4);t=time.perf_counter();bp=fn().reshape(xx.shape);bp_ms=(time.perf_counter()-t)*1000
 plan=make_rda_plan(nm,8192,nfft,dr,dx,fc,x,y);rda=rda_from_compressed(h,plan)
 result={'reference':'v1.1 algorithm-level float reference; not bit-accurate RTL','input':[nm,nr],'frequency_hz':fc,'PRF_Hz':prf,'speed_m_s':speed,'mapping_formula':'q=NA/2+sin(theta)*NA*2V/(PRF*lambda)','v11_fft_remap_ms':times,'bp_ms':bp_ms,'v11_peaks':metrics(image,x,y,points),'bp_peaks':metrics(bp,x,y,points),'rda_peaks':metrics(rda,x,y,points),'normalized_magnitude_correlation_v11_bp':float(np.corrcoef(abs(bp).ravel(),image.ravel())[0,1]),'scope':'Matches geometric mapping and magnitude-before-interpolation structure; excludes RTL fixed-point scaling, approximate multipliers, masks and gamma. Actual bitstream not built or executed.'}
 np.savez_compressed(a.output/'comparison.npz',v11=image,bp=bp,rda=rda,x=x,y=y,points=points)
 for n,z in [('v11',image),('bp',bp),('rda',rda)]:save_image(z,a.output/(n+'.png'))
 (a.output/'result.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
if __name__=='__main__':main()
