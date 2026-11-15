module OpenSketchupDC
  module OpenDC
    # Selection -> dynamic-component targets, plus the batch-edit
    # intersection logic.
    module Selection
      module_function

      # Selected entities that are dynamic components (either engine).
      def targets(model)
        return [] unless model

        model.selection.select { |e| DCReader.dynamic?(e) }
      end

      # Params shared by every selected target, intersected by name and
      # editable-ness. Values that differ across the set are marked "mixed".
      # Pure Ruby - operates on ParamSets (unit-testable).
      def shared_params(param_sets)
        return [] if param_sets.nil? || param_sets.empty?

        common = param_sets.first.editable.map(&:name)
        param_sets[1..].each do |ps|
          common &= ps.editable.map(&:name)
        end

        common.sort.map do |n|
          base = param_sets.first[n]
          next if base.nil?

          values = param_sets.map { |ps| ps[n]&.value }
          h = base.to_h
          h["mixed"] = values.uniq.length > 1
          h["value"] = nil if h["mixed"]
          h["entityIds"] = param_sets.map(&:entity_id)
          h
        end.compact
      end
    end
  end
end
