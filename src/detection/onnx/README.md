# SAR轻量化检测运行说明
建议从这个目录开始。程序覆盖预处理、ONNX推理、旋转框或水平框解码、NMS和原图坐标还原。

```bash
python -m pip install -r requirements.txt
python infer_onnx.py --source sample_input --output runs/compact --model compact-fp16 --rotation 90
python infer_onnx.py --source sample_input --output runs/int8 --model xu-int8 --rotation 90
```

默认小模型约206万参数，FP16权重ONNX约4.27MB；对照的YOLO11s部分INT8卷积模型约10.13MB。
输出位于annotated、detections.csv、results.json。输出记录模型、阈值、坐标及候选类别。
运行依赖见requirements.txt。FP32小模型可用--model compact-fp32运行。

本次提供可在现有PC环境复现的成果。K3迁移使用该ONNX入口，从FP32通路开始确认运行时和算子支持，再选择FP16或INT8；原PT包中的oneDNN INT8依赖现有CPU环境。
模型保留原始来源。原YOLOv5代码声明GPL-3.0，参考源码保留原版权头；量化与导出成果不改变原模型权利。
