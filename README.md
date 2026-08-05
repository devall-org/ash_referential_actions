# AshBorrow

Borrow semantics for Ash: non-owning `borrows` references that can never dangle.

## The problem

`belongs_to` conflates two meanings:

* **Containment** — the record is owned by its parent and must go down with it.
  `Comment belongs_to Post`: archiving the post archives the comment.
* **Non-owning reference** — the record merely *uses* the target. A
  `Document` rendered from a shared `Template` does not own it, and retiring
  the template must never take the documents down — nor may the template
  vanish while documents still use it. Other examples: immutable document
  snapshots, shared images or files, license/reference rows.

AshBorrow gives the second meaning its own vocabulary, borrowed from Rust:
a **borrow** is a non-owning reference, and the borrowed value cannot be
dropped while borrows are alive.

| Rust | AshBorrow |
| --- | --- |
| ownership, drop cascades | containment `belongs_to` (see [ash_cascade_archival](https://hex.pm/packages/ash_cascade_archival)) |
| borrow (`&T`) | `borrows` relationship |
| cannot drop while borrowed | FK restrict + archive guard |
| shared borrows | many records may borrow one target |

## Usage

```elixir
# The borrowing side
defmodule MyApp.Document do
  use Ash.Resource, extensions: [AshBorrow.Borrower]

  relationships do
    borrows :template, MyApp.Template
  end
end

# The borrowed side
defmodule MyApp.Template do
  use Ash.Resource, extensions: [AshBorrow.Borrowable]

  relationships do
    borrowed_by :documents, MyApp.Document
  end
end
```

`borrows` compiles to a plain `belongs_to` and `borrowed_by` to a plain
`has_many`, each carrying a marker — same options, same defaults, and every
Ash feature (loading, forms, policies, migrations) works unchanged. Whether
the reference is required (`allow_nil?`) or exposed (`public?`) is orthogonal
to borrowing: a document may well require its template.

Since Ash defaults `public?` to `false`, shorthands mirroring `ash_req_opt`'s
`belongs_to` variants are provided:

| entity            | `allow_nil?`        | `public?` |
| ----------------- | ------------------- | --------- |
| `borrows`         | belongs_to defaults             ||
| `req_borrows`     | `false`             | `true`    |
| `req_prv_borrows` | `false`             | `false`   |
| `opt_borrows`     | `true`              | `true`    |
| `opt_prv_borrows` | `true`              | `false`   |

## The invariant

> While live borrowers exist, the borrowed record can neither be deleted nor
> archived.

Enforced per path:

* **Hard delete** — the protection itself comes from the database: any real
  foreign key already restricts deleting referenced rows, for `borrows` and
  plain `belongs_to` alike. What AshBorrow adds is keeping it that way — a
  verifier rejects `on_delete: :delete/:nilify` on borrows references, so the
  guarantee cannot be silently traded away — and the runtime guard below also
  rejects destroys, covering data layers without foreign key constraints
  (e.g. `Ash.DataLayer.Ets`). Deleting an *unborrowed* row succeeds.
* **Soft delete (archive)** (when the borrowable also uses
  [ash_archival](https://hex.pm/packages/ash_archival)) — archival is an
  `archived_at` update, which no foreign key can see. AshBorrow injects a
  runtime guard (`AshBorrow.Changes.EnsureNotBorrowed`) into every destroy
  action of a borrowable resource: the destroy is rejected while live
  borrowers exist. Borrowers are enumerated through `borrowed_by` (which is
  therefore required for every borrows edge), querying with the
  relationship's `read_action` if declared, otherwise the borrower's primary
  read — a verifier rejects a filtered primary read as the default, so
  neither read policies nor action-level filters can silently hide a live
  borrower. Archival's global filter still applies, so archived borrowers do
  not block — archive the borrowers first (or let an ancestor cascade do it,
  see the `order` option of ash_cascade_archival) and the borrowable becomes
  archivable.
* **Borrowing a dead target** — the reverse direction is guarded too:
  `AshBorrow.Changes.EnsureTargetLive` is injected into every create and
  update action of a borrower, rejecting writes that point a borrows foreign
  key at an archived or missing target — whether the key arrives as direct
  input or through `manage_relationship`. Without it, a ghost reference
  could be created instead of left behind.

## Compile-time verifiers

All cross-module checks run on the borrower side, so compile-time
dependencies flow one way (borrower → borrowable):

* `borrows` must target an `AshBorrow.Borrowable` resource.
* A plain `belongs_to` targeting a borrowable resource is rejected — use
  `borrows`.
* The `borrows` reference must create a real foreign key with restrict
  semantics: `ignore?: true` is rejected, and `on_delete` must be omitted,
  `:restrict`, or `:nothing`.
* The borrowable must declare a `borrowed_by` matching every borrows edge on
  **both** key attributes, so the destroy guard can enumerate every borrower
  — on any data layer, archival or not.
* A `borrowed_by` on the borrowable that matches no `borrows` edge is
  rejected, as is a plain `has_many` traversing a borrows foreign key.
* The read actions the guards query through must be usable: a declared
  `read_action` (standard relationship option, on `borrows` and
  `borrowed_by` alike) must exist, and where the default — the queried
  resource's primary read — is used, it must carry no action-level filters,
  preparations, or required arguments. A filtered primary read forces an
  explicit `read_action` choice instead of silently hiding live rows.

Known limitations: a `borrowed_by` pointing at a module that borrows nothing
at all is not detectable (the check runs when the borrower compiles); the
guards are application-level checks — a borrow created concurrently with a
destroy is not serialized by the database; and custom global preparations
that filter default reads must pass guard queries through (check
`query.context[:ash_borrow_guard?]`) or they will hide live rows from the
guards.

## Installation

```elixir
def deps do
  [
    {:ash_borrow, "~> 0.1.0"}
  ]
end
```

## Relationship to ash_cascade_archival

The two libraries are independent and compose without knowing about each
other: cascade archival's verifier only constrains `belongs_to` edges whose
destination is archival with cascade in place, while a `borrows` edge points
at a borrowable resource whose archival (if any) is guarded. Together they
split `belongs_to` cleanly into containment chains and borrows.
