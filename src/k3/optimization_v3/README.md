# K3本版推理与回放
固定部署根目录 /root/radarbrain_k3_20261108，optimization_v3与optimization_v2是同级目录。
```bash
cd /root/radarbrain_k3_20261108/optimization_v3
chmod +x run_yolo11.sh run_pipeline.sh build_native.sh
./run_yolo11.sh
./run_pipeline.sh
./run_yolo11.sh --source /path/to/images --output results/new_images
```
原图方向与固定SAR样例一致时默认顺时针90度；已转好方向的图传 --rotation 0。
当前YOLO11s保持640输入，注意力子模块与DFL为FP32，其余适配运算为FP16。
两种运行默认都读同一批固定输入。run_pipeline是18张/轮、3轮的串行与重叠回放计时，结果保存results/pipeline_benchmark.json。
推理输出保存标注图、候选CSV、运行JSON。绘图与保存未包含在推理耗时中。
原生库可用build_native.sh重编译；check_preprocess.py用于四种旋转的张量逐元素核对。
export_attn32.py可由原浮点ONNX重建部署图，依赖onnx与onnxconverter-common。源图随01_相关证明材料/模型源文件提供，按需复制到../model_source/xu_yolo11s_fp32.onnx；板端运行不需要源图。
