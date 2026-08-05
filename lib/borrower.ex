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
  orthogonal to borrowing and stays fully configurable, exactly as on
  `belongs_to`.
  """

  @borrows %Spark.Dsl.Entity{
    name: :borrows,
    describe: """
    Declares a non-owning reference (a borrow) to a borrowable resource.

    Compiles to a `belongs_to` with identical options and defaults.
    The destination must use the `AshBorrow.Borrowable` extension.
    """,
    examples: [
      """
      borrows :template, Template
      """
    ],
    no_depend_modules: [:destination],
    target: Ash.Resource.Relationships.BelongsTo,
    schema: Ash.Resource.Relationships.BelongsTo.opt_schema(),
    transform: {__MODULE__, :transform, []},
    args: [:name, :destination]
  }

  use Spark.Dsl.Extension,
    dsl_patches: [
      %Spark.Dsl.Patch.AddEntity{section_path: [:relationships], entity: @borrows}
    ],
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
