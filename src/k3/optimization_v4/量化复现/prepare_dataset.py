from pathlib import Path
import json,hashlib
import numpy as np,cv2
from PIL import Image
W=Path(__file__).resolve().parent;DATA=Path(r'D:\profile\research\data\R35ZF_C\SARframes')
OUT=W/'calibration_real';OUT.mkdir(exist_ok=True)
def pre(path):
 im=np.asarray(Image.open(path).convert('RGB'));im=np.ascontiguousarray(np.rot90(im,-1));h,w=im.shape[:2];r=min(640/h,640/w);nw,nh=round(w*r),round(h*r);l,t=round((640-nw)/2-.1),round((640-nh)/2-.1)
 canvas=np.full((640,640,3),114,np.uint8);canvas[t:t+nh,l:l+nw]=cv2.resize(im,(nw,nh),interpolation=cv2.INTER_LINEAR)
 return np.ascontiguousarray(canvas.transpose(2,0,1)[None]).astype(np.float32)/255
records=[]
for role,indices in [('calibration',range(280,345,4)),('holdout',range(350,401,5))]:
 for i in indices:
  if i in (358,378):continue
  p=DATA/f'VP_RM_IMG_SAR_S000032_F{i:05d}.bmp'
  if not p.exists():continue
  x=pre(p);target=OUT/(p.stem+'.npy');np.save(target,x)
  records.append({'role':role,'source':str(p),'source_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'input':target.name,'frame':i})
for role in ['calibration','holdout']:(OUT/(role+'.txt')).write_text('\n'.join(r['input'] for r in records if r['role']==role),encoding='utf8')
(OUT/'manifest.json').write_text(json.dumps({'dataset':'R35ZF_C SARframes original BMP','processing':'clockwise90 RGB uint8 OpenCV letterbox640 padding114 float32 /255','partition':'temporal range split; unlabelled feasibility, not an independent-scene accuracy test','records':records},indent=2),encoding='utf8')
print({role:sum(r['role']==role for r in records) for role in ['calibration','holdout']})
