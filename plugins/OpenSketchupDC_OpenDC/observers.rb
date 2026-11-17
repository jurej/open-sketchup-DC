# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Watches selection and entity/dictionary changes so the panel stays live
    # and the engine sees external edits. Attribute dictionaries are Entity
    # subclasses, so EntityObserver works on them directly.
    module Observers
      class SelectionSpy < Sketchup::SelectionObserver
        def onSelectionBulkChange(_s)
          Panel.schedule_push
        end

        def onSelectionAdded(_s, _e)
          Panel.schedule_push
        end

        def onSelectionRemoved(_s, _e)
          Panel.schedule_push
        end

        def onSelectionCleared(_s)
          Panel.schedule_push
        end
      end

      class EntitySpy < Sketchup::EntityObserver
        def onChangeEntity(e)
          Panel.on_entity_changed(e)
        end

        def onEraseEntity(_e)
          Panel.schedule_push
        end
      end

      # A Selection observer only lives as long as the Selection it was
      # attached to - a new/opened model gets a fresh Selection and the spy
      # on the old one goes silent. AppObserver re-wires on model changes.
      class AppSpy < Sketchup::AppObserver
        def expectsStartupModelNotifications
          true
        end

        def onNewModel(model)
          Observers.on_model_change(model)
        end

        def onOpenModel(model)
          Observers.on_model_change(model)
        end

        # Multi-document switching (Mac); a no-op event on Windows.
        def onActivateModel(model)
          Observers.on_model_change(model)
        end
      end

      @selection_spy = nil
      @entity_spy = nil
      @app_spy = nil
      @selection_model = nil
      @watched = []
      @dict_owners = {}

      module_function

      def install(model)
        @entity_spy ||= EntitySpy.new
        @selection_spy ||= SelectionSpy.new
        ensure_selection_spy(model)
        watch_current(model)
        Sketchup.add_observer(@app_spy ||= AppSpy.new)
      end

      # Re-attach the selection spy whenever the active model changes.
      def ensure_selection_spy(model)
        return if model.nil? || @selection_model == model

        if @selection_model
          begin
            @selection_model.selection.remove_observer(@selection_spy)
          rescue StandardError
            nil
          end
        end
        model.selection.add_observer(@selection_spy)
        @selection_model = model
      rescue StandardError
        nil
      end

      def on_model_change(model)
        install(model)
        Panel.schedule_push
      end

      # Re-attach the entity spy to the currently selected targets, their
      # definitions, and both dictionaries on each.
      def watch_current(model)
        return if @entity_spy.nil?

        @watched.each do |w|
          w.remove_observer(@entity_spy)
        rescue StandardError
          nil
        end
        @watched = []
        @dict_owners = {}

        Selection.targets(model).each do |t|
          attach(t, t)
          attach(t, t.definition) if t.is_a?(Sketchup::ComponentInstance)
        end
      end

      def attach(target, holder)
        holder.add_observer(@entity_spy)
        @watched << holder
        [DC_DICT, OS_DC_DICT].each do |dn|
          d = DCReader.dict_of(holder, dn)
          next if d.nil?

          begin
            d.add_observer(@entity_spy)
            @watched << d
            @dict_owners[d] = target
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        nil
      end

      def owner_of_dict(dict_entity)
        @dict_owners[dict_entity]
      end
    end
  end
end
