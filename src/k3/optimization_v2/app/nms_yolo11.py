import numpy as np

def decode_horizontal(raw,kind,conf=.2,iou=.7,max_det=300):
 from infer_k3 import XU_NAMES,polygon
 a=raw[0].T;scores=a[:,4:].max(1);classes=a[:,4:].argmax(1)
 valid=np.isfinite(a).all(1)&(scores>conf)&(a[:,2]>0)&(a[:,3]>0)
 a=a[valid];scores=scores[valid];classes=classes[valid]
 boxes=a[:,:4].astype(np.float64);x1=boxes[:,0]-boxes[:,2]/2;y1=boxes[:,1]-boxes[:,3]/2;x2=boxes[:,0]+boxes[:,2]/2;y2=boxes[:,1]+boxes[:,3]/2
 areas=boxes[:,2]*boxes[:,3];keep=[]
 for cls in np.unique(classes):
  idx=np.flatnonzero(classes==cls);order=idx[np.argsort(-scores[idx],kind='stable')]
  while len(order):
   first=int(order[0]);keep.append(first);rest=order[1:]
   if not len(rest):break
   intersection=np.maximum(0,np.minimum(x2[first],x2[rest])-np.maximum(x1[first],x1[rest]))*np.maximum(0,np.minimum(y2[first],y2[rest])-np.maximum(y1[first],y1[rest]))
   overlap=intersection/np.maximum(areas[first]+areas[rest]-intersection,1e-15)
   order=rest[overlap<=iou]
 detections=[]
 for j in keep:
  cls=int(classes[j]);detections.append({'class_id':cls,'class_name':XU_NAMES[cls],'confidence':float(scores[j]),'polygon_input':polygon(*a[j,:4],0).tolist()})
 return sorted(detections,key=lambda d:d['confidence'],reverse=True)[:max_det]
