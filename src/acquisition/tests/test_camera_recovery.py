import csv,json,pathlib,tempfile,unittest
from types import SimpleNamespace
from unittest.mock import patch
from radar_stack.camera.config import atomic,read
from radar_stack.camera.recovery import select_device,restore_epochs,RecorderGuard

IDENTITY={'vendor':'09da','product':'2700','serial':'camera-a'}
def device(path,serial='camera-a'):
    return {'stable_path':path,'resolved_path':'/dev/video4','identity':dict(IDENTITY,serial=serial),'modes':[]}

class IdentityRecovery(unittest.TestCase):
    def test_changed_node_same_device(self):
        d=device('/dev/v4l/by-id/new-name')
        self.assertIs(select_device([d],'/dev/video0',IDENTITY),d)
    def test_unrelated_camera_is_not_selected(self):
        self.assertIsNone(select_device([device('/dev/v4l/by-id/other','other')],'/dev/video0',IDENTITY))
    def test_duplicate_serial_is_ambiguous(self):
        self.assertIsNone(select_device([device('/dev/video2'),device('/dev/video4')],'/dev/video0',IDENTITY))
    def test_no_serial_does_not_match_changed_path(self):
        self.assertIsNone(select_device([device('/dev/video4','')],'/dev/video0',dict(IDENTITY,serial='')))

class CrashRecovery(unittest.TestCase):
    def test_unfinished_epoch_retains_files_and_counts_persisted_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            s=pathlib.Path(tmp);e=s/'camera/epochs/epoch_0007';(e/'segments').mkdir(parents=True)
            complete=e/'segments/segment_000000.mkv';complete.write_bytes(b'completed')
            partial=e/'segments/segment_000001.mkv.part';partial.write_bytes(b'partial')
            (e/'frames.csv').write_text('encoded_bytes,host_probe_monotonic_ns\n50,100\n60,200\n')
            records,index=restore_epochs(s)
            self.assertEqual(index,7);self.assertEqual(records[0]['frames'],2)
            self.assertEqual(records[0]['completed_bytes'],9)
            self.assertTrue(records[0]['recovered_after_worker_exit'])
            self.assertEqual(complete.read_bytes(),b'completed');self.assertEqual(partial.read_bytes(),b'partial')
            self.assertEqual(len(records[0]['incomplete_files']),1)
            again,_=restore_epochs(s);self.assertEqual(records,again)

class ProcessGuardTests(unittest.TestCase):
    def test_stall_escalates_before_any_restart(self):
        g=RecorderGuard(100)
        self.assertEqual(g.assess(True,{},119),'healthy')
        self.assertEqual(g.assess(True,{},121),'terminate')
        self.assertEqual(g.assess(True,{},125),'waiting_for_exit')
        self.assertEqual(g.assess(True,{},130),'kill')
        self.assertEqual(g.assess(True,{},160),'kill') # Never start a second live recorder.
        self.assertEqual(g.assess(False,{},161),'schedule_restart')
        self.assertEqual(g.assess(False,{},162),'waiting_restart')
        self.assertEqual(g.assess(False,{},163),'restart')
        g.started(163);self.assertEqual(g.assess(True,{},164),'healthy')
    def test_waiting_device_heartbeat_prevents_restarts(self):
        g=RecorderGuard(0)
        for t in (100,500,1000):
            self.assertEqual(g.assess(True,{'state':'waiting_for_device','monotonic_ns':t*10**9},t+.5),'healthy')
    def test_backoff_is_bounded(self):
        g=RecorderGuard(0)
        for attempt in range(10):
            now=attempt*100
            self.assertEqual(g.assess(False,{},now),'schedule_restart')
            self.assertLessEqual(g.restart_at-now,10)
            g.started(now+20)

