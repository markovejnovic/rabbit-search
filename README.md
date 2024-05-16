# 🐇 Rabbit Search

*Rabbit Search* strives to be the fastest string search program on the planet.
It is, currently, to me, faster than `ag` and `ripgrep`.

> 🚧 *Rabbit Search* is under heavy development. Features may pop up, get
> deleted and performance may be improved.

## Benchmarks

> `TODO(markovejnovic)`

## How does it work

- I use `C11` `_Atomic` queues instead of `mutices`.
- I use `SIMD` `memmem` (courtesy of `stringzilla`) instead of regular `libc`
  `memmem`.

## Goals

The goals of `rabbit-search` are to:

* Be the fastest program to find a `needle` string in a tree of files.
* Be a minimal, trivial program, understandable by everyone with a `C`
  background.

### Not Goals

* Regex search - *You can always use `ag` and/or `rg` to perform these
  searches. Those projects are extremely mature, well developed and
  understandable.*
