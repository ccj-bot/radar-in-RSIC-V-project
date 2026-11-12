"""Loopback-only HTTP console. SSH handles remote authentication/encryption."""
import argparse, json, mimetypes, secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from radar_stack.web.state import Console, read_json
from radar_stack.capture.manager import capture_lock
from radar_stack.imaging.contract import completed_frames

class Handler(BaseHTTPRequestHandler):
    server_version='NXRadar/1'
    def log_message(self,*args):pass
    def send(self,code,data,kind='application/json; charset=utf-8'):
        content=json.dumps(data,ensure_ascii=False).encode() if isinstance(data,(dict,list)) else data
        self.send_response(code);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(content)))
        self.send_header('Cache-Control','no-store');self.send_header('X-Content-Type-Options','nosniff')
        self.send_header('Content-Security-Policy',"default-src 'self'; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        try:self.wfile.write(content)
        except (BrokenPipeError,ConnectionResetError):pass

    def check_origin(self,write=False):
        host=self.headers.get('Host',''); parsed=urlsplit('http://'+host)
        if parsed.hostname not in ('localhost','127.0.0.1','::1'):raise ValueError('不允许的访问地址')
        origin=self.headers.get('Origin')
        if origin and origin!='http://'+host:raise ValueError('来源校验失败，请从本机入口打开')
        if write and self.headers.get('X-Radar-Token')!=self.server.token:raise ValueError('页面已过期，请刷新后重试')

    def do_GET(self):
        try:
            self.check_origin();url=urlsplit(self.path);query=parse_qs(url.query);path=url.path;state=self.server.console
            if path=='/api/health':return self.send(200,{'service':'nx-radar-console','version':1})
            if path=='/api/bootstrap':return self.send(200,{'token':self.server.token})
            if path=='/api/status':return self.send(200,state.status())
            if path=='/api/history':return self.send(200,state.history(query.get('q',[''])[0],query.get('date',[''])[0]))
            if path=='/api/profile':return self.send(200,state.profile())
            if path=='/api/acquisition':return self.send(200,state.camera())
            if path.startswith('/api/imaging/'):
                parts=path.split('/');name=parts[3]
                from radar_stack.profiles.registry import _validate_name
                session=state.root/'sessions'/_validate_name(name)
                if len(parts)==5 and parts[4]=='frames':return self.send(200,completed_frames(session,int(query.get('start',['0'])[0]),int(query.get('limit',['100'])[0])))
                return self.send(200,read_json(session/'imaging_input.json',{'status':'legacy_session_no_contract'}))
            files={'/':'index.html','/app.js':'app.js','/style.css':'style.css'}
            if path not in files:return self.send(404,{'error':'未找到页面'})
            p=Path(__file__).parent/'static'/files[path]
            return self.send(200,p.read_bytes(),(mimetypes.guess_type(str(p))[0] or 'text/plain')+'; charset=utf-8')
        except Exception as exc:self.send(400,{'error':str(exc)})

    def do_POST(self):
        try:
            self.check_origin(True);length=int(self.headers.get('Content-Length','0'))
            if length<0 or length>16384:raise ValueError('请求过大')
            data=json.loads(self.rfile.read(length) or b'{}');state=self.server.console;path=urlsplit(self.path).path
            if path=='/api/start':result=state.begin(data.get('name',''),data.get('note',''))
            elif path=='/api/validate':result=state.begin(validate_only=True)
            elif path=='/api/stop':result=state.stop()
            elif path=='/api/acquisition/save':
                if not state.guard.acquire(False):raise ValueError('启动或验证过程中不能修改采集设置')
                try:result=state.save_acquisition(data)
                finally:state.guard.release()
            elif path in ('/api/profile/save','/api/profile/preview'):
                if not state.guard.acquire(False):raise ValueError('采集启动或验证中，暂不能修改配置')
                try:
                    with capture_lock(state.root):result=state.save_profile(data,preview=path.endswith('preview'))
                finally:state.guard.release()
            else:return self.send(404,{'error':'接口不存在'})
            self.send(200,result)
        except Exception as exc:self.send(409,{'error':str(exc)})

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--root',default='/home/ysy/nx_radar');parser.add_argument('--port',type=int,default=8088)
    args=parser.parse_args();server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    server.console=Console(args.root);server.token=secrets.token_urlsafe(32)
    print(f'NX radar console: http://127.0.0.1:{args.port}',flush=True)
    server.serve_forever()

if __name__=='__main__':main()
