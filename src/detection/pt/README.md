# SAR 双模型运行包

这个包包含两个 SAR 检测模型和 3 张 R 场景样图。运行 code.py，就会分别用两个模型检测 input 中的图片，将标框图、检测数据和并列图写入 output。

```text
SAR双模型运行包_R场景_20261104/
├── input/                  3 张 R 场景 SAR 样图
├── output/
│   ├── v5/                小 V5 的标框图、CSV、JSON
│   ├── int8/              徐硕 INT8 的标框图、CSV、JSON
│   └── compare/           两个模型的并列图
├── model/
│   ├── v5s_sar.pt         小 V5 原始权重
│   └── xu_yolo11s_int8.pt  徐硕 INT8 模型
├── code.py                模型加载、预处理、检测和结果导出
└── README.md
```

## 运行

环境为 Python 3.11。安装依赖后，在本目录运行：

```powershell
python -m pip install torch==2.10.0 numpy opencv-python packaging
python code.py
```

两个模型都使用 CPU，实测环境为 Windows、PyTorch 2.10.0。INT8 使用 PyTorch 的 oneDNN 后端。包内 output 已包含这 3 张样图的运行结果，可以直接查看。

单独运行一个模型：

```powershell
python code.py --model v5
python code.py --model int8
```

检测一张图片，或只看人和车：

```powershell
python code.py --source input/01_R35_SAR378.bmp
python code.py --classes person car --output output/person_car
```

换成自己的图片目录：

```powershell
python code.py --source "D:/SAR_images" --output "D:/SAR_results" --rotation 90
```

常用参数：--conf 0.2 设置置信度阈值；--iou 0.7 设置 NMS 阈值；--rotation 0/90/180/270 设置顺时针旋转角度。默认 --rotation auto 会按包内样图记录选择角度，新图片默认顺时针旋转 90 度。图片已经转到模型输入方向时，用 --rotation 0。两个模型都采用整图缩放补边到 640×640、RGB、像素除以 255 的预处理。

## 两个模型

| 选择 | 文件 | 大小 | 检测类别 | 框 |
|---|---|---:|---:|---|
| v5 | v5s_sar.pt | 4.55 MB | 20 类 | 旋转框 |
| int8 | xu_yolo11s_int8.pt | 10.82 MB | 9 类 | 水平框 |

小 V5 是一个模型同时识别 20 类，默认一次检测所有类别；--classes 可以只保留需要的类别。原始权重以 FP16 保存，本代码加载后使用 FP32 推理。V5 的加载兼容代码、CoordAtt 注意力模块和旋转框处理都包含在 code.py 中。

徐硕 INT8 是 TorchScript PT，代码用 torch.jit.load 加载。87 个卷积使用 INT8 运算，其余运算保留 FP32，接口输入和输出仍是 float32。直接调用模型时，两个版本的例子都在 code.py 的 load_model 和 infer 函数中。

```python
# 在本目录的其他 Python 脚本中调用
import importlib.util
import torch

spec = importlib.util.spec_from_file_location("sar_detector", "code.py")
sar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sar)
torch.set_num_threads(4)

image = sar.read_image(sar.ROOT / "input/01_R35_SAR378.bmp")
data, transform = sar.preprocess(image, rotation=90)
for which in ("v5", "int8"):
    model = sar.load_model(which)
    raw = sar.infer(model, data)
    decoded = sar.normalize_v5(raw) if which == "v5" else raw
    kind = "v5" if which == "v5" else "xu"
    detections = sar.postprocess(decoded, kind, conf=0.2, iou=0.7, max_det=300)
    print(which, len(detections))
```

V5 原始输出是 [1,25200,205]：4 个框参数、1 个目标分数、20 个类别分数、180 个角度分数；代码取每个框最高分的类别和角度，再执行 OpenCV 旋转 NMS。徐硕模型输出是 [1,13,8400]：4 个框参数和 9 个类别分数，再执行水平框 NMS。后处理得到的坐标先位于 640×640 输入平面，original_coordinates 函数负责换回原图坐标。

## 类别

两个模型的编号不同，使用 --classes person car 这样的英文类别名最方便。

| 类别 ID | 小 V5 | 徐硕 INT8 |
|---:|---|---|
| 0 | tree 树 | person 人 |
| 1 | manhole 井盖 | car 车 |
| 2 | bench 长椅 | bike 自行车 |
| 3 | hydrant 消防栓 | bush 灌木 |
| 4 | trunk 树干 | hydrant 消防栓 |
| 5 | bike 自行车 | handrail 栏杆 |
| 6 | light 灯 | building 建筑 |
| 7 | person 人 | light 灯 |
| 8 | walker，原数据单列类别 | tree 树 |
| 9 | roadblock 路障 | |
| 10 | handrail 栏杆 | |
| 11 | rider 骑行者 | |
| 12 | tricycle 三轮车 | |
| 13 | bush 灌木 | |
| 14 | bin 垃圾桶 | |
| 15 | guidepost 指示牌 | |
| 16 | car 车 | |
| 17 | fence 围栏 | |
| 18 | stair 台阶 | |
| 19 | building 建筑 | |

walker 与 person 沿用原模型的两个类别名，当前材料没有说明其标注区别。

## 样图和结果

| input 文件 | 来源 | 推理前顺时针旋转 |
|---|---|---:|
| 01_R35_SAR378.bmp | R35，第 378 帧 | 90° |
| 02_R07_F167.png | R07，第 167 帧 | 90° |
| 03_R35_SAR358.bmp | R35，第 358 帧 | 90° |

input 保留原始图片文件。output 中的标框图使用原图方向和尺寸，黄色框旁标注类别、置信度。compare 里左侧是小 V5，右侧是徐硕 INT8；两边使用相同比例显示，底部标注模型名称和框数。

detections.csv 每行一个框，记录图片名、类别、置信度和原图上四个顶点的坐标。results.json 同时记录预处理角度、阈值、图片及模型哈希。没有框的图片仍会保存对应结果，JSON 中检测列表为空。结果反映模型在这些样图上的检测输出，本包没有计算标签精度指标。

小 V5 的前向模块整理自随原权重提供的 YOLOv5 源码（GPL-3.0）。
