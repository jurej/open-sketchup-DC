module OpenSketchupDC
  module OpenDC
    # A single dynamic parameter plus its meta-attributes.
    # Pure Ruby - no SketchUp API dependencies, so it is unit-testable.
    class Param
      ACCESS_NONE    = "NONE".freeze
      ACCESS_VIEW    = "VIEW".freeze
      ACCESS_TEXTBOX = "TEXTBOX".freeze
      ACCESS_LIST    = "LIST".freeze
      ACCESS_LEVELS  = [ACCESS_NONE, ACCESS_VIEW, ACCESS_TEXTBOX, ACCESS_LIST].freeze

      # Internal storage is always inches; _<attr>_units is only a display
      # unit. DEGREES/FLOAT/INTEGER/STRING/BOOLEAN pass through unchanged.
      LENGTH_UNITS = %w[INCHES CENTIMETERS MILLIMETERS METERS FEET].freeze

      def self.length_unit?(units)
        LENGTH_UNITS.include?(units.to_s.upcase)
      end

      def self.inches_to_unit(inches, units)
        case units.to_s.upcase
        when "CENTIMETERS" then inches * 2.54
        when "MILLIMETERS" then inches * 25.4
        when "METERS"      then inches * 0.0254
        when "FEET"        then inches / 12.0
        else inches
        end
      end

      def self.unit_to_inches(value, units)
        case units.to_s.upcase
        when "CENTIMETERS" then value / 2.54
        when "MILLIMETERS" then value / 25.4
        when "METERS"      then value / 0.0254
        when "FEET"        then value * 12.0
        else value
        end
      end

      attr_accessor :name, :value, :default, :label, :formlabel,
                    :formula, :formulaunits, :access, :options, :units,
                    :overridden, :internal, :error

      def initialize(name, attrs = {})
        @name = name.to_s.downcase
        @value        = attrs[:value]
        @default      = attrs.key?(:default) ? attrs[:default] : attrs[:value]
        @label        = attrs[:label]
        @formlabel    = attrs[:formlabel]
        @formula      = attrs[:formula]
        @formulaunits = attrs[:formulaunits]
        @access       = normalize_access(attrs[:access])
        @options      = attrs[:options]
        @units        = attrs[:units]
        @overridden   = attrs.fetch(:overridden, false)
        @internal     = attrs.fetch(:internal, false)
        @error        = attrs[:error]
      end

      def configurable?
        [ACCESS_VIEW, ACCESS_TEXTBOX, ACCESS_LIST].include?(@access)
      end

      def editable?
        [ACCESS_TEXTBOX, ACCESS_LIST].include?(@access)
      end

      def list?
        @access == ACCESS_LIST
      end

      def formula?
        !@formula.to_s.empty?
      end

      def internal?
        !!@internal
      end

      # Value converted to the attribute's display unit (inches -> units).
      # Numeric only; everything else passes through.
      def display_value
        v = numeric_value(@value)
        return @value if v.nil? || !Param.length_unit?(@units)

        Param.inches_to_unit(v, @units)
      end

      def overridden?
        !!@overridden
      end

      def display_name
        if @formlabel.to_s.empty?
          @label.to_s.empty? ? @name : @label
        else
          @formlabel
        end
      end

      # Options string format: "Label=value&Other=v2" (URL-encoded).
      # Real DCs write it "&a=1&b=2&" - stray & produce empty pairs, skip them.
      def parsed_options
        return [] if @options.to_s.empty?

        @options.split("&").filter_map do |pair|
          next if pair.empty?

          k, v = pair.split("=", 2)
          { "label" => Param.url_decode(k.to_s), "value" => Param.url_decode(v.to_s) }
        end
      end

      def self.url_decode(str)
        str.to_s.gsub("+", " ").gsub(/%([0-9A-Fa-f]{2})/) do
          Regexp.last_match(1).hex.chr(Encoding::UTF_8)
        end
      end

      def self.url_encode(str)
        str.to_s.gsub(/[^A-Za-z0-9_.~-]/) { |c| format("%%%02X", c.ord) }
      end

      def self.encode_options(pairs)
        pairs.map do |label, value|
          "#{url_encode(label)}=#{url_encode(value)}"
        end.join("&")
      end

      # Classic DC formula storage: only &quot; is unescaped when DC reads a
      # _<name>_formula slot. &amp; / &lt; / &gt; are treated as literal text
      # and break evaluation (verified by live redraw). On READ we decode the
      # whole entity set anyway - &amp; last - so previously double-escaped or
      # foreign-written formulas still display and can be re-saved raw.
      def self.unescape_html(v)
        return v unless v.is_a?(String) && v.include?("&")

        v.gsub("&quot;", '"').gsub("&gt;", ">").gsub("&lt;", "<")
         .gsub("&#39;", "'").gsub("&apos;", "'")
         .gsub("&amp;", "&")
      end

      # Write-side counterpart: escape ONLY the double-quote. Storing & as
      # &amp; (or <> as &lt;/&gt;) makes DC evaluate the literal "amp;"/"lt;"
      # text and error; & and <> must be stored raw.
      def self.escape_html(v)
        return v unless v.is_a?(String)

        v.gsub('"', "&quot;")
      end

      # _<attr>_error holds eval status, often as an HTML span such as
      # <span class=subformula-success>80.0</span> - strip tags for display.
      def self.strip_markup(v)
        return v unless v.is_a?(String) && v.include?("<")

        v.gsub(/<[^>]*>/, "")
      end

      def to_h
        {
          "name" => @name,
          "value" => @value,
          "default" => @default,
          "label" => @label,
          "formlabel" => @formlabel,
          "displayName" => display_name,
          "formula" => @formula,
          "formulaunits" => @formulaunits,
          "access" => @access,
          "options" => @options,
          "optionsList" => parsed_options,
          "units" => @units,
          "displayValue" => display_value,
          "overridden" => @overridden,
          "internal" => @internal,
          "error" => @error
        }
      end

      private

      def numeric_value(v)
        return v if v.is_a?(Numeric)
        return nil unless v.is_a?(String)

        s = v.strip
        s.empty? ? nil : Float(s)
      rescue ArgumentError
        nil
      end

      def normalize_access(access)
        a = access.to_s.upcase
        ACCESS_LEVELS.include?(a) ? a : ACCESS_NONE
      end
    end

    # Ordered set of params belonging to one entity (component instance or group),
    # merged across its definition dictionary (defaults) and instance dictionary
    # (overrides). Pure Ruby - unit-testable.
    class ParamSet
      include Enumerable

      attr_reader :entity_id, :kind, :engine, :node_name, :params

      def initialize(entity_id: nil, kind: :component, engine: :classic,
                     node_name: nil, params: [])
        @entity_id = entity_id
        @kind      = kind
        @engine    = engine
        @node_name = node_name
        @params    = params
      end

      def each(&block)
        @params.each(&block)
      end

      def [](name)
        @params.find { |p| p.name == name.to_s.downcase }
      end

      def names
        @params.map(&:name)
      end

      def configurable
        @params.select(&:configurable?)
      end

      def editable
        @params.select(&:editable?)
      end

      def to_h
        {
          "entityId" => @entity_id,
          "kind" => @kind.to_s,
          "engine" => @engine.to_s,
          "nodeName" => @node_name,
          "params" => @params.map(&:to_h)
        }
      end
    end
  end
end
