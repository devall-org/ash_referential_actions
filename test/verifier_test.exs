defmodule AshReferentialActions.VerifierTest do
  use ExUnit.Case, async: true

  import Spark.Test

  defmodule Repo do
    use AshPostgres.Repo,
      otp_app: :ash_referential_actions,
      warn_on_missing_ash_functions?: false

    def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
  end

  test "plain attributable relationships are rejected" do
    error =
      assert_dsl_error %Spark.Error.DslError{} do
        defmodule PlainRelationship do
          use Ash.Resource, domain: nil, extensions: [AshReferentialActions]

          attributes do
            uuid_primary_key :id
          end

          relationships do
            belongs_to :parent, __MODULE__
          end
        end
      end

    assert error.message =~ "Plain belongs_to is forbidden"
  end

  test "Postgres adapter generates the matching on_delete action" do
    refute_dsl_errors do
      defmodule PostgresNilify do
        use Ash.Resource,
          domain: nil,
          data_layer: AshPostgres.DataLayer,
          extensions: [AshReferentialActions.Postgres]

        postgres do
          table "postgres_nilify"
          repo(AshReferentialActions.VerifierTest.Repo)
        end

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          opt_nilify_belongs_to :parent, __MODULE__
          nilify_has_many :children, __MODULE__, destination_attribute: :parent_id
        end
      end
    end

    reference =
      AshPostgres.DataLayer.Info.reference(
        AshReferentialActions.VerifierTest.PostgresNilify,
        :parent
      )

    assert reference.on_delete == :nilify
  end

  test "archival adapter generates archive_related from cascade relationships" do
    assert AshArchival.Resource.Info.archive_archive_related!(
             AshReferentialActions.Test.Resources.CascadeParent
           ) == [:children]
  end
end
