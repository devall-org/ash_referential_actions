defmodule AshBorrow.MarkerSurvivalTest do
  use ExUnit.Case, async: true

  alias AshBorrow.Test.Support.TestResources

  test "borrows compiles to a BelongsTo that keeps the :__borrows__ marker" do
    rel = Ash.Resource.Info.relationship(TestResources.Doc, :snapshot)

    assert %Ash.Resource.Relationships.BelongsTo{} = rel
    assert Map.get(rel, :__borrows__) == true
    assert rel.destination == TestResources.Snapshot
  end

  test "borrows passes belongs_to options through" do
    defmodule RequiredSnapshot do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrowable]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      relationships do
        borrowed_by :required_borrow_docs, AshBorrow.MarkerSurvivalTest.RequiredBorrowDoc do
          destination_attribute :snapshot_id
        end
      end
    end

    defmodule RequiredBorrowDoc do
      @moduledoc false
      use Ash.Resource, domain: nil, extensions: [AshBorrow.Borrower]

      attributes do
        uuid_primary_key :id
      end

      actions do
        defaults [:read]
      end

      relationships do
        borrows :snapshot, AshBorrow.MarkerSurvivalTest.RequiredSnapshot do
          allow_nil? false
          public? true
        end
      end
    end

    rel = Ash.Resource.Info.relationship(RequiredBorrowDoc, :snapshot)

    assert Map.get(rel, :__borrows__) == true
    assert rel.allow_nil? == false
    assert rel.public? == true
  end

  test "borrowed_by compiles to a HasMany that keeps the :__borrowed_by__ marker" do
    rel = Ash.Resource.Info.relationship(TestResources.Snapshot, :docs)

    assert %Ash.Resource.Relationships.HasMany{} = rel
    assert Map.get(rel, :__borrowed_by__) == true
    assert rel.destination == TestResources.Doc
    assert rel.destination_attribute == :snapshot_id
  end

  test "plain belongs_to and has_many carry no markers" do
    defmodule PlainParent do
      @moduledoc false
      use Ash.Resource, domain: nil

      attributes do
        uuid_primary_key(:id)
      end

      relationships do
        has_many(:children, AshBorrow.MarkerSurvivalTest.PlainChild)
      end
    end

    defmodule PlainChild do
      @moduledoc false
      use Ash.Resource, domain: nil

      attributes do
        uuid_primary_key(:id)
      end

      relationships do
        belongs_to(:plain_parent, AshBorrow.MarkerSurvivalTest.PlainParent)
      end
    end

    refute Ash.Resource.Info.relationship(PlainChild, :plain_parent) |> Map.get(:__borrows__)
    refute Ash.Resource.Info.relationship(PlainParent, :children) |> Map.get(:__borrowed_by__)
  end
end
