defmodule AshOwnership do
  @moduledoc """
  Makes ownership explicit: which `belongs_to` owns a record, and which only
  points at something else.

  A `belongs_to` relationship conflates three meanings:

  * **Containment** — the record is owned by its parent and must go down with
    it. This is the only one Ash names, and every record has exactly one owner
    (a join row has one per endpoint).
  * **Non-owning use** — the record merely *uses* the target; the target must
    not vanish while the reference is alive. Declared with `uses`.
  * **Ancestor key** — a denormalized id of some ancestor, kept for tenant
    filtering, policies and indexes. The real parent is another relationship.
    Declared with `ancestor`.

  Leaving all three as plain `belongs_to` makes an owner indistinguishable
  from a pointer, so nothing can tell what a teardown should reach. Naming the
  two non-owning kinds leaves `belongs_to` meaning ownership and nothing else.

  `uses` is modelled on
  Rust's borrow checker: a use is a borrow of the target, and the target
  cannot be dropped while any borrow is alive.

  ## Vocabulary

      defmodule MyApp.Document do
        use Ash.Resource, extensions: [AshOwnership]

        relationships do
          uses :template, MyApp.Template
        end
      end

      defmodule MyApp.Template do
        use Ash.Resource, extensions: [AshOwnership]

        relationships do
          used_by :documents, MyApp.Document
        end
      end

      defmodule MyApp.LineItem do
        use Ash.Resource, extensions: [AshOwnership]

        relationships do
          belongs_to :document, MyApp.Document   # owner
          uses :product, MyApp.Product           # non-owning reference
          ancestor :org, MyApp.Org               # denormalized ancestor id
        end
      end

  `uses` compiles to a `belongs_to` carrying a `:__uses__` marker, `used_by`
  to a `has_many` carrying a `:__used_by__` marker, and `ancestor` to a
  `belongs_to` carrying a `:__ancestor__` marker — same options,
  same defaults, so every Ash feature (loading, forms, policies, migrations)
  works unchanged while verifiers and other extensions can tell non-owning
  references apart from containment.

  A resource may declare outgoing `uses`, incoming `used_by`, or both. The
  transformers and verifiers for a direction that is not declared are no-ops.

  Whether the reference is required (`allow_nil?`) or exposed (`public?`) is
  orthogonal to use, so `uses` leaves both fully configurable. Ash defaults
  `public?` to `false`, so shorthands mirroring `ash_req_opt`'s `belongs_to`
  variants are provided:

  | entity          | `allow_nil?` | `public?` |
  | --------------- | ------------ | --------- |
  | `uses`          | belongs_to defaults      ||
  | `req_uses`      | `false`      | `true`    |
  | `req_priv_uses` | `false`      | `false`   |
  | `opt_uses`      | `true`       | `true`    |
  | `opt_priv_uses` | `true`       | `false`   |

  ## The invariant

  > While live users exist, the used record can neither be deleted nor
  > archived.

  Hard deletes are restricted by the foreign key (a verifier keeps
  `on_delete` from trading that away), and archives — which no foreign key
  can see — are rejected by `AshOwnership.Changes.EnsureNotUsed`. The reverse
  direction is guarded by `AshOwnership.Changes.EnsureTargetLive`, which rejects
  pointing a `uses` foreign key at an archived or missing target.
  """

  @uses_variants [
    {:uses, nil, nil},
    {:req_uses, false, true},
    {:req_priv_uses, false, false},
    {:opt_uses, true, true},
    {:opt_priv_uses, true, false}
  ]

  @uses_entities Enum.map(@uses_variants, fn {name, allow_nil?, public?} ->
                   fixed =
                     [allow_nil?: allow_nil?, public?: public?]
                     |> Enum.reject(fn {_key, value} -> is_nil(value) end)

                   describe =
                     case fixed do
                       [] ->
                         "identical options and defaults"

                       fixed ->
                         Enum.map_join(fixed, " and ", fn {key, value} ->
                           "`#{key}: #{value}`"
                         end)
                     end

                   %Spark.Dsl.Entity{
                     name: name,
                     describe: """
                     Declares a non-owning use of another resource.

                     Compiles to a `belongs_to` with #{describe}.
                     The destination must use the `AshOwnership` extension.
                     """,
                     examples: [
                       """
                       #{name} :template, Template
                       """
                     ],
                     no_depend_modules: [:destination],
                     target: Ash.Resource.Relationships.BelongsTo,
                     schema:
                       Ash.Resource.Relationships.BelongsTo.opt_schema()
                       |> Keyword.drop(Keyword.keys(fixed)),
                     transform: {__MODULE__, :transform_uses, []},
                     args: [:name, :destination],
                     auto_set_fields: fixed
                   }
                 end)

  @used_by %Spark.Dsl.Entity{
    name: :used_by,
    describe: """
    Declares the reverse side of a `uses` edge: the resources that use this
    resource.

    Compiles to a `has_many`. The destination must have a matching `uses`
    relationship pointing back at this resource.

    It supports no `filter` entity: the destroy guard relies on it to
    enumerate every user, which a filtered relationship could not guarantee.
    """,
    examples: [
      """
      used_by :documents, Document
      """
    ],
    no_depend_modules: [:destination],
    target: Ash.Resource.Relationships.HasMany,
    schema: Ash.Resource.Relationships.HasMany.opt_schema(),
    transform: {__MODULE__, :transform_used_by, []},
    args: [:name, :destination]
  }

  @ancestor %Spark.Dsl.Entity{
    name: :ancestor,
    describe: """
    Declares a denormalized ancestor key.

    Compiles to a `belongs_to`. The record's real parent is some other
    relationship; this one only carries an ancestor's id for tenant filtering,
    policy checks and indexes.

    The target needs no reverse relationship: cascades reach this record
    through its real parent, and the foreign key still keeps the ancestor from
    being deleted out from under it.
    """,
    examples: [
      """
      ancestor :org, Org
      """
    ],
    no_depend_modules: [:destination],
    target: Ash.Resource.Relationships.BelongsTo,
    schema: Ash.Resource.Relationships.BelongsTo.opt_schema(),
    transform: {__MODULE__, :transform_ancestor, []},
    args: [:name, :destination]
  }

  use Spark.Dsl.Extension,
    dsl_patches:
      Enum.map(
        [@used_by, @ancestor | @uses_entities],
        &%Spark.Dsl.Patch.AddEntity{section_path: [:relationships], entity: &1}
      ),
    transformers: [
      AshOwnership.Transformers.AddTargetGuard,
      AshOwnership.Transformers.AddDestroyGuard
    ],
    verifiers: [
      AshOwnership.Verifiers.UsesTargetEnabled,
      AshOwnership.Verifiers.RequiresUses,
      AshOwnership.Verifiers.UsesOnDeleteRestrict,
      AshOwnership.Verifiers.UsedByConsistency
    ]

  @doc false
  def transform_uses(belongs_to) do
    with {:ok, belongs_to} <- Ash.Resource.Relationships.BelongsTo.transform(belongs_to) do
      {:ok, Map.put(belongs_to, :__uses__, true)}
    end
  end

  @doc false
  def transform_ancestor(belongs_to) do
    with {:ok, belongs_to} <- Ash.Resource.Relationships.BelongsTo.transform(belongs_to) do
      {:ok, Map.put(belongs_to, :__ancestor__, true)}
    end
  end

  @doc false
  def transform_used_by(has_many) do
    with {:ok, has_many} <- Ash.Resource.Relationships.HasMany.transform(has_many) do
      {:ok, Map.put(has_many, :__used_by__, true)}
    end
  end
end
