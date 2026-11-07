# Zig 0.17.1

A ten-lecture course in Zig. The material follows the [Zig Book](https://pedropark99.github.io/zig-book/), the [language reference](https://ziglang.org/documentation/0.17.1/) and the standard library's own source, for Zig **0.17.1**.

## The lectures

| # | Title | The project | Main topics |
|---|-------|-------------|-------------|
| 1 | Fundamentals | A vending-machine state machine | values, control flow, functions, structs, enums, tagged unions, tests, `main` and `std.process.Init` |
| 2 | Memory, pointers and allocators | A bump allocator that implements `std.mem.Allocator` | `defer`/`errdefer`, pointers and slices, optionals, struct layout, allocators, leak detection |
| 3 | Contiguous data | Conway's Game of Life on a torus | arrays, slices, strings, `ArrayList`, vectors, `@embedFile`, multiline literals |
| 4 | Errors, optionals and unions | A calculator: tokenizer, parser, evaluator | error sets and unions, `try`/`catch`, error return traces, optionals, tagged unions, labeled `switch` |
| 5 | `comptime`, generics and reflection | Generic containers, a matrix type, a base64 codec | comptime evaluation, generic types, `@typeInfo`, `inline for`, compile-time tables |
| 6 | The standard library: containers, files and JSON | `codestat`, a source-tree statistics tool | hash maps, priority queues, directory walking, `Io.Reader`/`Io.Writer`, JSON, logging |
| 7 | Testing, the build system and packages | A statistics CLI depending on a `mathlib` package | `build.zig`/`build.zig.zon`, options, generated code, end-to-end tests, fuzzing, cross-compilation, docs |
| 8 | Threads, tasks and a networked service | A notes CRUD HTTP API serving concurrent connections | `std.Thread`, atomics, `Io.Mutex`/`RwLock`, `Io.Group`, `Io.Queue`, sockets, HTTP by hand |
| 9 | C and C++ interop | An image tool: stb_image (C), a C++ color counter, Zig filters exported to C | `translate-c`, `[*c]` pointers, callbacks, `extern "C"`, `export fn`, static libraries, `zig cc` |
| 10 | A window and a GPU | A spinning triangle: SDL3 window, Vulkan renderer, headless mode | the package manager, system libraries, shaders compiled at build time, Vulkan 1.3 |

Each lecture lives in `lecture_N/` (a self-contained Zig package: `build.zig`, `build.zig.zon`, `src/`) and its write-up in `lecture-md/lecture_N/lecture_N.md`. Read the write-up alongside the source: the write-up shows every file, in parts, with the reasoning.

## Requirements

**Zig 0.17.1.** Download the archive for your platform from <https://ziglang.org/download/>, extract it somewhere permanent, and put that directory on your `PATH`. For example, on Linux x86_64:

```bash
curl -LO https://ziglang.org/download/0.17.1/zig-x86_64-linux-0.17.1.tar.xz
```
```bash
tar -xf zig-x86_64-linux-0.17.1.tar.xz && mv zig-x86_64-linux-0.17.1 ~/.local/zig
```
```bash
echo 'export PATH="$HOME/.local/zig:$PATH"' >> ~/.bashrc && source ~/.bashrc
```
```bash
zig version
```
should print `0.17.1`. Every `build.zig.zon` declares `minimum_zig_version = "0.17.1"`; older versions, including 0.16, will not build these lectures (the I/O and concurrency APIs changed).

Lectures 1 to 9 need nothing else. Lecture 9 includes its C library in the repository; the Zig compiler builds the C and C++ itself.

**Lecture 10** additionally needs:
- the Vulkan headers and loader: `sudo apt install libvulkan-dev` (Debian/Ubuntu) or the [Vulkan SDK](https://vulkan.lunarg.com/);
- `glslc`, the GLSL-to-SPIR-V compiler: `sudo apt install glslc`, or the SDK;
- a GPU driver with Vulkan 1.3 (Mesa's software renderer, lavapipe, is enough to run the tests);
- network access for the first build, which fetches SDL3 through the Zig package manager and compiles it from source (about ten seconds). The fetched package is unpacked into `lecture_10/zig-pkg/`, which is ignored by git;
- optionally the validation layer (`sudo apt install vulkan-validationlayers`) for `--validate`.

## Building and running

Every lecture builds the same way, from its own directory:
```bash
cd lecture_1 && zig build run
```
```bash
zig build test --summary all
```
`zig build` alone installs the program into `zig-out/bin/`. Arguments after `--` go to the program (`zig build run -- 3 1 4 1 5`). Add `-Doptimize=safe` or `-Doptimize=fast` for optimized builds; the default is `debug`, with every safety check on. Some lectures have extra steps: `zig build fmt`, `cross` and `docs` in lecture 7, `run-c` and `translate` in lecture 9.

Or use the menu script at the root, which asks for a lecture (or all of them) and a configuration, and runs the matching `zig build` command:
```bash
./build.bash
```

Lecture 8's server and lecture 10's window run until you stop them (Ctrl-C, or closing the window); both take `--connections N` or `--frames N` to stop on their own. Lecture 10 picks the fastest GPU by default and lists the devices it found; `--device N` chooses another, which is worth doing on a machine whose discrete GPU is busy with something else. Lecture 10 also runs with `--headless`, rendering to a file with no window at all; that's how its test suite exercises it.

## Layout

```text
zig-course/
  README.md
  build.bash                 menu: choose a lecture and build / test / run it
  lecture_1/ ... lecture_10/ one Zig package per lecture
  lecture-md/lecture_N/      the write-ups
```
`zig-out/` (built programs), `.zig-cache/` (the compiler's cache) and `zig-pkg/` (fetched packages) appear inside each lecture as you build and are ignored by git.
