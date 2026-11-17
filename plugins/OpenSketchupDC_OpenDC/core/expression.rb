# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

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
    #   funcs:   the classic DC catalogue - math, text, trig, logical,
    #            SketchUp-model and option functions (see FUNCTIONS)
    #
    # Context protocol (injected by the engine):
    #   get:  ->(name)        # sibling attribute on same entity
    #   ref:  ->(scope, name) # parent!/global!/name! references
    #   meta: ->(name, field) # attribute meta (for OPTION*/CURRENT)
    #   env:  ->(fn, args)    # model functions (EDGES LAT SUNANGLE ...)
    #   fx:   ->(fn, args)    # onClick actions (SET ANIMATE* ...)
    module Expression
      class Error < StandardError; end

      Token = Struct.new(:type, :value)

      # Human-readable names so parse errors can name what was found.
      TOKEN_NAMES = {
        rparen: "')'", lparen: "'('", comma: "','", bang: "'!'",
        op: "an operator", ident: "a name", num: "a number",
        str: "a string", eof: "end of input"
      }.freeze

      LENGTH_UNITS = {
        "mm" => 1.0 / 25.4, "cm" => 1.0 / 2.54, "m" => 100.0 / 2.54,
        "in" => 1.0, '"' => 1.0, "ft" => 12.0, "'" => 12.0,
        "deg" => 1.0, "degrees" => 1.0
      }.freeze

      module_function

      def describe_token(t)
        t.type == :eof ? "end of input" : "'#{t.value}'"
      end

      def describe_type(type)
        TOKEN_NAMES[type] || type.to_s
      end

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
            # TRUE/FALSE stay idents so `TRUE()` can parse as a call;
            # ident_expr folds the bare word back to a number literal.
            tokens << case word.upcase
                      when "AND", "OR", "NOT" then Token.new(:op, word.upcase)
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
          unless peek.type == :eof
            raise Error, "unexpected #{Expression.describe_token(peek)}"
          end

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
          unless t.type == type
            raise Error, "expected #{Expression.describe_type(type)} " \
                         "but found #{Expression.describe_token(t)}"
          end

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
          when :op
            # AND(...) / OR(...) function form (NOT is handled in unary,
            # where `NOT x` and `NOT(x)` already work).
            if %w[AND OR].include?(t.value) && @t[@i + 1]&.type == :lparen
              next!
              return [:call, t.value, call_args]
            end
            raise Error, "unexpected #{Expression.describe_token(t)}"
          when :lparen
            next!
            e = expr
            expect(:rparen)
            e
          else
            raise Error, "unexpected #{Expression.describe_token(t)}"
          end
        end

        def ident_expr(name)
          next!
          if peek.type == :bang
            next!
            n2 = next!
            unless n2.type == :ident
              raise Error, "expected an attribute name after '#{name}!'"
            end

            return [:ref, name.downcase, n2.value.downcase]
          end
          return [:call, name.upcase, call_args] if peek.type == :lparen

          up = name.upcase
          return [:num, up == "TRUE" ? 1.0 : 0.0] if %w[TRUE FALSE].include?(up)

          [:var, name.downcase]
        end

        # `(arg, arg, ...)` - the lparen is consumed here.
        def call_args
          expect(:lparen)
          args = []
          args << expr unless peek.type == :rparen
          args << expr while match_type(:comma)
          expect(:rparen)
          args
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

      # Functions the evaluator understands (classic DC catalogue). Kept
      # next to eval_call's dispatch for validation: formula builders reject
      # unknown function names before the formula is stored.
      FUNCTIONS = %w[
        IF CHOOSE CURRENT
        AND OR NOT TRUE FALSE
        MIN MAX ROUND INT FLOOR CEILING ABS SQRT EXP LN LOG10 SIGN
        EVEN ODD ISEVEN ISODD RAND RANDBETWEEN
        PI DEGREES RADIANS
        SIN COS TAN ASIN ACOS ATAN SINH COSH TANH ASINH ACOSH ATANH
        CHAR CODE CONCATENATE DOLLAR EXACT FIND LEFT LEN LOWER MID PROPER
        REPLACE REPT RIGHT SUBSTITUTE TRIM UPPER VALUE
        LARGEST SMALLEST NEAREST
        OPTIONINDEX OPTIONVALUE OPTIONLABEL
        EDGES FACES FACEAREA LAT LNG SUNANGLE SUNELEVATION
      ].freeze

      class Evaluator
        # DC action functions (side effects). Handled via ctx[:fx] - a pure
        # eval context must not run them.
        ACTIONS = %w[SET ANIMATE ANIMATESLOW ANIMATEFAST ANIMATECUSTOM
                     REDRAW ALERT GOTOSCENE].freeze

        # Functions that read the SketchUp model rather than attribute
        # values; resolved through ctx[:env].
        ENV_FUNCTIONS = %w[EDGES FACES FACEAREA LAT LNG SUNANGLE
                           SUNELEVATION].freeze

        def initialize(ctx = {})
          @get  = ctx[:get]  || ->(n) { raise Error, "undefined attribute '#{n}'" }
          @ref  = ctx[:ref]  || ->(s, n) { raise Error, "undefined reference '#{s}!#{n}'" }
          @meta = ctx[:meta] || ->(_n, _f) { nil }
          @env  = ctx[:env]
          @fx   = ctx[:fx]
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
          # ---- logic --------------------------------------------------------
          when "IF"
            raise Error, "IF needs 3 arguments" unless args.length == 3

            truthy(eval_node(args[0])) ? eval_node(args[1]) : eval_node(args[2])
          when "AND"   then args.all? { |a| truthy(eval_node(a)) }
          when "OR"    then args.any? { |a| truthy(eval_node(a)) }
          when "NOT"   then !truthy(eval_node(args[0]))
          # Match the bare literals, which fold to 1.0 / 0.0 - keeps
          # `TRUE() = TRUE` comparisons and arithmetic consistent.
          when "TRUE"  then 1.0
          when "FALSE" then 0.0
          # ---- SketchUp / option --------------------------------------------
          when "CHOOSE"
            raise Error, "CHOOSE needs >= 2 arguments" if args.length < 2

            idx = num(eval_node(args[0])).to_i.clamp(1, args.length - 1)
            eval_node(args[idx])
          when "CURRENT" then @get.call(arg_str(args[0]))
          when "LARGEST", "SMALLEST"
            raise Error, "#{fn} needs >= 2 arguments" if args.length < 2

            k = num(eval_node(args[-1])).to_i
            vals = args[0..-2].map { |a| num(eval_node(a)) }.sort
            fn == "LARGEST" ? vals[-k] : vals[k - 1]
          when "NEAREST"
            raise Error, "NEAREST needs >= 2 arguments" if args.length < 2

            target = num(eval_node(args[0]))
            args[1..].map { |a| num(eval_node(a)) }
                     .min_by { |v| (v - target).abs }
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
          when "OPTIONLABEL"
            an = arg_str(args[0])
            cur = @get.call(an)
            opt = option_list(an).find { |o| loose_eq(o[1], cur) }
            opt && opt[0]
          # ---- math -----------------------------------------------------------
          when "MIN", "MAX"
            vals = args.map { |a| num(eval_node(a)) }
            fn == "MIN" ? vals.min : vals.max
          when "ROUND"
            nd = args.length > 1 ? num(eval_node(args[1])).to_i : 0
            num(eval_node(args[0])).round(nd).to_f
          when "INT" then num(eval_node(args[0])).floor
          when "FLOOR", "CEILING"
            v = num(eval_node(args[0]))
            if args.length > 1
              sig = num(eval_node(args[1]))
              raise Error, "#{fn} significance cannot be 0" if sig.zero?

              q = v / sig
              fn == "FLOOR" ? (q.floor * sig).round(9) : (q.ceil * sig).round(9)
            else
              fn == "FLOOR" ? v.floor : v.ceil
            end
          when "ABS"     then num(eval_node(args[0])).abs
          when "SQRT"    then domain { Math.sqrt(num(eval_node(args[0]))) }
          when "EXP"     then Math.exp(num(eval_node(args[0])))
          when "LN"
            v = num(eval_node(args[0]))
            raise Error, "LN requires a number > 0" unless v.positive?

            Math.log(v)
          when "LOG10"
            v = num(eval_node(args[0]))
            raise Error, "LOG10 requires a number > 0" unless v.positive?

            Math.log10(v)
          when "SIGN"    then num(eval_node(args[0])) <=> 0
          when "EVEN", "ODD"
            v = num(eval_node(args[0]))
            r = v.negative? ? v.floor : v.ceil
            bump = fn == "EVEN" ? r.odd? : r.even?
            r += v.negative? ? -1 : 1 if bump
            r
          when "ISEVEN"  then num(eval_node(args[0])).to_i.even?
          when "ISODD"   then num(eval_node(args[0])).to_i.odd?
          when "RAND"    then rand
          when "RANDBETWEEN"
            lo, hi = args.map { |a| num(eval_node(a)).to_i }
            raise Error, "RANDBETWEEN needs bottom <= top" if lo > hi

            rand(lo..hi)
          # ---- trig (degrees, like classic DC) ---------------------------------
          when "SIN"     then Math.sin(num(eval_node(args[0])) * Math::PI / 180.0)
          when "COS"     then Math.cos(num(eval_node(args[0])) * Math::PI / 180.0)
          when "TAN"     then Math.tan(num(eval_node(args[0])) * Math::PI / 180.0)
          when "ASIN"    then domain { Math.asin(num(eval_node(args[0]))) * 180.0 / Math::PI }
          when "ACOS"    then domain { Math.acos(num(eval_node(args[0]))) * 180.0 / Math::PI }
          when "ATAN"    then Math.atan(num(eval_node(args[0]))) * 180.0 / Math::PI
          when "SINH"    then Math.sinh(num(eval_node(args[0])) * Math::PI / 180.0)
          when "COSH"    then Math.cosh(num(eval_node(args[0])) * Math::PI / 180.0)
          when "TANH"    then Math.tanh(num(eval_node(args[0])) * Math::PI / 180.0)
          when "ASINH"   then Math.asinh(num(eval_node(args[0]))) * 180.0 / Math::PI
          when "ACOSH"   then domain { Math.acosh(num(eval_node(args[0]))) * 180.0 / Math::PI }
          when "ATANH"   then domain { Math.atanh(num(eval_node(args[0]))) * 180.0 / Math::PI }
          when "PI"      then Math::PI
          when "DEGREES" then num(eval_node(args[0])) * 180.0 / Math::PI
          when "RADIANS" then num(eval_node(args[0])) * Math::PI / 180.0
          # ---- text --------------------------------------------------------------
          when "CONCATENATE" then args.map { |a| str(eval_node(a)) }.join
          when "CHAR"   then num(eval_node(args[0])).to_i.chr
          when "CODE"
            s = str(eval_node(args[0]))
            raise Error, "CODE needs a non-empty string" if s.empty?

            s[0].ord
          when "DOLLAR"
            v = num(eval_node(args[0]))
            nd = args.length > 1 ? num(eval_node(args[1])).to_i : 2
            i, f = format("%.#{[nd, 0].max}f", v.round(nd)).split(".")
            i = i.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse
            "$#{i}#{f ? '.' + f : ''}"
          when "EXACT"  then str(eval_node(args[0])) == str(eval_node(args[1]))
          when "FIND"
            needle = str(eval_node(args[0]))
            hay = str(eval_node(args[1]))
            from = args.length > 2 ? [num(eval_node(args[2])).to_i - 1, 0].max : 0
            idx = hay.index(needle, from)
            idx ? idx + 1 : 0
          when "LEFT"
            s = str(eval_node(args[0]))
            n = args.length > 1 ? num(eval_node(args[1])).to_i : 1
            s[0, [n, 0].max] || ""
          when "RIGHT"
            s = str(eval_node(args[0]))
            n = args.length > 1 ? num(eval_node(args[1])).to_i : 1
            n <= 0 ? "" : (s[-n..] || s)
          when "MID"
            s = str(eval_node(args[0]))
            start = num(eval_node(args[1])).to_i - 1
            n = num(eval_node(args[2])).to_i
            start.negative? || n.negative? ? "" : (s[start, n] || "")
          when "LEN"   then str(eval_node(args[0])).length
          when "LOWER" then str(eval_node(args[0])).downcase
          when "UPPER" then str(eval_node(args[0])).upcase
          when "PROPER"
            str(eval_node(args[0])).gsub(/[A-Za-z]+/, &:capitalize)
          when "REPLACE"
            s = str(eval_node(args[0])).dup
            start = num(eval_node(args[1])).to_i - 1
            n = num(eval_node(args[2])).to_i
            raise Error, "REPLACE start must be >= 1" if start.negative?

            s[start, [n, 0].max] = str(eval_node(args[3]))
            s
          when "REPT"
            n = num(eval_node(args[1])).to_i
            raise Error, "REPT count must be >= 0" if n.negative?

            str(eval_node(args[0])) * n
          when "SUBSTITUTE"
            s = str(eval_node(args[0]))
            old = str(eval_node(args[1]))
            repl = str(eval_node(args[2]))
            if args.length > 3
              substitute_nth(s, old, repl, num(eval_node(args[3])).to_i)
            else
              s.gsub(old, repl)
            end
          when "TRIM"  then str(eval_node(args[0])).gsub(/\s+/, " ").strip
          when "VALUE" then num(eval_node(args[0]))
          else
            if ENV_FUNCTIONS.include?(fn)
              raise Error, "#{fn} requires SketchUp model context" if @env.nil?

              return @env.call(fn, args.map { |a| eval_node(a) })
            end
            if ACTIONS.include?(fn)
              raise Error, "#{fn} requires an onClick action context" if @fx.nil?

              return @fx.call(fn, args.map { |a| eval_node(a) })
            end
            raise Error, "unknown function '#{fn}'"
          end
        end

        def substitute_nth(s, old, repl, occ)
          return s if occ < 1 || old.empty?

          idx = -1
          occ.times do
            idx = s.index(old, idx + 1)
            return s unless idx
          end
          s.dup.tap { |x| x[idx, old.length] = repl }
        end

        def domain
          yield
        rescue Math::DomainError => e
          raise Error, e.message
        end

        def option_list(attr_name)
          @meta.call(attr_name, "options").to_s.split("&").filter_map do |pair|
            k, v = pair.split("=", 2)
            next if k.to_s.empty?

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
            if %w[CURRENT OPTIONINDEX OPTIONVALUE OPTIONLABEL].include?(node[1]) &&
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
