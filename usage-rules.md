# Rules for working with AshBorrow

## Purpose

AshBorrow distinguishes non-owning references from containment. A `borrows`
relationship is a `belongs_to` that does not own its target: the target is
not the record's parent, may be shared by many borrowers, and can neither be
hard-deleted nor archived while live borrowers exist.

## Vocabulary

```elixir
# Borrowing side
defmodule Document do
  use Ash.Resource, extensions: [AshBorrow.Borrower]

  relationships do
    borrows :template, Template
  end
end

# Borrowed side
defmodule Template do
  use Ash.Resource, extensions: [AshBorrow.Borrowable]

  relationships do
    borrowed_by :documents, Document
  end
end
```

* `borrows` compiles to `belongs_to` with a `:__borrows__` marker — same
  options and defaults as `belongs_to`; required/optional (`allow_nil?`) and
  exposure (`public?`) stay fully configurable. Shorthands set both:
  `req_borrows` (`false`/`true`), `req_priv_borrows` (`false`/`false`),
  `opt_borrows` (`true`/`true`), `opt_priv_borrows` (`true`/`false`) —
  mirroring `ash_req_opt`'s `belongs_to` variants.
* `borrowed_by` compiles to `has_many` with a `:__borrowed_by__` marker.
  It supports no `filter` — the archive guard must see every borrower.
* `AshBorrow.Info.borrows?/1`, `borrowed_by?/1`, and `borrowable?/1` expose
  the markers.

## When to use borrows vs belongs_to

* Use `borrows` when the target is data the record merely uses: shared
  templates, document snapshots, shared files, immutable content rows.
  Deleting or archiving the
  record must not touch the target, and vice versa.
* Use `belongs_to` for containment: the parent owns the record and cascade
  archival takes the record down with the parent. This holds even when the
  parent is itself borrowable — a borrowable may own children.
* The verifier enforces this split: a `belongs_to` targeting a borrowable
  resource is a compile error unless that borrowable declares the reverse
  `has_many`/`has_one` back, which is how containment is declared.

## Rules enforced at compile time

* `borrows` destinations must use `AshBorrow.Borrowable`.
* A plain `belongs_to` to a borrowable is allowed only as containment: the
  borrowable must declare a plain (non-`borrowed_by`) `has_many`/`has_one`
  back, matching both key attributes.
* The ash_postgres reference for a `borrows` relationship must create a real
  foreign key with restrict semantics: never `ignore?: true`, and omit
  `on_delete` or use `:restrict`/`:nothing`. Never `:delete`/`:nilify`.
* Every `borrows` edge must have a matching `borrowed_by` on the borrowable,
  matched on both key attributes — the destroy guard enumerates borrowers
  through it, on any data layer, archival or not.
* The reverse side of a borrows edge must be `borrowed_by`, not a plain
  `has_many`.

## Runtime guards

Two changes are injected automatically:

* `AshBorrow.Changes.EnsureNotBorrowed` on every destroy action of a
  borrowable: rejects the destroy while live borrowers exist.
* `AshBorrow.Changes.EnsureTargetLive` on every create and update action of
  a borrower: rejects writing a borrows foreign key that points at an
  archived or missing target. It checks both in `before_action` (direct
  attribute input) and in `after_action` on the result record, so
  `manage_relationship` paths are covered too. On non-transactional data
  layers (e.g. ETS) the after-action error is returned but the write is not
  rolled back.

Notes:

* Both guards query through the relationship's `read_action` if declared
  (the standard Ash relationship option, on `borrows` and `borrowed_by`
  alike), otherwise through the queried resource's primary read. A verifier
  rejects a filtered primary read as the default — declare a `read_action`
  pointing at an action suitable for existence checks instead. Policies
  never apply to guard queries (`authorize?: false`). Archival's global
  `is_nil(archived_at)` preparation still applies: archived rows count as
  gone. Archive borrowers first, then the borrowable.
* Custom **global preparations** do apply to guard queries. If yours
  filters rows out of default reads, pass the query through unchanged when
  `query.context[:ash_borrow_guard?]` is set — otherwise it will hide live
  rows from the guards.
* Inside one transaction, borrowers archived earlier are already invisible —
  an ancestor cascade passes deterministically if it orders borrowers before
  the borrowable (`order` option of ash_cascade_archival).
* The destroy guard is not atomic-compatible: bulk destroys of borrowables
  need `strategy: [:stream]` (Ash's default bulk strategy is `:atomic`);
  ash_archival's cascade already passes a stream-capable strategy. Borrower
  bulk updates stay atomic only when they neither touch a borrows foreign
  key nor run any other change (another change could set the key atomically
  behind the guard's back, so its presence forces the non-atomic path).
* The guards are application-level: they do not serialize against concurrent
  writes the way the FK serializes deletes.
* Because the destroy guard runs on every destroy (not only archives), the
  borrow invariant also holds on data layers without foreign key
  constraints, such as `Ash.DataLayer.Ets`.

## Enforcement

Spark surfaces verifier errors as compiler warnings — the module still
compiles. Run CI with `mix compile --warnings-as-errors` to make this
library's compile-time checks enforcing.

## Limitations

* A `borrowed_by` pointing at a module with no `borrows` at all is not
  detected (cross-module checks run when the borrower compiles).
* Enforcement of "must use borrows" only runs on resources that use the
  `AshBorrow.Borrower` extension — add it to your base resource module.
