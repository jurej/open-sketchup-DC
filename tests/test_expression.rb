require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../plugins/OpenSketchupDC_OpenDC", __dir__)
require "constants"
require "core/params"
require "core/expression"

class TestExpression < Minitest::Test
  E = OpenSketchupDC::OpenDC::Expression
  Ctx = OpenSketchupDC::OpenDC

  def ctx(attrs = {}, refs = {})
    {
      get: ->(n) { attrs.fetch(n) { raise E::Error, "undefined '#{n}'" } },
      ref: ->(s, n) { refs.fetch([s, n]) { raise E::Error, "undefined '#{s}!#{n}'" } },
      meta: ->(n, f) { attrs["__meta_#{n}_#{f}"] }
    }
  end

  def test_arithmetic
    assert_in_delta 7.0, E.eval!("1+2*3"), 1e-9
    assert_in_delta 9.0, E.eval!("(1+2)*3"), 1e-9
    assert_in_delta 4.0, E.eval!("2^2"), 1e-9
    assert_in_delta 1.0, E.eval!("7%3"), 1e-9
    assert_in_delta(-2.0, E.eval!("-2"), 1e-9)
  end

  def test_units
    assert_in_delta 10.0 / 2.54, E.eval!("10cm"), 1e-9
    assert_in_delta 1.0, E.eval!("25.4mm"), 1e-9
    assert_in_delta 12.0, E.eval!("1ft"), 1e-9
    assert_in_delta 24.0, E.eval!("2'"), 1e-9
    assert_in_delta 4.0, E.eval!("4\""), 1e-9
  end

  def test_strings
    assert_equal "ab", E.eval!('"a" & "b"')
    assert_equal "x:5", E.eval!('"x:" & 5')
    assert_equal "Panel: 2X", E.eval!('"Panel: " & 2 & "X"')
  end

  def test_comparison_and_logic
    assert_equal true, E.eval!("1 = 1")
    assert_equal true, E.eval!("2 <> 1")
    assert_equal true, E.eval!("3 > 2 AND 1 < 2")
    assert_equal true, E.eval!("NOT 0")
    assert_equal true, E.eval!('"Abc" = "abc"') # case-insensitive
  end

  def test_if_lazy
    assert_equal "b", E.eval!('IF(1>2,"a","b")')
    # dead branch references an undefined attribute - lazy eval must skip it
    assert_equal 5.0, E.eval!("IF(0, nosuchattr, 5)", ctx({}))
  end

  def test_choose
    assert_equal "b", E.eval!('CHOOSE(2,"a","b","c")')
    assert_equal "a", E.eval!('CHOOSE(0,"a","b")') # clamps
  end

  def test_functions
    assert_in_delta 5.0, E.eval!("MAX(1,5,3)"), 1e-9
    assert_in_delta 1.0, E.eval!("MIN(1,5,3)"), 1e-9
    assert_in_delta 3.5, E.eval!("ROUND(3.46,1)"), 1e-9
    assert_in_delta 1.0, E.eval!("SIN(90)"), 1e-9
    assert_in_delta 0.0, E.eval!("COS(90)"), 1e-9
    assert_in_delta Math::PI, E.eval!("PI()"), 1e-9
    assert_in_delta 3.0, E.eval!("SQRT(9)"), 1e-9
    assert_in_delta 4.0, E.eval!("LARGEST(1,4,2,8, 2)"), 1e-9
    assert_in_delta 1.0, E.eval!("SMALLEST(1,4,2,8, 1)"), 1e-9
  end

  def test_attribute_refs
    c = ctx({ "width" => 10.0 }, { %w[parent h] => 7.0 })
    assert_in_delta 20.0, E.eval!("width*2", c), 1e-9
    assert_in_delta 70.0, E.eval!("width*parent!h", c), 1e-9
  end

  def test_current
    c = ctx({ "w" => 3.0 })
    assert_in_delta 3.0, E.eval!('CURRENT("w")', c), 1e-9
  end

  def test_leading_equals_stripped
    assert_in_delta 3.0, E.eval!("=1+2"), 1e-9
  end

  def test_undefined_raises
    assert_raises(E::Error) { E.eval!("nosuchattr+1", ctx({})) }
    assert_raises(E::Error) { E.eval!("FOOBAR(1)") }
  end

  def test_refs_extraction
    deps = E.refs("width*2 + parent!h + global!k")
    assert_includes deps, [nil, "width"]
    assert_includes deps, %w[parent h]
    assert_includes deps, %w[global k]
    deps2 = E.refs('IF(a=1, CURRENT("b"), 0)')
    assert_includes deps2, [nil, "a"]
    assert_includes deps2, [nil, "b"]
  end
end
