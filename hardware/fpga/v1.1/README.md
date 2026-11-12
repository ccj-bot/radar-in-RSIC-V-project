# SAR Imaging v1.1 精简 RTL 基线

本目录基于 v1.0 精简 RTL 工程，将 PL 在线插值描述符生成器接入实际 SAR 数据通路。
交付内容为构建 bit 所需的 RTL、板级约束、FFT 初始化数据、Vivado/PowerShell 构建脚本和说明。
仿真、Python 数据示例、Vivado 工程/缓存、已生成 bit/XSA 和旧交付压缩包已于 2026-11-04 清除。

## 功能与意义

目标器件为 xc7z020clg484-1，PL/SRAM 主时钟固定 100 MHz。
输入为 1024×512 个复数回波点，每点 16 位实部和 16 位虚部；SAR 输出为 1024×591，
使用 DDR 图像 HDMI 灰度预览，显示画面为 1024×768。输入 FFT 尺寸固定。

```text
DDR 回波 -> AXI DMA -> 二维 FFT / 转置 -> 缩放、幅度计算与帧缓存
  -> 二维插值 -> Gamma 后处理 -> AXI DMA 写回 DDR -> HDMI 灰度预览

PS 每帧速度配置 + 固定几何元数据 -> 描述符 DMA
  -> sar_pl_iw_generator -> 二维插值模块
```

PL 生成器根据当前帧速度和固定几何，在线计算方位索引与四个双线性插值权重。
输出几何不变时，PS 更新一个 64 bit 帧配置字即可更新该模块的速度参数，
无需重算约 60 万个描述符。这减少速度更新时的 CPU 负载和等待，为连续成像提供基础；
每帧仍需传输固定几何元数据，实际 FPS 需进行板级测试。

生成器已在 sar_imaging_top 中实例化，SRAM 和 DDR 两条插值分支均使用其输出。
本目录为硬件源工程，PS/Vitis 应用、雷达自主配置和网口接收软件需另行提供。

## 目录与构建依赖

| 路径 | 用途 |
| --- | --- |
| `rtl/system` | SAR 顶层、控制寄存器和帧调度 |
| `rtl/pl_iw/sar_pl_iw_generator.v` | 已接入顶层的 PL 插值索引与权重生成 RTL |
| `rtl/2D_fft`、`rtl/common` | 二维 FFT、转置、SRAM 和通用运算 |
| `rtl/interp2`、`rtl/interp2_axi`、`rtl/postproc` | 二维插值、数据读取及 Gamma 后处理 |
| `rtl/axi`、`rtl/hdmi_test/rgb2dvi` | AXI 与 HDMI/DVI 支持 |
| `constraints/sram_example/sar_imaging_sram_pins.xdc` | 板级引脚、SRAM 与时序约束 |
| `data/scripts_output/transform/lookup_table*.mem` | FFT 重排初始化数据 |
| `rtl/2D_fft/fft/raw/*.txt` | FFT 因子原始数据，打包时转为 include 文件 |
| `script/build_v1.1.ps1`、`script/vivado` | IP 打包、BD、综合、实现及 bit/XSA 导出 |

`.mem` 与因子 `.txt` 是构建输入，应随源码交付。整个源目录可独立重建，不依赖相邻
v1.0、v4 或 pl_iw_descriptor 目录。

## 构建 bit

需要 Vivado 2024.2 和 Windows PowerShell。在本目录执行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\script\build_v1.1.ps1

# 自定义 Vivado 安装路径
powershell.exe -ExecutionPolicy Bypass -File .\script\build_v1.1.ps1 -VivadoRoot "E:\Xilinx\Vivado\2024.2"
```

默认 QScale=26564，对应 NA=512、fc=76 GHz、PRF=10000 Hz、c=3e8 m/s。
如采用 v4 的 PRF=1/63 us，应明确传入 `-QScale 16735`。
构建固定使用 xc7z020clg484-1、100 MHz；检查 setup、hold、DRC 和总线偏斜，
满足检查后导出 bit/XSA。默认 Jobs=1。

重建后将生成：

- Vivado 工程：`vivado/projects/v11/v11.xpr`。
- bit/XSA 与报告：`output/export/v11/`。
- 构建日志：`output/logs/`。

这些目录当前已清除，是可再生文件；本次精简没有重新运行整轮 Vivado 构建。

## 输入接口与速度参数

描述符输入为 64 bit AXI Stream：每帧一个配置字加 N 个几何元数据字，
配置字不产生输出像素，仅最后一个元数据字置 TLAST。每个字均完整传输，tkeep=0xff。

| 输入字 | 位段与内容 |
| --- | --- |
| 帧配置 | [63:48]=0x504c，[47:44]=1，[43:35]=V_Q4，[34:15]=N，其余置零 |
| 像素几何 | [63]=valid，[62:45]=有符号 sin(theta) Q17，[44:35]=距离索引 ar，[34:19]=距离比例 tr Q16，其余置零 |

速度 V=V_Q4/16 m/s。1024×591 输出对应 N=605184，
描述符 DMA 输入为 (N+1)×8=4841480 字节；图像输出仍为 N×2=1210368 字节。
旧 v1.0 的 PS 完整描述符表不能直接用于新版输入。

PS 应准备固定几何、初始化 DDR/DMA/缓存及原 SAR 帧控制状态，
将帧头速度与本帧控制中的速度保持一致，并保护在途帧的缓冲区。
PL 帧头不代替原有 PS/PL 帧控制协议；完成初始化后才能释放 PL。

| 只读寄存器偏移 | 说明 |
| --- | --- |
| 0x148 | [31:16]=0x1101，[9]=PL 配置错误，[8:0]=已接收帧头的 V_Q4 |
| 0x14C | 实际综合使用的 QScale 系数 |

## 精简前构建核验

2026-11-04 已完成 IP/BD、综合、布局布线、布线后优化、bit 生成和 XSA 导出，
时钟保持 100 MHz：

| 项目 | 结果 |
| --- | --- |
| Setup / Hold | WNS +0.094 ns、WHS +0.017 ns；TNS/THS 均为 0 |
| 路由 / DRC | 69276 个网络全部布通，routing errors 0，DRC 0 errors |
| 总线偏斜 | 报告所列路径均 MET |
| LUT / FF | 34805 / 43689 |
| BRAM Tile / DSP | 90 / 40 |

生成 bit 的 SHA-256：

```text
6D8219F5EAB2B99877F099865E1E1D40D4DD724F2568D401BB6B26B8FCF85262
```

当时 XSA 内嵌 bit 与独立 bit 逐字节一致。首次 HSI 导出路径问题已修正，并通过保存的
工程与检查点恢复验证，修正后的导出函数已纳入构建脚本。功能验证曾覆盖生成器、
真实插值核心及状态寄存器；当前精简包不保留这些仿真或数据示例。
完整 SAR 实测图像和连续 FPS 尚未上板验收。

历史证据位于工作区 `agent_work/logs/evidence/2026-11-04_v1.1_build/`，
不参与源码构建。过程见 [构建记录](../../agent_work/logs/2026-11-04_v1.1_pl_iw_minimal_project.md)
和 [精简记录](../../agent_work/logs/2026-11-04_v1.1_minimal_cleanup.md)。

