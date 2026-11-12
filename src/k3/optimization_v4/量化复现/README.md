# INT8量化复现

厂商来源 https://github.com/spacemit-com/xslim ，本次保存源码版本2.1.2。
解压厂商源码/xslim_main.zip，在独立Python环境安装源码与requirements.txt对应依赖；本次主机环境记录在证明材料/K3实机记录/host_environment.json。
原始FP32 ONNX位于证明材料/模型源文件/xu_yolo11s_fp32.onnx；校准数据与列表位于证明材料/INT8校准与检查输入。
运行示例：

```bash
python -X utf8 reproduce_quantization.py --input /path/xu_yolo11s_fp32.onnx --calibration-list /path/INT8校准与检查输入/calibration.txt --output-dir /path/rebuilt
```

校准列表中的npy已经是RGB、顺时针90度、640补边和/255的输入。原图哈希与帧划分见manifest.json。
运行板端直接使用models/yolo11_int8_percentile.onnx，无需重复量化。
