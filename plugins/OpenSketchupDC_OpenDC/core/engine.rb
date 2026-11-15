module OpenSketchupDC
  module OpenDC
    # The Open DC engine: watches open_dc dictionaries, evaluates formulas in
    # deterministic topological order, and applies results via Applier.
    #
    # Evaluation model:
    #   - dirty entities are coalesced and flushed once per UI timer tick,
    #     inside a single undo operation
    #   - local formula deps are topo-sorted (no eval-order bugs); cycles and
    #     eval failures are recorded to _<attr>_error instead of corrupting state
    #   - children are evaluated per parent-instance context; when a shared
    #     definition has multiple outer instances the last evaluation wins on
    #     shared child storage (documented beta-1 limitation)
    module Engine
      @dirty = {}
      @scheduled = false
      @applying = false

      module_function

      def mark_dirty(entity)
        return if @applying || entity.nil?

        @dirty[entity.persistent_id] = entity
        schedule
      end

      def applying?
        @applying
      end

      def pending?
        !@dirty.empty?
      end

      def schedule
        return if @scheduled

        @scheduled = true
        UI.start_timer(0.01, false) { flush }
      end

      def flush
        @scheduled = false
        return if @dirty.empty?

        model = Sketchup.active_model
        batch = @dirty.values.select do |e|
          e.valid?
        rescue StandardError
          false
        end
        @dirty.clear
        return if batch.empty? || model.nil?

        @applying = true
        begin
          Helpers.undo_wrap(model, "Open DC: Recompute") do
            batch.each { |e| evaluate_tree(e, model) }
          end
        ensure
          @applying = false
        end
        model.active_view.invalidate
      rescue StandardError => e
        @applying = false
        puts "#{PLUGIN_NAME}: engine flush failed - #{e.message}"
        puts e.backtrace.first(5).join("\n") if e.backtrace
      end

      # ------------------------------------------------------------------
      # Evaluation
      # ------------------------------------------------------------------

      def evaluate_tree(inst, model, parent_ctx = nil, copy_index = nil)
        return unless DCReader.dict_of(inst, OS_DC_DICT) ||
                      (inst.is_a?(Sketchup::ComponentInstance) &&
                       DCReader.dict_of(inst.definition, OS_DC_DICT))

        ps = DCReader.read(inst, dict_name: OS_DC_DICT)
        computed, errors = evaluate_params(inst, ps, parent_ctx, model, copy_index)
        write_back(inst, computed, errors)
        Applier.apply(inst, applied_values(ps, computed), dict_name: OS_DC_DICT)

        ctx = { inst: inst, ps: ps, computed: computed, model: model }
        ents = child_entities_collection(inst)
        child_entities(inst).each do |child|
          next unless child.valid? # sync_copies may erase siblings mid-iteration
          next unless dynamic_child?(child)
          next if generated_copy?(child)

          evaluate_tree(child, model, ctx, 0)
          n = copies_of(child)
          sync_copies(ents, child, n)
          copies_of_group(ents, child).each do |copy_inst|
            idx = DCReader.dict_get(DCReader.dict_of(copy_inst, OS_DC_DICT), "_osdc_copy").to_i
            evaluate_tree(copy_inst, model, ctx, idx)
          end
        end
      end

      def generated_copy?(entity)
        !DCReader.dict_get(DCReader.dict_of(entity, OS_DC_DICT), "_osdc_copy").nil?
      end

      def child_entities_collection(inst)
        inst.is_a?(Sketchup::Group) ? inst.entities : inst.definition.entities
      end

      def dynamic_child?(entity)
        return false unless entity.is_a?(Sketchup::ComponentInstance) ||
                            entity.is_a?(Sketchup::Group)

        DCReader.dict_of(entity, OS_DC_DICT) ||
          (entity.is_a?(Sketchup::ComponentInstance) &&
            DCReader.dict_of(entity.definition, OS_DC_DICT))
      end

      def child_entities(inst)
        ents = inst.is_a?(Sketchup::Group) ? inst.entities : inst.definition.entities
        ents.select do |e|
          e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
        end
      end

      # Merged effective values: computed where a formula ran, stored otherwise.
      def applied_values(ps, computed)
        out = {}
        ps.each do |p|
          next if p.internal?

          out[p.name] = computed.key?(p.name) ? computed[p.name] : p.value
        end
        out
      end

      def evaluate_params(inst, ps, parent_ctx, model, copy_index)
        computed = {}
        errors = {}

        g = Graph.new
        ps.each do |p|
          next if p.internal? || !p.formula?

          local = Expression.refs(p.formula).select { |s, _| s.nil? }.map { |_, n| n }
          g.add(p.name, local)
        end
        order, cyclic = g.order

        get = lambda do |n|
          n = n.to_s.downcase
          return computed[n] if computed.key?(n)
          return copy_index.to_f if n == "copy" && copy_index

          p = ps[n]
          raise Expression::Error, "undefined attribute '#{n}'" if p.nil?

          p.value
        end

        ref = lambda do |scope, n|
          resolve_ref(scope, n, inst, parent_ctx, model)
        end

        meta = lambda do |n, f|
          h = ps[n]&.to_h
          h && h[f]
        end

        order.each do |name|
          p = ps[name]
          next if p.nil? || !p.formula?

          begin
            computed[name] = Expression.eval!(p.formula, get: get, ref: ref, meta: meta)
          rescue StandardError => e
            errors[name] = e.message
          end
        end
        cyclic.each { |n| errors[n] = "circular reference" }

        [computed, errors]
      end

      def resolve_ref(scope, name, inst, parent_ctx, model)
        case scope
        when "parent"
          raise Expression::Error, "no parent context" unless parent_ctx

          if parent_ctx[:computed].key?(name)
            parent_ctx[:computed][name]
          else
            p = parent_ctx[:ps][name]
            raise Expression::Error, "parent has no attribute '#{name}'" if p.nil?

            p.value
          end
        when "global"
          v = model.get_attribute(OS_DC_DICT, name)
          raise Expression::Error, "no global attribute '#{name}'" if v.nil?

          v
        else
          sib = node_named(scope, inst, parent_ctx, model)
          raise Expression::Error, "no node named '#{scope}'" unless sib

          dict = DCReader.dict_of(sib, OS_DC_DICT)
          dict ||= DCReader.dict_of(sib.definition, OS_DC_DICT) if sib.is_a?(Sketchup::ComponentInstance)
          v = DCReader.dict_get(dict, name)
          raise Expression::Error, "node '#{scope}' has no attribute '#{name}'" if v.nil?

          v
        end
      end

      def node_named(scope, _inst, parent_ctx, model)
        ents = parent_ctx ? child_entities(parent_ctx[:inst]) : model.entities
        ents.find do |e|
          next false unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)

          node_name_of(e) == scope
        end
      end

      def node_name_of(e)
        nm = DCReader.dict_get(DCReader.dict_of(e, OS_DC_DICT), "_name")
        if nm.nil? && e.is_a?(Sketchup::ComponentInstance)
          nm = DCReader.dict_get(DCReader.dict_of(e.definition, OS_DC_DICT), "_name")
        end
        (nm || e.name).to_s.downcase
      end

      # Write computed values + errors back to the instance dict.
      # Skips unchanged values to limit observer churn.
      def write_back(inst, computed, errors)
        computed.each do |n, v|
          cur = inst.get_attribute(OS_DC_DICT, n)
          inst.set_attribute(OS_DC_DICT, n, v) unless same?(cur, v)
        end
        errors.each do |n, msg|
          inst.set_attribute(OS_DC_DICT, "_#{n}_error", msg)
        end
      end

      def same?(a, b)
        if a.is_a?(Numeric) && b.is_a?(Numeric)
          (a - b).abs < 1e-9
        else
          a == b
        end
      end

      # ------------------------------------------------------------------
      # Copies
      # ------------------------------------------------------------------

      # Effective copies count: instance dict first, then definition default.
      def copies_of(child)
        v = DCReader.dict_get(DCReader.dict_of(child, OS_DC_DICT), "copies")
        if v.nil? && child.is_a?(Sketchup::ComponentInstance)
          v = DCReader.dict_get(DCReader.dict_of(child.definition, OS_DC_DICT), "copies")
        end
        v.to_i
      end

      def copies_of_group(entities, original)
        return [] unless original.is_a?(Sketchup::ComponentInstance)

        entities.select do |e|
          e.is_a?(Sketchup::ComponentInstance) && e != original &&
            e.definition == original.definition &&
            !DCReader.dict_get(DCReader.dict_of(e, OS_DC_DICT), "_osdc_copy").nil?
        end
      end

      # Ensure `count` copy-instances of original's definition exist in the
      # parent entities collection, each marked _osdc_copy = <index>.
      def sync_copies(entities, original, count)
        return unless original.is_a?(Sketchup::ComponentInstance)
        return if count <= 0 && copies_of_group(entities, original).empty?

        existing = copies_of_group(entities, original)
        if existing.length < count
          (existing.length + 1..count).each do |idx|
            c = entities.add_instance(original.definition, original.transformation)
            c.set_attribute(OS_DC_DICT, "_osdc_copy", idx)
          end
        elsif existing.length > count
          existing[count..].each { |c| entities.erase_entities(c) }
        end
      end

      # Model-level globals ("global!name" refs).
      def global_params(model)
        dict = DCReader.dict_of(model, OS_DC_DICT)
        DCReader.attr_names(dict).sort
      end
    end
  end
end
