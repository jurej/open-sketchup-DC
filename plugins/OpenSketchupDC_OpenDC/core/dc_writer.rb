module OpenSketchupDC
  module OpenDC
    # Writes params back to "dynamic_attributes" or "open_dc" dictionaries.
    #
    #   value edits  -> instance dict, plain key (per-instance override)
    #   meta edits   -> definition dict (components) or instance dict (groups),
    #                   as _<attr>_<field>
    #   new params   -> full meta cluster on the definition/group dict
    #
    # Classic DC quirk (verified against Trimble's engine): _<name>_formula is
    # the authoritative user input slot; <name> is only the computed cache the
    # engine rewrites on redraw. So value writes for the classic dict target
    # the formula slot, while our own open_dc dict keeps literal values on the
    # plain key.
    module DCWriter
      module_function

      def owner_for(entity)
        entity.is_a?(Sketchup::ComponentInstance) ? entity.definition : entity
      end

      def set_value(entity, name, value, dict_name: DC_DICT)
        key = value_key(name, dict_name)
        value = value.to_s if dict_name == DC_DICT
        entity.set_attribute(dict_name, key, value)
      end

      def set_default(entity, name, value, dict_name: DC_DICT)
        key = value_key(name, dict_name)
        value = value.to_s if dict_name == DC_DICT
        owner_for(entity).set_attribute(dict_name, key, value)
      end

      # Authoritative storage slot for user-entered values per engine.
      def value_key(name, dict_name)
        dict_name == DC_DICT ? "_#{name.to_s.downcase}_formula" : name.to_s.downcase
      end

      def set_meta(entity, name, field, value, dict_name: DC_DICT)
        owner_for(entity).set_attribute(dict_name, "_#{name.to_s.downcase}_#{field}", value)
      end

      # Raw key writes (system keys such as "_engine", "_name").
      def set_system(entity, key, value, dict_name: DC_DICT)
        owner_for(entity).set_attribute(dict_name, key.to_s, value)
      end

      # Creates a full attribute cluster like the DC editor does.
      def add_param(entity, name:, label: nil, formlabel: nil,
                    access: ACCESS_TEXTBOX, value: "", units: "STRING",
                    options: nil, formula: nil, dict_name: DC_DICT)
        n = name.to_s.downcase
        stored = dict_name == DC_DICT ? value.to_s : value
        owner_for(entity).set_attribute(dict_name, n, stored)
        set_meta(entity, n, "label", label || name.to_s)
        set_meta(entity, n, "access", access)
        set_meta(entity, n, "units", units)
        set_meta(entity, n, "formlabel", formlabel || label || name.to_s)
        set_meta(entity, n, "options", options) unless options.nil?
        f = formula
        f = value.to_s if f.nil? && dict_name == DC_DICT
        set_meta(entity, n, "formula", f) unless f.nil?
        n
      end

      # Removes a param: the value key, all _<name>_* meta keys, and any
      # per-instance _inst_ copies, from both dictionaries.
      def delete_param(entity, name, dict_name: DC_DICT)
        n = name.to_s.downcase
        targets = [entity]
        targets << entity.definition if entity.is_a?(Sketchup::ComponentInstance)
        targets.uniq.each do |t|
          dict = DCReader.dict_of(t, dict_name)
          next if dict.nil?

          DCReader.dict_keys(dict).each do |k|
            next unless k == n || k == "_inst_#{n}" ||
                        k.start_with?("_#{n}_") || k.start_with?("_inst__#{n}_")

            dict_delete(dict, k)
          end
        end
      end

      def dict_delete(dict, key)
        dict.respond_to?(:delete_key) ? dict.delete_key(key) : dict.delete(key)
      end
    end
  end
end
