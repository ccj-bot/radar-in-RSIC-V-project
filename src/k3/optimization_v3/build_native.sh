#!/bin/sh
set -eu
ROOT=/root/radarbrain_k3_20261108
g++ -O3 -std=c++17 -march=rv64gcv -mabi=lp64d -shared -fPIC "$ROOT/optimization_v3/app/preprocess_native.cpp" -I"$ROOT/runtime/root/usr/include/opencv4" -L"$ROOT/runtime/root/usr/lib/riscv64-linux-gnu" -lopencv_imgproc -lopencv_core -o "$ROOT/optimization_v3/app/libpreprocess_native.so"
