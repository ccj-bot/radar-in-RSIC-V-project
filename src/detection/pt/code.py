"""Run both SAR detectors: python code.py. See README.md for examples."""
import argparse
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sys
import sysconfig
import types
import warnings

# Keep Python's interactive-console interface available under the name code.
stdlib_spec = importlib.util.spec_from_file_location('_sar_stdlib_code', Path(sysconfig.get_path('stdlib')) / 'code.py')
stdlib_code = importlib.util.module_from_spec(stdlib_spec)
stdlib_spec.loader.exec_module(stdlib_code)
for exported_name in stdlib_code.__all__:
    globals()[exported_name] = getattr(stdlib_code, exported_name)
if __name__ != 'code':
    sys.modules.setdefault('code', stdlib_code)

import cv2
import numpy as np
from packaging.version import Version

ROOT = Path(__file__).resolve().parent
V5_NAMES = ['tree', 'manhole', 'bench', 'hydrant', 'trunk', 'bike', 'light', 'person', 'walker', 'roadblock', 'handrail', 'rider', 'tricycle', 'bush', 'bin', 'guidepost', 'car', 'fence', 'stair', 'building']
XU_NAMES = ['person', 'car', 'bike', 'bush', 'hydrant', 'handrail', 'building', 'light', 'tree']
MODELS = {'v5': ('v5s_sar.pt', V5_NAMES), 'int8': ('xu_yolo11s_int8.pt', XU_NAMES)}
SAMPLE_ROTATIONS = {'01_R35_SAR378': 90, '02_R07_F167': 90, '03_R35_SAR358': 90}

def check_version(current, minimum='0.0.0', **kwargs):
    return Version(current.split('+')[0]) >= Version(minimum)

