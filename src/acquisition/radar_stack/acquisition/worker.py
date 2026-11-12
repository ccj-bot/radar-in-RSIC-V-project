from __future__ import annotations
import argparse,datetime,json,os,pathlib,shutil,signal,subprocess,sys,time,traceback
from radar_stack.camera.config import read,atomic
from radar_stack.capture.manager import capture_status,start_capture,stop_capture
from radar_stack.camera.recovery import RecorderGuard

STOP=False
def stop(sig,frame):
    global STOP
    STOP=True
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def stamp():return {'timestamp':now(),'monotonic_ns':time.monotonic_ns(),'unix_ns':time.time_ns()}

def prepare_camera_session(root,config,name):
    session=root/'sessions'/(datetime.datetime.now().strftime('%Y%m%dT%H%M%S_%f')+'__'+name)
    for directory in ('logs','camera','sync','reconstruction'):(session/directory).mkdir(parents=True,exist_ok=True)
    shutil.copy2(root/'config/station.yaml',session/'station_config_snapshot.yaml')
    atomic(session/'session_manifest.json',{'schema':'nx-radar-session/v2','session_name':name,'session_path':str(session),'prepared_at':now(),'status':'prepared_no_hardware_started','active_profile':None,'sensor_start_sent':False,'capture_kind':'camera_only'})
    atomic(session/'experiment.json',{'display_name':config['label'] or '摄像头采集 '+datetime.datetime.now().strftime('%m-%d %H:%M'),'note':config['note'],'source':'acquisition_console','created_at':now()})
    return session

