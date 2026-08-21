# AshReferentialActions

Explicit referential actions for Ash relationships.

## Why

`belongs_to`, `has_many`, and `has_one` describe cardinality but not lifecycle. A related record may be owned, may prevent deletion, may lose its foreign key, or may only be a query view. AshReferentialActions makes that choice mandatory and derives soft-archive and optional PostgreSQL behavior from it.

## DSL

Declare the same action on both sides of an attributable relationship:

```elixir
# Parent -> child ownership
req_cascade_belongs_to :invoice, Invoice
cascade_has_many :line_items, LineItem

# Shared target that cannot disappear while referenced
req_restrict_belongs_to :template, Template
restrict_has_many :documents, Document

# Weak reference cleared when the target disappears
opt_nilify_belongs_to :invoice, Invoice
nilify_has_many :bulk_entries, BulkEntry

# Query-only relationship with no lifecycle behavior
view_has_many :active_documents, Document, filter: expr(is_active)
```

Resources using the extension cannot declare plain attributable `belongs_to`, `has_many`, or `has_one`. Use one of `cascade_*`, `restrict_*`, `nilify_*`, or `view_*`.
Generated reverse relationships to resources outside the extension are exempt.

Required/optional and private/public variants are available for `belongs_to`:

- `req_cascade_belongs_to`, `req_priv_cascade_belongs_to`, `opt_cascade_belongs_to`, `opt_priv_cascade_belongs_to`
- the same variants for `restrict` and `view`
- `opt_nilify_belongs_to` and `opt_priv_nilify_belongs_to`; nilify can never be required

## Adapters

### Soft archive

```elixir
use Ash.Resource,
  extensions: [AshReferentialActions.Archival]
```

The archival adapter also installs `AshArchival.Resource` and:

- generates `archive_related` from `cascade_has_many` and `cascade_has_one`
- rejects an archive while a live `restrict_has_many/has_one` record exists
- generates a private nilify update action and clears live `nilify_has_many/has_one` foreign keys
- rejects new cascade/restrict/nilify references to archived targets
- validates cascade destinations and ordering

When cascade order must be pinned:

```elixir
referential_actions do
  archive_last [:templates]
end
```

### PostgreSQL physical delete

```elixir
use Ash.Resource,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshReferentialActions.Postgres]
```

The PostgreSQL adapter generates migration reference behavior:

- cascade -> `on_delete: :delete`
- restrict -> `on_delete: :restrict`
- nilify -> `on_delete: :nilify`

Do not enable this adapter merely because an application uses PostgreSQL. Applications that only soft-archive records should normally use the archival adapter alone and retain restrictive database foreign keys as a safety net.

The adapters can be combined when both soft archive and physical delete must share the same semantics.

## Generated nilify action

For:

```elixir
opt_nilify_belongs_to :invoice, Invoice
```

AshReferentialActions generates a private update action named from the source attribute, for example:

```elixir
:__ash_referential_actions_nilify_invoice_id__
```

The action accepts no input and only sets `invoice_id` to nil. The target's archival change invokes it through the matching reverse relationship with Ash's `cascade_update` change.

## Guarantees

Compile-time verification rejects:

- unmarked attributable relationships
- missing or mismatched forward/reverse actions
- nilify relationships whose foreign key is non-nullable
- filtered or manual lifecycle reverse relationships
- lifecycle targets that do not use AshReferentialActions
- invalid cascade destinations or cascade order
- PostgreSQL reference behavior that conflicts with the declared action
