# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Applies computed parameter values to an instance/group:
    # transforms (position/rotation/scale), hidden flag, material.
    # "Copies" are structural and handled by Engine, not here.
    module Applier
      module_function

      TRANSFORM_ATTRS = %w[x y z rotx roty rotz lenx leny lenz].freeze

      def apply(entity, values, dict_name: OS_DC_DICT)
        return if entity.nil? || !entity.valid?

        apply_transform(entity, values, dict_name)
        apply_hidden(entity, values)
        apply_material(entity, values)
        apply_drivers(entity, values, dict_name)
      end

      # Any transform attribute present in `values` is engine-controlled.
      # Unwritten transform attrs keep their current values (classic DC
      # semantics) - a lone "lenx" formula must not zero the rotation or
      # collapse the scale on a moved/rotated/mirrored component.
      def apply_transform(entity, values, dict_name)
        return unless TRANSFORM_ATTRS.any? { |k| values.key?(k) }

        cur = entity.transformation
        pos, rot = effective_transform(cur, values)
        scale = scale_factors(entity, values, dict_name, cur)
        t = compose_transform(pos, rot, scale)
        # A no-op recompute must not rewrite the transform - identical
        # writes still dirty the model and (on deferred observer
        # notifications) could feed a recompute -> change -> recompute
        # cycle.
        return if transform_equal?(cur, t)

        begin
          entity.transformation = t
        rescue StandardError => e
          # Last-resort guard - a singular matrix must never pop a modal.
          puts "Open DC: transform skipped on #{entity}: #{e.message}"
        end
      end

      # Final transform = T(x,y,z) * R(rotx,roty,rotz) * S(len/nominal).
      def compose_transform(pos, rot, scale)
        Geom::Transformation.translation(pos) *
          Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(1, 0, 0),
                                        rot[0] * Math::PI / 180.0) *
          Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 1, 0),
                                        rot[1] * Math::PI / 180.0) *
          Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1),
                                        rot[2] * Math::PI / 180.0) *
          Geom::Transformation.scaling(*scale)
      end

      # [[x, y, z], [rotx, roty, rotz]] in engine units: written values
      # where the attr exists, the transform's current state otherwise.
      def effective_transform(cur, values)
        rot = DCReader.euler_angles(cur)
        [[v(values, "x", cur.origin.x), v(values, "y", cur.origin.y),
          v(values, "z", cur.origin.z)],
         [v(values, "rotx", rot[0]), v(values, "roty", rot[1]),
          v(values, "rotz", rot[2])]]
      end

      # A zero (or near-zero) len value would make the scale matrix
      # singular - SketchUp rejects non-invertible transforms. Clamp to a
      # hairline instead: geometry collapses visually and recovers on the
      # next eval, no crash, no modal. 1e-4 is safely above SketchUp's
      # degeneracy threshold (~1e-5 passes, ~1e-6 fails).
      MIN_SCALE = 1.0e-4
      CLAMP_ERR = "zero len collapses the component - clamped".freeze

      # Scale per axis: len value / nominal when the attr is written,
      # the transform's current scale otherwise (preserves stretch on
      # attrs the engine doesn't control).
      def scale_factors(entity, values, dict_name, cur)
        cur_scale = { "x" => cur.xscale, "y" => cur.yscale,
                      "z" => cur.zscale }
        %w[x y z].map do |axis|
          len = values["len#{axis}"]
          next cur_scale[axis] if len.nil?

          nom = nominal(entity, axis, dict_name)
          s = nom.to_f.zero? ? 1.0 : len.to_f / nom
          if !s.finite? || s.abs < MIN_SCALE
            flag_clamp(entity, axis, dict_name)
            next s.finite? && s < 0 ? -MIN_SCALE : MIN_SCALE
          end
          unflag_clamp(entity, axis, dict_name)
          s
        end
      end

      def flag_clamp(entity, axis, dict_name)
        DCWriter.set_meta(entity, "len#{axis}", "error", CLAMP_ERR,
                          dict_name: dict_name)
      rescue StandardError
        nil
      end

      # Clear only OUR clamp message - never a real formula error.
      def unflag_clamp(entity, axis, dict_name)
        owner = DCWriter.owner_for(entity)
        dict = DCReader.dict_of(owner, dict_name)
        key = "_len#{axis}_error"
        owner.set_attribute(dict_name, key, nil) if DCReader.dict_get(dict, key) == CLAMP_ERR
      rescue StandardError
        nil
      end

      # Nominal (unscaled) length along an axis: _len<axis>_nominal meta,
      # else the definition/group local bounds.
      def nominal(entity, axis, dict_name)
        owner = DCWriter.owner_for(entity)
        dict = DCReader.dict_of(owner, dict_name)
        n = DCReader.dict_get(dict, "_len#{axis}_nominal")
        return n.to_f unless n.nil?

        bounds = if entity.is_a?(Sketchup::ComponentInstance)
                   entity.definition.bounds
                 elsif entity.is_a?(Sketchup::Group)
                   entity.local_bounds
                 end
        return 1.0 unless bounds

        { "x" => bounds.width, "y" => bounds.height, "z" => bounds.depth }[axis].to_f
      end

      def apply_hidden(entity, values)
        return unless values.key?("hidden")

        entity.hidden = truthy(values["hidden"])
      end

      def apply_material(entity, values)
        return unless values.key?("material")

        v = values["material"].to_s
        return if v.empty?

        model = entity.model
        mat = model.materials[v]
        if mat.nil?
          color = parse_color(v)
          entity.material = color || v
        else
          entity.material = mat
        end
      end

      def parse_color(v)
        if (m = v.match(/\A\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\z/))
          Sketchup::Color.new(m[1].to_i, m[2].to_i, m[3].to_i)
        elsif (m = v.match(/\A#?([0-9A-Fa-f]{6})\z/))
          hex = m[1]
          Sketchup::Color.new(hex[0..1].to_i(16), hex[2..3].to_i(16), hex[4..5].to_i(16))
        end
      end

      # Driver attributes (sketchup!<prop>, <dict>!<key>): write the
      # computed formula value out to the native property or foreign
      # dictionary key. Each driver writes independently - one failure
      # flags _<name>_error and doesn't abort the rest. Values that
      # didn't change are skipped so a no-op recompute doesn't dirty the
      # model. Engine drops formula-less drivers before this runs.
      def apply_drivers(entity, values, dict_name)
        values.each do |name, v|
          target = SkProps.driver_target(name)
          next if target.nil?

          begin
            kind, a, b = target
            if kind == :sketchup
              cur = begin
                SkProps.value_of(entity, a, dict_name: dict_name)
              rescue StandardError
                nil
              end
              SkProps.write(entity, a, v) unless cur == v
            else
              dict = SkProps.dict_named(entity, a)
              raise "no dictionary '#{a}'" if dict.nil?

              cur = SkProps.dict_get(dict, b)
              SkProps.set_dict_attr(entity, a, b, v) unless cur == v
            end
            clear_driver_error(entity, name, dict_name)
          rescue StandardError => e
            flag_driver_error(entity, name, e.message, dict_name)
          end
        end
      end

      # Apply errors share _<name>_error with eval errors - the prefix
      # keeps them distinguishable so an eval message is never overwritten
      # or cleared by the apply pass.
      APPLY_ERR_PREFIX = "apply: ".freeze

      def flag_driver_error(entity, name, msg, dict_name)
        owner = DCWriter.owner_for(entity)
        dict = DCReader.dict_of(owner, dict_name)
        key = "_#{name}_error"
        cur = DCReader.dict_get(dict, key)
        return if cur && !cur.to_s.start_with?(APPLY_ERR_PREFIX)

        owner.set_attribute(dict_name, key, "#{APPLY_ERR_PREFIX}#{msg}")
      rescue StandardError
        nil
      end

      def clear_driver_error(entity, name, dict_name)
        owner = DCWriter.owner_for(entity)
        dict = DCReader.dict_of(owner, dict_name)
        key = "_#{name}_error"
        cur = DCReader.dict_get(dict, key)
        owner.set_attribute(dict_name, key, nil) if cur.to_s.start_with?(APPLY_ERR_PREFIX)
      rescue StandardError
        nil
      end

      def transform_equal?(a, b)
        a.to_a.zip(b.to_a).all? { |x, y| (x - y).abs < 1e-9 }
      end

      def truthy(v)
        !(v.nil? || v == false || v.zero? || v == 0.0 || v.to_s == "0" || v.to_s.empty?)
      end

      def v(values, key, default)
        return default unless values.key?(key)

        f = values[key].to_f
        f.finite? ? f : default
      end
    end
  end
end
