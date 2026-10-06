/* iOS-Madeira -- the app's own copy of the iOS-only symbols FEXCore expects.
 *
 * This file provides two groups: the FEX bridges (below), and the allocator
 * globals that ship inside the rpmalloc submodule (further down). Both have the
 * same shape of problem: FEX arranges for a guest *module* to define them, and
 * the app is a third consumer of FEXCore that links no module.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * FEXCore's shared code calls these symbols unconditionally on an iOS host. The
 * definitions live in the *guest modules* -- Source/Windows/WOW64 for the 32-bit
 * module and Source/Windows/ARM64EC for the x86-64 one -- and FEX arranges for
 * them to resolve by linking module and FEXCore into a single image: both module
 * CMakeLists.txt files list $<TARGET_OBJECTS:FEXCore_object>, and FEXCore_object
 * is real (created by AddObject(${PROJECT_NAME}_object) at
 * FEXCore/Source/CMakeLists.txt:271, wrapped into the archive by AddLibrary at
 * 279).
 *
 * The app is a third consumer of FEXCore and does not link either module. It
 * links libFEXCore.a directly -- FEXBridge.mm creates FEXCore::Context::Context
 * itself -- so it must supply the bridge too. build/fex-ios/build.sh builds only
 * FEXCore, FEXCore_Base, JemallocLibs and rpmalloc, which is why the link
 * reported IosMonoResolveRW, IosSubfloorToReal and the five ios_fex_mono_*
 * symbols undefined even though the app ships xtajit.dll and xtajit64.dll: those
 * are PE images the guest loader maps at runtime, and a PE image cannot satisfy
 * a static link.
 *
 * IosMonoBridge.cpp states the rule: the bridge is needed by "Core.cpp's
 * MonoBackpatcherWrite and the Windows InvalidationTracker" and "each statically
 * links its own copy of FEXCore, so neither can borrow the other's storage". The
 * app is one more copy, so it needs one more set of storage. That is all this
 * is.
 *
 * WHICH VARIANT, AND WHY
 * ----------------------
 * The two modules provide the same names with different bodies. The app's
 * FEXCore is a plain aarch64 build -- build/fex-ios/build.sh does not set
 * ARCHITECTURE_arm64ec -- so the relevant counterpart is the WOW64 one, which
 * Core.cpp itself calls "a plain aarch64 PE". The ARM64EC file cannot be used
 * here in any case: it includes <windows.h> and <winternl.h> and its
 * IosAliasEntries table is consumed by Module.S's ExitFunctionEC, none of which
 * exists in a Mach-O link.
 *
 * The mono-bridge bodies below are the bodies from
 * Source/Windows/WOW64/IosMonoBridge.cpp, with two mechanical changes:
 *   - no windows.h. The only thing it was used for is the TEB/PEB read, which is
 *     the weak ios_jit_current_peb() below.
 *   - IOS_FEX_EXPORT instead of __declspec(dllexport): these have to be visible
 *     across archive boundaries in one link, not exported from a DLL.
 *
 * NOTHING PUBLISHES THE BRIDGE YET, AND THAT IS SAFE
 * --------------------------------------------------
 * g_MonoBridge is null until something calls BTCpuIosSetMonoBridge, and nothing
 * in this tree does: that name appears only inside the prebuilt xtajit.dll, and
 * not in build/, wine/ or app/. IosMonoBridge.cpp documents what that state
 * means, and it is not a stub: "Until Wine calls BTCpuIosSetMonoBridge,
 * g_MonoBridge is null: every resolve misses, the miss is counted, and
 * MonoBackpatcherWrite falls back to the direct store, which faults and is
 * emulated exactly as it is today. That is a real answer ('no bridge has been
 * published'), not a stub that pretends to have succeeded."
 *
 * So this file reproduces the module's semantics exactly, including that default,
 * and becomes fully functional the moment anything publishes and arms the
 * bridge. It does not fake success anywhere: IosMonoResolveRW returns 0 on
 * every miss and the caller counts it.
 */

#include <stdint.h>
#include <stdatomic.h>
#include <stddef.h>

#include "ios_mono_bridge.h"

#define IOS_FEX_EXPORT __attribute__((visibility("default")))

