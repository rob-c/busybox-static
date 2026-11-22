---
title: "Linking IOKit into busybox, and the four traps on the way"
kind: "gotcha"
summary: "iostat works on Darwin at 261 applets: link frameworks as -Wl,-framework,X tokens, put <locale.h> before libbb.h, CFSTR() only C-string keys, and fill GLOBAL_UPTIME or every rate divides by 1."
tags: [darwin, iostat, iokit, corefoundation, linking, locale, cfstring]
created: "2026-11-21T21:12:25.064Z"
updated: "2026-11-21T21:12:25.064Z"
---
`iostat` runs on Darwin (261 applets) with real per-disk throughput from IOKit. Getting there needed four fixes that will bite anyone linking a framework into busybox.

```text
 /proc/uptime    -> KERN_BOOTTIME                (SMP_UPTIME)
 /proc/stat      -> host_statistics(HOST_CPU_LOAD_INFO)   (4 state ticks + GLOBAL_UPTIME)
 /proc/diskstats -> IOKit IOBlockStorageDriver "Statistics"
```

## Linking a framework into busybox

`build.sh` exports the Darwin link line through `CONFIG_EXTRA_LDLIBS`. busybox splits that string on spaces and **prefixes `-l` to any token that does not start with `-`**, so `"-framework IOKit"` becomes `-framework -lIOKit` and `ld` reports `framework '-lIOKit' not found`. Pass a single token that already starts with a dash:

```text
 CONFIG_EXTRA_LDLIBS="-lresolv -Wl,-framework,IOKit -Wl,-framework,CoreFoundation"
```

IOKit alone is not enough: CoreFoundation is not re-exported at link time on arm64, so `CFDictionaryGetValue`, `CFRelease`, `___CFConstantStringClassReference` and friends stay undefined until `-framework CoreFoundation` is added too.

The `-pure` variants must remain libSystem-only, so `iostat` is disabled there (`CONFIG_IOSTAT=n` in build.sh's PURE branch); verified with `otool -L` — pure shows only `libSystem.B.dylib`.

## `<locale.h>` before `libbb.h`

Including CoreFoundation after libbb.h fails with a bizarre `locale.h:56:18: error: expected identifier or '('`. libbb.h contains `# define setlocale(x,y) ((void)0)` when locale support is off, so CoreFoundation's pull-in of `<locale.h>` macro-expands the *prototype*:

```c
char *_LIBC_CSTR   setlocale(int, const char *);   /* -> ((void)0)(int, char*) */
```

Include `<locale.h>` **before** `libbb.h`; the declaration is then parsed while the macro does not exist yet.

## CFSTR() is for C string literals only

`IOBlockStorageDriver.h` defines its keys as C strings (`"Statistics"`, `"Bytes (Read)"`), so they need `CFSTR(kIOBlobKey)`. `IOBSD.h` defines `kIOBSDNameKey` the same way. Passing the bare macro to `IORegistryEntryCreateCFProperty(...)` hands CF a `char*` and the process dies with `EXC_BREAKPOINT` inside `CoreFoundation __CF_IS_OBJC` — a crash with no useful message, and `bt` shows nothing because busybox is built with `-fno-unwind-tables`.

Two of the statistics key names are not what you would guess:

```text
 wrong                                right
 ...StatisticsReadOperationsKey   ->  ...StatisticsReadsKey    "Operations (Read)"
 ...StatisticsWriteOperationsKey  ->  ...StatisticsWritesKey   "Operations (Write)"
```

Guard the dictionary itself before reading: `if (!dict || CFGetTypeID(dict) != CFDictionaryGetTypeID()) return 0;`.

## Fill GLOBAL_UPTIME and SMP_UPTIME or every rate is wrong

`stats_cpu_t` is `cputime_t vector[N_STATS_CPU]`. A Darwin collector that fills only `STATS_CPU_{USER,NICE,SYSTEM,IDLE}` leaves `GLOBAL_UPTIME` and `SMP_UPTIME` at 0, so `get_interval()` returns 1 and the first report printed `42489790000.00` percent. Set `GLOBAL_UPTIME` to the sum of the four state counters and `SMP_UPTIME` to the boot-time delta.

## Instrument, do not guess

With unwind tables off, `lldb bt` yields only `frame #0`, so a CF crash is opaque. Three `fprintf(stderr, "DBG …")` markers — before the driver loop, after the BSD-name lookup, after the Statistics fetch — localised it in one build.
