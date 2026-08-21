defmodule AshOwnership.VerifierTest do
  use ExUnit.Case, async: true

  import Spark.Test

  describe "LocksTargetEnabled" do
    test "locks targeting a resource without the extension is rejected" do
      defmodule PlainTarget do
        @moduledoc false
        use Ash.Resource, domain: nil

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule LocksPlainTarget do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              locks(:plain_target, AshOwnership.VerifierTest.PlainTarget)
            end
          end
        end

      assert error.message =~ "does not have the"
    end
  end

  describe "RequiresLocks" do
    test "plain belongs_to to an AshOwnership resource is rejected" do
      defmodule Enabled1 do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BelongsToEnabled do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              belongs_to(:enabled1, AshOwnership.VerifierTest.Enabled1)
            end
          end
        end

      assert error.message =~ "declares no relationship back"
    end

    test "an AshOwnership resource may own contained children" do
      refute_dsl_errors do
        defmodule OwningResource do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshOwnership]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            # Plain has_many: containment, declared by the owner.
            has_many(:line_items, AshOwnership.VerifierTest.OwnedLineItem)
          end
        end

        defmodule OwnedLineItem do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshOwnership]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            belongs_to(:owning_resource, AshOwnership.VerifierTest.OwningResource)
          end
        end
      end
    end

    test "a containment reverse with a mismatched key pair is still rejected" do
      defmodule MismatchedOwner do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key(:id)
          attribute(:alt_id, :uuid, public?: true)
        end

        actions do
          defaults([:read])
        end

        relationships do
          has_many :mismatched_children, AshOwnership.VerifierTest.MismatchedChild do
            source_attribute(:alt_id)
            destination_attribute(:mismatched_owner_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule MismatchedChild do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            actions do
              defaults([:read])
            end

            relationships do
              belongs_to(:mismatched_owner, AshOwnership.VerifierTest.MismatchedOwner)
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
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          locked_by :channel_docs, AshOwnership.VerifierTest.FilteredPrimaryDoc do
            destination_attribute :channel_snapshot_id
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule FilteredPrimaryDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

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
              locks :channel_snapshot, AshOwnership.VerifierTest.ChannelSnapshot
            end
          end
        end

      assert error.message =~ "a union of filtered views can miss a live user"
    end

    test "one unfiltered locked_by is enough alongside filtered views" do
      refute_dsl_errors do
        defmodule MixedChannelSnapshot do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshOwnership]

          attributes do
            uuid_primary_key :id
          end

          actions do
            defaults [:read]
          end

          relationships do
            locked_by :active_mixed_docs, AshOwnership.VerifierTest.MixedChannelDoc do
              destination_attribute :mixed_channel_snapshot_id
              read_action :list_active
            end

            locked_by :all_mixed_docs, AshOwnership.VerifierTest.MixedChannelDoc do
              destination_attribute :mixed_channel_snapshot_id
            end
          end
        end

        defmodule MixedChannelDoc do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshOwnership]

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
            locks :mixed_channel_snapshot, AshOwnership.VerifierTest.MixedChannelSnapshot
          end
        end
      end
    end

    test "only filtered locked_by channels are rejected" do
      defmodule FilteredOnlySnapshot do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          locked_by :active_filtered_docs, AshOwnership.VerifierTest.FilteredOnlyDoc do
            destination_attribute :filtered_only_snapshot_id
            read_action :list_active
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule FilteredOnlyDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

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
              locks :filtered_only_snapshot, AshOwnership.VerifierTest.FilteredOnlySnapshot
            end
          end
        end

      assert error.message =~ "a union of filtered views can miss a live user"
    end

    test "a declared read_action that does not exist is rejected" do
      defmodule MissingActionSnapshot do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          locked_by :missing_action_docs, AshOwnership.VerifierTest.MissingActionDoc do
            destination_attribute :missing_action_snapshot_id
            read_action :nonexistent_read
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule MissingActionDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end

            relationships do
              locks :missing_action_snapshot, AshOwnership.VerifierTest.MissingActionSnapshot
            end
          end
        end

      assert error.message =~ "no read action with that name"
    end
  end

  describe "LockedByConsistency" do
    test "locks to an archival target without matching locked_by is rejected" do
      defmodule ArchivalNoReverse do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          extensions: [AshOwnership, AshArchival.Resource]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule LocksArchivalNoReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              locks(:archival_no_reverse, AshOwnership.VerifierTest.ArchivalNoReverse)
            end
          end
        end

      assert error.message =~ "declares no `locked_by`"
    end

    test "locks to a non-archival target without matching locked_by is rejected" do
      defmodule NonArchivalNoReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule LocksNonArchivalNoReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              locks(:non_archival_no_reverse, AshOwnership.VerifierTest.NonArchivalNoReverse)
            end
          end
        end

      assert error.message =~ "declares no `locked_by`"
    end

    test "locked_by whose source_attribute matches no locks is rejected" do
      defmodule MisWiredReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key(:id)
          attribute :alt_id, :uuid, public?: true
        end

        relationships do
          locked_by :mis_wired, AshOwnership.VerifierTest.LocksMisWiredReverse do
            source_attribute(:alt_id)
            destination_attribute(:mis_wired_reverse_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule LocksMisWiredReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              locks(:mis_wired_reverse, AshOwnership.VerifierTest.MisWiredReverse)
            end
          end
        end

      assert error.message =~ "matching `locks`"
    end

    test "locked_by whose destination_attribute matches no locks is rejected" do
      defmodule LyingReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          locked_by :liars, AshOwnership.VerifierTest.LocksLyingReverse do
            destination_attribute(:unrelated_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule LocksLyingReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              locks(:lying_reverse, AshOwnership.VerifierTest.LyingReverse)
            end
          end
        end

      assert error.message =~ "no matching `locks`"
    end

    test "plain has_many traversing a locks foreign key is rejected" do
      defmodule PlainHasManyReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshOwnership]

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          has_many :lockers, AshOwnership.VerifierTest.LocksPlainHasManyReverse do
            destination_attribute(:plain_has_many_reverse_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule LocksPlainHasManyReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshOwnership]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              locks(:plain_has_many_reverse, AshOwnership.VerifierTest.PlainHasManyReverse)
            end
          end
        end

      assert error.message =~ "must be declared with `locked_by`"
    end

    test "a matched locks / locked_by pair compiles cleanly" do
      refute_dsl_errors do
        defmodule CleanSnapshot do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            extensions: [AshOwnership, AshArchival.Resource]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            locked_by :clean_docs, AshOwnership.VerifierTest.CleanDoc do
              destination_attribute(:clean_snapshot_id)
            end
          end
        end

        defmodule CleanDoc do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshOwnership]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            locks(:clean_snapshot, AshOwnership.VerifierTest.CleanSnapshot)
          end
        end
      end
    end
  end
end
