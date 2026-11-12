"""Native V4L2 -> MKV stream copy, per-frame timestamps and reconnect epochs."""
from __future__ import annotations
import argparse,csv,fcntl,json,os,pathlib,shutil,signal,time,threading,traceback
from radar_stack.camera.config import read,atomic,probe_device,choose_mode

STOP=False
def stop(sig,frame):
    global STOP
    STOP=True

def stamp():return {'monotonic_ns':time.monotonic_ns(),'unix_ns':time.time_ns()}

def event(root,name,**kwargs):
    with (root/'events.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps({'event':name,**stamp(),**kwargs},ensure_ascii=False)+'\n')

def record_epoch(root,session,camera,config,index,total_before,segments_before,bytes_before,on_first_frame=None):
    import gi
    gi.require_version('Gst','1.0')
    from gi.repository import Gst
    Gst.init(None)
    device=config['camera_device'];info=probe_device(root,device,fixed_fps=True);mode=choose_mode(info['modes'],config['mode_id'])
    epoch=camera/'epochs'/f'epoch_{index:04d}';raw=epoch/'segments';raw.mkdir(parents=True)
    pipeline=Gst.Pipeline.new('camera-native-recorder')
    source=Gst.ElementFactory.make('v4l2src','source');capsfilter=Gst.ElementFactory.make('capsfilter','caps')
    queue=Gst.ElementFactory.make('queue','bounded_queue');tap=Gst.ElementFactory.make('identity','timestamp_tap');sink=Gst.ElementFactory.make('splitmuxsink','writer')
    if any(x is None for x in (pipeline,source,capsfilter,queue,tap,sink)):raise RuntimeError('GStreamer 录像组件不完整')
    source.set_property('device',device);source.set_property('do-timestamp',False)
    media='image/jpeg' if mode['fourcc']=='MJPG' else 'video/x-raw,format=YUY2'
    caps=Gst.Caps.from_string(f"{media},width={mode['width']},height={mode['height']},framerate={mode['fps_num']}/{mode['fps_den']}")
    capsfilter.set_property('caps',caps);queue.set_property('max-size-buffers',8);queue.set_property('max-size-bytes',0);queue.set_property('max-size-time',0)
    sink.set_property('location',str(raw/'segment_%06d.mkv.part'));sink.set_property('max-size-time',int(config['segment_seconds']*Gst.SECOND))
    sink.set_property('max-size-bytes',0);sink.set_property('muxer-factory','matroskamux');sink.set_property('async-finalize',True)
    for element in (source,capsfilter,queue,tap,sink):pipeline.add(element)
    if not source.link(capsfilter) or not capsfilter.link(queue) or not queue.link(tap) or not tap.link(sink):raise RuntimeError('摄像头录像管线连接失败')
    rows=(epoch/'frames.csv').open('w',newline='',encoding='utf-8');writer=csv.writer(rows)
    writer.writerow(['frame_index','gst_pts_ns','gst_duration_ns','gst_offset','gst_clock_time_ns','pipeline_base_time_ns','host_probe_monotonic_ns','host_probe_unix_ns','encoded_bytes','gst_buffer_flags'])
    guard=threading.Lock();state={'frames':0,'encoded_bytes':0,'first_pts_ns':None,'last_pts_ns':None,'first_host_monotonic_ns':None,'last_host_monotonic_ns':None,'offset_gap_frames':0,'timestamp_regressions':0,'last_offset':None,'segments':[]}
    last_publish=time.monotonic();last_frames=0;last_bytes=0;error=None;reason='manual_stop';eos_sent=False;deadline=None;started=time.monotonic()
    snapshot={'schema':'nx-camera-epoch/v1','device':info,'mode':mode,'started':stamp(),
        'pipeline':'v4l2src -> capsfilter -> bounded queue -> timestamp tap -> splitmuxsink(matroskamux)',
        'reencoding':False,'pixel_data':'device-native MJPEG' if mode['fourcc']=='MJPG' else 'uncompressed YUYV/YUY2',
        'timestamp_basis':'GStreamer V4L2 source PTS, pipeline clock and host monotonic/realtime receipt; no hardware exposure synchronization claimed'}
    atomic(epoch/'contract.json',snapshot)
    def probe(pad,probe_info):
        buffer=probe_info.get_buffer()
        if buffer is None:return Gst.PadProbeReturn.OK
        mono=time.monotonic_ns();unix=time.time_ns();clock=pipeline.get_clock();clock_now=clock.get_time() if clock else None;base=pipeline.get_base_time()
        pts=int(buffer.pts) if buffer.pts!=Gst.CLOCK_TIME_NONE else None
        offset=int(buffer.offset) if buffer.offset!=2**64-1 else None
        duration=int(buffer.duration) if buffer.duration!=Gst.CLOCK_TIME_NONE else None
        with guard:
            n=state['frames'];state.setdefault('negotiated_caps',pad.get_current_caps().to_string());previous=state['last_pts_ns'];last_offset=state['last_offset']
            if previous is not None and pts is not None and pts<previous:state['timestamp_regressions']+=1
            if last_offset is not None and offset is not None and offset>last_offset+1:state['offset_gap_frames']+=offset-last_offset-1
            if state['first_host_monotonic_ns'] is None:state['first_host_monotonic_ns']=mono;state['first_pts_ns']=pts
            state['last_pts_ns']=pts;state['last_offset']=offset;state['last_host_monotonic_ns']=mono
            writer.writerow([n,pts,duration,offset,clock_now,base,mono,unix,buffer.get_size(),int(buffer.get_flags())])
            state['frames']+=1;state['encoded_bytes']+=buffer.get_size()
        if n==0 and on_first_frame:on_first_frame({'monotonic_ns':mono,'unix_ns':unix})
        return Gst.PadProbeReturn.OK
    tap.get_static_pad('src').add_probe(Gst.PadProbeType.BUFFER,probe)
    bus=pipeline.get_bus()
    def snapshot_state():
        with guard:return {k:v for k,v in state.items() if k!='last_offset'}
    def handle(message):
        nonlocal error,reason,eos_sent,deadline
        if message.type==Gst.MessageType.ERROR:
            err,debug=message.parse_error();error=error or err.message;reason='device_or_stream_error'
            event(camera,'camera_stream_error',epoch=index,error=err.message,debug=debug)
            if not eos_sent:pipeline.send_event(Gst.Event.new_eos());eos_sent=True;deadline=time.monotonic()+3
        elif message.type==Gst.MessageType.WARNING:
            err,debug=message.parse_warning();event(camera,'camera_warning',epoch=index,message=err.message)
        elif message.type==Gst.MessageType.ELEMENT:
            st=message.get_structure()
            if st and st.get_name() in ('splitmuxsink-fragment-opened','splitmuxsink-fragment-closed'):
                location=st.get_value('location');running=st.get_value('running-time')
                if st.get_name().endswith('closed'):
                    original=pathlib.Path(location);final=original.with_suffix('')
                    if original.exists():original.replace(final)
                    item={'path':str(final.relative_to(session)),'bytes':final.stat().st_size if final.exists() else 0,'end_running_time_ns':running,**stamp()}
                    state['segments'].append(item);event(camera,'camera_segment_closed',epoch=index,**item)
                else:event(camera,'camera_segment_opened',epoch=index,path=str(pathlib.Path(location).relative_to(session)),running_time_ns=running)
        return message.type==Gst.MessageType.EOS
    try:
        if pipeline.set_state(Gst.State.PLAYING)==Gst.StateChangeReturn.FAILURE:raise RuntimeError('摄像头无法进入录像状态')
        event(camera,'camera_epoch_started',epoch=index,mode=mode,device=device)
        while True:
            now=time.monotonic()
            if STOP and not eos_sent:reason='manual_stop';pipeline.send_event(Gst.Event.new_eos());eos_sent=True;deadline=now+8
            reserve=int(config.get('reserve_disk_gib',10)*1024**3)
            if not eos_sent and shutil.disk_usage(session).free<=reserve+1024**3:
                reason='disk_reserve';pipeline.send_event(Gst.Event.new_eos());eos_sent=True;deadline=now+8
            if not eos_sent and not pathlib.Path(device).exists():
                reason='device_disconnected';error='摄像头已断开';pipeline.send_event(Gst.Event.new_eos());eos_sent=True;deadline=now+3
            current=snapshot_state()
            if not eos_sent and now-started>8 and (not current['last_host_monotonic_ns'] or time.monotonic_ns()-current['last_host_monotonic_ns']>5_000_000_000):
                reason='frame_timeout';error='摄像头连续 5 秒未提供帧';pipeline.send_event(Gst.Event.new_eos());eos_sent=True;deadline=now+3
            message=bus.timed_pop(200*Gst.MSECOND)
            if message and handle(message):break
            if deadline and now>=deadline:error=error or 'camera EOS finalization timeout';break
            if now-last_publish>=1:
                current=snapshot_state();elapsed=now-last_publish
                live={'state':'stopping' if eos_sent else 'recording','epoch':index,'mode':mode,'frames':total_before+current['frames'],
                    'epoch_frames':current['frames'],'fps':(current['frames']-last_frames)/elapsed,
                    'rate_mib_s':(current['encoded_bytes']-last_bytes)/elapsed/1024**2,
                    'encoded_bytes':current['encoded_bytes'],'total_bytes':bytes_before+current['encoded_bytes'],'complete_segments':segments_before+len(current['segments']),
                    'timestamp_regressions':current['timestamp_regressions'],'offset_gap_frames':current['offset_gap_frames'],
                    'reencoding':False,**stamp()}
                atomic(camera/'live.json',live);rows.flush();last_frames=current['frames'];last_bytes=current['encoded_bytes'];last_publish=now
    finally:
        pipeline.set_state(Gst.State.NULL)
        while True:
            message=bus.pop()
            if not message:break
            handle(message)
        rows.flush();rows.close()
    result=snapshot_state();result.update({'epoch':index,'mode':mode,'finished':stamp(),'stop_reason':reason,'error':error,
                                         'incomplete_files':[str(p.relative_to(session)) for p in raw.glob('*.part')]})
    span=(result['last_pts_ns']-result['first_pts_ns'])/1e9 if result['last_pts_ns'] is not None and result['first_pts_ns'] is not None else 0
    result['measured_fps']=(result['frames']-1)/span if span>0 else 0
    result['fps_shortfall']=span>=2 and result['measured_fps']<mode['fps']*.9
    result['completed_bytes']=sum(s['bytes'] for s in result['segments'])
    atomic(epoch/'result.json',result);return result

def supervise(root,session):
    from radar_stack.camera.config import inventory
    from radar_stack.camera.recovery import select_device,restore_epochs
    root=pathlib.Path(root);session=pathlib.Path(session);camera=session/'camera';camera.mkdir(exist_ok=True)
    config=read(session/'camera_config_snapshot.json');os.nice(5)
    lock=(root/'runtime/camera.lock').open('a+')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:
        event(camera,'camera_lock_busy');return 2
    results,index=restore_epochs(session)
    checkpoint=read(camera/'recovery_state.json');gaps=checkpoint.get('gaps',[]);gap_start=checkpoint.get('gap_start')
    identity=read(camera/'device_identity.json');attempt=checkpoint.get('reconnect_attempts',0)
    total_frames=sum(e.get('frames',0) for e in results);total_segments=sum(len(e.get('segments',[])) for e in results)
    last_error=None;reserve_stop=False;last_state=None;backoff=1
    if results and gap_start is None:
        prior=read(camera/'live.json');gap_start={k:prior[k] for k in ('monotonic_ns','unix_ns') if k in prior} or stamp()
    def persist():
        atomic(camera/'recovery_state.json',{'gaps':gaps,'gap_start':gap_start,'reconnect_attempts':attempt,'last_epoch':index})
    def publish(state,message,error=None,**extra):
        nonlocal last_state
        if state!=last_state:event(camera,'camera_recovery_state',state=state,message=message);last_state=state
        atomic(camera/'live.json',{'state':state,'status_message':message,'frames':total_frames,'complete_segments':total_segments,
            'total_bytes':sum(e.get('completed_bytes',0) for e in results),'fps':0,'rate_mib_s':0,'error':error,
            'reconnect_attempts':attempt,'device_detected':state not in ('waiting_for_device',),**extra,**stamp()})
    def pause(seconds):
        deadline=time.monotonic()+seconds
        while not STOP and time.monotonic()<deadline:time.sleep(min(.25,max(0,deadline-time.monotonic())))
    def first_frame(when):
        nonlocal gap_start,backoff,last_state
        if gap_start is not None:
            gaps.append({'start':gap_start,'end':when});gap_start=None
            event(camera,'camera_recovered',epoch=index,device=config['camera_device'],first_frame=when)
        backoff=1;last_state='recording';persist()
    event(camera,'camera_supervisor_started',device=config.get('camera_device'),resumed_epochs=len(results))
    persist()
    publish('starting','正在检测摄像头')
    while not STOP:
        if shutil.disk_usage(session).free<=int(config.get('reserve_disk_gib',10)*1024**3)+1024**3:reserve_stop=True;break
        try:
            devices=inventory(root)['devices'];selected=select_device(devices,config.get('camera_device',''),identity)
        except Exception as exc:
            selected=None;last_error=str(exc)
        if not selected:
            if gap_start is None:gap_start=stamp();persist()
            publish('waiting_for_device','系统尚未识别到所选摄像头；持续检测中，重新识别后自动续录到本次采集。请检查 USB 接线、集线器与供电。',last_error,detected_camera_count=len(devices) if 'devices' in locals() else 0)
            pause(2);continue
        if STOP:break
        if not identity:
            identity=selected.get('identity',{});atomic(camera/'device_identity.json',identity)
        newpath=selected['stable_path']
        if config.get('camera_device')!=newpath:event(camera,'camera_device_path_resolved',previous=config.get('camera_device'),device=newpath,identity=identity)
        config['camera_device']=newpath
        index+=1;attempt+=1;persist()
        publish('retrying','摄像头已识别，正在恢复录像；仍属于本次采集。',last_error,epoch=index)
        try:
            result=record_epoch(root,session,camera,config,index,total_frames,total_segments,sum(e.get('completed_bytes',0) for e in results),first_frame)
        except Exception as exc:
            last_error=str(exc);event(camera,'camera_epoch_failed',epoch=index,error=last_error)
            recovered,_=restore_epochs(session)
            result=next((e for e in recovered if e.get('epoch')==index),{'epoch':index,'frames':0,'segments':[],'completed_bytes':0,'incomplete_files':[]})
            result.update(error=last_error,stop_reason='open_or_pipeline_error')
            atomic(camera/'epochs'/f'epoch_{index:04d}'/'result.json',result)
        results.append(result);total_frames+=result.get('frames',0);total_segments+=len(result.get('segments',[]));last_error=result.get('error')
        if result.get('stop_reason')=='disk_reserve':reserve_stop=True;break
        if not STOP:
            if gap_start is None:gap_start=stamp()
            event(camera,'camera_reconnect_scheduled',previous_epoch=index,error=last_error,retry_after_s=backoff)
            persist();publish('retrying','录像中断，正在重新检测并恢复同一摄像头。',last_error)
            pause(backoff);backoff=min(10,backoff*2)
    if gap_start is not None:gaps.append({'start':gap_start,'end':stamp()});gap_start=None
    persist()
    incomplete=[str(p.relative_to(session)) for p in camera.rglob('*.part')]
    result={'schema':'nx-camera-result/v2','frames':total_frames,'complete_segments':total_segments,'epochs':results,'gaps':gaps,
            'completed_bytes':sum(e.get('completed_bytes',0) for e in results),'incomplete_files':incomplete,
            'stop_reason':'disk_reserve' if reserve_stop else 'manual_stop','last_error':last_error,'reconnect_attempts':attempt,
            'quality':'normal' if total_frames and not incomplete and not gaps and not any(e.get('error') or e.get('offset_gap_frames') or e.get('timestamp_regressions') or e.get('fps_shortfall') for e in results) else 'degraded',
            'finished':stamp(),'reencoding':False}
    atomic(camera/'result.json',result);atomic(camera/'live.json',{'state':'stopped',**result,'fps':0,'rate_mib_s':0,**stamp()})
    event(camera,'camera_supervisor_finished',frames=total_frames,quality=result['quality']);lock.close();return 0

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--root',required=True);parser.add_argument('--session',required=True);args=parser.parse_args()
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,stop)
    return supervise(args.root,args.session)

if __name__=='__main__':raise SystemExit(main())
