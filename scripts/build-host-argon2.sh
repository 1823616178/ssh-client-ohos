#!/usr/bin/env bash
# 宿主机 libargon2（S2 单测依赖）。不需要 root：装到 ~/ohos-probe/build/host-deps/argon2
set -euo pipefail
PREFIX="${HOME}/ohos-probe/build/host-deps/argon2"
if [ -f "${PREFIX}/lib/libargon2.a" ] && [ -f "${PREFIX}/include/argon2.h" ]; then
  echo "[host-argon2] 已存在 ${PREFIX}"
  exit 0
fi
mkdir -p /tmp/argon2-src "${PREFIX}/lib" "${PREFIX}/include"
cd /tmp/argon2-src
if [ ! -f argon2-20190702.tar.gz ]; then
  curl -fsSL -o argon2-20190702.tar.gz \
    https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/20190702.tar.gz
fi
rm -rf phc-winner-argon2-20190702
tar xf argon2-20190702.tar.gz
cd phc-winner-argon2-20190702
make libargon2.a OPTTARGET=generic -j"$(nproc 2>/dev/null || echo 4)"
cp libargon2.a "${PREFIX}/lib/"
cp include/argon2.h "${PREFIX}/include/"
echo "[host-argon2] 已安装 ${PREFIX}"
