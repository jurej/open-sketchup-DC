# OpenSketchupDC_OpenDC.rb
# Registration file only - all logic lives in the support folder.

require "sketchup"
require "extensions"

module OpenSketchupDC
  module OpenDC
    EXTENSION = SketchupExtension.new(
      "Open DC - Dynamic Components",
      File.join("OpenSketchupDC_OpenDC", "main")
    )
    EXTENSION.version     = "0.1.0"
    EXTENSION.creator     = "Jure Judez"
    EXTENSION.description = "Modern dynamic components: parameter panel, batch editing, and an open parametric engine."
    EXTENSION.copyright   = "2026, Jure Judez"

    Sketchup.register_extension(EXTENSION, true)
  end
end
