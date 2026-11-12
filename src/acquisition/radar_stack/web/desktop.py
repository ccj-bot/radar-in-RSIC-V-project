"""Native GTK/WebKit viewer for the acquisition console on the NX display."""
from __future__ import annotations
import argparse
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import subprocess
import time
import urllib.request

URL = 'http://127.0.0.1:8088'

def ensure_service():
    env = dict(os.environ)
    env.setdefault('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
    env.setdefault('DBUS_SESSION_BUS_ADDRESS', f"unix:path={env['XDG_RUNTIME_DIR']}/bus")
    result = subprocess.run(['systemctl', '--user', 'start', 'nx-radar-ui.service'],
                            env=env, capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError('采集后台启动失败：' + result.stderr.strip())
    for _ in range(20):
        try:
            with urllib.request.urlopen(URL + '/api/health', timeout=1) as response:
                if json.load(response).get('service') == 'nx-radar-console':
                    return
        except (OSError, ValueError):
            time.sleep(.2)
    raise RuntimeError('采集后台没有回应，请查看 logs/desktop_ui.log')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default='/home/ysy/nx_radar')
    parser.add_argument('--diagnostics')
    parser.add_argument('--snapshot')
    args = parser.parse_args()
    log_path = Path(args.root) / 'logs' / 'desktop_ui.log'
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s',
                        handlers=[RotatingFileHandler(log_path, maxBytes=2_000_000, backupCount=2, encoding='utf-8')])
    import gi
    gi.require_version('Gtk', '3.0')
    gi.require_version('WebKit2', '4.0')
    from gi.repository import Gtk, Gdk, Gio, GLib, WebKit2

    class Viewer(Gtk.Application):
        def __init__(self):
            super().__init__(application_id='org.nxradar.Acquisition', flags=Gio.ApplicationFlags.FLAGS_NONE)
            self.window = None
            self.view = None
            self.started_diagnostics = False
            self.evidence = {'schema': 'nx-radar-desktop-check/v1', 'checks': []}

        def do_activate(self):
            if self.window:
                self.window.present()
                return
            self.window = Gtk.ApplicationWindow(application=self)
            self.window.set_title('NX 雷达采集')
            display = Gdk.Display.get_default()
            monitor = display.get_primary_monitor() or display.get_monitor(0)
            area = monitor.get_workarea()
            self.window.set_default_size(min(1280, max(700, area.width - 80)), min(900, max(600, area.height - 100)))
            self.window.connect('destroy', self.closed)
            header = Gtk.HeaderBar(title='NX 雷达采集', subtitle='关闭窗口不会停止采集')
            header.set_show_close_button(True)
            reload_button = Gtk.Button.new_from_icon_name('view-refresh-symbolic', Gtk.IconSize.BUTTON)
            reload_button.set_tooltip_text('刷新采集页面')
            reload_button.connect('clicked', lambda button: self.view.reload() if self.view else None)
            header.pack_end(reload_button)
            self.window.set_titlebar(header)
            self.view = WebKit2.WebView()
            self.view.get_settings().set_hardware_acceleration_policy(WebKit2.HardwareAccelerationPolicy.NEVER)
            self.view.connect('load-failed', self.load_failed)
            self.view.connect('load-changed', self.loaded)
            self.window.add(self.view)
            self.window.show_all()
            try:
                ensure_service()
                self.view.load_uri(URL)
                logging.info('Desktop viewer opened display=%s url=%s', os.environ.get('DISPLAY'), URL)
            except Exception as exc:
                logging.exception('Desktop startup failed')
                self.error_dialog(str(exc))

        def closed(self, widget):
            logging.info('Desktop window closed; capture service remains independent')
            self.window = None
            self.quit()

        def error_dialog(self, message):
            dialog = Gtk.MessageDialog(transient_for=self.window, modal=True,
                message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE,
                text='无法打开雷达采集界面')
            dialog.format_secondary_text(message)
            dialog.run()
            dialog.destroy()

        def load_failed(self, view, event, uri, error):
            logging.error('Page load failed: %s: %s', uri, error.message)
            self.error_dialog(error.message + '\n可以点击窗口右上方的刷新按钮重试。')
            return True

        def loaded(self, view, event):
            if event == WebKit2.LoadEvent.FINISHED and args.diagnostics and not self.started_diagnostics:
                self.started_diagnostics = True
                self.attempts = 0
                GLib.timeout_add(1000, self.check_capture)

        def evaluate(self, script, callback):
            def done(view, result, data=None):
                try:
                    value = view.run_javascript_finish(result).get_js_value().to_string()
                    callback(json.loads(value))
                except Exception as exc:
                    self.evidence['error'] = str(exc)
                    self.save_evidence()
                    logging.exception('Desktop page verification failed')
            self.view.run_javascript(script, None, done, None)

        def check_capture(self):
            self.attempts += 1
            def checked(data):
                if data.get('connection') != '已连接 NX' and self.attempts < 15:
                    GLib.timeout_add(1000, self.check_capture)
                    return
                self.evidence['checks'].append({'page': 'capture', **data})
                self.view.run_javascript("document.querySelector('.nav[data-page=\"settings\"]').click(); document.getElementById('preview').click();", None, None, None)
                GLib.timeout_add(1500, self.check_settings)
            self.evaluate("JSON.stringify({connection:document.getElementById('connection-text')?.textContent,status:document.getElementById('capture-pill')?.textContent,issues:document.getElementById('hardware-issues')?.textContent,profile:document.getElementById('profile-name')?.textContent})", checked)
            return False

        def check_settings(self):
            def checked(data):
                self.evidence['checks'].append({'page': 'settings', **data})
                self.view.run_javascript("document.querySelector('.nav[data-page=\"history\"]').click();", None, None, None)
                GLib.timeout_add(1500, self.check_history)
            self.evaluate("JSON.stringify({result:document.getElementById('parameter-result')?.textContent,fps:document.querySelector('input[name=fps]')?.value,notice:document.getElementById('notice')?.textContent})", checked)
            return False

        def check_history(self):
            def checked(data):
                self.evidence['checks'].append({'page': 'history', **data})
                self.evidence['passed'] = (self.evidence['checks'][0].get('connection') == '已连接 NX'
                    and self.evidence['checks'][1].get('result') == '计算完成，尚未保存。'
                    and data.get('rows', 0) > 0)
                self.view.run_javascript("document.querySelector('.nav[data-page=\"capture\"]').click();", None, None, None)
                self.save_evidence()
                if args.snapshot:
                    GLib.timeout_add(750, self.snapshot)
                logging.info('Desktop page verification passed=%s', self.evidence['passed'])
            self.evaluate("JSON.stringify({rows:document.querySelectorAll('#records tr').length,count:document.getElementById('record-count')?.textContent})", checked)
            return False

        def save_evidence(self):
            if args.diagnostics:
                Path(args.diagnostics).write_text(json.dumps(self.evidence, ensure_ascii=False, indent=2), encoding='utf-8')

        def snapshot(self):
            def captured(view, result, data=None):
                try:
                    surface = view.get_snapshot_finish(result)
                    surface.write_to_png(args.snapshot)
                    self.evidence['snapshot'] = args.snapshot
                except Exception as exc:
                    self.evidence['snapshot_error'] = str(exc)
                    logging.exception('Desktop snapshot failed')
                self.save_evidence()
            self.view.get_snapshot(WebKit2.SnapshotRegion.VISIBLE, WebKit2.SnapshotOptions.NONE, None, captured, None)
            return False

    app = Viewer()
    return app.run([])

if __name__ == '__main__':
    raise SystemExit(main())
