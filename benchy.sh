#!/bin/sh

NEEDLE="foo"
DIR="~/Desktop/applier"

hyperfine \
  --warmup 3 \
  "./build/default/rbs $DIR $NEEDLE -j 2" \
  "./build/default/rbs $DIR $NEEDLE -j 4" \
  "./build/default/rbs $DIR $NEEDLE -j 8" \
  "./build/default/rbs $DIR $NEEDLE -j 16" \
  "./build/default/rbs $DIR $NEEDLE -j 32" \
  "rg -j 2 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
  "rg -j 4 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
  "rg -j 8 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
  "rg -j 16 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
  "rg -j 32 --no-ignore --hidden --binary --fixed-strings --no-heading --no-line-number $NEEDLE $DIR" \
