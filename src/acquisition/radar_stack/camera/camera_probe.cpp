#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <iostream>
#include <string>
static std::string quote(const std::string&s){std::string o="\"";for(unsigned char c:s){if(c=='"'||c=='\\')o+='\\';if(c>=32)o+=char(c);}return o+"\"";}
int main(int argc,char**argv){
 if(argc<2||argc>3){std::cerr<<"usage: camera_probe /dev/videoN [--fixed-fps]\n";return 2;}
 int fd=open(argv[1],O_RDWR|O_NONBLOCK);if(fd<0){std::cerr<<strerror(errno)<<"\n";return 2;}
 v4l2_capability cap{};if(ioctl(fd,VIDIOC_QUERYCAP,&cap)<0){std::cerr<<strerror(errno);close(fd);return 2;}
 unsigned caps=(cap.capabilities&V4L2_CAP_DEVICE_CAPS)?cap.device_caps:cap.capabilities;
 std::cout<<"{\"device\":"<<quote(argv[1])<<",\"name\":"<<quote((char*)cap.card)<<",\"driver\":"<<quote((char*)cap.driver)<<",\"bus\":"<<quote((char*)cap.bus_info)<<",\"capture\":"<<((caps&V4L2_CAP_VIDEO_CAPTURE)?"true":"false")<<",\"streaming\":"<<((caps&V4L2_CAP_STREAMING)?"true":"false")<<",\"modes\":[";
 bool first=true;
 for(unsigned f=0;;++f){v4l2_fmtdesc format{};format.index=f;format.type=V4L2_BUF_TYPE_VIDEO_CAPTURE;if(ioctl(fd,VIDIOC_ENUM_FMT,&format)<0)break;
  std::string fourcc;for(int k=0;k<4;++k)fourcc+=char((format.pixelformat>>(k*8))&255);
  for(unsigned s=0;;++s){v4l2_frmsizeenum size{};size.index=s;size.pixel_format=format.pixelformat;if(ioctl(fd,VIDIOC_ENUM_FRAMESIZES,&size)<0)break;if(size.type!=V4L2_FRMSIZE_TYPE_DISCRETE)continue;
   for(unsigned t=0;;++t){v4l2_frmivalenum interval{};interval.index=t;interval.pixel_format=format.pixelformat;interval.width=size.discrete.width;interval.height=size.discrete.height;if(ioctl(fd,VIDIOC_ENUM_FRAMEINTERVALS,&interval)<0)break;if(interval.type!=V4L2_FRMIVAL_TYPE_DISCRETE||!interval.discrete.numerator)continue;
    if(!first)std::cout<<",";first=false;std::cout<<"{\"fourcc\":"<<quote(fourcc)<<",\"width\":"<<size.discrete.width<<",\"height\":"<<size.discrete.height<<",\"fps_num\":"<<interval.discrete.denominator<<",\"fps_den\":"<<interval.discrete.numerator<<",\"fps\":"<<double(interval.discrete.denominator)/interval.discrete.numerator<<",\"compressed\":"<<((format.flags&V4L2_FMT_FLAG_COMPRESSED)?"true":"false")<<"}";
   }
  }
 }
 std::cout<<"],\"controls\":[";bool firstControl=true;
 v4l2_queryctrl query{};query.id=V4L2_CTRL_FLAG_NEXT_CTRL;
 while(ioctl(fd,VIDIOC_QUERYCTRL,&query)==0){
  v4l2_control value{};value.id=query.id;bool readable=ioctl(fd,VIDIOC_G_CTRL,&value)==0;
  if(!firstControl)std::cout<<",";firstControl=false;
  std::cout<<"{\"id\":"<<query.id<<",\"name\":"<<quote((char*)query.name)<<",\"value\":"<<(readable?std::to_string(value.value):"null")<<",\"minimum\":"<<query.minimum<<",\"maximum\":"<<query.maximum<<",\"default\":"<<query.default_value<<"}";
  query.id|=V4L2_CTRL_FLAG_NEXT_CTRL;
 }
 std::cout<<"]";
 if(argc==3&&std::string(argv[2])=="--fixed-fps"){
  v4l2_control value{};value.id=V4L2_CID_EXPOSURE_AUTO_PRIORITY;int before=0;bool supported=ioctl(fd,VIDIOC_G_CTRL,&value)==0;before=value.value;bool applied=false;
  if(supported){value.value=0;applied=ioctl(fd,VIDIOC_S_CTRL,&value)==0;}
  std::cout<<",\"fixed_fps_control\":{\"supported\":"<<(supported?"true":"false")<<",\"before\":"<<before<<",\"applied\":"<<(applied?"true":"false")<<",\"requested_exposure_auto_priority\":0}";
 }
 std::cout<<"}\n";close(fd);return 0;
}
