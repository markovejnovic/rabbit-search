# 🐇 Rabbit Search

> ![WARNING]
> 🚧 This program is a work-in-progress. It is not ready for production use and may contain bugs.

![Dumb Drawing by ChatGPT](./res/banner.webp)

*Rabbit Search* strives to be the fastest string search program on the planet. **It currently is
not that.**

## Future Optimizations

- On Linux, we can call `close` via iouring to avoid waiting for the syscall to complete. We don't
  care about the result of close, so we can just fire and forget.