/* Defined in FEXCore's Core.cpp (lines 1346 and 1369), which owns the types and
 * LogMan. The module declares these as plain externs; here they are weak for a
 * link-order reason. This object is a member of libntdll_unix.a, which the
 * Frameworks phase lists *after* libFEXCore.a, so when it is pulled to satisfy
 * FEXCore's own references, ld has already been past libFEXCore.a. Both symbols
 * happen to sit in Core.cpp's translation unit -- the very member already loaded
 * for CompileBlock and MonoBackpatcherWrite -- so they do resolve today. Weak
 * linking makes that a property of the symbol rather than a property of archive
 * order, so a future reshuffle of FEXCore's sources cannot turn it back into a
 * link failure that only shows up 25 minutes into a CI run. A null hook simply
 * skips the notification. */
extern void ios_fex_mono_bridge_publish(void *Bridge) __attribute__((weak_import));
extern void ios_fex_mono_report_armed(uint64_t Base, uint64_t End) __attribute__((weak_import));

/* Declared weakly on purpose. The real definition is not in this file, and a
 * hard reference would turn "the app has no PEB accessor" into a link error for
 * a function whose only consumer is already gated off. loader_ios.c and
 * server_ios.c declare it the same way (as a plain extern, because for them it
 * always exists); here it is resolved if present and treated as absent if not.
 * A null return is the same condition the module handles: its IosMonoBridge.cpp
 * does `if (!Context) return 0;`. */
extern void *ios_jit_current_peb(void) __attribute__((weak_import));

/* ------------------------------------------------------------------------
 * Sub-floor window lookups
 *
 * Ported from Source/Windows/WOW64/Module.cpp:2061, which is the WOW64 module's
 * own account of why this is not a placeholder:
 *
 *   "FEXCore's Frontend and OpcodeDispatcher call the ARM64EC module's sub-floor
 *    window lookups (ARM64EC/IosJitAlias.cpp) on the iOS host, which the WOW64
 *    module does not link. A 32-bit guest lives entirely inside its own 4 GB
 *    window and never has a PE image mapped below the 4 GB floor, so here there
 *    is no window: addresses map to themselves and no code belongs to one."
 *
 * IosSubfloorToReal is called from Frontend.cpp:1408 on every
 * DecodeInstructionsAtEntry, so it is on the translation path and must be right,
 * not merely present: identity is what this host needs, because the app's
 * FEXCore is the same non-ARM64EC build the comment describes.
 * IosSubfloorWindowForCode is referenced from OpcodeDispatcher.cpp:4008, inside
 * the FEX_GUEST_WINDOW block that this configuration leaves off; it is defined
 * here anyway so the pair stays together and a future guest-window build does
 * not rediscover the same link failure.
 * ------------------------------------------------------------------------ */

IOS_FEX_EXPORT uint64_t IosSubfloorToReal(uint64_t Addr) {
    return Addr;
}

IOS_FEX_EXPORT int IosSubfloorWindowForCode(uint64_t Rip, uint64_t *Low,
                                            uint64_t *Size, uint64_t *Real) {
    (void)Rip;
    (void)Low;
    (void)Size;
    (void)Real;
    return 0;
}

/* ------------------------------------------------------------------------
 * The mono backpatcher bridge
 * ------------------------------------------------------------------------ */

static _Atomic(struct ios_mono_bridge *) g_MonoBridge;

/* The publish entry point, named as the module names it (BTCpuIos* matching the
 * WoW64 BT API prefix; the ARM64EC module uses BTCpu64Ios*). Kept here so the
 * bridge can actually be turned on from the app side without another FEX change;
 * see the file header for why it is inert today. */
IOS_FEX_EXPORT void BTCpuIosSetMonoBridge(uint64_t BridgeAddr) {
    struct ios_mono_bridge *B = (struct ios_mono_bridge *)(uintptr_t)BridgeAddr;
    if (!B || B->abi_version != IOS_MONO_ABI_VERSION) {
        /* Refuse rather than arm a struct whose layout we cannot trust -- the
         * native side reads it from inside a Mach fault handler. */
        return;
    }
    atomic_store_explicit(&g_MonoBridge, B, memory_order_release);
    if (ios_fex_mono_bridge_publish) {
        ios_fex_mono_bridge_publish(B);
    }
}

/* Resolve an executable address to its writable alias. Sequence-lock read
 * exactly as the writer publishes: sample the generation, read, sample again,
 * accept only when both are equal and ODD. A retired-and-reused slot therefore
 * misses instead of returning a stale mapping, which would put a guest code
 * write into memory that no longer backs it. Returns 0 on miss; the caller
 * counts it and falls back rather than guessing.
 *
 * The parameter is a HOST address. Everything in this table is an address
 * actually mapped in this process, and MonoBackpatcherWrite applies the guest
 * window before calling in -- the name says host so a reader does not
 * "helpfully" add the base a second time. */
