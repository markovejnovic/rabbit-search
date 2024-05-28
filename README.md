# 🐇 Rabbit Search

![Dumb Drawing by ChatGPT](./res/banner.webp)

*Rabbit Search* strives to be the fastest string search program on the planet.
It is, currently, to me, faster than `ag` and `ripgrep`.

> 🚧 *Rabbit Search* is under heavy development. Features may pop up, get
> deleted and performance may be improved. The correctness of this program is
> **not** guaranteed.

## Benchmarks

> `TODO(markovejnovic)`

At the moment, I've ran some manual benchmarks on
[Marlin](https://github.com/MarlinFirmware/Marlin.git). Currently, `rbbs` is
about 10% faster than
[the\_silver\_searcher](https://github.com/ggreer/the_silver_searcher) (which
is what I use normally).

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
