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
    Sketchup.require(File.join(PLUGIN_DIR, "core", "applier"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "engine"))
    Sketchup.require(File.join(PLUGIN_DIR, "core", "convert"))
    Sketchup.require(File.join(PLUGIN_DIR, "selection"))
    Sketchup.require(File.join(PLUGIN_DIR, "observers"))
    Sketchup.require(File.join(PLUGIN_DIR, "commands"))
    Sketchup.require(File.join(PLUGIN_DIR, "registry_caps"))
    Sketchup.require(File.join(PLUGIN_DIR, "ui", "panel"))

    unless file_loaded?(__FILE__)
      menu = UI.menu("Extensions").add_submenu("Open DC")
      menu.add_item("Parameter Panel") { Panel.toggle }
      menu.add_separator
      menu.add_item("Recompute Selected") { Commands.recompute_selection }
      menu.add_separator
      menu.add_item("Convert to Open DC") { Commands.convert_selection }
      menu.add_item("Revert to Classic DC") { Commands.revert_selection }
      file_loaded(__FILE__)
    end
  end
end
