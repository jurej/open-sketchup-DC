# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"

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
          next if Expression::FUNCTIONS.include?(fn)
          next if allow_actions && Expression::Evaluator::ACTIONS.include?(fn)

          errors << "unknown function '#{fn}'"
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
          else
            node = top_level?(entity) &&
                   Interact.node_named(scope, nil, entity, Sketchup.active_model)
            if node.nil?
              hints << "node '#{scope}' not verified here"
            else
              nps = DCReader.read(node, dict_name: DCReader.dict_name_for(node))
              errors << "node '#{scope}' has no attribute '#{n}'" if nps[n].nil?
            end
          end
        end
        { "ok" => errors.empty?, "errors" => errors.uniq, "hints" => hints.uniq }
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

      # Parse a UI-entered value as a plain number or a unit-suffixed
      # literal (450, -2.5, 10cm, 18", 3', 45deg).
      # Returns [number, suffix_unit|nil] or nil.
      def value_literal(s)
        return [s.to_f, nil] if s =~ /\A-?\d+(\.\d+)?\z/

        m = s.match(/\A(-?\d+(?:\.\d+)?)(mm|cm|m|in|ft|deg|degrees|"|')\z/i)
        m ? [m[1].to_f, VALUE_SUFFIX_UNITS[m[2].downcase]] : nil
      end

      # Type-check a UI-entered value against the param's declared type
      # before it is written. Returns a user-facing error string or nil.
      def validate_value(entity, name, raw, dict_name)
        param = DCReader.read(entity, dict_name: dict_name)[name]
        return nil if param.nil?

        s = raw.to_s.strip
        return nil if s.empty?

        types = [param.units, param.formulaunits].map { |u| u.to_s.upcase }
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
        num, suffix = s =~ /\A-?\d/ ? value_literal(s) : [nil, nil]
        if num
          if Param.length_unit?(units)
            # bare numbers arrive in display units; a suffixed literal
            # carries its own unit (10cm in a feet field is still 10cm)
            src = suffix && suffix != "DEGREES" ? suffix : units
            inches = Param.unit_to_inches(num, src)
            return inches if dict_name == OS_DC_DICT

            target = target_units.to_s.empty? ? units : target_units
            return Param.inches_to_unit(inches, target)
          end
          # numeric-typed field or a bare number anywhere -> store the
          # number; a length-suffixed literal in a text field stays text
          return num if suffix.nil? || suffix == "DEGREES" ||
                        NUMERIC_UNITS.include?(units.to_s.upcase)

          return s
        end
        return true if s == "true"
        return false if s == "false"

        s
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
          ["copy", "index of this generated copy (when copies &gt; 0)"]
        ]],
        ["Functions", [
          ["IF(test, then, else)", "conditional value"],
          ["CHOOSE(index, v1, v2, ...)", "pick the index-th value (1-based)"],
          ["CURRENT(\"name\")", "current value of an attribute"],
          ["MIN(a, b, ...) / MAX(a, b, ...)", "smallest / largest of the arguments"],
          ["ROUND(x, n) / INT / FLOOR / CEILING", "rounding"],
          ["ABS(x) / SQRT(x)", "absolute value / square root"],
          ["SIN / COS / TAN / ASIN / ACOS / ATAN", "trigonometry (radians)"],
          ["DEGREES(rad) / RADIANS(deg)", "angle conversion"],
          ["PI()", "3.14159..."],
          ["LARGEST / SMALLEST(list, k)", "k-th largest / smallest value"],
          ["NEAREST(x, v1, v2, ...)", "the listed value closest to x"],
          ["OPTIONINDEX(\"name\")", "index of the selected LIST option"],
          ["OPTIONVALUE(\"name\", \"label\")", "value mapped to a LIST option label"]
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
          @graph_pending = {
            "label" => entity_label(ent),
            "entityId" => eid,
            "graph" => entity_graph(read_graph_set(ent, eid))
          }
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
        @graph_pending = {
          "label" => entity_label(ent),
          "entityId" => data["entityId"].to_s,
          "graph" => entity_graph(read_graph_set(ent, data["entityId"].to_s))
        }
        push_graph
      rescue StandardError => e
        push_error(e.message)
      end

      def push_graph
        return if @graph_dialog.nil? || @graph_pending.nil?

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
        @graph_pending = {
          "label" => entity_label(ent),
          "entityId" => data["entityId"].to_s,
          "graph" => entity_graph(read_graph_set(ent, data["entityId"].to_s))
        }
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
            "attrs" => ps.names,
            "builtins" => DCReader::BUILTIN_ATTRS,
            "globals" => global_params(Sketchup.active_model).map { |g| g["name"] },
            "functions" => Expression::FUNCTIONS,
            "actions" => Expression::Evaluator::ACTIONS,
            "fnArity" => AstGraph::FN_ARITY,
            "fnVararg" => AstGraph::FN_VARARG,
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

      def functions_reference_html
        rows = FX_REFERENCE.map do |section, items|
          "<h2>#{section}</h2><table>" +
            items.map do |sig, desc|
              "<tr><td class='sig'>#{sig}</td><td class='desc'>#{desc}</td></tr>"
            end.join("") + "</table>"
        end.join("")
        <<~HTML
          <!DOCTYPE html><html><head><meta charset="utf-8"><style>
            body{background:#17181c;color:#d8d8de;font:13px/1.5 "Segoe UI",sans-serif;margin:14px}
            h1{font-size:15px;margin:0 0 10px;color:#4f9cf9}
            h2{font-size:12px;text-transform:uppercase;color:#8a8a93;margin:16px 0 6px;border-bottom:1px solid #2a2b31;padding-bottom:4px}
            table{width:100%;border-collapse:collapse}
            td{padding:3px 6px;vertical-align:top}
            tr:nth-child(odd){background:#1e1f24}
            .sig{font-family:Consolas,monospace;color:#b9a5f0;white-space:nowrap;width:45%}
            .desc{color:#a9a9b2}
          </style></head><body>
          <h1>Formula Reference</h1>
          #{rows}
          </body></html>
        HTML
      end

      # ------------------------------------------------------------------
      # Ruby -> JS state push
      # ------------------------------------------------------------------

      def schedule_push
        return if @push_pending

        @push_pending = true
        UI.start_timer(0.05, false) do
          @push_pending = false
          push_state
        end
      end

      def push_state
        return if @dialog.nil?

        json = JSON.generate(json_safe(state(Sketchup.active_model)))
        @dialog.execute_script("window.OpenDC && window.OpenDC.update(#{json})")
        Observers.watch_current(Sketchup.active_model)
      rescue StandardError => e
        puts "#{PLUGIN_NAME}: push_state failed - #{e.message}"
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
      def on_entity_changed(e)
        owner = Observers.owner_of_dict(e)
        Engine.mark_dirty(owner) if owner && DCReader.engine_of(owner) == :osdc
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
          "globals" => global_params(model),
          "entities" => sets.each_with_index.map do |ps, i|
            h = ps.to_h
            h["label"] = entity_label(ts[i])
            h["engine"] = ps.engine.to_s
            h["graph"] = entity_graph(ps)
            h
          end,
          "batch" => batch_state(sets)
        }
      end

      def batch_state(sets)
        return nil if sets.length < 2

        { "count" => sets.length, "shared" => Selection.shared_params(sets) }
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
        # editable graph: non-internal params stay visible as wire targets
        # even when they have no edges yet
        names.each { |n| used[n] = true unless ps[n]&.internal }

        nodes = names.select { |n| used[n] }.map do |n|
          { "id" => n, "level" => level[n] || 0, "cyclic" => cyclic.include?(n),
            "formula" => ps[n]&.formula, "hasFormula" => !(ps[n]&.formula.to_s.empty?) }
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
