# 运行入口

## K3 检测

当前入口为 `src/k3/optimization_v5/run_int8.sh` 和 `run_pipeline.sh`。
v5 依赖 `optimization_v4/models/yolo11_int8_percentile.onnx`、v3 前处理与根目录 `app/`，因此保留这些依赖目录。

现有板端脚本沿用固定路径 `/root/radarbrain_k3_20261108`。本次保持源码原样，尚未做路径通用化。
部署时应将 `src/k3/` **内部内容**放到该板端路径，并单独安全传入获授权的模型与输入；在当前 Windows 目录直接运行板端脚本不适用。

新 K3 环境需要厂商软件源、SpaceMIT ONNX Runtime、RISC-V C++ 编译器、OpenCV、NumPy 等，清单见 `src/k3/RUNTIME_PACKAGES.json`。`setup_runtime.sh` 下载软件包并解压到项目内 `runtime/`，不随 Git 保存。Python 版本、厂商源和库路径应按板端实际环境核对。

已有运行库时，根目录 `build.sh`、`optimization_v3/build_native.sh`、`optimization_v5/build_native.sh` 用于重新编译原生库。v5 的构建脚本最后还会运行验证脚本；该验证依赖旧版本的原生库和历史比对数组，精简仓库没有包含全部比对输入，完整回归应补齐这些本地资产后进行。

在准备好的 K3 环境中：

```sh
cd /root/radarbrain_k3_20261108/optimization_v5
sh run_int8.sh --source /path/to/local/images --output /path/to/local/results
```

原图默认顺时针旋转 90 度，已预旋转的输入传 `--rotation 0`。模型不在 GitHub 上，不能仅凭克隆仓库完成推理。

## BP 合成示例

这是无模型权重的合成回波示例；安装依赖后可单独运行：

```powershell
cd 'D:\profile\radar in RSIC-V\src\imaging\bp'
python -m pip install -r requirements.txt
python run_demo.py --output runs/bp_demo
```

首次运行含 Numba 编译。该示例不直接读取雷达原始 ADC 文件。

## 雷达和相机采集

`src/acquisition/radar_stack/web/server.py` 为服务入口，`fpga_udp/` 为驱动源码。
原实现针对 NX / Ubuntu 22.04 / ARM64 / Python 3.10，依赖 GStreamer、GI、GTK/WebKit、FTDI 和 C++17。
本仓库移除了预编译 ARM64 库及可执行二进制；迁移到 RISC-V 需要重编译驱动并适配环境。
设备 IP、网卡、服务根路径见 `config/` 和 `deploy/`，应按实际硬件配置后再启动采集。

## FPGA

`hardware/fpga/v1.1/README.md` 描述 RTL、初始化表与构建入口，目标器件为 xc7z020clg484-1，原构建流程使用 Vivado 2024.2。
`hardware/fpga/interpolation/` 保存插值模块与测试平台；帧接口见 `hardware/fpga/FPGA_K3_IMAGE_INTERFACE.json`。
`.mem` 与 FFT 因子 `.txt` 是硬件构建输入，已保留；没有包含生成的 bitstream。
