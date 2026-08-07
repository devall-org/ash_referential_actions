# AshOwnership

Ownership vocabulary for Ash: `uses` references that can never dangle, and
`ancestor` keys that are not parents.

## The problem

`belongs_to` conflates three meanings:

* **Containment** — the record is owned by its parent and must go down with it.
  `Comment belongs_to Post`: archiving the post archives the comment.
* **Non-owning reference** — the record merely *uses* the target. A
  `Document` rendered from a shared `Template` does not own it, and retiring
  the template must never take the documents down — nor may the template
  vanish while documents still use it. Other examples: immutable document
  snapshots, shared images or files, license/reference rows.
* **Denormalized ancestor key** — the column carries a grandparent's id for
  tenant filtering, policies, or indexes. The real parent is a different
  relationship, and the ancestor should not carry a reverse relationship
  back to every descendant table.

Reading a resource, you cannot tell these apart: all three are
`belongs_to`. That matters, because tooling that walks containment — cascade
archival above all — has to guess. AshOwnership gives each meaning its own
name.

The `uses` vocabulary is borrowed from Rust: a `uses` edge is a borrow of the
target, and the target cannot be dropped while any borrow is alive.

| Rust | AshOwnership |
| --- | --- |
| ownership, drop cascades | containment `belongs_to` (see [ash_cascade_archival](https://hex.pm/packages/ash_cascade_archival)) |
| borrow (`&T`) | `uses` relationship |
| cannot drop while borrowed | FK restrict + archive guard |
| shared borrows | many records may use one target |

## Usage

```elixir
# The using side
defmodule MyApp.Document do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    uses :template, MyApp.Template
  end
end

# The used side
defmodule MyApp.Template do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    used_by :documents, MyApp.Document
  end
end
```

`uses` compiles to a plain `belongs_to` and `used_by` to a plain
`has_many`, each carrying a marker — same options, same defaults, and every
Ash feature (loading, forms, policies, migrations) works unchanged. Whether
the reference is required (`allow_nil?`) or exposed (`public?`) is orthogonal
to use: a document may well require its template.

Since Ash defaults `public?` to `false`, shorthands mirroring `ash_req_opt`'s
`belongs_to` variants are provided:

| entity            | `allow_nil?`        | `public?` |
| ----------------- | ------------------- | --------- |
| `uses`         | belongs_to defaults             ||
| `req_uses`     | `false`             | `true`    |
| `req_priv_uses` | `false`             | `false`   |
| `opt_uses`     | `true`              | `true`    |
| `opt_priv_uses` | `true`              | `false`   |

### Ancestor keys

`ancestor` compiles to a `belongs_to` carrying an `:__ancestor__` marker. Use
it when the column only holds an ancestor's id — tenant filtering, policies,
indexes — and the record's real parent is a different relationship.

```elixir
defmodule MyApp.Comment do
  use Ash.Resource, extensions: [AshOwnership]

  relationships do
    belongs_to :post, MyApp.Post          # the real parent
    ancestor :account, MyApp.Account      # denormalized tenant key
  end
end
```

The target needs no reverse relationship: a cascade reaches this record
through its real parent, and the foreign key still keeps the ancestor from
being deleted out from under it. Without `ancestor`, an account with fifty
descendant tables would need fifty `has_many` declarations that exist only to
satisfy a containment check — and each one would be a second cascade path to
rows the real parent already covers.

`ancestor` carries no archive guard: an ancestor is not borrowed, it is
merely denormalized.

## The invariant

> While live users exist, the used record can neither be deleted nor
> archived.

Enforced per path:

* **Hard delete** — the protection itself comes from the database: any real
  foreign key already restricts deleting referenced rows, for `uses` and
  plain `belongs_to` alike. What AshOwnership adds is keeping it that way — a
  verifier rejects `on_delete: :delete/:nilify` on `uses` edges, so the
  guarantee cannot be silently traded away — and the runtime guard below also
  rejects destroys, covering data layers without foreign key constraints
  (e.g. `Ash.DataLayer.Ets`). Deleting an *unused* row succeeds.
* **Soft delete (archive)** (when the used resource also uses
  [ash_archival](https://hex.pm/packages/ash_archival)) — archival is an
  `archived_at` update, which no foreign key can see. AshOwnership injects a
  runtime guard (`AshOwnership.Changes.EnsureNotUsed`) into every destroy
  action of a resource with the AshOwnership extension: the destroy is rejected while live
  users exist. Users are enumerated through `used_by` (which is
  therefore required for every uses edge), querying with the
  relationship's `read_action` if declared, otherwise the user's primary
  read — a verifier rejects a filtered primary read as the default, so
  neither read policies nor action-level filters can silently hide a live
  user. Archival's global filter still applies, so archived users do
  not block — archive the users first (or let an ancestor cascade do it,
  see the `archive_last` option of ash_cascade_archival) and the used resource becomes
  archivable.
* **Using a dead target** — the reverse direction is guarded too:
  `AshOwnership.Changes.EnsureTargetLive` is injected into every create and
  update action of a using resource, rejecting writes that point a `uses` foreign
  key at an archived or missing target — whether the key arrives as direct
  input or through `manage_relationship`. Without it, a ghost reference
  could be created instead of left behind.

## Compile-time verifiers

All cross-module checks run on the user side, so compile-time
dependencies flow one way (using side → used side):

* `uses` must target an `AshOwnership` resource.
* A plain `belongs_to` targeting a resource with the AshOwnership extension is rejected unless it
  is containment — that is, unless the used resource declares the reverse
  `has_many`/`has_one` back. A used resource may own children of its own; those
  go down with it and need no guard. Anything else is a non-owning reference
  and must be declared with `uses`.
* The `uses` reference must create a real foreign key with restrict
  semantics: `ignore?: true` is rejected, and `on_delete` must be omitted,
  `:restrict`, or `:nothing`.
* The used resource must declare a `used_by` matching every uses edge on
  **both** key attributes, so the destroy guard can enumerate every user
  — on any data layer, archival or not.
* A `used_by` on the used resource that matches no `uses` edge is
  rejected, as is a plain `has_many` traversing a uses foreign key.
* The read actions the guards query through must be usable: a declared
  `read_action` (standard relationship option, on `uses` and
  `used_by` alike) must exist, and where the default — the queried
  resource's primary read — is used, it must carry no action-level filters,
  preparations, or required arguments. A filtered primary read forces an
  explicit `read_action` choice instead of silently hiding live rows. When
  several `used_by` cover one foreign key, the destroy guard ORs them, so
  at least one must be unfiltered: a union of filtered views is not a proof
  that no user is left.

Known limitations: a `used_by` pointing at a module that uses nothing
at all is not detectable (the check runs when the user compiles); the
guards fall back to plain application-level checks on data layers without
lock support (e.g. ETS), where a use created concurrently with a destroy is
not serialized — elsewhere they take paired `FOR UPDATE`/`FOR SHARE` locks on
the used resource's row; and custom global preparations
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
destination is archival with cascade in place, while a `uses` edge points
at a resource with the AshOwnership extension whose archival (if any) is guarded. Together they
split `belongs_to` cleanly into containment chains and non-owning uses.
