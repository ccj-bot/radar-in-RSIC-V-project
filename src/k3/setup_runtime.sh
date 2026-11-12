#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$ROOT/runtime/debs" "$ROOT/runtime/root" "$ROOT/runtime/vendor/debs" "$ROOT/runtime/vendor/root" "$ROOT/logs"
cd "$ROOT/runtime/debs"
apt-get download python3-onnxruntime python3-numpy libblas3 liblapack3 libgfortran5 python3-coloredlogs python3-humanfriendly python3-flatbuffers python3-protobuf python3-sympy python3-mpmath libopencv-core410 libopencv-imgproc410 libopencv-core-dev libopencv-imgproc-dev libtbb12 libtbbmalloc2 libtbbbind-2-5 python3-pil libfftw3-single3
for f in ./*.deb; do dpkg-deb -x "$f" ../root; done
cd "$ROOT/runtime/vendor/debs"
apt-get download python3-spacemit-ort spacemit-runtime spacemit-onnxruntime
for f in ./*.deb; do dpkg-deb -x "$f" ../root; done
cd "$ROOT"
./build.sh
printf '\nRuntime extracted into project only. Run optimization_v5/run_int8.sh next.\n'
