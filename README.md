# Quick Start

Requirements:
* [Odin](https://github.com/odin-lang/Odin/releases/tag/dev-2025-02) (at least release 2025-02 for SDL3 support)
* [SDL3](https://wiki.libsdl.org/SDL3/FrontPage)
* A system with [Vulkan](https://www.vulkan.org/) support

Can be build simply by invoking the Odin compiler:
```bash
odin build . -debug     # enable debug symbols and vulkan validation
```
```bash
odin build . -o:speed   # release build
```

If you modify the shaders you need to recompile the glsl code into SPIR-V bytecode, eg. using [`shaderc`](https://github.com/google/shaderc) (see `build.sh`)
