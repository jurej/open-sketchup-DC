# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Menu commands.
    module Commands
      module_function

      def convert_selection
        model = Helpers.require_model
        return unless model

        # Any selected component/group converts - a plain entity gets a
        # fresh open_dc dict, a classic one migrates its attributes.
        ts = Selection.targets(model).select { |t| DCReader.engine_of(t) != :osdc }
        if ts.empty?
          UI.messagebox("Select one or more components or groups to convert.")
          return
        end

        count = ts.count { |t| Convert.to_open_dc(t) }
        Panel.schedule_push
        UI.messagebox("Converted #{count} component(s) to Open DC.")
      end

      def revert_selection
        model = Helpers.require_model
        return unless model

        ts = Selection.dynamic_targets(model).select { |t| DCReader.engine_of(t) == :osdc }
        if ts.empty?
          UI.messagebox("Select one or more Open DC components to revert.")
          return
        end

        count = ts.count { |t| Convert.to_classic(t) }
        Panel.schedule_push
        UI.messagebox("Reverted #{count} component(s) to classic DC.")
      end

      def interact
        model = Helpers.require_model
        model&.select_tool(Interact::Tool.new)
      end

      def recompute_selection
        model = Helpers.require_model
        return unless model

        ts = Selection.dynamic_targets(model)
        ts.each do |t|
          if DCReader.engine_of(t) == :osdc
            Engine.mark_dirty(t)
          else
            DCBridge.redraw!(t)
          end
        end
      end
    end
  end
end
