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
      end

      # Final transform = T(x,y,z) * R(rotx,roty,rotz) * S(len/nominal).
      # Any transform attribute present in `values` is engine-controlled.
      def apply_transform(entity, values, dict_name)
        return unless TRANSFORM_ATTRS.any? { |k| values.key?(k) }

        cur = entity.transformation
        x   = v(values, "x", cur.origin.x)
        y   = v(values, "y", cur.origin.y)
        z   = v(values, "z", cur.origin.z)
        rx  = v(values, "rotx", 0.0)
        ry  = v(values, "roty", 0.0)
        rz  = v(values, "rotz", 0.0)

        sx, sy, sz = scale_factors(entity, values, dict_name)

        tr = Geom::Transformation.translation([x, y, z]) *
             Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(1, 0, 0),
                                           rx * Math::PI / 180.0) *
             Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 1, 0),
                                           ry * Math::PI / 180.0) *
             Geom::Transformation.rotation(Geom::Point3d.new(0, 0, 0), Geom::Vector3d.new(0, 0, 1),
                                           rz * Math::PI / 180.0) *
             Geom::Transformation.scaling(sx, sy, sz)
        begin
          entity.transformation = tr
        rescue StandardError => e
          # Last-resort guard - a singular matrix must never pop a modal.
          puts "Open DC: transform skipped on #{entity}: #{e.message}"
        end
      end

      # A zero (or near-zero) len value would make the scale matrix
      # singular - SketchUp rejects non-invertible transforms. Clamp to a
      # hairline instead: geometry collapses visually and recovers on the
      # next eval, no crash, no modal. 1e-4 is safely above SketchUp's
      # degeneracy threshold (~1e-5 passes, ~1e-6 fails).
      MIN_SCALE = 1.0e-4
      CLAMP_ERR = "zero len collapses the component - clamped".freeze

      def scale_factors(entity, values, dict_name)
        %w[x y z].map do |axis|
          len = values["len#{axis}"]
          next 1.0 if len.nil?

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
