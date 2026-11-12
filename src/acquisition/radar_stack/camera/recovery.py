"""Camera identity, crash recovery and process supervision; no USB resets."""
from __future__ import annotations
import csv,pathlib
from radar_stack.camera.config import read,atomic

def usb_identity(device):
    node=pathlib.Path(device).resolve().name
    sysdevice=pathlib.Path('/sys/class/video4linux')/node/'device'
    for parent in (sysdevice.resolve(),*sysdevice.resolve().parents):
        if (parent/'idVendor').exists() and (parent/'idProduct').exists():
            def value(name):
                try:return (parent/name).read_text().strip()
                except OSError:return ''
            return {'vendor':value('idVendor'),'product':value('idProduct'),'serial':value('serial')}
    return {}

def same_identity(expected,actual):
    keys=('vendor','product','serial')
    return bool(expected.get('serial') and all(expected.get(k)==actual.get(k) for k in keys))

def select_device(devices,configured,identity):
    """Never replace a missing selected camera with an unrelated first device."""
    exact=[d for d in devices if configured in (d.get('stable_path'),d.get('resolved_path'))]
    if exact:
        d=exact[0]
        if not identity or same_identity(identity,d.get('identity',{})):
            return d
        if not identity.get('serial') and all(identity.get(k)==d.get('identity',{}).get(k) for k in ('vendor','product')):
            return d
    matching=[d for d in devices if same_identity(identity,d.get('identity',{}))]
    if len(matching)==1:return matching[0]
    if not configured and not identity and len(devices)==1:return devices[0]
    return None

def restore_epochs(session):
    """Resume in a new epoch; retain completed clips and incomplete .part files."""
    session=pathlib.Path(session);results=[];highest=0
    for epoch in sorted((session/'camera/epochs').glob('epoch_*')):
        try:index=int(epoch.name.split('_')[-1])
        except ValueError:continue
        highest=max(highest,index);result=read(epoch/'result.json')
        if not result:
            count=0;encoded=0;first=None;last=None
            try:
                with (epoch/'frames.csv').open(newline='') as f:
                    for row in csv.DictReader(f):
                        try:
                            size=int(row['encoded_bytes']);mono=int(row['host_probe_monotonic_ns'])
                        except (ValueError,KeyError,TypeError):continue
                        count+=1;encoded+=size;last=mono
                        if first is None:first=mono
            except OSError:pass
            segments=[{'path':str(p.relative_to(session)),'bytes':p.stat().st_size} for p in sorted((epoch/'segments').glob('*.mkv'))]
            result={'epoch':index,'frames':count,'encoded_bytes':encoded,'segments':segments,
                    'completed_bytes':sum(p['bytes'] for p in segments),'mode':read(epoch/'contract.json').get('mode'),
                    'first_host_monotonic_ns':first,'last_host_monotonic_ns':last,
                    'error':'录像进程异常退出，已保留完整分段；将从新分段恢复',
                    'stop_reason':'recorder_process_exit','recovered_after_worker_exit':True,
                    'frame_count_basis':'persisted CSV rows; unflushed rows may be unavailable',
                    'incomplete_files':[str(p.relative_to(session)) for p in epoch.rglob('*.part')]}
            atomic(epoch/'result.json',result)
        results.append(result)
    return results,highest

class RecorderGuard:
    """Nonblocking escalation for this recorder PID only, with bounded backoff."""
    def __init__(self,now,heartbeat_timeout=20,stop_grace=8):
        self.heartbeat_timeout=heartbeat_timeout;self.stop_grace=stop_grace;self.failures=0
        self.started(now)
    def started(self,now):
        self.started_at=now;self.termination_at=None;self.restart_at=None
    def assess(self,alive,live,now):
        if alive:
            if self.termination_at is not None:
                return 'kill' if now-self.termination_at>=self.stop_grace else 'waiting_for_exit'
            heartbeat=max(self.started_at,float(live.get('monotonic_ns',0))/1e9)
            if now-heartbeat>self.heartbeat_timeout:
                self.termination_at=now;return 'terminate'
            return 'healthy'
        if self.restart_at is None:
            self.failures+=1;self.restart_at=now+min(10,2**min(self.failures,4));return 'schedule_restart'
        return 'restart' if now>=self.restart_at else 'waiting_restart'
