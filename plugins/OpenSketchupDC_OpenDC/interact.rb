# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # "Interact" tool: click a dynamic entity to run its `onclick` action
    # formula. The DC action functions (SET, ANIMATE*, REDRAW, ALERT,
    # GOTOSCENE) run through the evaluator's :fx hook; pure formula contexts
    # still refuse them.
    #
    # SET/ANIMATE semantics: the target attribute cycles to the state after
    # its current value (wrapping; first state when the current value is not
    # in the list). ANIMATE*/ANIMATECUSTOM currently step directly to the
    # next state - interpolated animation is a beta follow-up. Each click is
    # one undoable write plus an engine re-evaluation (classic goes through
    # Trimble's redraw_with_undo, which manages its own undo step).
    module Interact
      module_function

      # Full instance path of the deepest pick at (x, y): [outer, ..., leaf].
      def pick_path(view, x, y)
        ph = view.pick_helper
        return nil if ph.do_pick(x, y) <= 0

        path = ph.path_at(0)
        path.respond_to?(:to_a) ? path.to_a : Array(path)
      end

      # The leaf-most path element carrying a non-empty `onclick` attribute,
      # as [entity, dict_name, source]; nil when nothing clickable was hit.
      def target_in(path)
        return nil unless path

        path.each_index.reverse_each do |i|
          found = onclick_of(path[i])
          return [path[i], *found, path[0..i]] if found
        end
        nil
      end

      # Fire `onclick` on the leaf-most path entity that has one.
      # Returns the entity that ran, or nil.
      def fire(path, model)
        hit = target_in(path)
        return nil unless hit

        entity, dict_name, src, sub = hit
        run_onclick(entity, dict_name, src, sub, model)
        entity
      end

      # ---- onClick discovery ------------------------------------------------

      # [dict_name, source] when entity has a non-empty onclick param.
      def onclick_of(entity)
        return nil unless DCReader.dynamic?(entity)
        return nil unless entity.valid?

        dict_name = DCReader.dict_name_for(entity)
        p = DCReader.read(entity, dict_name: dict_name)["onclick"]
        return nil if p.nil?

        src = p.formula.to_s.strip.empty? ? p.value : p.formula
        src = src.to_s.strip
        src.empty? ? nil : [dict_name, src]
      end

      # ---- evaluation context ----------------------------------------------

      # Effective current value of `name` on `path[-1]`: the formula slot is
      # authoritative user input, so an unflushed write there is honoured even
      # while the plain-key cache lags behind (deferred classic eval).
      def param_value(path, name, model, seen = {})
        entity = path[-1]
        dict_name = DCReader.dict_name_for(entity)
        ps = DCReader.read(entity, dict_name: dict_name)
        p = ps[name]
        if p.nil?
          return SkProps.value_of(entity, name, dict_name: dict_name) if SkProps.known?(name)

          raise Expression::Error, "no attribute '#{name}'"
        end

        return p.value if p.formula.to_s.strip.empty?

        key = [entity.persistent_id, name]
        raise Expression::Error, "circular reference '#{name}'" if seen[key]

        Expression.eval!(p.formula,
                         get: ->(n) { param_value(path, n, model, seen.merge(key => true)) },
                         ref: ->(s, n) { resolve_ref(s, n, path, model) },
                         meta: ->(n, f) { (h = ps[n]&.to_h) && h[f] },
                         env: Engine.env_for(path[-1], model),
                         dict: ->(dn, k) { SkProps.dict_value(entity, dn, k) })
      end

      def resolve_ref(scope, name, path, model)
        case scope
        when "parent"
          raise Expression::Error, "no parent context" if path.length < 2

          param_value(path[0..-2], name, model)
        when "global"
          dict_name = DCReader.dict_name_for(path[-1])
          v = model.get_attribute(dict_name, name)
          raise Expression::Error, "no global attribute '#{name}'" if v.nil?

          v
        when "sketchup"
          SkProps.value_of(path[-1], name, dict_name: DCReader.dict_name_for(path[-1]))
        else
          ctx = path.length >= 2 ? path[-2] : nil
          sib = node_named(scope, ctx, path[-1], model)
          if sib
            dict_name = DCReader.dict_name_for(sib)
            ps = DCReader.read(sib, dict_name: dict_name)
            p = ps[name]
            raise Expression::Error, "node '#{scope}' has no attribute '#{name}'" if p.nil?

            return p.value
          end

          # Sibling nodes win the scope name; a dictionary on this entity
          # (or its definition) is the fallback scope, e.g. su_instanceset!price.
          if (fdict = SkProps.dict_named(path[-1], scope))
            v = SkProps.dict_get(fdict, name)
            if v.nil?
              raise Expression::Error,
                    "dictionary '#{SkProps.dict_name_of(fdict)}' has no attribute '#{name}'"
            end

            return SkProps.scalar?(v) ? v : v.to_s
          end

          raise Expression::Error, "no node named '#{scope}'"
        end
      end

      # Sibling node lookup: children of the entity's containing instance
      # (or the model root for a top-level entity).
      def node_named(scope, ctx_entity, entity, model)
        ents =
          if ctx_entity
            ctx_entity.is_a?(Sketchup::Group) ? ctx_entity.entities : ctx_entity.definition.entities
          else
            model.entities
          end
        ents.find do |e|
          next false unless e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group)
          next false if e == entity

          node_name_of(e) == scope
        end
      end

      def node_name_of(e)
        nm = DCReader.dict_get(DCReader.dict_of(e, DC_DICT), "_name") ||
             DCReader.dict_get(DCReader.dict_of(e, OS_DC_DICT), "_name")
        if nm.nil? && e.is_a?(Sketchup::ComponentInstance)
          nm = DCReader.dict_get(DCReader.dict_of(e.definition, DC_DICT), "_name") ||
               DCReader.dict_get(DCReader.dict_of(e.definition, OS_DC_DICT), "_name")
        end
        nm
      end

      # ---- action execution -------------------------------------------------

      def run_onclick(entity, dict_name, src, path, model)
        ps = DCReader.read(entity, dict_name: dict_name)
        fx = lambda do |fn, args|
          run_action(fn, args, entity, dict_name, ps, path, model)
        end
        Expression.eval!(src,
                         get: ->(n) { param_value(path, n, model) },
                         ref: ->(s, n) { resolve_ref(s, n, path, model) },
                         meta: ->(n, f) { (h = ps[n]&.to_h) && h[f] },
                         env: Engine.env_for(entity, model),
                         dict: ->(dn, k) { SkProps.dict_value(entity, dn, k) },
                         fx: fx)
      end

      def run_action(fn, args, entity, dict_name, ps, path, model)
        case fn
        when "SET"
          advance(entity, dict_name, ps, args[0].to_s.downcase, args[1..], path, model)
        when "ANIMATE", "ANIMATESLOW", "ANIMATEFAST"
          advance(entity, dict_name, ps, args[0].to_s.downcase, args[1..], path, model)
        when "ANIMATECUSTOM"
          advance(entity, dict_name, ps, args[0].to_s.downcase, args[4..], path, model)
        when "REDRAW"
          recompute(entity, dict_name, model)
        when "ALERT"
          UI.messagebox(args.map(&:to_s).join(" "))
        when "GOTOSCENE"
          page = model.pages.find { |pg| pg.name == args[0].to_s }
          model.pages.selected_page = page if page
        end
      end

      # Cycle `name` to the state after its current effective value.
      # The write targets the attr's input slot: the formula slot when the
      # attr is formula-backed (the engine recomputes and would overwrite a
      # plain-key write), the plain value otherwise.
      def advance(entity, dict_name, ps, name, states, path, model)
        return nil if states.empty?

        cur = param_value(path, name, model)
        idx = states.each_index.find { |i| loose_eq(states[i], cur) }
        nxt_i = idx ? (idx + 1) % states.length : 0
        nxt = states[nxt_i]

        Helpers.undo_wrap(model, "Open DC: Interact") do
          if dict_name == DC_DICT || ps[name]&.formula.to_s.strip.empty?
            DCWriter.set_value(entity, name, nxt, dict_name: dict_name)
          else
            entity.set_attribute(dict_name, "_#{name}_formula", fmt_value(nxt))
          end
          owner = owner_dict(entity, dict_name, "onclick")
          owner["_onclick_state1"] = nxt_i if owner
          Engine.evaluate_tree(entity, model) if dict_name == OS_DC_DICT
        end
        DCBridge.redraw!(entity) if dict_name == DC_DICT
        nxt
      end

      def fmt_value(v)
        v.is_a?(Float) && v.modulo(1).zero? ? v.to_i.to_s : v.to_s
      end

      def recompute(entity, dict_name, model)
        if dict_name == OS_DC_DICT
          Helpers.undo_wrap(model, "Open DC: Interact") do
            Engine.evaluate_tree(entity, model)
          end
        else
          DCBridge.redraw!(entity)
        end
      end

      # The dictionary that actually carries `key` (definition dict for a
      # component, else the instance/group dict).
      def owner_dict(entity, dict_name, key)
        if DCReader.component?(entity)
          d = DCReader.dict_of(entity.definition, dict_name)
          return d if DCReader.dict_key?(d, key)
        end
        DCReader.dict_of(entity, dict_name)
      end

      def loose_eq(a, b)
        if numeric?(a) && numeric?(b)
          (a.to_f - b.to_f).abs < 1e-9
        else
          a.to_s.downcase == b.to_s.downcase
        end
      end

      def numeric?(v)
        v.is_a?(Numeric) ||
          (v.is_a?(String) && v.strip =~ /\A-?\d+(\.\d+)?\z/)
      end

      # ---- tool -------------------------------------------------------------

      # Click-to-interact tool: leaf-most `onclick` in the pick path wins,
      # matching the classic Interact tool's ancestor bubble-up. The entity
      # under the cursor gets an orange bounds outline when it (or one of
      # its ancestors) is clickable.
      class Tool
        def activate
          Sketchup.set_status_text(
            "Open DC Interact: click a dynamic component to run its onClick action."
          )
        end

        def deactivate(view)
          @hover = nil
          view.invalidate
        end

        def suspend(view)
          view.invalidate
        end

        def onLButtonDown(_flags, x, y, view)
          path = Interact.pick_path(view, x, y)
          entity = path && Interact.fire(path, view.model)
          Sketchup.set_status_text(
            entity ? "Open DC: onClick ran." : "Open DC: no onClick here."
          )
          view.invalidate
        end

        def onMouseMove(_flags, x, y, view)
          path = Interact.pick_path(view, x, y)
          hit = path && Interact.target_in(path)
          entity = hit && hit[0]
          return if entity == @hover

          @hover = entity
          view.invalidate
        end

        def onCancel(_reason, view)
          view.model.select_tool(nil)
        end

        def getExtents
          @hover&.valid? ? @hover.bounds : Geom::BoundingBox.new
        end

        def draw(view)
          return unless @hover&.valid?

          bb = @hover.bounds
          c = (0..7).map { |i| bb.corner(i) }
          view.line_width = 3
          view.drawing_color = "orange"
          view.draw(GL_LINE_LOOP, [c[0], c[1], c[3], c[2]])
          view.draw(GL_LINE_LOOP, [c[4], c[5], c[7], c[6]])
          view.draw(GL_LINES, [c[0], c[4], c[1], c[5], c[2], c[6], c[3], c[7]])
        end
      end
    end
  end
end
