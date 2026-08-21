# Rules for working with AshOwnership

## Purpose

AshOwnership names what a `belongs_to` means: containment (plain
`belongs_to`), a non-owning reference (`locks`), or a denormalized refers id
(`refers`). A `locks`
relationship is a `belongs_to` that does not own its target: the target is
not the record's parent, may be shared by many users, and can neither be
hard-deleted nor archived while live users exist.

## Vocabulary

```elixir
# The using side
defmodule Document do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    locks :template, Template
  end
end

# The used side
defmodule Template do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    locked_by :documents, Document
  end
end
```

* `refers` compiles to `belongs_to` with a `:__refers__` marker. Use it
  when the column only carries another resource's id (tenant filtering, policies,
  indexes) and the record's real parent is another relationship. The target
  needs no reverse relationship, and cascades reach the record through its
  real parent.

* `locks` compiles to `belongs_to` with a `:__locks__` marker — same
  options and defaults as `belongs_to`; required/optional (`allow_nil?`) and
  exposure (`public?`) stay fully configurable. Shorthands set both:
  `req_locks` (`false`/`true`), `req_priv_locks` (`false`/`false`),
  `opt_locks` (`true`/`true`), `opt_priv_locks` (`true`/`false`) —
  mirroring `ash_req_opt`'s `belongs_to` variants.
* `locked_by` compiles to `has_many` with a `:__locked_by__` marker.
  It supports no `filter` — the archive guard must see every user.
* `AshOwnership.Info.locks?/1`, `locked_by?/1`, and `enabled?/1` expose
  the markers.

## When to use `locks` vs `belongs_to`

* Use `locks` when the target is data the record merely locks: shared
  templates, document snapshots, shared files, immutable content rows.
  Deleting or archiving the
  record must not touch the target, and vice versa.
* Use `belongs_to` for containment: the parent owns the record and cascade
  archival takes the record down with the parent. This holds even when the
  parent is itself used resource — a used resource may own children.
* The verifier enforces this split: a `belongs_to` targeting a used resource
  resource is a compile error unless that used resource declares the reverse
  `has_many`/`has_one` back, which is how containment is declared.

## Rules enforced at compile time

* `locks` destinations must use `AshOwnership`.
* A plain `belongs_to` to a used resource is allowed only as containment: the
  used resource must declare a plain (non-`locked_by`) `has_many`/`has_one`
  back, matching both key attributes.
* The ash_postgres reference for a `locks` relationship must create a real
  foreign key with restrict semantics: never `ignore?: true`, and omit
  `on_delete` or use `:restrict`/`:nothing`. Never `:delete`/`:nilify`.
* Every `locks` edge must have a matching `locked_by` on the used resource,
  matched on both key attributes — the destroy guard enumerates users
  through it, on any data layer, archival or not.
* The reverse side of a locks edge must be `locked_by`, not a plain
  `has_many`.

## Runtime guards

Two changes are injected automatically:

* `AshOwnership.Changes.EnsureNotLocked` on every destroy action of a
  used resource: rejects the destroy while live users exist.
* `AshOwnership.Changes.EnsureTargetLive` on every create and update action of
  a user: rejects writing a locks foreign key that points at an
  archived or missing target. It checks both in `before_action` (direct
  attribute input) and in `after_action` on the result record, so
  `manage_relationship` paths are covered too. On non-transactional data
  layers (e.g. ETS) the after-action error is returned but the write is not
  rolled back.

A resource may export `locked_message/1` to replace the guard's rejection
message for a given `locked_by` relationship (return nil to keep the default).
Ash stops at the first error and this guard usually runs before a resource's
own checks, so this is how an application keeps its own wording.

Notes:

* Both guards query through the relationship's `read_action` if declared
  (the standard Ash relationship option, on `locks` and `locked_by`
  alike), otherwise through the queried resource's primary read. A verifier
  rejects a filtered primary read as the default — declare a `read_action`
  pointing at an action suitable for existence checks instead. Several
  `locked_by` may cover one foreign key (filtered views of the users);
  the guard ORs them, and a verifier requires at least one of them to be
  unfiltered so the union cannot miss a live user. Policies
  never apply to guard queries (`authorize?: false`). Archival's global
  `is_nil(archived_at)` preparation still applies: archived rows count as
  gone. Archive users first, then the used resource.
* Custom **global preparations** do apply to guard queries. If yours
  filters rows out of default reads, pass the query through unchanged when
  `query.context[:ash_ownership_guard?]` is set — otherwise it will hide live
  rows from the guards.
* Inside one transaction, locking records archived earlier are already invisible —
  a reference cascade passes deterministically if it orders locking records before
  the locked resource (`archive_last` option of ash_cascade_archival).
* The destroy guard is not atomic-compatible: bulk destroys of used resources
  need `strategy: [:stream]` (Ash's default bulk strategy is `:atomic`);
  ash_archival's cascade already passes a stream-capable strategy. Using-side
  bulk updates stay atomic only when they neither touch a `locks` foreign
  key nor run any other change (another change could set the key atomically
  behind the guard's back, so its presence forces the non-atomic path).
* The guards serialize against each other on the used resource's row where the
  data layer supports locking: the destroy guard takes `FOR UPDATE` on it and
  the target-live guard takes `FOR SHARE`, so a use created concurrently
  with a destroy cannot slip through. Without lock support (e.g. ETS) both are
  plain application-level checks and the race remains.
* Because the destroy guard runs on every destroy (not only archives), the
  use invariant also holds on data layers without foreign key
  constraints, such as `Ash.DataLayer.Ets`.

## Enforcement

Spark surfaces verifier errors as compiler warnings — the module still
compiles. Run CI with `mix compile --warnings-as-errors` to make this
library's compile-time checks enforcing.

## Limitations

* A `locked_by` pointing at a module with no `locks` at all is not
  detected (cross-module checks run when the user compiles).
* Enforcement of "must use `locks`" only runs on resources that have the
  `AshOwnership` extension — add it to your base resource module.
