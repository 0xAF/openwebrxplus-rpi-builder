#!/usr/bin/env bash
set -euo pipefail

# cmakebuild <folder> [git_tag|git_commit] [-DCMAKE_FLAG=YES ...]
source /tmp/cmake_helper.sh

pushd /tmp

git clone https://github.com/mobilinkd/m17-cxx-demod.git
cmakebuild m17-cxx-demod
ldconfig

rm -rf m17-cxx-demod

popd
