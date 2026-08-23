# frozen_string_literal: true

require "test_helper"

class TestParallelismTest < ActiveSupport::TestCase
  test "local parallel requests clamp to one worker" do
    assert_equal 1, TestParallelism.worker_count("PARALLEL_WORKERS" => "4")
  end

  test "CI keeps its parallel worker policy" do
    assert_equal :number_of_processors, TestParallelism.worker_count("CI" => "true")
    assert_equal 4, TestParallelism.worker_count("CI" => "true", "PARALLEL_WORKERS" => "4")
  end

  test "the explicit measurement escape hatch preserves the requested count" do
    env = {
      "PARALLEL_WORKERS" => "4",
      TestParallelism::UNSAFE_OVERRIDE => "1"
    }

    assert_equal 4, TestParallelism.worker_count(env)
  end

  test "single-process requests remain untouched" do
    assert_equal 1, TestParallelism.worker_count("PARALLEL_WORKERS" => "1")
    assert_equal 0, TestParallelism.worker_count("PARALLEL_WORKERS" => "0")
  end
end
