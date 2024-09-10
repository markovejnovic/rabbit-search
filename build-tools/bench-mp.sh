#!/bin/sh

MAX_THREADS="7"
WARMUP_ITERS=10

if [ -z "$4" ]; then
    echo "Usage: $0 <RABBIT-SEARCH-BINARY> <NEEDLE> <DIR> <OUTPUT-DIR>"
    exit 63
fi

rs_binary="$1"
needle="$2"
search_dir="$3"
output_dir="$4"

run_benchmark() {
    # Execute benchmarks, returning the path to the benchmark JSON.

    benchmark_json="$output_dir/mp-results.json"

    hyperfine \
        -N \
        --export-json "$benchmark_json" \
        --warmup "$WARMUP_ITERS" \
        -P threads 0 "$MAX_THREADS" \
        "$rs_binary -j{threads} $needle $search_dir" 1>&2

    echo "$benchmark_json"
}

plot_results() {
    # Plot the results given a benchmarks JSON
    benchmark_json="$1"
    benchmark_dat="$(mktemp)"

    #                   X Axis is -jX               Y Axis is the time  xerr=0  yerr=stddev
    jq -r '.results[] | .parameters.threads + " " + (.mean|tostring) + " 0 " + (.stddev|tostring)' \
        < "$benchmark_json" \
        > "$benchmark_dat"

    plot_png="$output_dir/mp-benchmark.png"
    gnuplot <<EOF
reset session
unset key
set terminal png size 800,600
set output '$plot_png'
set grid
set xlabel "Thread Count []"
set ylabel "Execution Time [s]"
set autoscale
plot '$benchmark_dat' with lines
EOF
    echo "$plot_png"
}

benchmark_json="$(run_benchmark)"
plot_png="$(plot_results "$benchmark_json")"

# Echo the artifacts for other programs to collect
echo "$benchmark_json"
echo "$plot_png"
