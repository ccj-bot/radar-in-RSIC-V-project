from __future__ import annotations
import fcntl,os,pathlib,signal,subprocess,sys,time
from radar_stack.camera.config import read,atomic,settings,inventory
from radar_stack.capture.manager import capture_status

def running(pid):
    try:return b'radar_stack.acquisition.worker' in pathlib.Path(f'/proc/{int(pid)}/cmdline').read_bytes()
    except (OSError,ValueError):return False

def batch_status(root):
    root=pathlib.Path(root);state=read(root/'runtime/active_batch.json')
    if state and running(state.get('worker_pid',0)):
        state['active']=True;return state
    return {'active':False}

def start_batch(root,label='',note=''):
    root=pathlib.Path(root);runtime=root/'runtime';runtime.mkdir(exist_ok=True)
    lock=(runtime/'batch.lock').open('a+')
    try:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise RuntimeError('已有采集任务正在启动或运行') from None
        if capture_status(root).get('active'):raise RuntimeError('已有独立雷达采集正在运行')
        cfg=settings(root)
        from radar_stack.profiles.registry import active_profile_path
        form=read(active_profile_path(root));cfg['reserve_disk_gib']=float(form.get('fields',{}).get('reserve_disk_gib',{}).get('value',10))
        info=inventory(root) if cfg['camera_enabled'] else {}
        if not cfg['camera_device'] and info.get('selected'):cfg['camera_device']=info['selected']['stable_path']
        if cfg['camera_enabled'] and info.get('mode_error'):raise ValueError(info['mode_error'])
        if not cfg['radar_enabled'] and not cfg['camera_enabled']:raise ValueError('至少选择一个采集通道')
        cfg['label']=str(label).strip()[:120];cfg['note']=str(note)[:1000]
        config=runtime/'launches'/f'{time.time_ns()}.json';atomic(config,cfg)
        log=root/'logs'/('batch-launch-'+config.stem+'.log')
        with log.open('w') as f:
            process=subprocess.Popen([sys.executable,'-m','radar_stack.acquisition.worker','--root',str(root),'--launch',str(config),'--lock-fd',str(lock.fileno())],stdout=f,stderr=subprocess.STDOUT,start_new_session=True,pass_fds=(lock.fileno(),))
        # Worker publishes detailed state once its session directory is prepared.
        return {'worker_pid':process.pid,'state':'starting','message':'正在启动所选采集通道','launch':str(config)}
    finally:lock.close()

def stop_batch(root):
    state=batch_status(root)
    if not state.get('active'):return {'stop_requested':False,'message':'当前没有联合采集任务'}
    os.kill(int(state['worker_pid']),signal.SIGTERM)
    return {'stop_requested':True,'session':state.get('session'),'message':'正在分别结束雷达帧和视频分段'}
