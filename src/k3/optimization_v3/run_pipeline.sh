#!/bin/sh
set -eu
ROOT=/root/radarbrain_k3_20261108
export PYTHONPATH="$ROOT/runtime/vendor/root/usr/lib/python3.14/dist-packages:$ROOT/runtime/root/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$ROOT/runtime/vendor/root/usr/lib:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/blas:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/lapack${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SPACEMIT_EP_INTRA_THREAD_NUM=8
export SPACEMIT_EP_INTER_THREAD_NUM=1
exec python3 "$ROOT/optimization_v3/app/pipeline_bench.py" "$@"
