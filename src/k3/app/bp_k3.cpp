#include <cmath>
#include <cstddef>
#include <vector>
#include <riscv_vector.h>
#include <omp.h>

extern "C" std::size_t rvv_bits() {return __riscv_vsetvlmax_e64m1()*64;}

extern "C" void bp_scalar(const double* qx,const double* qy,int np,const double* apx,int nm,
 const float* hr,const float* hi,int nr,double dr,double fref,double* out_r,double* out_i,int threads) {
 const double scale=4.0*std::acos(-1.0)*fref/3e8;
 #pragma omp parallel for num_threads(threads)
 for(int p=0;p<np;++p){
  double sr=0,si=0;
  for(int m=0;m<nm;++m){
   double dx=qx[p]-apx[m],r=std::sqrt(dx*dx+qy[p]*qy[p]);
   double index=r/dr;int j=static_cast<int>(std::floor(index));
   if(j<0 || j+1>=nr)continue;
   double t=index-j;std::size_t k=static_cast<std::size_t>(m)*nr+j;
   double vr=hr[k]*(1-t)+hr[k+1]*t,vi=hi[k]*(1-t)+hi[k+1]*t;
   double phase=scale*r,co=std::cos(phase),sn=std::sin(phase);
   sr+=vr*co-vi*sn;si+=vr*sn+vi*co;
  }
  out_r[p]=sr/nm;out_i[p]=si/nm;
 }
}

// Vectorize range calculation and complex accumulation across output pixels.
// Trigonometry and range-profile indexing remain scalar in this first port.
extern "C" void bp_rvv(const double* qx,const double* qy,int np,const double* apx,int nm,
 const float* hr,const float* hi,int nr,double dr,double fref,double* out_r,double* out_i,int threads) {
 const double scale=4.0*std::acos(-1.0)*fref/3e8;
 const int lanes=static_cast<int>(__riscv_vsetvlmax_e64m1());
 const int groups=(np+lanes-1)/lanes;
 #pragma omp parallel num_threads(threads)
 {
  std::vector<double> ranges(lanes),vr(lanes),vi(lanes),co(lanes),sn(lanes);
  #pragma omp for
  for(int group=0;group<groups;++group){
   int start=group*lanes;std::size_t vl=__riscv_vsetvl_e64m1(np-start);
   auto vx=__riscv_vle64_v_f64m1(qx+start,vl);
   auto vy=__riscv_vle64_v_f64m1(qy+start,vl);
   auto yy=__riscv_vfmul_vv_f64m1(vy,vy,vl);
   auto sr=__riscv_vfmv_v_f_f64m1(0,vl),si=__riscv_vfmv_v_f_f64m1(0,vl);
   for(int m=0;m<nm;++m){
    auto dx=__riscv_vfsub_vf_f64m1(vx,apx[m],vl);
    auto rr=__riscv_vfsqrt_v_f64m1(__riscv_vfadd_vv_f64m1(__riscv_vfmul_vv_f64m1(dx,dx,vl),yy,vl),vl);
    __riscv_vse64_v_f64m1(ranges.data(),rr,vl);
    for(std::size_t lane=0;lane<vl;++lane){
     double index=ranges[lane]/dr;int j=static_cast<int>(std::floor(index));
     if(j<0||j+1>=nr){vr[lane]=vi[lane]=sn[lane]=0;co[lane]=1;continue;}
     double t=index-j;std::size_t k=static_cast<std::size_t>(m)*nr+j;
     vr[lane]=hr[k]*(1-t)+hr[k+1]*t;vi[lane]=hi[k]*(1-t)+hi[k+1]*t;
     double phase=scale*ranges[lane];co[lane]=std::cos(phase);sn[lane]=std::sin(phase);
    }
    auto ar=__riscv_vle64_v_f64m1(vr.data(),vl),ai=__riscv_vle64_v_f64m1(vi.data(),vl);
    auto c=__riscv_vle64_v_f64m1(co.data(),vl),s=__riscv_vle64_v_f64m1(sn.data(),vl);
    sr=__riscv_vfadd_vv_f64m1(sr,__riscv_vfsub_vv_f64m1(__riscv_vfmul_vv_f64m1(ar,c,vl),__riscv_vfmul_vv_f64m1(ai,s,vl),vl),vl);
    si=__riscv_vfadd_vv_f64m1(si,__riscv_vfadd_vv_f64m1(__riscv_vfmul_vv_f64m1(ar,s,vl),__riscv_vfmul_vv_f64m1(ai,c,vl),vl),vl);
   }
   __riscv_vse64_v_f64m1(out_r+start,__riscv_vfdiv_vf_f64m1(sr,nm,vl),vl);
   __riscv_vse64_v_f64m1(out_i+start,__riscv_vfdiv_vf_f64m1(si,nm,vl),vl);
  }
 }
}
