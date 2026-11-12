"""Fixed world vehicle, one continuous echo stream, time-windowed spherical BP.

Run with py311. Synthetic calibrated FMCW-equivalent frequency data; no GT or
optical input. GM is read only for an independent visual reference panel.
"""
from pathlib import Path
import argparse
import json
import math
import os
import time

import numpy as np
import pandas as pd
import numba
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import Normalize
from matplotlib.cm import ScalarMappable
from PIL import Image, ImageDraw, ImageFont
import cv2

from render_bp_full_sar_scene_20261105 import synthesize
from render_bp_2d_simulation_20261105 import backproject, direct_kernel, C, NFFT
from audit_nx_imaging_parameters_20261105 import dump, sha

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / 'docs/sar_research/BP_PARAMETER_BASELINE_20261105.json'
SCENARIOS = ROOT / 'docs/sar_research/BP_CONTINUOUS_50HZ_SCENARIOS_20261105.json'
GM = ROOT.parent / 'data/GM_RM019/GM_RM019_SARframes_gray/000269.png'
SEED = 20261105
VMIN, VMAX = -40., 5.
Q = np.array([[np.cos(np.pi/6), -np.sin(np.pi/6)],
              [np.sin(np.pi/6), np.cos(np.pi/6)]])
CAR_D = np.array([0., 10.])
CAR_W = CAR_D @ Q.T
KEYS = [0, 30, 60, 90, 120, 150]
COMPARE = [0, 75, 150]
FONT = 'C:/Windows/Fonts/msyh.ttc'


def power_db(z):
    return 10*np.log10(np.maximum(np.abs(z)**2, 1e-14))


def render_rgb(z, cmap='magma'):
    a = np.clip((power_db(z)-VMIN)/(VMAX-VMIN), 0, 1)
    return np.round(plt.get_cmap(cmap)(a)[..., :3]*255).astype('uint8')


def grid(x, y):
    xx, yy = np.meshgrid(x, y)
    return np.column_stack([xx.ravel(), yy.ravel()])


def scene():
    rng = np.random.default_rng(SEED)
    records = []
    def add(d, a, phase, kind):
        records.append([*d, a, phase, kind])
    yaw = np.deg2rad(12)
    rot = np.array([[np.cos(yaw), -np.sin(yaw)], [np.sin(yaw), np.cos(yaw)]])
    # Same physical scatterers, phases, orientation for the ENTIRE sequence.
    for x in [-.9, .9]:
        for y in [-2.1, 2.1]:
            add(CAR_D + np.array([x, y]) @ rot.T, rng.uniform(.9, 1.4),
                rng.uniform(-np.pi, np.pi), 'car_corner')
        for y in np.linspace(-1.85, 1.85, 22):
            add(CAR_D + np.array([x, y]) @ rot.T, rng.uniform(.14, .27),
                rng.uniform(-np.pi, np.pi), 'car_edge')
    for y in [-2.1, 2.1]:
        for x in [-.45, 0., .45]:
            add(CAR_D + np.array([x, y]) @ rot.T, .23,
                rng.uniform(-np.pi, np.pi), 'car_edge')
    # Sparse, fixed coherent surroundings. All take part in echo synthesis.
    for side in [-1, 1]:
        for y in np.linspace(2., 28., 90):
            add(np.array([side*5.5, y]), rng.uniform(.04, .10),
                rng.uniform(-np.pi, np.pi), 'road')
    for _ in range(140):
        d = np.array([rng.uniform(-12, 12), rng.uniform(2, 29)])
        if np.linalg.norm(d-CAR_D) < 4.2:
            continue
        add(d, .018*rng.rayleigh(), rng.uniform(-np.pi, np.pi), 'ground')
    df = pd.DataFrame(records, columns=['x_display_world_m', 'y_display_world_m',
                                      'amplitude', 'phase_rad', 'kind'])
    p = df.iloc[:, :2].to_numpy() @ Q.T
    df['x_reference_world_m'], df['y_reference_world_m'] = p[:, 0], p[:, 1]
    outline = CAR_D + np.array([[-.9,-2.1], [.9,-2.1], [.9,2.1], [-.9,2.1], [-.9,-2.1]]) @ rot.T
    return df, p, df.amplitude.to_numpy()*np.exp(1j*df.phase_rad.to_numpy()), outline


