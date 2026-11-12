"""Generate actual 2D synthetic point-scatterer BP images from complex echoes.

Continuous 10kHz, fixed 3m/s/reference x-motion, 200/1000/2000-chirp apertures.
Equivalent frequency samples represent stop-go FMCW data after phase/RVP
calibration. IFFT range compression + complex interpolation + spherical BP.
This does not use GM imagery, optical inputs, GT or generative imagery.
"""
from pathlib import Path
import argparse
import json
import math
import os
import time
import sys

import numpy as np
import pandas as pd
import numba
from numba import njit, prange
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from audit_nx_imaging_parameters_20261105 import dump, sha
from evaluate_bp_five_frame_3mps_20261105 import metrics

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "docs/sar_research/BP_PARAMETER_BASELINE_20261105.json"
SCENARIOS = ROOT / "docs/sar_research/BP_CONTINUOUS_50HZ_SCENARIOS_20261105.json"
C = 3e8
NFFT = 8192


@njit(parallel=True, cache=True)
def backproject(q, apx, hrrp, drange, fref):
    output = np.zeros(len(q), dtype=np.complex128)
    scale = 4 * np.pi * fref / C
    for i in prange(len(q)):
        xx, yy = q[i, 0], q[i, 1]
        value = 0j
        for m in range(len(apx)):
            distance = math.sqrt((xx - apx[m]) ** 2 + yy ** 2)
            index = distance / drange
            k = int(math.floor(index))
            if k < 0 or k + 1 >= hrrp.shape[1]:
                continue
            fraction = index - k
            val = hrrp[m, k] * (1 - fraction) + hrrp[m, k + 1] * fraction
            phase = scale * distance
            value += val * complex(math.cos(phase), math.sin(phase))
        output[i] = value / len(apx)
    return output


def geometry(n):
    return 3 * (np.arange(n) - (n - 1) / 2) / 10000.


def make_hrrp(points, coeff, n, frequency, retained):
    apx = geometry(n)
    echo = np.zeros((n, len(frequency)), dtype=np.complex128)
    for p, a in zip(points, coeff):
        rr = np.sqrt((p[0] - apx) ** 2 + p[1] ** 2)
        echo += a * np.exp(-1j * 4 * np.pi / C * rr[:, None] * frequency[None, :])
    echo[:, :100] = 0
    center = (len(frequency) - 1) / 2
    # Positive range transform on the original n-index frequency grid, followed
    # by an explicit origin correction to leave phase exp(-j4pi*fref*R/c).
    transformed = np.fft.ifft(echo, n=NFFT, axis=1) * (NFFT / retained)
    transformed *= np.exp(-1j * 2 * np.pi * center * np.arange(NFFT) / NFFT)[None, :]
    return apx, np.ascontiguousarray(transformed.astype(np.complex64)), echo.astype(np.complex64)


def direct_kernel(q, p, apx, frequency):
    rp = np.sqrt((p[0] - apx) ** 2 + p[1] ** 2)
    rq = np.sqrt((q[:, None, 0] - apx) ** 2 + q[:, None, 1] ** 2)
    dr = rq - rp
    f = frequency[100:]
    df, count = f[1] - f[0], len(f)
    z = 2 * df * dr / C
    return (np.sinc(count * z) / np.sinc(z) * np.exp(1j * 4 * np.pi * f.mean() / C * dr)).mean(axis=1)


def db(z):
    return 10 * np.log10(np.maximum(abs(z) ** 2, 1e-10))


