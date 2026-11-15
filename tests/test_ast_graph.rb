# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../plugins/OpenSketchupDC_OpenDC", __dir__)
require "core/expression"
require "core/ast_graph"

module OpenSketchupDC
  module OpenDC
    class TestAstGraph < Minitest::Test
      def roundtrip(src)
        AstGraph.to_formula(AstGraph.to_graph(src))
      end

      # Semantic round-trip: re-emit must re-parse to an equal AST.
      def assert_semantic(src)
        assert_equal Expression.parse(src),
                     Expression.parse(roundtrip(src)), "for #{src.inspect}"
      end

      def test_simple_attr
        assert_equal "lenx", roundtrip("LenX") # parser lowercases names
      end

      def test_real_formulas
        assert_semantic 'if(CURRENT("RotZ")=-180,"Desno","Levo")'
        assert_semantic "-(parent!zzzOdprto)"
        assert_semantic 'SET("zzzOdprto",0,15,30,45,60,75,90)'
        assert_semantic "round(LenX,1)"
        assert_semantic 'sirina&"/"&visina'
        assert_semantic "a*b+c*d"
        assert_semantic "if(visina>0,round(visina),0)"
      end

      def test_precedence_parens
        assert_equal "a+b*c", roundtrip("a+b*c")
        assert_equal "(a+b)*c", roundtrip("(a+b)*c")
        assert_equal "a-(b-c)", roundtrip("a-(b-c)")
        assert_equal "a-b-c", roundtrip("a-b-c")
        assert_equal "a AND (b OR c)", roundtrip("a AND (b OR c)")
        assert_equal "NOT (a=b)", roundtrip("NOT (a=b)")
        assert_equal "-(a+b)", roundtrip("-(a+b)")
      end

      def test_strings_and_refs
        assert_equal 'x&" cm"', roundtrip('x&" cm"')
        assert_equal "parent!h", roundtrip("parent!h")
        assert_equal 'CURRENT("RotZ")', roundtrip('CURRENT("RotZ")')
      end

      def test_manual_graph_build
        g = {
          "nodes" => {
            "a" => { "t" => "attr", "v" => "lenx" },
            "c" => { "t" => "const", "k" => "num", "v" => "2" },
            "m" => { "t" => "bin", "v" => "*" }
          },
          "links" => [
            { "f" => "a", "t" => "m", "p" => "a" },
            { "f" => "c", "t" => "m", "p" => "b" }
          ],
          "root" => "m"
        }
        assert_equal "lenx*2", AstGraph.to_formula(g)
      end

      def test_unconnected_raises
        g = { "nodes" => { "m" => { "t" => "bin", "v" => "*" } },
              "links" => [], "root" => "m" }
        assert_raises(Expression::Error) { AstGraph.to_formula(g) }
      end
    end
  end
end