def compress(echo, retained):
    z = np.fft.ifft(echo, n=NFFT, axis=1)*(NFFT/retained)
    z *= np.exp(-1j*2*np.pi*(echo.shape[1]-1)/2*np.arange(NFFT)/NFFT)[None, :]
    return np.ascontiguousarray(z.astype(np.complex64))


def image(ax, z, x, y, title, cmap='magma'):
    dx, dy = x[1]-x[0], y[1]-y[0]
    im = ax.imshow(power_db(z), origin='lower', cmap=cmap, vmin=VMIN, vmax=VMAX,
                   extent=[x[0]-dx/2, x[-1]+dx/2, y[0]-dy/2, y[-1]+dy/2],
                   interpolation='nearest', aspect='equal', rasterized=True)
    ax.set_title(title, fontsize=11, loc='left', pad=9)
    ax.set_xlabel('横向 / m')
    ax.set_ylabel('前向 / m')
    ax.tick_params(labelsize=9, length=3, color='#75808c')
    return im


def save(fig, out, name, vector=True):
    fig.savefig(out/f'{name}.png', dpi=190, facecolor=fig.get_facecolor())
    if vector:
        fig.savefig(out/f'{name}.svg', facecolor=fig.get_facecolor())
    plt.close(fig)


def colorbar_assets(out):
    for cmap in ['gray', 'magma']:
        for orient in ['vertical', 'horizontal']:
            fig = plt.figure(figsize=(1.65, 5.) if orient=='vertical' else (6., 1.25))
            ax = fig.add_axes([.12, .08, .23, .85] if orient=='vertical' else [.06,.57,.88,.23])
            cb = fig.colorbar(ScalarMappable(norm=Normalize(VMIN, VMAX), cmap=cmap),
                              cax=ax, orientation=orient, ticks=[-40,-30,-20,-10,0,5])
            cb.set_label('归一化 BP 功率 / dB', fontsize=10)
            cb.ax.tick_params(labelsize=9)
            cb.outline.set_linewidth(.6)
            for ext in ['png', 'svg']:
                fig.savefig(out/f'colorbar_{cmap}_{orient}.{ext}', dpi=240, transparent=True)
            plt.close(fig)
    lut = {c: np.round(plt.get_cmap(c)(np.linspace(0,1,256))[:, :3]*255).astype(int).tolist()
           for c in ['gray', 'magma']}
    dump(out/'colorbar_mapping.json', dict(formula='10*log10(abs(z)^2 / 1)',
         reference='Unit isolated scatterer, normalized coherent BP amplitude 1',
         vmin_db=VMIN, vmax_db=VMAX, clipping=True, lut_rgb_256=lut))


def width(offset, z):
    p = abs(z)**2
    peak = np.argmax(p)
    half = p[peak]*.5
    left = np.flatnonzero(p[:peak] < half)
    right = np.flatnonzero(p[peak+1:] < half)
    if not len(left) or not len(right):
        return float('nan')
    l, r = left[-1], peak+1+right[0]
    xl = offset[l] + (half-p[l])/(p[l+1]-p[l])*(offset[l+1]-offset[l])
    xr = offset[r-1] + (half-p[r-1])/(p[r]-p[r-1])*(offset[r]-offset[r-1])
    return float(xr-xl)


