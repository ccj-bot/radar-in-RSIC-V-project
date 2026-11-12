# 雷达智脑K3实机部署 INT8更新版

固定根目录 /root/radarbrain_k3_20261108 。最新入口：

```bash
cd /root/radarbrain_k3_20261108/optimization_v5
./run_int8.sh
./run_pipeline.sh
```

optimization_v4提供厂商INT8模型、量化源码和浮点解码，optimization_v5提供原生BMP/PNG读取、前处理与NMS；v3保留混合精度参考，v2保留RDA/BP及真实bin RD。
板端已有隔离runtime，无需再次安装。新设备按原setup_runtime.sh重建项目内运行库，核对RUNTIME_PACKAGES.json和environment.json；模型使用厂商SpaceMIT后端。
本次额外依赖的libpng16为板端已有系统运行库，build_native.sh只在项目目录获取编译头文件。其他格式沿用Pillow和v3原生前处理。
模型原件与校准输入分别位于证明材料/模型源文件和INT8校准与检查输入，量化复现方法见optimization_v4/量化复现/README.md。
完整SAR采集、成像和FPGA图像接口继续联调。原混合精度和历史文件均保留，按版本目录区分。
