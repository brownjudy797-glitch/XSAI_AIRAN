#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Install explicit OS packages or build private, pinned source dependencies.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=${1:-}
work=${2:-}
die() { echo "ERROR: $*" >&2; exit 1; }
case "$mode" in
  apt)
    [[ $(uname -s) == Linux ]] || die 'Ubuntu Linux is required.'
    source /etc/os-release
    [[ $ID == ubuntu ]] || die 'This package list is for Ubuntu; do not run it on another distribution.'
    packages=(build-essential cmake ninja-build git ca-certificates curl pkg-config
      python3 python3-venv autoconf automake libtool bison flex
      libconfig-dev libcjson-dev libyaml-dev libyaml-cpp-dev libfftw3-dev
      libblas-dev liblapacke-dev libssl-dev libsctp-dev libcap-dev libzmq3-dev
      libpcre2-dev libedit-dev zlib1g-dev iproute2 procps util-linux)
    if [[ $(uname -m) == riscv64 ]]; then
      [[ $VERSION_ID == 26.04 ]] || die 'K3 profile currently targets Ubuntu 26.04 with GCC16. Verify another image separately.'
      packages+=(gcc-16 g++-16)
    fi
    sudo apt-get update
    sudo apt-get install -y "${packages[@]}"
    ;;
  tools)
    [[ -n $work && -f $work/.xsai-repro.json ]] || die 'Run reproduce.py prepare WORKSPACE first.'
    work=$(realpath "$work")
    prefix="$work/deps"
    mkdir -p "$prefix/src" "$prefix/include"
    readarray -t lock < <(python3 - "$repo/config/repro/20261029.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
for k in ['asn1cRepository','asn1cCommit','simdeRepository','simdeCommit','simdePatch','simdePatchSha256']:
    print(p[k])
PY
)
    checkout() {
      local url=$1 commit=$2 target=$3
      if [[ ! -e $target ]]; then
        git -c http.version=HTTP/1.1 clone --filter=blob:none --no-checkout "$url" "$target"
        git -C "$target" checkout --detach "$commit"
      else
        [[ -d $target/.git ]] || die "Dependency directory is not a checkout: $target"
        [[ $(git -C "$target" rev-parse HEAD) == "$commit" ]] || die "Unexpected dependency commit: $target; preserve it for inspection."
      fi
    }
    checkout "${lock[2]}" "${lock[3]}" "$prefix/src/simde"
    printf '%s  %s\n' "${lock[5]}" "$repo/${lock[4]}" | sha256sum --check -
    if ! git -C "$prefix/src/simde" apply --reverse --check "$repo/${lock[4]}" 2>/dev/null; then
      git -C "$prefix/src/simde" apply --check "$repo/${lock[4]}"
      git -C "$prefix/src/simde" apply "$repo/${lock[4]}"
    fi
    diff_sha=$(git -C "$prefix/src/simde" diff --no-ext-diff --binary | sha256sum | awk '{print $1}')
    [[ $diff_sha == "${lock[5]}" ]] || die 'SIMDe has changes beyond the published patch; preserve and inspect it.'
    if [[ ! -e $prefix/include/simde && ! -L $prefix/include/simde ]]; then
      ln -s ../src/simde "$prefix/include/simde"
    fi
    [[ $(realpath "$prefix/include/simde") == "$prefix/src/simde" ]] || die 'Unexpected SIMDe include path.'
    checkout "${lock[0]}" "${lock[1]}" "$prefix/src/asn1c"
    git -C "$prefix/src/asn1c" diff --quiet HEAD -- || die 'ASN1C source has local changes; preserve and inspect it.'
    if [[ ! -x $prefix/asn1c/bin/asn1c ]]; then
      (
        cd "$prefix/src/asn1c"
        autoreconf -iv
        CFLAGS='-O0 -g3' CXXFLAGS='-O0 -g3' ./configure --prefix="$prefix/asn1c"
        make -j "${JOBS:-4}"
        make install
      )
    fi
    "$prefix/asn1c/bin/asn1c" -h 2>&1 | head -n 2 || true
    echo "Private dependencies ready: $prefix"
    ;;
  *) echo "Usage: bash $0 apt | tools ABSOLUTE_WORKSPACE" >&2; exit 2 ;;
esac
