# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # Dependency graph over (entity_key, attribute) nodes with deterministic
    # topological ordering via Kahn's algorithm. Pure Ruby - unit-testable.
    class Graph
      def initialize
        @deps = {} # key => [dep keys]
      end

      def add(key, deps = [])
        @deps[key] ||= []
        deps.each do |d|
          @deps[key] << d unless @deps[key].include?(d)
        end
        key
      end

      def key?(key)
        @deps.key?(key)
      end

      def keys
        @deps.keys
      end

      # Returns [ordered_keys, cyclic_keys]. ordered_keys lists dependencies
      # before their dependents; any leftover keys form cycles.
      def order
        dependents = Hash.new { |h, k| h[k] = [] }
        remaining = {}
        @deps.each do |k, ds|
          remaining[k] = ds.count { |d| @deps.key?(d) }
          ds.each { |d| dependents[d] << k if @deps.key?(d) }
        end

        queue = remaining.select { |_k, n| n.zero? }.keys
        ordered = []
        until queue.empty?
          k = queue.shift
          ordered << k
          dependents[k].each do |dep|
            remaining[dep] -= 1
            queue << dep if remaining[dep].zero?
          end
        end

        cyclic = remaining.select { |_k, n| n.positive? }.keys
        [ordered, cyclic]
      end
    end
  end
end
