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

      # SketchUp UnitsOptions LengthUnit codes -> our unit tokens.
      MODEL_LENGTH_UNITS = %w[INCHES FEET MILLIMETERS CENTIMETERS METERS].freeze

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
        mu = model_length_units(entity)
        ps =
          if component?(entity)
            build(dict_of(entity.definition, dict_name),
                  dict_of(entity, dict_name),
                  kind: :component, engine: engine, entity_id: entity_id,
                  model_units: mu)
          else
            build(nil, dict_of(entity, dict_name),
                  kind: :group, engine: engine, entity_id: entity_id,
                  model_units: mu)
          end
        append_builtins(ps, entity, dict_name, mu)
        apply_display_strings(ps)
        ps
      end

      # End user's model display unit (UnitsOptions.LengthUnit) - what the
      # classic "DEFAULT" _<attr>_units resolves to. Accepts an entity or
      # the model itself (Sketchup::Model has no #model). nil when
      # unreadable.
      def model_length_units(entity_or_model)
        model = entity_or_model
        model = model.model if model.respond_to?(:model)
        MODEL_LENGTH_UNITS[model.options["UnitsOptions"]["LengthUnit"].to_i]
      rescue StandardError
        nil
      end

      # DEFAULT-unit params get a SketchUp-formatted Length string that
      # honors the model's unit AND format (decimal, architectural,
      # engineering, fractional) plus precision. The numeric
      # displayValue/displayUnits stay behind as editable fallbacks.
      def apply_display_strings(ps)
        ps.params.each do |p|
          next unless Param.model_units_dependent?(p.units)

          p.display_string = length_string(p.value)
          p.display_default_string = length_string(p.default)
        end
      end

      def length_string(v)
        return nil if v.nil?

        n = v.is_a?(Numeric) ? v : Float(v.to_s)
        n.to_l.to_s
      rescue StandardError
        nil
      end

      def component?(entity)
        entity.is_a?(Sketchup::ComponentInstance)
      end

      # --- built-in attributes (computed live, not stored) ----------------

      # Display units per synthesized builtin. "DEFAULT" resolves to the
      # end user's model units, same as a stored _<attr>_units.
      BUILTIN_UNITS = {
        "x" => "DEFAULT", "y" => "DEFAULT", "z" => "DEFAULT",
        "lenx" => "DEFAULT", "leny" => "DEFAULT", "lenz" => "DEFAULT",
        "rotx" => "DEGREES", "roty" => "DEGREES", "rotz" => "DEGREES",
        "hidden" => "BOOLEAN", "material" => "STRING",
        "onclick" => "STRING", "copies" => "INTEGER",
        "copy" => "INTEGER", "scaletool" => "STRING"
      }.freeze

      # Units a bare number in a _<attr>_formula slot is interpreted in:
      # inches for lengths, degrees for rotations (classic defaults).
      BUILTIN_FORMULAUNITS = {
        "x" => "INCHES", "y" => "INCHES", "z" => "INCHES",
        "lenx" => "INCHES", "leny" => "INCHES", "lenz" => "INCHES",
        "rotx" => "DEGREES", "roty" => "DEGREES", "rotz" => "DEGREES"
      }.freeze

      # Appends computed params for every built-in attribute not already
      # claimed by a dict key. The classic engine resolves these names
      # implicitly on any component; we surface the same values so the
      # panel shows them (and formulas can reference them) everywhere.
      # A stored-but-unevaluated builtin attr (adopted by writing only a
      # _<name>_formula/meta slot, cache not yet written) still shows the
      # live transform value as its current state.
      def append_builtins(ps, entity, dict_name, model_units)
        builtin_values(entity, dict_name).each do |name, v|
          if (p = ps[name])
            p.value = v if p.value.nil?
            next
          end
          ps.params << builtin_param(name, v, model_units)
        end
      rescue StandardError => e
        # Builtins are cosmetic - never break a read over them, but don't
        # hide a real failure either.
        puts "Open DC: builtins skipped on #{entity}: #{e.message}"
        ps
      end

      def builtin_param(name, v, model_units)
        cased = BUILTIN_ATTRS.find { |b| b.casecmp(name).zero? } || name.capitalize
        Param.new(name,
                  value: v,
                  label: cased, formlabel: cased,
                  access: ACCESS_TEXTBOX,
                  units: BUILTIN_UNITS[name],
                  formulaunits: BUILTIN_FORMULAUNITS[name],
                  model_units: model_units,
                  tooltip: "Built-in SketchUp attribute - set a display rule " \
                           "(fx) to show it in the main panel",
                  builtin: true)
      end

      # Live values for every builtin we synthesize, read straight off the
      # entity's transform/bounds/flags (inches, degrees). The behavior
      # builtins (onclick, copies, copy, scaletool) have no transform to
      # read - they surface stored state (or the classic default) so the
      # attrs are adoptable: onclick in particular is only reachable as a
      # formula when a row exists to hang the fx editor off.
      def builtin_values(entity, dict_name)
        t = entity.transformation
        o = t.origin.to_a
        rx, ry, rz = euler_angles(t)
        # xaxis/yaxis/zaxis are normalized directions - the scale lives
        # on xscale/yscale/zscale (verified: xaxis.length stays 1.0 for
        # scaled transforms, so len* would never track external scaling).
        lens = %w[x y z].zip([t.xscale, t.yscale, t.zscale]).map do |a, s|
          Applier.nominal(entity, a, dict_name).to_f * s
        end
        d = dict_of(entity, dict_name)
        d ||= dict_of(entity.definition, dict_name) if component?(entity)

        {
          "x" => o[0], "y" => o[1], "z" => o[2],
          "lenx" => lens[0], "leny" => lens[1], "lenz" => lens[2],
          "rotx" => rx, "roty" => ry, "rotz" => rz,
          "hidden" => entity.hidden?,
          "material" => material_name(entity),
          "onclick" => "",
          "copies" => dict_get(d, "copies").to_i,
          "copy" => dict_get(dict_of(entity, dict_name), "_osdc_copy").to_i,
          "scaletool" => dict_get(d, "_scaletool") || dict_get(d, "scaletool") ||
                        "x, y, z"
        }
      end

      # Rotation part of a transform as Euler angles matching Applier's
      # composition (R = Rx * Ry * Rz). Falls back to zeros for degenerate
      # matrices; gimbal lock picks rotx = 0.
      def euler_angles(t)
        xa = t.xaxis.normalize
        ya = t.yaxis.normalize
        za = t.zaxis.normalize
        sy = za.x.to_f.clamp(-1.0, 1.0)
        roty = Math.asin(sy)
        rotx, rotz =
          if sy.abs > 0.9999
            [0.0, Math.atan2(xa.y, xa.x)]
          else
            [Math.atan2(-za.y, za.z), Math.atan2(-ya.x, xa.x)]
          end
        [rotx, roty, rotz].map { |a| a * 180.0 / Math::PI }
      rescue StandardError
        [0.0, 0.0, 0.0]
      end

      def material_name(entity)
        m = entity.material
        return "" if m.nil?

        m.respond_to?(:name) ? m.name.to_s : m.to_s
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

      def build(def_dict, inst_dict, kind:, engine: :classic, entity_id: nil,
                model_units: nil)
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
          p = param_for(n, base, inst_dict, kind, model_units)
          p.section = sections[n]
          p
        end
        params += system_params(base, inst_dict)

        ParamSet.new(entity_id: entity_id, kind: kind, engine: engine,
                     node_name: node, params: params)
      end

      # Meta fields whose _<attr>_<field> key marks a user attribute even
      # without a plain <attr> value key - e.g. a builtin adopted by
      # writing _x_formula, or an attr whose cache the engine hasn't
      # materialized yet. Engine-written status keys (_error, _display,
      # _nominal) are excluded: they can outlive the attribute itself.
      # (.+?) stays non-greedy so _x_formulaunits maps to attr "x".
      INPUT_META_FIELDS = (META_FIELDS - %w[error display nominal]).freeze
      INPUT_META_RE = /\A_(?!inst_)(.+?)_(#{INPUT_META_FIELDS.join('|')})\z/
      INST_META_RE = /\A_inst__(.+?)_(#{INPUT_META_FIELDS.join('|')})\z/

      # Non-underscore keys are user attributes; so is a user-input
      # _<attr>_<meta> cluster key (see INPUT_META_FIELDS).
      def attr_names(dict)
        dict_keys(dict).reject { |k| k.start_with?("_") }.map(&:downcase) |
          meta_attr_names(dict)
      end

      def meta_attr_names(dict)
        dict_keys(dict).filter_map do |k|
          next if SYSTEM_KEYS.include?(k.downcase)

          (m = k.match(INPUT_META_RE)) && m[1].downcase
        end
      end

      # Instance-side names: plain overrides + nested _inst_<attr> values
      # + _inst__<attr>_<meta> input clusters.
      def inst_attr_names(dict)
        return [] if dict.nil?

        plain = attr_names(dict)
        nested = dict_keys(dict).filter_map do |k|
          (m = k.match(/\A_inst_(?!_)(.+)\z/) || k.match(INST_META_RE)) &&
            m[1].downcase
        end
        plain | nested
      end

      def param_for(name, base, inst, kind, model_units = nil)
        override = nil
        override_meta = {}

        if kind == :component && inst
          override = dict_key?(inst, name) ? dict_get(inst, name) : dict_get(inst, "_inst_#{name}")
          override_meta = instance_meta(inst, name)
        end

        default = dict_get(base, name)
        meta = merged_meta(base, override_meta, name)

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
                  model_units: model_units,
                  tooltip: meta["tooltip"],
                  overridden: kind == :component && !override.nil? && override != default,
                  error: param_error(base, name))
      end

      # Per-instance meta overrides live in two places: _inst__<a>_<f>
      # (nested-component form) and plain _<a>_<f> on the instance dict,
      # which is where classic DC stores per-instance formula overrides.
      def instance_meta(inst, name)
        out = {}
        META_FIELDS.each do |f|
          v = dict_get(inst, "_inst__#{name}_#{f}")
          v = dict_get(inst, "_#{name}_#{f}") if v.nil?
          out[f] = v unless v.nil?
        end
        out
      end

      # Instance meta wins over definition meta. Builtin attrs (x, lenx,
      # rotz, ...) default to classic's units when nothing overrides them:
      # model units for lengths, degrees for rotations, inches in formulas.
      def merged_meta(base, override_meta, name)
        meta = {}
        META_FIELDS.each do |f|
          meta[f] = override_meta.key?(f) ? override_meta[f] : dict_get(base, "_#{name}_#{f}")
        end
        meta["units"] ||= BUILTIN_UNITS[name]
        meta["formulaunits"] ||= BUILTIN_FORMULAUNITS[name]
        meta
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
