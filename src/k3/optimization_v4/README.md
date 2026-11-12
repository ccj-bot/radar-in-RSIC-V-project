# K3 INT8与浮点解码

YOLO11s保持640输入和原网络结构。采用厂商XSlim 2.1.2源码版本，以17张R35帧进行percentile校准，主网络为INT8，检测头卷积后的坐标解码、分类Sigmoid及拼接采用浮点。

```bash
cd /root/radarbrain_k3_20261108/optimization_v4
./run_int8.sh
./run_pipeline.sh
```

最新原生处理入口位于同级optimization_v5。模型models/yolo11_int8_percentile.onnx的SHA256为cb243c62ce53e01e5bc592e3acb17f47cb5af466a62b308db2232af005bfa549。
网络复核40.5ms，先预热3次、固定三图各测10次。11张按时间划分的检查帧相对浮点模型保留全部30个车辆候选，匹配框IoU中位0.847、最小0.809。原始输出与协议随证明材料提供。
量化复现见量化复现/README.md；原始浮点ONNX位于证明材料/模型源文件，校准输入与列表位于证明材料/INT8校准与检查输入。
文件检测回放按读图至NMS计时，采集、SAR成像与显示分别记录。
