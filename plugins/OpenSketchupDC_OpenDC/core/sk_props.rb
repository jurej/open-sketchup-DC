# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Native SketchUp entity properties (the `sketchup!` formula scope) and
    # foreign attribute-dictionary access (`dictname!key`, `DICTATTR()`).
    #
    # Properties read live entity/definition state - nothing is stored in
    # the open_dc dictionary, so `sketchup!name` always reflects the current
    # SketchUp-side value. Writable properties are assigned through `write`;
    # inherently read-only ones (guid, ids, typename) raise.
    #
    # Dictionaries are accessed case-insensitively on the instance AND its
    # definition, so `su_instanceset!price` and `DICTATTR("SU_InstanceSet",
    # "Price")` resolve the same key. Reads return scalars; structured
    # values (arrays, points, times) stringify so concat still works.
    # Writes are scalar-only - overwriting a nested structure would corrupt
    # the owning plugin's data.
    module SkProps
      # [prop name, panel label, writable, tooltip]. Ordered for display.
      # `name` maps to the definition name on components (the "component
      # name" most users mean) and to the entity name on groups - classic
      # DC's Name info field is definition-level too.
      PROPS = [
        ["name",         "Name",          true,
         "sketchup!name - component definition / group name; a write " \
         "renames every instance of the definition"],
        ["instname",     "Instance name", true,
         "sketchup!instname - Entity Info instance name (components only)"],
        ["description",  "Description",   true,
         "sketchup!description - definition / group description"],
        ["summary",      "Summary",       true,
         "sketchup!summary - definition summary (components only)"],
        ["itemcode",     "Item code",     true,
         "sketchup!itemcode - definition item code (components only)"],
        ["creator",      "Creator",       true,
         "sketchup!creator - definition creator field (components only)"],
        ["layer",        "Layer (tag)",   true,
         "sketchup!layer - assigned layer/tag name; write requires an " \
         "existing layer"],
        ["guid",         "GUID",          false,
         "sketchup!guid - definition/group persistent GUID"],
        ["persistentid", "Persistent ID", false,
         "sketchup!persistentid - stable id for this model"],
        ["entityid",     "Entity ID",     false,
         "sketchup!entityid - per-session entity id"],
        ["typename",     "Type",          false,
         "sketchup!typename - SketchUp API class name"],
        ["instances",    "Used in model", false,
         "sketchup!instances - placed instance count (components only)"]
      ].freeze

      PROP_NAMES = PROPS.map(&:first).freeze
      WRITABLE = PROPS.select { |_, _, w, _| w }.map(&:first).freeze

      # Dicts our engines own - resolvable via scope but not listed in the
      # panel's "Attribute dictionaries" section (they're the params).
      ENGINE_DICTS = [DC_DICT, OS_DC_DICT].freeze

      module_function

      # --- native properties ----------------------------------------------

      # Names the `sketchup!` scope resolves: the property table plus the
      # live geometric builtins (sketchup!x, sketchup!lenx, ...).
      def known?(name)
        n = name.to_s.downcase
        PROP_NAMES.include?(n) || DCReader::BUILTIN_UNITS.key?(n)
      end

      def writable?(entity, name)
        n = name.to_s.downcase
        return false unless WRITABLE.include?(n)
        return false if n == "instname" && !entity.is_a?(Sketchup::ComponentInstance)
        if %w[summary itemcode creator].include?(n)
          return prop_owner(entity).respond_to?(:"#{n}=")
        end

        true
      end

      # The object a definition-level property lives on: the definition for
      # component instances, the entity itself for groups.
      def prop_owner(entity)
        entity.is_a?(Sketchup::ComponentInstance) ? entity.definition : entity
      end

      # Live property value; geometric names delegate to the reader's
      # builtin synthesis so sketchup!lenx matches the LenX row exactly.
      # Raises Expression::Error for unknown names (formula context).
      def value_of(entity, name, dict_name: OS_DC_DICT)
        n = name.to_s.downcase
        if DCReader::BUILTIN_UNITS.key?(n)
          return DCReader.builtin_values(entity, dict_name)[n]
        end
        unless PROP_NAMES.include?(n)
          raise Expression::Error, "unknown SketchUp attribute '#{n}'"
        end

        read_prop(entity, n)
      end

      def read_prop(entity, n)
        owner = prop_owner(entity)
        case n
        when "name"         then owner.name
        when "instname"
          unless entity.is_a?(Sketchup::ComponentInstance)
            raise Expression::Error, "'instname' is a component-instance property"
          end

          entity.name
        when "description"  then owner.description if owner.respond_to?(:description)
        when "summary"      then owner.summary if owner.respond_to?(:summary)
        when "itemcode"     then owner.itemcode if owner.respond_to?(:itemcode)
        when "creator"      then owner.creator if owner.respond_to?(:creator)
        when "layer"        then entity.layer&.name
        when "guid"         then owner.guid if owner.respond_to?(:guid)
        when "persistentid" then entity.persistent_id
        when "entityid"     then entity.entityID
        when "typename"     then entity.typename
        when "instances"
          entity.is_a?(Sketchup::ComponentInstance) ? entity.definition.count_used_instances : nil
        end
      end

      # Panel rows for the foldable "SketchUp" section.
      def list(entity)
        PROPS.map do |n, label, _w, tip|
          { "name" => n, "label" => label, "tip" => tip,
            "writable" => writable?(entity, n),
            "value" => safe_value(entity, n) }
        end
      end

      def safe_value(entity, n)
        read_prop(entity, n)
      rescue StandardError
        nil
      end

      # Assign a writable property. Raises a user-facing message on
      # read-only props, wrong entity kind, or a missing layer.
      def write(entity, name, value)
        n = name.to_s.downcase
        unless PROP_NAMES.include?(n)
          raise "unknown SketchUp attribute '#{n}'"
        end
        unless writable?(entity, n)
          raise "'#{n}' is read-only"
        end

        v = value.to_s
        case n
        when "name"
          prop_owner(entity).name = v
        when "instname"
          entity.name = v
        when "description", "summary", "itemcode", "creator"
          owner = prop_owner(entity)
          raise "'#{n}' is not writable on this entity" unless owner.respond_to?(:"#{n}=")

          owner.send(:"#{n}=", v)
        when "layer"
          lay = entity.model.layers[v]
          raise "no layer/tag named '#{v}'" if lay.nil?

          entity.layer = lay
        end
      end

      # --- driver attributes (fx on a native prop / dict key) --------------

      # A param whose name contains "!" is a driver: its formula doesn't
      # produce a user attribute, it drives an external target
      # (sketchup!<prop> -> a native property, <dict>!<key> -> a dictionary
      # value). No user path can create "!" names - addParam validation is
      # word-chars only - so the marker is unambiguous.
      def driver_name?(name)
        name.to_s.include?("!")
      end

      # Where a driver writes. sketchup! wins the scope unconditionally -
      # a dictionary literally named "sketchup" stays reachable for reads
      # via DICTATTR but can't be a driver target.
      # Returns [:sketchup, prop] or [:dict, dict_name, key], else nil.
      def driver_target(name)
        scope, key = name.to_s.split("!", 2)
        return nil if scope.nil? || key.nil? || key.empty?
        return [:sketchup, key] if scope.casecmp("sketchup").zero?

        [:dict, scope, key]
      end

      # --- attribute dictionaries ------------------------------------------

      # [owner_entity, "instance"|"definition"] pairs that can host dicts.
      def dict_sources(entity)
        srcs = [[entity, "instance"]]
        srcs << [entity.definition, "definition"] if entity.is_a?(Sketchup::ComponentInstance)
        srcs
      end

      # Foreign dictionaries for the panel section: every dict on the
      # instance + definition except the two engine dicts (which already
      # render as params).
      def dictionaries(entity)
        out = []
        dict_sources(entity).each do |owner, scope|
          (owner.attribute_dictionaries || []).each do |d|
            next if ENGINE_DICTS.include?(d.name)

            attrs = DCReader.dict_keys(d).map do |k|
              v = DCReader.dict_get(d, k)
              { "name" => k, "value" => scalar?(v) ? v : v.to_s,
                "writable" => scalar?(v) }
            end
            out << { "name" => d.name, "owner" => scope, "attrs" => attrs }
          end
        end
        out
      end

      # The dict whose name matches `name` case-insensitively, on the
      # instance first, then the definition. Any dictionary matches,
      # including dynamic_attributes/open_dc (system keys stay readable).
      def dict_named(entity, name)
        pair = find_dict(dict_pairs(entity), name)
        pair && pair[1]
      end

      # Same, plus the entity that hosts the dict (set_attribute target).
      def dict_owner(entity, name)
        find_dict(dict_pairs(entity), name)
      end

      # [[host_entity, dict], ...] - pure once the sources are enumerated.
      def dict_pairs(entity)
        dict_sources(entity).flat_map do |owner, _|
          (owner.attribute_dictionaries || []).map { |d| [owner, d] }
        end
      end

      def find_dict(pairs, name)
        down = name.to_s.downcase
        pairs.find { |_, d| dict_name_of(d).downcase == down }
      end

      def dict_name_of(dict)
        dict.respond_to?(:name) ? dict.name.to_s : ""
      end

      # Actual stored key matching `key` case-insensitively (dict keys like
      # "Price" are mixed-case while formula refs arrive lowercased).
      def key_in(dict, key)
        down = key.to_s.downcase
        DCReader.dict_keys(dict).find { |k| k.downcase == down }
      end

      def dict_key?(dict, key)
        !key_in(dict, key).nil?
      end

      def dict_get(dict, key)
        k = key_in(dict, key)
        k.nil? ? nil : DCReader.dict_get(dict, k)
      end

      # Formula-context read (dictname!key and DICTATTR): missing dict or
      # key raises Expression::Error; structured values stringify.
      def dict_value(entity, dict_name, key)
        dict = dict_named(entity, dict_name)
        raise Expression::Error, "no dictionary '#{dict_name}'" if dict.nil?

        v = dict_get(dict, key)
        if v.nil?
          raise Expression::Error,
                "dictionary '#{dict_name_of(dict)}' has no attribute '#{key}'"
        end

        scalar?(v) ? v : v.to_s
      end

      # Scalar guard: strings, numbers and booleans are safe to overwrite.
      # Arrays/points/colors/nested structures belong to the owning plugin.
      def scalar?(v)
        v.nil? || v.is_a?(Numeric) || v.is_a?(String) || v == true || v == false
      end

      # Panel write-through for a foreign-dict key. Only existing scalar
      # keys are writable - no new keys, no structured values.
      def set_dict_attr(entity, dict_name, key, value)
        owner, dict = dict_owner(entity, dict_name)
        raise "no dictionary '#{dict_name}'" if dict.nil?

        k = key_in(dict, key)
        raise "dictionary '#{dict_name_of(dict)}' has no attribute '#{key}'" if k.nil?

        cur = DCReader.dict_get(dict, k)
        unless scalar?(cur)
          raise "'#{dict_name_of(dict)}!#{k}' holds a structured value - read-only"
        end

        owner.set_attribute(dict_name_of(dict), k, coerce_dict_value(cur, value))
      end

      # Keep the key's existing type: numeric keys get numbers, boolean
      # keys get booleans (classic DC stringifies - foreign dicts don't
      # have that quirk, so "true"/"false" become real booleans).
      def coerce_dict_value(cur, raw)
        s = raw.to_s
        case cur
        when Numeric
          begin
            Float(s)
          rescue ArgumentError
            raise "'#{s}' isn't a number - the existing value is numeric"
          end
        when TrueClass, FalseClass
          case s.strip.downcase
          when "true", "1" then true
          when "false", "0" then false
          else raise "'#{s}' isn't a boolean - the existing value is true/false"
          end
        else
          s
        end
      end
    end
  end
end
