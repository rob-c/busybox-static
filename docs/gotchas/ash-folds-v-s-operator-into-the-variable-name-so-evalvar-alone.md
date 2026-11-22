---
title: "ash case modifiers: the bug is the evalvar shortcut, not the lexer"
kind: "gotcha"
summary: "Lexer is fine: ${v##} with the identical shape works, so the eaten character comes from evalvar's VSNORMAL shortcut — route the new case subtypes through subevalvar instead."
tags: [ash, evalvar, subevalvar, case-modifiers, vstype, vsnul]
created: "2026-11-21T16:17:00.457Z"
updated: "2026-11-21T16:31:46.862Z"
---
Five attempts at bash-style case modifiers (`${v^^}`, `${v,,}`, `${v^}`, `${v,}`) in busybox ash have failed and been reverted. The tree is pristine for the feature (still `bad substitution`); the only ash change kept is `$SECONDS`. The last experiment narrowed the remaining bug to one specific place, which is where the next attempt should start.

```text
 ${v##}  lexer consumes both '#'  ──► subevalvar() pattern path  ──► AabB   (correct)
 ${v^^}  lexer consumes both '^'  ──► my VSNORMAL shortcut       ──► AAB    (B eaten)
```

## The decisive measurement

The lexer is **not** the problem. `${v##}` uses the identical `case '%': case '#':` shape — `pgetc_eatbnl()`, compare with `cc`, `subtype++` or `pungetc()`, `newsyn = BASESYNTAX` — and quoted `${v##}B` prints `AabB` correctly. With four distinct subtypes (`VSUPPER`, `VSUPPERALL`, `VSLOWER`, `VSLOWERALL` in the freed `0x0e`–`0x11` range, after widening `VSTYPE` to `0x1f` and moving `VSNUL` to `0x20`) all four forms then *convert* correctly — `HELLO WORLD`, `hello world`, `HeLLo woRLD`, `heLLo woRLD` — but one character after the expansion is still consumed: `printf "A${v^^}B"` emits `AAB`.

So the loss happens in `evalvar()`'s shortcut, not in parsing. What my version does that `${v##}` does not:

```c
	/* subtype rewritten to VSNORMAL, then straight to record */
	varflags &= ~VSTYPE; varflags |= VSNORMAL; subtype = VSNORMAL;
	...
	if (subtype == VSNORMAL) { /* convert bytes */ goto record; }
```

## What to try next

Do **not** shortcut to `VSNORMAL`. Route the four new subtypes through the existing pattern path (`flag |= discard; STPUTC('\0', expdest); patloc = ...; p = subevalvar(...)`) with an empty pattern, the way `VSTRIMLEFT` does, and convert the bytes at `startloc` afterwards. That path is proven not to lose a character. Alternatively find what consumes the extra byte: something after `evalvar()` returns must be advancing by one, and the difference between the two paths is exactly whether `subevalvar()` ran.

Also note `subtype` is a `char` in `evalvar()` and the widened values are all below `0x20`, so signedness is not the cause — but any new comparison must mask with `VSTYPE` (`(subtype & VSTYPE) == VSNORMAL`), because `VSNUL` is now `0x20` and sits above the mask.
