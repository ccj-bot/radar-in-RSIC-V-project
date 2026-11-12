"""Read preserved NX physical-frame bins; decode as existing four-lane reader; RD only."""
from pathlib import Path
import argparse,json,time,hashlib,platform
import numpy as np
from PIL import Image
from fft_backend import fft,NAME as FFT_NAME

def main():
 p=argparse.ArgumentParser();p.add_argument('--input',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--repeat',type=int,default=5);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 meta=json.loads((a.input/'imaging_input.json').read_text(encoding='utf8'));timing=meta['timing'];nr=meta['adc_samples'];nm=meta['chirps_per_frame'];lanes=4
 files=sorted((a.input/'radar/raw_segments').glob('*.bin'));nfft=nr
 range_m=np.fft.fftshift(np.fft.fftfreq(nfft,d=1/timing['adc_sample_rate_hz']))*3e8/(2*timing['frequency_slope_mhz_per_us']*1e12)
 doppler_hz=np.fft.fftshift(np.fft.fftfreq(nm,d=timing['chirp_period_us']*1e-6));velocity_m_s=doppler_hz*timing['wavelength_m']/2
 window_range=np.hanning(nr).astype(np.float32);window_doppler=np.hanning(nm).astype(np.float32)
 records=[]
 for path in files:
  t=time.perf_counter();words=np.fromfile(path,dtype='<i2')
  if path.stat().st_size!=meta['segment_bytes']:raise RuntimeError('Physical frame size mismatch')
  words=words.reshape(nm,nr,2*lanes)
  # Only unpack the requested transport lane into the FFT pipeline.
  signal=np.ascontiguousarray(words[:,:,0].astype(np.float32)+1j*words[:,:,lanes].astype(np.float32))
  decode_ms=(time.perf_counter()-t)*1000;times=[]
  for _ in range(a.repeat):
   t=time.perf_counter();range_fft=fft(signal*window_range[None,:],axis=1);rd=np.fft.fftshift(fft(range_fft*window_doppler[:,None],axis=0),axes=(0,1));times.append((time.perf_counter()-t)*1000)
  db=20*np.log10(np.maximum(abs(rd)/max(float(abs(rd).max()),1e-12),1e-8));Image.fromarray(np.uint8(np.clip((db+60)/60,0,1)*255)).save(a.output/(path.stem+'_rd.png'))
  channel_power=np.array([np.mean(words[:,:,k].astype(np.float32)**2+words[:,:,k+lanes].astype(np.float32)**2) for k in range(lanes)])
  np.savez_compressed(a.output/(path.stem+'_rd.npz'),rd=rd,range_m=range_m,doppler_hz=doppler_hz,velocity_m_s=velocity_m_s,channel_power=channel_power)
  record={'file':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'bytes':path.stat().st_size,'decoded_shape':[nm,nr,lanes],'decode_ms':decode_ms,'RD_ms':times,'RD_median_ms':float(np.median(times)),'transport_lane_power':channel_power.tolist()};records.append(record)
 result={'machine':platform.machine(),'kind':'real_NX_bin_range_doppler_replay','frames':records,'range_axis':'signed beat-frequency apparent range; IQ polarity uncalibrated','doppler_axis':'nominal within-frame Doppler from actual saved timing','layout':'Existing raw_capture_reader.cpp: every 8 int16 values are I0 I1 I2 I3 Q0 Q1 Q2 Q3; 4 transport lanes, lane0 preview','timing':timing,'scope':'One 128-chirp physical frame per FFT. Do not join frames across gap. No SAR trajectory provided; this is a distance-Doppler map, not focused SAR or validated target velocity.'}
 result['fft_backend']=FFT_NAME
 (a.output/'result.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result),flush=True)
if __name__=='__main__':main()
