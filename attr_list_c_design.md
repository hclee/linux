# NTFS attr_list C design notes

## Goal

Replace `ctx->al_entry` raw-pointer lifetime dependency with restartable
locator state while keeping the code change smaller than the reverted
search-context lifetime lock design.

The design must solve two problems together:

- prevent attr-list buffer replacement/free from invalidating state kept in
  `struct ntfs_attr_search_ctx`
- avoid the large lock-mode propagation caused by making `search_ctx` own
  `attr_list_lock` for its whole lifetime

## Final direction

### Summary

- remove `ctx->al_entry` as a raw pointer
- add restartable locator state to `struct ntfs_attr_search_ctx`
- add `attr_list_lock` and `attr_list_gen` to `struct ntfs_inode`
- use `attr_list_lock` only for short in-memory attr-list critical sections
- keep the current runlist-heavy structure as much as possible
- remove the true reverse locking cases by splitting in-memory attr-list
  mutation from on-disk `$ATTRIBUTE_LIST` persistence

### Lock order

The practical lock order is:

`inode_lock/i_rwsem -> mrec_lock -> runlist.lock -> attr_list_lock`

Rules:

- `runlist.lock -> attr_list_lock` is allowed
- `attr_list_lock -> runlist.lock` is forbidden
- `attr_list_lock` is not a `search_ctx` lifetime lock
- `attr_list_lock` only protects:
  - `base_ni->attr_list`
  - `base_ni->attr_list_size`
  - `base_ni->attr_list_gen`
  - in-memory ALE locate / splice / update

`attr_list_lock` must not be held across calls that can descend into runlist
allocation or runlist mutation.

## Why this lock order

The current NTFS code is already centered around `runlist.lock` in many write
paths, including:

- `file.c::ntfs_trim_prealloc()`
- `inode.c::__ntfs_write_inode()`
- `attrib.c::{ntfs_non_resident_attr_expand, ntfs_non_resident_attr_insert_range,
  ntfs_non_resident_attr_collapse_range, ntfs_non_resident_attr_punch_hole,
  ntfs_attr_fallocate}`
- `iomap.c::ntfs_write_da_iomap_begin_non_resident()`
- `compress.c::ntfs_write_cb()`
- `mft.c::{ntfs_mft_bitmap_extend_allocation_nolock,
  ntfs_mft_data_extend_allocation_nolock}`

Trying to make `attr_list_lock` outer than `runlist.lock` forces large-scale
helper/API changes. Keeping `runlist.lock` outer is the smaller change, as long
as the true reverse path is removed.

## The real reverse path to eliminate

The dangerous reverse path is not every attrlist-aware lookup. Under this
design, normal `ntfs_attr_lookup()` / `ntfs_external_attr_find()` only hold
`attr_list_lock` inside one call, so a later `runlist.lock` in the caller is
not an overlapping lock pair.

The true reverse cases are centered in `attrlist.c`:

- `ntfs_attrlist_update()`
- `ntfs_attrlist_entry_add()`
- `ntfs_attrlist_entry_rm()`

Why:

- these paths modify in-memory attr-list state
- then immediately persist `$ATTRIBUTE_LIST`
- persistence can call `ntfs_attr_truncate_i()`
- that can descend into `ntfs_resident_attr_resize()`
- that can descend into `ntfs_attr_make_non_resident()`
- that finally takes `runlist.lock`

So the reverse path is removed by a local split:

- hold `attr_list_lock` only for in-memory attr-list mutation
- drop `attr_list_lock`
- then call `ntfs_attrlist_update()`

This is a small local split in `attrlist.c`, not a broad phase split across all
runlist callers.

## Current `ctx->al_entry` use classification

### 1. Enumeration cursor

- file: `fs/ntfs/attrib.c`
- function: `ntfs_external_attr_find()`
- role:
  - starting point for the next attr-list scan
  - previous entry when synthesizing `$ATTRIBUTE_LIST` during enumeration

### 2. Insertion anchor

- file: `fs/ntfs/attrlist.c`
- function: `ntfs_attrlist_entry_add()`
- role:
  - exact insert-before position returned with `-ENOENT`
  - previous matching extent when inserting after a matching lowest_vcn range

### 3. Exact writer-side identity

- file: `fs/ntfs/attrlist.c`
- function: `ntfs_attrlist_entry_rm()`
- role:
  - exact ALE to remove

- file: `fs/ntfs/attrib.c`
- function: `ntfs_attr_record_move_to()`
- role:
  - exact ALE whose `mft_reference` and `instance` must be updated

- file: `fs/ntfs/attrib.c`
- function: `__ntfs_attr_update_mapping_pairs()`
- role:
  - exact ALE whose `lowest_vcn` must be updated

### 4. Presence / debug-only uses

- file: `fs/ntfs/inode.c`
- function: `ntfs_attr_position()`
- role:
  - checks whether the insert anchor points into a different extent mft record

- file: `fs/ntfs/index.c`
- function: resize failure path near index-root reparenting
- role:
  - boolean: attrlist path already exists

- file: `fs/ntfs/attrib.c`
- function: `ntfs_external_attr_find()`
- role:
  - corruption log metadata source

