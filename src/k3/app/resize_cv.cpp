#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <cstdint>
extern "C" int resize_linear_rgb(const std::uint8_t* source,int h,int w,std::uint8_t* dest,int dh,int dw) {
 try {
  cv::Mat a(h,w,CV_8UC3,const_cast<std::uint8_t*>(source));
  cv::Mat b(dh,dw,CV_8UC3,dest);
  cv::resize(a,b,cv::Size(dw,dh),0,0,cv::INTER_LINEAR);
  return 0;
 } catch(...) {return -1;}
}
