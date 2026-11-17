# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Optional capabilities on the Open SketchUp Registry middleware bus.
    # Fully optional - the plugin works without the registry installed.
    module RegistryCaps
      module_function

      def register_capabilities
        return true if @capabilities_registered
        return false unless defined?(OpenSketchUp::Registry)

        Helpers.registry_register("dc.params.list",
                                  version: VERSION,
                                  description: "List dynamic parameters of selected dynamic " \
                                               "components. Returns: [Hash]",
                                  callable: method(:cap_list))

        Helpers.registry_register("dc.params.set",
                                  version: VERSION,
                                  description: "Set one dynamic parameter on a component identified by persistent_id.",
                                  parameters: { persistent_id: "Integer", name: "String", value: "Numeric|String" },
                                  callable: method(:cap_set))

        Helpers.registry_register("dc.params.batch_set",
                                  version: VERSION,
                                  description: "Set one shared dynamic parameter on all selected dynamic components.",
                                  parameters: { name: "String", value: "Numeric|String" },
                                  callable: method(:cap_batch_set))

        @capabilities_registered = true
      end

      def cap_list(**_kw)
        Selection.dynamic_targets(Sketchup.active_model).map do |t|
          DCReader.read(t, dict_name: DCReader.dict_name_for(t)).to_h
        end
      end

      def cap_set(persistent_id:, name:, value:)
        model = Sketchup.active_model
        e = find_by_pid(model, persistent_id)
        raise "entity #{persistent_id} not found" unless e

        dict_name = DCReader.dict_name_for(e)
        Helpers.undo_wrap(model, "Open DC: Set #{name}") do
          DCWriter.set_value(e, name, value, dict_name: dict_name)
        end
        reevaluate(e, dict_name)
        true
      end

      def cap_batch_set(name:, value:)
        model = Sketchup.active_model
        ts = Selection.dynamic_targets(model)
        raise "no dynamic components selected" if ts.empty?

        classic = []
        Helpers.undo_wrap(model, "Open DC: Batch set #{name}") do
          ts.each do |t|
            dict_name = DCReader.dict_name_for(t)
            DCWriter.set_value(t, name, value, dict_name: dict_name)
            dict_name == OS_DC_DICT ? Engine.mark_dirty(t) : classic << t
          end
        end
        DCBridge.redraw_all!(classic)
        ts.length
      end

      def reevaluate(entity, dict_name)
        dict_name == OS_DC_DICT ? Engine.mark_dirty(entity) : DCBridge.redraw!(entity)
      end

      def find_by_pid(model, pid)
        if model.respond_to?(:find_entity_by_persistent_id)
          model.find_entity_by_persistent_id(pid)
        else
          model.entities.find { |e| e.persistent_id == pid }
        end
      end
    end

    register_capabilities = RegistryCaps.method(:register_capabilities)
    register_capabilities.call
    Helpers.registry_when_ready { RegistryCaps.register_capabilities }
  end
end
