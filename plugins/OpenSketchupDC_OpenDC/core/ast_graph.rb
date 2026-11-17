# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Bidirectional mapper between formula ASTs (Expression.parse output)
    # and a node-graph document edited by the nodes UI.
    #
    # Graph JSON schema (engine-neutral; the JS adapts to/from Rete):
    #   nodes: { id => { "t" => "const|attr|ref|call|un|bin", "v" => payload,
    #                    "k" => "num|str" (const only) } }
    #   links: [ { "f" => from_node_id, "t" => to_node_id,
    #              "p" => "a"|"b"|"x"|"arg0"|"arg1"|... } ]
    #   root:  id of the node producing the final value
    #
    # "f" is the output end, "t" the consuming input port. For bin nodes
    # a=left b=right; for un nodes x=operand; for call nodes argN by index.
    # Pure Ruby - unit-testable.
    module AstGraph
      extend self

      PRECEDENCE = {
        "OR" => 1, "AND" => 2,
        "=" => 3, "<>" => 3, "<" => 3, ">" => 3, "<=" => 3, ">=" => 3,
        "&" => 4, "+" => 5, "-" => 5,
        "*" => 6, "/" => 6, "%" => 6, "^" => 6
      }.freeze
      UN_PREC = 7
      PRIMARY_PREC = 8
      # Right operand needs parens at <= precedence for these ops
      # (a-(b-c) != (a-b)-c; a^(b^c) != (a^b)^c; a=(b=c) non-chainable).
      NON_ASSOC_RIGHT = ["-", "/", "%", "^",
                         "=", "<>", "<", ">", "<=", ">="].freeze

      # Minimum argument count per function for the node editor (functions
      # not listed get one input). Vararg functions get a "+ arg" control.
      FN_ARITY = {
        "IF" => 3, "CHOOSE" => 2, "CURRENT" => 1,
        "AND" => 1, "OR" => 1, "NOT" => 1, "TRUE" => 0, "FALSE" => 0,
        "MIN" => 1, "MAX" => 1, "ROUND" => 1,
        "INT" => 1, "FLOOR" => 1, "CEILING" => 1, "ABS" => 1, "SQRT" => 1,
        "EXP" => 1, "LN" => 1, "LOG10" => 1, "SIGN" => 1,
        "EVEN" => 1, "ODD" => 1, "ISEVEN" => 1, "ISODD" => 1,
        "RAND" => 0, "RANDBETWEEN" => 2,
        "PI" => 0, "DEGREES" => 1, "RADIANS" => 1,
        "SIN" => 1, "COS" => 1, "TAN" => 1,
        "ASIN" => 1, "ACOS" => 1, "ATAN" => 1,
        "SINH" => 1, "COSH" => 1, "TANH" => 1,
        "ASINH" => 1, "ACOSH" => 1, "ATANH" => 1,
        "CHAR" => 1, "CODE" => 1, "CONCATENATE" => 1, "DOLLAR" => 1,
        "EXACT" => 2, "FIND" => 2, "LEFT" => 1, "LEN" => 1, "LOWER" => 1,
        "MID" => 3, "PROPER" => 1, "REPLACE" => 4, "REPT" => 2,
        "RIGHT" => 1, "SUBSTITUTE" => 3, "TRIM" => 1, "UPPER" => 1,
        "VALUE" => 1,
        "LARGEST" => 2, "SMALLEST" => 2, "NEAREST" => 2,
        "OPTIONINDEX" => 1, "OPTIONVALUE" => 2, "OPTIONLABEL" => 1,
        "EDGES" => 0, "FACES" => 0, "FACEAREA" => 0,
        "LAT" => 0, "LNG" => 0, "SUNANGLE" => 0, "SUNELEVATION" => 0
      }.freeze
      FN_VARARG = %w[CHOOSE MIN MAX ROUND LARGEST SMALLEST NEAREST
                     AND OR CONCATENATE].freeze

      # ------------------------------------------------------------------
      # formula string / AST -> graph document
      # ------------------------------------------------------------------
      def to_graph(src)
        ast = src.is_a?(String) ? Expression.parse(Expression.strip_eq(src)) : src
        nodes = {}
        links = []
        counter = 0
        walk = nil
        walk = lambda do |n|
          id = "n#{counter += 1}"
          case n[0]
          when :num then nodes[id] = { "t" => "const", "k" => "num", "v" => n[1].to_s }
          when :str then nodes[id] = { "t" => "const", "k" => "str", "v" => n[1] }
          when :var then nodes[id] = { "t" => "attr", "v" => n[1] }
          when :ref then nodes[id] = { "t" => "ref", "v" => "#{n[1]}!#{n[2]}" }
          when :un
            c = walk.call(n[2])
            nodes[id] = { "t" => "un", "v" => n[1] }
            links << { "f" => c, "t" => id, "p" => "x" }
          when :bin
            l = walk.call(n[2])
            r = walk.call(n[3])
            nodes[id] = { "t" => "bin", "v" => n[1] }
            links << { "f" => l, "t" => id, "p" => "a" }
            links << { "f" => r, "t" => id, "p" => "b" }
          when :call
            args = n[2].map { |a| walk.call(a) }
            nodes[id] = { "t" => "call", "v" => n[1] }
            args.each_with_index { |a, i| links << { "f" => a, "t" => id, "p" => "arg#{i}" } }
          else
            raise Expression::Error, "bad AST node #{n[0]}"
          end
          id
        end
        root = walk.call(ast)
        { "nodes" => nodes, "links" => links, "root" => root }
      end

      # ------------------------------------------------------------------
      # graph document -> formula string
      # ------------------------------------------------------------------
      def to_formula(graph)
        nodes = graph["nodes"] || {}
        links = graph["links"] || []
        in_map = {}
        links.each { |l| in_map[[l["t"], l["p"].to_s]] = l["f"] }
        fed = {}
        links.each { |l| fed[l["f"]] = true }
        root = graph["root"] || (nodes.keys - fed.keys).first
        raise Expression::Error, "empty graph" if root.nil?

        emit_node(root, nodes, in_map).first
      end

      private

      def emit_port(nodes, in_map, id, port)
        src = in_map[[id, port]]
        raise Expression::Error, "unconnected input #{port} on node #{id}" if src.nil?

        emit_node(src, nodes, in_map)
      end

      # Returns [text, precedence]. Children are parenthesized only when
      # their precedence is lower than the operator demands.
      def emit_node(id, nodes, in_map)
        n = nodes[id]
        raise Expression::Error, "unknown node #{id}" if n.nil?

        case n["t"]
        when "const"
          [n["k"] == "str" ? %("#{n['v'].to_s.gsub('"', '')}") : n["v"].to_s, PRIMARY_PREC]
        when "attr", "ref"
          [n["v"].to_s, PRIMARY_PREC]
        when "un"
          s, p = emit_port(nodes, in_map, id, "x")
          inner = p < UN_PREC ? "(#{s})" : s
          op = n["v"].to_s
          [op == "NOT" ? "NOT #{inner}" : "#{op}#{inner}", UN_PREC]
        when "bin"
          op = n["v"].to_s
          pr = PRECEDENCE.fetch(op) { raise Expression::Error, "unknown operator '#{op}'" }
          ls, lp = emit_port(nodes, in_map, id, "a")
          rs, rp = emit_port(nodes, in_map, id, "b")
          left = lp < pr ? "(#{ls})" : ls
          right = (NON_ASSOC_RIGHT.include?(op) ? rp <= pr : rp < pr) ? "(#{rs})" : rs
          text_op = %w[AND OR].include?(op) ? " #{op} " : op
          ["#{left}#{text_op}#{right}", pr]
        when "call"
          args = in_map.keys.select { |k| k[0] == id && k[1].start_with?("arg") }
                   .sort_by { |k| k[1][3..].to_i }
          fn = n["v"].to_s
          if args.empty? && FN_ARITY.fetch(fn.upcase, 1) > 0
            raise Expression::Error, "#{fn} has no arguments"
          end

          texts = args.map { |k| emit_node(in_map[k], nodes, in_map).first }
          ["#{fn}(#{texts.join(',')})", PRIMARY_PREC]
        else
          raise Expression::Error, "unknown node type #{n['t']}"
        end
      end
    end
  end
end
