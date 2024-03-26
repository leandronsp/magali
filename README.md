# Magali

A minimalist yet multi-threaded HTTP server coded in pure Assembly x86_64, designed to output a "Hello world" message in HTML format.

The server employs a pool of threads consuming connections from a queue that is synchronized using mutex in spinlock and futex for condition variable.

## Requirements

* Linux/AMD64 (tested in Ubuntu)
* NASM 2.15.05
* GNU ld 2.38

```bash
$ nasm -f elf64 -o server.o server.asm
$ ld -o server server.o
$ ./server

Listening on the port 3000
```

---
A product of [Monica](https://gist.github.com/leandronsp/8b11d339613e5d7f37fa4e083d07efc3)
