#!/bin/sh

if [ -z "$3" ]; then
    echo "Usage: $0 <RABBIT-SEARCH-BINARY> <NEEDLE> <DIR>"
    exit 63
fi

rs_binary="$1"
needle="$2"
search_dir="$3"
threads="8"

$rs_binary -j$threads "$needle" "$search_dir" | wc -l
