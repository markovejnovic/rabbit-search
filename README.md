# 🚧 This repository is under heavy optimization

# 🐇 Rabbit Search

![Dumb Drawing by ChatGPT](./res/banner.webp)

*Rabbit Search* strives to be the fastest string search program on the planet. **It currently is
not that.**

> 🚧 *Rabbit Search* is under heavy development. Features may pop up, get
> deleted and performance may be improved. The correctness of this program is
> **not** guaranteed.

## Future Optimizations

- On Linux, we can call `close` via iouring to avoid waiting for the syscall to complete. We don't
  care about the result of close, so we can just fire and forget.