def run(root,launch):
    root=pathlib.Path(root);config=read(launch);runtime=root/'runtime/active_batch.json'
    started=now();session=None;camera=None;reason='manual_stop_requested';error=None;radar_started=False
    state={'schema':'nx-acquisition-batch/v1','worker_pid':os.getpid(),'active':True,'state':'starting','started_at':started,'sources':{'radar':config['radar_enabled'],'camera':config['camera_enabled']}}
    atomic(runtime,state)
    def publish(**details):
        state.update(details);state['updated_monotonic_ns']=time.monotonic_ns();atomic(runtime,state)
        if session:atomic(session/'batch_live.json',state)
    def event(name,**details):
        if session:
            with (session/'sync/events.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps({'event':name,**stamp(),**details},ensure_ascii=False)+'\n')
    def launch_camera():
        with (session/'logs/camera_worker.log').open('a') as f:
            child=subprocess.Popen([sys.executable,'-m','radar_stack.camera.worker','--root',str(root),'--session',str(session)],stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
        event('camera_worker_started',pid=child.pid)
        return child
    try:
        name='batch-'+datetime.datetime.now().strftime('%H%M%S-%f')
        if config['radar_enabled']:
            radar=start_capture(root,name,session_metadata={'display_name':config['label'] or '联合采集 '+datetime.datetime.now().strftime('%m-%d %H:%M'),'note':config['note'],'source':'acquisition_console'})
            session=pathlib.Path(radar['session']);radar_started=True
            plan=read(session/'capture_plan.json');config['reserve_disk_gib']=plan['derived']['reserve_disk_gib']
        else:session=prepare_camera_session(root,config,name)
        (session/'camera').mkdir(exist_ok=True);(session/'sync').mkdir(exist_ok=True)
        atomic(session/'acquisition_config_snapshot.json',config)
        atomic(session/'camera_config_snapshot.json',config)
        atomic(session/'sync/clock_reference.json',{'schema':'nx-acquisition-clock/v1',**stamp(),'clock':'CLOCK_MONOTONIC on this NX; realtime references also recorded','radar_timestamps':'radar segment host receipt times, not RF emission times','camera_timestamps':'GStreamer V4L2 PTS plus pipeline clock/base-time and host probe receipt','hardware_synchronized':False})
        manifest=read(session/'session_manifest.json');manifest.update(capture_kind='radar_camera' if config['radar_enabled'] and config['camera_enabled'] else ('radar_only' if config['radar_enabled'] else 'camera_only'),acquisition_config='acquisition_config_snapshot.json',batch_live='batch_live.json');atomic(session/'session_manifest.json',manifest)
        event('batch_started',sources=state['sources'])
        publish(session=str(session),label=config['label'] or read(session/'experiment.json').get('display_name',name))
        if config['camera_enabled'] and not STOP:
            camera=launch_camera()
        camera_guard=RecorderGuard(time.monotonic())
        while not STOP:
            rs=capture_status(root);radar_active=bool(rs.get('active') and rs['runtime']['session']==str(session))
            radar_result=read(session/'capture_result.json') if config['radar_enabled'] else {}
            cs=read(session/'camera/live.json');camera_active=camera is not None and camera.poll() is None
            if shutil.disk_usage(session).free<=int(config.get('reserve_disk_gib',10)*1024**3)+1024**3:reason='disk_reserve';break
            if radar_result.get('stop_reason') in ('manual_stop_requested','disk_reserve') and not radar_active:
                reason=radar_result['stop_reason'];break
            action='healthy'
            if config['camera_enabled'] and not STOP:
                camera_result=read(session/'camera/result.json') if not camera_active else {}
                if camera_result.get('stop_reason')=='disk_reserve' and camera_result.get('finished',{}).get('monotonic_ns',0)/1e9>=camera_guard.started_at:
                    reason='disk_reserve';break
                action=camera_guard.assess(camera_active,cs,time.monotonic())
                if action=='terminate':
                    event('camera_heartbeat_timeout',pid=camera.pid);camera.terminate()
                elif action=='kill':
                    if camera_active:camera.kill()
                elif action=='schedule_restart':
                    event('camera_worker_exit',returncode=camera.returncode if camera else None,restart_count=camera_guard.failures)
                elif action=='restart':
                    camera=launch_camera();camera_guard.started(time.monotonic());camera_active=True
                    event('camera_worker_restarted',pid=camera.pid,restart_count=camera_guard.failures)
                if action!='healthy':
                    cs.update(state='retrying',status_message='录像进程异常或无响应，正在恢复到本次采集；已完成的视频保留。',fps=0,rate_mib_s=0,monotonic_ns=time.monotonic_ns(),unix_ns=time.time_ns(),worker_restarts=camera_guard.failures)
                    atomic(session/'camera/live.json',cs)
            radar_state='disabled' if not config['radar_enabled'] else ('recording' if radar_active else ('failed' if radar_result.get('error') else 'stopped'))
            camera_state='disabled' if not config['camera_enabled'] else (cs.get('state','starting') if camera_active or action!='healthy' else 'failed')
            degraded=radar_state=='failed' or camera_state in ('failed','waiting_for_device','retrying')
            publish(state='degraded' if degraded else 'capturing',radar_state=radar_state,camera_state=camera_state,camera_pid=camera.pid if camera else None)
            if not radar_active and not camera_active and not config['camera_enabled']:
                reason='all_sources_finished';break
            time.sleep(.5)
    except Exception as exc:error=str(exc);reason='batch_error';traceback.print_exc()
    finally:
        if session:
            publish(state='stopping');event('batch_stop_requested',reason=reason)
            rs=capture_status(root)
            if rs.get('active') and rs['runtime']['session']==str(session):
                try:stop_capture(root,str(session))
                except Exception as exc:event('radar_stop_error',error=str(exc))
            if camera and camera.poll() is None:camera.send_signal(signal.SIGTERM)
            deadline=time.monotonic()+35
            while time.monotonic()<deadline:
                rs=capture_status(root)
                radar_active=rs.get('active') and rs['runtime']['session']==str(session)
                if not radar_active and (camera is None or camera.poll() is not None):break
                time.sleep(.25)
            if camera and camera.poll() is None:
                camera.kill();camera.wait(timeout=5);event('camera_forced_termination')
            radar_result=read(session/'capture_result.json') if config['radar_enabled'] else {}
            camera_result=read(session/'camera/result.json') if config['camera_enabled'] else {}
            radar_ok=bool(radar_result.get('quality_gate',{}).get('passed') and not radar_result.get('error')) if config['radar_enabled'] else None
            camera_ok=bool(camera_result.get('frames',0)>0 and camera_result.get('quality')=='normal') if config['camera_enabled'] else None
            partial=any(x is False for x in (radar_ok,camera_ok))
            result={'schema':'nx-acquisition-batch-result/v1','session':str(session),'sources':state['sources'],'started_at':started,'finished_at':now(),'stop_reason':reason,'error':error,
                    'radar_ok':radar_ok,'camera_ok':camera_ok,'radar_result':'capture_result.json' if config['radar_enabled'] else None,'camera_result':'camera/result.json' if config['camera_enabled'] else None,
                    'radar_written_bytes':radar_result.get('quality',{}).get('written_bytes',0) if radar_result.get('quality') else 0,
                    'camera_written_bytes':camera_result.get('completed_bytes',0),'camera_frames':camera_result.get('frames',0),'status':'capture_failed' if error else ('capture_partial' if partial else 'capture_stopped')}
            atomic(session/'batch_result.json',result)
            if not config['radar_enabled']:
                atomic(session/'capture_result.json',{'session':str(session),'started_at':started,'finished_at':result['finished_at'],'stop_reason':reason,'error':error,'quality':None,'camera_result':'camera/result.json','batch_result':'batch_result.json'})
            manifest=read(session/'session_manifest.json');manifest.update(status=result['status'],batch_result='batch_result.json');atomic(session/'session_manifest.json',manifest)
            event('batch_finished',status=result['status'],radar_ok=radar_ok,camera_ok=camera_ok)
            publish(active=False,state='stopped',result=result)
        else:atomic(root/'runtime/last_batch_error.json',{'at':now(),'error':error,'launch':str(launch)})
        current=read(runtime)
        if current.get('worker_pid')==os.getpid():runtime.unlink(missing_ok=True)
    return 2 if error else 0

def main():
    p=argparse.ArgumentParser();p.add_argument('--root',required=True);p.add_argument('--launch',required=True);p.add_argument('--lock-fd',type=int,required=True);a=p.parse_args()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,stop)
    return run(a.root,a.launch)
if __name__=='__main__':raise SystemExit(main())
