"""Portable SAR ONNX detection: Pillow/NumPy I/O, polygon NMS, timed inference."""
from pathlib import Path
import argparse, csv, hashlib, json, math, time, platform, ctypes
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parents[1]
import sys
sys.path[:0]=[str(ROOT/'app'),str(ROOT/'optimization_v3/app')]
COMPACT_NAMES=['tree','manhole','bench','hydrant','trunk','bike','light','person','walker','roadblock','handrail','rider','tricycle','bush','bin','guidepost','car','fence','stair','building']
XU_NAMES=['person','car','bike','bush','hydrant','handrail','building','light','tree']
MODELS={'yolo11-int8-native':'../optimization_v4/models/yolo11_int8_percentile.onnx'}
RESIZE_BACKEND='opencv'
RESIZE_LIB=None

def preprocess(image,rotation=90,size=640):
    codes={90:Image.Transpose.ROTATE_270,180:Image.Transpose.ROTATE_180,270:Image.Transpose.ROTATE_90}
    work=image.transpose(codes[rotation]) if rotation else image
    w,h=work.size;ratio=min(size/h,size/w);nw,nh=round(w*ratio),round(h*ratio)
    left,top=round((size-nw)/2-.1),round((size-nh)/2-.1)
    if RESIZE_BACKEND=='pillow':resized=work.resize((nw,nh),Image.Resampling.BILINEAR)
    else:
        global RESIZE_LIB
        pixels=np.ascontiguousarray(np.asarray(work));target=np.empty((nh,nw,3),np.uint8)
        libpath=ROOT/'app/libresize_cv.so'
        if libpath.exists():
            if RESIZE_LIB is None:
                RESIZE_LIB=ctypes.CDLL(str(libpath));RESIZE_LIB.resize_linear_rgb.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.c_void_p,ctypes.c_int,ctypes.c_int];RESIZE_LIB.resize_linear_rgb.restype=ctypes.c_int
            status=RESIZE_LIB.resize_linear_rgb(pixels.ctypes.data,h,w,target.ctypes.data,nh,nw)
            if status:raise RuntimeError('OpenCV resize failed')
        else:
            import cv2
            target=cv2.resize(pixels,(nw,nh),interpolation=cv2.INTER_LINEAR)
        resized=Image.fromarray(target)
    padded=Image.new('RGB',(size,size),(114,114,114));padded.paste(resized,(left,top))
    data=np.ascontiguousarray(np.asarray(padded).transpose(2,0,1)[None]).astype(np.float32)/255
    return data,(ratio,left,top)

def polygon(cx,cy,w,h,theta):
    c,s=math.cos(theta),math.sin(theta);center=np.array([cx,cy]);v1=np.array([w*c/2,-w*s/2]);v2=np.array([-h*s/2,-h*c/2])
    return np.stack([center+v1+v2,center+v1-v2,center-v1-v2,center-v1+v2])

def area(poly):
    p=np.asarray(poly)
    return abs(float(np.dot(p[:,0],np.roll(p[:,1],-1))-np.dot(p[:,1],np.roll(p[:,0],-1))))/2 if len(p)>=3 else 0.

def cross(a,b):return float(a[0]*b[1]-a[1]*b[0])

def polygon_iou(p,q):
    p=np.asarray(p,float);q=np.asarray(q,float)
    ap,aq=area(p),area(q)
    if min(ap,aq)<=0:return 0.
    if np.any(p.max(0)<q.min(0)) or np.any(q.max(0)<p.min(0)):return 0.
    signed=np.dot(q[:,0],np.roll(q[:,1],-1))-np.dot(q[:,1],np.roll(q[:,0],-1))
    sign=1 if signed>=0 else -1
    output=list(p)
    for j in range(len(q)):
        a=q[j];b=q[(j+1)%len(q)];edge=b-a
        points=output;output=[]
        if not points:break
        prev=points[-1];dp=sign*cross(edge,prev-a)
        for curr in points:
            dc=sign*cross(edge,curr-a)
            if (dc>=-1e-8)!=(dp>=-1e-8):
                denominator=dp-dc
                if abs(denominator)>1e-15:output.append(prev+(curr-prev)*(dp/denominator))
            if dc>=-1e-8:output.append(curr)
            prev,dp=curr,dc
    inter=area(output)
    return inter/max(ap+aq-inter,1e-12)