## Data structure design

### `struct ntfs_inode`

Add:

- `struct rw_semaphore attr_list_lock`
- `u32 attr_list_gen`

Rules:

- every attr-list buffer replacement increments `attr_list_gen`
- every in-place ALE update that changes lookup / ordering-visible metadata also
  increments `attr_list_gen`
- pure on-disk persistence of an unchanged in-memory attr-list does not bump it

### `struct ntfs_attr_search_ctx`

Remove:

- `struct attr_list_entry *al_entry`

Add locator state:

- `struct ntfs_attrlist_cursor al_cursor`
  - restartable enumeration state
  - fields:
    - `u32 off`
    - `u32 gen`
    - `bool valid`
- `struct ntfs_attrlist_anchor al_insert`
  - insert-before anchor returned with `-ENOENT`
  - fields:
    - `u32 off`
    - `u32 gen`
    - `bool valid`
    - `bool at_end`
- `struct ntfs_attrlist_exact al_exact`
  - exact ALE identity for writer-side updates/removal
  - fields:
    - `u32 off`
    - `u32 gen`
    - `bool valid`
    - exact key:
      - `type`
      - `name_len`
      - copied name buffer
      - `lowest_vcn`
      - `mft_reference`
      - `instance`
- `bool used_attrlist`
  - records whether lookup actually traversed attrlist

### Why `al_insert` stays smaller than `al_exact`

`al_insert` is only an insert-before anchor. To keep `search_ctx` smaller, it
stores offset/generation only. If generation mismatches, callers can rerun
lookup to recompute insertion position.

`al_exact` must survive writer-side relock/relookup and therefore needs a full
exact key.

## Locking model by operation type

### Read-side attrlist lookup

`ntfs_external_attr_find()`:

- `down_read(&base_ni->attr_list_lock)`
- resolve / refresh `al_cursor`
- scan attr-list entries
- fill `al_insert`, `al_exact`, `used_attrlist`
- `up_read(&base_ni->attr_list_lock)`
- continue with extent mft mapping / attr record lookup without holding
  `attr_list_lock`

This keeps the attr-list critical section short and prevents search-context
lifetime lock propagation.

### Write-side in-memory attrlist update

Writer paths that change in-memory ALE state:

- `ntfs_attrlist_entry_add()`
- `ntfs_attrlist_entry_rm()`
- `ntfs_attr_record_move_to()`
- `__ntfs_attr_update_mapping_pairs()`

Pattern:

- `down_write(&base_ni->attr_list_lock)`
- exact ALE relookup if needed
- in-memory splice/update
- `attr_list_gen++`
- refresh `al_exact` / `al_cursor` as needed
- `up_write(&base_ni->attr_list_lock)`

### Forbidden while holding `attr_list_lock`

The following must not be called while `attr_list_lock` is held:

- `ntfs_attrlist_update()`
- `ntfs_attr_make_non_resident()`
- `ntfs_resident_attr_resize()`
- `ntfs_attr_truncate_i()`
- cluster alloc/free helpers
- runlist mutation helpers

## Key replacement rules by use site

### Enumeration cursor

Replace raw pointer with:

- `al_cursor.off`
- `al_cursor.gen`

Code shape:

```c
if (!ctx->al_cursor.valid ||
    ctx->al_cursor.gen != base_ni->attr_list_gen ||
    ctx->al_cursor.off >= base_ni->attr_list_size) {
	ctx->al_cursor.off = 0;
	ctx->al_cursor.gen = base_ni->attr_list_gen;
	ctx->al_cursor.valid = true;
}
```

### Insertion anchor

Replace `ctx->al_entry` on `-ENOENT` with:

- `al_insert.off`
- `al_insert.gen`
- `al_insert.valid`
- `al_insert.at_end`

Code shape:

```c
ctx->al_insert.off = (u8 *)al_entry - al_start;
ctx->al_insert.gen = base_ni->attr_list_gen;
ctx->al_insert.valid = true;
ctx->al_insert.at_end = ((u8 *)al_entry == al_end);
```

### Exact writer-side identity

Replace mutable raw pointer with:

- fast path: `al_exact.off` + `al_exact.gen`
- correctness path: `al_exact.key`

Code shape:

```c
ale = ntfs_attrlist_find_exact_locked(base_ni, &ctx->al_exact,
		&al_start, &al_end);
if (!ale)
	return -EIO;
```

### Presence / debug

Replace:

- `ctx->al_entry != NULL` with `ctx->used_attrlist` or `ctx->al_insert.valid`
- corruption logs with `ctx->al_exact.key`

## Function-specific design

### `ntfs_external_attr_find()`

Responsibilities under the new design:

- restart enumeration using `al_cursor`
- capture insert-before anchor in `al_insert`
- capture exact ALE identity in `al_exact`
- set `used_attrlist`
- never leave a raw ALE pointer in `search_ctx`

### `ntfs_attr_position()`

Replace `ctx->al_entry->mft_reference` tests with metadata from
`al_insert`/`al_exact`.

### `ntfs_attrlist_entry_add()`

