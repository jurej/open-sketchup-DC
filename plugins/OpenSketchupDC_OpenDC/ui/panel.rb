require "json"

module OpenSketchupDC
  module OpenDC
    # HtmlDialog bridge for the parameter panel. JS sends a single JSON
    # message {action, payload} through the "dc" action callback; state is
    # pushed back as a JSON snapshot via window.OpenDC.update(state).
    module Panel
      PANEL_FILE = File.join(PLUGIN_DIR, "ui", "panel", "index.html")
      GRAPH_FILE = File.join(PLUGIN_DIR, "ui", "graph", "index.html")

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
        return e if e && begin
          e.valid?
        rescue StandardError
          false
        end

        nil
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
        when "batchSet"      then cmd_batch_set(p)
        when "redraw"        then cmd_redraw(p)
        when "validateFormula" then cmd_validate_formula(p)
        when "fxDocs"        then cmd_fx_docs
        when "graph"         then cmd_graph(p["entityId"])
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

      def cmd_batch_set(p)
        ids = p["entityIds"] || []
        entities = ids.map { |id| entity(id) }.compact
        return push_error("No matching entities.") if entities.empty?

        name = p["name"]
        model = Sketchup.active_model
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
          return { "ok" => false, "errors" => ["syntax: #{e.message}"], "hints" => hints }
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
        if s =~ /\A-?\d+(\.\d+)?\z/
          n = s.to_f
          if Param.length_unit?(units)
            inches = Param.unit_to_inches(n, units)
            return inches if dict_name == OS_DC_DICT

            target = target_units.to_s.empty? ? units : target_units
            return Param.inches_to_unit(inches, target)
          end
          return n
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
          ps = DCReader.read(ent, dict_name: DCReader.dict_name_for(ent), entity_id: eid)
          @graph_pending = {
            "label" => entity_label(ent),
            "graph" => entity_graph(ps)
          }
          if @graph_dialog.nil?
            @graph_dialog = ::UI::HtmlDialog.new(
              dialog_title: "Open DC - Dependency Graph",
              preferences_key: "#{PLUGIN_ID}_graph",
              scrollable: true,
              resizable: true,
              width: 640,
              height: 520,
              min_width: 320,
              min_height: 240,
              style: ::UI::HtmlDialog::STYLE_UTILITY
            )
            @graph_dialog.add_action_callback("gready") do |_ctx, arg|
              @gqa = arg unless arg.to_s.empty? # dev/QA read-back channel
              push_graph
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

      def push_graph
        return if @graph_dialog.nil? || @graph_pending.nil?

        json = JSON.generate(json_safe(@graph_pending))
        @graph_dialog.execute_script("window.renderGraph && window.renderGraph(#{json})")
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

        nodes = names.select { |n| used[n] }.map do |n|
          { "id" => n, "level" => level[n] || 0, "cyclic" => cyclic.include?(n) }
        end
        virtual = (used.keys - names).map { |n| { "id" => n, "virtual" => true } }
        extnodes = extdeps.values.flatten.uniq.map { |id| { "id" => id, "external" => true } }
        edges = []
        deps.each { |n, ds| ds.each { |d| edges << { "from" => d, "to" => n } } }
        extdeps.each { |n, ids| ids.uniq.each { |id| edges << { "from" => id, "to" => n } } }
        { "nodes" => nodes | extnodes | virtual, "edges" => edges.uniq }
      end

      def global_params(model)
        dict = DCReader.dict_of(model, OS_DC_DICT)
        DCReader.attr_names(dict).sort.map do |n|
          { "name" => n, "value" => DCReader.dict_get(dict, n) }
        end
      end

      def entity_label(e)
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
