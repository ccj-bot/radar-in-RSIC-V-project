# 复数回波到BP成像的独立运行示例
```bash
python -m pip install -r requirements.txt
python run_demo.py --output runs/bp_demo
```
该入口直接调用现有研究代码中的synthesize、compress、backproject数值核，完成复数回波合成、IFFT距离压缩、插值和球面相位补偿BP。
使用连续PRF10000Hz、平台3m/s、1000chirp、三个静止点散射目标，输出二维灰度图、复数矩阵及聚焦位置检查。首次运行包含Numba编译开销。
既有车辆时序及空间自适应孔径成果位于证明材料中，属于受控成像仿真。这个小入口用于快速确认数值链路与迁移前基线，不直接读取原始雷达bin。
provenance保存抽取数值核的原脚本。内含原研究目录引用的文件仅供追溯，运行入口为本目录run_demo.py。