- under `attr_list_lock`, use `al_insert` or relookup to compute insertion
  offset
- splice new buffer in memory
- bump `attr_list_gen`
- unlock
- call `ntfs_attrlist_update()` outside the lock

### `ntfs_attrlist_entry_rm()`

- under `attr_list_lock`, relookup exact ALE using `al_exact`
- splice new buffer in memory
- bump `attr_list_gen`
- unlock
- call `ntfs_attrlist_update()` outside the lock

### `ntfs_attr_record_move_to()`

- under `attr_list_lock`, relookup exact ALE using `al_exact`
- update `mft_reference` and `instance`
- bump `attr_list_gen`
- refresh `al_exact`

### `__ntfs_attr_update_mapping_pairs()`

- under `attr_list_lock`, relookup exact ALE using `al_exact`
- update in-memory `lowest_vcn`
- bump `attr_list_gen`
- refresh `al_exact`
- any later `ntfs_attrlist_update()` stays outside `attr_list_lock`

### `index.c` presence tests

Replace `ctx->al_entry` boolean checks with `ctx->used_attrlist`.

## Why `ctx->al_entry` can be removed

It can be removed as a raw pointer because every current use falls into one of
these buckets:

- restartable position
- insert-before anchor
- exact ALE identity that can be re-looked up under write lock
- presence/debug metadata

It cannot be removed without replacement state because `ntfs_external_attr_find`
must preserve:

- enumeration resume position
- `-ENOENT` insert-before semantics

## Implementation plan

### Step 1. Document and lock rules

- final lock order
- forbidden calls while holding `attr_list_lock`
- generation rules

### Step 2. Plumbing

Files:

- `fs/ntfs/inode.h`
- `fs/ntfs/inode.c`
- `fs/ntfs/attrib.h`

Changes:

- add `attr_list_lock`
- add `attr_list_gen`
- add locator structs and helper prototypes
- initialize inode fields

### Step 3. Read-side lookup conversion

Files:

- `fs/ntfs/attrib.c`
- `fs/ntfs/inode.c`
- `fs/ntfs/index.c`

Changes:

- convert `ntfs_external_attr_find()`
- update `ntfs_attr_init_search_ctx()` / `ntfs_attr_reinit_search_ctx()`
- update `ntfs_attr_position()`
- replace boolean `ctx->al_entry` users

### Step 4. Writer-side attrlist mutation conversion

Files:

- `fs/ntfs/attrlist.c`

Changes:

- convert `ntfs_attrlist_entry_add()`
- convert `ntfs_attrlist_entry_rm()`
- ensure `ntfs_attrlist_update()` is lock-outside only

### Step 5. Exact ALE metadata update conversion

Files:

- `fs/ntfs/attrib.c`

Changes:

- exact ALE relookup helper
- convert `ntfs_attr_record_move_to()`
- convert `__ntfs_attr_update_mapping_pairs()`

### Step 6. Generation completeness pass

Files:

- `fs/ntfs/inode.c`
- `fs/ntfs/attrib.c`
- `fs/ntfs/attrlist.c`

Changes:

- buffer create/clear/rollback paths
- ordering-visible in-memory ALE updates
- remaining `ctx->al_entry` removal

### Step 7. Validation

- build
- lockdep-enabled kernel if available
- `generic/013`
- `generic/467`
- attrlist create/remove/move paths
- writeback / fallocate / compress paths

## Commit split

### Commit 1

`docs: add attr-list C design notes`

- design document only

### Commit 2

`ntfs: add attr-list lock and locator plumbing`

- `attr_list_lock`
- `attr_list_gen`
- locator structs
- helper skeletons
- inode initialization

### Commit 3

`ntfs: convert attr-list lookup to locator-based search ctx`

- `ntfs_external_attr_find()`
- `ntfs_attr_init_search_ctx()`
- `ntfs_attr_reinit_search_ctx()`
- `ntfs_attr_position()`
- index boolean cleanup

### Commit 4

`ntfs: split attrlist mutation from attrlist persist`

- `ntfs_attrlist_entry_add()`
- `ntfs_attrlist_entry_rm()`
- `ntfs_attrlist_update()` contract cleanup

### Commit 5

`ntfs: update exact ALE users to relookup by key`

- `ntfs_attr_record_move_to()`
- `__ntfs_attr_update_mapping_pairs()`
- exact ALE relookup helper

### Commit 6

`ntfs: finish attr-list generation updates and cleanup`

- generation completeness pass
- rollback / clear / init path fixes
- remaining comment cleanup

### Commit 7

`ntfs: validate attr-list locking changes`

- follow-up fixes found during build / tests
- optional if no follow-up is needed

## Open implementation cautions

- `al_exact.name` must be copied, not pointer-borrowed
- `attr_list_gen` should track ordering-visible in-memory state, not pure disk
  flushes
- `ntfs_attr_update_mapping_pairs()` still needs careful treatment because it
  mixes runlist-heavy logic with ALE metadata updates; the design only requires
  the ALE update part to use `attr_list_lock`
- lockdep-facing comments are useful because the design intentionally forbids
  `attr_list_lock -> runlist.lock`
