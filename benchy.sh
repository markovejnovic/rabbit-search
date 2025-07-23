#!/bin/sh

set -e

NEEDLE="foo"
DIR="~/Desktop/applier"

RBS_MIMALLOC_PATH="./build/benchmark/rbs-mimalloc"
RBS_GLIBCMALLOC_PATH="./build/benchmark/rbs-glibcmalloc"

cmake --preset benchmark -DRBS_USE_MIMALLOC=ON \
  && ninja -C build/benchmark --verbose \
  && mv build/benchmark/rbs "$RBS_MIMALLOC_PATH"

cmake --preset benchmark -DRBS_USE_MIMALLOC=OFF \
  && ninja -C build/benchmark --verbose \
  && mv build/benchmark/rbs "$RBS_GLIBCMALLOC_PATH"

hyperfine \
  --warmup 8 \
  --runs 32 \
  "$RBS_MIMALLOC_PATH $DIR $NEEDLE -j 1" \
  "$RBS_MIMALLOC_PATH $DIR $NEEDLE -j 2" \
  "$RBS_MIMALLOC_PATH $DIR $NEEDLE -j 4" \
  "$RBS_MIMALLOC_PATH $DIR $NEEDLE -j 8" \
  "$RBS_GLIBCMALLOC_PATH $DIR $NEEDLE -j 1" \
  "$RBS_GLIBCMALLOC_PATH $DIR $NEEDLE -j 2" \
  "$RBS_GLIBCMALLOC_PATH $DIR $NEEDLE -j 4" \
  "$RBS_GLIBCMALLOC_PATH $DIR $NEEDLE -j 8" \
  "rg -j 1 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
  "rg -j 2 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
  "rg -j 4 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
  "rg -j 8 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
