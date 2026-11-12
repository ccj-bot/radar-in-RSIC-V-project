#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <png.h>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <vector>
static cv::Mat read_rgb(const char* path){
 std::ifstream f(path,std::ios::binary);if(!f)return {};
 unsigned char h[54];f.read(reinterpret_cast<char*>(h),54);if(f.gcount()!=54)return {};
 if(h[0]=='B'&&h[1]=='M'){
  auto u32=[&](int i){return std::uint32_t(h[i])|(std::uint32_t(h[i+1])<<8)|(std::uint32_t(h[i+2])<<16)|(std::uint32_t(h[i+3])<<24);};
  int w=std::int32_t(u32(18)),height=std::int32_t(u32(22));int bpp=h[28]|(h[29]<<8);
  if(w<=0||height==0||height==INT32_MIN||w>32768||std::abs(height)>32768||u32(30)!=0||(bpp!=24&&bpp!=32))return {};
  int nrows=std::abs(height),stride=((w*bpp+31)/32)*4,channels=bpp/8;
  cv::Mat rgb(nrows,w,CV_8UC3);std::vector<unsigned char> row(stride);f.seekg(u32(10));
  for(int i=0;i<nrows;++i){
   f.read(reinterpret_cast<char*>(row.data()),stride);if(!f)return {};
   auto* dst=rgb.ptr<unsigned char>(height>0?nrows-1-i:i);
   for(int x=0;x<w;++x){dst[3*x]=row[channels*x+2];dst[3*x+1]=row[channels*x+1];dst[3*x+2]=row[channels*x];}
  }
  return rgb;
 }
 png_image image{};image.version=PNG_IMAGE_VERSION;
 if(!png_image_begin_read_from_file(&image,path))return {};
 image.format=PNG_FORMAT_RGB;cv::Mat rgb(image.height,image.width,CV_8UC3);
 if(!png_image_finish_read(&image,nullptr,rgb.data,0,nullptr)){png_image_free(&image);return {};}
 png_image_free(&image);return rgb;
}
extern "C" int preprocess_file(const char* path,int rotation,int size,float* out,double* meta){
 try {
  cv::setNumThreads(1);
  cv::Mat rgb=read_rgb(path);if(rgb.empty())return -2;
  cv::Mat rotated,resized;
  if(rotation==90)cv::rotate(rgb,rotated,cv::ROTATE_90_CLOCKWISE);
  else if(rotation==180)cv::rotate(rgb,rotated,cv::ROTATE_180);
  else if(rotation==270)cv::rotate(rgb,rotated,cv::ROTATE_90_COUNTERCLOCKWISE);
  else rotated=rgb;
  const double ratio=std::min(double(size)/rotated.rows,double(size)/rotated.cols);
  const int nw=int(std::nearbyint(rotated.cols*ratio)),nh=int(std::nearbyint(rotated.rows*ratio));
  const int left=int(std::nearbyint((size-nw)/2.0-.1)),top=int(std::nearbyint((size-nh)/2.0-.1));
  cv::resize(rotated,resized,cv::Size(nw,nh),0,0,cv::INTER_LINEAR);
  const int plane=size*size;const float pad=float(114)/float(255);
  for(int i=0;i<3*plane;++i)out[i]=pad;
  for(int y=0;y<nh;++y){
   const auto* row=resized.ptr<std::uint8_t>(y);const int offset=(y+top)*size+left;
   for(int x=0;x<nw;++x){
    out[offset+x]=float(row[3*x])/float(255);
    out[plane+offset+x]=float(row[3*x+1])/float(255);
    out[2*plane+offset+x]=float(row[3*x+2])/float(255);
   }
  }
  meta[0]=ratio;meta[1]=left;meta[2]=top;meta[3]=rgb.cols;meta[4]=rgb.rows;
  return 0;
 }catch(...){return -1;}
}
