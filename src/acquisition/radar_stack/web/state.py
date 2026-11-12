from __future__ import annotations
import copy, csv, io, json, math, os, shutil, subprocess, tempfile, threading, time
from datetime import datetime, timezone
from pathlib import Path
from radar_stack.profiles.plan import build_capture_plan
from radar_stack.profiles.registry import active_profile_path, select_profile, _atomic_json, _validate_name
from radar_stack.profiles.sync import sync_profile
from radar_stack.profiles.validation import validation_status, validate_active_profile
from radar_stack.capture.manager import capture_status, capture_lock, start_capture, stop_capture
from radar_stack.capture.usb import usb_presence
from radar_stack.camera.config import inventory as camera_inventory, settings as acquisition_settings, save_settings as save_acquisition_settings
from radar_stack.acquisition.manager import batch_status, start_batch, stop_batch

def acquisition_status(root):
    batch=batch_status(root)
    if batch.get('active'):
        return {'active':True,'runtime':batch,'sources':batch.get('sources',{}),'batch':True}
    return capture_status(root)


FAULTS=('duplicate_packets','out_of_order_packets','short_packets','oversized_packets',
        'source_ip_anomalies','source_port_anomalies','byte_gaps','byte_stride_mismatches',
        'sequence_mismatches','queue_overflows','trailing_unresolved_packets')

def read_json(path, default=None):
    try: return json.loads(Path(path).read_text(encoding='utf-8'))
    except (OSError, ValueError): return {} if default is None else default

def now(): return datetime.now(timezone.utc).isoformat()

def timestamp(value):
    try:return datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()
    except (ValueError,AttributeError):return None

def tail_csv(path):
    try:
        with Path(path).open('rb') as f:
            header=f.readline().decode(); f.seek(0,2); size=f.tell(); f.seek(max(len(header),size-8192))
            raw=f.read().decode(errors='replace').splitlines()
        rows=list(csv.DictReader(io.StringIO(header+'\n'.join(raw[-3:])+'\n')))
        return rows[-1] if rows else {}
    except (OSError,ValueError):return {}

