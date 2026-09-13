# nifly patches

Local fixes to the `native/nifly` submodule.

nifly is pinned to `ousnius/nifly` upstream, so a fix cannot be committed into the
checkout — the submodule pointer would have nowhere to point. Each fix lives here as
a patch and is applied to the checkout by `native/SConstruct` before nifly's sources
are globbed into the build. A fresh clone or a `git submodule update` therefore still
builds a patched nifly.

Application is idempotent: a patch that already reverse-applies is skipped. A patch
that neither applies nor reverse-applies **stops the build** — upstream has moved and
the patch needs rebasing, or the fix has landed and the patch should be deleted.
An unpatched nifly reads NIFs subtly wrong rather than failing to link, so this case
must never be silent.

`git status` will report `native/nifly (modified content)` on a built tree. That is
expected and is the patch being present. Do not `git checkout` or `git submodule
update --force` it away; the next build re-applies it either way.

## Rebasing a patch

```
cd native/nifly
git apply --reverse ../nifly_patches/<patch>      # back to pristine
<make the change again against the new upstream>
git diff -- <file> > ../nifly_patches/<patch>
```

## Current patches

### `0001-nistring-read-preserve-embedded-nuls.patch`

`NiString::Read()` ended with `str = buf.get()`, a `char*` assignment that stops at
the first embedded NUL. `NiStringPalette` is a single `NiString` holding
NUL-*separated* entries, so a 1,107-byte palette loaded as its first 5 bytes and every
offset past the first entry resolved to nothing. The patch tracks the byte count each
size branch read and uses `str.assign(buf.get(), sizeRead)`.

Affects 360 controlled blocks across five player idles in `Fallout - Meshes.bsa`:
`eatidle.kf`, `pistolvariant01.kf`, `talk_handsatside_moving.kf`,
`talk_handsatside_moving2.kf`, `talk_handsatside_still2.kf`.

Inert elsewhere: every other NIF string is read at its exact length with no embedded
NUL, so assigning by length yields the same bytes as stopping at the terminator.
SHA-256 over all 140,475 node names in the corpus is identical with and without it.

Reported upstream as [ousnius/nifly#66](https://github.com/ousnius/nifly/issues/66).
Delete this patch and the entry above once that lands and the submodule is advanced.
