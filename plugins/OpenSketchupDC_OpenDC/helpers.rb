# Open SketchUp Framework - Helpers Module
# Version: 0.3.0 - vendored copy wrapped as OpenSketchupDC::OpenDC::Helpers
# Source: open-sketchup-framework/src/open_sketchup_helpers.rb
# Regenerate with: powershell -File scripts/vendor_helpers.ps1

module OpenSketchupDC
  module OpenDC
    module Helpers
      VERSION = "0.3.0".freeze

      # =========================================================================
      # UNDO OPERATIONS
      # =========================================================================

      # Wraps a block in a proper SketchUp undo operation.
      # Automatically commits on success, aborts on error, logs backtrace,
      # and shows a friendly error dialog to the user.
      #
      # Re-entrant & coordinated: if ANY framework-conforming plugin already has
      # an operation open on this model, this yields to the existing transaction
      # instead of nesting model.start_operation (which would commit or corrupt
      # the outer one). Depth is tracked on the shared OpenSketchUp::Registry
      # when available, otherwise in a per-plugin local counter.
      #
      # NOTE: Prefer `next` over `return` inside the block — a `return` unwinds
      # past the commit below; undo_wrap detects this and commits in `ensure`,
      # but `next` keeps the flow obvious.
      #
      # Usage:
      #   OpenSketchUpHelpers.undo_wrap(model, "My Operation") do
      #     # ... modify the model ...
      #   end
      #
      def self.undo_wrap(model, operation_name, disable_ui: true, transparent: false)
        tracker = operation_tracker

        if tracker.operation_depth(model) > 0
          tracker.operation_enter(model)
          begin
            return yield
          ensure
            tracker.operation_leave(model)
          end
        end

        model.start_operation(operation_name, disable_ui, false, transparent)
        tracker.operation_enter(model)
        finished = false
        begin
          result = yield
          model.commit_operation
          tracker.operation_commit(model)
          finished = true
          result
        rescue StandardError => e
          begin
            model.abort_operation
          rescue StandardError
          end
          tracker.operation_abort(model)
          finished = true
          puts "Open SketchUp Framework: Operation '#{operation_name}' failed: #{e.message}"
          puts e.backtrace.join("\n") if e.backtrace
          UI.messagebox("Operation '#{operation_name}' failed: #{e.message}")
          raise e
        ensure
          # A `return`/`break` inside the block unwinds past the commit above.
          # Close the operation properly instead of leaking it open.
          unless finished
            begin
              if $!
                model.abort_operation
                tracker.operation_abort(model)
              else
                model.commit_operation
                tracker.operation_commit(model)
              end
            rescue StandardError
            end
          end
        end
      end

      # --- Transaction depth tracking -----------------------------------------
      # These mirror the OpenSketchUp::Registry API so `operation_tracker` can
      # treat either object polymorphically. Call undo_wrap, not these directly.

      def self.operation_tracker
        if defined?(OpenSketchUp::Registry)
          OpenSketchUp::Registry
        else
          self
        end
      end

      def self.operation_depth(model)
        local_operation_depths[model]
      end

      def self.operation_open?(model)
        operation_depth(model) > 0
      end

      def self.operation_enter(model)
        local_operation_depths[model] += 1
      end

      def self.operation_leave(model)
        decrement_local_operation(model)
      end

      def self.operation_commit(model)
        decrement_local_operation(model)
      end

      def self.operation_abort(model)
        decrement_local_operation(model)
      end

      def self.local_operation_depths
        @local_operation_depths ||= Hash.new(0)
      end
      private_class_method :local_operation_depths

      def self.decrement_local_operation(model)
        depths = local_operation_depths
        remaining = depths[model] - 1
        if remaining <= 0
          depths.delete(model)
        else
          depths[model] = remaining
        end
      end
      private_class_method :decrement_local_operation

      # =========================================================================
      # ENTITY HELPERS
      # =========================================================================

      # Get all faces from an Entities collection (or nested groups/components).
      #
      # Options:
      #   recursive: false — only top-level entities
      #   recursive: true  — traverse into groups and component instances
      #
      def self.get_faces(entities, recursive: false)
        if recursive
          collect_recursive(entities, Sketchup::Face)
        else
          entities.grep(Sketchup::Face)
        end
      end

      # Get all edges from an Entities collection.
      def self.get_edges(entities, recursive: false)
        if recursive
          collect_recursive(entities, Sketchup::Edge)
        else
          entities.grep(Sketchup::Edge)
        end
      end

      # Get all groups from an Entities collection.
      def self.get_groups(entities, recursive: false)
        if recursive
          collect_recursive(entities, Sketchup::Group)
        else
          entities.grep(Sketchup::Group)
        end
      end

      # Get all component instances from an Entities collection.
      def self.get_components(entities, recursive: false)
        if recursive
          collect_recursive(entities, Sketchup::ComponentInstance)
        else
          entities.grep(Sketchup::ComponentInstance)
        end
      end

      # Recursively collect entities of a given type.
      def self.collect_recursive(entities, type, results = [])
        entities.each do |entity|
          results << entity if entity.is_a?(type)
          if entity.is_a?(Sketchup::Group)
            collect_recursive(entity.entities, type, results)
          elsif entity.is_a?(Sketchup::ComponentInstance)
            collect_recursive(entity.definition.entities, type, results)
          end
        end
        results
      end
      private_class_method :collect_recursive

      # =========================================================================
      # SELECTION HELPERS
      # =========================================================================
      # NOTE: Selection is view state, not model data. Changing it does NOT need
      # to be wrapped in undo_wrap — doing so adds a junk entry to Edit > Undo.

      # Filter the current selection by entity type.
      #
      # Usage:
      #   faces = OpenSketchUpHelpers.selection_filter(model, Sketchup::Face)
      #
      def self.selection_filter(model, type)
        model.selection.grep(type)
      end

      # Replace the current selection with the given entities.
      def self.selection_set(model, entities)
        model.selection.clear
        model.selection.add(entities)
        entities
      end

      # =========================================================================
      # GEOMETRY & BOUNDS HELPERS
      # =========================================================================

      # Get the center point (Geom::Point3d) of an entity's bounding box.
      def self.bounds_center(entity)
        entity.bounds.center
      end

      # Get the dimensions [width, height, depth] of an entity's bounding box.
      def self.bounds_dimensions(entity)
        b = entity.bounds
        [b.width, b.height, b.depth]
      end

      # =========================================================================
      # UNIT & CONVERSION HELPERS
      # =========================================================================

      # Convert millimeters to inches (SketchUp internal units).
      # Returns a plain Float — safe to pass to any SketchUp API method that
      # takes a Length (Float and Length are interchangeable).
      def self.to_inches(length_mm)
        length_mm.to_f / 25.4
      end

      # Convert inches (SketchUp internal units) to millimeters. Returns a Float.
      def self.to_mm(length_inches)
        length_inches.to_f * 25.4
      end

      # Format an area in square inches to a human-readable string (sq meters or sq feet).
      # NOTE: face.area is ALWAYS in square inches (Float), regardless of model units.
      def self.format_area(area_sq_inches, unit: :sq_m)
        case unit
        when :sq_m, :sq_meters, "m2"
          sq_m = area_sq_inches * 0.00064516
          "#{sq_m.round(2)} m²"
        when :sq_ft, :sq_feet, "ft2"
          sq_ft = area_sq_inches / 144.0
          "#{sq_ft.round(2)} sq ft"
        else
          "#{area_sq_inches.round(2)} sq in"
        end
      end

      # =========================================================================
      # INPUT DIALOG HELPERS
      # =========================================================================

      # Show an input dialog with a simpler API than UI.inputbox.
      # Returns an array of STRING values (convert with .to_f / .to_i), or nil
      # if the user cancelled.
      #
      # Usage:
      #   results = OpenSketchUpHelpers.input_dialog(
      #     title: "My Dialog",
      #     prompts: ["Width", "Height", "Material"],
      #     defaults: [10.0, 5.0, "Wood"],
      #     lists: [nil, nil, "Wood|Steel|Concrete"]
      #   )
      #
      def self.input_dialog(title:, prompts:, defaults: nil, lists: nil)
        defaults ||= Array.new(prompts.length, "")
        lists ||= Array.new(prompts.length, "")
        result = UI.inputbox(prompts, defaults, lists, title)
        result == false ? nil : result
      end

      # Show an HTML dialog (SketchUp 2017+). Prefer this over UI.inputbox for
      # anything beyond a few text fields, and NEVER use the deprecated
      # UI::WebDialog. `block` receives arguments sent from JS via
      # `sketchup.osf_callback(arg1, arg2, ...)`. Returns the dialog.
      #
      # Usage:
      #   dialog = OpenSketchUpHelpers.html_dialog(
      #     title: "My Panel",
      #     html: "<button onclick='sketchup.osf_callback(42)'>Go</button>"
      #   ) { |value| do_something(value) }
      #
      def self.html_dialog(title:, html:, width: 420, height: 360, preferences_key: nil, &block)
        dialog = UI::HtmlDialog.new(
          dialog_title: title,
          preferences_key: preferences_key || "OSF_#{title}",
          scrollable: true,
          resizable: true,
          width: width,
          height: height,
          style: UI::HtmlDialog::STYLE_DIALOG
        )
        dialog.add_action_callback("osf_callback") { |_, *args| block.call(*args) } if block
        dialog.set_html(html)
        dialog.show
        dialog
      end

      # =========================================================================
      # MATERIAL HELPERS
      # =========================================================================

      # Apply a color to entities. Creates a material if needed.
      #
      # Usage:
      #   OpenSketchUpHelpers.apply_color(model, faces, [255, 0, 0])
      #   OpenSketchUpHelpers.apply_color(model, faces, "Red")
      #   OpenSketchUpHelpers.apply_color(model, faces, Sketchup::Color.new(255, 0, 0))
      #
      def self.apply_color(model, entities, color, material_name: nil)
        color = Sketchup::Color.new(*color) if color.is_a?(Array)
        material_name ||= default_material_name(color)

        material = model.materials[material_name]
        unless material
          material = model.materials.add(material_name)
          material.color = color
        end

        entities = [entities] unless entities.is_a?(Array)
        entities.each { |e| e.material = material }
        material
      end

      def self.default_material_name(color)
        if color.is_a?(Sketchup::Color)
          "OSF_#{color.to_a[0..2].join('_')}"
        else
          "OSF_#{color.to_s.gsub(/[^a-zA-Z0-9]+/, '_')}"
        end
      end
      private_class_method :default_material_name

      # =========================================================================
      # MIDDLEWARE BUS (DELEGATES TO OpenSketchUp::Registry)
      # =========================================================================
      # The optional Open SketchUp Registry extension provides shared services:
      # capabilities (RPC), events (pub/sub), shared state, transaction depth,
      # and a shared panel host. Every adapter degrades gracefully (or falls
      # back locally) when the registry extension is absent or disabled.

      # --- Capabilities (service registry) ------------------------------------

      # Register a capability that this plugin provides. Multiple plugins may
      # provide the same capability_id; `priority` decides the default provider
      # (ties: most recently registered wins). `parameters` documents the
      # keyword-argument contract for callers (including AI agents).
      def self.registry_register(capability_id, version:, callable:, description: "",
                                 provider: nil, priority: 0, parameters: nil)
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.register(capability_id,
                                        version: version, callable: callable, description: description,
                                        provider: provider, priority: priority, parameters: parameters)
      end

      # Find a registered capability (effective provider, or a specific one).
      def self.registry_find(capability_id, provider: nil)
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.find(capability_id, provider: provider)
      end

      # All providers registered for a capability, keyed by provider id.
      def self.registry_providers(capability_id)
        registry_flush_pending
        return {} unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.providers(capability_id)
      end

      # List all registered capabilities (effective providers).
      def self.registry_list
        registry_flush_pending
        return {} unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.list
      end

      # Check if a capability is available.
      def self.registry_available?(capability_id)
        registry_flush_pending
        defined?(OpenSketchUp::Registry) && OpenSketchUp::Registry.available?(capability_id)
      end

      # Invoke a registered capability. Pass `provider: "Some::Namespace"` to
      # select a specific provider when several are registered.
      def self.registry_call(capability_id, *args, **kwargs, &block)
        registry_flush_pending
        raise LoadError, "Open SketchUp Registry extension is not available." unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.call(capability_id, *args, **kwargs, &block)
      end

      # Introspect a capability's contract (provider, version, parameters,
      # description) — what AI agents should consult before hardcoding an ID.
      def self.registry_describe(capability_id, provider: nil)
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.describe(capability_id, provider: provider)
      end

      # Snapshot of the whole bus: all capabilities+providers, event topics,
      # state namespaces, and panels.
      def self.registry_catalog
        registry_flush_pending
        return {} unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.catalog
      end

      # --- Load-order handshake ------------------------------------------------
      # The registry may load after this plugin (alphabetical order) or be
      # enabled mid-session via Extension Manager. Register a callback that runs
      # once the registry appears. The callback should return true/false to
      # signal success; it is retried a few times via UI timers, whenever any
      # registry_* adapter is used, and on app lifecycle events.
      #
      # Usage:
      #   register_capabilities
      #   Helpers.registry_when_ready { register_capabilities } unless @capabilities_registered
      #
      REGISTRY_RETRY_DELAYS = [0, 0.5, 2, 5].freeze

      def self.registry_when_ready(&block)
        (@registry_pending ||= []) << block
        registry_flush_pending
        registry_start_watcher
        nil
      end

      def self.registry_flush_pending
        return unless defined?(OpenSketchUp::Registry)

        pending = @registry_pending
        @registry_pending = []
        pending&.each { |callback| (@registry_pending ||= []) << callback unless callback.call }
        nil
      end

      def self.registry_start_watcher
        return if @registry_watcher_started

        @registry_watcher_started = true
        helpers = self

        REGISTRY_RETRY_DELAYS.each do |delay|
          UI.start_timer(delay, false) { helpers.registry_flush_pending }
        end

        # Covers the registry being enabled long after startup.
        observer = Class.new(Sketchup::AppObserver) do
          define_method(:expectsStartupModelNotifications) { true }
          define_method(:onNewModel) { |*| helpers.registry_flush_pending }
          define_method(:onOpenModel) { |*| helpers.registry_flush_pending }
        end.new
        Sketchup.add_observer(observer)
        @registry_observer = observer
      end

      # --- Events (publish / subscribe) ----------------------------------------
      # Semantic domain events ("material.faces_colored") let plugins react to
      # each other without observers or tight coupling. Payload is a Hash.
      # Events emitted inside an open coordinated transaction are delivered only
      # after the outermost operation commits (dropped if it aborts).
      #
      #   Helpers.registry_on("geom.walls_created") { |payload| update_takeoff(payload[:count]) }
      #   Helpers.registry_emit("geom.walls_created", count: 4, entities: ids)
      #
      def self.registry_on(topic, &block)
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.subscribe(topic, &block)
      end

      def self.registry_off(topic, callable)
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.unsubscribe(topic, callable)
      end

      def self.registry_emit(topic, **payload)
        registry_flush_pending
        return 0 unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.publish(topic, **payload)
      end

      # --- Shared state ----------------------------------------------------------
      # Namespaced in-memory store for cross-plugin data exchange. Defaults to
      # this plugin's own namespace ("AuthorName::PluginName"). Falls back to a
      # local store when the registry is absent. Session-scoped — use entity
      # attribute dictionaries for data that must persist in the .skp file.
      #
      #   Helpers.state_set("last_report", {...})
      #   Helpers.state_get("spatial_index", namespace: "Other::Plugin")
      #
      def self.state_set(key, value, namespace: nil)
        namespace ||= default_state_namespace
        if defined?(OpenSketchUp::Registry)
          registry_flush_pending
          OpenSketchUp::Registry.state_set(namespace, key, value)
        else
          (local_state[namespace] ||= {})[key.to_s] = value
        end
      end

      def self.state_get(key, default: nil, namespace: nil)
        namespace ||= default_state_namespace
        if defined?(OpenSketchUp::Registry)
          registry_flush_pending
          OpenSketchUp::Registry.state_get(namespace, key, default: default)
        else
          local_state.fetch(namespace, {}).fetch(key.to_s, default)
        end
      end

      def self.state_delete(key, namespace: nil)
        namespace ||= default_state_namespace
        if defined?(OpenSketchUp::Registry)
          registry_flush_pending
          OpenSketchUp::Registry.state_delete(namespace, key)
        else
          ns = local_state[namespace]
          ns&.delete(key.to_s)
          local_state.delete(namespace) if ns&.empty?
        end
      end

      def self.default_state_namespace
        # "AuthorName::PluginName::Helpers" -> "AuthorName::PluginName"
        module_name = name
        module_name.include?("::") ? module_name.sub(/::[^:]+$/, "") : module_name
      end
      private_class_method :default_state_namespace

      def self.local_state
        @local_state ||= {}
      end
      private_class_method :local_state

      # --- Panels (shared UI host) -----------------------------------------------
      # Register a lightweight HTML panel that renders inside the shared
      # "Open SketchUp Hub" dialog — one CEF process instead of a separate
      # browser window per plugin. `html` may be a String or a callable
      # returning a String (re-evaluated each time the panel is opened).
      #
      # Interactivity: <script> tags in panel HTML do not execute, but inline
      # handlers do. Panels call OSFHub.send('your.panel.id', {...}) from JS;
      # the payload reaches `handler` (a block receiving a Hash). Return a
      # String from the handler to re-render the panel.
      #
      #   Helpers.register_panel("my.panel", title: "Takeoff",
      #     html: "<button onclick=\"OSFHub.send('my.panel', {cmd:'go'})\">Go</button>",
      #     handler: ->(payload) { "<p>You clicked #{payload['cmd']}</p>" })
      #   Helpers.show_hub
      #
      def self.register_panel(panel_id, title:, html:, handler: nil, &block)
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.register_panel(panel_id,
                                              title: title, html: html, provider: default_state_namespace,
                                              handler: handler || block)
      end

      def self.unregister_panel(panel_id)
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.unregister_panel(panel_id)
      end

      def self.show_hub
        registry_flush_pending
        return nil unless defined?(OpenSketchUp::Registry)

        OpenSketchUp::Registry.show_hub
      end

      # =========================================================================
      # MENU HELPERS
      # =========================================================================

      # Add a menu item under Extensions, avoiding duplicates.
      # Creates a submenu if submenu_name is provided.
      #
      # Usage:
      #   OpenSketchUpHelpers.add_menu_item("My Tools", "Do Something") { do_it }
      #
      def self.add_menu_item(submenu_name, item_name, &block)
        extensions_menu = UI.menu("Extensions")
        submenu = extensions_menu.add_submenu(submenu_name)
        submenu.add_item(item_name, &block)
      end

      # =========================================================================
      # VALIDATION HELPERS
      # =========================================================================

      # Check that there is an active model. Shows an error if not.
      def self.require_model
        model = Sketchup.active_model
        unless model
          UI.messagebox("No active model found. Please open or create a model first.")
          return nil
        end
        model
      end

      # Check that there is a selection. Shows an error if empty.
      def self.require_selection(model)
        if model.selection.empty?
          UI.messagebox("Please select at least one entity first.")
          return nil
        end
        model.selection
      end

      # =========================================================================
      # ATTRIBUTE HELPERS
      # =========================================================================

      # Get/set attributes on entities using a consistent dictionary name.
      # Uses "open_sketchup" as the default attribute dictionary.
      #
      # Usage:
      #   OpenSketchUpHelpers.set_attribute(face, "category", "wall")
      #   value = OpenSketchUpHelpers.get_attribute(face, "category")
      #
      def self.set_attribute(entity, key, value, dict_name: "open_sketchup")
        entity.set_attribute(dict_name, key, value)
      end

      def self.get_attribute(entity, key, default: nil, dict_name: "open_sketchup")
        entity.get_attribute(dict_name, key, default)
      end
    end
  end
end
