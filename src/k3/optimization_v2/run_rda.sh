#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PYTHONPATH="$ROOT/runtime/root/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$ROOT/runtime/root/usr/lib/riscv64-linux-gnu:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/blas:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/lapack${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export RDA_FFT_BACKEND=fftw
export RDA_FFT_THREADS=4
exec python3 "$ROOT/optimization_v2/app/compare_rda_bp.py" --scenario original --range-fft 512 --output "$ROOT/optimization_v2/results/rda_demo" --lib "$ROOT/app/libbp_k3.so" "$@"
