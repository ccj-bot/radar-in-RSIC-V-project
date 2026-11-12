"""Standalone fixed-640 SAR inference. Requires numpy, opencv-python, onnxruntime."""
import argparse,csv,hashlib,json,math,pathlib
import cv2,numpy as np,onnxruntime as ort

ROOT=pathlib.Path(__file__).resolve().parent
COMPACT_NAMES=['tree','manhole','bench','hydrant','trunk','bike','light','person','walker','roadblock','handrail','rider','tricycle','bush','bin','guidepost','car','fence','stair','building']
XU_NAMES=['person','car','bike','bush','hydrant','handrail','building','light','tree']
MODELS={'compact-fp16':'sar_v5_compact_decoded_fp16.onnx','compact-fp32':'sar_v5_compact_decoded_fp32.onnx','xu-int8':'xu_yolo11s_int8_qdq.onnx'}

def preprocess(image,rotation,size=640):
    codes={90:cv2.ROTATE_90_CLOCKWISE,180:cv2.ROTATE_180,270:cv2.ROTATE_90_COUNTERCLOCKWISE}
    work=cv2.rotate(image,codes[rotation]) if rotation else image.copy()
    h,w=work.shape[:2];ratio=min(size/h,size/w);nw,nh=round(w*ratio),round(h*ratio)
    dw,dh=(size-nw)/2,(size-nh)/2;left,top=round(dw-.1),round(dh-.1)
    padded=cv2.copyMakeBorder(cv2.resize(work,(nw,nh)),top,round(dh+.1),left,round(dw+.1),cv2.BORDER_CONSTANT,value=(114,114,114))
    data=np.ascontiguousarray(padded[:,:,::-1].transpose(2,0,1)[None]).astype(np.float32)/255
    return data,(ratio,left,top)

def polygon(cx,cy,w,h,theta):
    c,s=math.cos(theta),math.sin(theta);center=np.array([cx,cy]);v1=np.array([w*c/2,-w*s/2]);v2=np.array([-h*s/2,-h*c/2])
    return np.stack([center+v1+v2,center+v1-v2,center-v1-v2,center-v1+v2])

def postprocess(raw,kind,conf,iou,max_det):
    detections=[]
    if kind.startswith('compact'):
        a=raw[0];a=a[np.isfinite(a).all(1)&(a[:,5]>conf)&(a[:,2]>0)&(a[:,3]>0)]
        for cls in np.unique(a[:,6].astype(int)):
            subset=a[a[:,6].astype(int)==cls]
            rects=[((float(r[0]),float(r[1])),(float(r[2]),float(r[3])),float(-r[4]*180/np.pi)) for r in subset]
            ids=cv2.dnn.NMSBoxesRotated(rects,subset[:,5].tolist(),conf,iou)
            for idx in np.asarray(ids).reshape(-1) if len(ids) else []:
                r=subset[int(idx)]
                detections.append({'class_id':int(cls),'class_name':COMPACT_NAMES[int(cls)],'confidence':float(r[5]),'polygon_input':polygon(*r[:5]).tolist()})
    else:
        a=raw[0].T;scores=a[:,4:].max(1);classes=a[:,4:].argmax(1)
        valid=np.isfinite(a).all(1)&(scores>conf)&(a[:,2]>0)&(a[:,3]>0)
        a,scores,classes=a[valid],scores[valid],classes[valid]
        for cls in np.unique(classes):
            indices=np.where(classes==cls)[0]
            rects=[[float(a[j,0]-a[j,2]/2),float(a[j,1]-a[j,3]/2),float(a[j,2]),float(a[j,3])] for j in indices]
            ids=cv2.dnn.NMSBoxes(rects,scores[indices].tolist(),conf,iou)
            for k in np.asarray(ids).reshape(-1) if len(ids) else []:
                j=indices[int(k)]
                detections.append({'class_id':int(cls),'class_name':XU_NAMES[int(cls)],'confidence':float(scores[j]),'polygon_input':polygon(*a[j,:4],0).tolist()})
    return sorted(detections,key=lambda x:x['confidence'],reverse=True)[:max_det]

