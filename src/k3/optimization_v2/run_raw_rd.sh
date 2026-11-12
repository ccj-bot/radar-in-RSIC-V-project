#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PYTHONPATH="$ROOT/runtime/root/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$ROOT/runtime/root/usr/lib/riscv64-linux-gnu:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/blas:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/lapack${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export RDA_FFT_BACKEND=fftw
exec python3 "$ROOT/optimization_v2/app/raw_rd_replay.py" --input "$ROOT/optimization_v2/raw_input" --output "$ROOT/optimization_v2/results/raw_rd_demo" "$@"
