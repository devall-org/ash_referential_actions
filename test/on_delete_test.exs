defmodule AshBorrow.OnDeleteTest do
  use ExUnit.Case, async: true

  import Spark.Test

  defmodule Repo do
    @moduledoc false
    use AshPostgres.Repo, otp_app: :ash_borrow, warn_on_missing_ash_functions?: false

    def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
  end

  defmodule PgSnapshot do
    @moduledoc false
    use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end

    relationships do
      borrowed_by :nilify_docs, AshBorrow.OnDeleteTest.NilifyDoc do
        destination_attribute :pg_snapshot_id
      end

      borrowed_by :restrict_docs, AshBorrow.OnDeleteTest.RestrictDoc do
        destination_attribute :pg_snapshot_id
      end

      borrowed_by :ignore_docs, AshBorrow.OnDeleteTest.IgnoreDoc do
        destination_attribute :pg_snapshot_id
      end
    end
  end

  test "a borrows reference with on_delete: :nilify is rejected" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule NilifyDoc do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshBorrow.Borrower]

          postgres do
            table "nilify_doc"
            repo(AshBorrow.OnDeleteTest.Repo)

            references do
              reference(:pg_snapshot, on_delete: :nilify)
            end
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end

          relationships do
            borrows :pg_snapshot, AshBorrow.OnDeleteTest.PgSnapshot
          end
        end
      end

    assert error.message =~ "restrict semantics"
  end

  test "a borrows reference with ignore?: true is rejected" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule IgnoreDoc do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshBorrow.Borrower]

          postgres do
            table "ignore_doc"
            repo(AshBorrow.OnDeleteTest.Repo)

            references do
              reference(:pg_snapshot, ignore?: true)
            end
          end

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end

          relationships do
            borrows :pg_snapshot, AshBorrow.OnDeleteTest.PgSnapshot
          end
        end
      end

    assert error.message =~ "removes the foreign key constraint"
  end

  test "a borrows reference keeping restrict semantics compiles" do
    refute_dsl_errors do
      defmodule RestrictDoc do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshBorrow.Borrower]

        postgres do
          table "restrict_doc"
          repo(AshBorrow.OnDeleteTest.Repo)

          references do
            reference(:pg_snapshot, on_delete: :restrict)
          end
        end

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          borrows :pg_snapshot, AshBorrow.OnDeleteTest.PgSnapshot
        end
      end
    end

    rel = Ash.Resource.Info.relationship(AshBorrow.OnDeleteTest.RestrictDoc, :pg_snapshot)
    assert AshBorrow.Info.borrows?(rel)
  end
end