def install_v5_classes():
    import torch
    from torch import nn
    # V5 components adapted from the supplied YOLOv5 source (GPL-3.0).
    def autopad(k, p=None):
        if p is None:
            p = k // 2 if isinstance(k, int) else [x // 2 for x in k]
        return p

    class Conv(nn.Module):

        def __init__(self, c1, c2, k=1, s=1, p=None, g=1, act=True):
            super().__init__()
            self.conv = nn.Conv2d(c1, c2, k, s, autopad(k, p), groups=g, bias=False)
            self.bn = nn.BatchNorm2d(c2)
            self.act = nn.SiLU() if act is True else act if isinstance(act, nn.Module) else nn.Identity()

        def forward(self, x):
            return self.act(self.bn(self.conv(x)))

        def forward_fuse(self, x):
            return self.act(self.conv(x))

    class DWConv(Conv):

        def __init__(self, c1, c2, k=1, s=1, act=True):
            super().__init__(c1, c2, k, s, g=math.gcd(c1, c2), act=act)

    class Bottleneck(nn.Module):

        def __init__(self, c1, c2, shortcut=True, g=1, e=0.5):
            super().__init__()
            c_ = int(c2 * e)
            self.cv1 = Conv(c1, c_, 1, 1)
            self.cv2 = Conv(c_, c2, 3, 1, g=g)
            self.add = shortcut and c1 == c2

        def forward(self, x):
            return x + self.cv2(self.cv1(x)) if self.add else self.cv2(self.cv1(x))

    class C3(nn.Module):

        def __init__(self, c1, c2, n=1, shortcut=True, g=1, e=0.5):
            super().__init__()
            c_ = int(c2 * e)
            self.cv1 = Conv(c1, c_, 1, 1)
            self.cv2 = Conv(c1, c_, 1, 1)
            self.cv3 = Conv(2 * c_, c2, 1)
            self.m = nn.Sequential(*(Bottleneck(c_, c_, shortcut, g, e=1.0) for _ in range(n)))

        def forward(self, x):
            return self.cv3(torch.cat((self.m(self.cv1(x)), self.cv2(x)), dim=1))

    class SPPF(nn.Module):

        def __init__(self, c1, c2, k=5):
            super().__init__()
            c_ = c1 // 2
            self.cv1 = Conv(c1, c_, 1, 1)
            self.cv2 = Conv(c_ * 4, c2, 1, 1)
            self.m = nn.MaxPool2d(kernel_size=k, stride=1, padding=k // 2)

        def forward(self, x):
            x = self.cv1(x)
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                y1 = self.m(x)
                y2 = self.m(y1)
                return self.cv2(torch.cat([x, y1, y2, self.m(y2)], 1))

    class Concat(nn.Module):

        def __init__(self, dimension=1):
            super().__init__()
            self.d = dimension

        def forward(self, x):
            return torch.cat(x, self.d)

    class h_sigmoid(nn.Module):

        def __init__(self, inplace=True):
            super(h_sigmoid, self).__init__()
            self.relu = nn.ReLU6(inplace=inplace)

        def forward(self, x):
            return self.relu(x + 3) / 6

    class h_swish(nn.Module):

        def __init__(self, inplace=True):
            super(h_swish, self).__init__()
            self.sigmoid = h_sigmoid(inplace=inplace)

        def forward(self, x):
            return x * self.sigmoid(x)

    class CoordAtt(nn.Module):

        def __init__(self, inp, oup, reduction=32):
            super(CoordAtt, self).__init__()
            self.pool_h = nn.AdaptiveAvgPool2d((None, 1))
            self.pool_w = nn.AdaptiveAvgPool2d((1, None))
            mip = max(8, inp // reduction)
            self.conv1 = nn.Conv2d(inp, mip, kernel_size=1, stride=1, padding=0)
            self.bn1 = nn.BatchNorm2d(mip)
            self.act = h_swish()
            self.conv_h = nn.Conv2d(mip, oup, kernel_size=1, stride=1, padding=0)
            self.conv_w = nn.Conv2d(mip, oup, kernel_size=1, stride=1, padding=0)

        def forward(self, x):
            identity = x
            n, c, h, w = x.size()
            x_h = self.pool_h(x)
            x_w = self.pool_w(x).permute(0, 1, 3, 2)
            y = torch.cat([x_h, x_w], dim=2)
            y = self.conv1(y)
            y = self.bn1(y)
            y = self.act(y)
            x_h, x_w = torch.split(y, [h, w], dim=2)
            x_w = x_w.permute(0, 1, 3, 2)
            a_h = self.conv_h(x_h).sigmoid()
            a_w = self.conv_w(x_w).sigmoid()
            out = identity * a_w * a_h
            return out

    class CoATT(nn.Module):

        def __init__(self, c1, c2, k=1, s=1, p=None, g=1, act=True):
            super(CoATT, self).__init__()
            self.conv = nn.Conv2d(c1, c2, k, s, autopad(k, p), groups=g, bias=False)
            self.CA = CoordAtt(c2, c2)
            self.bn = nn.BatchNorm2d(c2)
            self.act = nn.SiLU() if act is True else act if isinstance(act, nn.Module) else nn.Identity()

        def forward(self, x):
            return self.act(self.bn(self.CA(self.conv(x))))

    class Detect(nn.Module):
        stride = None
        onnx_dynamic = False

        def __init__(self, nc=80, anchors=(), ch=(), inplace=True):
            super().__init__()
            self.nc = nc
            self.no = nc + 5 + 180
            self.nl = len(anchors)
            self.na = len(anchors[0]) // 2
            self.grid = [torch.zeros(1)] * self.nl
            self.anchor_grid = [torch.zeros(1)] * self.nl
            self.register_buffer('anchors', torch.tensor(anchors).float().view(self.nl, -1, 2))
            self.m = nn.ModuleList((nn.Conv2d(x, self.no * self.na, 1) for x in ch))
            self.inplace = inplace

        def forward(self, x):
            """
            Args:
                x (list[P3_in,...]): torch.Size(b, c_i, h_i, w_i)

            Return：
                if train:
                    x (list[P3_out,...]): torch.Size(b, self.na, h_i, w_i, self.no), self.na means the number of anchors scales
                else:
                    inference (tensor): (b, n_all_anchors, self.no)
                    x (list[P3_in,...]): torch.Size(b, c_i, h_i, w_i)
            """
            z = []
            for i in range(self.nl):
                x[i] = self.m[i](x[i])
                bs, _, ny, nx = x[i].shape
                x[i] = x[i].view(bs, self.na, self.no, ny, nx).permute(0, 1, 3, 4, 2).contiguous()
                if not self.training:
                    if self.onnx_dynamic or self.grid[i].shape[2:4] != x[i].shape[2:4]:
                        self.grid[i], self.anchor_grid[i] = self._make_grid(nx, ny, i)
                    y = x[i].sigmoid()
                    if self.inplace:
                        y[..., 0:2] = (y[..., 0:2] * 2 - 0.5 + self.grid[i]) * self.stride[i]
                        y[..., 2:4] = (y[..., 2:4] * 2) ** 2 * self.anchor_grid[i]
                    else:
                        xy = (y[..., 0:2] * 2 - 0.5 + self.grid[i]) * self.stride[i]
                        wh = (y[..., 2:4] * 2) ** 2 * self.anchor_grid[i]
                        y = torch.cat((xy, wh, y[..., 4:]), -1)
                    z.append(y.view(bs, -1, self.no))
            return x if self.training else (torch.cat(z, 1), x)

        def _make_grid(self, nx=20, ny=20, i=0):
            d = self.anchors[i].device
            if check_version(torch.__version__, '1.10.0'):
                yv, xv = torch.meshgrid([torch.arange(ny, device=d), torch.arange(nx, device=d)], indexing='ij')
            else:
                yv, xv = torch.meshgrid([torch.arange(ny, device=d), torch.arange(nx, device=d)])
            grid = torch.stack((xv, yv), 2).expand((1, self.na, ny, nx, 2)).float()
            anchor_grid = (self.anchors[i].clone() * self.stride[i]).view((1, self.na, 1, 1, 2)).expand((1, self.na, ny, nx, 2)).float()
            return (grid, anchor_grid)

    class Model(nn.Module):

        def forward(self, x):
            return self._forward_once(x)

        def _forward_once(self, x):
            y = []
            for m in self.model:
                if m.f != -1:
                    x = y[m.f] if isinstance(m.f, int) else [x if j == -1 else y[j] for j in m.f]
                x = m(x)
                y.append(x if m.i in self.save else None)
            return x

        def _apply(self, fn):
            self = super()._apply(fn)
            m = self.model[-1]
            if isinstance(m, Detect):
                m.stride = fn(m.stride)
                m.grid = list(map(fn, m.grid))
                if isinstance(m.anchor_grid, list):
                    m.anchor_grid = list(map(fn, m.anchor_grid))
            return self

    package = types.ModuleType('models')
    package.__path__ = []
    common = types.ModuleType('models.common')
    yolo = types.ModuleType('models.yolo')
    classes = locals().copy()
    for name in ('Conv', 'DWConv', 'Bottleneck', 'C3', 'SPPF', 'Concat', 'h_sigmoid', 'h_swish', 'CoordAtt', 'CoATT'):
        setattr(common, name, classes[name])
    yolo.Detect, yolo.Model = Detect, Model
    package.common, package.yolo = common, yolo
    sys.modules.update({'models': package, 'models.common': common, 'models.yolo': yolo})


def load_model(which):
    """Return an inference model on CPU; both versions take float32 inputs."""
    global torch
    import torch
    weight = ROOT / 'model' / MODELS[which][0]
    if which == 'int8':
        if 'onednn' not in torch.backends.quantized.supported_engines:
            raise RuntimeError('Install a PyTorch CPU build with the oneDNN quantization backend.')
        torch.backends.quantized.engine = 'onednn'
        # File objects also work with Chinese Windows paths.
        with weight.open('rb') as stream:
            return torch.jit.load(stream, map_location='cpu').eval()

    install_v5_classes()
    checkpoint = torch.load(weight, map_location='cpu', weights_only=False)
    model = (checkpoint.get('ema') or checkpoint['model']).float().eval()
    for layer in model.modules():
        if isinstance(layer, torch.nn.Upsample) and not hasattr(layer, 'recompute_scale_factor'):
            layer.recompute_scale_factor = None
    return model

def preprocess(image, rotation, size=640):
    codes = {90: cv2.ROTATE_90_CLOCKWISE, 180: cv2.ROTATE_180, 270: cv2.ROTATE_90_COUNTERCLOCKWISE}
    work = cv2.rotate(image, codes[rotation]) if rotation else image.copy()
    h, w = work.shape[:2]
    ratio = min(size / h, size / w)
    nw, nh = (round(w * ratio), round(h * ratio))
    dw, dh = ((size - nw) / 2, (size - nh) / 2)
    left, top = (round(dw - 0.1), round(dh - 0.1))
    padded = cv2.copyMakeBorder(cv2.resize(work, (nw, nh)), top, round(dh + 0.1), left, round(dw + 0.1), cv2.BORDER_CONSTANT, value=(114, 114, 114))
    data = np.ascontiguousarray(padded[:, :, ::-1].transpose(2, 0, 1)[None]).astype(np.float32) / 255
    return (data, (ratio, left, top))

def polygon(cx, cy, w, h, theta):
    c, s = (math.cos(theta), math.sin(theta))
    center = np.array([cx, cy])
    v1 = np.array([w * c / 2, -w * s / 2])
    v2 = np.array([-h * s / 2, -h * c / 2])
    return np.stack([center + v1 + v2, center + v1 - v2, center - v1 - v2, center - v1 + v2])

def postprocess(raw, kind, conf, iou, max_det):
    detections = []
    if kind == 'v5':
        a = raw[0]
        a = a[np.isfinite(a).all(1) & (a[:, 5] > conf) & (a[:, 2] > 0) & (a[:, 3] > 0)]
        for cls in np.unique(a[:, 6].astype(int)):
            subset = a[a[:, 6].astype(int) == cls]
            rects = [((float(r[0]), float(r[1])), (float(r[2]), float(r[3])), float(-r[4] * 180 / np.pi)) for r in subset]
            ids = cv2.dnn.NMSBoxesRotated(rects, subset[:, 5].tolist(), conf, iou)
            for idx in np.asarray(ids).reshape(-1) if len(ids) else []:
                r = subset[int(idx)]
                detections.append({'class_id': int(cls), 'class_name': V5_NAMES[int(cls)], 'confidence': float(r[5]), 'polygon_input': polygon(*r[:5]).tolist()})
    else:
        a = raw[0].T
        scores = a[:, 4:].max(1)
        classes = a[:, 4:].argmax(1)
        valid = np.isfinite(a).all(1) & (scores > conf) & (a[:, 2] > 0) & (a[:, 3] > 0)
        a, scores, classes = (a[valid], scores[valid], classes[valid])
        for cls in np.unique(classes):
            indices = np.where(classes == cls)[0]
            rects = [[float(a[j, 0] - a[j, 2] / 2), float(a[j, 1] - a[j, 3] / 2), float(a[j, 2]), float(a[j, 3])] for j in indices]
            ids = cv2.dnn.NMSBoxes(rects, scores[indices].tolist(), conf, iou)
            for k in np.asarray(ids).reshape(-1) if len(ids) else []:
                j = indices[int(k)]
                detections.append({'class_id': int(cls), 'class_name': XU_NAMES[int(cls)], 'confidence': float(scores[j]), 'polygon_input': polygon(*a[j, :4], 0).tolist()})
    return sorted(detections, key=lambda x: x['confidence'], reverse=True)[:max_det]

def original_coordinates(poly, pre, shape, rotation):
    ratio, left, top = pre
    p = np.asarray(poly, float).copy()
    p[:, 0] = (p[:, 0] - left) / ratio
    p[:, 1] = (p[:, 1] - top) / ratio
    h, w = shape[:2]
    if rotation == 90:
        p = np.stack([p[:, 1], h - p[:, 0]], 1)
    elif rotation == 180:
        p = np.stack([w - p[:, 0], h - p[:, 1]], 1)
    elif rotation == 270:
        p = np.stack([w - p[:, 1], p[:, 0]], 1)
    return p

def normalize_v5(raw):
    """Decode class and angle bins to cx,cy,w,h,theta,score,class_id."""
    scores = raw[:, :, 5:25] * raw[:, :, 4:5]
    angles = (raw[:, :, 25:].argmax(-1, keepdims=True).astype(np.float32) - 90) * (np.pi / 180)
    return np.concatenate([raw[:, :, :4], angles, scores.max(-1, keepdims=True),
                           scores.argmax(-1, keepdims=True).astype(np.float32)], axis=-1)

def read_image(path):
    image = cv2.imdecode(np.frombuffer(path.read_bytes(), np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f'Cannot read image: {path}')
    return image

def write_image(path, image):
    ok, encoded = cv2.imencode('.png', image)
    if not ok:
        raise IOError(f'Cannot encode image: {path}')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(encoded.tobytes())

def draw_detections(image, detections):
    result = image.copy()
    scale = max(.5, min(1., image.shape[1] / 1600))
    for detection in detections:
        points = np.asarray(detection['polygon_original']).round().astype(np.int32)
        cv2.polylines(result, [points], True, (0, 255, 255), 2)
        text = f"{detection['class_name']} {detection['confidence']:.3f}"
        (width, height), baseline = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, 1)
        x = max(0, min(int(points[:, 0].min()), image.shape[1] - width - 3))
        y = max(height + 3, min(int(points[:, 1].min()) - 5, image.shape[0] - baseline - 1))
        cv2.rectangle(result, (x, y - height - 2), (x + width + 2, y + baseline), (0, 0, 0), -1)
        cv2.putText(result, text, (x + 1, y), cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 255, 255), 1, cv2.LINE_AA)
    return result

def compare_image(left, right, left_count, right_count):
    """Same source, scale and brightness in both panels; labels below images."""
    height, width = left.shape[:2]
    scale = min(600 / width, 600 / height, 1.)
    new_width, new_height = round(width * scale), round(height * scale)
    panel_width, gap, footer = 600, 16, 70
    canvas = np.full((new_height + footer, panel_width * 2 + gap, 3), 255, np.uint8)
    for i, (image, label) in enumerate([(left, f'Small V5  |  {left_count} boxes'),
                                      (right, f'Xu INT8  |  {right_count} boxes')]):
        x = i * (panel_width + gap)
        display = cv2.resize(image, (new_width, new_height), interpolation=cv2.INTER_AREA)
        canvas[:new_height, x + (panel_width - new_width) // 2:x + (panel_width + new_width) // 2] = display
        (label_width, _), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, .8, 1)
        cv2.putText(canvas, label, (x + (panel_width - label_width) // 2, new_height + 44),
                    cv2.FONT_HERSHEY_SIMPLEX, .8, (25, 25, 25), 1, cv2.LINE_AA)
    return canvas, scale

def infer(model, data):
    with torch.inference_mode():
        result = model(torch.from_numpy(data))
        if isinstance(result, (tuple, list)):
            result = result[0]
        return result.float().cpu().numpy()

def run(which, files, args):
    model = load_model(which)
    folder = args.output / which
    folder.mkdir(parents=True, exist_ok=True)
    records, rows = [], []
    for source in files:
        rotation = SAMPLE_ROTATIONS.get(source.stem, 90) if args.rotation == 'auto' else int(args.rotation)
        image = read_image(source)
        data, transform = preprocess(image, rotation)
        raw = infer(model, data)
        if which == 'v5':
            raw = normalize_v5(raw)
        detections = postprocess(raw, 'v5' if which == 'v5' else 'xu', args.conf, args.iou, args.max_det)
        if args.classes:
            detections = [d for d in detections if d['class_name'] in args.classes]
        for index, detection in enumerate(detections):
            points = original_coordinates(detection['polygon_input'], transform, image.shape, rotation)
            detection['polygon_original'] = points.tolist()
            rows.append({'image': source.name, 'index': index, 'class_id': detection['class_id'],
                         'class_name': detection['class_name'], 'confidence': detection['confidence'],
                         **dict(zip(['x1', 'y1', 'x2', 'y2', 'x3', 'y3', 'x4', 'y4'], points.reshape(-1).tolist()))})
        write_image(folder / (source.stem + '.png'), draw_detections(image, detections))
        records.append({'image': source.name, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                        'original_shape': list(image.shape), 'rotation_clockwise': rotation,
                        'preprocess': {'ratio': transform[0], 'left': transform[1], 'top': transform[2]},
                        'count': len(detections), 'detections': detections})
        print(f'{which:4s}  {source.name}  {len(detections)} boxes', flush=True)
    fields = ['image', 'index', 'class_id', 'class_name', 'confidence', 'x1', 'y1', 'x2', 'y2', 'x3', 'y3', 'x4', 'y4']
    with (folder / 'detections.csv').open('w', encoding='utf-8-sig', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    weight = ROOT / 'model' / MODELS[which][0]
    report = {'model': weight.name, 'model_sha256': hashlib.sha256(weight.read_bytes()).hexdigest(),
              'classes': MODELS[which][1], 'device': 'cpu', 'torch_version': torch.__version__,
              'input_shape': [1, 3, 640, 640], 'input_dtype': 'float32',
              'precision': 'FP32 inference from original FP16 weights' if which == 'v5' else 'INT8 convolutions / FP32 remaining operations',
              'preprocessing': 'clockwise rotation, square letterbox, RGB, divide by 255',
              'conf': args.conf, 'iou': args.iou, 'max_det': args.max_det,
              'class_filter': args.classes, 'images': records}
    (folder / 'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return records

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', choices=['all', 'v5', 'int8'], default='all')
    parser.add_argument('--source', type=Path, default=ROOT / 'input')
    parser.add_argument('--output', type=Path, default=ROOT / 'output')
    parser.add_argument('--rotation', choices=['auto', '0', '90', '180', '270'], default='auto')
    parser.add_argument('--conf', type=float, default=.2)
    parser.add_argument('--iou', type=float, default=.7)
    parser.add_argument('--max-det', type=int, default=300)
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--classes', nargs='+', choices=sorted(set(V5_NAMES + XU_NAMES)))
    args = parser.parse_args()
    import torch
    if not 0 <= args.conf <= 1 or not 0 <= args.iou <= 1:
        parser.error('conf and iou must be in [0,1]')
    if args.threads <= 0 or args.max_det <= 0:
        parser.error('threads and max-det must be positive')
    torch.set_num_threads(args.threads)
    if args.source.is_dir():
        files = sorted(p for p in args.source.iterdir() if p.suffix.lower() in {'.png', '.bmp', '.jpg', '.jpeg', '.tif', '.tiff'})
    else:
        files = [args.source]
    if not files:
        parser.error('No images in the input directory')
    selected = ['v5', 'int8'] if args.model == 'all' else [args.model]
    reports = {which: run(which, files, args) for which in selected}
    if args.model == 'all':
        figures = []
        for i, source in enumerate(files):
            left = read_image(args.output / 'v5' / (source.stem + '.png'))
            right = read_image(args.output / 'int8' / (source.stem + '.png'))
            picture, scale = compare_image(left, right, reports['v5'][i]['count'], reports['int8'][i]['count'])
            filename = source.stem + '.png'
            write_image(args.output / 'compare' / filename, picture)
            figures.append({'file': filename, 'source': source.name, 'source_sha256': reports['v5'][i]['sha256'],
                            'pixel_shape': list(picture.shape), 'display_scale': scale,
                            'left': 'v5', 'right': 'int8', 'intensity_adjustment': 'none'})
        (args.output / 'compare' / 'images.json').write_text(json.dumps(figures, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Output: {args.output.resolve()}')

if __name__ == '__main__':
    main()