class Console:
    def __init__(self, root):
        self.root=Path(root).resolve(); self.guard=threading.Lock(); self.job={}; self.cancel=threading.Event()
        self._hardware=(0,{}); self._rate={}; self._history_cache={}; self._camera=(0,{})

    def hardware(self):
        if time.monotonic()-self._hardware[0]<5:return self._hardware[1]
        station=read_json(self.root/'config/station.yaml'); network=station['network']
        def run(cmd):
            try:return subprocess.run(cmd,capture_output=True,text=True,timeout=3).stdout.strip()
            except (OSError,subprocess.TimeoutExpired):return ''
        usb=run(['lsusb']); address=run(['ip','-br','addr','show',network['interface']])
        speed_path=Path('/sys/class/net')/network['interface']/'speed'
        try:speed=int(speed_path.read_text())
        except (OSError,ValueError):speed=0
        issues=[]
        if network['nx_ip'] not in address:issues.append('雷达网卡地址不匹配')
        if speed!=1000:issues.append('雷达网口未连接到千兆链路')
        interfaces=usb_presence(usb)
        # AWR2243 control uses DevPack/FTDI SPI. XDS110 UART/debug nodes
        # are optional; DevPack-only capture was verified on this station.
        if not interfaces['ftdi_control']:issues.append('未检测到雷达 FTDI/DevPack 控制接口，请检查 USB 连接')
        result={'ready':not issues,'issues':issues,'link_mbps':speed,'interface':network['interface'],
                'address':network['nx_ip'],'usb_interfaces':interfaces,'checked_at':now()}
        self._hardware=(time.monotonic(),result);return result

    def camera(self):
        if time.monotonic()-self._camera[0]<3:return self._camera[1]
        info=camera_inventory(self.root);self._camera=(time.monotonic(),info);return info

    def save_acquisition(self, values):
        if acquisition_status(self.root).get('active'):raise ValueError('采集中不能更改通道或摄像头设置')
        result=save_acquisition_settings(self.root,values);self._camera=(0,{})
        return self.camera()

    def profile(self):
        path=active_profile_path(self.root); form=read_json(path); plan=build_capture_plan(path,project_root=self.root)
        v=validation_status(self.root,form,plan,read_json(self.root/'config/station.yaml'))
        d=plan['derived']; t=d['timing_model']; f=form['fields']; val=lambda k,default=None:f.get(k,{}).get('value',default)
        return {'name':path.stem,'validated':v['next_action']=='ready_for_capture','validation_action':v['next_action'],
                'parameters':{'fps':t['frame_rate_hz'],'chirps':t['chirps_per_frame'],
                  'adc_samples':t['adc_samples'],'blank_ms':val('radar_target_frame_blank_time_ms',0.5),
                  'reserve_gib':d['reserve_disk_gib'],'ramp_us':t['ramp_end_time_us'],
                  'rx_mask':val('radar_channel_rx_mask',15),'tx':val('radar_chirp_tx_sequence',[0]),
                  'packet_delay_us':val('dca_packet_delay_us',5)},
                'timing':t,'rate_mib_s':d['estimated_raw_rate_MiBps'],
                'bin_bytes':d['physical_segment_full_bytes'],'stop_policy':d.get('stop_policy'),
                'budget':d['transport_budget'],'disk_guard_bytes':d.get('disk_stop_guard_bytes',1024**3)}

    def status(self):
        capture=acquisition_status(self.root); disk=shutil.disk_usage(self.root/'sessions'); metrics={}
        try:profile=self.profile()
        except Exception as exc:profile={'error':str(exc)}
        camera_info=self.camera(); camera_live={}
        if capture.get('active') and capture['runtime'].get('session'):
            session=Path(capture['runtime']['session']); metrics=read_json(session/'radar/receiver_live.json')
            current_ms=metrics.get('updated_unix_ms',0); written=metrics.get('written_bytes',0)
            old=self._rate.get(str(session)); rate=old[2] if old else 0
            if old and old[0]>0 and current_ms>old[0]:rate=max(0,(written-old[1])*1000/(current_ms-old[0])/1024**2)
            self._rate[str(session)]=(current_ms,written,rate)
            metrics['rate_mib_s']=rate if time.time()*1000-current_ms<3500 else 0
            metrics['stale']=not current_ms or time.time()*1000-current_ms>3500
            started=timestamp(capture['runtime'].get('started_at',capture['runtime'].get('requested_at')))
            metrics['elapsed_s']=max(0,time.time()-started) if started else 0
            capture['label']=read_json(session/'experiment.json').get('display_name',session.name)
            camera_live=read_json(session/'camera/live.json')
            metrics['radar_written_bytes']=metrics.get('written_bytes',0)
            metrics['radar_rate_mib_s']=metrics.get('rate_mib_s',0)
            metrics['written_bytes']=metrics.get('written_bytes',0)+camera_live.get('total_bytes',camera_live.get('completed_bytes',0))
            metrics['rate_mib_s']=metrics.get('rate_mib_s',0)+camera_live.get('rate_mib_s',0)
            metrics['camera_frames']=camera_live.get('frames',0)
            metrics['camera_segments']=camera_live.get('complete_segments',0)
        elif self.job.get('session'):
            result=read_json(Path(self.job['session'])/'capture_result.json')
            if result.get('error'):
                self.job.update(phase='failed',message='采集异常：'+result['error'])
            elif result.get('finished_at'):
                reason={'manual_stop_requested':'手动停止','disk_reserve':'磁盘达到保留空间阈值'}.get(result.get('stop_reason'),result.get('stop_reason'))
                self.job.update(phase='complete',message='采集已结束：'+str(reason))
        reserve=profile.get('parameters',{}).get('reserve_gib',10)*1024**3
        cfg=acquisition_settings(self.root)
        rate=metrics.get('rate_mib_s') or (profile.get('rate_mib_s',0) if cfg['radar_enabled'] else 0)
        return {'schema':'nx-radar-console/v1','server_time':now(),'capture':capture,'metrics':metrics,
                'profile':profile,'hardware':self.hardware(),'operation':dict(self.job),'acquisition':cfg,'camera':{**camera_info,'live':camera_live},
                'disk':{'free_bytes':disk.free,'total_bytes':disk.total,'used_bytes':disk.used,
                        'reserve_bytes':reserve,'guard_bytes':profile.get('disk_guard_bytes',1024**3),
                        'estimated_remaining_s':max(0,disk.free-reserve-profile.get('disk_guard_bytes',1024**3))/(rate*1024**2) if rate else None},
                'storage_root':str(self.root/'sessions'),'imaging_enabled':False}

    def history(self, query='',date='',limit=200):
        active=acquisition_status(self.root); active_path=active.get('runtime',{}).get('session')
        items=[]
        for p in sorted((self.root/'sessions').iterdir(),reverse=True):
            if not p.is_dir():continue
            m=read_json(p/'session_manifest.json'); result=read_json(p/'capture_result.json'); batch=read_json(p/'batch_result.json'); cam=read_json(p/'camera/result.json')
            if not m:continue
            meta=read_json(p/'experiment.json'); label=meta.get('display_name',m.get('session_name',p.name))
            if query.lower() not in (label+' '+p.name+' '+str(m.get('active_profile') or '')).lower():continue
            started=result.get('started_at',m.get('prepared_at')); ts=timestamp(started)
            local_date=datetime.fromtimestamp(ts).strftime('%Y-%m-%d') if ts else p.name[:8]
            if date and date!=local_date:continue
            q=result.get('quality') or read_json(p/'radar/radar_quality_summary.json')
            live=str(p)==active_path and active.get('active')
            if live:
                q=read_json(p/'radar/receiver_live.json') or q
                cam=read_json(p/'camera/live.json') or cam
            plan=read_json(p/'capture_plan.json'); d=plan.get('derived',{}); timing=d.get('timing_model',{})
            end=batch.get('finished_at') or result.get('finished_at'); duration=max(0,(timestamp(end) or time.time())-ts) if ts and (live or end) else None
            written=q.get('written_bytes',0); segment=q.get('segment_bytes') or d.get('physical_segment_full_bytes')
            faults={k:q[k] for k in FAULTS if q.get(k)}
            status=m.get('status','unknown')
            if not live and not result and m.get('sensor_start_sent') and 'discovery' not in status:status='interrupted'
            items.append({'id':p.name,'name':label,'profile':m.get('active_profile'),'started_at':started,
                'ended_at':end,'duration_s':duration,'status':'capturing' if live else status,
                'stop_reason':batch.get('stop_reason') or result.get('stop_reason'),'bytes':written+cam.get('completed_bytes',cam.get('total_bytes',0)),'camera_frames':cam.get('frames',0),'camera_segments':cam.get('complete_segments',0),'camera_quality':cam.get('quality'),'sources':batch.get('sources',read_json(p/'acquisition_config_snapshot.json')),'bin_count':written//segment if segment else None,
                'quality':'abnormal' if result.get('error') or faults else ('degraded' if batch.get('status')=='capture_partial' else ('normal' if q or cam.get('quality')=='normal' else 'unknown')),
                'faults':faults,'error':result.get('error'),'boundary_discard_bytes':q.get('boundary_discard_bytes',0),
                'parameters':{'fps':timing.get('frame_rate_hz'),'chirps':timing.get('chirps_per_frame'),'adc_samples':timing.get('adc_samples')},
                'kind':'validation' if 'validat' in p.name or 'discovery' in status else ('capture' if result or live else 'prepared')})
            if len(items)>=min(int(limit),1000):break
        return {'items':items,'count':len(items)}

    def save_profile(self, values, preview=False):
        if acquisition_status(self.root).get('active'):raise ValueError('采集中不能更改配置，请先停止')
        def number(key, low, high, integer=False):
            raw=values[key]
            if isinstance(raw,bool):raise ValueError(f'{key} 不能是布尔值')
            value=float(raw)
            if not math.isfinite(value) or not low<=value<=high or (integer and value!=int(value)):
                raise ValueError(f'{key} 必须在 {low} 到 {high} 之间'+('，并为整数' if integer else ''))
            return int(value) if integer else value
        fps=number('fps',0.1,100); loops=number('chirps',1,255,True); samples=number('adc_samples',64,4096,True)
        blank=number('blank_ms',0.3,1000); reserve=number('reserve_gib',1,10000)
        ramp=number('ramp_us',1,5000); rx=number('rx_mask',1,15,True); packet=number('packet_delay_us',5,500)
        tx=values.get('tx',[0])
        if not isinstance(tx,list) or len(tx)!=1 or type(tx[0]) is not int or tx[0] not in (0,1,2):
            raise ValueError('当前简化界面使用单 TX；请选择 TX0、TX1 或 TX2')
        form=read_json(self.root/'config/profiles/saved/s30-uniform.json')
        if not form:raise ValueError('缺少基础配置 s30-uniform')
        name='continuous-'+datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        changes={'profile_name':name,'capture_mode':'manual_until_disk_reserve','stop_after_gib':0,
            'reserve_disk_gib':reserve,'radar_target_frame_rate_hz':fps,'radar_frame_loop_count':loops,
            'radar_profile0_adc_samples':samples,'radar_target_frame_blank_time_ms':blank,
            'radar_profile0_ramp_end_time_ticks':int(round(ramp*100)),
            'radar_channel_rx_mask':rx,'radar_chirp_tx_sequence':tx,'dca_packet_delay_us':packet,
            'physical_segment_frames':1,'physical_segment_pulses':loops,'reconstruction_windows':[loops]}
        for k,v in changes.items():form['fields'].setdefault(k,{'zh':k})['value']=v
        # Validate in a disposable directory, so an invalid edit cannot change active files.
        drafts=self.root/'runtime'/'drafts';drafts.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=drafts) as temporary:
            tmp=Path(temporary); (tmp/'config/profiles/saved').mkdir(parents=True)
            (tmp/'sessions').symlink_to(self.root/'sessions',target_is_directory=True)
            for k in ('radar_config_template','dca_config_template'):
                rel=form['fields'][k]['value']; dest=tmp/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(self.root/rel,dest)
            _atomic_json(tmp/'config/profiles/saved'/f'{name}.json',form)
            sync_profile(tmp,name); plan=build_capture_plan(tmp/'config/profiles/saved'/f'{name}.json',project_root=tmp)
            if preview:return {'timing':plan['derived']['timing_model'],'rate_mib_s':plan['derived']['estimated_raw_rate_MiBps'],
                              'bin_bytes':plan['derived']['physical_segment_full_bytes'],'budget':plan['derived']['transport_budget']}
            target=self.root/'config/profiles/saved'/f'{name}.json'
            shutil.copy2(tmp/'config/profiles/saved'/f'{name}.json',target)
            # Regenerate at the actual root so provenance paths do not refer to the draft.
            sync_profile(self.root,name);select_profile(self.root,name)
        return self.profile()

    def begin(self, label='', note='', validate_only=False):
        if not self.guard.acquire(False):raise ValueError('上一项操作尚未完成')
        if acquisition_status(self.root).get('active'):
            self.guard.release();raise ValueError('已有采集正在运行')
        self.cancel.clear();self.job={'busy':True,'phase':'checking','message':'正在检查所选采集通道','started_at':now()}
        def run():
            try:
                cfg=acquisition_settings(self.root)
                if cfg['radar_enabled'] or validate_only:
                    with capture_lock(self.root) as fd:
                        hardware=self.hardware()
                        if not hardware['ready']:raise ValueError('；'.join(hardware['issues']))
                        profile=self.profile()
                        if not profile['validated'] or validate_only:
                            self.job.update(phase='validating',message='正在进行雷达 10 帧短采验证')
                            validate_active_profile(self.root,frames=10,lock_fd=fd)
                if self.cancel.is_set():self.job.update(phase='cancelled',message='已取消启动');return
                if validate_only:self.job.update(phase='complete',message='雷达配置验证通过');return
                result=start_batch(self.root,label,note)
                self.job.update(phase='starting',message='正在启动所选通道')
                deadline=time.monotonic()+12
                while time.monotonic()<deadline:
                    batch=batch_status(self.root)
                    if batch.get('session'):
                        self.job.update(phase='complete',message='采集任务已启动',session=batch['session'])
                        if self.cancel.is_set():stop_batch(self.root)
                        return
                    if self.cancel.is_set() and batch.get('active'):stop_batch(self.root)
                    time.sleep(.2)
                raise RuntimeError(read_json(self.root/'runtime/last_batch_error.json').get('error') or '任务尚未完成启动，请检查后台日志')
            except Exception as exc:self.job.update(phase='failed',message=str(exc))
            finally:self.job.update(busy=False,finished_at=now());self.guard.release()
        threading.Thread(target=run,daemon=True).start();return dict(self.job)

    def stop(self):
        self.cancel.set()
        if batch_status(self.root).get('active'):return stop_batch(self.root)
        if capture_status(self.root).get('active'):return stop_capture(self.root)
        return {'stop_requested':True,'message':'已请求取消启动；短采验证会先完成收尾'}