def plot_grid(fig, axes, arrays, x, y, titles, cbar_label, marks=None):
    image = None
    for index, (ax, arr, title) in enumerate(zip(np.asarray(axes).ravel(), arrays, titles)):
        image = ax.imshow(db(arr), origin="lower", cmap="magma", vmin=-35, vmax=0,
                          extent=[x[0], x[-1], y[0], y[-1]], interpolation="nearest", aspect="equal")
        ax.set(title=title, xlabel="x (m)", ylabel="y (m)")
        if marks is not None:
            ax.plot(marks[:, 0], marks[:, 1], "+", color="cyan", ms=4, mew=.8)
    fig.colorbar(image, ax=np.asarray(axes).ravel().tolist(), label=cbar_label, shrink=.85)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    if not out.is_relative_to(ROOT / "outputs"):
        raise ValueError("Wrong output root")
    out.mkdir(parents=True, exist_ok=False)
    numba.set_num_threads(min(8, os.cpu_count() or 1))
    b = json.loads(BASELINE.read_text(encoding="utf-8"))
    scenarios = json.loads(SCENARIOS.read_text(encoding="utf-8"))
    assert b["simulation_trajectory"]["speed_mps"] == 3
    assert b["simulation_trajectory"]["motion_axis"] == "x"
    assert scenarios["prf_hz"] == 10000 and scenarios["step_chirps"] == 200
    w = b["waveform"]
    frequency = w["start_frequency_hz"] + w["slope_hz_per_s"] * (
        w["adc_start_s"] + np.arange(w["adc_samples"]) / w["adc_sample_rate_hz"])
    fref = float((frequency[0] + frequency[-1]) / 2)
    df = float(w["slope_hz_per_s"] / w["adc_sample_rate_hz"])
    drange = C / (2 * NFFT * df)
    retained = w["adc_samples"] - 100
    source_paths = [BASELINE, SCENARIOS, Path(__file__),
                    Path(__file__).with_name("evaluate_bp_five_frame_3mps_20261105.py"),
                    Path(__file__).with_name("audit_nx_imaging_parameters_20261105.py")]
    hashes = {str(p): sha(p) for p in source_paths}
    protocol = dict(prf_hz=10000, speed_mps=3., motion_axis="x", step_chirps=200,
                    apertures=[200, 1000, 2000], nominal_output_hz=50,
                    frequency_hz=dict(first=float(frequency[0]), last=float(frequency[-1]),
                                      phase_reference=fref, slope_hz_per_s=w["slope_hz_per_s"]),
                    range_transform=dict(method="IFFT with explicit fast-time phase origin correction",
                                         fft_length=NFFT, grid_spacing_m=drange,
                                         removed_ADC_samples=100, retained_ADC_samples=retained),
                    bp="Exact spherical distance; complex linear HRRP interpolation; coherent sum before intensity",
                    display="10log10(|z|^2), common reference isolated unit point = 0dB; all panels [-35,0]dB",
                    forward_model="Constant point scattering, stop-go single channel, phase/RVP-calibrated FMCW-equivalent frequency samples",
                    phase_update="RF frequency samples and BP use the same derived reference, about77.899GHz; older simplified plots used76GHz",
                    scene_grid_spacing_m=.03, local_grid_spacing_m=.002,
                    limitations=["No physical vehicle scattering model, multipath, noise or motion error",
                                 "Synthetic frequency data are calibrated equivalents, not hardware raw ADC captures",
                                 "50Hz is the window cadence, not claimed measured computation throughput"])
    dump(out / "protocol.json", protocol)
    # Nine equal point scatterers, exactly on the global 3cm display grid.
    points = np.array([[-2.4, 2.4], [0., 3.], [1.2, 3.6],
                       [-5.4, 7.2], [0., 9.], [3., 9.],
                       [-9., 12.], [0., 15.], [4.5, 13.5]])
    truth = pd.DataFrame(dict(id=np.arange(1, len(points) + 1), x_m=points[:, 0], y_m=points[:, 1],
                              amplitude=1., phase_rad=0., range_m=np.linalg.norm(points, axis=1),
                              bearing_deg=np.rad2deg(np.arctan2(points[:, 0], points[:, 1]))))
    truth.to_csv(out / "synthetic_scene_points.csv", index=False)
    gx = np.arange(-350, 184) * .03
    gy = np.arange(551) * .03
    xx, yy = np.meshgrid(gx, gy)
    radius = np.hypot(xx, yy)
    bearing = np.rad2deg(np.arctan2(xx, yy))
    mask = (radius > 0) & (radius <= 16.5) & (bearing >= -90) & (bearing <= 30)
    q = np.column_stack([xx[mask], yy[mask]])
    raw_images, scene_metrics, validation = [], [], []
    start = time.perf_counter()
    for n in [200, 1000, 2000]:
        apx, hrrp, echo = make_hrrp(points, np.ones(len(points)), n, frequency, retained)
        values = backproject(q, apx, hrrp, drange, fref)
        image = np.zeros(xx.shape, dtype=np.complex128)
        image[mask] = values
        raw_images.append(image)
        np.savez_compressed(out / f"scene_BP_{n}chirps.npz", x_m=gx, y_m=gy, bp=image.astype(np.complex64), mask=mask)
        if n == 2000:
            np.savez_compressed(out / "synthetic_frequency_echo_2000chirps.npz", frequency_hz=frequency,
                                antenna_x_m=apx, echo=echo, note="Calibrated complex frequency samples, not raw ADC")
        # Compare an independent analytic sum to this FFT/interpolation chain.
        probes = np.r_[points, points + [.017, .009]]
        measured = backproject(probes, apx, hrrp, drange, fref)
        exact = sum(direct_kernel(probes, p, apx, frequency) for p in points)
        err = float(np.max(abs(measured - exact)))
        validation.append(dict(aperture_chirps=n, comparison="scene FFT/interpolated BP versus direct discrete-frequency BP",
                               max_complex_error=err, probe_count=len(probes)))
        assert err < .025
        for i, (p, z) in enumerate(zip(points, measured[:len(points)])):
            scene_metrics.append(dict(aperture_chirps=n, point_id=i + 1,
                                      true_x=p[0], true_y=p[1], power_at_true_point=float(abs(z) ** 2)))
        print("global scene", n, "complex error", err, "elapsed", round(time.perf_counter() - start, 1), flush=True)
        del hrrp, echo
    fig, axes = plt.subplots(1, 3, figsize=(13.5, 6.3), layout="constrained")
    plot_grid(fig, axes, raw_images, gx, gy, [f"{n} chirps/BP; step=200" for n in [200, 1000, 2000]],
              "Power relative to isolated unit point (dB)", points)
    fig.suptitle("SIMULATED BP: same nine stationary point scatterers; continuous10kHz, 3m/s\n"
                 "Cyan crosses = input positions; identical 3cm output grid, common intensity scale; all update every20ms")
    fig.savefig(out / "01_full_scene_BP_comparison.png", dpi=170)
    plt.close(fig)
    pd.DataFrame(scene_metrics).to_csv(out / "scene_point_response.csv", index=False)

    offset = np.linspace(-.3, .3, 301)
    lx, ly = np.meshgrid(offset, offset)
    local, local_metrics = {}, []
    for r in [3., 10., 15.]:
        p = np.array([0., r])
        qlocal = p + np.column_stack([lx.ravel(), ly.ravel()])
        for n in [200, 1000, 2000]:
            apx, hrrp, _ = make_hrrp([p], [1.], n, frequency, retained)
            z = backproject(qlocal, apx, hrrp, drange, fref).reshape(lx.shape)
            local[(r, n)] = z
            np.savez_compressed(out / f"single_R{r:g}_BP{n}.npz", offset_x_m=offset, offset_y_m=offset, bp=z.astype(np.complex64))
            # 2mm sampling is disclosed; these widths are image-cut measurements.
            for direction, line in [("tangent", z[len(offset) // 2]), ("radial", z[:, len(offset) // 2])]:
                local_metrics.append(dict(range_m=r, aperture_chirps=n, direction=direction,
                                           image_sampling_m=.002, **metrics(offset, abs(line) ** 2)))
            print("local point", r, n, "elapsed", round(time.perf_counter() - start, 1), flush=True)
            del hrrp
    fig, axes = plt.subplots(3, 3, figsize=(11.4, 10.6), layout="constrained")
    arrs = [local[(r, n)] for r in [3., 10., 15.] for n in [200, 1000, 2000]]
    titles = [f"R={r:g}m; {n} chirps" for r in [3., 10., 15.] for n in [200, 1000, 2000]]
    plot_grid(fig, axes, arrs, offset, offset, titles, "Power relative to isolated unit point (dB)", np.array([[0., 0.]]))
    for ax in axes.ravel():
        ax.set(xlabel="Tangent offset (m)", ylabel="Radial offset (m)")
    fig.suptitle("SIMULATED single-point BP: identical 0.6m x 0.6m local views, 2mm sampling\n"
                 "Continuous10kHz, fixed3m/s and orientation; same [-35,0]dB display in every panel")
    fig.savefig(out / "02_single_point_space_and_aperture.png", dpi=170)
    plt.close(fig)
    pd.DataFrame(local_metrics).to_csv(out / "single_point_image_cut_metrics.csv", index=False)

    pair = np.array([[-.05, 10.], [.05, 10.]])
    qpair = np.array([0., 10.]) + np.column_stack([lx.ravel(), ly.ravel()])
    pair_images = {}
    for phase_name, coefficients in [("same_phase", [1., 1.]), ("opposite_phase", [1., -1.])]:
        for n in [200, 1000, 2000]:
            apx, hrrp, _ = make_hrrp(pair, coefficients, n, frequency, retained)
            z = backproject(qpair, apx, hrrp, drange, fref).reshape(lx.shape)
            pair_images[(phase_name, n)] = z
            np.savez_compressed(out / f"pair10cm_{phase_name}_BP{n}.npz", offset_x_m=offset, offset_y_m=offset, bp=z.astype(np.complex64))
            print("pair", phase_name, n, "elapsed", round(time.perf_counter() - start, 1), flush=True)
            del hrrp
    fig, axes = plt.subplots(2, 3, figsize=(11.4, 7.3), layout="constrained")
    arrs = [pair_images[(ph, n)] for ph in ["same_phase", "opposite_phase"] for n in [200, 1000, 2000]]
    titles = [f"{ph.replace('_', ' ')}; {n} chirps" for ph in ["same_phase", "opposite_phase"] for n in [200, 1000, 2000]]
    # Pair peaks may exceed unit point; use a fixed pair-reference of 4 (=+6dB),
    # not an independent normalization of each panel.
    plot_grid(fig, axes, [z / 2 for z in arrs], offset, offset, titles,
              "Power / 4 (dB); fixed equal-pair maximum reference", np.array([[-.05, 0.], [.05, 0.]]))
    for ax in axes.ravel():
        ax.set(xlabel="Tangent offset (m)", ylabel="Radial offset (m)")
    fig.suptitle("SIMULATED BP of identical10cm double points at R10m\n"
                 "Cyan crosses = true points; relative scattering phase is an explicit control, not a resolution claim")
    fig.savefig(out / "03_double_point_BP_phase_control.png", dpi=170)
    plt.close(fig)
    pd.DataFrame(validation).to_csv(out / "FFT_BP_vs_direct_kernel.csv", index=False)
    assert all(sha(p) == h for p, h in hashes.items())
    verification = dict(status="PASS", max_complex_error_against_direct_kernel=max(row["max_complex_error"] for row in validation),
                        source_hashes=hashes, source_files_unchanged=True,
                        numba_cpu_threads=numba.get_num_threads(), elapsed_wall_s=time.perf_counter() - start,
                        global_images=3, single_point_local_images=9, double_point_local_images=6,
                        grid_sampling_note="3cm context grid; 2mm local grid, no claim that finer pixels add information",
                        interpreter=sys.executable)
    dump(out / "VERIFICATION.json", verification)
    dump(out / "artifact_manifest.json", [dict(file=p.name, bytes=p.stat().st_size, sha256=sha(p))
                                          for p in sorted(out.iterdir()) if p.is_file()])
    print(json.dumps(verification, ensure_ascii=False, indent=2), flush=True)


if __name__ == "__main__":
    main()
