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

      @selection_spy = nil
      @entity_spy = nil
      @watched = []
      @dict_owners = {}

      module_function

      def install(model)
        @entity_spy ||= EntitySpy.new
        unless @selection_spy
          @selection_spy = SelectionSpy.new
          model.selection.add_observer(@selection_spy)
        end
        watch_current(model)
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