IOS_FEX_EXPORT uint64_t IosMonoResolveRW(uint64_t HostAddr, uint64_t Size) {
    struct ios_mono_bridge *B = atomic_load_explicit(&g_MonoBridge, memory_order_acquire);
    if (!B) {
        return 0;
    }
    const uint32_t Count = __atomic_load_n(&B->alias_count, __ATOMIC_ACQUIRE);
    for (uint32_t i = 0; i < Count && i < IOS_MONO_MAX_ALIASES; i++) {
        const uint32_t G1 = __atomic_load_n(&B->aliases[i].generation, __ATOMIC_ACQUIRE);
        if (!(G1 & 1)) {
            continue; /* retired or mid-update */
        }
        const uint64_t Base = B->aliases[i].guest_rx;
        const uint64_t Sz = B->aliases[i].size;
        const uint64_t RW = B->aliases[i].host_rw;
        const uint32_t G2 = __atomic_load_n(&B->aliases[i].generation, __ATOMIC_ACQUIRE);
        if (G1 != G2) {
            continue; /* changed under us */
        }
        if (HostAddr >= Base && HostAddr + Size <= Base + Sz) {
            return RW + (HostAddr - Base);
        }
    }
    return 0;
}

/* Called the moment the Mono module is recognised. Until this runs, mono_base is
 * 0 and the native Mach handler declines every capture. */
IOS_FEX_EXPORT void ios_fex_mono_arm(uint64_t Base, uint64_t End) {
    struct ios_mono_bridge *B = atomic_load_explicit(&g_MonoBridge, memory_order_acquire);
    if (!B) {
        return;
    }
    B->mono_end = End;
    __atomic_store_n(&B->mono_base, Base, __ATOMIC_RELEASE); /* publish LAST: it is the gate */
    if (ios_fex_mono_report_armed) {
        ios_fex_mono_report_armed(Base, End);
    }
}

/* Take this context's pending event, if any. One-shot: the slot moves to state 2
 * and never fires again for this process, so a mis-detection cannot loop.
 *
 * Keyed by PEB because pseudo-processes share one address space -- a global slot
 * would let one process's fault mark another process's block. The module reads
 * that from CurrentTEB()->ProcessEnvironmentBlock; this host has no TEB, so it
 * asks ios_jit_current_peb(), which is weak and may be absent. Absent means no
 * context, which means no match: return 0, the same thing the module does when
 * its Context read comes back zero. */
IOS_FEX_EXPORT int ios_fex_mono_take_pending(uint64_t *BlockBegin, uint64_t *HostPC,
                                             uint64_t *FaultAddr) {
    struct ios_mono_bridge *B = atomic_load_explicit(&g_MonoBridge, memory_order_acquire);
    if (!B) {
        return 0;
    }
    const uint64_t Context =
        ios_jit_current_peb ? (uint64_t)(uintptr_t)ios_jit_current_peb() : 0;
    if (!Context) {
        return 0;
    }
    for (uint32_t i = 0; i < IOS_MONO_MAX_CONTEXTS; i++) {
        struct ios_mono_pending *P = &B->pending[i];
        if (__atomic_load_n(&P->context, __ATOMIC_ACQUIRE) != Context) {
            continue;
        }
        uint32_t Want = 1;
        if (!__atomic_compare_exchange_n(&P->state, &Want, 2, 0, __ATOMIC_ACQ_REL,
                                         __ATOMIC_ACQUIRE)) {
            return 0; /* empty, or already consumed */
        }
        *BlockBegin = P->block_begin;
        *HostPC = P->host_pc;
        *FaultAddr = P->fault_addr;
        return 1;
    }
    return 0;
}

/* One relaxed load. Keeps CompileBlock's added cost to a load+branch until the
 * bridge is armed AND something is actually pending. */
IOS_FEX_EXPORT int ios_fex_mono_bridge_armed(void) {
    struct ios_mono_bridge *B = atomic_load_explicit(&g_MonoBridge, memory_order_acquire);
    if (!B || !__atomic_load_n(&B->mono_base, __ATOMIC_ACQUIRE)) {
        return 0;
    }
    return __atomic_load_n(&B->n_captured, __ATOMIC_RELAXED) !=
           __atomic_load_n(&B->n_activated, __ATOMIC_RELAXED);
}

