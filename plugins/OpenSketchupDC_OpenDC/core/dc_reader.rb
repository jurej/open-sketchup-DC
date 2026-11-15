# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Reads the classic "dynamic_attributes" format (or our own "open_dc"
    # dictionary, which uses the same cluster schema) into ParamSet objects.
    #
    # Three storage forms handled:
    #   :component - definition dict holds defaults + _<attr>_<meta> clusters;
    #                instance dict holds plain-key overrides. Nested component
    #                instances may also use _inst_<attr> values and
    #                _inst__<attr>_<meta> meta.
    #   :group     - attributes + meta live directly on the instance dict.
    #
    # Dict access is abstracted so unit tests can pass plain Hashes.
    module DCReader
      # Built-in DC attributes that exist on every dynamic component even
      # without explicit dict keys - formulas may reference them freely
      # (e.g. CURRENT("RotZ") when no rotz key exists).
      BUILTIN_ATTRS = %w[X Y Z LenX LenY LenZ RotX RotY RotZ
                         Hidden Copies Copy Material ScaleTool onClick
                         Name Summary Description ItemCode Creator].freeze

      module_function

      # --- dict access abstraction -----------------------------------------

      def dict_get(dict, key)
        dict.nil? ? nil : dict[key]
      end

      def dict_keys(dict)
        dict.nil? ? [] : dict.keys.map(&:to_s)
      end

      def dict_key?(dict, key)
        !dict.nil? && dict_keys(dict).include?(key)
      end

      def dict_of(entity, dict_name)
        dicts = entity.attribute_dictionaries
        dicts ? dicts[dict_name] : nil
      end

      # --- SketchUp-facing entry points ------------------------------------

      # entity: Sketchup::ComponentInstance | Sketchup::Group
      def read(entity, dict_name: DC_DICT, entity_id: nil)
        engine = dict_name == OS_DC_DICT ? :osdc : :classic
        if component?(entity)
          build(dict_of(entity.definition, dict_name),
                dict_of(entity, dict_name),
                kind: :component, engine: engine, entity_id: entity_id)
        else
          build(nil, dict_of(entity, dict_name),
                kind: :group, engine: engine, entity_id: entity_id)
        end
      end

      def component?(entity)
        entity.is_a?(Sketchup::ComponentInstance)
      end

      # Is this entity dynamic at all (either engine)?
      def dynamic?(entity)
        return false unless entity.is_a?(Sketchup::ComponentInstance) ||
                            entity.is_a?(Sketchup::Group)

        return true if dict_of(entity, DC_DICT) || dict_of(entity, OS_DC_DICT)

        entity.is_a?(Sketchup::ComponentInstance) &&
          (dict_of(entity.definition, DC_DICT) || dict_of(entity.definition, OS_DC_DICT))
      end

      # Which engine owns this entity: :osdc when the open_dc marker exists,
      # otherwise :classic (presence of dynamic_attributes assumed by caller).
      def engine_of(entity)
        osd = component?(entity) ? dict_of(entity.definition, OS_DC_DICT) : nil
        osi = dict_of(entity, OS_DC_DICT)
        return :osdc if dict_get(osd, "_engine") == ENGINE_OS ||
                        dict_get(osi, "_engine") == ENGINE_OS

        :classic
      end

      def dict_name_for(entity)
        engine_of(entity) == :osdc ? OS_DC_DICT : DC_DICT
      end

      # --- pure core (Hash-friendly) ---------------------------------------

      def build(def_dict, inst_dict, kind:, engine: :classic, entity_id: nil)
        base = kind == :group ? inst_dict : def_dict
        return ParamSet.new(entity_id: entity_id, kind: kind, engine: engine) if base.nil? && inst_dict.nil?

        names = attr_names(base)
        names |= inst_attr_names(inst_dict) if kind == :component && inst_dict

        node = dict_get(base, "_name")
        node ||= dict_get(inst_dict, "_name") if inst_dict

        # Display order: _itemorder when present (classic format - comma
        # list where "&Title&" entries are section headers in the options
        # dialog), otherwise the dict's own key order (what classic DC
        # shows). Unlisted attrs append sorted at the end, no section.
        order, sections = parse_itemorder(dict_get(base, "_itemorder"))
        ordered = order & names
        leftover = (names - ordered).sort
        params = (ordered + leftover).map do |n|
          p = param_for(n, base, inst_dict, kind)
          p.section = sections[n]
          p
        end
        params += system_params(base, inst_dict)

        ParamSet.new(entity_id: entity_id, kind: kind, engine: engine,
                     node_name: node, params: params)
      end

      # Non-underscore keys are user attributes.
      def attr_names(dict)
        dict_keys(dict).reject { |k| k.start_with?("_") }.map(&:downcase)
      end

      # Instance-side names: plain overrides + nested _inst_<attr> values.
      def inst_attr_names(dict)
        return [] if dict.nil?

        plain = attr_names(dict)
        nested = dict_keys(dict).filter_map do |k|
          m = k.match(/\A_inst_(?!_)(.+)\z/)
          m && m[1].downcase
        end
        plain | nested
      end

      def param_for(name, base, inst, kind)
        override = nil
        override_meta = {}

        if kind == :component && inst
          override = dict_key?(inst, name) ? dict_get(inst, name) : dict_get(inst, "_inst_#{name}")
          META_FIELDS.each do |f|
            # Per-instance meta overrides live in two places: _inst__<a>_<f>
            # (nested-component form) and plain _<a>_<f> on the instance dict,
            # which is where classic DC stores per-instance formula overrides.
            v = dict_get(inst, "_inst__#{name}_#{f}")
            v = dict_get(inst, "_#{name}_#{f}") if v.nil?
            override_meta[f] = v unless v.nil?
          end
        end

        default = dict_get(base, name)
        meta = {}
        META_FIELDS.each do |f|
          meta[f] = override_meta.key?(f) ? override_meta[f] : dict_get(base, "_#{name}_#{f}")
        end

        Param.new(name,
                  value: override.nil? ? default : override,
                  default: default,
                  label: meta["label"],
                  formlabel: meta["formlabel"],
                  formula: Param.unescape_html(meta["formula"]),
                  formulaunits: meta["formulaunits"],
                  access: meta["access"],
                  options: meta["options"],
                  units: meta["units"],
                  tooltip: meta["tooltip"],
                  overridden: kind == :component && !override.nil? && override != default,
                  error: param_error(base, name))
      end

      # _<attr>_error stores the last formula-eval status: an HTML span
      # (<span class=subformula-success>80.0</span>), a plain evaluated result,
      # or a real error message. Only genuine errors surface to the UI.
      def param_error(dict, name)
        raw = dict_get(dict, "_#{name}_error")
        return nil if raw.nil?

        s = raw.to_s
        return nil if s.include?("subformula-success")

        stripped = Param.strip_markup(s)
        return nil if stripped.empty? || stripped =~ /\A-?[\d.]+(?:e[+-]?\d+)?\z/i

        stripped
      end

      # Parses classic _itemorder: "a,b,&Title&,c" -> ordered names +
      # {name => section title}. Entries wrapped in &...& are section
      # headers; names before the first header have no section ("").
      def parse_itemorder(raw)
        return [[], {}] if raw.to_s.strip.empty?

        order = []
        sections = {}
        current = ""
        raw.to_s.split(",").each do |tok|
          tok = tok.strip
          next if tok.empty?

          # Attr names can't contain &, so &-parts inside a token
          # alternate: name, title, name... A token starting with & has a
          # title first. Handles "&T&", "&T&name" and "name&T&name".
          expect_name = !tok.start_with?("&")
          tok.split("&").each do |part|
            part = part.strip
            next if part.empty?

            if expect_name
              order << part.downcase
              sections[part.downcase] = current
              expect_name = false
            else
              current = part
              expect_name = true
            end
          end
        end
        [order, sections]
      end

      # Entity-level metadata (leading-underscore keys) exposed read-only.
      def system_params(base, inst_dict)
        SYSTEM_KEYS.filter_map do |k|
          v = dict_get(base, k)
          v = dict_get(inst_dict, k) if v.nil? && inst_dict
          next if v.nil?

          Param.new(k, value: v, internal: true, access: Param::ACCESS_NONE)
        end
      end
    end
  end
end
