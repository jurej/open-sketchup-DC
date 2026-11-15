require "json"

module OpenSketchupDC
  module OpenDC
    # HtmlDialog bridge for the parameter panel. JS sends a single JSON
    # message {action, payload} through the "dc" action callback; state is
    # pushed back as a JSON snapshot via window.OpenDC.update(state).
    module Panel
      PANEL_FILE = File.join(PLUGIN_DIR, "ui", "panel", "index.html")

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
        when "convert"       then with_entity(p["entityId"]) do |e|
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
          value = coerce_value(p["value"], param_units(e, p["name"]))
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
          value = coerce_value(p["value"], param_units(e, p["name"]))
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
          Helpers.undo_wrap(Sketchup.active_model, "Open DC: Add #{p['name']}") do
            DCWriter.add_param(e,
                               name: p["name"],
                               label: p["label"],
                               formlabel: p["formlabel"],
                               access: p["access"] || ACCESS_TEXTBOX,
                               value: coerce_value(p["value"]),
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
            value = coerce_value(p["value"], param_units(e, name))
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

      # Convert a UI-entered value to its stored form. Numbers typed into a
      # length-unit field (CENTIMETERS etc.) arrive in display units - internal
      # storage is always inches.
      def coerce_value(v, units = nil)
        return v if v.is_a?(Numeric) || v == true || v == false

        s = v.to_s.strip
        if s =~ /\A-?\d+(\.\d+)?\z/
          n = s.to_f
          n = Param.unit_to_inches(n, units) if Param.length_unit?(units)
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
          "globals" => global_params(model),
          "entities" => sets.each_with_index.map do |ps, i|
            h = ps.to_h
            h["label"] = entity_label(ts[i])
            h["engine"] = ps.engine.to_s
            h
          end,
          "batch" => batch_state(sets)
        }
      end

      def batch_state(sets)
        return nil if sets.length < 2

        { "count" => sets.length, "shared" => Selection.shared_params(sets) }
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