def geometry_figure(out, table, measures, psfmaps, px, py):
    fig,axes=plt.subplots(2,3,figsize=(14.5,9.4),layout='constrained')
    fig.suptitle('几何与独立点响应：解释时序变化',fontsize=18,fontweight='bold')
    ax=axes[0,0]
    track=np.column_stack([[-8.,1.],[0.,0.]])@Q
    ax.plot(track[:,0],track[:,1],color='#3274a1',lw=2,label='雷达轨迹：3 m/s')
    car=table[table.kind.str.startswith('car')]
    ax.scatter(car.x_display_world_m,car.y_display_world_m,s=11,c='#b45124',label='固定车辆散射点')
    for k in COMPARE:
        d=np.array([-8+3*k*.02,0.])@Q
        ax.plot(*d,'^',color='#3274a1',ms=7)
        ax.plot([d[0],CAR_D[0]],[d[1],CAR_D[1]],'--',color='#a6b1bc',lw=.7)
        ax.annotate(f'{k*.02:.1f} s',d,xytext=(4,-16) if k==0 else (-8,-16),
                    textcoords='offset points',fontsize=9)
    ax.set(xlabel='世界横向 / m',ylabel='世界前向 / m',title='(a) 车与散射系数全程固定')
    ax.set_aspect('equal'); ax.legend(frameon=False,fontsize=8,loc='upper left'); ax.grid(alpha=.14)
    colors=['#bd6b28','#2d7994','#704e98']
    for ax,column,title in zip(axes[0,1:],['radial_fwhm_cm','tangential_fwhm_cm'],['(b) 径向半功率全宽','(c) 切向半功率全宽']):
        for n,color,ls in zip([200,1000,2000],colors,['-','--',':']):
            d=measures[measures.chirps==n]
            ax.plot(d.time_s,d[column],color=color,lw=1.7,ls=ls,label=f'{n} chirp')
        ax.set(xlabel='窗口中心时间 / s',ylabel='孤立点 FWHM / cm',title=title,xlim=(0,3),
               ylim=(0,5) if column=='radial_fwhm_cm' else (0,40))
        ax.grid(alpha=.17); ax.legend(frameon=False,fontsize=8,loc='upper left')
    axes[0,1].text(.06,.66,'约 4.05 cm\n三种孔径的曲线基本重合',transform=axes[0,1].transAxes,
                    fontsize=10,color='#495a69',va='top')
    for ax,k in zip(axes[1],COMPARE):
        im=image(ax,psfmaps[k],px*100,py*100,f'孤立单位点 · 1000 chirp · t = {k*.02:.1f} s')
        ax.set_xlabel('横向偏移 / cm'); ax.set_ylabel('前向偏移 / cm')
    fig.colorbar(im,ax=axes[1].tolist(),shrink=.8,pad=.02,label='归一化 BP 功率 / dB')
    fig.supxlabel('曲线由完整离散频率匹配核测量；下排由独立点回波经距离压缩与 BP 得到',fontsize=10)
    save(fig,out,'04_geometry_and_point_response')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--restyle-points', action='store_true', help='Only redraw the existing point/geometry figure from saved numerical data')
    args = parser.parse_args()
    out = args.out.resolve()
    if not out.is_relative_to(ROOT/'outputs'):
        raise ValueError('Output must be in this worktree outputs')
    if args.restyle_points:
        plt.rcParams.update({'font.sans-serif':['Microsoft YaHei','DejaVu Sans'],
                             'axes.unicode_minus':False,'font.size':10,
                             'axes.spines.top':False,'axes.spines.right':False,
                             'figure.facecolor':'#fafbfd','svg.fonttype':'none'})
        table=pd.read_csv(out/'stationary_scene_scatterers.csv')
        measures=pd.read_csv(out/'isolated_point_fwhm.csv')
        p=np.load(out/'isolated_point_complex_controls.npz')
        geometry_figure(out,table,measures,dict(zip(COMPARE,p['z'])),p['x_offset_display_m'],p['y_offset_display_m'])
        print('Restyled point figure from saved numerical arrays only',flush=True)
        return
    out.mkdir(parents=True, exist_ok=False)
    (out/'clean_keyframes').mkdir()
    numba.set_num_threads(min(8, os.cpu_count() or 1))
    plt.rcParams.update({'font.sans-serif':['Microsoft YaHei','DejaVu Sans'],
                         'axes.unicode_minus':False, 'font.size':10,
                         'axes.spines.top':False, 'axes.spines.right':False,
                         'figure.facecolor':'#fafbfd', 'axes.titleweight':'medium',
                         'svg.fonttype':'none'})
    b = json.loads(BASELINE.read_text(encoding='utf-8'))
    s = json.loads(SCENARIOS.read_text(encoding='utf-8'))
    assert b['prf_hz']==s['prf_hz']==10000 and s['step_chirps']==200
    assert b['simulation_trajectory']['speed_mps']==3
    wave=b['waveform']; nr=wave['adc_samples']; retained=nr-100
    freq=wave['start_frequency_hz']+wave['slope_hz_per_s']*(wave['adc_start_s']+np.arange(nr)/wave['adc_sample_rate_hz'])
    df=wave['slope_hz_per_s']/wave['adc_sample_rate_hz']
    fref=float((freq[0]+freq[-1])/2); drange=C/(2*NFFT*df)
    total=32000
    times=(np.arange(total)-999.5)/10000.
    apx=-8.+3.*times  # One GLOBAL trajectory, never recentered per image.
    table, points, coeff, outline = scene()
    table.to_csv(out/'stationary_scene_scatterers.csv', index=False)
    sourcepaths=[Path(__file__),BASELINE,SCENARIOS,GM,
                 Path(__file__).with_name('render_bp_2d_simulation_20261105.py'),
                 Path(__file__).with_name('render_bp_full_sar_scene_20261105.py')]
    hashes={str(p):sha(p) for p in sourcepaths}
    protocol=dict(model='Fixed world point scatterers, stop-go calibrated FMCW equivalent frequency echo',
         prf_hz=10000, speed_mps=3., step_chirps=200, apertures=[200,1000,2000],
         primary_aperture=1000, images=151, center_times_s=[0.,3.],
         global_chirp_count=total, global_chirp_time_origin_index=999.5,
         platform_reference_x='-8 + 3*time_s', platform_reference_y=0.,
         car_center_display_world_m=CAR_D.tolist(), car_center_reference_world_m=CAR_W.tolist(),
         car_size_m=[1.8,4.2], car_yaw_display_deg=12, seed=SEED,
         display_to_reference_rotation=Q.tolist(),
         local_animation_grid_m=.04, local_keyframe_grid_m=.02, overview_grid_m=.08,
         gray_limits_db=[VMIN,VMAX], reference='Isolated unit scatterer power = 0 dB; same limits for every BP image',
         frequency_reference_hz=fref, range_interpolation_m=drange,
         effective_frequency_count=retained, source_hashes=hashes,
         limitations=['Fixed point coefficients; no car CAD/EM, visibility/occlusion or multipath',
                      'No noise, beam taper, range attenuation or motion error',
                      'Display fan mask only; it is not an antenna beam model',
                      '50Hz denotes sampling/window cadence, not measured real-time throughput',
                      'Straight-track mirror ambiguity is retained; plotted fan is a selected half-space',
                      'GM is only a read-only independent display reference, not a simulation input'])
    dump(out/'protocol.json',protocol)
    started=time.perf_counter()
    print('Synthesis:',len(points),'fixed scatterers;',total,'unique continuous chirps',flush=True)
    echo=np.lib.format.open_memmap(out/'continuous_frequency_echo.npy',mode='w+',dtype=np.complex64,shape=(total,nr))
    for start in range(0,total,1000):
        z=synthesize(points,coeff,apx[start:start+1000],float(freq[0]),float(df),nr)
        z[:,:100]=0
        echo[start:start+len(z)]=z.astype(np.complex64)
        if start%5000==0:
            print('echo',start+1000,'/',total,'elapsed',round(time.perf_counter()-started,1),flush=True)
    echo.flush()
    np.savez_compressed(out/'continuous_trajectory_and_frequency.npz',time_s=times,radar_reference_x_m=apx,frequency_hz=freq)
    forward_error=[]
    for m,n in [(0,100),(1000,1023),(15999,511),(31999,900)]:
        r=np.sqrt((points[:,0]-apx[m])**2+points[:,1]**2)
        exact=np.sum(coeff*np.exp(-1j*4*np.pi*freq[n]*r/C))
        forward_error.append(float(abs(exact-echo[m,n])))
    # Native samples: no cosmetic blur/interpolation is applied to the data.
    xc=np.arange(-80,81)*.04; yc=np.arange(-85,86)*.04
    xf=np.arange(-160,161)*.02; yf=np.arange(-170,171)*.02
    qc=(grid(xc,yc)+CAR_D)@Q.T
    qf=(grid(xf,yf)+CAR_D)@Q.T
    local=np.empty((151,len(yc),len(xc)),dtype=np.complex64)
    keymaps={}; compare={}; overview={}; windows=[]; displaystats=[]
    ring=compress(echo[:2000],retained)
    rx=np.arange(-432,433)*.08; ry=np.arange(501)*.08
    rq=grid(rx,ry)
    mask=(np.linalg.norm(rq,axis=1)<=40)&(np.abs(np.arctan2(rq[:,0],rq[:,1]))<=np.pi/3)&(rq[:,1]>.1)
    for k in range(151):
        if k:
            begin=2000+(k-1)*200
            new=compress(echo[begin:begin+200],retained)
            ring=np.concatenate([ring[200:],new],axis=0)
        pos=apx[k*200:k*200+2000]
        local[k]=backproject(qc,pos[500:1500],ring[500:1500],drange,fref).reshape(len(yc),len(xc))
        center_time=k*.02; center_x=-8+3*center_time
        car_relative=(CAR_W-np.array([center_x,0]))@Q
        rng=float(np.linalg.norm(car_relative))
        bearing=float(np.degrees(np.arctan2(car_relative[0],car_relative[1])))
        windows.append(dict(frame=k,time_s=center_time,radar_x_reference_m=center_x,
            range_to_car_center_m=rng,car_bearing_display_deg=bearing,
            first_chirp=k*200+500,last_chirp=k*200+1499,
            first_time_s=float(times[k*200+500]),last_time_s=float(times[k*200+1499]),
            car_world_x_m=float(CAR_W[0]),car_world_y_m=float(CAR_W[1])))
        if k in set(KEYS+COMPARE):
            fine=backproject(qf,pos[500:1500],ring[500:1500],drange,fref).reshape(len(yf),len(xf))
            keymaps[k]=fine
            for cmap in ['gray','magma']:
                rgb=render_rgb(fine,cmap)[::-1]
                Image.fromarray(rgb).save(out/'clean_keyframes'/f'world_car_t{center_time:04.2f}s_{cmap}.png')
            np.savez_compressed(out/'clean_keyframes'/f'world_car_t{center_time:04.2f}s_complex.npz',
                z=fine.astype(np.complex64),x_offset_m=xf,y_offset_m=yf,time_s=center_time,
                car_center_display_world_m=CAR_D)
        if k in COMPARE:
            for n in [200,1000,2000]:
                lo=(2000-n)//2
                if n==1000:
                    compare[k,n]=keymaps[k]
                else:
                    compare[k,n]=backproject(qf,pos[lo:lo+n],ring[lo:lo+n],drange,fref).reshape(len(yf),len(xf))
            z=np.zeros(len(rq),dtype=np.complex64)
            world=rq[mask]@Q.T+np.array([center_x,0.])
            z[mask]=backproject(world,pos[500:1500],ring[500:1500],drange,fref)
            overview[k]=z.reshape(len(ry),len(rx))
            for cmap in ['gray','magma']:
                rgb=render_rgb(overview[k],cmap)[::-1]
                rgb[~mask.reshape(len(ry),len(rx))[::-1]]=0
                Image.fromarray(rgb).save(out/'clean_keyframes'/f'radar_view_t{center_time:04.2f}s_{cmap}.png')
            np.savez_compressed(out/'clean_keyframes'/f'radar_view_t{center_time:04.2f}s_complex.npz',
                z=overview[k],fan_mask=mask.reshape(len(ry),len(rx)),x_radar_display_m=rx,y_radar_display_m=ry)
            if k==75:
                frozen=backproject(qf,np.full(1000,center_x),ring[500:1500],drange,fref).reshape(len(yf),len(xf))
        if k%10==0:
            print('BP frame',k,'/150 elapsed',round(time.perf_counter()-started,1),flush=True)
    frames=pd.DataFrame(windows); frames.to_csv(out/'window_geometry.csv',index=False)
    np.savez_compressed(out/'temporal_vehicle_complex.npz',z=local,x_offset_m=xc,y_offset_m=yc,
                        time_s=frames.time_s.to_numpy(),car_center_display_world_m=CAR_D)
    for k,n in compare:
        z=compare[k,n]; d=power_db(z)
        displaystats.append(dict(time_s=k*.02,chirps=n,min_db=float(d.min()),max_db=float(d.max()),
                        clipped_above_fraction=float(np.mean(d>VMAX)),below_floor_fraction=float(np.mean(d<VMIN))))
    pd.DataFrame(displaystats).to_csv(out/'display_statistics.csv',index=False)
    print('Computing isolated point controls',flush=True)
    offset=np.arange(-450,451)*.001
    measures=[]; psfmaps={}; bp_errors=[]
    px=np.arange(-75,76)*.004; py=px.copy(); pq=grid(px,py)@Q.T+CAR_W
    for k in range(0,151,5):
        center_x=-8+3*k*.02
        er=(CAR_W-np.array([center_x,0.]))
        er/=np.linalg.norm(er); et=np.array([-er[1],er[0]])
        for n in [200,1000,2000]:
            lo=k*200+(2000-n)//2; positions=apx[lo:lo+n]
            cuts=[]
            for direction in [er,et]:
                cuts.append(direct_kernel(CAR_W+offset[:,None]*direction,CAR_W,positions,freq))
            measures.append(dict(frame=k,time_s=k*.02,chirps=n,
                radial_fwhm_cm=100*width(offset,cuts[0]),tangential_fwhm_cm=100*width(offset,cuts[1])))
        if k in COMPARE:
            positions=apx[k*200+500:k*200+1500]
            ep=synthesize(CAR_W[None,:],np.ones(1,dtype=np.complex128),positions,float(freq[0]),float(df),nr)
            ep[:,:100]=0; hp=compress(ep,retained)
            psfmaps[k]=backproject(pq,positions,hp,drange,fref).reshape(len(py),len(px))
            testq=CAR_W+np.array([[0.,0.],[.02,0.],[0.,.03],[.08,-.04]])
            bp=backproject(testq,positions,hp,drange,fref)
            direct=direct_kernel(testq,CAR_W,positions,freq)
            bp_errors.extend(abs(bp-direct).tolist())
    measures=pd.DataFrame(measures); measures.to_csv(out/'isolated_point_fwhm.csv',index=False)
    np.savez_compressed(out/'isolated_point_complex_controls.npz',
                        z=np.stack([psfmaps[k] for k in COMPARE]),time_s=np.array(COMPARE)*.02,
                        x_offset_display_m=px,y_offset_display_m=py)
    np.savez_compressed(out/'motion_compensation_control.npz',matched=compare[75,1000],
                        frozen=frozen,x_offset_m=xf,y_offset_m=yf,time_s=1.5)
    print('Rendering figures and animation',flush=True)
    fig,axes=plt.subplots(2,3,figsize=(13.1,9.5),layout='constrained')
    fig.suptitle('同一辆静止车：连续回波的时序 BP 成像',fontsize=18,fontweight='bold')
    for ax,k,label in zip(axes.ravel(),KEYS,'abcdef'):
        r=frames.iloc[k]
        im=image(ax,keymaps[k],xf,yf,
                 f'({label})  t = {r.time_s:.1f} s    R = {r.range_to_car_center_m:.2f} m')
    fig.colorbar(im,ax=axes.ravel().tolist(),shrink=.8,pad=.02,label='归一化 BP 功率 / dB',ticks=[-40,-30,-20,-10,0,5])
    fig.supxlabel('世界坐标固定裁剪 · 坐标相对车辆中心 · 1000 chirp / 图，step 200 · 固定幅相散射点模型',fontsize=10)
    save(fig,out,'01_temporal_vehicle_BP')
    fig,axes=plt.subplots(3,3,figsize=(12.6,13.8),layout='constrained')
    fig.suptitle('同一中心时刻，不同合成孔径',fontsize=18,fontweight='bold')
    for row,n in enumerate([200,1000,2000]):
        for col,k in enumerate(COMPARE):
            im=image(axes[row,col],compare[k,n],xf,yf,f'{n} chirp · {n/10:.0f} ms    |    t = {k*.02:.1f} s','gray')
    fig.colorbar(im,ax=axes.ravel().tolist(),shrink=.8,pad=.02,label='归一化 BP 功率 / dB')
    fig.supxlabel('全部图像共享 −40 至 +5 dB 映射；同一世界坐标、同一车辆、同一连续回波',fontsize=10)
    save(fig,out,'02_aperture_time_comparison')
    fig,axes=plt.subplots(1,3,figsize=(14.4,7.2),layout='constrained')
    fig.suptitle('雷达随动视图：车辆静止，图中相对位置改变',fontsize=17,fontweight='bold')
    for ax,k in zip(axes,COMPARE):
        im=image(ax,overview[k],rx,ry,f't = {k*.02:.1f} s','gray')
        carlocal=(outline@Q.T-np.array([-8+3*k*.02,0.]))@Q
        ax.plot(carlocal[:,0],carlocal[:,1],color='#47d7dc',lw=.8,ls='--')
        ax.plot(0,0,'^',color='#ea8b35',ms=6)
        ax.set_xlim(-25,25); ax.set_ylim(0,40)
    fig.colorbar(im,ax=axes,shrink=.75,pad=.015,label='归一化 BP 功率 / dB')
    fig.supxlabel('虚线为输入车辆轮廓；40 m / ±60° 显示扇区，非波束模型；1000 chirp / 图',fontsize=10)
    save(fig,out,'03_radar_view_sequence')
    geometry_figure(out,table,measures,psfmaps,px,py)
    gm=np.asarray(Image.open(GM).convert('L'))
    fig,axes=plt.subplots(1,3,figsize=(14.8,6.3),layout='constrained')
    fig.suptitle('处理对照与独立真实图参考',fontsize=17,fontweight='bold')
    for ax,z,title in zip(axes[:2],[compare[75,1000],frozen],['(a) 正确轨迹 BP · t = 1.5 s','(b) 负对照：补偿时冻结雷达位置']):
        im=image(ax,z,xf,yf,title,'gray')
    fig.colorbar(im,ax=axes[:2],shrink=.75,pad=.02,label='归一化 BP 功率 / dB')
    axes[2].imshow(gm,cmap='gray',vmin=0,vmax=255,interpolation='nearest')
    axes[2].set_title('(c) 原始 GM19 F269 · 独立显示参考',loc='left',fontsize=11,pad=9)
    axes[2].set_axis_off()
    fig.supxlabel('前两栏：同一回波、同一尺度；右栏：另一真实场景，原始 8 bit 灰度，不共享功率标定',fontsize=10)
    save(fig,out,'05_controls_and_real_reference')
    colorbar_assets(out)
    # Deliver a 50fps movie plus an explicitly slowed GIF for convenient inspection.
    font=ImageFont.truetype(FONT,22); small=ImageFont.truetype(FONT,17)
    width_video,height_video=1100,680
    writer=cv2.VideoWriter(str(out/'vehicle_sequence_50fps.mp4'),cv2.VideoWriter_fourcc(*'mp4v'),50,(width_video,height_video))
    if not writer.isOpened():
        raise RuntimeError('MP4 writer did not open')
    gif=[]
    for k,z in enumerate(local):
        canvas=Image.new('RGB',(width_video,height_video),'#fafbfd'); draw=ImageDraw.Draw(canvas)
        draw.text((30,18),'固定车辆时序 BP  |  1000 chirp / 图，step 200',font=font,fill='#182938')
        r=frames.iloc[k]
        draw.text((30,56),f't = {r.time_s:.2f} s    R = {r.range_to_car_center_m:.2f} m    方位 = {r.car_bearing_display_deg:+.1f}°',font=small,fill='#495a69')
        for cmap,x0 in [('gray',30),('magma',570)]:
            rgb=render_rgb(z,cmap)[::-1]
            tile=Image.fromarray(rgb).resize((483,513),Image.Resampling.NEAREST)
            canvas.paste(tile,(x0,103))
            draw.text((x0,625),f'{cmap} · 固定映射 −40 至 +5 dB',font=small,fill='#495a69')
        writer.write(cv2.cvtColor(np.asarray(canvas),cv2.COLOR_RGB2BGR))
        if k%2==0:
            thumb=canvas.resize((825,510),Image.Resampling.LANCZOS)
            ImageDraw.Draw(thumb).text((24,487),'回放减速 5 倍；原始更新率 50 Hz',font=ImageFont.truetype(FONT,13),fill='#495a69')
            gif.append(thumb)
    writer.release()
    gif[0].save(out/'vehicle_sequence_slow5x.gif',save_all=True,append_images=gif[1:],duration=200,loop=0,optimize=False)
    video=cv2.VideoCapture(str(out/'vehicle_sequence_50fps.mp4'))
    video_info=dict(frame_count=int(video.get(cv2.CAP_PROP_FRAME_COUNT)),fps=video.get(cv2.CAP_PROP_FPS),
                    width=int(video.get(cv2.CAP_PROP_FRAME_WIDTH)),height=int(video.get(cv2.CAP_PROP_FRAME_HEIGHT)))
    ok,_=video.read(); video.release()
    # Continuous indexing + exact point kernel validate phase and coordinate handling.
    assert max(forward_error)<2e-6
    assert max(bp_errors)<.02
    assert video_info['frame_count']==151 and video_info['fps']==50 and ok
    assert np.isfinite(local).all()
    assert np.allclose(np.diff(frames.time_s),.02)
    assert len(np.unique(frames.car_world_x_m))==len(np.unique(frames.car_world_y_m))==1
    # Global straight-track ambiguity: reflected points have identical ranges.
    mirror_range_error=float(np.max(abs(np.sqrt((CAR_W[0]-apx)**2+CAR_W[1]**2)-np.sqrt((CAR_W[0]-apx)**2+(-CAR_W[1])**2))))
    # Translating the scene and platform jointly must preserve the point response.
    positions=apx[500:1500]; delta=1.234
    tq=CAR_W+np.array([[.02,0.],[0.,.03]])
    translation_error=float(np.max(abs(direct_kernel(tq,CAR_W,positions,freq)-direct_kernel(tq+[delta,0],CAR_W+[delta,0],positions+delta,freq))))
    hashes_after={str(p):sha(p) for p in sourcepaths}
    assert hashes==hashes_after and translation_error<1e-8
    verification=dict(status='PASS',forward_complex_abs_error_max=max(forward_error),
        bp_vs_exact_point_kernel_complex_error_max=max(bp_errors),
        translation_invariance_error=translation_error,mirror_range_error_m=mirror_range_error,
        sources_unchanged=hashes==hashes_after,video=video_info,
        wall_seconds=round(time.perf_counter()-started,2),visual_review='Pending separate inspection',
        main_point_width_endpoints=measures[(measures.chirps==1000)&measures.frame.isin([0,75,150])].to_dict('records'),
        motion_control_power_sum_ratio=float(np.sum(abs(frozen)**2)/np.sum(abs(compare[75,1000])**2)))
    dump(out/'VERIFICATION.json',verification)
    dump(out/'artifact_manifest.json',{str(p.relative_to(out)):dict(bytes=p.stat().st_size,sha256=sha(p))
         for p in out.rglob('*') if p.is_file() and p.name!='artifact_manifest.json'})
    print(json.dumps(verification,ensure_ascii=False,indent=2),flush=True)


if __name__=='__main__':
    main()