IOS_FEX_EXPORT void ios_fex_mono_count_activated(void) {
    struct ios_mono_bridge *B = atomic_load_explicit(&g_MonoBridge, memory_order_acquire);
    if (B) {
        __atomic_add_fetch(&B->n_activated, 1, __ATOMIC_RELAXED);
    }
}

IOS_FEX_EXPORT uint64_t ios_fex_mono_captured_count(void) {
    struct ios_mono_bridge *B = atomic_load_explicit(&g_MonoBridge, memory_order_acquire);
    return B ? __atomic_load_n(&B->n_captured, __ATOMIC_RELAXED) : 0;
}

/* Counters live with the table, off the caller's hot path. */
IOS_FEX_EXPORT void ios_fex_mono_count_helper(int Miss) {
    struct ios_mono_bridge *B = atomic_load_explicit(&g_MonoBridge, memory_order_acquire);
    if (!B) {
        return;
    }
    __atomic_add_fetch(&B->n_helper_calls, 1, __ATOMIC_RELAXED);
    if (Miss) {
        __atomic_add_fetch(&B->n_alias_miss, 1, __ATOMIC_RELAXED);
    }
}

/* ------------------------------------------------------------------------
 * The allocator globals, which normally live in the rpmalloc submodule
 *
 * FEXCore references these unconditionally. Their definitions are in
 * FEX/External/rpmalloc/rpmalloc/rpmalloc.c, inside its `#ifdef FEX_IOS_HOST`
 * block, and that submodule is added only under `if (ENABLE_FEX_ALLOCATOR)` --
 * which FEX's own CMakeLists.txt forces to FALSE on Apple:
 *
 *     if (APPLE)
 *       set(ENABLE_FEX_ALLOCATOR FALSE)
 *       message(STATUS "Apple platform detected - disabling jemalloc and rpmalloc")
 *
 * A plain set() shadows a -D from the command line, so passing ON cannot help.
 * I tried that first, and it is worth recording why it was worse than useless:
 * it does not add the submodule, so librpmalloc.a is never produced, while my
 * pbxproj edit had already asked the linker for it. The link would have failed
 * on a missing library instead of a missing symbol. Both halves are reverted.
 *
 * The comment in rpmalloc.c beside these says they live there "purely so that
 * every FEX binary that links FEXCore has a definition without each one needing
 * its own". On Apple that promise cannot be kept by rpmalloc, so the app keeps
 * it here. Nothing about the values is invented:
 *
 *   - the two band globals are 0, which is the value the submodule itself
 *     starts them at and which every reader treats as "not published".
 *     AllocatorHooks.h says so directly: `if (!ios_fex_band_base)`, then "No
 *     host-only band on this device. Falling through to the unconstrained path
 *     is exactly what corrupts a constrained device, so fail visibly instead",
 *     and it returns nullptr. On this host the band genuinely was never chosen,
 *     because the code that chooses it (ios_fex_band_select) is inside the
 *     PLATFORM_WINDOWS branch of that same file.
 *
 *   - the JIT-pool pair is 0 for the same reason, and its comment gives the
 *     meaning: "Zero means 'not published yet' and disables the check rather
 *     than failing allocations." On the modules, Module.cpp fills them in at
 *     process init; there is no such init here.
 *
 *   - rpm_cas_snapshot_take returning 0 is the documented "no snapshot
 *     available": Core.cpp only uses it to print one [rpm-cas] diagnostic line,
 *     and returns early when it is 0. There is no rpmalloc CAS machinery in this
 *     process to snapshot, so 0 is the true answer, not a placeholder.
 * ------------------------------------------------------------------------ */

IOS_FEX_EXPORT uintptr_t ios_fex_band_base = 0;
IOS_FEX_EXPORT uintptr_t ios_fex_band_end = 0;
IOS_FEX_EXPORT uintptr_t ios_fex_jit_pool_rx = 0;
IOS_FEX_EXPORT uintptr_t ios_fex_jit_pool_end = 0;

/* Left incomplete on purpose: nothing here reads the struct, and the caller
 * (Core.cpp) declares it inside an extern "C" block, so the C++ name and this
 * one are the same symbol. */
struct rpm_cas_snapshot;

IOS_FEX_EXPORT int rpm_cas_snapshot_take(struct rpm_cas_snapshot *out) {
    (void)out;
    return 0;
}
