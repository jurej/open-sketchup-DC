module OpenSketchupDC
  module OpenDC
    # Sandboxed formula parser + evaluator for the Open DC engine.
    # No Ruby eval() - formulas run through a small interpreter, which keeps
    # them deterministic and safe to embed in shared components.
    #
    # Language (DC-compatible subset):
    #   numbers: 12, 12.5, 10cm, 25mm, 2m, 4in, 4", 6ft, 6'
    #   strings: "hello"   concat: "a" & "b"
    #   math:    + - * / % ^ ( )
    #   compare: = <> < > <= >=   logic: AND OR NOT
    #   refs:    attr  parent!attr  global!attr  siblingname!attr
    #   funcs:   IF CHOOSE CURRENT MIN MAX ROUND INT FLOOR CEILING ABS SQRT
    #            SIN COS TAN ASIN ACOS ATAN PI DEGREES RADIANS
    #            LARGEST SMALLEST OPTIONINDEX OPTIONVALUE
    #
    # Context protocol (injected by the engine):
    #   get:  ->(name)        # sibling attribute on same entity
    #   ref:  ->(scope, name) # parent!/global!/name! references
    #   meta: ->(name, field) # attribute meta (for OPTIONINDEX/OPTIONVALUE)
    module Expression
      class Error < StandardError; end

      Token = Struct.new(:type, :value)

      LENGTH_UNITS = {
        "mm" => 1.0 / 25.4, "cm" => 1.0 / 2.54, "m" => 100.0 / 2.54,
        "in" => 1.0, '"' => 1.0, "ft" => 12.0, "'" => 12.0,
        "deg" => 1.0, "degrees" => 1.0
      }.freeze

      module_function

      # ------------------------------------------------------------------
      # Lexer
      # ------------------------------------------------------------------
      def lex(src)
        s = src.to_s
        tokens = []
        i = 0
        while i < s.length
          c = s[i]
          case c
          when /\s/
            i += 1
          when /[\d.]/
            m = s.match(/\G(?:\d+\.?\d*|\.\d+)/, i)
            raise Error, "bad number at #{i}" unless m

            num = m[0].to_f
            i += m[0].length
            num, i = lex_unit(s, i, num)
            tokens << Token.new(:num, num)
          when '"'
            j = i + 1
            str = +""
            str << s[j] and j += 1 while j < s.length && s[j] != '"'
            raise Error, "unterminated string" if j >= s.length

            tokens << Token.new(:str, str)
            i = j + 1
          when /[A-Za-z_]/
            m = s.match(/\G[A-Za-z_][A-Za-z0-9_]*/, i)
            word = m[0]
            i += word.length
            tokens << case word.upcase
                      when "AND", "OR", "NOT" then Token.new(:op, word.upcase)
                      when "TRUE"  then Token.new(:num, 1.0)
                      when "FALSE" then Token.new(:num, 0.0)
                      else Token.new(:ident, word)
                      end
          when "!"
            if s[i + 1] == "="
              tokens << Token.new(:op, "<>")
              i += 2
            else
              tokens << Token.new(:bang)
              i += 1
            end
          when "="
            i += 1 while s[i + 1] == "="
            tokens << Token.new(:op, "=")
            i += 1
          when "<", ">"
            op = c
            op << s[i + 1] if s[i + 1] == "=" || (c == "<" && s[i + 1] == ">")
            tokens << Token.new(:op, op)
            i += op.length
          when "+", "-", "*", "/", "%", "^", "&"
            tokens << Token.new(:op, c)
            i += 1
          when "(" then tokens << Token.new(:lparen)
                        i += 1
          when ")" then tokens << Token.new(:rparen)
                        i += 1
          when "," then tokens << Token.new(:comma)
                        i += 1
          else
            raise Error, "unexpected character '#{c}'"
          end
        end
        tokens << Token.new(:eof)
        tokens
      end

      # Unit suffix directly after a number literal (adjacent only).
      def lex_unit(s, i, num)
        return [num, i] if i >= s.length

        c = s[i]
        return [num * LENGTH_UNITS[c], i + 1] if ['"', "'"].include?(c)
        return [num, i] unless c =~ /[A-Za-z]/

        m = s.match(/\G[A-Za-z]+/, i)
        unit = m[0].downcase
        factor = LENGTH_UNITS[unit]
        raise Error, "unknown unit '#{unit}'" unless factor

        [num * factor, i + m[0].length]
      end

      # ------------------------------------------------------------------
      # Parser -> AST
      #   [:num v] [:str s] [:var name] [:ref scope name]
      #   [:un op e] [:bin op l r] [:call fn [args]]
      # ------------------------------------------------------------------
      class Parser
        def initialize(tokens)
          @t = tokens
          @i = 0
        end

        def parse
          ast = expr
          raise Error, "trailing tokens" unless peek.type == :eof

          ast
        end

        private

        def peek = @t[@i]

        def next!
          t = @t[@i]
          @i += 1
          t
        end

        def expect(type)
          t = next!
          raise Error, "expected #{type}, got #{t.type}" unless t.type == type

          t
        end

        def expr = or_expr

        def or_expr
          l = and_expr
          l = [:bin, "OR", l, and_expr] while match_op("OR")
          l
        end

        def and_expr
          l = cmp_expr
          l = [:bin, "AND", l, cmp_expr] while match_op("AND")
          l
        end

        def cmp_expr
          l = concat_expr
          if peek.type == :op && %w[= <> < > <= >=].include?(peek.value)
            op = next!.value
            return [:bin, op, l, concat_expr]
          end
          l
        end

        def concat_expr
          l = add_expr
          l = [:bin, "&", l, add_expr] while match_op("&")
          l
        end

        def add_expr
          l = mul_expr
          while peek.type == :op && %w[+ -].include?(peek.value)
            op = next!.value
            l = [:bin, op, l, mul_expr]
          end
          l
        end

        def mul_expr
          l = unary
          while peek.type == :op && %w[* / % ^].include?(peek.value)
            op = next!.value
            l = [:bin, op, l, unary]
          end
          l
        end

        def unary
          if peek.type == :op && %w[- + NOT].include?(peek.value)
            op = next!.value
            return [:un, op, unary]
          end
          primary
        end

        def primary
          t = peek
          case t.type
          when :num then next! && [:num, t.value]
          when :str then next! && [:str, t.value]
          when :ident then ident_expr(t.value)
          when :lparen
            next!
            e = expr
            expect(:rparen)
            e
          else
            raise Error, "unexpected #{t.type} '#{t.value}'"
          end
        end

        def ident_expr(name)
          next!
          if peek.type == :bang
            next!
            n2 = next!
            raise Error, "expected attribute after !" unless n2.type == :ident

            return [:ref, name.downcase, n2.value.downcase]
          end
          if peek.type == :lparen
            next!
            args = []
            args << expr unless peek.type == :rparen
            args << expr while match_type(:comma)
            expect(:rparen)
            return [:call, name.upcase, args]
          end
          [:var, name.downcase]
        end

        def match_op(op)
          return false unless peek.type == :op && peek.value == op

          next!
          true
        end

        def match_type(type)
          return false unless peek.type == type

          next!
          true
        end
      end

      def parse(src)
        Parser.new(lex(src)).parse
      end

      # ------------------------------------------------------------------
      # Evaluator
      # ------------------------------------------------------------------
      class Evaluator
        def initialize(ctx = {})
          @get  = ctx[:get]  || ->(n) { raise Error, "undefined attribute '#{n}'" }
          @ref  = ctx[:ref]  || ->(s, n) { raise Error, "undefined reference '#{s}!#{n}'" }
          @meta = ctx[:meta] || ->(_n, _f) { nil }
        end

        def eval_node(node)
          case node[0]
          when :num then node[1]
          when :str then node[1]
          when :var then @get.call(node[1])
          when :ref then @ref.call(node[1], node[2])
          when :un  then eval_un(node[1], node[2])
          when :bin then eval_bin(node[1], node[2], node[3])
          when :call then eval_call(node[1], node[2])
          else raise Error, "bad node #{node[0]}"
          end
        end

        private

        def eval_un(op, node)
          v = eval_node(node)
          case op
          when "-"  then -num(v)
          when "+"  then num(v)
          when "NOT" then !truthy(v)
          end
        end

        def eval_bin(op, l_node, r_node)
          l = eval_node(l_node)
          r = eval_node(r_node)
          case op
          when "+"  then num(l) + num(r)
          when "-"  then num(l) - num(r)
          when "*"  then num(l) * num(r)
          when "/"  then num(l) / num(r)
          when "%"  then num(l) % num(r)
          when "^"  then num(l)**num(r)
          when "&"  then str(l) + str(r)
          when "AND" then truthy(l) && truthy(r)
          when "OR"  then truthy(l) || truthy(r)
          else compare(op, l, r)
          end
        end

        def compare(op, l, r)
          c = cmp(l, r)
          case op
          when "="  then c.zero?
          when "<>" then c != 0
          when "<"  then c.negative?
          when ">"  then c.positive?
          when "<=" then c <= 0
          when ">=" then c >= 0
          end
        end

        def cmp(l, r)
          if numeric?(l) && numeric?(r)
            num(l) <=> num(r)
          else
            l.to_s.downcase <=> r.to_s.downcase
          end
        end

        def eval_call(fn, args)
          case fn
          when "IF"
            raise Error, "IF needs 3 arguments" unless args.length == 3

            truthy(eval_node(args[0])) ? eval_node(args[1]) : eval_node(args[2])
          when "CHOOSE"
            raise Error, "CHOOSE needs >= 2 arguments" if args.length < 2

            idx = num(eval_node(args[0])).to_i.clamp(1, args.length - 1)
            eval_node(args[idx])
          when "CURRENT" then @get.call(arg_str(args[0]))
          when "MIN", "MAX"
            vals = args.map { |a| num(eval_node(a)) }
            fn == "MIN" ? vals.min : vals.max
          when "ROUND"
            nd = args.length > 1 ? num(eval_node(args[1])).to_i : 0
            num(eval_node(args[0])).round(nd).to_f
          when "INT"     then num(eval_node(args[0])).to_i
          when "FLOOR"   then num(eval_node(args[0])).floor
          when "CEILING" then num(eval_node(args[0])).ceil
          when "ABS"     then num(eval_node(args[0])).abs
          when "SQRT"    then Math.sqrt(num(eval_node(args[0])))
          when "SIN"     then Math.sin(num(eval_node(args[0])) * Math::PI / 180.0)
          when "COS"     then Math.cos(num(eval_node(args[0])) * Math::PI / 180.0)
          when "TAN"     then Math.tan(num(eval_node(args[0])) * Math::PI / 180.0)
          when "ASIN"    then Math.asin(num(eval_node(args[0]))) * 180.0 / Math::PI
          when "ACOS"    then Math.acos(num(eval_node(args[0]))) * 180.0 / Math::PI
          when "ATAN"    then Math.atan(num(eval_node(args[0]))) * 180.0 / Math::PI
          when "PI"      then Math::PI
          when "DEGREES" then num(eval_node(args[0])) * 180.0 / Math::PI
          when "RADIANS" then num(eval_node(args[0])) * Math::PI / 180.0
          when "LARGEST", "SMALLEST"
            raise Error, "#{fn} needs >= 2 arguments" if args.length < 2

            k = num(eval_node(args[-1])).to_i
            vals = args[0..-2].map { |a| num(eval_node(a)) }.sort
            fn == "LARGEST" ? vals[-k] : vals[k - 1]
          when "OPTIONINDEX"
            an = arg_str(args[0])
            opts = option_list(an)
            cur = @get.call(an)
            idx = opts.index { |o| loose_eq(o[1], cur) }
            idx ? idx + 1 : nil
          when "OPTIONVALUE"
            an = arg_str(args[0])
            label = eval_node(args[1]).to_s
            opt = option_list(an).find { |o| o[0] == label }
            opt && opt[1]
          else
            raise Error, "unknown function '#{fn}'"
          end
        end

        def option_list(attr_name)
          @meta.call(attr_name, "options").to_s.split("&").map do |pair|
            k, v = pair.split("=", 2)
            [Param.url_decode(k.to_s), Param.url_decode(v.to_s)]
          end
        end

        def arg_str(node)
          v = node[0] == :str ? node[1] : eval_node(node)
          v.to_s.downcase
        end

        def loose_eq(a, b)
          cmp(a, b).zero?
        end

        def numeric?(v)
          v.is_a?(Numeric) ||
            (v.is_a?(String) && v.strip =~ /\A-?\d+(\.\d+)?\z/)
        end

        def num(v)
          return v.to_f if v.is_a?(Numeric)
          return v.strip.to_f if numeric?(v)

          raise Error, "'#{v}' is not a number"
        end

        def truthy(v)
          return false if v.nil? || v == false || v == ""
          return v != 0 if v.is_a?(Numeric)

          true
        end

        def str(v)
          v.is_a?(String) ? v : fmt(v)
        end

        def fmt(v)
          v.is_a?(Float) && v == v.to_i ? v.to_i.to_s : v.to_s
        end
      end

      # ------------------------------------------------------------------
      # Public API
      # ------------------------------------------------------------------
      def eval!(src, ctx = {})
        Evaluator.new(ctx).eval_node(parse(strip_eq(src)))
      end

      # Dependency names referenced by a formula: [[scope|nil, attr], ...]
      # scope nil => local attribute; "parent"/"global"/<node> otherwise.
      def refs(src)
        ast = parse(strip_eq(src))
        deps = []
        walk(ast) do |node|
          case node[0]
          when :var then deps << [nil, node[1]]
          when :ref then deps << [node[1], node[2]]
          when :call
            if %w[CURRENT OPTIONINDEX OPTIONVALUE].include?(node[1]) &&
               node[2][0].is_a?(Array) && node[2][0][0] == :str
              deps << [nil, node[2][0][1].downcase]
            end
          end
        end
        deps.uniq
      rescue Error
        []
      end

      # Users type "=..."; stored formulas may also carry a leading =.
      def strip_eq(src)
        src.to_s.sub(/\A\s*=/, "")
      end

      def walk(node, &block)
        return unless node.is_a?(Array)

        yield node
        node.each { |child| walk(child, &block) if child.is_a?(Array) }
      end
    end
  end
end
