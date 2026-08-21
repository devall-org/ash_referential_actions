# AshOwnership

Ownership vocabulary for Ash: lifecycle `locks` that can never dangle, and
`refers` relationships that are not parents.

## The problem

`belongs_to` conflates three meanings:

* **Containment** — the record is owned by its parent and must go down with it.
  `Comment belongs_to Post`: archiving the post archives the comment.
* **Lifecycle lock** — the record locks a target that it does not own. A
  `Document` rendered from a shared `Template` does not own it, and retiring
  the template must never take the documents down — nor may the template
  vanish while documents still lock it. Other examples: immutable document
  snapshots, shared images or files, license/reference rows.
* **Denormalized reference key** — the column carries another resource's id for
  tenant filtering, policies, or indexes. The real parent is a different
  relationship, and the reference should not carry a reverse relationship
  back to every descendant table.

Reading a resource, you cannot tell these apart: all three are
`belongs_to`. That matters, because tooling that walks containment — cascade
archival above all — has to guess. AshOwnership gives each meaning its own
name.

A `locks` edge is an explicit lifecycle lock: the target cannot be dropped
while any live record holds the lock.

## Usage

```elixir
# The locking side
defmodule MyApp.Document do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    locks :template, MyApp.Template
  end
end

# The locked side
defmodule MyApp.Template do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    locked_by :documents, MyApp.Document
  end
end
```

`locks` compiles to a plain `belongs_to` and `locked_by` to a plain
`has_many`, each carrying a marker — same options, same defaults, and every
Ash feature (loading, forms, policies, migrations) works unchanged. Whether
the reference is required (`allow_nil?`) or exposed (`public?`) is orthogonal
to locking: a document may well require its template.

Since Ash defaults `public?` to `false`, shorthands mirroring `ash_req_opt`'s
`belongs_to` variants are provided:

| entity            | `allow_nil?`        | `public?` |
| ----------------- | ------------------- | --------- |
| `locks`         | belongs_to defaults             ||
| `req_locks`     | `false`             | `true`    |
| `req_priv_locks` | `false`             | `false`   |
| `opt_locks`     | `true`              | `true`    |
| `opt_priv_locks` | `true`              | `false`   |

### Reference keys

`refers` compiles to a `belongs_to` carrying an `:__refers__` marker. Use
it when the column only holds another resource's id — tenant filtering, policies,
indexes — and the record's real parent is a different relationship.

```elixir
defmodule MyApp.Comment do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    belongs_to :post, MyApp.Post          # the real parent
    refers :account, MyApp.Account        # denormalized tenant key
  end
end
```

The target needs no reverse relationship: a cascade reaches this record
through its real parent, and the foreign key still keeps the referenced row from
being deleted out from under it. Without `refers`, an account with fifty
descendant tables would need fifty `has_many` declarations that exist only to
satisfy a containment check — and each one would be a second cascade path to
rows the real parent already covers.

`refers` carries no archive guard: it is merely a denormalized reference.

## The invariant

> While live locking records exist, the locked record can neither be deleted nor
> archived.

Enforced per path:

* **Hard delete** — the protection itself comes from the database: any real
  foreign key already restricts deleting referenced rows, for `locks` and
  plain `belongs_to` alike. What AshOwnership adds is keeping it that way — a
  verifier rejects `on_delete: :delete/:nilify` on `locks` edges, so the
  guarantee cannot be silently traded away — and the runtime guard below also
  rejects destroys, covering data layers without foreign key constraints
  (e.g. `Ash.DataLayer.Ets`). Deleting an *unused* row succeeds.
* **Soft delete (archive)** (when the locked resource also has
  [ash_archival](https://hex.pm/packages/ash_archival)) — archival is an
  `archived_at` update, which no foreign key can see. AshOwnership injects a
  runtime guard (`AshOwnership.Changes.EnsureNotLocked`) into every destroy
  action of a resource with the AshOwnership extension: the destroy is rejected while live
  locking records exist. They are enumerated through `locked_by` (which is
  therefore required for every locks edge), querying with the
  relationship's `read_action` if declared, otherwise the locking resource's primary
  read — a verifier rejects a filtered primary read as the default, so
  neither read policies nor action-level filters can silently hide a live
  locking record. Archival's global filter still applies, so archived locking records do
  not block — archive the locking records first (or let a reference cascade do it,
  see the `archive_last` option of ash_cascade_archival) and the locked resource becomes
  archivable.
* **Locking a dead target** — the reverse direction is guarded too:
  `AshOwnership.Changes.EnsureTargetLive` is injected into every create and
  update action of a locking resource, rejecting writes that point a `locks` foreign
  key at an archived or missing target — whether the key arrives as direct
  input or through `manage_relationship`. Without it, a ghost reference
  could be created instead of left behind.

## Compile-time verifiers

All cross-module checks run on the locking side, so compile-time
dependencies flow one way (locking side → locked side):

* `locks` must target an `AshOwnership` resource.
* A plain `belongs_to` targeting a resource with the AshOwnership extension is rejected unless it
  is containment — that is, unless the locked resource declares the reverse
  `has_many`/`has_one` back. A locked resource may own children of its own; those
  go down with it and need no guard. Anything else is a non-owning reference
  and must be declared with `locks`.
* The `locks` reference must create a real foreign key with restrict
  semantics: `ignore?: true` is rejected, and `on_delete` must be omitted,
  `:restrict`, or `:nothing`.
* The locked resource must declare a `locked_by` matching every locks edge on
  **both** key attributes, so the destroy guard can enumerate every locking record
  — on any data layer, archival or not.
* A `locked_by` on the used resource that matches no `locks` edge is
  rejected, as is a plain `has_many` traversing a locks foreign key.
* The read actions the guards query through must be usable: a declared
  `read_action` (standard relationship option, on `locks` and
  `locked_by` alike) must exist, and where the default — the queried
  resource's primary read — is used, it must carry no action-level filters,
  preparations, or required arguments. A filtered primary read forces an
  explicit `read_action` choice instead of silently hiding live rows. When
  several `locked_by` cover one foreign key, the destroy guard ORs them, so
  at least one must be unfiltered: a union of filtered views is not a proof
  that no locking record is left.

Known limitations: a `locked_by` pointing at a module that locks nothing
at all is not detectable (the check runs when the locking resource compiles); the
guards fall back to plain application-level checks on data layers without
lock support (e.g. ETS), where a lock created concurrently with a destroy is
not serialized — elsewhere they take paired `FOR UPDATE`/`FOR SHARE` locks on
the locked resource's row; and custom global preparations
that filter default reads must pass guard queries through (check
`query.context[:ash_ownership_guard?]`) or they will hide live rows from the
guards.

## Installation

```elixir
def deps do
  [
    {:ash_ownership, "~> 0.1.0"}
  ]
end
```

## Relationship to ash_cascade_archival

The two libraries are independent and compose without knowing about each
other: cascade archival's verifier only constrains `belongs_to` edges whose
destination is archival with cascade in place, while a `locks` edge points
at a resource with the AshOwnership extension whose archival (if any) is guarded. Together they
split `belongs_to` cleanly into containment chains and non-owning locks.
