"""Full grayscale synthetic SAR scenes and an HRRP/BP comparison.

Physical imaging is synthetic single-scattering matched BP. GM PNG is read only
as an independent visual reference and never enters the synthetic echo/image.
"""
from pathlib import Path
import argparse
import json
import math
import os
import sys
import time

import numpy as np
import pandas as pd
import numba
from numba import njit, prange
from PIL import Image
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from render_bp_2d_simulation_20261105 import backproject, direct_kernel, geometry, C, NFFT
from audit_nx_imaging_parameters_20261105 import dump, sha

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "docs/sar_research/BP_PARAMETER_BASELINE_20261105.json"
GM = ROOT.parent / "data/GM_RM019/GM_RM019_SARframes_gray/000269.png"
SEED = 20261105


@njit(parallel=True, cache=True)
def synthesize(points, coeff, apx, first_frequency, df, nr):
    result = np.zeros((len(apx), nr), dtype=np.complex128)
    for m in prange(len(apx)):
        for j in range(len(points)):
            r = math.sqrt((points[j, 0] - apx[m]) ** 2 + points[j, 1] ** 2)
            p0 = -4 * np.pi * first_frequency * r / C
            pd = -4 * np.pi * df * r / C
            z = coeff[j] * complex(math.cos(p0), math.sin(p0))
            step = complex(math.cos(pd), math.sin(pd))
            for n in range(nr):
                result[m, n] += z
                z *= step
    return result


def scene():
    rng = np.random.default_rng(SEED)
    records = []
    def add(x, y, amp, phase, category, group):
        records.append(dict(x_display_m=x, y_display_m=y, amplitude=amp,
                            phase_rad=phase, category=category, group=group))
    # Distributed coherent ground clutter: positions and complex coefficients
    # are actual forward-model inputs, not a texture pasted onto the image.
    for i in range(1600):
        angle = rng.uniform(-np.pi / 3, np.pi / 3)
        r = np.sqrt(rng.uniform(2. ** 2, 38. ** 2))
        add(r * np.sin(angle), r * np.cos(angle), .035 * rng.rayleigh(),
            rng.uniform(-np.pi, np.pi), "distributed_scatterer", "ground")
    for side in [-1, 1]:
        for i, y in enumerate(np.linspace(3., 37., 260)):
            x = side * (5.8 + .0025 * (y - 18.) ** 2)
            if abs(np.rad2deg(np.arctan2(x, y))) > 59:
                continue
            add(x, y, .075 + rng.uniform(0, .06), rng.uniform(-np.pi, np.pi),
                "road_edge_scatterer", f"road_side{side}")
    # Stylized 4.2m x 1.8m scatterer groups, not CAD/EM vehicle models.
    centers = [(-3., 7., 10.), (3.2, 10., -12.), (-6.5, 16., 18.),
               (2., 23., -8.), (-9., 29., 12.)]
    for g, (cx, cy, yaw) in enumerate(centers, 1):
        angle = np.deg2rad(yaw)
        rot = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
        for sx in [-.9, .9]:
            for sy in [-2.1, 2.1]:
                p = np.array([cx, cy]) + rot @ [sx, sy]
                add(p[0], p[1], rng.uniform(.8, 1.5), rng.uniform(-np.pi, np.pi),
                    "strong_object_scatterer", f"object{g}")
            for sy in np.linspace(-1.8, 1.8, 24):
                p = np.array([cx, cy]) + rot @ [sx, sy]
                add(p[0], p[1], rng.uniform(.13, .30), rng.uniform(-np.pi, np.pi),
                    "object_edge_scatterer", f"object{g}")
    for i, p in enumerate([(-1.0, 3.), (9., 18.), (7., 32.)], 1):
        add(*p, 1., 0., "isolated_point", f"point{i}")
    add(-.05, 14., 1., 0., "double_point", "pair10cm")
    add(.05, 14., 1., 0., "double_point", "pair10cm")
    table = pd.DataFrame(records)
    # Rotate display coordinates into the unchanged reference BP coordinates.
    # AQref=-30deg becomes the image forward/display axis; +/-60deg fan in PNG.
    a = np.deg2rad(30.)
    x, y = table.x_display_m.to_numpy(), table.y_display_m.to_numpy()
    table["x_reference_m"] = x * np.cos(a) - y * np.sin(a)
    table["y_reference_m"] = x * np.sin(a) + y * np.cos(a)
    return table


