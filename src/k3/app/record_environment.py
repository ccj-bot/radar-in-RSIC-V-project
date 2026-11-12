from pathlib import Path
import hashlib,json,subprocess,platform,os
root=Path(__file__).resolve().parents[1]
files=[]
for directory in ['models','input','app']:
 for p in sorted((root/directory).glob('*')):
  if p.is_file():files.append({'file':str(p.relative_to(root)),'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
(root/'SOURCE_MANIFEST.json').write_text(json.dumps(files,indent=2))
packages=[]
for p in sorted((root/'runtime').rglob('*.deb')):
 fields={name:subprocess.check_output(['dpkg-deb','-f',str(p),name],text=True).strip() for name in ['Package','Version','Architecture']}
 packages.append({'deb':str(p.relative_to(root)),**fields,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
(root/'RUNTIME_PACKAGES.json').write_text(json.dumps(packages,indent=2))
summary={'model':Path('/proc/device-tree/model').read_bytes().rstrip(b'\0').decode(),'uname':platform.uname()._asdict(),'cpu_count':os.cpu_count(),'python':platform.python_version(),'os_release':Path('/etc/os-release').read_text(),'isolation':'All added binary/Python dependencies extracted under project/runtime. No apt install or upgrade performed.'}
(root/'environment.json').write_text(json.dumps(summary,indent=2))
print('PROJECT_FILES',len(files),'DEPENDENCY_ARCHIVES',len(packages))
