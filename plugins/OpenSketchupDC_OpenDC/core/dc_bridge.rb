module OpenSketchupDC
  module OpenDC
    # Bridge to Trimble's Dynamic Components extension. The DC engine is
    # proprietary and undocumented; the redraw entry point below is the
    # community-standard hook. Everything degrades cleanly when absent.
    module DCBridge
      module_function

      def available?
        defined?($dc_observers) && $dc_observers.respond_to?(:get_latest_class)
      rescue StandardError
        false
      end

      # Redraw one classic DC through Trimble's engine.
      # NOTE: redraw_with_undo manages its own undo step; batching several
      # instances therefore creates several undo entries (beta 1 limitation).
      def redraw!(entity)
        return false unless available? && entity&.valid?

        $dc_observers.get_latest_class.redraw_with_undo(entity)
        true
      rescue StandardError => e
        puts "#{PLUGIN_NAME}: DC redraw failed - #{e.message}"
        false
      end

      # Same engine redraw without its own undo step - for animation ticks
      # inside a caller-managed transaction.
      def redraw_no_undo!(entity)
        return false unless available? && entity&.valid?

        $dc_observers.get_latest_class.redraw(entity)
        true
      rescue StandardError => e
        puts "#{PLUGIN_NAME}: DC redraw failed - #{e.message}"
        false
      end

      def redraw_all!(entities)
        entities.count { |e| redraw!(e) }
      end
    end
  end
end