def to_gray(z, mask):
    power_db = 10 * np.log10(np.maximum(abs(z) ** 2, 1e-14))
    gray = np.clip((power_db + 45) / 50, 0, 1)  # Same -45..+5dB for all BP images.
    result = np.round(gray * 255).astype(np.uint8)
    result[~mask] = 0
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    if not out.is_relative_to(ROOT / "outputs"):
        raise ValueError("Wrong output root")
    out.mkdir(parents=True, exist_ok=False)
    numba.set_num_threads(min(8, os.cpu_count() or 1))
    plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "DejaVu Sans"]
    plt.rcParams["axes.unicode_minus"] = False
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    assert baseline["simulation_trajectory"]["speed_mps"] == 3.
    assert baseline["prf_hz"] == 10000.
    wave = baseline["waveform"]
    freq = wave["start_frequency_hz"] + wave["slope_hz_per_s"] * (
        wave["adc_start_s"] + np.arange(wave["adc_samples"]) / wave["adc_sample_rate_hz"])
    df = wave["slope_hz_per_s"] / wave["adc_sample_rate_hz"]
    fref = float((freq[0] + freq[-1]) / 2)
    drange = C / (2 * NFFT * df)
    retained = len(freq) - 100
    sources = [BASELINE, Path(__file__), Path(__file__).with_name("render_bp_2d_simulation_20261105.py"), GM]
    hashes = {str(p): sha(p) for p in sources}
    table = scene()
    table.to_csv(out / "synthetic_scene_scatterers.csv", index=False)
    points = table[["x_reference_m", "y_reference_m"]].to_numpy()
    coeff = table.amplitude.to_numpy() * np.exp(1j * table.phase_rad.to_numpy())
    pair = table[table.group == "pair10cm"][["x_display_m", "y_display_m"]].to_numpy()
    assert np.isclose(np.linalg.norm(pair[0] - pair[1]), .10)
    protocol = dict(seed=SEED, model="Single scattering, stationary point cloud, phase/RVP-calibrated equivalent frequency echoes",
                    speed_mps=3., prf_hz=10000., step_chirps=200, apertures=[200, 1000, 2000],
                    scatterer_counts=table.category.value_counts().to_dict(),
                    display=dict(width=2308, height=1334, nominal_metres_per_pixel=.03,
                                 radar_pixel_x=1154., radar_pixel_y=1330.6, range_limit_m=40.,
                                 fan_half_width_deg=60., reference_sector_center_deg=-30.,
                                 mapping="display(xt,yt) -> reference(x=xt*cos30-yt*sin30, y=xt*sin30+yt*cos30)",
                                 gray="Fixed power mapping -45..+5dB, unit scatterer peak reference; no separate panel normalization"),
                    pair_separation_m=.1,
                    BP="Coherent sum of interpolated complex HRRP with exact spherical phase compensation",
                    real_GM_use="Independent display comparison only; not a background texture, input scene, or calibration source",
                    object_scope="Vehicle-size synthetic scatterer groups with ground/road scattering; no CAD/EM claim")
    dump(out / "protocol.json", protocol)
    started = time.perf_counter()
    apx = geometry(2000)
    echo = synthesize(points, coeff, apx, float(freq[0]), float(df), len(freq))
    echo[:, :100] = 0
    # Verify the complex recurrence used for efficient synthesis against direct
    # point/complex-exponential summation at independent index pairs.
    forward_errors = []
    for m, n in [(0, 100), (999, 700), (1999, 1023)]:
        rr = np.linalg.norm(points - [apx[m], 0.], axis=1)
        exact = np.sum(coeff * np.exp(-1j * 4 * np.pi / C * freq[n] * rr))
        forward_errors.append(abs(exact - echo[m, n]))
    assert max(forward_errors) < 1e-6
    print("synthesized", len(points), "scatterers; elapsed", round(time.perf_counter() - started, 1), flush=True)
    np.savez_compressed(out / "synthetic_complex_echo.npz", frequency_hz=freq,
                        antenna_x_reference_m=apx, frequency_echo=echo.astype(np.complex64))
    hrrp = np.fft.ifft(echo, n=NFFT, axis=1) * NFFT / retained
    hrrp *= np.exp(-1j * 2 * np.pi * (len(freq) - 1) / 2 * np.arange(NFFT) / NFFT)[None, :]
    hrrp = np.ascontiguousarray(hrrp.astype(np.complex64))
    # Native GM-like display layout: image top = farther forward, radar at bottom.
    ix, iy = np.meshgrid(np.arange(2308), np.arange(1334))
    x = (ix - 1154.) * .03
    y = (1330.6 - iy) * .03
    radius = np.hypot(x, y)
    theta = np.rad2deg(np.arctan2(x, y))
    mask = (y >= 0) & (radius > .1) & (radius <= 40) & (abs(theta) <= 60)
    c, s = np.cos(np.pi / 6), np.sin(np.pi / 6)
    q = np.column_stack([x[mask] * c - y[mask] * s, x[mask] * s + y[mask] * c])
    gray_images, stats = [], []
    for n in [200, 1000, 2000]:
        first = (2000 - n) // 2
        z = np.zeros(mask.shape, dtype=np.complex64)
        z[mask] = backproject(q, apx[first:first + n], hrrp[first:first + n], drange, fref)
        gray = to_gray(z, mask)
        Image.fromarray(gray).save(out / f"SAR_gray_{n}chirps.png")
        np.savez_compressed(out / f"SAR_complex_{n}chirps.npz", bp=z, mask=mask)
        gray_images.append(gray)
        power = abs(z[mask]) ** 2
        stats.append(dict(aperture_chirps=n, native_width=2308, native_height=1334,
                          mask_pixels=int(mask.sum()), below_display_floor_fraction=float(np.mean(power < 10 ** (-4.5))),
                          above_display_ceiling_fraction=float(np.mean(power > 10 ** .5)),
                          max_power=float(power.max())))
        print("full BP", n, "elapsed", round(time.perf_counter() - started, 1), flush=True)
    pd.DataFrame(stats).to_csv(out / "display_statistics.csv", index=False)
    fig, axes = plt.subplots(3, 1, figsize=(13, 16), layout="constrained")
    for ax, n, gray in zip(axes, [200, 1000, 2000], gray_images):
        ax.imshow(gray, cmap="gray", vmin=0, vmax=255, interpolation="nearest")
        ax.set_title(f"合成SAR灰度图：{n} chirp/BP，step=200；3 m/s，连续10 kHz", fontsize=12)
        ax.set(xticks=[], yticks=[])
    fig.suptitle("同一静止散射场景的全幅BP像：道路边缘、分布背景和车辆大小的散射点组\n统一灰度映射与扇形显示；原生2308×1334像素", fontsize=14)
    fig.savefig(out / "01_full_SAR_grayscale_comparison.png", dpi=150)
    plt.close(fig)
    # HRRP actually used in BP: range x slow time. It is not the final SAR map.
    raxis = np.arange(NFFT) * drange
    rid = np.flatnonzero((raxis >= 0) & (raxis <= 40))[::4]
    start, stop = 500, 1500
    profiles = abs(hrrp[start:stop, rid]).T ** 2
    hr_db = 10 * np.log10(np.maximum(profiles, 1e-14))
    gm_array = np.asarray(Image.open(GM))
    assert gm_array.shape == (1334, 2308, 3)
    assert np.array_equal(gm_array[:, :, 0], gm_array[:, :, 1])
    gm = gm_array[:, :, 0]
    fig, axes = plt.subplots(1, 3, figsize=(16.5, 5.8), layout="constrained")
    axes[0].imshow(hr_db, origin="lower", aspect="auto", cmap="gray", vmin=-45, vmax=5,
                   extent=[apx[start] / 3 * 1000, apx[stop - 1] / 3 * 1000, raxis[rid[0]], raxis[rid[-1]]])
    axes[0].set(title="距离像堆叠 HRRP（中间结果）", xlabel="慢时间 / ms", ylabel="距离 / m")
    axes[1].imshow(gray_images[1], cmap="gray", vmin=0, vmax=255, interpolation="nearest")
    axes[1].set(title="同一份合成回波的二维BP SAR像", xticks=[], yticks=[])
    axes[2].imshow(gm, cmap="gray", vmin=0, vmax=255, interpolation="nearest")
    axes[2].set(title="原始GM19 F269（独立实景参照）", xticks=[], yticks=[])
    fig.suptitle("左：距离×慢时间；中/右：二维成像平面\n合成与实景是不同场景；实景只用于显示形式参照", fontsize=13)
    fig.savefig(out / "02_HRRP_BP_real_GM_comparison.png", dpi=150)
    plt.close(fig)
    np.savez_compressed(out / "HRRP_display_subset.npz", range_m=raxis[rid],
                        slow_time_s=apx[start:stop] / 3, hrrp=hrrp[start:stop, rid])
    # Position metadata and a clean crop let the viewer locate a stylized object
    # without mistaking scene support for measured physical vehicle boundaries.
    selected = table[table.group == "object2"]
    cx, cy = 3.2, 10.
    px, py = int(round(cx / .03 + 1154)), int(round(1330.6 - cy / .03))
    fig, axes = plt.subplots(1, 3, figsize=(12, 4.7), layout="constrained")
    for ax, n, gray in zip(axes, [200, 1000, 2000], gray_images):
        crop = gray[py - 120:py + 121, px - 100:px + 101]
        ax.imshow(crop, cmap="gray", vmin=0, vmax=255, interpolation="nearest",
                  extent=[cx - 3., cx + 3., cy + 3.6, cy - 3.6])
        ax.set(title=f"{n} chirp/BP", xlabel="显示x / m", ylabel="显示y / m")
    fig.suptitle("同一车辆大小散射点组的SAR局部图（非真实车辆电磁模型）\n保持相同灰度映射，未添加原始GM纹理", fontsize=12)
    fig.savefig(out / "03_object_scatterer_group_crops.png", dpi=160)
    plt.close(fig)
    assert all(sha(p) == h for p, h in hashes.items())
    verification = dict(status="PASS", source_sha256=hashes, source_inputs_unchanged=True,
                        separation_of_pair_m=float(np.linalg.norm(pair[0] - pair[1])),
                        forward_synthesis_max_complex_error=float(max(forward_errors)),
                        synthesized_scatterers=len(points), native_image_shape=[1334, 2308],
                        signal_grid_note="Same baseline waveform, continuous3m/s, fixed reference orientation; display rotation only",
                        real_GM_was_used_only_in_comparison_figure=True,
                        elapsed_s=time.perf_counter() - started, threads=numba.get_num_threads(),
                        interpreter=sys.executable)
    dump(out / "VERIFICATION.json", verification)
    dump(out / "artifact_manifest.json", [dict(file=p.name, bytes=p.stat().st_size, sha256=sha(p))
                                          for p in sorted(out.iterdir()) if p.is_file()])
    print(json.dumps(verification, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
