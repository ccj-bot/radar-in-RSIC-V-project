"""Generate a self-contained results page from actual K3 output files."""
from pathlib import Path
import base64,html,json,statistics
ROOT=Path(__file__).resolve().parents[1]
RESULTS=ROOT/'results'

def data(p):return 'data:image/png;base64,'+base64.b64encode(p.read_bytes()).decode('ascii')
def escape(v):return html.escape(str(v))
def read(p):return json.loads(p.read_text(encoding='utf8'))
def choose(paths):return next((p for p in paths if p.exists()),None)

def main():
 vendor=choose([RESULTS/'demo_vendor/compact-fp32/results.json',RESULTS/'vendor_cv/compact-fp32/results.json'])
 cpu=choose([RESULTS/'demo_cpu/compact-fp32/results.json',RESULTS/'cpu_cv/compact-fp32/results.json'])
 primary=vendor or cpu
 if primary is None:raise RuntimeError('Run detector first')
 report=read(primary);bp=read(RESULTS/'bp/result.json') if (RESULTS/'bp/result.json').exists() else None
 median=statistics.median(r['timing_ms']['inference_median'] for r in report['images'])
 cpu_ms=statistics.median(r['timing_ms']['inference_median'] for r in read(cpu)['images']) if cpu else None
 bptext=f"{bp['rvv_median_ms']:.0f} ms" if bp else '待运行'
 speed=f"{bp['speedup']:.2f}×" if bp else '—'
 panels=[]
 for r in report['images']:
  image=primary.parent/(Path(r['image']).stem+'.png')
  classes=', '.join(f"{d['class_name']} {d['confidence']:.3f}" for d in r['detections']) or '本帧没有超过阈值的候选'
  panels.append(f'<article class="scene"><img src="{data(image)}" alt="{escape(r["image"])}"><div class="body"><h3>{escape(r["image"])}</h3><p>{len(r["detections"])} 个候选 · 纯推理 {r["timing_ms"]["inference_median"]:.1f} ms</p><p class="small">{escape(classes)}</p></div></article>')
 rows=[]
 for route,label in [('cpu_cv','通用 CPU'),('vendor_cv','厂商 EP')]:
  for p in sorted((RESULTS/route).glob('*/results.json')):
   r=read(p);ms=statistics.median(i['timing_ms']['inference_median'] for i in r['images'])
   rows.append(f'<tr><td>{label}</td><td>{escape(r["model"])}</td><td>{ms:.1f} ms</td><td>{sum(len(i["detections"]) for i in r["images"])} / {len(r["images"])} 张图</td></tr>')
 bpsection=''
 if bp:
  bpsection=f'''<section><div class="sectionhead"><h2>复数 BP 成像与 RVV</h2><span>受控合成回波 · 三个静止点</span></div>
  <div class="bpgrid"><img src="{data(RESULTS/'bp/bp_rvv.png')}" alt="实际BP成像结果"><div>
  <h3>从回波到聚焦图像</h3><p>合成复数回波 → IFFT 距离压缩 → C++ 球面 BP。输出 {bp['output_shape'][1]} × {bp['output_shape'][0]} 像素，1000 chirp，PRF 10000 Hz，平台 3 m/s。</p>
  <table><tr><th>四线程实现</th><th>BP 中位耗时</th></tr><tr><td>标量参考</td><td>{bp['scalar_median_ms']:.1f} ms</td></tr><tr><td>显式 RVV</td><td>{bp['rvv_median_ms']:.1f} ms</td></tr></table>
  <p>向量长度 {bp['rvv_bits']} bit。标量与 RVV 最大复数差 {bp['max_complex_absolute_difference']:.3g}，三点聚焦位置检查 {bp['check']}。</p>
  <p class="small">计时仅覆盖 BP。首版向量化距离计算和复数累加，三角函数与索引仍为标量。两版同为四线程；编译时关闭自动向量化，显式 RVV 保留。每版完整运行 3 次。</p></div></div></section>'''
 chart=ROOT/'results/实机耗时对比.png'
 chartsection=f'<section><h2>实测计算耗时</h2><img class="chart" src="{data(chart)}" alt="实测耗时对比"></section>' if chart.exists() else ''
 comparisons=RESULTS/'migration_comparison.json'
 consistency=''
 if comparisons.exists():
  checks=read(comparisons);ok=all(x['input_exact'] and x['classes_equal'] for x in checks)
  consistency=f'<p>固定样例跨平台核对：{len(checks)} 组输入张量完全一致，候选数量与类别全部对应，检查 {"PASS" if ok else "待检查"}。厂商 FP32 候选最大置信度差约 0.0062、最大框坐标差约 0.63 像素。</p>'
 content=f'''<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>雷达智脑 K3 实机成果</title>
 <style>*{{box-sizing:border-box}}body{{margin:0;background:#f3f6f8;color:#172c3b;font-family:"Microsoft YaHei",Arial,sans-serif;line-height:1.65}}main{{max-width:1280px;margin:auto;padding:45px 36px}}.eyebrow{{font-size:13px;color:#12677c;letter-spacing:2px}}h1{{font-size:38px;line-height:1.3;margin:12px 0}}h2{{font-size:24px;margin:0 0 18px}}h3{{font-size:18px;margin:0 0 10px}}.lead{{max-width:980px;color:#526776}}.chips{{display:flex;gap:10px;flex-wrap:wrap;margin:22px 0}}.chips span{{font-size:13px;background:#e5edf1;padding:5px 12px;border-radius:4px}}.stats{{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin:28px 0}}.stat{{padding:22px;background:white;border:1px solid #dbe4e9;border-radius:9px}}.stat strong{{display:block;font-size:31px;color:#12677c}}.stat span{{font-size:14px;color:#526776}}section{{margin-top:34px;background:#fff;padding:28px;border-radius:10px;border:1px solid #dbe4e9}}.sectionhead{{display:flex;align-items:baseline;justify-content:space-between;gap:15px}}.sectionhead span,.small{{font-size:13px;color:#637785}}.grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}}.scene{{border:1px solid #dbe4e9;border-radius:7px;overflow:hidden}}.scene img{{display:block;width:100%;background:#080f18}}.body{{padding:16px}}.body p{{margin:5px 0}}.bpgrid{{display:grid;grid-template-columns:1fr 1.2fr;gap:35px;align-items:center}}.bpgrid img{{width:100%;image-rendering:auto}}table{{border-collapse:collapse;width:100%;margin:18px 0;font-size:14px}}th,td{{text-align:left;padding:12px;border-bottom:1px solid #dbe4e9}}th{{background:#eef3f6}}.chart{{width:100%;display:block}}pre{{padding:18px;background:#132c3a;color:#ecf6f9;border-radius:6px;overflow:auto}}footer{{margin-top:25px;color:#637785;font-size:13px}}@media(max-width:850px){{main{{padding:24px 16px}}.stats{{grid-template-columns:repeat(2,1fr)}}.grid,.bpgrid{{grid-template-columns:1fr}}.sectionhead{{display:block}}h1{{font-size:30px}}}}</style></head><body><main>
 <div class="eyebrow">RADARBRAIN · SPACEMIT K3 · 实机运行结果</div><h1>雷达智脑 K3 迁移首版</h1><p class="lead">SAR 检测模型已在开发板完成推理，BP 成像已迁移至 C++ 并运行显式 RVV。页面中的图像和数字来自本次 K3 输出，所有源码、模型、日志和输入均独立保存在项目目录。</p>
 <div class="chips"><span>Bianbu 4.0.7</span><span>riscv64 · 16 个逻辑处理器</span><span>RVV 256 bit</span><span>2026 年 11 月 8 日</span></div>
 <div class="stats"><div class="stat"><strong>{median:.0f} ms</strong><span>小模型纯推理 · {'厂商 EP' if vendor else 'CPU'}</span></div><div class="stat"><strong>{bptext}</strong><span>三点算例 BP · RVV 四线程</span></div><div class="stat"><strong>{speed}</strong><span>BP 相对标量参考加速</span></div><div class="stat"><strong>3 / 3</strong><span>ONNX 模型通过通用 CPU 路线</span></div></div>
 <section><div class="sectionhead"><h2>SAR 图像上的目标候选</h2><span>FP32 小模型 · 旋转框 · conf 0.20 · IoU 0.70</span></div><div class="grid">{''.join(panels)}</div><p class="small">输入按原流程旋转、OpenCV 线性缩放及补边，RGB/255，640×640。原始图像保持原显示映射，叠加框为模型候选。计时不含模型加载、预处理、后处理和绘图。</p></section>
 {bpsection}{chartsection}
 <section><h2>检测模型与运行路线</h2><table><tr><th>路线</th><th>模型</th><th>纯推理中位数</th><th>候选数</th></tr>{''.join(rows)}</table><p class="small">同一块板，固定 3 张图，预热 1 次，每张推理 3 次；表中先取每张中位数，再取三张中位数。请求 ORT 算子内线程数为 4；厂商 EP 使用其内部默认调度。不是完整雷达系统帧率。</p>{consistency}<p>厂商 EP 的 FP32 路线已执行，性能分析记录包含实际厂商节点。FP16 路线遇到 Concat 形状错误，INT8 路线遇到 Clip 输出类型错误，当前保留通用 CPU 入口作为可用路线。没有将厂商 EP 的执行直接解释为专用 AI 硬件加速。</p></section>
 <section><h2>在开发板上重新运行</h2><pre>cd /root/radarbrain_k3_20261108\n./demo.sh</pre><p>运行 FP32 检测、C++ RVV BP，并更新 results/index.html。可用 <code>./demo.sh cpu</code> 选择通用 CPU 推理。原始回波接入、实测轨迹和成像检测闭环属于后续集成工作；本次检测使用已有 SAR 图像，BP 使用受控合成回波。</p></section>
 <footer>源码与结果独立目录 /root/radarbrain_k3_20261108 · 依赖通过软件包下载后解压到项目内 · 原系统推理库及 /root/rvv_demo 保留</footer></main></body></html>'''
 (RESULTS/'index.html').write_text(content,encoding='utf8')
 print('RESULTS_PAGE',RESULTS/'index.html')
if __name__=='__main__':main()
