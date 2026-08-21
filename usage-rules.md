# Rules for AshReferentialActions

## Choose an explicit action

On every resource using AshReferentialActions, attributable `belongs_to`, `has_many`, and `has_one` relationships must use one of these prefixes:

- `cascade_*`: the related record is owned and follows the target's destroy/archive.
- `restrict_*`: the target cannot be destroyed or archived while live referrers exist.
- `nilify_*`: destroying or archiving the target clears the source foreign key.
- `view_*`: lifecycle-neutral relationship used only for loading/querying.

Never use plain `belongs_to`, `has_many`, or `has_one` on an enabled resource. The verifier rejects them.
Generated reverse relationships whose destination does not use AshReferentialActions
(for example audit/version resources owned by another extension) are exempt because
their lifecycle is outside this graph.

Declare the same action on both sides and align both key attributes:

```elixir
nilify_belongs_to :invoice, Invoice, allow_nil?: true
nilify_has_many :bulk_entries, BulkEntry, destination_attribute: :invoice_id
```

Lifecycle reverse relationships (`cascade/restrict/nilify has_many/has_one`) must be unfiltered, attributable, and manual-free. Add separate `view_has_many/view_has_one` relationships for filtered business views.

## Belongs-to options

Do not create req/opt/private macro variants. Use the normal Ash options on the
four action macros:

```elixir
cascade_belongs_to :required_parent, Parent, allow_nil?: false
restrict_belongs_to :optional_target, Target, allow_nil?: true
view_belongs_to :private_pointer, File, allow_nil?: true, public?: false
```

`nilify_belongs_to` always uses `allow_nil?: true`; the verifier rejects a
non-nullable nilify foreign key.

## Choose adapters by actual delete behavior

For soft archive behavior, use:

```elixir
extensions: [AshReferentialActions.Archival]
```

This adapter installs AshArchival, generates `archive_related`, runs restrict guards, and invokes generated nilify actions.

For PostgreSQL physical-delete FK behavior, opt in separately:

```elixir
extensions: [AshReferentialActions.Postgres]
```

Do not enable the PostgreSQL adapter only because PostgreSQL is the data layer. If the application never physically deletes rows, keep database FKs restrictive and use only the archival adapter. This avoids unnecessary FK migrations and preserves the database as a hard-delete safety net.

Use both adapters only when the application intentionally supports both soft archive and physical delete with matching semantics.

## Nilify actions

Do not create routine nilify actions manually. The archival adapter generates a private update action per source foreign-key attribute. It accepts no input and only sets that attribute to nil.

A target destroy invokes the generated action through the canonical `nilify_has_many/has_one` relationship. Keep that reverse relationship unfiltered; use additional `view_*` relationships for filtered lists.

## Cascade configuration

Do not set AshArchival `archive_related` directly. It is generated only from `cascade_has_many` and `cascade_has_one`.

If restrict edges require a specific sequential cascade order, declare only the exceptional tail:

```elixir
referential_actions do
  archive_last [:locked_resource]
end
```

The cascade-order verifier reports the required ordering when it is wrong.

## many_to_many

`many_to_many` is a query relationship and is not assigned a referential action directly. Declare lifecycle actions on the join resource's two `belongs_to` relationships and on the corresponding canonical reverse relationships. Use `view_has_many` or `many_to_many` for query views.
