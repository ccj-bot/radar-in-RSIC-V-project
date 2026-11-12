import csv, json, os, pathlib, shutil, signal, socket, struct, subprocess, tempfile, threading, time, unittest
import sys
from contextlib import ExitStack
from types import SimpleNamespace
from unittest import mock
from radar_stack.profiles.plan import build_capture_plan, FormError
from radar_stack.profiles.sync import sync_profile
from radar_stack.profiles.registry import _atomic_json, select_profile
from radar_stack.capture.manager import capture_lock, _pid_is_running
from radar_stack.imaging.contract import write_contract, completed_frames
from radar_stack.web.state import Console

ROOT=pathlib.Path(__file__).resolve().parents[1]

class ContinuousPolicy(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name)
        (self.root/'config/profiles/saved').mkdir(parents=True);(self.root/'sessions').mkdir()
        form=json.loads((ROOT/'config/profiles/saved/s30-uniform.json').read_text())
        for k in ('radar_config_template','dca_config_template'):
            rel=form['fields'][k]['value'];dest=self.root/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/rel,dest)
        (self.root/'config/station.yaml').write_text((ROOT/'config/station.yaml').read_text())
        self.form=form
        for k,v in {'capture_mode':'manual_until_disk_reserve','stop_after_gib':0,'reserve_disk_gib':1,'radar_target_frame_blank_time_ms':0.3}.items():form['fields'][k]['value']=v
        _atomic_json(self.root/'config/profiles/saved/s30-uniform.json',form)
        sync_profile(self.root,'s30-uniform');select_profile(self.root,'s30-uniform')
    def tearDown(self):self.temp.cleanup()
    def plan(self):return build_capture_plan(self.root/'config/profiles/saved/s30-uniform.json',project_root=self.root)
    def test_continuous_not_50g_and_quantized_blank(self):
        p=self.plan();d=p['derived'];self.assertEqual(d['stop_policy'],'manual_or_disk_reserve');self.assertGreater(d['receiver_max_bytes'],50*1024**3)
        self.assertIsNone(d['stop_after_gib_requested']);self.assertGreaterEqual(d['timing_model']['frame_blank_time_ms'],0.3)
        self.assertFalse(d['timing_model']['multi_frame_uniform_fft_safe'])
    def test_reserve_and_invalid_rates(self):
        console=Console(self.root);before=(self.root/'config/active_profile.json').read_bytes()
        values=console.profile()['parameters'];values['fps']=100
        with self.assertRaises(ValueError):console.save_profile(values)
        self.assertEqual(before,(self.root/'config/active_profile.json').read_bytes())
        values['fps']=30;values['reserve_gib']=0
        with self.assertRaises(ValueError):console.save_profile(values)
    def test_preview_does_not_change_active_profile(self):
        console=Console(self.root);values=console.profile()['parameters'];before=(self.root/'config/active_profile.json').read_bytes()
        result=console.save_profile(values,preview=True);self.assertIn('timing',result)
        self.assertEqual(before,(self.root/'config/active_profile.json').read_bytes())
    def test_frame_feed_skips_part_and_rejects_wrong_size(self):
        s=self.root/'sessions/test';raw=s/'radar/raw_segments';raw.mkdir(parents=True)
        p=self.plan();_atomic_json(s/'capture_plan.json',p);write_contract(s)
        size=p['derived']['physical_segment_full_bytes'];(raw/'segment_0.bin').write_bytes(b'\0'*size)
        (raw/'segment_1.bin.part').write_bytes(b'\0'*30)
        self.assertEqual(len(completed_frames(s)['frames']),1)
        (raw/'segment_1.bin').write_bytes(b'wrong')
        with self.assertRaises(ValueError):completed_frames(s)
    def test_lock_excludes_concurrent_launch(self):
        with capture_lock(self.root):
            with self.assertRaises(RuntimeError):
                with capture_lock(self.root):pass
        self.assertFalse(_pid_is_running(os.getpid()))
    def test_history_never_needs_raw_content(self):
        s=self.root/'sessions'/'20261020T120000__example';s.mkdir()
        _atomic_json(s/'session_manifest.json',{'session_name':'sample','prepared_at':'2026-10-20T04:00:00+00:00','status':'capture_stopped'})
        _atomic_json(s/'capture_result.json',{'started_at':'2026-10-20T04:00:00+00:00','finished_at':'2026-10-20T04:00:10+00:00','stop_reason':'disk_reserve','quality':{'written_bytes':4096,'segment_bytes':2048}})
        rows=Console(self.root).history()['items'];self.assertEqual(rows[0]['bin_count'],2);self.assertEqual(rows[0]['duration_s'],10)
    def test_camera_only_history_with_null_profile(self):
        s=self.root/'sessions'/'camera-only';(s/'camera').mkdir(parents=True)
        _atomic_json(s/'session_manifest.json',{'session_name':'camera','active_profile':None,'prepared_at':'2026-10-21T04:00:00+00:00','status':'capture_stopped'})
        _atomic_json(s/'camera/result.json',{'frames':120,'complete_segments':2,'completed_bytes':12345,'quality':'normal'})
        rows=Console(self.root).history(query='camera')['items']
        self.assertEqual(rows[0]['camera_frames'],120);self.assertEqual(rows[0]['bytes'],12345)
    def test_devpack_capture_does_not_require_xds110_debug_uart(self):
        original=pathlib.Path.read_text
        def read_text(path,*args,**kwargs):
            if str(path).endswith('/speed'):return '1000'
            return original(path,*args,**kwargs)
        station=json.loads((self.root/'config/station.yaml').read_text())
        def command(args,**kwargs):
            return SimpleNamespace(stdout='0451:fd03 AR-DevPack-EVM-012' if args[0]=='lsusb' else station['network']['nx_ip'])
        with mock.patch('radar_stack.web.state.subprocess.run',side_effect=command),mock.patch.object(pathlib.Path,'read_text',read_text):
            result=Console(self.root).hardware()
        self.assertTrue(result['ready'],result);self.assertFalse(result['usb_interfaces']['ti_xds110'])
    def test_xds110_alone_does_not_replace_ftdi_control(self):
        original=pathlib.Path.read_text
        def read_text(path,*args,**kwargs):
            if str(path).endswith('/speed'):return '1000'
            return original(path,*args,**kwargs)
        station=json.loads((self.root/'config/station.yaml').read_text())
        def command(args,**kwargs):
            return SimpleNamespace(stdout='0451:bef3 XDS110' if args[0]=='lsusb' else station['network']['nx_ip'])
        with mock.patch('radar_stack.web.state.subprocess.run',side_effect=command),mock.patch.object(pathlib.Path,'read_text',read_text):
            result=Console(self.root).hardware()
        self.assertFalse(result['ready']);self.assertFalse(result['usb_interfaces']['ftdi_control'])

