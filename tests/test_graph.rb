require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../plugins/OpenSketchupDC_OpenDC", __dir__)
require "constants"
require "core/graph"

class TestGraph < Minitest::Test
  G = OpenSketchupDC::OpenDC::Graph

  def test_linear_order
    g = G.new
    g.add("a", ["b"])
    g.add("b", ["c"])
    g.add("c", [])
    order, cyclic = g.order
    assert_equal %w[c b a], order
    assert_empty cyclic
  end

  def test_diamond
    g = G.new
    g.add("a", %w[b c])
    g.add("b", ["d"])
    g.add("c", ["d"])
    g.add("d", [])
    order, cyclic = g.order
    assert_equal "d", order.first
    assert_equal "a", order.last
    assert_equal 4, order.length
    assert_empty cyclic
  end

  def test_cycle_detected
    g = G.new
    g.add("a", ["b"])
    g.add("b", ["a"])
    g.add("c", [])
    order, cyclic = g.order
    assert_equal ["c"], order
    assert_equal %w[a b].sort, cyclic.sort
  end

  def test_missing_deps_ignored
    g = G.new
    g.add("a", ["nonexistent"])
    order, _cyclic = g.order
    assert_equal ["a"], order
  end
end