class SupervisorRecovery(unittest.TestCase):
    def simulate(self,first_open_fails=False):
        from radar_stack.camera import worker
        with tempfile.TemporaryDirectory() as tmp:
            r=pathlib.Path(tmp);s=r/'sessions/same-session';(r/'runtime').mkdir();(s/'camera/epochs/epoch_0001/segments').mkdir(parents=True)
            old=s/'camera/epochs/epoch_0001/segments/segment_000000.mkv';old.write_bytes(b'old-video')
            atomic(s/'camera_config_snapshot.json',{'camera_device':'/dev/video0','mode_id':'auto','segment_seconds':10,'reserve_disk_gib':10})
            atomic(s/'camera/device_identity.json',IDENTITY)
            atomic(s/'camera/epochs/epoch_0001/result.json',{'epoch':1,'frames':10,'segments':[{'path':str(old.relative_to(s)),'bytes':9}],'completed_bytes':9})
            clock=[100.0];calls=[]
            def sleep(n):clock[0]+=n
            fake_time=SimpleNamespace(monotonic=lambda:clock[0],monotonic_ns=lambda:int(clock[0]*1e9),time_ns=lambda:int((clock[0]+1000)*1e9),sleep=sleep)
            def record(root,session,camera,cfg,index,frames,segments,byte_count,on_first):
                calls.append((str(session),cfg['camera_device'],index,frames,segments,byte_count))
                if first_open_fails and len(calls)==1:raise RuntimeError('temporary open failure')
                on_first(worker.stamp());worker.STOP=True
                dest=camera/'epochs'/f'epoch_{index:04d}'/'segments';dest.mkdir(parents=True)
                (dest/'segment_000000.mkv').write_bytes(b'new-video')
                result={'epoch':index,'frames':4,'segments':[{'path':str((dest/'segment_000000.mkv').relative_to(session)),'bytes':9}],'completed_bytes':9,'error':None,'stop_reason':'manual_stop'}
                atomic(dest.parent/'result.json',result);return result
            available={'devices':[device('/dev/v4l/by-id/reconnected')]}
            responses=[{'devices':[]},available,available]
            worker.STOP=False
            try:
                with patch.object(worker,'time',fake_time),patch.object(worker.os,'nice'),patch.object(worker.shutil,'disk_usage',return_value=SimpleNamespace(free=2**40)),patch('radar_stack.camera.config.inventory',side_effect=responses),patch.object(worker,'record_epoch',side_effect=record):
                    self.assertEqual(worker.supervise(r,s),0)
                result=read(s/'camera/result.json');events=[json.loads(line) for line in (s/'camera/events.jsonl').read_text().splitlines()]
                self.assertEqual(old.read_bytes(),b'old-video');self.assertEqual(result['frames'],14);self.assertEqual(result['complete_segments'],2)
                self.assertTrue(result['gaps']);self.assertTrue(any(e['event']=='camera_recovered' for e in events))
                self.assertTrue(all(c[0]==str(s) for c in calls));self.assertEqual(calls[-1][1],'/dev/v4l/by-id/reconnected')
                self.assertEqual(calls[-1][2],3 if first_open_fails else 2)
            finally:worker.STOP=False
    def test_missing_then_returning_camera_stays_in_same_session(self):self.simulate()
    def test_temporary_open_error_retries_without_losing_old_video(self):self.simulate(True)

class CoordinatorRecovery(unittest.TestCase):
    def test_dead_camera_restarts_in_same_batch_and_stops_cleanly(self):
        from radar_stack.acquisition import worker
        with tempfile.TemporaryDirectory() as tmp:
            r=pathlib.Path(tmp);(r/'config').mkdir();(r/'sessions').mkdir();(r/'runtime').mkdir();(r/'config/station.yaml').write_text('{}')
            config=r/'launch.json';atomic(config,{'radar_enabled':False,'camera_enabled':True,'label':'simulation','note':'no hardware','reserve_disk_gib':10})
            clock=[10.0];children=[];sessions=[]
            class Child:
                def __init__(self,args):
                    self.pid=20000+len(children);self.returncode=70 if not children else None
                    self.session=pathlib.Path(args[args.index('--session')+1]);sessions.append(self.session)
                def poll(self):return self.returncode
                def send_signal(self,sig):
                    self.returncode=0;atomic(self.session/'camera/result.json',{'frames':4,'quality':'degraded','completed_bytes':8,'finished':{'monotonic_ns':int(clock[0]*1e9)}})
                def kill(self):self.returncode=-9
                def wait(self,timeout):return self.returncode
            def spawn(args,**kwargs):
                p=Child(args);children.append(p);return p
            def sleep(n):
                clock[0]+=n
                if len(children)>=2:worker.STOP=True
            fake_time=SimpleNamespace(monotonic=lambda:clock[0],monotonic_ns=lambda:int(clock[0]*1e9),time_ns=lambda:int((clock[0]+1000)*1e9),sleep=sleep)
            worker.STOP=False
            try:
                with patch.object(worker,'time',fake_time),patch.object(worker,'capture_status',return_value={'active':False}),patch.object(worker.subprocess,'Popen',side_effect=spawn),patch.object(worker.shutil,'disk_usage',return_value=SimpleNamespace(free=2**40)):
                    self.assertEqual(worker.run(r,config),0)
                self.assertEqual(len(children),2);self.assertEqual(sessions[0],sessions[1]);self.assertEqual(children[1].returncode,0)
                events=[json.loads(line) for line in (sessions[0]/'sync/events.jsonl').read_text().splitlines()]
                self.assertTrue(any(e['event']=='camera_worker_restarted' for e in events))
                self.assertFalse((r/'runtime/active_batch.json').exists())
            finally:worker.STOP=False

if __name__=='__main__':unittest.main()
