# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../plugins/OpenSketchupDC_OpenDC", __dir__)
require "constants"
require "core/params"
require "core/dc_reader"
require "core/engine"
require "core/applier"

# Engine#write_back error-slot lifecycle: eval errors must clear once the
# attr recovers (or loses its formula), while "apply: " driver errors are
# owned by the apply pass and must survive this write.
class TestEngine < Minitest::Test
  DC = OpenSketchupDC::OpenDC
  R = DC::DCReader

  # Minimal entity double: SketchUp's get/set_attribute where a nil
  # write deletes the key.
  class FakeEntity
    def initialize(dict) = @dicts = { DC::OS_DC_DICT => dict }

    def get_attribute(dict, key) = @dicts.dig(dict, key)

    def set_attribute(dict, key, value)
      value.nil? ? @dicts[dict].delete(key) : (@dicts[dict] ||= {})[key] = value
    end
  end

  def entity_for(dict)
    [FakeEntity.new(dict), R.build(nil, dict, kind: :group)]
  end

  def test_recovered_eval_clears_stale_error
    dict = { "x" => 1.0, "_x_error" => "undefined attribute 'bogus'" }
    inst, ps = entity_for(dict)
    DC::Engine.write_back(inst, ps, {}, { "x" => "undefined attribute 'bogus'" })
    assert_equal "undefined attribute 'bogus'", dict["_x_error"]

    DC::Engine.write_back(inst, ps, { "x" => 10.0 }, {})
    assert_nil dict["_x_error"]
    assert_equal 10.0, dict["x"]
  end

  def test_stale_error_cleared_when_formula_removed
    dict = { "x" => 5.0, "_x_error" => "old eval failure" }
    inst, ps = entity_for(dict)
    DC::Engine.write_back(inst, ps, {}, {})
    assert_nil dict["_x_error"]
  end

  def test_apply_error_survives_eval_write_back
    dict = { "sketchup!name" => "X", "_sketchup!name_error" => "apply: no tag 'Foo'" }
    inst, ps = entity_for(dict)
    DC::Engine.write_back(inst, ps, { "sketchup!name" => "Y" }, {})
    assert_equal "apply: no tag 'Foo'", dict["_sketchup!name_error"]
  end
end
