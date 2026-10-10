#!/usr/bin/env bash
#
# trim-qemu-sysroot.sh - keep only the parts of a UTM sysroot that a Linux guest
# on iOS actually loads.
#
# WHY THIS EXISTS
# The published QEMU payload is a whole build tree, not a runtime: 3,010 MiB of
# it, in 12,442 files, of which almost nothing is ever loaded. Shipping it as it
# stands is not merely wasteful. The IPA built from it (build-8, 2026-10-10)
# unpacked to 3.5 GiB in 14,136 entries, and SideStore could not re-sign it: the
# walk over a 3.5 GiB tree is what failed, and what it reported named a Mach-O
# slice because that is where it stopped. An app that cannot be installed is not
# a feature, so the payload is trimmed to what the launcher opens.
#
# WHAT IS KEPT, AND WHY EACH THING IS HERE
#   Frameworks/qemu-aarch64-softmmu.framework
#       The engine. ONE simulation target: the launcher boots aarch64 guests
#       with an aarch64 UEFI firmware, so the x86_64, i386, ppc, ppc64, riscv64
#       and m68k cores it also ships can never be started by this app.
#   Frameworks/*.framework (the rest)
#       The engine's dependencies. These are the LOADABLE copies: their install
#       names are `@rpath/<name>.framework/<name>`. The same libraries under
#       lib/ name themselves with the absolute path of the machine that built
#       them (`/Users/runner/work/.../lib/libglib-2.0.0.dylib`), which resolves
#       on no device, so lib/ is a build tree and cannot be the runtime.
#       Deleting one of these is deleting a dependency of the engine, which is
#       why the list below is asserted rather than assumed.
#   share/qemu
#       Firmware, the machine descriptors that name it, and the small option
#       ROMs. The firmware images for machines this app cannot start are 241 MiB
#       of the 315 MiB, and they go.
#   share/glib-2.0
#       glib's compiled schema cache; gio reads it at startup.
#   loader/
#       0.6 MiB. The Vulkan loader virglrenderer looks for when a guest asks for
#       accelerated GL. Cheap enough to keep rather than find out the hard way.
#
# WHAT IS DROPPED
#   lib/, include/, bin/, sbin/, libexec/, host/, ssl/
#       The build tree, plus 97 command line tools, 1,093 headers, and a
#       pkg-config built to run on macOS. None of it is loaded by the launcher,
#       which dlopens one framework and calls three exported symbols.
#   share/{doc,man,locale,gtk-doc,info,gettext*,aclocal,installed-tests,gdb,...}
#       ~10,700 files of documentation and translations: 30 MiB, and more
#       entries than the rest of the app put together.
#
# IDEMPOTENT: everything here is a deletion guarded by a test, so running it on
# an already-trimmed sysroot changes nothing and still checks the result. It is
# called by linux-engine.yml before the payload is tarred, and by build.yml after
# the payload is fetched, so a stale published payload is still shipped correctly
# and a trimming mistake is caught by the build rather than by a device.
#
# Usage: trim-qemu-sysroot.sh <sysroot-directory>
# Exit 0 when the sysroot is trimmed and complete, 1 when it is not usable.

set -euo pipefail

root="${1:-}"
if [ -z "$root" ]; then
    echo "usage: trim-qemu-sysroot.sh <sysroot-directory>" >&2
    exit 1
fi
if [ ! -d "$root" ]; then
    echo "::error::$root is not a directory" >&2
    exit 1
fi
if [ ! -d "$root/Frameworks" ]; then
    echo "::error::$root has no Frameworks/ - this is not a UTM sysroot" >&2
    exit 1
fi

size_before=$(du -sk "$root" | cut -f1)
files_before=$(find "$root" -type f | wc -l | tr -d ' ')

# 1. One simulation target, not seven.
for framework in "$root"/Frameworks/qemu-*-softmmu.framework; do
    [ -e "$framework" ] || continue
    case "$(basename "$framework")" in
    qemu-aarch64-softmmu.framework) ;;
    *) rm -rf "$framework" ;;
    esac
done

# 2. The build tree.
rm -rf "$root/lib" "$root/include" "$root/bin" "$root/sbin" "$root/libexec" "$root/host" "$root/ssl"

# 3. Documentation, translations and headers under share/.
rm -rf \
    "$root/share/doc" \
    "$root/share/man" \
    "$root/share/locale" \
    "$root/share/gtk-doc" \
    "$root/share/info" \
    "$root/share/aclocal" \
    "$root/share/icons" \
    "$root/share/installed-tests" \
    "$root/share/gdb" \
    "$root/share/pkgconfig" \
    "$root/share/applications" \
    "$root/share/common-lisp" \
    "$root/share/bash-completion"
rm -rf "$root"/share/gettext* "$root"/share/gettext-*

# 4. Firmware for machines this app cannot start. The rule is a size, not a list
#    of names: every image a guest could need here is either the aarch64 pair
#    (named below) or small enough to be an option ROM, and the firmware for
#    other architectures is tens of megabytes each.
if [ -d "$root/share/qemu" ]; then
    find "$root/share/qemu" -maxdepth 1 -type f -size +1024k | while read -r image; do
        case "$(basename "$image")" in
        edk2-aarch64-code.fd | edk2-arm-vars.fd | edk2-aarch64-vars.fd) continue ;;
        esac
        rm -f "$image"
    done

    # The descriptors that name firmware which is now gone. QEMU reads them only
    # when it is asked to pick a firmware itself; the launcher passes the pair
    # explicitly, and a descriptor for a missing image would be a trap for
    # anyone who later lets QEMU choose.
    for descriptor in "$root"/share/qemu/firmware/*.json; do
        [ -e "$descriptor" ] || continue
        for named in $(grep -o '"[a-zA-Z0-9_.-]*\.fd"' "$descriptor" | tr -d '"'); do
            if [ ! -f "$root/share/qemu/$named" ]; then
                rm -f "$descriptor"
                break
            fi
        done
    done
fi

# 5. Now check that what is left is what the launcher opens. The engine's own
#    load commands name these frameworks, so each one is a file whose absence is
#    a dlopen failure on a device and nothing at all on the build machine.
engine="$root/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
if [ ! -f "$engine" ]; then
    echo "::error::$engine is missing: the payload has no aarch64 engine" >&2
    exit 1
fi

missing=""
for dependency in glib-2.0.0 gobject-2.0.0 gio-2.0.0 gmodule-2.0.0 pixman-1.0 jpeg.62 \
    epoxy.0 zstd.1 slirp.0 spice-server.1 virglrenderer.1; do
    [ -f "$root/Frameworks/$dependency.framework/$dependency" ] || missing="$missing $dependency"
done
if [ -n "$missing" ]; then
    echo "::error::the engine needs frameworks that are not in the payload:$missing" >&2
    echo "::error::they were deleted by this script or never built; see its header" >&2
    exit 1
fi

if [ ! -f "$root/share/qemu/edk2-aarch64-code.fd" ]; then
    echo "::error::$root/share/qemu/edk2-aarch64-code.fd is missing: a guest cannot boot without firmware" >&2
    exit 1
fi

size_after=$(du -sk "$root" | cut -f1)
files_after=$(find "$root" -type f | wc -l | tr -d ' ')
echo "sysroot trimmed: $((size_before / 1024)) MiB -> $((size_after / 1024)) MiB, $files_before -> $files_after file(s)"
echo "engine: Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
echo "firmware: share/qemu/edk2-aarch64-code.fd"
