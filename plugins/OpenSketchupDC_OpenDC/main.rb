# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

module OpenSketchupDC
  module OpenDC
    # __dir__ is not UTF-8 encoded on Windows - force it for non-ASCII paths.
    PLUGIN_DIR = __dir__.dup.force_encoding(Encoding::UTF_8).freeze

    Sketchup.require(File.join(PLUGIN_DIR, "helpers"))
    Sketchup.require(File.join(PLUGIN_DIR, "constants"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "params"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "dc_reader"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "dc_writer"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "dc_bridge"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "expression"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "graph"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "ast_graph"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "applier"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "engine"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "convert"))
    Sketchup.require(File.join(PLUGIN_DIR, "selection"))
    Sketchup.require(File.join(PLUGIN_DIR, "observers"))
    Sketchup.require(File.join(PLUGIN_DIR, "interact"))
    Sketchup.require(File.join(PLUGIN_DIR, "commands"))
    Sketchup.require(File.join(PLUGIN_DIR, "registry_caps"))
    Sketchup.require(File.join(PLUGIN_DIR, "ui", "panel"))

    unless file_loaded?(__FILE__)
      menu = UI.menu("Extensions").add_submenu("Open DC")
      menu.add_item("Parameter Panel") { Panel.toggle }
      menu.add_item("Interact Tool") { Commands.interact }
      menu.add_separator
      menu.add_item("Recompute Selected") { Commands.recompute_selection }
      menu.add_separator
      menu.add_item("Convert to Open DC") { Commands.convert_selection }
      menu.add_item("Revert to Classic DC") { Commands.revert_selection }

      # Right-click on a dynamic component: same actions, contextual.
      # Nothing is added for non-DC selections so other menus stay clean.
      UI.add_context_menu_handler do |context_menu|
        next if Selection.targets(Sketchup.active_model).empty?

        sub = context_menu.add_submenu("Open DC")
        sub.add_item("Parameter Panel") { Panel.toggle }
        sub.add_item("Interact Tool") { Commands.interact }
        sub.add_separator
        sub.add_item("Recompute") { Commands.recompute_selection }
        sub.add_separator
        sub.add_item("Convert to Open DC") { Commands.convert_selection }
        sub.add_item("Revert to Classic DC") { Commands.revert_selection }
      end

      file_loaded(__FILE__)
    end
  end
end
