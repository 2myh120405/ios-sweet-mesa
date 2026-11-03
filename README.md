# ios-sweet-mesa

Mesa 25.0.7 built as an **arm64 iOS (Mach-O) dylib** — a software OpenGL ES
implementation for iOS CoreAnimation on the umi (SM8250) xnu port.

This is the Linux/CI port of leafall903's build (ios-sweet-umi v6,
`tools/mk-mesa.sh` + `userland/build.sh` GL=1), which is the only known way to
keep CoreAnimation rendering without a GPU driver: CoreAnimation's render server
uses the OpenGL ES path when an `EAGLContext` implementation is present, and
`eagl.c` provides one backed by Mesa's OSMesa.

## What is built

| output | what it is |
|---|---|
| `out/libOSMesa.8.dylib` | Mesa: softpipe (software rasterizer, no LLVM), OSMesa with an **OpenGL ES 2/3 profile** (the `OSMESA_ES_PROFILE` patch), install name `/redwood/lib/libOSMesa.8.dylib` |
| `out/libhakios.gl.dylib` | `gl/eagl.c` (EAGLContext swizzling) + `gl/gl_osmesa.c` (OSMesa bridge), install name `/redwood/lib/libhakios.gl.dylib` |
| `out/exported-gl.txt` | the `gl*` functions `libOSMesa` exports |
| `out/gl.xml` | Khronos registry out of that Mesa tree |

`libhakios.gl.dylib` links `libOSMesa.8.dylib` with the absolute install name
`/redwood/lib/libOSMesa.8.dylib`; ship both at that path (or edit the load
command).

## Status

Built and verified on 2026-11-04 (run
[41669314311](https://github.com/2myh120405/ios-sweet-mesa/actions/runs/41669314311),
artifact `mesa-ios-softpipe`):

* `libOSMesa.8.dylib` 13,057,796 B — Mach-O arm64, `LC_BUILD_VERSION ios 16.5`,
  install name `/redwood/lib/libOSMesa.8.dylib`, 1,296 `gl*` exports, `NOUNDEFS`
* `libhakios.gl.dylib` 525,568 B — same platform; loads
  `/redwood/lib/libOSMesa.8.dylib`, CoreFoundation, IOKit, IOSurface, libobjc

Not yet run on a device. softpipe is a CPU rasterizer: correctness first, speed
unknown (the reference prefers freedreno when the kernel has a GPU driver).

## How it is built (no macOS runner)

* Ubuntu 24.04, stock `clang` targeting `arm64-apple-ios16.5`
* theos' Linux cctools as the linker (`ld64`, `nm`, `install_name_tool`)
* `iPhoneOS16.5.sdk` from [theos/sdks](https://github.com/theos/sdks) (sparse
  checkout, ~220 MB)
* Mesa 25.0.7 from archive.mesa3d.org, `patches/mesa-25.0.7-umi-v6.patch`
  (sha256 `6da1ef86...`) on top
* meson cross file: `system=darwin`, `subsystem=ios`, `cpu_family=aarch64`,
  `needs_exe_wrapper=true` — the reference's cross file

`scripts/build.sh` does all of it; `.github/workflows/build.yml` runs it and
uploads the dylibs as artifacts (workflow_dispatch, driver choice `softpipe` or
`softpipe,freedreno`).

The only change to the reference patch series: when freedreno is not built, the
`driver_freedreno, idep_xmlconfig, dep_libdrm` dependency the patch adds to
`src/gallium/targets/osmesa/meson.build` is removed (the reference always builds
freedreno). Nothing else is touched.

## Provenance

* Mesa 25.0.7 — <https://archive.mesa3d.org/mesa-25.0.7.tar.xz>
* `patches/mesa-25.0.7-umi-v6.patch` — from
  `ios-sweet-umi-v6/devices/umi/userland/mesa/`, itself the concatenation of
  Darwin-on-redwood's `tools/mesa/*.patch` (OSMesa ES profile, hakios-drm
  libdrm stand-in, freedreno/Darwin, ir3, AIR)
* `gl/*` — from the same v6 source drop (`userland/src/eagl.c`, `gl_osmesa.c`,
  `eagl_gen.h`, `hakios.gl.h`, `gpu_probe.c`)

## Caveats

* `eagl_gen.h` was generated for iOS 16.5's `OpenGLES` function table
  (`eagl_slots.txt`); this userland is 16.7.16, so the `getMacroContextPrivate`
  offsets are assumed unchanged — verify before shipping.
* softpipe is a CPU rasterizer. It is correct, not fast; the reference gets
  usable frames from the Adreno via freedreno when the kernel has a GPU driver,
  and falls back to softpipe otherwise.
* `libOSMesa.8.dylib` is not byte-reproducible (documented in the reference
  `mk-mesa.sh`); compare code, not hashes.
