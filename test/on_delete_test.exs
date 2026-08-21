defmodule AshOwnership.OnDeleteTest do
  use ExUnit.Case, async: true

  import Spark.Test

  defmodule Repo do
    @moduledoc false
    use AshPostgres.Repo, otp_app: :ash_ownership, warn_on_missing_ash_functions?: false

    def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
  end

  defmodule PgSnapshot do
    @moduledoc false
    use Ash.Resource, domain: nil, extensions: [AshOwnership]

    attributes do
      uuid_primary_key :id
    end

    actions do
      defaults [:read]
    end

    relationships do
      locked_by :nilify_docs, AshOwnership.OnDeleteTest.NilifyDoc do
        destination_attribute :pg_snapshot_id
      end

      locked_by :restrict_docs, AshOwnership.OnDeleteTest.RestrictDoc do
        destination_attribute :pg_snapshot_id
      end

      locked_by :ignore_docs, AshOwnership.OnDeleteTest.IgnoreDoc do
        destination_attribute :pg_snapshot_id
      end
    end
  end

  test "a locks reference with on_delete: :nilify is rejected" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule NilifyDoc do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshOwnership]

          postgres do
            table "nilify_doc"
            repo(AshOwnership.OnDeleteTest.Repo)

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
            locks :pg_snapshot, AshOwnership.OnDeleteTest.PgSnapshot
          end
        end
      end

    assert error.message =~ "restrict semantics"
  end

  test "a locks reference with ignore?: true is rejected" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule IgnoreDoc do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshOwnership]

          postgres do
            table "ignore_doc"
            repo(AshOwnership.OnDeleteTest.Repo)

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
            locks :pg_snapshot, AshOwnership.OnDeleteTest.PgSnapshot
          end
        end
      end

    assert error.message =~ "removes the foreign key constraint"
  end

  test "a locks reference keeping restrict semantics compiles" do
    refute_dsl_errors do
      defmodule RestrictDoc do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshOwnership]

        postgres do
          table "restrict_doc"
          repo(AshOwnership.OnDeleteTest.Repo)

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
          locks :pg_snapshot, AshOwnership.OnDeleteTest.PgSnapshot
        end
      end
    end

    rel = Ash.Resource.Info.relationship(AshOwnership.OnDeleteTest.RestrictDoc, :pg_snapshot)
    assert AshOwnership.Info.locks?(rel)
  end
end
