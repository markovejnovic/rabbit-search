#!/bin/sh

set -e
set -x

NEEDLE="foo"
DIR="$HOME/Desktop/applier"

RBS_MIMALLOC_PATH="./build/benchmark/rbs-mimalloc"
RBS_GLIBCMALLOC_PATH="./build/benchmark/rbs-glibcmalloc"

cmake --preset benchmark -DRBS_USE_MIMALLOC=ON \
  && ninja -C build/benchmark --verbose \
  && mv build/benchmark/rbs "$RBS_MIMALLOC_PATH"

cmake --preset benchmark -DRBS_USE_MIMALLOC=OFF \
  && ninja -C build/benchmark --verbose \
  && mv build/benchmark/rbs "$RBS_GLIBCMALLOC_PATH"

rm -rf testy-results
mkdir -p testy-results

"$RBS_MIMALLOC_PATH" "$DIR" "$NEEDLE" -j 1 | sort > testy-results/rbs-mimalloc-1.txt
"$RBS_MIMALLOC_PATH" "$DIR" "$NEEDLE" -j 2 | sort > testy-results/rbs-mimalloc-2.txt
"$RBS_MIMALLOC_PATH" "$DIR" "$NEEDLE" -j 4 | sort > testy-results/rbs-mimalloc-4.txt
"$RBS_GLIBCMALLOC_PATH" "$DIR" "$NEEDLE" -j 1 | sort > testy-results/rbs-glibc-1.txt
"$RBS_GLIBCMALLOC_PATH" "$DIR" "$NEEDLE" -j 2 | sort > testy-results/rbs-glibc-2.txt
"$RBS_GLIBCMALLOC_PATH" "$DIR" "$NEEDLE" -j 4 | sort > testy-results/rbs-glibc-4.txt

set +e

diff testy-results/rbs-mimalloc-1.txt testy-results/rbs-glibc-1.txt
diff testy-results/rbs-mimalloc-2.txt testy-results/rbs-glibc-2.txt
diff testy-results/rbs-mimalloc-4.txt testy-results/rbs-glibc-4.txt
diff testy-results/rbs-mimalloc-1.txt testy-results/rbs-mimalloc-2.txt
diff testy-results/rbs-mimalloc-1.txt testy-results/rbs-mimalloc-4.txt

set -e
