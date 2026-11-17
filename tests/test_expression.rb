# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

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

  def test_action_functions_need_fx
    assert_raises(E::Error) { E.eval!('SET("x",1,2)', ctx({})) }
    assert_raises(E::Error) { E.eval!("REDRAW()", ctx({})) }
  end

  def test_action_functions_delegate_to_fx
    calls = []
    fx = lambda { |fn, args|
      calls << [fn, args]
      args[-1]
    }
    c = ctx({}).merge(fx: fx)
    assert_in_delta 2.0, E.eval!('SET("x",1,2)', c), 1e-9
    assert_equal [["SET", ["x", 1.0, 2.0]]], calls
    assert_nil E.eval!("REDRAW()", c)
    assert_equal [["SET", ["x", 1.0, 2.0]], ["REDRAW", []]], calls
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

  def test_refs_optionlabel
    deps = E.refs('OPTIONLABEL("finish")')
    assert_includes deps, [nil, "finish"]
  end

  # ---- classic DC catalogue ---------------------------------------------

  def test_logical_function_forms
    assert_equal true,  E.eval!("AND(1=1, 2>1)")
    assert_equal false, E.eval!("AND(1=1, 2<1)")
    assert_equal true,  E.eval!("OR(1=2, 2>1)")
    assert_equal false, E.eval!("OR(1=2, 2<1)")
    assert_equal false, E.eval!("NOT(1=1)")
    assert_in_delta 1.0, E.eval!("TRUE()"), 1e-9
    assert_in_delta 0.0, E.eval!("FALSE()"), 1e-9
    # bare literals still work
    assert_equal true, E.eval!("1 = TRUE")
    assert_equal true, E.eval!("TRUE() = TRUE")
    assert_equal true, E.eval!("FALSE = 0")
  end

  def test_math_functions
    assert_in_delta 4.0,    E.eval!("EVEN(3)"),    1e-9
    assert_in_delta(-4.0,   E.eval!("EVEN(-3)"),   1e-9)
    assert_in_delta 3.0,    E.eval!("ODD(1.5)"),   1e-9
    assert_equal true,  E.eval!("ISEVEN(4.9)")
    assert_equal true,  E.eval!("ISODD(3.2)")
    assert_equal false, E.eval!("ISEVEN(3)")
    assert_in_delta Math.exp(2), E.eval!("EXP(2)"), 1e-9
    assert_in_delta Math.log(10), E.eval!("LN(10)"), 1e-9
    assert_in_delta 2.0,    E.eval!("LOG10(100)"), 1e-9
    assert_in_delta(-1.0,   E.eval!("SIGN(-5)"),   1e-9)
    assert_in_delta 0.0,    E.eval!("SIGN(0)"),    1e-9
    assert_in_delta 1.0,    E.eval!("SIGN(7)"),    1e-9
    # rounding with significance
    assert_in_delta 26.3,   E.eval!("CEILING(26.25, 0.1)"), 1e-9
    assert_in_delta 26.2,   E.eval!("FLOOR(26.25, 0.1)"),   1e-9
    assert_in_delta 3.0,    E.eval!("CEILING(2.5)"),        1e-9
    assert_in_delta 2.0,    E.eval!("FLOOR(2.5)"),          1e-9
    assert_in_delta(-2.0,   E.eval!("INT(-1.5)"),           1e-9)
    assert_raises(E::Error) { E.eval!("SQRT(-1)") }
    assert_raises(E::Error) { E.eval!("LN(0)") }
  end

  def test_rand_functions
    100.times do
      r = E.eval!("RAND()")
      assert r >= 0 && r < 1
      b = E.eval!("RANDBETWEEN(3, 6)")
      assert [3, 4, 5, 6].include?(b)
    end
    assert_raises(E::Error) { E.eval!("RANDBETWEEN(6, 3)") }
  end

  def test_trig_functions
    assert_in_delta 0.0, E.eval!("SINH(0)"), 1e-9
    assert_in_delta 1.0, E.eval!("COSH(0)"), 1e-9
    assert_in_delta 0.0, E.eval!("TANH(0)"), 1e-9
    assert_in_delta 0.0, E.eval!("ASINH(0)"), 1e-9
    assert_in_delta 0.0, E.eval!("ATANH(0)"), 1e-9
    assert_raises(E::Error) { E.eval!("ACOSH(0)") } # domain: x >= 1
    assert_raises(E::Error) { E.eval!("ATANH(2)") } # domain: |x| < 1
    # inverse hyperbolic returns degrees like ASIN/ACOS/ATAN
    assert_in_delta 0.0, E.eval!("ASINH(0)"), 1e-9
  end

  def test_text_functions
    assert_equal "abc",     E.eval!('CONCATENATE("a","b","c")')
    assert_equal "A",       E.eval!("CHAR(65)")
    assert_in_delta 65.0,   E.eval!('CODE("Apple")'), 1e-9
    assert_equal "$1,234.50", E.eval!("DOLLAR(1234.5)")
    assert_equal "$1,234.5",  E.eval!("DOLLAR(1234.5, 1)")
    assert_equal true,      E.eval!('EXACT("Word","Word")')
    assert_equal false,     E.eval!('EXACT("Word","word")')
    assert_in_delta 5.0,    E.eval!('FIND("o", "Hello")'), 1e-9
    assert_in_delta 0.0,    E.eval!('FIND("z", "Hello")'), 1e-9
    assert_equal "He",      E.eval!('LEFT("Hello", 2)')
    assert_equal "lo",      E.eval!('RIGHT("Hello", 2)')
    assert_equal "ell",     E.eval!('MID("Hello", 2, 3)')
    assert_in_delta 5.0,    E.eval!('LEN("Hello")'), 1e-9
    assert_equal "hello",   E.eval!('LOWER("HeLLo")')
    assert_equal "HELLO",   E.eval!('UPPER("Hello")')
    assert_equal "This Is", E.eval!('PROPER("THIS IS")')
    assert_equal "Hillo",   E.eval!('REPLACE("Hello", 2, 3, "ill")')
    assert_equal "abab",    E.eval!('REPT("ab", 2)')
    assert_equal "Hello",   E.eval!('SUBSTITUTE("He11o", "1", "l")')
    assert_equal "a b",     E.eval!('TRIM("  a   b  ")')
    assert_in_delta 12.5,   E.eval!('VALUE("12.5")'), 1e-9
  end

  def test_substitute_occurrence
    assert_equal "Hello", E.eval!('SUBSTITUTE("Hello", "l", "x", 0)') # no change
    assert_equal "Hexlo", E.eval!('SUBSTITUTE("Hello", "l", "x", 1)')
    assert_equal "Helxo", E.eval!('SUBSTITUTE("Hello", "l", "x", 2)')
    assert_equal "Hello", E.eval!('SUBSTITUTE("Hello", "l", "x", 3)') # only 2 l's
    assert_equal "Hexxo", E.eval!('SUBSTITUTE("Hello", "l", "x")')
  end

  def test_optionlabel
    c = ctx({ "mat" => "Oak",
              "__meta_mat_options" => "&Pine=Pine&Oak=Oak&Birch=Birch&" })
    assert_equal "Oak", E.eval!('OPTIONLABEL("mat")', c)
    assert_equal 2.0,   E.eval!('OPTIONINDEX("mat")', c)
  end

  def test_env_functions_need_env
    assert_raises(E::Error) { E.eval!("EDGES()", ctx({})) }
    assert_raises(E::Error) { E.eval!("LAT()", ctx({})) }
    calls = []
    env = lambda { |fn, args| calls << [fn, args]; 42.0 }
    c = ctx({}).merge(env: env)
    assert_in_delta 42.0, E.eval!("FACES()", c), 1e-9
    assert_in_delta 42.0, E.eval!('FACEAREA("Oak")', c), 1e-9
    assert_equal [["FACES", []], ["FACEAREA", ["Oak"]]], calls
  end
end