def decode(raw,kind,conf=.2,iou=.7,max_det=300):
    candidates=[]
    if kind.startswith('compact'):
        a=raw[0];a=a[np.isfinite(a).all(1)&(a[:,5]>conf)&(a[:,2]>0)&(a[:,3]>0)]
        for r in a:
            cls=int(r[6])
            if 0<=cls<len(COMPACT_NAMES):candidates.append({'class_id':cls,'class_name':COMPACT_NAMES[cls],'confidence':float(r[5]),'polygon_input':polygon(*r[:5]).tolist()})
    else:
        a=raw[0].T;scores=a[:,4:].max(1);classes=a[:,4:].argmax(1)
        valid=np.isfinite(a).all(1)&(scores>conf)&(a[:,2]>0)&(a[:,3]>0)
        for r,score,cls in zip(a[valid],scores[valid],classes[valid]):
            candidates.append({'class_id':int(cls),'class_name':XU_NAMES[int(cls)],'confidence':float(score),'polygon_input':polygon(*r[:4],0).tolist()})
    candidates.sort(key=lambda x:x['confidence'],reverse=True);kept=[]
    for d in candidates:
        if not any(d['class_id']==k['class_id'] and polygon_iou(d['polygon_input'],k['polygon_input'])>iou for k in kept):kept.append(d)
        if len(kept)>=max_det:break
    return kept