class ReceiverIntegration(unittest.TestCase):
    def run_receiver(self,mode):
        with tempfile.TemporaryDirectory() as tmp:
            session=pathlib.Path(tmp);src=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);src.bind(('127.0.0.1',0))
            probe=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);probe.bind(('127.0.0.1',0));port=probe.getsockname()[1];probe.close()
            segment=16384;cmd=[str(ROOT/'bin/dca_segment_receiver'),'--bind-ip','127.0.0.1','--source-ip','127.0.0.1','--port',str(port),'--source-port',str(src.getsockname()[1]),'--session',tmp,'--chirp-bytes','1024','--segment-bytes',str(segment),'--max-bytes',str(segment*(4 if mode=='capacity' else 100000)),'--queue-packets','4096','--reorder-window','64','--idle-timeout-ms','800']
            if mode=='disk':cmd+=['--reserve-bytes','1','--disk-guard-bytes',str(2**62)]
            process=subprocess.Popen(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                time.sleep(.15);seq=1;count=0;started=time.monotonic();live_seen=False;signal_sent=False
                while process.poll() is None and time.monotonic()-started<5:
                    elapsed=time.monotonic()-started
                    if mode=='manual' and elapsed>1.2 and not signal_sent:process.send_signal(signal.SIGINT);signal_sent=True
                    if mode!='timeout':
                        if mode=='gap' and seq==15:count+=1456*100;seq+=100
                        src.sendto(struct.pack('<I',seq)+count.to_bytes(6,'little')+bytes([seq%256])*1456,('127.0.0.1',port));seq+=1;count+=1456
                    if (session/'radar/receiver_live.json').exists():
                        live=json.loads((session/'radar/receiver_live.json').read_text());live_seen=True;self.assertIn('updated_unix_ms',live)
                    time.sleep(.003)
                stdout,stderr=process.communicate(timeout=3)
                q=json.loads((session/'radar/radar_quality_summary.json').read_text())
                bins=list((session/'radar/raw_segments').glob('*.bin'))
                self.assertTrue(all(p.stat().st_size==segment for p in bins))
                if mode in ('capacity','manual','disk'):
                    self.assertEqual(process.returncode,0,(stdout,stderr,q));self.assertGreater(len(bins),0)
                    self.assertEqual(q['written_bytes'],len(bins)*segment)
                    self.assertFalse(list((session/'radar/raw_segments').glob('*.part')))
                    with (session/'radar/radar_segments.csv').open() as f:
                        records=list(csv.DictReader(f))
                    self.assertEqual(len(records),len(bins))
                    for row in records:
                        self.assertGreater(int(row['first_receive_monotonic_ns']),0)
                        self.assertGreaterEqual(int(row['last_receive_monotonic_ns']),int(row['first_receive_monotonic_ns']))
                if mode=='disk':self.assertEqual(q['status'],'disk_reserve_stop')
                if mode=='manual':self.assertEqual(q['status'],'manual_boundary_stop');self.assertTrue(live_seen)
                if mode in ('gap','timeout'):self.assertNotEqual(process.returncode,0);self.assertTrue(q['error'])
                return q
            finally:
                if process.poll() is None:process.kill();process.wait()
                src.close()
    def test_capacity(self):self.run_receiver('capacity')
    def test_manual_boundary_and_live(self):self.run_receiver('manual')
    def test_disk_reserve_boundary(self):self.run_receiver('disk')
    def test_packet_gap(self):self.run_receiver('gap')
    def test_stream_timeout(self):self.run_receiver('timeout')

class CaptureWorkerFinalization(unittest.TestCase):
    def simulate(self, receiver_rc=0, disk_stop=False):
        from radar_stack.capture import worker
        with tempfile.TemporaryDirectory() as temp, ExitStack() as patches:
            root=pathlib.Path(temp);session=root/'sessions/test'
            (session/'radar').mkdir(parents=True);(session/'logs').mkdir()
            radar=session/'radar.cfg';radar.write_text('fake');dca=session/'dca.json';dca.write_text('{}')
            derived={'capture_mode':'manual_until_disk_reserve','bytes_per_chirp':1024,'physical_segment_full_bytes':16384,
                'total_expected_bytes':65536,'receiver_max_bytes':2**60,'reserve_disk_gib':1,'disk_stop_guard_bytes':1024,
                'stop_after_gib_requested':None}
            network={'dca_data_source_port':1024,'dca_data_source_port_verified':True,'interface':'fake0',
                'nx_ip':'127.0.0.1','dca_ip':'127.0.0.2','data_port':4098,'config_port':4096,'dca_config':str(dca)}
            _atomic_json(session/'capture_plan.json',{'derived':derived});_atomic_json(session/'station_config_snapshot.yaml',{'network':network})
            _atomic_json(session/'profile_form_snapshot.json',{'fields':{'radar_config':{'value':str(radar)},'dca_config':{'value':str(dca)}}})
            _atomic_json(session/'session_manifest.json',{'status':'prepared_no_hardware_started'})
            _atomic_json(session/'radar/radar_quality_summary.json',{'status':'manual_boundary_stop','written_bytes':16384})
            class Receiver:
                pid=4321
                returncode=None
                def poll(self):return self.returncode
                def send_signal(self,sig):_atomic_json(session/'radar/boundary_stop_ready.json',{'status':'complete_segment_closed','complete_segments':1})
                def wait(self,timeout):self.returncode=receiver_rc;return receiver_rc
                def terminate(self):self.returncode=receiver_rc
            def start_sensor():worker.STOP_REQUESTED=not disk_stop;return 0
            fake=SimpleNamespace(AWR2243_init=lambda path:0,AWR2243_setFrameCfg=lambda n:0,AWR2243_sensorStart=start_sensor,
                AWR2243_sensorStop=lambda:0,AWR2243_poweroff=lambda:0)
            patches.enter_context(mock.patch.dict(sys.modules,{'fpga_udp':fake}))
            for name in ('reset_dca_target','configure_dca_capture','start_dca_stream','stop_dca_stream','probe_dca'):
                patches.enter_context(mock.patch.object(worker,name,return_value={'ok':True}))
            patches.enter_context(mock.patch.object(worker,'snapshot_host',return_value={}))
            patches.enter_context(mock.patch.object(worker,'evidence_delta',return_value={'transport_clean':True,'transport_faults':[]}))
            patches.enter_context(mock.patch.object(worker.subprocess,'Popen',return_value=Receiver()))
            patches.enter_context(mock.patch.object(worker.time,'sleep',return_value=None))
            patches.enter_context(mock.patch.object(worker.shutil,'disk_usage',return_value=SimpleNamespace(free=1 if disk_stop else 2**40)))
            worker.STOP_REQUESTED=False
            try:code=worker.run(root,session)
            finally:worker.STOP_REQUESTED=False
            return code,json.loads((session/'capture_result.json').read_text()),json.loads((session/'session_manifest.json').read_text())
    def test_manual_stop_finalizes_after_sensor_stop(self):
        code,result,manifest=self.simulate();self.assertEqual(code,0);self.assertEqual(manifest['status'],'capture_stopped');self.assertTrue(result['quality_gate']['passed'])
    def test_receiver_failure_is_not_masked_by_successful_sensor_stop(self):
        code,result,manifest=self.simulate(receiver_rc=2);self.assertEqual(code,2);self.assertEqual(manifest['status'],'capture_failed');self.assertIn('receiver exited',result['error'])
    def test_worker_disk_guard_requests_boundary_stop(self):
        code,result,manifest=self.simulate(disk_stop=True);self.assertEqual(code,0);self.assertEqual(result['stop_reason'],'disk_reserve');self.assertIn('boundary_stop_ready',result)

if __name__=='__main__':unittest.main()
