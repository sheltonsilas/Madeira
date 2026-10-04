#!/bin/bash
# Build the ARM64EC modules that ordinary Windows programs need, but games do
# not. This is the fix for "I could not run a single app".
#
# WHY THIS EXISTS
# Madeira's PE farm is split in two:
#
#   aarch64-windows/   native ARM64 Windows. Has the shell programs:
#                      explorer.exe, cmd.exe, services.exe, wineboot.exe,
#                      rpcss.exe, notepad.exe, regedit.exe, taskmgr.exe.
#   arm64ec-windows/   the ARM64EC hybrid set, used for x86_64 guests. 144
#                      files, and NOT ONE of those programs.
#
# WineProcessBridge picks between them with the MADEIRA_USE_ARM64EC heuristic:
# an x86_64 program - which is essentially every real Windows application -
# runs against arm64ec-windows. That set carries the game-critical graphics
# stack (d3d9/10/11/12, dxgi, dcomp, winemetal, xinput) and almost nothing of
# the general-purpose stack. So a normal app launches with no shell, no command
# interpreter, no installer and no GDI+, and dies or hangs before drawing a
# window. Games worked because modules were added one game at a time.
#
# WHAT THIS ADDS
#   Programs: explorer.exe, services.exe, cmd.exe, wineboot.exe, msiexec.exe,
#             start.exe, rpcss.exe, conhost.exe, taskmgr.exe, regedit.exe,
#             notepad.exe, winecfg.exe
#   DLLs:     gdiplus.dll   - GDI+, used by a very large share of Win32 apps,
#                             .NET WinForms and many installers
#             msi.dll       - the Windows Installer engine msiexec.exe drives
#             d2d1.dll      - Direct2D
#             comdlg32/shell32/ole32/comctl32 are already tracked; they are
#             listed in the verify step only so a regression is caught.
#
# Not included, deliberately: dotnet and vcredist. dotnet's real runtime is a
# large Microsoft redistribution with its own terms, and the VC++ runtime is
# explicitly not redistributable (see docs/BUILDING.md and LICENSES/NOTICE).
# Both remain "supply it yourself" inputs.
#
# Requires the llvm-mingw toolchain and a configured wine/build-arm64ec, exactly
# as build/wine-pe/build-ntdll.sh does. Follows the same convention: build in
# the tree, copy the .dll or .exe out to app/Madeira/arm64ec-windows/. No
# strip/pad here - that is ntdll's special case.
set -eu

R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin"
export PATH="$TC:$PATH"
B="$R/wine/build-arm64ec"
DEST="$R/app/Madeira/arm64ec-windows"

if [ ! -f "$B/config.status" ]; then
    echo "error: $B is not configured. Run build/wine-pe/build-ntdll.sh first" >&2
    echo "       (it creates the tree with --enable-archs=arm64ec)." >&2
    exit 1
fi
[ -d "$DEST" ] || { echo "error: $DEST not found" >&2; exit 1; }

# Modules whose output is a .dll under dlls/<name>/arm64ec-windows/.
DLLS="gdiplus msi d2d1"
# Programs. In Wine these are built from programs/<name>/.
PROGS="explorer services cmd wineboot msiexec start rpcss conhost taskmgr regedit notepad winecfg"

copied=0
failed=""
# Where per-module make logs land when something fails. Kept out of the repo.
OBJ_LOG="${TMPDIR:-/tmp}/madeira-pe-universal"

copy_one() {
    # $1 = module name, $2 = expected file name
    local name="$1" file="$2" src
    src="$B/dlls/$name/arm64ec-windows/$file"
    [ -f "$src" ] || src="$B/programs/$name/arm64ec-windows/$file"
    if [ ! -f "$src" ]; then
        failed="$failed $name"
        return 1
    fi
    cp "$src" "$DEST/$file"
    echo "  + $file"
    copied=$((copied + 1))
}

echo "Building ARM64EC general-purpose modules into $DEST"

# build_module <dir> <label>
#
# Runs make in the module's OWN directory, which is what the generated stub
# Makefile expects: it forwards to the top-level tree as `<dir>/all`. The
# previous form, `make -C "$B" programs/<name>`, asked the top-level Makefile
# for a target that does not exist there (the real one is
# `programs/<name>/all`), so it failed for every program while gdiplus and
# d2d1 -- which used the per-directory form -- built fine. That mismatch is why
# the whole program set was reported as "produced nothing".
#
# Output is captured and echoed ONLY on failure. Swallowing it entirely
# (>/dev/null 2>&1) is what made the previous runs unreadable: a target that
# does not exist and a compiler error look identical in the log.
build_module() {
    local dir="$1"
    local label="$2"
    # Separate declaration: `local a="$1" b="$OBJ/$a.log"` cannot see $a under
    # `set -u` (which this script runs), and died with "label: unbound
    # variable" on the first module.
    local log="$OBJ_LOG/$label.log"
    mkdir -p "$(dirname "$log")"
    if make -C "$B/$dir" >"$log" 2>&1; then
        return 0
    fi
    echo "  --- make output for $label (tail) ---"
    tail -25 "$log" | sed 's/^/  | /'
    return 1
}

for name in $DLLS; do
    echo "=== dlls/$name ==="
    # A module that upstream does not carry is reported, not fatal: the goal is
    # the widest working set this fork can produce, and one absent module must
    # not stop the rest.
    build_module "dlls/$name" "dlls/$name" || echo "  ! make failed for dlls/$name"
    copy_one "$name" "$name.dll" || echo "  ! dlls/$name produced nothing"
done

for name in $PROGS; do
    echo "=== programs/$name ==="
    build_module "programs/$name" "programs/$name" || echo "  ! make failed for programs/$name"
    copy_one "$name" "$name.exe" || echo "  ! programs/$name produced nothing"
done

echo
echo "Copied $copied module(s) into app/Madeira/arm64ec-windows/."
if [ -n "$failed" ]; then
    echo "Not produced on this run:$failed"
    echo "Check the exact target name with: make -C wine/build-arm64ec help | grep <name>"
fi

# Verify the result, so a partial build is visible rather than silent.
echo
echo "Presence check in the arm64ec farm:"
missing=0
for f in gdiplus.dll msi.dll explorer.exe services.exe cmd.exe msiexec.exe \
         wineboot.exe shell32.dll comctl32.dll ole32.dll comdlg32.dll \
         d3d11.dll dxgi.dll winemetal.dll; do
    if [ -f "$DEST/$f" ]; then
        echo "  ok      $f"
    else
        echo "  MISSING $f"
        missing=$((missing + 1))
    fi
done
if [ "$missing" -gt 0 ]; then
    echo
    echo "$missing expected module(s) absent. An ordinary Windows app needs the"
    echo "shell, cmd and the installer; a game does not, which is why the gap was"
    echo "invisible until now."
    exit 1
fi
echo "All expected general-purpose modules present."