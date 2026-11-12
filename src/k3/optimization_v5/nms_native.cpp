#include <algorithm>
#include <cmath>
#include <vector>
struct Box {int index,cls;float score;double x1,y1,x2,y2,area;};
extern "C" int nms_select(const float* raw,int channels,int n,float conf,double iou,int maxdet,int* indices) {
  std::vector<Box> b;
  for(int i=0;i<n;++i){
    bool finite=true;for(int c=0;c<channels;++c)finite=finite&&std::isfinite(raw[c*n+i]);
    if(!finite||raw[2*n+i]<=0||raw[3*n+i]<=0)continue;
    int cls=0;float score=raw[4*n+i];
    for(int c=5;c<channels;++c)if(raw[c*n+i]>score){score=raw[c*n+i];cls=c-4;}
    if(!(score>conf))continue;
    double x=raw[i],y=raw[n+i],w=raw[2*n+i],h=raw[3*n+i];
    b.push_back({i,cls,score,x-w/2,y-h/2,x+w/2,y+h/2,w*h});
  }
  std::stable_sort(b.begin(),b.end(),[](const Box&a,const Box&b){return a.cls<b.cls||(a.cls==b.cls&&a.score>b.score);});
  std::vector<Box> kept;
  for(const auto& v:b){
    bool suppressed=false;
    for(const auto& q:kept)if(v.cls==q.cls){
      double intersection=std::max(0.0,std::min(v.x2,q.x2)-std::max(v.x1,q.x1))*std::max(0.0,std::min(v.y2,q.y2)-std::max(v.y1,q.y1));
      if(intersection/std::max(v.area+q.area-intersection,1e-15)>iou){suppressed=true;break;}
    }
    if(!suppressed)kept.push_back(v);
  }
  std::stable_sort(kept.begin(),kept.end(),[](const Box&a,const Box&b){return a.score>b.score;});
  int count=std::min(int(kept.size()),maxdet);for(int i=0;i<count;++i)indices[i]=kept[i].index;
  return count;
}
