#!/usr/bin/env bash
# Build Mesa 25.0.7 as an arm64 iOS (Mach-O) dylib and, on top of it, the
# EAGL/OpenGL ES shim libhakios.gl.dylib that CoreAnimation talks to.
#
# This is the Linux port of leafall903's tools/mk-mesa.sh + userland/build.sh
# (GL=1), see README.md.  It runs on ubuntu-24.04 with:
#   * clang (Ubuntu's) targeting arm64-apple-ios16.5
#   * theos' Linux cctools (ld64, nm, install_name_tool) and theos/sdks
#     iPhoneOS16.5.sdk
#
# Environment:
#   THEOS    default $ROOT/theos
#   SDK      default $THEOS/sdks/iPhoneOS16.5.sdk
#   CCTOOLS  default $THEOS/toolchain/linux/iphone/bin
#   DRIVERS  default softpipe   (the reference also builds softpipe,freedreno)
#   WORK     default $ROOT/work
#   OUT      default $ROOT/out
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=${MESA_VERSION:-25.0.7}
SHA256=${MESA_SHA256:-592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6}
DRIVERS=${DRIVERS:-softpipe}
THEOS=${THEOS:-$ROOT/theos}
SDK=${SDK:-$THEOS/sdks/iPhoneOS16.5.sdk}
CCTOOLS=${CCTOOLS:-$THEOS/toolchain/linux/iphone/bin}
WORK=${WORK:-$ROOT/work}
OUT=${OUT:-$ROOT/out}
JOBS=${JOBS:-$(nproc)}
TARGET=${TARGET:-arm64-apple-ios16.5}

log() { printf '== %s\n' "$*"; }
die() { printf 'build: %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK" "$OUT"
cd "$WORK"

# ---------------------------------------------------------------- tool check
[ -d "$SDK/usr/include" ] || die "no SDK at $SDK (set SDK=...)"
[ -x "$CCTOOLS/ld" ] || die "no cctools ld64 at $CCTOOLS/ld (set CCTOOLS=...)"
[ -f "$SDK/usr/include/stdio.h" ] || die "$SDK is not an iPhoneOS SDK"

CLANG=${CLANG:-$(command -v clang || true)}
[ -n "$CLANG" ] || die "no clang"
CLANGXX=${CLANGXX:-${CLANG}++}
[ -x "$CLANGXX" ] || CLANGXX=$CLANG

# Ubuntu installs versioned LLVM tools (llvm-ar-18); take the newest.
llvm_tool() {
	local t
	if command -v "$1" >/dev/null 2>&1; then command -v "$1"; return; fi
	t=$(ls -1 /usr/bin/"$1"-* 2>/dev/null | sort -V | tail -1 || true)
	[ -n "$t" ] || die "no $1 (install llvm)"
	printf '%s\n' "$t"
}
AR=$(llvm_tool llvm-ar)
RANLIB=$(llvm_tool llvm-ranlib)
STRIP=$(llvm_tool llvm-strip)
NM=$(command -v "$CCTOOLS/nm" 2>/dev/null || llvm_tool llvm-nm)
INS=$(command -v "$CCTOOLS/install_name_tool" 2>/dev/null || llvm_tool llvm-install-name-tool)

log "clang: $($CLANG --version | head -1)"
log "sdk:   $SDK"
log "ld64:  $CCTOOLS/ld ($("$CCTOOLS/ld" -v 2>&1 | head -1 || true))"
log "drivers: $DRIVERS"

# ------------------------------------------------------------ compiler shim
# stock Linux clang defaults to ELF; this names the iPhoneOS target and the
# cctools ld64, exactly like xnu-deps/host/bin/xnu-clang does for the kernel.
cat > "$WORK/apple-clang" <<EOF
#!/bin/bash
case "\$(basename "\$0")" in
	*++) drv="$CLANGXX" ;;
	*)   drv="$CLANG" ;;
esac
exec "\$drv" -target "$TARGET" -isysroot "$SDK" -Wno-unused-command-line-argument --ld-path="$CCTOOLS/ld" "\$@"
EOF
chmod +x "$WORK/apple-clang"
ln -sf "$WORK/apple-clang" "$WORK/apple-clang++"

# ------------------------------------------------------------- Mesa sources
if [ ! -f "mesa-$VERSION.tar.xz" ]; then
	log "downloading mesa-$VERSION.tar.xz"
	curl -L --fail --retry 5 -sS -o "mesa-$VERSION.tar.xz" \
		"https://archive.mesa3d.org/mesa-$VERSION.tar.xz" || die "download failed"
fi
echo "$SHA256  mesa-$VERSION.tar.xz" | sha256sum -c --quiet -

if [ ! -d "mesa-$VERSION" ] || [ ! -f "mesa-$VERSION/.patched" ]; then
	log "unpacking and patching Mesa $VERSION"
	rm -rf "mesa-$VERSION"
	tar xJf "mesa-$VERSION.tar.xz"
	patch -s -p1 --no-backup-if-mismatch -d "mesa-$VERSION" < "$ROOT/patches/mesa-$VERSION-umi-v6.patch" \
		|| die "the patch does not apply to Mesa $VERSION (see patch output above)"
	touch "mesa-$VERSION/.patched"
