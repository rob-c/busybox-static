---
title: "Usage-text edits need the binary deleted first, or make silently keeps the old help"
kind: "gotcha"
summary: "After a usage-text edit, `make` reports success without relinking busybox; delete the binary plus usage_compressed.h/appletlib.o/applets/*.o and run oldconfig first."
tags: [make, relink, usage, umount, build]
created: "2026-11-23T21:32:05.124Z"
updated: "2026-11-23T21:32:05.124Z"
---
`make` will report success without relinking `busybox` after a usage-text change — the help output stays stale and every "the edit did nothing" conclusion that follows is wrong. The reliable recipe is to remove the binary and the generated usage artefacts first.

```mermaid
flowchart LR
  A["edit //usage: + usage.h"] --> B["make: 'success',<br/>help unchanged"]
  B --> C["rm busybox + usage_compressed.h<br/>+ appletlib.o + applets/*.o"]
  C --> D["oldconfig, then make"]
  D --> E["help updates"]
```

## The recipe

```sh
rm -f build/$TARGET/busybox build/$TARGET/include/usage_compressed.h \
      build/$TARGET/libbb/appletlib.o build/$TARGET/applets/*.o
yes '' | make -C src O=$PWD/build/$TARGET oldconfig   # .config newer than autoconf.h fails otherwise
make -C src O=$PWD/build/$TARGET -j18 CC="…" AR=… RANLIB=…
```

`oldconfig` is not optional: deleting objects leaves `.config` newer than `include/autoconf.h`, and the next `make` runs a prompting `silentoldconfig` that dies without a tty.

## Worked example: umount

`FEATURE_MOUNT_LOOP` gates `-d`'s help text, but `OPTION_STRING` in `src/util-linux/umount.c` accepts `d` unconditionally (`"fldnrat:" "cvi"`), so the flag is a harmless no-op where there are no loop devices. With `"d"` moved out of the `IF_FEATURE_MOUNT_LOOP()` guard in both `src/util-linux/umount.c` and `src/include/usage.h`, the help should read `Usage: umount [-rlfda] [-t FSTYPE]`.

After the recipe above, the option string did update (`[-rlfda]`) — proof the recipe works. The `-d  Free loop device if it has been used` **description** line still did not appear, even though `build/$TARGET/include/usage.h` contains it, so a cache exists below `usage_compressed.h`. Treat that line as still differing until someone finds it.

## Two ways to check the edit actually landed

```sh
grep -n 'umount_trivial_usage' -A1 build/$TARGET/include/usage.h   # generated copy
cc -E -Ibuild/$TARGET/include -Isrc/include src/util-linux/umount.c | grep -m1 rlf
```

The second is the decisive one: it shows the string the compiler will actually embed. If the preprocessed macro is right and the binary disagrees, the problem is the relink, not the source.
