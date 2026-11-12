# K3 INT8原生处理版本

在已有隔离部署根目录下运行：

```bash
cd /root/radarbrain_k3_20261108/optimization_v5
./run_int8.sh
./run_pipeline.sh
```

run_int8输出标注PNG、CSV与JSON，可传--source、--output、--rotation。默认顺时针90度，与原PT处理流程一致；原图已旋转则传--rotation 0。
模型复用optimization_v4/models/yolo11_int8_percentile.onnx，SHA256 cb243c62ce53e01e5bc592e3acb17f47cb5af466a62b308db2232af005bfa549。
优化是原生BMP/PNG读取、同数值OpenCV预处理及C++ NMS；其他图像格式沿用Pillow与原生预处理。v3的preprocess_native模块用于格式回退，根目录app/infer_k3.py提供既有类别和坐标定义。

三图四种旋转输入逐元素一致；11张检查帧和三图的NMS与NumPy版完全一致。回放每轮18张、3轮，原生重叠22.37张/秒，同次原INT8通路20.85张/秒。计时包含文件读取、预处理、推理、有限值检查与NMS，采集、成像、绘图与保存另计。此程序重复固定文件，衡量回放吞吐。

主表保留INT8复核40.5ms网络值，本次关闭ORT Profile的run_int8发布测量约37.9ms。线程配置为8，Profile与发布模式分别记录。

build_native.sh在K3上编译两个库，使用已有runtime内OpenCV头文件与库；首次编译按需在项目目录下载并解包libpng-dev头文件，运行库由现有系统与隔离runtime提供。
quantization模型和校准复现见optimization_v4，原混合精度模型保留optimization_v3。发布入口采用已测量的8线程配置。

回放默认无需检查用中间数组；如需重做11帧NMS检查，保留板端optimization_v4/holdout并传 --validate-holdout。对应发布记录已随包保存。
