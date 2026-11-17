# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

require "json"
require "time"

module OpenSketchupDC
  module OpenDC
    # Converts entities between the classic "dynamic_attributes" format and
    # our own "open_dc" format. On convert, the original dictionary is kept as
    # a JSON snapshot under _legacy_dc so the operation can be reverted.
    #
    # A component is never owned by both engines: the classic dict is deleted
    # on convert (so Trimble's engine stops processing it) and restored on
    # revert.
    module Convert
      module_function

      # Converts any component/group: with a classic dict the attributes
      # migrate, without one the entity still joins the osdc tree (the
      # marker + nominals make it a blank-slate Open DC component).
      def to_open_dc(entity)
        return false unless entity.is_a?(Sketchup::ComponentInstance) ||
                            entity.is_a?(Sketchup::Group)
        return false if DCReader.engine_of(entity) == :osdc

        model = Sketchup.active_model
        Helpers.undo_wrap(model, "Open DC: Convert to Open DC") do
          convert_target(entity)
          convert_target(entity.definition) if entity.is_a?(Sketchup::ComponentInstance)
          child_entities_of(entity).each { |c| to_open_dc_child(c) }
          record_nominals(entity)
        end
        true
      end

      def to_classic(entity)
        return false unless DCReader.engine_of(entity) == :osdc

        model = Sketchup.active_model
        Helpers.undo_wrap(model, "Open DC: Revert to Classic DC") do
          revert_target(entity)
          revert_target(entity.definition) if entity.is_a?(Sketchup::ComponentInstance)
          child_entities_of(entity).each { |c| to_classic_child(c) }
        end
        true
      end

      # ------------------------------------------------------------------

      def convert_target(t)
        dcd = dict_of(t, DC_DICT)
        if dcd.nil?
          # Plain entity: no attributes to migrate, but the marker claims
          # it for our engine and creates the open_dc dict so params and
          # _len*_nominal have somewhere to land.
          t.set_attribute(OS_DC_DICT, "_engine", ENGINE_OS)
          return
        end

        snapshot = {}
        dcd.each do |k, v|
          snapshot[k.to_s] = encode(v)
          t.set_attribute(OS_DC_DICT, k, v)
        end

        t.set_attribute(OS_DC_DICT, "_engine", ENGINE_OS)
        t.set_attribute(OS_DC_DICT, "_legacy_dc", JSON.generate(snapshot))
        t.attribute_dictionaries.delete(dcd)
      end

      def revert_target(t)
        osd = dict_of(t, OS_DC_DICT)
        return if osd.nil?

        raw = DCReader.dict_get(osd, "_legacy_dc")
        if raw
          begin
            snapshot = JSON.parse(raw)
            snapshot.each { |k, v| t.set_attribute(DC_DICT, k, decode(v)) }
          rescue StandardError => e
            puts "#{PLUGIN_NAME}: legacy snapshot restore failed - #{e.message}"
          end
        end
        t.attribute_dictionaries.delete(osd)
      end

      def to_open_dc_child(c)
        convert_target(c)
        convert_target(c.definition) if c.is_a?(Sketchup::ComponentInstance)
        # Recurse: a classic grandchild would otherwise stay Trimble-owned
        # with its parent! refs dangling - the parent's dict is gone.
        child_entities_of(c).each { |gc| to_open_dc_child(gc) }
        record_nominals(c)
      end

      def to_classic_child(c)
        revert_target(c)
        revert_target(c.definition) if c.is_a?(Sketchup::ComponentInstance)
        child_entities_of(c).each { |gc| to_classic_child(gc) }
      end

      # Store the current unscaled bounds as _len<axis>_nominal so Len* scale
      # math has a baseline (mirrors what the DC editor writes).
      def record_nominals(entity)
        owner = DCWriter.owner_for(entity)
        bounds = nominal_bounds(entity)
        return unless bounds

        { "x" => bounds.width, "y" => bounds.height, "z" => bounds.depth }.each do |axis, len|
          key = "_len#{axis}_nominal"
          next unless DCReader.dict_get(DCReader.dict_of(owner, OS_DC_DICT), key).nil?

          owner.set_attribute(OS_DC_DICT, key, len.to_f)
        end
      end

      def nominal_bounds(entity)
        if entity.is_a?(Sketchup::ComponentInstance)
          entity.definition.bounds
        elsif entity.is_a?(Sketchup::Group)
          entity.local_bounds
        end
      end

      def child_entities_of(entity)
        ents = if entity.is_a?(Sketchup::Group)
                 entity.entities
               else
                 entity.definition.entities
               end
        ents.select do |e|
          e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        end
      end

      def dict_of(entity, name)
        entity.attribute_dictionaries && entity.attribute_dictionaries[name]
      end

      # ------------------------------------------------------------------
      # JSON-safe tagged serialization for attribute values.
      # ------------------------------------------------------------------

      def encode(v)
        case v
        when Geom::Point3d  then { "__pt" => v.to_a }
        when Geom::Vector3d then { "__vec" => v.to_a }
        when Time           then { "__time" => v.iso8601 }
        when Array          then v.map { |e| encode(e) }
        when Hash           then v.to_h { |k, x| [k.to_s, encode(x)] }
        when Numeric, String, TrueClass, FalseClass, NilClass then v
        else v.to_s
        end
      end

      def decode(v)
        case v
        when Hash
          if v["__pt"] then Geom::Point3d.new(*v["__pt"])
          elsif v["__vec"]  then Geom::Vector3d.new(*v["__vec"])
          elsif v["__time"] then Time.parse(v["__time"])
          else
            v.transform_values { |x| decode(x) }
          end
        when Array then v.map { |e| decode(e) }
        else v
        end
      end
    end
  end
end
