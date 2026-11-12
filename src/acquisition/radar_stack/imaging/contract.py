"""Only completed physical frames are visible to downstream consumers."""
import json
from pathlib import Path

def write_contract(session):
    session = Path(session)
    plan = json.loads((session / 'capture_plan.json').read_text())
    d = plan['derived']; t = d['timing_model']
    contract = {
        'schema': 'nx-radar-imaging-input/v1',
        'status': 'interface_only_imaging_not_enabled',
        'raw_directory': 'radar/raw_segments',
        'completed_pattern': 'segment_<index>.bin',
        'incomplete_suffix': '.part',
        'segment_index': 'radar/radar_segments.csv',
        'quality_summary': 'radar/radar_quality_summary.json',
        'adc_samples': t['adc_samples'], 'sample_encoding': 'little_endian_int16_complex',
        'layout_source': 'profile_form_snapshot.json and validated transport geometry',
        'bytes_per_chirp': d['bytes_per_chirp'],
        'chirps_per_frame': t['chirps_per_frame'],
        'frames_per_bin': d['physical_segment_pulses'] // t['chirps_per_frame'],
        'segment_bytes': d['physical_segment_full_bytes'],
        'tx_sequence': plan['radar_profile_summary'].get('effective_tx_sequence'),
        'timing': t,
        'relative_chirp_time_seconds': 'frame_index * frame_period_ms / 1000 + chirp_in_frame * chirp_period_us / 1000000',
        'time_origin': 'relative nominal radar schedule; no measured RF epoch available',
        'timestamps': 'packet host receive times are transport evidence, not RF emission timestamps',
        'cross_frame_uniform_fft_allowed': False,
        'requirements': ['read completed bins only', 'preserve physical frame boundaries',
                         'never bind capture UDP port', 'never delay or delete acquisition data',
                         'verify cross-frame phase coherence before coherent imaging'],
        'results_directory': 'reconstruction',
    }
    p = session / 'imaging_input.json'
    p.write_text(json.dumps(contract, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    return contract

def completed_frames(session, start=0, limit=100):
    """Bounded, resumable polling. Does not read raw sample contents."""
    session = Path(session)
    contract = json.loads((session / 'imaging_input.json').read_text())
    if contract['frames_per_bin'] != 1:
        raise ValueError('v1 frame feed requires one complete physical frame per bin')
    rows=[]
    for i in range(max(0, int(start)), max(0,int(start))+min(max(int(limit),1),1000)):
        p=session/'radar'/'raw_segments'/f'segment_{i}.bin'
        if not p.exists(): break
        if p.stat().st_size != contract['segment_bytes']:
            raise ValueError(f'completed bin has wrong size: {p.name}')
        rows.append({'index':i,'path':str(p),'bytes':p.stat().st_size,
                     'relative_frame_start_s':i*contract['timing']['frame_period_ms']/1000,
                     'timing_basis':'nominal_configuration'})
    return {'frames':rows,'next_index':rows[-1]['index']+1 if rows else max(0,int(start)),
            'quality_is_separate':True}