def original_coordinates(poly,pre,shape,rotation):
    ratio,left,top=pre;p=np.asarray(poly,float).copy();p[:,0]=(p[:,0]-left)/ratio;p[:,1]=(p[:,1]-top)/ratio
    h,w=shape[:2]
    if rotation==90:p=np.stack([p[:,1],h-p[:,0]],1)
    elif rotation==180:p=np.stack([w-p[:,0],h-p[:,1]],1)
    elif rotation==270:p=np.stack([w-p[:,1],p[:,0]],1)
    return p

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=pathlib.Path,required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True)
    parser.add_argument('--model',choices=MODELS,default='compact-fp16')
    parser.add_argument('--rotation',type=int,choices=[0,90,180,270],default=90)
    parser.add_argument('--conf',type=float,default=.2);parser.add_argument('--iou',type=float,default=.7)
    parser.add_argument('--max-det',type=int,default=300);parser.add_argument('--threads',type=int,default=4)
    args=parser.parse_args()
    if not 0<=args.conf<=1 or not 0<=args.iou<=1:parser.error('conf and iou must be in [0,1]')
    if args.max_det<=0 or args.threads<=0:parser.error('max-det and threads must be positive')
    weight=ROOT/'models'/MODELS[args.model]
    if not weight.is_file():raise FileNotFoundError(weight)
    if args.source.is_dir():files=sorted(p for p in args.source.iterdir() if p.suffix.lower() in {'.png','.bmp','.jpg','.jpeg','.tif','.tiff'})
    else:files=[args.source]
    if not files:raise ValueError('No supported images found')
    options=ort.SessionOptions();options.intra_op_num_threads=args.threads;options.log_severity_level=3
    session=ort.InferenceSession(str(weight),options,providers=['CPUExecutionProvider'])
    args.output.mkdir(parents=True,exist_ok=True);(args.output/'annotated').mkdir(exist_ok=True)
    records=[];flat=[]
    for i,p in enumerate(files):
        # Decode bytes so Windows paths containing Chinese characters work too.
        image=cv2.imdecode(np.frombuffer(p.read_bytes(),dtype=np.uint8),cv2.IMREAD_COLOR)
        if image is None:raise ValueError('Unable to read '+str(p))
        x,pre=preprocess(image,args.rotation)
        raw=session.run(None,{'images':x})[0]
        detections=postprocess(raw,args.model,args.conf,args.iou,args.max_det)
        canvas=image.copy()
        for j,d in enumerate(detections):
            poly=original_coordinates(d['polygon_input'],pre,image.shape,args.rotation)
            d['polygon_original']=poly.tolist()
            d['aabb_original']=[float(poly[:,0].min()),float(poly[:,1].min()),float(poly[:,0].max()),float(poly[:,1].max())]
            q=poly.round().astype(np.int32);cv2.polylines(canvas,[q],True,(0,255,255),2)
            cv2.putText(canvas,f"{j} {d['class_name']} {d['confidence']:.3f}",tuple(q[0]),cv2.FONT_HERSHEY_SIMPLEX,.5,(0,255,255),1)
            flat.append({'source':str(p.resolve()),'index':j,'class_id':d['class_id'],'class_name':d['class_name'],'confidence':d['confidence'],
                         **dict(zip(['x1','y1','x2','y2','x3','y3','x4','y4'],poly.reshape(-1).tolist()))})
        image_out=args.output/'annotated'/f'{i:04d}_{p.stem}.png'
        ok,encoded=cv2.imencode('.png',canvas)
        if not ok:raise IOError('Unable to encode '+str(image_out))
        image_out.write_bytes(encoded.tobytes())
        records.append({'source':str(p.resolve()),'source_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'shape':list(image.shape),'detections':detections})
    fields=['source','index','class_id','class_name','confidence','x1','y1','x2','y2','x3','y3','x4','y4']
    with (args.output/'detections.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();writer.writerows(flat)
    report={'model':args.model,'weight_sha256':hashlib.sha256(weight.read_bytes()).hexdigest(),'onnxruntime':ort.__version__,
            'parameters':{'rotation':args.rotation,'input':[1,3,640,640],'conf':args.conf,'iou':args.iou,'max_det':args.max_det,'mode':'full'},
            'interpretation':'Detection proposals only; no accuracy/identity validation. Compact training orientation remains unconfirmed.', 'images':records}
    (args.output/'results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'images':len(records),'detections':len(flat),'model':args.model,'output':str(args.output.resolve())},ensure_ascii=False))
if __name__=='__main__':main()
