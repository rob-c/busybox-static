---
title: "lsblk on Darwin: IOKit IOMedia plus the existing getmntinfo layer"
kind: "discovery"
summary: "lsblk works on Darwin at 262 applets: enumerate IOKit IOMedia for name/size/whole, take mountpoints from the existing getmntinfo layer, and disable it in the -pure variants."
tags: [darwin, lsblk, iokit, iomedia, getmntinfo, pure]
created: "2026-11-21T21:20:32.215Z"
updated: "2026-11-21T21:20:32.215Z"
---
`lsblk` runs on Darwin (262 applets) listing real disks, partitions, sizes and mountpoints. The IOKit enumeration is small once `iostat` exists, and the mountpoints come from the layer `mount`/`df` already use.

```text
 NAME       source                          property / call
 name       IOKit IOMedia                   kIOBSDNameKey      "disk0s2"
 size       IOKit IOMedia                   kIOMediaSizeKey    bytes -> >>9 = sectors
 type       IOKit IOMedia                   kIOMediaWholeKey   true => "disk", else "part"
 mountpoint libbb/mntent.c -> getmntinfo(3)  match f_mntfromname == "/dev/<name>"
 MAJ:MIN    none                            prints "-"
```

## Two rules carried over from iostat

The `<locale.h>`-before-`libbb.h` ordering, and `CFSTR()` around the `kIO*Key` C-string macros, both apply unchanged. `IOKit/IOBSD.h` must be included explicitly for `kIOBSDNameKey`; `IOKit/storage/IOMedia.h` supplies the size/whole keys.

Type-safe property reads matter: a property may be a `CFNumber` *or* a `CFBoolean` (`kIOMediaWholeKey` is a boolean), so branch on `CFGetTypeID` before `CFNumberGetValue`, and always `CFRelease` what `IORegistryEntryCreateCFProperty` returns.

## Verified against the system tools

```text
 $ busybox lsblk
 NAME            MAJ:MIN  SIZE TYPE MOUNTPOINTS
 disk0           -       1863G disk
 disk0s1         -        550M part
 disk2s1         -       5119M part /System/Volumes/Update/SFR/mnt1
 disk5           -        170K disk /Volumes/SidePulse
```

`diskutil list` agrees on which units are physical vs synthesized (`disk0`, `disk3`, `disk5`), and the sizes match its partition tables.

## The `-pure` variants

`lsblk` needs the same IOKit/CoreFoundation dylibs as `iostat`, so it is disabled alongside it (`CONFIG_LSBLK=n` in build.sh's PURE branch). Verified after a full `build-all.sh`: pure is 259 applets and `otool -L` shows exactly one dependency, `libSystem.B.dylib`, while the full Darwin builds carry libresolv + IOKit + CoreFoundation + libSystem.
