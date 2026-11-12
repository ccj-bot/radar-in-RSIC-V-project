#!/bin/sh
set -eu
ROOT=/root/radarbrain_k3_20261108
export PYTHONPATH="$ROOT/runtime/vendor/root/usr/lib/python3.14/dist-packages:$ROOT/runtime/root/usr/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$ROOT/runtime/vendor/root/usr/lib:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/blas:$ROOT/runtime/root/usr/lib/riscv64-linux-gnu/lapack${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SPACEMIT_EP_INTRA_THREAD_NUM=8 SPACEMIT_EP_INTER_THREAD_NUM=1
cd "$ROOT/optimization_v5"
if [ ! -f runtime/root/usr/include/libpng16/png.h ]; then
 mkdir -p runtime/debs runtime/root
 cd runtime/debs
 apt download libpng-dev
 for p in libpng-dev*.deb; do dpkg-deb -x "$p" ../root; done
 cd ../..
fi
g++ -O3 -std=c++17 -march=rv64gcv -mabi=lp64d -fPIC -shared -I"$ROOT/runtime/root/usr/include/opencv4" -I"$ROOT/optimization_v5/runtime/root/usr/include/libpng16" -L"$ROOT/runtime/root/usr/lib/riscv64-linux-gnu" preprocess_file.cpp -o libpreprocess_file.so -lopencv_core -lopencv_imgproc -l:libpng16.so.16
g++ -O3 -std=c++17 -march=rv64gcv -mabi=lp64d -fPIC -shared nms_native.cpp -o libnms_native.so
exec python3 "$ROOT/optimization_v5/validate_native.py"