fi

# The reference always builds softpipe+freedreno, so its osmesa target lists
# freedreno unconditionally.  With a software-only build driver_freedreno is
# not defined and meson would stop here; drop the dependency.
if [[ ",$DRIVERS," != *",freedreno,"* ]]; then
	python3 - "$WORK/mesa-$VERSION/src/gallium/targets/osmesa/meson.build" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "    driver_freedreno, idep_xmlconfig, dep_libdrm,\n"
if needle in s:
    open(p, "w").write(s.replace(needle, "", 1))
PY
fi

# ------------------------------------------------------------ meson cross file
cat > cross.ini <<EOF
[binaries]
c = ['$WORK/apple-clang']
cpp = ['$WORK/apple-clang++']
objc = ['$WORK/apple-clang']
ar = '$AR'
ranlib = '$RANLIB'
strip = '$STRIP'
pkg-config = 'false'

[host_machine]
system = 'darwin'
subsystem = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true

# meson's has_header_symbol('time.h', 'struct timespec') answers NO for the
# iPhoneOS SDK (it compiles "(void) struct timespec;", which clang rejects for a
# complete type), so Mesa would define struct timespec itself and clash with
# sys/_types/_timespec.h.  Apple's SDK has it; say so.
[built-in options]
c_args = ['-DHAVE_STRUCT_TIMESPEC']
cpp_args = ['-DHAVE_STRUCT_TIMESPEC']
EOF

BUILD="build-${DRIVERS//,/-}"
EXTRA=()
if [[ ",$DRIVERS," == *",freedreno,"* ]]; then
	EXTRA+=(-Dfreedreno-kmds=msm)
fi

if [ ! -f "$BUILD/build.ninja" ]; then
	log "meson setup ($BUILD)"
	meson setup "$BUILD" "mesa-$VERSION" --cross-file cross.ini --wrap-mode=nofallback \
		--prefix=/redwood --libdir=lib --buildtype=release -Db_ndebug=true \
		-Dplatforms= -Dgallium-drivers="$DRIVERS" "${EXTRA[@]}" \
		-Dvulkan-drivers= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
		-Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
		-Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled -Dshader-cache=disabled -Dvalgrind=disabled \
		-Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= -Dtools= -Dgallium-vdpau=disabled -Dgallium-va=disabled \
		-Dgallium-xa=disabled -Dlmsensors=disabled -Dbuild-tests=false > meson-setup.log 2>&1 \
		|| { tail -80 meson-setup.log; die "meson setup failed"; }
fi

log "ninja ($JOBS jobs)"
ninja -C "$BUILD" -j "$JOBS" > ninja.log 2>&1 || { tail -100 ninja.log; die "ninja failed"; }

LIB="$BUILD/src/gallium/targets/osmesa/libOSMesa.8.dylib"
[ -f "$LIB" ] || die "no $LIB after the build"

# ------------------------------------------------------- libOSMesa.8.dylib
"$STRIP" -x -o "$OUT/libOSMesa.8.dylib" "$LIB"
"$INS" -id /redwood/lib/libOSMesa.8.dylib "$OUT/libOSMesa.8.dylib" 2>/dev/null \
	|| { echo "build: install_name_tool -id failed" >&2; exit 1; }
"$NM" -gU "$OUT/libOSMesa.8.dylib" 2>/dev/null | awk '$3 ~ /^_gl/ { print substr($3, 2) }' | sort -u > "$OUT/exported-gl.txt"
cp "mesa-$VERSION/src/mapi/glapi/registry/gl.xml" "$OUT/gl.xml"

# --------------------------------------------------- libhakios.gl.dylib
# The EAGL replacement: eagl.c (method swizzling on EAGLContext) behind
# gl_osmesa.c (OSMesa with an OpenGL ES profile).
log "linking libhakios.gl.dylib"
"$WORK/apple-clang" -dynamiclib -O1 \
	-install_name /redwood/lib/libhakios.gl.dylib \
	-I"$ROOT/gl" \
	-framework CoreFoundation -framework IOKit -framework IOSurface -lobjc \
	"$OUT/libOSMesa.8.dylib" \
	"$ROOT/gl/eagl.c" "$ROOT/gl/gl_osmesa.c" \
	-o "$OUT/libhakios.gl.dylib" || die "libhakios.gl.dylib link failed"

{
	echo "mesa $VERSION drivers=$DRIVERS"
	echo "mesa archive sha256 $SHA256"
	echo "patch sha256 $(sha256sum "$ROOT/patches/mesa-$VERSION-umi-v6.patch" | cut -d' ' -f1)"
	echo "clang $($CLANG --version | head -1)"
	echo "target $TARGET"
	echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/BUILD-INFO.txt"

log "outputs:"
ls -l "$OUT"
for f in "$OUT"/*.dylib; do file "$f"; done
log "gl* exports: $(wc -l < "$OUT/exported-gl.txt")"
