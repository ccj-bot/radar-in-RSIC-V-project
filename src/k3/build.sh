#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIB="$ROOT/runtime/root/usr/lib/riscv64-linux-gnu"
g++ -O2 -std=c++17 -march=rv64gcv -mabi=lp64d -fopenmp -ffp-contract=off -fno-tree-vectorize -shared -fPIC "$ROOT/app/bp_k3.cpp" -o "$ROOT/app/libbp_k3.so"
g++ -O2 -std=c++17 -shared -fPIC "$ROOT/app/resize_cv.cpp" -I"$ROOT/runtime/root/usr/include/opencv4" -L"$LIB" -lopencv_imgproc -lopencv_core -o "$ROOT/app/libresize_cv.so"
