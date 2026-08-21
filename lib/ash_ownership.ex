defmodule AshOwnership do
  @moduledoc """
  Makes ownership explicit: which `belongs_to` owns a record, and which only
  points at something else.

  A `belongs_to` relationship conflates three meanings:

  * **Containment** — the record is owned by its parent and must go down with
    it. This is the only one Ash names, and every record has exactly one owner
    (a join row has one per endpoint).
  * **Lifecycle lock** — the record locks a target that it does not own; the target must
    not vanish while the reference is alive. Declared with `locks`.
  * **Reference key** — a denormalized id of another resource, kept for tenant
    filtering, policies and indexes. The real parent is another relationship.
    Declared with `refers`.

  Leaving all three as plain `belongs_to` makes an owner indistinguishable
  from a pointer, so nothing can tell what a teardown should reach. Naming the
  two non-owning kinds leaves `belongs_to` meaning ownership and nothing else.

  A `locks` edge is an explicit lifecycle lock: the target cannot be dropped
  while a live record holds the lock.

  ## Vocabulary

      defmodule MyApp.Document do
        use Ash.Resource, extensions: [AshOwnership]

        relationships do
          locks :template, MyApp.Template
        end
      end

      defmodule MyApp.Template do
        use Ash.Resource, extensions: [AshOwnership]

        relationships do
          locked_by :documents, MyApp.Document
        end
      end

      defmodule MyApp.LineItem do
        use Ash.Resource, extensions: [AshOwnership]

        relationships do
          belongs_to :document, MyApp.Document   # owner
          locks :product, MyApp.Product           # non-owning reference
          refers :org, MyApp.Org                 # denormalized reference id
        end
      end

  `locks` compiles to a `belongs_to` carrying a `:__locks__` marker, `locked_by`
  to a `has_many` carrying a `:__locked_by__` marker, and `refers` to a
  `belongs_to` carrying a `:__refers__` marker — same options,
  same defaults, so every Ash feature (loading, forms, policies, migrations)
  works unchanged while verifiers and other extensions can tell non-owning
  references apart from containment.

  A resource may declare outgoing `locks`, incoming `locked_by`, or both. The
  transformers and verifiers for a direction that is not declared are no-ops.

  Whether the reference is required (`allow_nil?`) or exposed (`public?`) is
  orthogonal to locking, so `locks` leaves both fully configurable. Ash defaults
  `public?` to `false`, so shorthands mirroring `ash_req_opt`'s `belongs_to`
  variants are provided:

  | entity          | `allow_nil?` | `public?` |
  | --------------- | ------------ | --------- |
  | `locks`          | belongs_to defaults      ||
  | `req_locks`      | `false`      | `true`    |
  | `req_priv_locks` | `false`      | `false`   |
  | `opt_locks`      | `true`       | `true`    |
  | `opt_priv_locks` | `true`       | `false`   |

  ## The invariant

  > While live locking records exist, the locked record can neither be deleted nor
  > archived.

  Hard deletes are restricted by the foreign key (a verifier keeps
  `on_delete` from trading that away), and archives — which no foreign key
  can see — are rejected by `AshOwnership.Changes.EnsureNotLocked`. The reverse
  direction is guarded by `AshOwnership.Changes.EnsureTargetLive`, which rejects
  pointing a `locks` foreign key at an archived or missing target.
  """

  @locks_variants [
    {:locks, nil, nil},
    {:req_locks, false, true},
    {:req_priv_locks, false, false},
    {:opt_locks, true, true},
    {:opt_priv_locks, true, false}
  ]

  @locks_entities Enum.map(@locks_variants, fn {name, allow_nil?, public?} ->
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
                      transform: {__MODULE__, :transform_locks, []},
                      args: [:name, :destination],
                      auto_set_fields: fixed
                    }
                  end)

  @locked_by %Spark.Dsl.Entity{
    name: :locked_by,
    describe: """
    Declares the reverse side of a `locks` edge: the resources that lock this
    resource.

    Compiles to a `has_many`. The destination must have a matching `locks`
    relationship pointing back at this resource.

    It supports no `filter` entity: the destroy guard relies on it to
    enumerate every locking record, which a filtered relationship could not guarantee.
    """,
    examples: [
      """
      locked_by :documents, Document
      """
    ],
    no_depend_modules: [:destination],
    target: Ash.Resource.Relationships.HasMany,
    schema: Ash.Resource.Relationships.HasMany.opt_schema(),
    transform: {__MODULE__, :transform_locked_by, []},
    args: [:name, :destination]
  }

  @refers %Spark.Dsl.Entity{
    name: :refers,
    describe: """
    Declares a denormalized reference key.

    Compiles to a `belongs_to`. The record's real parent is some other
    relationship; this one only carries another resource's id for tenant filtering,
    policy checks and indexes.

    The target needs no reverse relationship: cascades reach this record
    through its real parent, and the foreign key still keeps the referenced row from
    being deleted out from under it.
    """,
    examples: [
      """
      refers :org, Org
      """
    ],
    no_depend_modules: [:destination],
    target: Ash.Resource.Relationships.BelongsTo,
    schema: Ash.Resource.Relationships.BelongsTo.opt_schema(),
    transform: {__MODULE__, :transform_refers, []},
    args: [:name, :destination]
  }

  use Spark.Dsl.Extension,
    dsl_patches:
      Enum.map(
        [@locked_by, @refers | @locks_entities],
        &%Spark.Dsl.Patch.AddEntity{section_path: [:relationships], entity: &1}
      ),
    transformers: [
      AshOwnership.Transformers.AddTargetGuard,
      AshOwnership.Transformers.AddDestroyGuard
    ],
    verifiers: [
      AshOwnership.Verifiers.LocksTargetEnabled,
      AshOwnership.Verifiers.RequiresLocks,
      AshOwnership.Verifiers.LocksOnDeleteRestrict,
      AshOwnership.Verifiers.LockedByConsistency
    ]

  @doc false
  def transform_locks(belongs_to) do
    with {:ok, belongs_to} <- Ash.Resource.Relationships.BelongsTo.transform(belongs_to) do
      {:ok, Map.put(belongs_to, :__locks__, true)}
    end
  end

  @doc false
  def transform_refers(belongs_to) do
    with {:ok, belongs_to} <- Ash.Resource.Relationships.BelongsTo.transform(belongs_to) do
      {:ok, Map.put(belongs_to, :__refers__, true)}
    end
  end

  @doc false
  def transform_locked_by(has_many) do
    with {:ok, has_many} <- Ash.Resource.Relationships.HasMany.transform(has_many) do
      {:ok, Map.put(has_many, :__locked_by__, true)}
    end
  end
end
