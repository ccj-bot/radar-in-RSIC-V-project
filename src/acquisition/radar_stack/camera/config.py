from __future__ import annotations
import json, pathlib, subprocess, time, os, tempfile

def read(path,default=None):
    try:return json.loads(pathlib.Path(path).read_text(encoding='utf-8'))
    except (OSError,ValueError):return {} if default is None else default

def atomic(path,data):
    path=pathlib.Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    fd,temp=tempfile.mkstemp(prefix=path.name+'.',suffix='.part',dir=path.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:json.dump(data,f,ensure_ascii=False,indent=2);f.write('\n')
        os.replace(temp,path)
    finally:
        if os.path.exists(temp):os.unlink(temp)

def settings(root):
    return {'radar_enabled':True,'camera_enabled':True,'camera_device':'','mode_id':'auto',
            'segment_seconds':10,'reserve_disk_gib':10,**read(pathlib.Path(root)/'config/acquisition.json')}

def mode_id(mode):return f"{mode['fourcc']}:{mode['width']}x{mode['height']}:{mode['fps_num']}/{mode['fps_den']}"

def supported(mode):return mode.get('fourcc') in ('MJPG','YUYV') and mode.get('fps',0)>0

def choose_mode(modes,wanted='auto'):
    options={mode_id(m):m for m in modes if supported(m)}
    if not options:raise ValueError('摄像头未提供可直接记录的 MJPEG 或 YUYV 模式')
    if wanted!='auto':
        if wanted not in options:raise ValueError('保存的摄像头模式当前不可用，请重新选择')
        selected=options[wanted]
    else:selected=max(options.values(),key=lambda m:(m['fps'],m['width']*m['height'],m['fourcc']=='MJPG'))
    return {**selected,'id':mode_id(selected)}

def probe_device(root,path,fixed_fps=False):
    command=[str(pathlib.Path(root)/'bin/camera_probe'),str(path)]+(['--fixed-fps'] if fixed_fps else [])
    result=subprocess.run(command,capture_output=True,text=True,timeout=4)
    if result.returncode:raise RuntimeError(result.stderr.strip() or '摄像头能力读取失败')
    info=json.loads(result.stdout)
    if not info['capture']:raise ValueError('此节点不是视频采集节点')
    from radar_stack.camera.recovery import usb_identity
    info['identity']=usb_identity(path)
    modes={mode_id(m):{**m,'id':mode_id(m)} for m in info['modes'] if supported(m)}
    info['modes']=sorted(modes.values(),key=lambda m:(m['fps'],m['width']*m['height'],m['fourcc']=='MJPG'),reverse=True)
    return info

def inventory(root):
    root=pathlib.Path(root);cfg=settings(root);devices=[];seen=set()
    candidates=sorted(pathlib.Path('/dev/v4l/by-id').glob('*'))
    candidates+=sorted(pathlib.Path('/dev/v4l/by-path').glob('*'))
    candidates+=sorted(pathlib.Path('/dev').glob('video*'))
    for path in candidates:
        target=str(path.resolve())
        if target in seen:continue
        seen.add(target)
        try:
            info=probe_device(root,path);info['stable_path']=str(path);info['resolved_path']=target
            devices.append(info)
        except (OSError,ValueError,subprocess.SubprocessError):continue
        except RuntimeError:continue
    selected=next((d for d in devices if d['stable_path']==cfg['camera_device']),None)
    if not cfg['camera_device'] and devices:selected=devices[0]
    result={'settings':cfg,'devices':devices,'selected':selected,'available':selected is not None,
            'checked_monotonic_ns':time.monotonic_ns(),'native_recording':True,'container':'Matroska / MKV'}
    if selected:
        try:result['selected_mode']=choose_mode(selected['modes'],cfg['mode_id'])
        except ValueError as exc:result['mode_error']=str(exc)
    return result

def save_settings(root,values):
    cfg=settings(root)
    for key in ('radar_enabled','camera_enabled'):
        if type(values.get(key)) is not bool:raise ValueError('采集通道开关必须是布尔值')
        cfg[key]=values[key]
    if not cfg['radar_enabled'] and not cfg['camera_enabled']:raise ValueError('至少选择一个采集通道')
    seconds=values.get('segment_seconds',10)
    if type(seconds) is not int or not 2<=seconds<=300:raise ValueError('视频分段时长应为 2–300 秒整数')
    cfg['segment_seconds']=seconds
    path=values.get('camera_device',cfg['camera_device'])
    if path and (not isinstance(path,str) or not path.startswith(('/dev/video','/dev/v4l/'))):raise ValueError('无效的摄像头路径')
    info=inventory(root);available={d['stable_path']:d for d in info['devices']}
    if path and path not in available and path!=cfg['camera_device']:raise ValueError('请选择检测到的摄像头')
    cfg['camera_device']=path or (info['selected']['stable_path'] if info['selected'] else '')
    wanted=values.get('mode_id','auto')
    if not isinstance(wanted,str):raise ValueError('无效视频模式')
    if cfg['camera_device'] in available:choose_mode(available[cfg['camera_device']]['modes'],wanted)
    elif wanted!='auto' and wanted!=cfg['mode_id']:raise ValueError('离线摄像头不能验证新的视频模式')
    cfg['mode_id']=wanted
    atomic(pathlib.Path(root)/'config/acquisition.json',cfg);return cfg
