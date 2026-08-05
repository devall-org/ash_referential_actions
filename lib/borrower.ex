defmodule AshBorrow.Borrower do
  @moduledoc """
  Extension for resources that borrow other resources.

  Provides the `borrows` relationship entity: a non-owning `belongs_to` to an
  `AshBorrow.Borrowable` resource. The compiled relationship is a regular
  `Ash.Resource.Relationships.BelongsTo` carrying a `:__borrows__` marker —
  same options, same defaults — so every Ash feature (loading, forms,
  policies, migrations) works unchanged while verifiers and other extensions
  can tell borrows apart from containment `belongs_to` relationships.

  Whether the reference is required (`allow_nil?`) or exposed (`public?`) is
  orthogonal to borrowing, so `borrows` leaves both fully configurable. Ash
  defaults `public?` to `false`, so shorthands mirroring `ash_req_opt`'s
  `belongs_to` variants are provided:

  | entity              | `allow_nil?` | `public?` |
  | ------------------- | ------------ | --------- |
  | `borrows`           | belongs_to defaults      ||
  | `req_borrows`       | `false`      | `true`    |
  | `req_prv_borrows`   | `false`      | `false`   |
  | `opt_borrows`       | `true`       | `true`    |
  | `opt_prv_borrows`   | `true`       | `false`   |
  """

  @borrows_variants [
    {:borrows, nil, nil},
    {:req_borrows, false, true},
    {:req_prv_borrows, false, false},
    {:opt_borrows, true, true},
    {:opt_prv_borrows, true, false}
  ]

  @borrows_entities Enum.map(@borrows_variants, fn {name, allow_nil?, public?} ->
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
                        Declares a non-owning reference (a borrow) to a borrowable resource.

                        Compiles to a `belongs_to` with #{describe}.
                        The destination must use the `AshBorrow.Borrowable` extension.
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
                        transform: {__MODULE__, :transform, []},
                        args: [:name, :destination],
                        auto_set_fields: fixed
                      }
                    end)

  use Spark.Dsl.Extension,
    dsl_patches:
      Enum.map(
        @borrows_entities,
        &%Spark.Dsl.Patch.AddEntity{section_path: [:relationships], entity: &1}
      ),
    transformers: [AshBorrow.Borrower.AddTargetGuard],
    verifiers: [
      AshBorrow.Verifiers.BorrowsTargetBorrowable,
      AshBorrow.Verifiers.BorrowableRequiresBorrows,
      AshBorrow.Verifiers.BorrowsOnDeleteRestrict,
      AshBorrow.Verifiers.BorrowedByConsistency
    ]

  @doc false
  def transform(belongs_to) do
    with {:ok, belongs_to} <- Ash.Resource.Relationships.BelongsTo.transform(belongs_to) do
      {:ok, Map.put(belongs_to, :__borrows__, true)}
    end
  end
end
