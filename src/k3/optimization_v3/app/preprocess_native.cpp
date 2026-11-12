#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <cstdint>
extern "C" int preprocess_rgb(const std::uint8_t* source,int h,int w,int rotation,int nw,int nh,int left,int top,int size,float* out){
 try {
  cv::Mat rgb(h,w,CV_8UC3,const_cast<std::uint8_t*>(source)), rotated, resized;
  if(rotation==90)cv::rotate(rgb,rotated,cv::ROTATE_90_CLOCKWISE);
  else if(rotation==180)cv::rotate(rgb,rotated,cv::ROTATE_180);
  else if(rotation==270)cv::rotate(rgb,rotated,cv::ROTATE_90_COUNTERCLOCKWISE);
  else rotated=rgb;
  cv::resize(rotated,resized,cv::Size(nw,nh),0,0,cv::INTER_LINEAR);
  const int plane=size*size;
  const float pad=float(114)/float(255);
  for(int i=0;i<3*plane;++i)out[i]=pad;
  for(int y=0;y<nh;++y){
   const auto* row=resized.ptr<std::uint8_t>(y);
   const int offset=(y+top)*size+left;
   for(int x=0;x<nw;++x){
    out[offset+x]=float(row[3*x])/float(255);
    out[plane+offset+x]=float(row[3*x+1])/float(255);
    out[2*plane+offset+x]=float(row[3*x+2])/float(255);
   }
  }
  return 0;
 }catch(...){return -1;}
}
