defmodule AshBorrow.VerifierTest do
  use ExUnit.Case, async: true

  import Spark.Test

  describe "UsesTargetEnabled" do
    test "uses targeting a resource without the extension is rejected" do
      defmodule PlainTarget do
        @moduledoc false
        use Ash.Resource, domain: nil

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule UsesPlainTarget do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              uses(:plain_target, AshBorrow.VerifierTest.PlainTarget)
            end
          end
        end

      assert error.message =~ "does not have the"
    end
  end

  describe "RequiresUses" do
    test "plain belongs_to to an AshBorrow resource is rejected" do
      defmodule Enabled1 do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BelongsToEnabled do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              belongs_to(:enabled1, AshBorrow.VerifierTest.Enabled1)
            end
          end
        end

      assert error.message =~ "declares no relationship back"
    end

    test "an AshBorrow resource may own contained children" do
      refute_dsl_errors do
        defmodule OwningResource do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            # Plain has_many: containment, declared by the owner.
            has_many(:line_items, AshBorrow.VerifierTest.OwnedLineItem)
          end
        end

        defmodule OwnedLineItem do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            belongs_to(:owning_resource, AshBorrow.VerifierTest.OwningResource)
          end
        end
      end
    end

    test "a containment reverse with a mismatched key pair is still rejected" do
      defmodule MismatchedOwner do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key(:id)
          attribute(:alt_id, :uuid, public?: true)
        end

        actions do
          defaults([:read])
        end

        relationships do
          has_many :mismatched_children, AshBorrow.VerifierTest.MismatchedChild do
            source_attribute(:alt_id)
            destination_attribute(:mismatched_owner_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule MismatchedChild do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            actions do
              defaults([:read])
            end

            relationships do
              belongs_to(:mismatched_owner, AshBorrow.VerifierTest.MismatchedOwner)
            end
          end
        end

      assert error.message =~ "declares no relationship back"
    end
  end

  describe "guard read channels" do
    test "a filtered primary read on the using side without read_action is rejected" do
      defmodule ChannelSnapshot do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          used_by :channel_docs, AshBorrow.VerifierTest.FilteredPrimaryDoc do
            destination_attribute :channel_snapshot_id
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule FilteredPrimaryDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key :id
              attribute :active, :boolean, public?: true, default: true
            end

            actions do
              read :read do
                primary? true
                filter expr(active == true)
              end
            end

            relationships do
              uses :channel_snapshot, AshBorrow.VerifierTest.ChannelSnapshot
            end
          end
        end

      assert error.message =~ "a union of filtered views can miss a live user"
    end

    test "one unfiltered used_by is enough alongside filtered views" do
      refute_dsl_errors do
        defmodule MixedChannelSnapshot do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow]

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end

          relationships do
            used_by :active_mixed_docs, AshBorrow.VerifierTest.MixedChannelDoc do
              destination_attribute :mixed_channel_snapshot_id
              read_action :list_active
            end

            used_by :all_mixed_docs, AshBorrow.VerifierTest.MixedChannelDoc do
              destination_attribute :mixed_channel_snapshot_id
            end
          end
        end

        defmodule MixedChannelDoc do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow]

          attributes do
            uuid_primary_key :id
            attribute :active, :boolean, public?: true, default: true
          end

          actions do
            defaults [:read]

            read :list_active do
              filter expr(active == true)
            end
          end

          relationships do
            uses :mixed_channel_snapshot, AshBorrow.VerifierTest.MixedChannelSnapshot
          end
        end
      end
    end

    test "only filtered used_by channels are rejected" do
      defmodule FilteredOnlySnapshot do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          used_by :active_filtered_docs, AshBorrow.VerifierTest.FilteredOnlyDoc do
            destination_attribute :filtered_only_snapshot_id
            read_action :list_active
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule FilteredOnlyDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key :id
              attribute :active, :boolean, public?: true, default: true
            end

            actions do
              defaults [:read]

              read :list_active do
                filter expr(active == true)
              end
            end

            relationships do
              uses :filtered_only_snapshot, AshBorrow.VerifierTest.FilteredOnlySnapshot
            end
          end
        end

      assert error.message =~ "a union of filtered views can miss a live user"
    end

    test "a declared read_action that does not exist is rejected" do
      defmodule MissingActionSnapshot do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          used_by :missing_action_docs, AshBorrow.VerifierTest.MissingActionDoc do
            destination_attribute :missing_action_snapshot_id
            read_action :nonexistent_read
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule MissingActionDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end

            relationships do
              uses :missing_action_snapshot, AshBorrow.VerifierTest.MissingActionSnapshot
            end
          end
        end

      assert error.message =~ "no read action with that name"
    end
  end

  describe "UsedByConsistency" do
    test "uses to an archival target without matching used_by is rejected" do
      defmodule ArchivalNoReverse do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          extensions: [AshBorrow, AshArchival.Resource]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule UsesArchivalNoReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              uses(:archival_no_reverse, AshBorrow.VerifierTest.ArchivalNoReverse)
            end
          end
        end

      assert error.message =~ "declares no `used_by`"
    end

    test "uses to a non-archival target without matching used_by is rejected" do
      defmodule NonArchivalNoReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule UsesNonArchivalNoReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              uses(:non_archival_no_reverse, AshBorrow.VerifierTest.NonArchivalNoReverse)
            end
          end
        end

      assert error.message =~ "declares no `used_by`"
    end

    test "used_by whose source_attribute matches no uses is rejected" do
      defmodule MisWiredReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key(:id)
          attribute :alt_id, :uuid, public?: true
        end

        relationships do
          used_by :mis_wired, AshBorrow.VerifierTest.UsesMisWiredReverse do
            source_attribute(:alt_id)
            destination_attribute(:mis_wired_reverse_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule UsesMisWiredReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              uses(:mis_wired_reverse, AshBorrow.VerifierTest.MisWiredReverse)
            end
          end
        end

      assert error.message =~ "matching `uses`"
    end

    test "used_by whose destination_attribute matches no uses is rejected" do
      defmodule LyingReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          used_by :liars, AshBorrow.VerifierTest.UsesLyingReverse do
            destination_attribute(:unrelated_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule UsesLyingReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              uses(:lying_reverse, AshBorrow.VerifierTest.LyingReverse)
            end
          end
        end

      assert error.message =~ "no matching `uses`"
    end

    test "plain has_many traversing a uses foreign key is rejected" do
      defmodule PlainHasManyReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow]

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          has_many :borrowers, AshBorrow.VerifierTest.UsesPlainHasManyReverse do
            destination_attribute(:plain_has_many_reverse_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule UsesPlainHasManyReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              uses(:plain_has_many_reverse, AshBorrow.VerifierTest.PlainHasManyReverse)
            end
          end
        end

      assert error.message =~ "must be declared with `used_by`"
    end

    test "a matched uses / used_by pair compiles cleanly" do
      refute_dsl_errors do
        defmodule CleanSnapshot do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            extensions: [AshBorrow, AshArchival.Resource]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            used_by :clean_docs, AshBorrow.VerifierTest.CleanDoc do
              destination_attribute(:clean_snapshot_id)
            end
          end
        end

        defmodule CleanDoc do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            uses(:clean_snapshot, AshBorrow.VerifierTest.CleanSnapshot)
          end
        end
      end
    end
  end
end
