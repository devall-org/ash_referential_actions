defmodule AshBorrow.VerifierTest do
  use ExUnit.Case, async: true

  import Spark.Test

  describe "BorrowsTargetBorrowable" do
    test "borrows to a non-borrowable resource is rejected" do
      defmodule PlainTarget do
        @moduledoc false
        use Ash.Resource, domain: nil

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BorrowsPlainTarget do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              borrows(:plain_target, AshBorrow.VerifierTest.PlainTarget)
            end
          end
        end

      assert error.message =~ "not borrowable"
    end
  end

  describe "BorrowableRequiresBorrows" do
    test "plain belongs_to to a borrowable resource is rejected" do
      defmodule Borrowable1 do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BelongsToBorrowable do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              belongs_to(:borrowable1, AshBorrow.VerifierTest.Borrowable1)
            end
          end
        end

      assert error.message =~ "declares no relationship back"
    end

    test "a borrowable may own contained children" do
      refute_dsl_errors do
        defmodule OwningBorrowable do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            # Plain has_many: containment, declared by the owner.
            has_many(:line_items, AshBorrow.VerifierTest.BorrowableLineItem)
          end
        end

        defmodule BorrowableLineItem do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            belongs_to(:owning_borrowable, AshBorrow.VerifierTest.OwningBorrowable)
          end
        end
      end
    end

    test "a containment reverse with a mismatched key pair is still rejected" do
      defmodule MismatchedOwner do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

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
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

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
    test "a filtered primary read on the borrower without read_action is rejected" do
      defmodule ChannelSnapshot do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          borrowed_by :channel_docs, AshBorrow.VerifierTest.FilteredPrimaryDoc do
            destination_attribute :channel_snapshot_id
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule FilteredPrimaryDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

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
              borrows :channel_snapshot, AshBorrow.VerifierTest.ChannelSnapshot
            end
          end
        end

      assert error.message =~ "hide physically live rows"
    end

    test "a declared read_action that does not exist is rejected" do
      defmodule MissingActionSnapshot do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

        attributes do
          uuid_primary_key :id
        end

        actions do
          defaults [:read]
        end

        relationships do
          borrowed_by :missing_action_docs, AshBorrow.VerifierTest.MissingActionDoc do
            destination_attribute :missing_action_snapshot_id
            read_action :nonexistent_read
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule MissingActionDoc do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key :id
            end

            actions do
              defaults [:read]
            end

            relationships do
              borrows :missing_action_snapshot, AshBorrow.VerifierTest.MissingActionSnapshot
            end
          end
        end

      assert error.message =~ "no read action with that name"
    end
  end

  describe "BorrowedByConsistency" do
    test "borrows to an archival borrowable without matching borrowed_by is rejected" do
      defmodule ArchivalNoReverse do
        @moduledoc false
        use Ash.Resource,
          domain: nil,
          extensions: [AshBorrow.Borrowable, AshArchival.Resource]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BorrowsArchivalNoReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              borrows(:archival_no_reverse, AshBorrow.VerifierTest.ArchivalNoReverse)
            end
          end
        end

      assert error.message =~ "declares no `borrowed_by`"
    end

    test "borrows to a non-archival borrowable without matching borrowed_by is rejected" do
      defmodule NonArchivalNoReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

        attributes do
          uuid_primary_key(:id)
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BorrowsNonArchivalNoReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              borrows(:non_archival_no_reverse, AshBorrow.VerifierTest.NonArchivalNoReverse)
            end
          end
        end

      assert error.message =~ "declares no `borrowed_by`"
    end

    test "borrowed_by whose source_attribute matches no borrows is rejected" do
      defmodule MisWiredReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

        attributes do
          uuid_primary_key(:id)
          attribute :alt_id, :uuid, public?: true
        end

        relationships do
          borrowed_by :mis_wired, AshBorrow.VerifierTest.BorrowsMisWiredReverse do
            source_attribute(:alt_id)
            destination_attribute(:mis_wired_reverse_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BorrowsMisWiredReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              borrows(:mis_wired_reverse, AshBorrow.VerifierTest.MisWiredReverse)
            end
          end
        end

      assert error.message =~ "matching `borrows`"
    end

    test "borrowed_by whose destination_attribute matches no borrows is rejected" do
      defmodule LyingReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          borrowed_by :liars, AshBorrow.VerifierTest.BorrowsLyingReverse do
            destination_attribute(:unrelated_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BorrowsLyingReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              borrows(:lying_reverse, AshBorrow.VerifierTest.LyingReverse)
            end
          end
        end

      assert error.message =~ "no matching `borrows`"
    end

    test "plain has_many traversing a borrows foreign key is rejected" do
      defmodule PlainHasManyReverse do
        @moduledoc false
        use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

        attributes do
          uuid_primary_key(:id)
        end

        relationships do
          has_many :borrowers, AshBorrow.VerifierTest.BorrowsPlainHasManyReverse do
            destination_attribute(:plain_has_many_reverse_id)
          end
        end
      end

      error =
        assert_dsl_error %Spark.Error.DslError{} do
          defmodule BorrowsPlainHasManyReverse do
            @moduledoc false
            use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

            attributes do
              uuid_primary_key(:id)
            end

            relationships do
              borrows(:plain_has_many_reverse, AshBorrow.VerifierTest.PlainHasManyReverse)
            end
          end
        end

      assert error.message =~ "must be declared with `borrowed_by`"
    end

    test "a matched borrows / borrowed_by pair compiles cleanly" do
      refute_dsl_errors do
        defmodule CleanSnapshot do
          @moduledoc false
          use Ash.Resource,
            domain: nil,
            extensions: [AshBorrow.Borrowable, AshArchival.Resource]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            borrowed_by :clean_docs, AshBorrow.VerifierTest.CleanDoc do
              destination_attribute(:clean_snapshot_id)
            end
          end
        end

        defmodule CleanDoc do
          @moduledoc false
          use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

          attributes do
            uuid_primary_key(:id)
          end

          actions do
            defaults([:read])
          end

          relationships do
            borrows(:clean_snapshot, AshBorrow.VerifierTest.CleanSnapshot)
          end
        end
      end
    end
  end
end
