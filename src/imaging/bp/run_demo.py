"""A small, standalone complex echo to BP imaging demonstration."""
from pathlib import Path
import argparse, json, time
import numpy as np
from PIL import Image
from bp_core import synthesize, compress, backproject, C, NFFT

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',type=Path,default=Path('runs/bp_demo'))
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    points=np.array([[-.6,10.],[0.,10.],[.6,10.]])
    coeff=np.ones(3,dtype=np.complex128)
    nr=256;df=3e9/nr;first=77e9;fref=first+(nr-1)*df/2
    n=1000;apx=(np.arange(n)-(n-1)/2)*3/10000
    x=np.linspace(-1.1,1.1,221);y=np.linspace(9.65,10.35,101)
    xx,yy=np.meshgrid(x,y);q=np.column_stack([xx.ravel(),yy.ravel()])
    started=time.perf_counter()
    echo=synthesize(points,coeff,apx,first,df,nr)
    h=compress(echo,nr);drange=C/(2*NFFT*df)
    z=backproject(q,apx,h,drange,fref).reshape(len(y),len(x))
    db=20*np.log10(np.maximum(np.abs(z)/np.abs(z).max(),1e-8))
    image=np.uint8(np.clip((db+40)/40,0,1)*255)
    Image.fromarray(image[::-1]).save(args.output/'bp_image.png')
    np.savez_compressed(args.output/'bp_complex.npz',z=z,x=x,y=y,points=points)
    # Verify the strongest response within each target's local neighborhood.
    peaks=[]
    for px,py in points:
        m=(np.abs(xx-px)<.15)&(np.abs(yy-py)<.12)
        idx=np.argmax(np.where(m,np.abs(z),-1));iy,ix=np.unravel_index(idx,z.shape)
        peaks.append({'input_xy_m':[float(px),float(py)],'peak_xy_m':[float(x[ix]),float(y[iy])],
                      'error_m':float(np.hypot(x[ix]-px,y[iy]-py))})
    result={'mode':'synthetic_complex_echo_BP','chirps':n,'PRF_Hz':10000,'speed_m_s':3,
            'output_shape':list(z.shape),'peaks':peaks,'elapsed_s':time.perf_counter()-started,
            'finite':bool(np.isfinite(z).all())}
    (args.output/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
    print(json.dumps(result,ensure_ascii=False))
    if not result['finite'] or any(p['error_m']>.04 for p in peaks):raise RuntimeError('BP focus verification failed')

if __name__=='__main__':main()