def original_coordinates(poly,pre,size,rotation):
    ratio,left,top=pre;p=np.asarray(poly,float).copy();p[:,0]=(p[:,0]-left)/ratio;p[:,1]=(p[:,1]-top)/ratio
    w,h=size
    if rotation==90:p=np.stack([p[:,1],h-p[:,0]],1)
    elif rotation==180:p=np.stack([w-p[:,0],h-p[:,1]],1)
    elif rotation==270:p=np.stack([w-p[:,1],p[:,0]],1)
    return p

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'input')
    parser.add_argument('--output',type=Path,default=ROOT/'optimization_v5/results/release')
    parser.add_argument('--model',choices=['all']+list(MODELS),default='yolo11-int8-native')
    parser.add_argument('--backend',choices=['ort','spacemit','vendor-cpu'],default='spacemit')
    parser.add_argument('--profile',action='store_true')
    parser.add_argument('--resize',choices=['opencv','pillow'],default='opencv')
    parser.add_argument('--rotation',type=int,choices=[0,90,180,270],default=90)
    parser.add_argument('--threads',type=int,default=8)
    parser.add_argument('--repeat',type=int,default=10)
    parser.add_argument('--warmup',type=int,default=3)
    parser.add_argument('--conf',type=float,default=.2)
    parser.add_argument('--iou',type=float,default=.7)
    parser.add_argument('--save-raw',action='store_true')
    args=parser.parse_args()
    global RESIZE_BACKEND
    RESIZE_BACKEND=args.resize
    if args.repeat<1 or args.warmup<0 or args.threads<1:parser.error('Invalid counts')
    import onnxruntime as ort
    if args.backend=='spacemit':import spacemit_ort
    files=sorted(p for p in args.source.iterdir() if p.suffix.lower() in {'.png','.bmp','.jpg','.jpeg'}) if args.source.is_dir() else [args.source]
    if not files:raise RuntimeError('No input images')
    selected=list(MODELS) if args.model=='all' else [args.model]
    summary=[]
    for model in selected:
        output=args.output/model;output.mkdir(parents=True,exist_ok=True)
        options=ort.SessionOptions();options.intra_op_num_threads=args.threads;options.inter_op_num_threads=1;options.log_severity_level=3
        options.enable_profiling=args.profile
        if args.profile:options.profile_file_prefix=str(output/'ort_profile')
        weight=ROOT/'models'/MODELS[model]
        providers=['SpaceMITExecutionProvider','CPUExecutionProvider'] if args.backend=='spacemit' else ['CPUExecutionProvider']
        t=time.perf_counter();session=ort.InferenceSession(str(weight),sess_options=options,providers=providers);load_ms=(time.perf_counter()-t)*1000
        input_name=session.get_inputs()[0].name
        from preprocess_file import prepare_file
        from nms_native import decode_horizontal
        first,_,_=prepare_file(files[0],args.rotation)
        for _ in range(args.warmup):session.run(None,{input_name:first})
        records=[];rows=[]
        for p in files:
            start=time.perf_counter();x,pre,image_size=prepare_file(p,args.rotation);pre_ms=(time.perf_counter()-start)*1000
            times=[]
            for _ in range(args.repeat):
                t=time.perf_counter();raw=session.run(None,{input_name:x})[0];times.append((time.perf_counter()-t)*1000)
            if not np.isfinite(raw).all():raise RuntimeError('Non-finite model output')
            t=time.perf_counter();detections=decode_horizontal(raw,model,args.conf,args.iou)
            for j,d in enumerate(detections):
                poly=original_coordinates(d['polygon_input'],pre,image_size,args.rotation)
                d['polygon_original']=poly.tolist()
                rows.append({'image':p.name,'index':j,'class_name':d['class_name'],'confidence':d['confidence'],**dict(zip(['x1','y1','x2','y2','x3','y3','x4','y4'],poly.ravel().tolist()))})
            post_ms=(time.perf_counter()-t)*1000
            image=Image.open(p).convert('RGB')
            annotated=image.copy();draw=ImageDraw.Draw(annotated)
            try:font=ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',19)
            except OSError:font=ImageFont.load_default(size=19)
            for d in detections:
                points=[tuple(pt) for pt in d['polygon_original']];draw.line(points+[points[0]],fill='#FFFF00',width=3)
                px,py=points[0];label=f"{d['class_name']} {d['confidence']:.3f}";box=draw.textbbox((px,py),label,font=font)
                draw.rectangle(box,fill='black');draw.text((px,py),label,fill='yellow',font=font)
            annotated.save(output/(p.stem+'.png'))
            if args.save_raw:np.savez_compressed(output/(p.stem+'_raw.npz'),raw=raw,input=x)
            record={'image':p.name,'source_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'detections':detections,
                    'timing_ms':{'preprocess_and_read':pre_ms,'inference':times,'inference_median':float(np.median(times)),'postprocess':post_ms,
                                 'pipeline_median_excluding_draw_save':pre_ms+float(np.median(times))+post_ms}}
            records.append(record)
            print(json.dumps({'model':model,'image':p.name,'candidates':len(detections),'infer_ms':round(float(np.median(times)),2)},ensure_ascii=False),flush=True)
        fields=['image','index','class_name','confidence','x1','y1','x2','y2','x3','y3','x4','y4']
        with (output/'detections.csv').open('w',encoding='utf-8-sig',newline='') as f:
            writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerows(rows)
        result={'model':model,'weight_sha256':hashlib.sha256(weight.read_bytes()).hexdigest(),'runtime':ort.__version__,'providers':session.get_providers(),
                'machine':platform.machine(),'backend':args.backend,'threads':args.threads,'warmup':args.warmup,'repeat':args.repeat,'session_load_ms':load_ms,
                'preprocessing':f'{args.resize} bilinear RGB letterbox 640, rotation clockwise90 by default; compare using identical input tensors',
                'conf':args.conf,'iou':args.iou,'images':records}
        if args.profile:
            profile_path=session.end_profiling();events=json.loads(Path(profile_path).read_text(encoding='utf8'));counts={}
            for e in events:
                provider=e.get('args',{}).get('provider')
                if provider:counts[provider]=counts.get(provider,0)+1
            result['profile_node_event_counts_by_provider']=counts
            result['profile_file']=Path(profile_path).name
        (output/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf8')
        summary.append({'model':model,'median_inference_ms':float(np.median([r['timing_ms']['inference_median'] for r in records])),
                        'images':len(records),'candidates':sum(len(r['detections']) for r in records)})
    (args.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf8')

if __name__=='__main__':main()
