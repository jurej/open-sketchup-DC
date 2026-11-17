# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "win32/registry" if Sketchup.platform == :platform_win

module OpenSketchupDC
  module OpenDC
    # HtmlDialog bridge for the parameter panel. JS sends a single JSON
    # message {action, payload} through the "dc" action callback; state is
    # pushed back as a JSON snapshot via window.OpenDC.update(state).
    module Panel
      PANEL_FILE = File.join(PLUGIN_DIR, "ui", "panel", "index.html")
      GRAPH_FILE = File.join(PLUGIN_DIR, "ui", "graph", "index.html")
      NODES_FILE = File.join(PLUGIN_DIR, "ui", "nodes", "index.html")

      @dialog = nil
      @push_pending = false
      @entity_map = {}

      module_function

      def toggle
        if @dialog&.visible?
          @dialog.bring_to_front
        else
          show
        end
      end

      def show
        @dialog = ::UI::HtmlDialog.new(
          dialog_title: "Open DC - Parameters",
          preferences_key: PLUGIN_ID,
          scrollable: true,
          resizable: true,
          width: 380,
          height: 560,
          min_width: 280,
          min_height: 360,
          style: ::UI::HtmlDialog::STYLE_DIALOG
        )
        @dialog.add_action_callback("dc") { |_ctx, json| route(json) }
        @dialog.set_can_close do
          @dialog = nil
          true
        end
        @dialog.set_file(PANEL_FILE)
        @dialog.show
        Observers.install(Sketchup.active_model)
      end

      # ------------------------------------------------------------------
      # Entity id mapping (UI sends back ids we issued in the last snapshot)
      # ------------------------------------------------------------------

      def register(entity)
        id = entity.respond_to?(:persistent_id) ? "p#{entity.persistent_id}" : "o#{entity.object_id}"
        @entity_map[id] = entity
        id
      end

      def entity(id)
        e = @entity_map[id]
        return e if valid_entity?(e)

        # SketchUp invalidates entity references across undo/redraw/model
        # changes - re-resolve persistent ids to a live object when possible
        if id.to_s.start_with?("p")
          begin
            e = Sketchup.active_model.find_entity_by_persistent_id(id[1..].to_i)
          rescue StandardError
            e = nil
          end
          @entity_map[id] = e if e
        end
        e
      end

      def valid_entity?(e)
        e && e.valid?
      rescue StandardError
        false
      end

      def with_entity(id)
        e = entity(id)
        push_error("Entity no longer available (selection changed?)") if e.nil?
        yield e if e
      end

      # ------------------------------------------------------------------
      # JS -> Ruby routing
      # ------------------------------------------------------------------

      def route(json)
        data = JSON.parse(json.to_s)
        action = data["action"].to_s
        p = data["payload"] || {}

        case action
        when "ready", "refresh" then push_state
        when "setParam"      then cmd_set_param(p)
        when "setDefault"    then cmd_set_default(p)
        when "setMeta"       then cmd_set_meta(p)
        when "addParam"      then cmd_add_param(p)
        when "deleteParam"   then cmd_delete_param(p)
        when "reorder"       then cmd_reorder(p)
        when "rename"        then cmd_rename(p)
        when "batchSet"      then cmd_batch_set(p)
        when "setInstName"   then cmd_set_inst_name(p)
        when "setEntityProp" then cmd_set_entity_prop(p)
        when "setDictAttr"   then cmd_set_dict_attr(p)
        when "redraw"        then cmd_redraw(p)
        when "validateFormula" then cmd_validate_formula(p)
        when "fxDocs"        then cmd_fx_docs
        when "graph"         then cmd_graph(p["entityId"])
        when "nodes"         then cmd_nodes(p)
        when "qaEcho"        then @qa_last = p["r"] # dev/QA read-back channel
        when "convert" then with_entity(p["entityId"]) do |e|
          Convert.to_open_dc(e)
          push_state
        end
        when "revert" then with_entity(p["entityId"]) do |e|
          Convert.to_classic(e)
          push_state
        end
        end
      rescue StandardError => e
        push_error(e.message)
      end

      # ------------------------------------------------------------------
      # Commands
      # ------------------------------------------------------------------

      def cmd_set_param(p)
        with_entity(p["entityId"]) do |e|
          dict_name = DCReader.dict_name_for(e)
          err = validate_value(e, p["name"], p["value"], dict_name)
          if err
            push_error(err)
            next
          end
          value = coerce_value(p["value"], param_units(e, p["name"]), dict_name,
                               param_formulaunits(e, p["name"]))
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Set #{p['name']}") do
            DCWriter.set_value(e, p["name"], value, dict_name: dict_name)
          end
          reevaluate(e, dict_name)
          push_state
        end
      end

      def cmd_set_default(p)
        with_entity(p["entityId"]) do |e|
          dict_name = DCReader.dict_name_for(e)
          err = validate_value(e, p["name"], p["value"], dict_name)
          if err
            push_error(err)
            next
          end
          # the literal <name> slot stores inches (engine units), unlike the
          # formula slot which evals in _<name>_formulaunits
          value = coerce_value(p["value"], param_units(e, p["name"]), dict_name, "INCHES")
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Set default #{p['name']}") do
            DCWriter.set_default(e, p["name"], value, dict_name: dict_name)
          end
          reevaluate(e, dict_name)
          push_state
        end
      end

      def cmd_set_meta(p)
        with_entity(p["entityId"]) do |e|
          dict_name = DCReader.dict_name_for(e)
          if SkProps.driver_name?(p["name"])
            # Drivers (sketchup!prop, dict!key) evaluate only under our
            # engine - refuse to seed them into a classic dict, and treat
            # an emptied formula as driver removal.
            if dict_name == DC_DICT
              push_error("'#{p['name']}' drives only under the Open DC " \
                         "engine - convert the component first")
              next
            end
            if p["field"] == "formula" && p["value"].to_s.strip.empty?
              Helpers.undo_wrap(Sketchup.active_model,
                                "Open DC: Remove driver #{p['name']}") do
                DCWriter.delete_param(e, p["name"], dict_name: dict_name)
              end
              reevaluate(e, dict_name)
              push_state
              next
            end
          end
          if p["field"] == "formula" && !p["value"].to_s.strip.empty?
            v = validate_formula(e, p["value"].to_s, p["name"].to_s)
            unless v["ok"]
              push_error("Formula not saved: #{v['errors'].join('; ')}")
              next
            end
          end
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Set #{p['name']}_#{p['field']}") do
            DCWriter.set_meta(e, p["name"], p["field"], p["value"], dict_name: dict_name)
          end
          reevaluate(e, dict_name)
          push_state
        end
      end

      def cmd_add_param(p)
        with_entity(p["entityId"]) do |e|
          dict_name = DCReader.dict_name_for(e)
          if p["formula"].to_s.strip != ""
            v = validate_formula(e, p["formula"].to_s, p["name"].to_s)
            unless v["ok"]
              push_error("Formula not saved: #{v['errors'].join('; ')}")
              next
            end
          end
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Add #{p['name']}") do
            DCWriter.add_param(e,
                               name: p["name"],
                               label: p["label"],
                               formlabel: p["formlabel"],
                               access: p["access"] || ACCESS_TEXTBOX,
                               value: coerce_value(p["value"], p["units"], dict_name),
                               units: p["units"] || "STRING",
                               options: p["options"],
                               formula: p["formula"],
                               dict_name: dict_name)
          end
          reevaluate(e, dict_name)
          push_state
        end
      end

      # Component rename from the configure view: writes the DC "_name"
      # system key on the owner dict - the same name node!/parent!
      # scoping resolves and the same one classic DC shows.
      def cmd_rename(p)
        with_entity(p["entityId"]) do |e|
          dict_name = DCReader.dict_name_for(e)
          name = p["name"].to_s.strip
          next if name.empty?

          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Rename") do
            DCWriter.set_system(e, "_name", name, dict_name: dict_name)
          end
          push_state
        end
      end

      # SketchUp instance name (Entity Info "Name") - a plain instance
      # property, not the DC _name node name. Components only: groups
      # carry no instance name.
      def cmd_set_inst_name(p)
        with_entity(p["entityId"]) do |e|
          next unless e.is_a?(Sketchup::ComponentInstance)

          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Rename instance") do
            e.name = p["name"].to_s
          end
          push_state
        end
      end

      # Native SketchUp property (sketchup!name, layer, description, ...):
      # writes the entity/definition directly - nothing is stored in the
      # DC dictionary. SkProps raises on read-only props.
      def cmd_set_entity_prop(p)
        with_entity(p["entityId"]) do |e|
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Set #{p['name']}") do
            SkProps.write(e, p["name"], p["value"])
          end
          Engine.mark_dirty(e) if DCReader.engine_of(e) == :osdc
          push_state
        end
      end

      # Foreign-dictionary value edit from the "Attribute dictionaries"
      # section: existing scalar keys only (SkProps guards the rest).
      def cmd_set_dict_attr(p)
        with_entity(p["entityId"]) do |e|
          Helpers.undo_wrap(Sketchup.active_model,
                            "Open DC: Set #{p['dict']}!#{p['name']}") do
            SkProps.set_dict_attr(e, p["dict"], p["name"], p["value"])
          end
          Engine.mark_dirty(e) if DCReader.engine_of(e) == :osdc
          push_state
        end
      end

      def cmd_delete_param(p)
        with_entity(p["entityId"]) do |e|
          dict_name = DCReader.dict_name_for(e)
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Delete #{p['name']}") do
            DCWriter.delete_param(e, p["name"], dict_name: dict_name)
          end
          reevaluate(e, dict_name)
          push_state
        end
      end

      # Drag-reorder in the panel: the frontend ships the visible token
      # list (param names + "&Title&" section markers) which we store as
      # classic _itemorder. Order does not affect evaluation - no reeval.
      def cmd_reorder(p)
        with_entity(p["entityId"]) do |e|
          dict_name = DCReader.dict_name_for(e)
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Reorder attributes") do
            DCWriter.set_order(e, p["order"] || [], dict_name: dict_name)
          end
          push_state
        end
      end

      def cmd_batch_set(p)
        ids = p["entityIds"] || []
        entities = ids.map { |id| entity(id) }.compact
        return push_error("No matching entities.") if entities.empty?

        name = p["name"]
        model = Sketchup.active_model
        # Type-check per entity before writing anything - a bad value on
        # one component shouldn't leave the rest half-updated.
        entities.each do |e|
          err = validate_value(e, name, p["value"], DCReader.dict_name_for(e))
          return push_error("#{entity_label(e)}: #{err}") if err
        end
        classic = []
        Helpers.undo_wrap(model, "Open DC: Batch set #{name}") do
          entities.each do |e|
            dict_name = DCReader.dict_name_for(e)
            value = coerce_value(p["value"], param_units(e, name), dict_name,
                                 param_formulaunits(e, name))
            DCWriter.set_value(e, name, value, dict_name: dict_name)
            dict_name == OS_DC_DICT ? Engine.mark_dirty(e) : classic << e
          end
        end
        DCBridge.redraw_all!(classic)
        push_state
      end

      def cmd_redraw(p)
        ids = p["entityIds"] || []
        entities = ids.map { |id| entity(id) }.compact
        entities.each do |e|
          next unless DCReader.dynamic?(e)

          DCReader.dict_name_for(e) == OS_DC_DICT ? Engine.mark_dirty(e) : DCBridge.redraw!(e)
        end
        push_state
      end

      def reevaluate(entity, dict_name)
        dict_name == OS_DC_DICT ? Engine.mark_dirty(entity) : DCBridge.redraw!(entity)
      end

      def cmd_validate_formula(p)
        with_entity(p["entityId"]) do |e|
          push_validation(p.merge(validate_formula(e, p["formula"].to_s, p["name"].to_s)))
        end
      end

      # Static check of a formula against this entity's attribute set:
      # syntax via the real parser, unknown function names, and unresolved
      # attribute references (with did-you-mean suggestions). Scopes that
      # can't be resolved from the panel (parent!/node! on a nested entity)
      # produce hints, not errors.
      def validate_formula(entity, src, attr_name)
        dict_name = DCReader.dict_name_for(entity)
        ps = DCReader.read(entity, dict_name: dict_name)
        allow_actions = attr_name == "onclick"
        errors = []
        hints = []

        begin
          ast = Expression.parse(Expression.strip_eq(src))
        rescue Expression::Error => e
          return { "ok" => false,
                   "errors" => [friendly_syntax_error(src, e.message)],
                   "hints" => hints }
        end

        Expression.walk(ast) do |node|
          next unless node[0] == :call

          fn = node[1]
          if !Expression::FUNCTIONS.include?(fn) &&
             !(allow_actions && Expression::Evaluator::ACTIONS.include?(fn))
            errors << "unknown function '#{fn}'"
            next
          end
          # DICTATTR("dict","key") with literal arguments can be checked
          # against this entity's dictionaries right here.
          next unless fn == "DICTATTR" &&
                      node[2].length == 2 && node[2].all? { |a| a[0] == :str }

          dn, key = node[2].map { |a| a[1].to_s }
          if (fd = SkProps.dict_named(entity, dn))
            unless SkProps.dict_key?(fd, key)
              hints << "dictionary '#{SkProps.dict_name_of(fd)}' has no " \
                       "attribute '#{key}' (it may appear later)"
            end
            hints << osdc_only("DICTATTR", dict_name)
          else
            errors << "no dictionary named '#{dn}'"
          end
        end

        names = ps.params.map(&:name)
        known = names | DCReader::BUILTIN_ATTRS.map(&:downcase)
        Expression.refs(src).each do |scope, n|
          case scope
          when nil
            next if known.include?(n.downcase)
            next if n == "copy" && names.include?("copies")

            sug = DidYouMean::SpellChecker.new(dictionary: known).correct(n).first
            errors << "unknown attribute '#{n}'" +
                      (sug ? " - did you mean '#{sug}'?" : "")
          when "global"
            g = DCReader.dict_of(Sketchup.active_model, dict_name)
            errors << "no global attribute '#{n}'" unless DCReader.dict_key?(g, n)
          when "parent"
            hints << "parent!#{n} resolves when this component is nested - not verified here"
          when "sketchup"
            errors << "unknown SketchUp attribute '#{n}'" unless SkProps.known?(n)
            hints << osdc_only("sketchup!#{n}", dict_name)
          when "model"
            errors << "unknown model attribute '#{n}'" unless SkProps::MODEL_PROP_NAMES.include?(n)
            hints << osdc_only("model!#{n}", dict_name)
          when "scene"
            errors << "unknown scene attribute '#{n}'" unless SkProps::SCENE_PROP_NAMES.include?(n)
            hints << osdc_only("scene!#{n}", dict_name)
          else
            node = top_level?(entity) &&
                   Interact.node_named(scope, nil, entity, Sketchup.active_model)
            if node.nil?
              if (fd = SkProps.dict_named(entity, scope))
                unless SkProps.dict_key?(fd, n)
                  hints << "dictionary '#{SkProps.dict_name_of(fd)}' has no " \
                           "attribute '#{n}' (it may appear later)"
                end
                hints << osdc_only("#{scope}!#{n}", dict_name)
              else
                hints << "node '#{scope}' not verified here"
              end
            else
              nps = DCReader.read(node, dict_name: DCReader.dict_name_for(node))
              errors << "node '#{scope}' has no attribute '#{n}'" if nps[n].nil?
            end
          end
        end
        hints.compact!
        { "ok" => errors.empty?, "errors" => errors.uniq, "hints" => hints.uniq }
      end

      # sketchup!/dictname!/DICTATTR evaluate only under our engine - in a
      # classic formula Trimble's engine would fail them, so warn (not
      # block) when the target dict is dynamic_attributes.
      def osdc_only(what, dict_name)
        return nil unless dict_name == DC_DICT

        "'#{what}' resolves under the Open DC engine only"
      end

      # Units whose values must parse as numbers (length, angle, plain
      # numeric). STRING/TEXT/BOOLEAN are handled separately.
      NUMERIC_UNITS = (Param::LENGTH_UNITS +
                       %w[DEGREES RADIANS DECIMAL FLOAT PERCENT INTEGER]).freeze

      # Typed suffixes on value literals -> the DC unit they express
      # (10cm, 2", 3', 45deg). Mirrors the formula lexer's unit set.
      VALUE_SUFFIX_UNITS = {
        "mm" => "MILLIMETERS", "cm" => "CENTIMETERS", "m" => "METERS",
        "in" => "INCHES", '"' => "INCHES",
        "ft" => "FEET", "'" => "FEET",
        "deg" => "DEGREES", "degrees" => "DEGREES"
      }.freeze

      # Turn a raw parser message into something a non-programmer can act
      # on. "trailing tokens" tells you nothing; "wrap it in quotes" does.
      def friendly_syntax_error(src, msg)
        s = src.to_s.strip
        case msg
        when /\Aunexpected '(.+)'\z/
          tok = Regexp.last_match(1)
          if s =~ /\A[A-Za-z_][\w.]*(\s+[A-Za-z_][\w.]*)+\z/
            # bare words like `Valles GAL2` - almost surely meant as text
            "'#{s}' looks like a text value - " \
              "wrap it in double quotes: \"#{s}\""
          elsif tok == ")"
            "extra ')' - there is no '(' matching it"
          else
            "unexpected '#{tok}' - an operator (+ - * / &) or a bracket " \
              "may be missing before it"
          end
        when "unexpected end of input"
          "the formula ends abruptly - it looks incomplete"
        when /\Aexpected (.+) but found (.+)\z/
          "expected #{Regexp.last_match(1)} but found #{Regexp.last_match(2)}"
        when "unterminated string"
          'the text never closes - add the missing "'
        when /\Aunexpected character '(.+)'\z/
          "'#{Regexp.last_match(1)}' can't be used in a formula"
        when /\Abad number at (\d+)\z/
          "malformed number near character #{Regexp.last_match(1).to_i + 1}"
        when /\Aunknown unit '(.+)'\z/
          "unknown unit '#{Regexp.last_match(1)}' - " \
            "use mm, cm, m, in/\", ft/' or deg"
        when /\Aexpected an attribute name after '(.+)!'\z/
          "'#{Regexp.last_match(1)}!' needs an attribute after it, " \
            "e.g. #{Regexp.last_match(1)}!name"
        else
          msg
        end
      end

      # The end user's model display unit - what classic "DEFAULT" units
      # resolve to. INCHES fallback keeps writes sane when unreadable.
      def model_units
        DCReader.model_length_units(Sketchup.active_model) || "INCHES"
      end

      # "DEFAULT" (End user's model units) -> the active model's unit;
      # everything else passes through.
      def resolve_units(units)
        Param.model_units_dependent?(units) ? model_units : units
      end

      # Parse a UI-entered value as a plain number or a unit-suffixed
      # literal (450, -2.5, 10cm, 18", 3', 45deg).
      # Returns [number, suffix_unit|nil] or nil.
      def value_literal(s)
        return [s.to_f, nil] if s =~ /\A-?\d+(\.\d+)?\z/

        m = s.match(/\A(-?\d+(?:\.\d+)?)\s*(mm|cm|m|in|ft|deg|degrees|"|')\z/i)
        m ? [m[1].to_f, VALUE_SUFFIX_UNITS[m[2].downcase]] : nil
      end

      # Architectural/fractional literal shape: [feet'][whole][num/den]["]
      ARCH_INCHES_RE = %r{\A(?:(\d+(?:\.\d+)?)\s*')?\s*(?:(\d+(?:\.\d+)?)\s*)?(?:(\d+)\s*/\s*(\d+)\s*)?"?\z}

      # Architectural/fractional literal -> inches: 3'6", 1' 3 1/4",
      # 12 1/2", 3/4". Returns nil when the input isn't in that shape -
      # bare numbers and single-suffix literals go through value_literal.
      def arch_inches(s)
        m = s.to_s.strip.match(ARCH_INCHES_RE)
        return nil if m.nil? || (m[1].nil? && m[2].nil? && m[3].nil?)

        frac = m[3] ? m[3].to_f / m[4].to_i : 0.0
        m[1].to_f * 12.0 + m[2].to_f + frac
      end

      # Type-check a UI-entered value against the param's declared type
      # before it is written. Returns a user-facing error string or nil.
      def validate_value(entity, name, raw, dict_name)
        param = DCReader.read(entity, dict_name: dict_name)[name]
        return nil if param.nil?

        s = raw.to_s.strip
        return nil if s.empty?

        types = [param.units, param.formulaunits].map { |u| resolve_units(u).to_s.upcase }
        label = param.display_name

        if types.include?("BOOLEAN") && s !~ /\A(true|false|0|1)\z/i
          return "#{label} expects true or false - '#{s}' isn't valid"
        end

        if param.list? && param.parsed_options.any?
          opts = param.parsed_options
          unless opts.any? { |o| o["value"] == s || o["label"] == s }
            names = opts.map { |o| o["label"] }.first(6).join(", ")
            names += ", ..." if opts.length > 6
            return "#{label} is a list - '#{s}' isn't one of its " \
                   "options (#{names})"
          end
          return nil
        end

        return nil unless (types & NUMERIC_UNITS).any?

        lit = value_literal(s)
        if lit.nil?
          return nil if (types & Param::LENGTH_UNITS).any? && arch_inches(s)

          return "#{label} expects a number - '#{s}' isn't one " \
                 "(examples: 450, 45.5, 10cm, 18\")"
        end
        num, suffix = lit
        if types.include?("INTEGER") && num != num.to_i
          return "#{label} expects a whole number - '#{s}' isn't"
        end
        if suffix == "DEGREES" && (types & Param::LENGTH_UNITS).any?
          return "#{label} is a length - 'deg' is an angle unit"
        end
        if suffix && suffix != "DEGREES" && (types & Param::LENGTH_UNITS).empty?
          return "#{label} isn't a length field - '#{s}' carries one"
        end
        nil
      end

      def top_level?(entity)
        entity.parent.is_a?(Sketchup::Model)
      rescue StandardError
        false
      end

      # Convert a UI-entered value to its stored form. Numbers typed into a
      # length-unit field arrive in that field's display units (_<name>_units).
      # Classic DC evaluates bare numbers in _<name>_formula_formulaunits, so
      # classic writes convert display -> inches -> formulaunits (or the
      # explicit target, e.g. "INCHES" for the literal <name> slot). open_dc
      # stores inches internally. Non-length units pass through untouched.
      def coerce_value(v, units = nil, dict_name = nil, target_units = nil)
        return v if v.is_a?(Numeric) || v == true || v == false

        s = v.to_s.strip
        # "DEFAULT" (End user's model units) resolves to the model's unit
        # for both the display source and the formula/default target.
        units = resolve_units(units)
        target_units = resolve_units(target_units)
        num, suffix = s =~ /\A-?\d/ ? value_literal(s) : [nil, nil]
        if num.nil? && Param.length_unit?(units) && (inches = arch_inches(s))
          # architectural/fractional input already arrives in inches
          return inches_for_target(inches, units, dict_name, target_units)
        end

        if num
          if Param.length_unit?(units)
            # bare numbers arrive in display units; a suffixed literal
            # carries its own unit (10cm in a feet field is still 10cm)
            src = suffix && suffix != "DEGREES" ? suffix : units
            return inches_for_target(Param.unit_to_inches(num, src), units,
                                     dict_name, target_units)
          end
          # numeric-typed field or a bare number anywhere -> store the
          # number; a length-suffixed literal in a text field stays text
          return num if suffix.nil? || suffix == "DEGREES" ||
                        NUMERIC_UNITS.include?(units.to_s.upcase)

          return s
        end
        return true if s == "true"
        return false if s == "false"

        classic_text(s, dict_name)
      end

      # Classic's _<name>_formula slot is evaluated by the DC engine, so
      # prose typed into a text field ("Valles GAL2") must arrive as a
      # quoted literal or the engine reports a parse error. Input that is
      # already an expression (lenx*2, "text") passes through; a leading
      # = marks explicit formula intent and is stripped for storage.
      # A lone bare word ("CPL", parent!x) is still prose - the engine
      # resolves it as an unknown attribute reference and errors.
      # open_dc's value slot is a literal, never evaluated - passes raw.
      def classic_text(s, dict_name)
        return s unless dict_name == DC_DICT

        f = Expression.strip_eq(s)
        ast = expression_ast(f)
        return f if ast && (s != f || !%i[var ref].include?(ast[0]))

        s.include?('"') ? s : %("#{s}")
      end

      def expression_ast(src)
        Expression.parse(src.to_s)
      rescue Expression::Error
        nil
      end

      # inches -> stored form: open_dc keeps inches; classic converts to
      # the write target (formulaunits, or the display units when empty).
      def inches_for_target(inches, units, dict_name, target_units)
        return inches if dict_name == OS_DC_DICT

        target = target_units.to_s.empty? ? units : target_units
        Param.inches_to_unit(inches, target)
      end

      def param_units(entity, name)
        dict_name = DCReader.dict_name_for(entity)
        DCReader.read(entity, dict_name: dict_name)[name]&.units
      rescue StandardError
        nil
      end

      def param_formulaunits(entity, name)
        dict_name = DCReader.dict_name_for(entity)
        DCReader.read(entity, dict_name: dict_name)[name]&.formulaunits
      rescue StandardError
        nil
      end

      # ------------------------------------------------------------------
      # Formula reference window
      # ------------------------------------------------------------------

      FX_REFERENCE = [
        ["References", [
          ["name", "attribute on this component"],
          ["parent!name", "attribute on the parent component"],
          ["global!name", "model-global attribute (open_dc)"],
          ["node!name", "attribute on a sibling node"],
          ["sketchup!name", "native property: name, instname, description, layer, guid, x, lenx, ..."],
          ["model!name", "model global: name, title, units, lat, lng, northangle, ..."],
          ["scene!name", "active scene: name, description, transitiontime, ..."],
          ["dictname!key", "attribute-dictionary value (any dict on this component)"],
          ["copy", "index of this generated copy (when copies &gt; 0)"]
        ]],
        ["Logical", [
          ["IF(test, then, else)", "conditional value"],
          ["AND(a, b, ...) / OR(a, b, ...) / NOT(a)", "also usable as infix keywords"],
          ["TRUE() / FALSE()", "boolean literals"]
        ]],
        ["Math", [
          ["MIN(a, b, ...) / MAX(a, b, ...)", "smallest / largest of the arguments"],
          ["ROUND(x, n) / INT(x)", "round to n digits / round down"],
          ["FLOOR(x, sig) / CEILING(x, sig)", "round to a multiple (significance optional)"],
          ["EVEN(x) / ODD(x)", "round away from zero to even / odd"],
          ["ISEVEN(x) / ISODD(x)", "TRUE when the integer part is even / odd"],
          ["ABS(x) / SQRT(x) / SIGN(x)", "absolute value / square root / -1, 0, 1"],
          ["EXP(x) / LN(x) / LOG10(x)", "e^x / natural log / base-10 log"],
          ["RAND() / RANDBETWEEN(lo, hi)", "random 0..1 / random integer lo..hi"],
          ["PI() / DEGREES(rad) / RADIANS(deg)", "pi / angle conversion"]
        ]],
        ["Trigonometry (degrees)", [
          ["SIN / COS / TAN", "sine / cosine / tangent"],
          ["ASIN / ACOS / ATAN", "inverse sine / cosine / tangent"],
          ["SINH / COSH / TANH", "hyperbolic sine / cosine / tangent"],
          ["ASINH / ACOSH / ATANH", "inverse hyperbolic functions"]
        ]],
        ["Text", [
          ["CONCATENATE(t1, t2, ...)", "join strings; same as \"a\" &amp; \"b\""],
          ["LEFT(t, n) / RIGHT(t, n) / MID(t, start, n)", "substring; positions are 1-based"],
          ["LEN(t) / TRIM(t)", "length / collapse whitespace"],
          ["LOWER(t) / UPPER(t) / PROPER(t)", "case conversion"],
          ["CHAR(n) / CODE(t)", "character &lt;-&gt; code table value"],
          ["FIND(find, text, pos)", "1-based position of find in text; 0 when absent"],
          ["REPLACE(t, start, n, new)", "replace n characters at start"],
          ["SUBSTITUTE(t, old, new, occ)", "replace all / the occ-th occurrence"],
          ["REPT(t, n)", "repeat text n times"],
          ["EXACT(a, b)", "case-sensitive equality"],
          ["VALUE(t) / DOLLAR(v, dec)", "text to number / currency format"]
        ]],
        ["SketchUp", [
          ["CHOOSE(index, v1, v2, ...)", "pick the index-th value (1-based)"],
          ["CURRENT(\"name\")", "current value of an attribute"],
          ["LARGEST / SMALLEST(list, k)", "k-th largest / smallest value"],
          ["NEAREST(x, v1, v2, ...)", "the listed value closest to x"],
          ["OPTIONINDEX(\"name\")", "index of the selected LIST option"],
          ["OPTIONVALUE(\"name\", \"label\")", "value mapped to a LIST option label"],
          ["OPTIONLABEL(\"name\")", "label of the current LIST option"],
          ["EDGES() / FACES()", "ungrouped edge / face count in this component"],
          ["FACEAREA(\"material\")", "face area in square inches (material optional)"],
          ["LAT() / LNG()", "model latitude / longitude"],
          ["SUNANGLE() / SUNELEVATION()", "sun azimuth / altitude"],
          ["DICTATTR(\"dict\", \"key\")", "dictionary value by name - when the dict name isn't a valid scope"]
        ]],
        ["Actions (onClick only)", [
          ["SET(\"name\", v1, v2, ...)", "cycle the attribute through the values"],
          ["ANIMATE*(\"name\", ...)", "animate through the values"],
          ["REDRAW()", "force a redraw"],
          ["ALERT(\"msg\")", "show a message box"],
          ["GOTOSCENE(\"scene\")", "activate a scene page"]
        ]],
        ["Syntax", [
          ["+ - * / ^", "arithmetic; ^ = power"],
          ["&amp;", "string concatenation"],
          ["== != &lt; &gt; &lt;= &gt;=", "comparison; = also works"],
          ["AND / OR / NOT / TRUE / FALSE", "logic keywords"],
          ["4\"  2'  3cm  5mm", "feet/inch/unit suffixes on numbers"],
          ["\"text\"", "string literal"]
        ]]
      ].freeze

      def cmd_fx_docs
        if @fx_dialog.nil?
          @fx_dialog = ::UI::HtmlDialog.new(
            dialog_title: "Open DC - Formula Reference",
            preferences_key: "#{PLUGIN_ID}_fxdocs",
            scrollable: true,
            resizable: true,
            width: 480,
            height: 560,
            min_width: 320,
            min_height: 300,
            style: ::UI::HtmlDialog::STYLE_UTILITY
          )
          @fx_dialog.set_can_close do
            @fx_dialog = nil
            true
          end
        end
        @fx_dialog.set_html(functions_reference_html)
        @fx_dialog.show
        @fx_dialog.bring_to_front
      rescue StandardError => e
        push_error(e.message)
      end

      # Floating dependency-graph window. One shared dialog retargets to
      # whichever entity card's Graph button was clicked last; the page
      # handshake (gready) triggers the first data push after load.
      def cmd_graph(eid)
        with_entity(eid) do |ent|
          @graph_eid = eid
          @graph_pending = build_graph_pending(ent, eid)
          if @graph_dialog.nil?
            @graph_dialog = ::UI::HtmlDialog.new(
              dialog_title: "Open DC - Dependency Graph",
              preferences_key: "#{PLUGIN_ID}_graph",
              scrollable: false,
              resizable: true,
              width: 800,
              height: 600,
              min_width: 400,
              min_height: 300,
              style: ::UI::HtmlDialog::STYLE_UTILITY
            )
            @graph_dialog.add_action_callback("gready") do |_ctx, arg|
              @gqa = arg unless arg.to_s.empty? # dev/QA read-back channel
              push_graph
            end
            @graph_dialog.add_action_callback("gact") do |_ctx, json|
              graph_apply(JSON.parse(json.to_s))
            end
            @graph_dialog.set_can_close do
              @graph_dialog = nil
              true
            end
            @graph_dialog.set_file(GRAPH_FILE)
            @graph_dialog.show
          else
            push_graph
            @graph_dialog.bring_to_front
          end
        end
      rescue StandardError => e
        push_error(e.message)
      end

      def read_graph_set(ent, eid)
        DCReader.read(ent, dict_name: DCReader.dict_name_for(ent), entity_id: eid)
      end

      # Formula edits coming from the graph window (wire/unlink). Same
      # validation + undo + reevaluate path as the panel's formula field.
      def graph_apply(data)
        case data["op"].to_s
        when "openNodes" then return cmd_nodes(data)
        when "addParam"  then return graph_add_param(data)
        when "previewDoc", "applyDoc" then return graph_apply_doc(data)
        end

        ent = entity(data["entityId"].to_s)
        if ent.nil?
          push_error("Entity no longer available (selection changed?)")
          return
        end

        name = data["name"].to_s
        formula = data["formula"].to_s
        v = validate_formula(ent, formula, name) unless formula.strip.empty?
        if v && !v["ok"]
          push_error("Formula not saved: #{v['errors'].join('; ')}")
          return
        end
        dict_name = DCReader.dict_name_for(ent)
        Helpers.undo_wrap(Sketchup.active_model, "Open DC: Wire #{name}") do
          DCWriter.set_meta(ent, name, "formula", formula, dict_name: dict_name)
        end
        reevaluate(ent, dict_name)
        push_state
        @graph_pending = build_graph_pending(ent, data["entityId"].to_s)
        push_graph
      rescue StandardError => e
        push_error(e.message)
      end

      # Pending payload for the graph window: the dependency graph plus
      # the catalogs the formula subgraphs need for in-canvas editing
      # (same fields cmd_nodes pushes to the fx editor).
      def build_graph_pending(ent, eid)
        ps = read_graph_set(ent, eid)
        {
          "label" => entity_label(ent),
          "entityId" => eid,
          "graph" => entity_graph(ps),
          "palette" => {
            "attrs" => ps.names.reject { |n| SkProps.driver_name?(n) },
            "builtins" => DCReader::BUILTIN_ATTRS,
            "skprops" => SkProps::PROP_NAMES,
            "modelprops" => SkProps::MODEL_PROP_NAMES,
            "sceneprops" => SkProps::SCENE_PROP_NAMES,
            "dicts" => dict_scope_names(ent),
            "globals" => global_params(Sketchup.active_model).map { |g| g["name"] },
            "functions" => Expression::FUNCTIONS,
            "actions" => Expression::Evaluator::ACTIONS,
            "fnArity" => AstGraph::FN_ARITY,
            "fnVararg" => AstGraph::FN_VARARG,
            "fnGroups" => AstGraph::FN_GROUPS
          }
        }
      end

      # In-subgraph formula edits: the JS serializes the subgraph back to
      # an AstGraph doc. previewDoc emits + validates only; applyDoc also
      # writes through the normal validated/undo/reevaluate path.
      def graph_apply_doc(data)
        name = data["name"].to_s
        ent = entity(data["entityId"].to_s)
        if ent.nil?
          return push_graph_status("ok" => false, "name" => name,
                                   "errors" => ["entity unavailable"])
        end

        formula =
          begin
            AstGraph.to_formula(data["doc"] || {})
          rescue StandardError => e
            return push_graph_status("ok" => false, "name" => name,
                                     "errors" => [e.message])
          end

        v = validate_formula(ent, formula, name)
        unless v["ok"]
          return push_graph_status("ok" => false, "name" => name,
                                   "errors" => v["errors"])
        end

        unless data["op"].to_s == "applyDoc"
          return push_graph_status("ok" => true, "name" => name,
                                   "formula" => formula)
        end

        write_graph_formula(ent, data["entityId"].to_s, name, formula,
                            "Open DC: Graph formula #{name}")
        push_graph_status("ok" => true, "name" => name, "formula" => formula,
                          "applied" => true)
      rescue StandardError => e
        push_graph_status("ok" => false, "name" => data["name"].to_s,
                          "errors" => [e.message])
      end

      # Shared write path for graph-driven formula edits: validated write
      # inside undo, reevaluate, then refresh panel + graph window.
      def write_graph_formula(ent, eid, name, formula, undo_label)
        dict_name = DCReader.dict_name_for(ent)
        Helpers.undo_wrap(Sketchup.active_model, undo_label) do
          DCWriter.set_meta(ent, name, "formula", formula, dict_name: dict_name)
        end
        reevaluate(ent, dict_name)
        push_state
        @graph_pending = build_graph_pending(ent, eid)
        push_graph
      end

      def push_graph
        return if @graph_dialog.nil? || @graph_pending.nil?

        push_theme(@graph_dialog)
        json = JSON.generate(json_safe(@graph_pending))
        @graph_dialog.execute_script("window.renderGraph && window.renderGraph(#{json})")
      end

      # One-shot status to the graph window (errors/hints that don't come
      # with a fresh renderGraph push).
      def push_graph_status(payload)
        return if @graph_dialog.nil?

        json = JSON.generate(json_safe(payload))
        @graph_dialog.execute_script("window.onGraphStatus && window.onGraphStatus(#{json})")
      end

      # Context-menu "+ attr" on the dependency graph: creates a plain
      # user attribute cluster, then re-pushes so the new param shows up
      # as a wire target.
      def graph_add_param(data)
        ent = entity(data["entityId"].to_s)
        if ent.nil?
          return push_graph_status("error" => "Entity no longer available (selection changed?)")
        end

        name = data["name"].to_s.strip.downcase
        unless name =~ /\A[a-z][a-z0-9_]*\z/
          return push_graph_status(
            "error" => "Invalid attribute name '#{data['name']}' - letters, digits, underscores only")
        end

        dict_name = DCReader.dict_name_for(ent)
        if read_graph_set(ent, data["entityId"].to_s)[name]
          return push_graph_status("error" => "Attribute '#{name}' already exists")
        end

        Helpers.undo_wrap(Sketchup.active_model, "Open DC: Add #{name}") do
          DCWriter.add_param(ent, name: name, access: ACCESS_TEXTBOX, dict_name: dict_name)
        end
        reevaluate(ent, dict_name)
        push_state
        push_graph_status("msg" => "Added '#{name}'")
        @graph_pending = build_graph_pending(ent, data["entityId"].to_s)
        push_graph
      rescue StandardError => e
        push_graph_status("error" => e.message)
      end

      # ------------------------------------------------------------------
      # Node editor (Rete.js expression graph) for a single attribute
      # ------------------------------------------------------------------

      def cmd_nodes(p)
        with_entity(p["entityId"]) do |ent|
          dict_name = DCReader.dict_name_for(ent)
          ps = DCReader.read(ent, dict_name: dict_name, entity_id: p["entityId"])
          param = ps[p["name"].to_s.downcase]
          graph = begin
            param&.formula? ? AstGraph.to_graph(param.formula) : nil
          rescue StandardError
            nil
          end
          @nodes_pending = {
            "entityId" => p["entityId"].to_s,
            "name" => p["name"].to_s.downcase,
            "label" => "#{entity_label(ent)} :: #{p['name']}",
            "formula" => param ? param.formula.to_s : "",
            "graph" => graph,
            "attrs" => ps.names.reject { |n| SkProps.driver_name?(n) },
            "builtins" => DCReader::BUILTIN_ATTRS,
            "skprops" => SkProps::PROP_NAMES,
            "modelprops" => SkProps::MODEL_PROP_NAMES,
            "sceneprops" => SkProps::SCENE_PROP_NAMES,
            "dicts" => dict_scope_names(ent),
            "globals" => global_params(Sketchup.active_model).map { |g| g["name"] },
            "functions" => Expression::FUNCTIONS,
            "actions" => Expression::Evaluator::ACTIONS,
            "fnArity" => AstGraph::FN_ARITY,
            "fnVararg" => AstGraph::FN_VARARG,
            "fnGroups" => AstGraph::FN_GROUPS,
            "isAction" => p["name"].to_s.casecmp("onclick").zero?
          }
          open_nodes_dialog
        end
      rescue StandardError => e
        push_error(e.message)
      end

      def open_nodes_dialog
        if @nodes_dialog.nil?
          @nodes_dialog = ::UI::HtmlDialog.new(
            dialog_title: "Open DC - Node Editor",
            preferences_key: "#{PLUGIN_ID}_nodes",
            scrollable: false,
            resizable: true,
            width: 900,
            height: 640,
            min_width: 480,
            min_height: 320,
            style: ::UI::HtmlDialog::STYLE_UTILITY
          )
          @nodes_dialog.add_action_callback("nready") do |_ctx, _a|
            @nodes_ready = true
            push_nodes
          end
          @nodes_dialog.add_action_callback("nact") do |_ctx, json|
            @nlast = json.to_s
            nodes_apply(JSON.parse(json.to_s))
          end
          @nodes_dialog.set_can_close do
            @nodes_dialog = nil
            true
          end
          @nodes_dialog.set_file(NODES_FILE)
          @nodes_dialog.show
        else
          push_nodes
          @nodes_dialog.bring_to_front
        end
      end

      def push_nodes
        return if @nodes_dialog.nil? || @nodes_pending.nil?

        push_theme(@nodes_dialog)
        json = JSON.generate(json_safe(@nodes_pending))
        @nodes_dialog.execute_script("window.renderNodes && window.renderNodes(#{json})")
      end

      def push_nodes_status(payload)
        return if @nodes_dialog.nil?

        json = JSON.generate(json_safe(payload))
        @nodes_dialog.execute_script("window.onNodeStatus && window.onNodeStatus(#{json})")
      end

      # nact ops: preview emits the formula + validation only; apply also
      # writes it through the normal validated/undo/reevaluate path.
      def nodes_apply(data)
        return if data["op"].to_s == "dbg" # JS diagnostics - kept in @nlast

        formula =
          begin
            AstGraph.to_formula(data["doc"] || {})
          rescue StandardError => e
            return push_nodes_status("ok" => false, "errors" => [e.message])
          end

        ent = entity(data["entityId"].to_s)
        if ent.nil?
          return push_nodes_status("ok" => false, "errors" => ["entity unavailable"])
        end

        v = validate_formula(ent, formula, data["name"].to_s)
        unless v["ok"]
          return push_nodes_status("ok" => false, "errors" => v["errors"])
        end

        if data["op"].to_s == "apply"
          dict_name = DCReader.dict_name_for(ent)
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Nodes #{data['name']}") do
            DCWriter.set_meta(ent, data["name"], "formula", formula, dict_name: dict_name)
          end
          reevaluate(ent, dict_name)
          push_state
          push_nodes_status("ok" => true, "formula" => formula, "applied" => true)
        else
          push_nodes_status("ok" => true, "formula" => formula,
                                          "hints" => v["hints"])
        end
      rescue StandardError => e
        push_nodes_status("ok" => false, "errors" => [e.message])
      end

      def functions_reference_rows
        FX_REFERENCE.map do |section, items|
          "<h2>#{section}</h2><table>" +
            items.map do |sig, desc|
              "<tr><td class='sig'>#{sig}</td><td class='desc'>#{desc}</td></tr>"
            end.join("") + "</table>"
        end.join("")
      end

      def functions_reference_html
        <<~HTML
          <!DOCTYPE html><html><head><meta charset="utf-8">
          <script>(function(){var f=#{JSON.generate(os_theme)},m=matchMedia("(prefers-color-scheme: light)");
          function a(){document.documentElement.setAttribute("data-theme",
          f||(m.matches?"light":"dark"))}
          m.addEventListener&&m.addEventListener("change",a);a()})();</script>
          <style>
            :root{color-scheme:dark;--bg:#17181c;--bg2:#1e1f24;--fg:#d8d8de;
              --dim:#a9a9b2;--muted:#8a8a93;--accent:#4f9cf9;--fn:#b9a5f0;
              --border:#2a2b31}
            :root[data-theme=light]{color-scheme:light;--bg:#f1f2f4;
              --bg2:#ffffff;--fg:#23252d;--dim:#565b66;--muted:#747a88;
              --accent:#0d6dd8;--fn:#7a5cd0;--border:#d3d6dc}
            body{background:var(--bg);color:var(--fg);font:11.5px/1.5 "Segoe UI",sans-serif;margin:14px}
            h1{font-size:13.5px;margin:0 0 10px;color:var(--accent)}
            h2{font-size:11px;text-transform:uppercase;color:var(--muted);margin:16px 0 6px;border-bottom:1px solid var(--border);padding-bottom:4px}
            table{width:100%;border-collapse:collapse}
            td{padding:3px 6px;vertical-align:top}
            tr:nth-child(odd){background:var(--bg2)}
            .sig{font-family:Consolas,monospace;color:var(--fn);white-space:nowrap;width:45%}
            .desc{color:var(--dim)}
          </style></head><body>
          <h1>Formula Reference</h1>
          #{functions_reference_rows}
          </body></html>
        HTML
      end

      # ------------------------------------------------------------------
      # Ruby -> JS state push
      # ------------------------------------------------------------------

      # OS color mode for the HtmlDialogs: "light"/"dark" on Windows from
      # the AppsUseLightTheme personalization flag, nil elsewhere so the
      # page falls back to its own prefers-color-scheme detection.
      def os_theme
        return nil unless Sketchup.platform == :platform_win

        Win32::Registry::HKEY_CURRENT_USER.open(
          'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        ) { |r| r["AppsUseLightTheme"].to_i.zero? ? "dark" : "light" }
      rescue StandardError
        nil
      end

      # theme.js owns html[data-theme]; a nil push hands control back to
      # the page's media query. Re-pushed on every state update so OS
      # mode flips reach open dialogs.
      def push_theme(dialog)
        return if dialog.nil?

        t = JSON.generate(os_theme)
        dialog.execute_script("window.OpenDCTheme && window.OpenDCTheme.set(#{t})")
      end

      def schedule_push
        return if @push_pending

        @push_pending = true
        UI.start_timer(0.05, false) do
          @push_pending = false
          push_state
        end
      end

      def push_state
        refresh_graph_window
        return if @dialog.nil?

        push_theme(@dialog)
        json = JSON.generate(json_safe(state(Sketchup.active_model)))
        @dialog.execute_script("window.OpenDC && window.OpenDC.update(#{json})")
        Observers.watch_current(Sketchup.active_model)
      rescue StandardError => e
        puts "#{PLUGIN_NAME}: push_state failed - #{e.message}"
      end

      # Keeps the floating graph window live on selection/entity changes:
      # re-push fresh data for the tracked entity while it stays selected,
      # retarget to the first selected dynamic target otherwise. With no
      # dynamic selection the window falls back to an empty view only when
      # its entity is gone for good.
      def refresh_graph_window
        return if @graph_dialog.nil?

        cur = entity(@graph_eid.to_s)
        dyn = Selection.dynamic_targets(Sketchup.active_model)
        target = dyn.include?(cur) ? cur : dyn.first
        if target.nil?
          return if valid_entity?(cur)

          @graph_pending = { "label" => "", "entityId" => nil,
                             "graph" => { "nodes" => [], "edges" => [] } }
          return push_graph
        end

        eid = register(target)
        @graph_eid = eid
        @graph_pending = build_graph_pending(target, eid)
        push_graph
      rescue StandardError => e
        puts "#{PLUGIN_NAME}: graph refresh failed - #{e.message}"
      end

      def push_error(msg)
        return if @dialog.nil?

        json = JSON.generate(msg.to_s)
        @dialog.execute_script("window.OpenDC && window.OpenDC.error(#{json})")
      end

      # One-shot answer to a JS validateFormula request (not a state push).
      def push_validation(payload)
        return if @dialog.nil?

        json = JSON.generate(json_safe(payload))
        @dialog.execute_script("window.OpenDC && window.OpenDC.onValidation(#{json})")
      rescue StandardError => e
        puts "#{PLUGIN_NAME}: push_validation failed - #{e.message}"
      end

      # Called by the entity observer for both entities and dictionaries.
      # Dictionary changes resolve through @dict_owners; entity-level
      # changes (transform/scale/move, hidden, material, layer) arrive
      # with the entity or its definition - recompute the owning target
      # so live builtins like lenx stay current.
      def on_entity_changed(e)
        targets = if (owner = Observers.owner_of_dict(e))
                    [owner]
                  else
                    Observers.targets_of(e)
                  end
        targets.each do |t|
          Engine.mark_dirty(t) if DCReader.engine_of(t) == :osdc
        end
        schedule_push
      end

      # ------------------------------------------------------------------
      # State snapshot
      # ------------------------------------------------------------------

      def state(model)
        ts = Selection.targets(model)
        sets = ts.map do |t|
          DCReader.read(t, dict_name: DCReader.dict_name_for(t), entity_id: register(t))
        end
        {
          "version" => VERSION,
          "dcAvailable" => DCBridge.available?,
          "functions" => Expression::FUNCTIONS,
          "actions" => Expression::Evaluator::ACTIONS,
          "builtins" => DCReader::BUILTIN_ATTRS,
          "skprops" => SkProps::PROP_NAMES,
          "modelprops" => SkProps::MODEL_PROP_NAMES,
          "sceneprops" => SkProps::SCENE_PROP_NAMES,
          "globals" => global_params(model),
          "entities" => sets.each_with_index.map do |ps, i|
            h = ps.to_h
            h["label"] = entity_label(ts[i])
            h["instanceName"] = instance_name_of(ts[i])
            h["engine"] = ps.engine.to_s
            h["dynamic"] = DCReader.dynamic?(ts[i])
            h["graph"] = entity_graph(ps)
            h["sketchup"] = skprop_rows(ts[i], ps)
            h["dictionaries"] = dict_rows(ts[i], ps)
            h
          end,
          "batch" => batch_state(sets, ts)
        }
      end

      # Section rows for the foldable "SketchUp" section: live properties
      # plus any stored driver formula (sketchup!<prop>) and its error.
      def skprop_rows(entity, ps)
        SkProps.list(entity).map do |row|
          p = ps["sketchup!#{row['name']}"]
          row.merge("formula" => p&.formula.to_s, "error" => p&.error.to_s)
        end
      end

      # Same for the "Attribute dictionaries" section (<dict>!<key> drivers).
      def dict_rows(entity, ps)
        SkProps.dictionaries(entity).map do |d|
          d.merge("attrs" => d["attrs"].map do |a|
            p = ps["#{d['name']}!#{a['name']}"]
            a.merge("formula" => p&.formula.to_s, "error" => p&.error.to_s)
          end)
        end
      end

      # "dictname!key" strings for node-editor palettes: only pairs that
      # are valid scope!key syntax (both sides ident-safe). Exotic names
      # stay reachable via DICTATTR("dict", "key").
      def dict_scope_names(entity)
        ident = /\A[a-z_][a-z0-9_]*\z/i
        SkProps.dictionaries(entity).flat_map do |d|
          next [] unless d["name"] =~ ident

          d["attrs"].filter_map do |a|
            "#{d['name']}!#{a['name']}" if a["name"] =~ ident
          end
        end
      end

      # Batch edits only make sense across already-dynamic targets - a
      # plain component contributes no params to the intersection.
      def batch_state(sets, targets)
        dyn = sets.zip(targets).select { |_, t| DCReader.dynamic?(t) }.map(&:first)
        return nil if dyn.length < 2

        { "count" => dyn.length, "shared" => Selection.shared_params(dyn) }
      end

      # Read-only dependency graph for the Graph tab: nodes are params plus
      # external (scope!) references and builtin refs without keys; edges
      # point dep -> dependent (data flow). Levels are longest-path depth
      # for the column layout.
      def entity_graph(ps)
        names = ps.params.map(&:name)
        known = names | DCReader::BUILTIN_ATTRS.map(&:downcase)
        deps = {} # param name => [local dep names]
        extdeps = {} # param name => [external node ids]
        ps.params.each do |p|
          next if p.formula.to_s.empty?

          locals = []
          Expression.refs(p.formula).each do |scope, n|
            n = n.to_s.downcase
            if scope.nil?
              locals << n if known.include?(n)
            else
              (extdeps[p.name] ||= []) << "#{scope}!#{n}"
            end
          end
          deps[p.name] = locals.uniq
        end

        g = Graph.new
        names.each { |n| g.add(n, deps[n] || []) }
        ordered, cyclic = g.order
        level = {}
        ordered.each do |k|
          ds = deps[k] || []
          level[k] = ds.empty? ? 0 : ds.map { |d| level[d] || 0 }.max + 1
        end

        used = {}
        deps.each do |n, ds|
          next if ds.empty?
          used[n] = true
          ds.each { |d| used[d] = true }
        end
        extdeps.each_key { |n| used[n] = true }
        cyclic.each { |n| used[n] = true }
        # Editable graph: every non-internal param stays visible as a
        # wire target even with no edges yet - builtins included, since
        # wiring one writes a formula and adopts it (that's how lenx or
        # onclick gain behavior in the first place).
        names.each { |n| used[n] = true unless ps[n]&.internal }

        nodes = names.select { |n| used[n] }.map do |n|
          { "id" => n, "level" => level[n] || 0, "cyclic" => cyclic.include?(n),
            "formula" => ps[n]&.formula, "hasFormula" => !(ps[n]&.formula.to_s.empty?),
            "doc" => param_doc(ps[n]) }
        end
        virtual = (used.keys - names).map { |n| { "id" => n, "virtual" => true } }
        extnodes = extdeps.values.flatten.uniq.map { |id| { "id" => id, "external" => true } }
        edges = []
        deps.each do |n, ds|
          ds.each do |d|
            edges << { "from" => d, "to" => n, "literal" => edge_literal(ps[d], ps[n]) }
          end
        end
        extdeps.each do |n, ids|
          ids.uniq.each { |id| edges << { "from" => id, "to" => n, "literal" => "0" } }
        end
        { "nodes" => nodes | extnodes | virtual, "edges" => edges.uniq }
      end

      # AstGraph doc for a param's formula, so the graph window can render
      # the formula as a drill-down subgraph. nil when unparseable/missing.
      def param_doc(p)
        return nil if p.nil? || p.formula.to_s.empty?

        AstGraph.to_graph(p.formula)
      rescue StandardError
        nil
      end

      # Value literal used when an edge is unlinked: the dep's current value
      # expressed in the DEPENDENT's formula units (bare numbers inside a
      # formula are interpreted in _<name>_formulaunits). Non-numeric values
      # become quoted strings; unknown (builtin w/o key, external) -> "0".
      def edge_literal(dep_p, target_p)
        return "0" if dep_p.nil?

        v = dep_p.value
        return "0" if v.nil?

        n = v.is_a?(Numeric) ? v : begin
          Float(v.to_s.strip)
        rescue StandardError
          nil
        end
        if n
          tu = target_p&.formulaunits.to_s.empty? ? target_p&.units : target_p.formulaunits
          tu = resolve_units(tu)
          n = Param.inches_to_unit(n, tu) if Param.length_unit?(tu)
          n.round(6).to_s
        else
          %("#{v.to_s.gsub('"', "")}")
        end
      end

      def global_params(model)
        dict = DCReader.dict_of(model, OS_DC_DICT)
        DCReader.attr_names(dict).sort.map do |n|
          { "name" => n, "value" => DCReader.dict_get(dict, n) }
        end
      end

      def instance_name_of(e)
        e.is_a?(Sketchup::ComponentInstance) ? e.name.to_s : nil
      end

      def entity_label(e)
        dn = begin
          DCReader.dict_name_for(e)
        rescue StandardError
          DC_DICT
        end
        nm = DCReader.dict_get(DCReader.dict_of(e, dn), "_name")
        if nm.nil? && e.is_a?(Sketchup::ComponentInstance)
          nm = DCReader.dict_get(DCReader.dict_of(e.definition, dn), "_name")
        end
        return nm.to_s unless nm.to_s.empty?

        if e.is_a?(Sketchup::ComponentInstance)
          n = e.name.to_s.empty? ? e.definition.name : e.name
          n.to_s
        else
          e.name.to_s.empty? ? "Group" : e.name.to_s
        end
      end

      # Deep-convert attribute values to JSON-native types.
      def json_safe(v)
        case v
        when Numeric, String, TrueClass, FalseClass, NilClass then v
        when Time then v.to_s
        when Array then v.map { |x| json_safe(x) }
        when Hash then v.to_h { |k, x| [k.to_s, json_safe(x)] }
        when Geom::Point3d, Geom::Vector3d then v.to_a
        else v.to_s
        end
      end
    end
  end
end
