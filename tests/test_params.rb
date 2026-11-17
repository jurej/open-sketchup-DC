# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../plugins/OpenSketchupDC_OpenDC", __dir__)
require "constants"
require "core/params"
require "core/dc_reader"
require "selection"

class TestParams < Minitest::Test
  DC = OpenSketchupDC::OpenDC
  R = DC::DCReader

  DEF_DICT = {
    "lenx" => 10.0,
    "_lenx_label" => "LenX",
    "_lenx_formula" => "5*2",
    "_lenx_access" => "TEXTBOX",
    "_lenx_formlabel" => "Width",
    "_lenx_units" => "INCHES",
    "material" => "Red",
    "_material_access" => "LIST",
    "_material_options" => "Red=red&Blue=blue",
    "spacing" => 4.0,
    "_name" => "panel",
    "_formatversion" => 1.0
  }.freeze

  def test_component_merge_with_override
    inst = { "lenx" => 12.0 }
    ps = R.build(DEF_DICT, inst, kind: :component)

    lenx = ps["lenx"]
    assert_equal 12.0, lenx.value
    assert_equal 10.0, lenx.default
    assert_equal true, lenx.overridden
    assert_equal "5*2", lenx.formula
    assert_equal "TEXTBOX", lenx.access
    assert_equal "Width", lenx.display_name

    mat = ps["material"]
    assert_equal "Red", mat.value
    assert_equal false, mat.overridden
    assert_equal [{ "label" => "Red", "value" => "red" },
                  { "label" => "Blue", "value" => "blue" }], mat.parsed_options

    assert_equal "panel", ps.node_name
    assert(ps.params.any? { |p| p.internal? && p.name == "_name" })
  end

  def test_nested_inst_form
    inst = { "_inst_lenx" => 9.5, "_inst__lenx_access" => "VIEW" }
    ps = R.build(DEF_DICT, inst, kind: :component)
    lenx = ps["lenx"]
    assert_equal 9.5, lenx.value
    assert_equal "VIEW", lenx.access # instance-level meta override
  end

  def test_group_form
    ps = R.build(nil, DEF_DICT, kind: :group)
    lenx = ps["lenx"]
    assert_equal 10.0, lenx.value
    assert_equal false, lenx.overridden
  end

  def test_no_dicts
    ps = R.build(nil, nil, kind: :component)
    assert_empty ps.params
  end

  def test_batch_shared_params
    p1 = DC::Param.new("w", value: 1.0, access: "TEXTBOX")
    p2 = DC::Param.new("h", value: 2.0, access: "TEXTBOX")
    p3 = DC::Param.new("w", value: 5.0, access: "TEXTBOX")
    p4 = DC::Param.new("x", value: 0.0, access: "NONE")

    ps1 = DC::ParamSet.new(params: [p1, p2], entity_id: "e1")
    ps2 = DC::ParamSet.new(params: [p3, p4], entity_id: "e2")

    shared = DC::Selection.shared_params([ps1, ps2])
    assert_equal 1, shared.length
    assert_equal "w", shared[0]["name"]
    assert_equal true, shared[0]["mixed"]
    assert_equal %w[e1 e2], shared[0]["entityIds"]
  end

  # Synthesized SketchUp attributes (x, lenx, rotz, ...) are editable like
  # real params but must stay out of the batch-edit intersection.
  def test_builtin_param_excluded_from_batch
    p1 = DC::Param.new("w", value: 1.0, access: "TEXTBOX")
    pb = DC::Param.new("lenx", value: 24.0, access: "TEXTBOX", builtin: true)
    ps1 = DC::ParamSet.new(params: [p1, pb], entity_id: "e1")

    assert_equal true, pb.builtin?
    assert_equal true, pb.to_h["builtin"]
    assert_equal true, pb.editable? # per-param edit still allowed
    shared = DC::Selection.shared_params([ps1])
    assert_equal %w[w], shared.map { |h| h["name"] }
  end

  def test_batch_single_set_not_mixed
    p1 = DC::Param.new("w", value: 1.0, access: "TEXTBOX")
    ps1 = DC::ParamSet.new(params: [p1], entity_id: "e1")
    shared = DC::Selection.shared_params([ps1])
    assert_equal false, shared[0]["mixed"]
    assert_equal 1.0, shared[0]["value"]
  end

  def test_html_unescape_escape
    raw = "if(CURRENT(&quot;RotZ&quot;)=-180,&quot;Desno&quot;,&quot;Levo&quot;)"
    assert_equal 'if(CURRENT("RotZ")=-180,"Desno","Levo")',
                 DC::Param.unescape_html(raw)
    # write-side: only " is escaped - &, <, > must stay raw or DC errors
    assert_equal "&quot;a&quot; & &quot;b&quot;",
                 DC::Param.escape_html('"a" & "b"')
    assert_equal 'sirina&&quot;/&quot;&visina',
                 DC::Param.escape_html('sirina&"/"&visina')
    assert_equal "if(a<b)",
                 DC::Param.escape_html("if(a<b)") # < stays raw
    # one-pass semantics: &amp;quot; decodes to literal &quot;
    assert_equal "&quot;", DC::Param.unescape_html("&amp;quot;")
  end

  def test_error_markup_strip_and_success_filtered
    dict = { "sirina" => 38.9, "_sirina_access" => "NONE",
             "_sirina_error" => "<span class=subformula-success>80.0</span>" }
    ps = R.build(nil, dict, kind: :group)
    assert_nil ps["sirina"].error

    dict2 = { "sirina" => 38.9, "_sirina_access" => "NONE",
              "_sirina_error" => "<span class=subformula-error>syntax error</span>" }
    ps2 = R.build(nil, dict2, kind: :group)
    assert_equal "syntax error", ps2["sirina"].error
  end

  def test_display_value_units
    p = DC::Param.new("lenx", value: "31.496062992125985", units: "CENTIMETERS")
    assert_in_delta 80.0, p.display_value, 0.001

    mm = DC::Param.new("d", value: 1.0, units: "MILLIMETERS")
    assert_in_delta 25.4, mm.display_value, 1e-9

    str = DC::Param.new("name", value: "abc", units: "STRING")
    assert_equal "abc", str.display_value

    assert_in_delta 31.496, DC::Param.unit_to_inches(80.0, "CENTIMETERS"), 0.001
    assert_in_delta 80.0, DC::Param.inches_to_unit(31.496, "CENTIMETERS"), 0.001
    assert(DC::Param.length_unit?("CENTIMETERS"))
    refute(DC::Param.length_unit?("STRING"))
  end

  # _<attr>_units = "DEFAULT" is classic's "End user's model units": the
  # reader supplies model_units and display resolves to it; unresolved it
  # stays a pass-through (pure builds, tests).
  def test_default_units_resolve_to_model_units
    dict = { "cokel" => "3.937007874015748",
             "_cokel_access" => "TEXTBOX",
             "_cokel_units" => "DEFAULT" }

    ps = R.build(nil, dict, kind: :group, model_units: "CENTIMETERS")
    p = ps["cokel"]
    assert_equal "CENTIMETERS", p.display_units
    assert_in_delta 10.0, p.display_value, 0.001
    assert_equal "CENTIMETERS", p.to_h["displayUnits"]
    assert_in_delta 10.0, p.display_default, 0.001
    assert(DC::Param.model_units_dependent?(p.units))
    refute(DC::Param.model_units_dependent?("STRING"))

    ps2 = R.build(nil, dict, kind: :group)
    p2 = ps2["cokel"]
    assert_equal "DEFAULT", p2.display_units
    assert_equal "3.937007874015748", p2.display_value

    mm = R.build(nil, dict, kind: :group, model_units: "MILLIMETERS")["cokel"]
    assert_in_delta 100.0, mm.display_value, 0.001
  end

  # model_length_units takes an entity OR the model directly - panel.rb
  # calls it with Sketchup.active_model, which has no #model.
  def test_model_length_units_entity_or_model
    fake_model = Object.new
    fake_model.define_singleton_method(:options) do
      { "UnitsOptions" => { "LengthUnit" => 3 } }
    end
    fake_entity = Object.new
    fake_entity.define_singleton_method(:model) { fake_model }

    assert_equal "CENTIMETERS", R.model_length_units(fake_entity)
    assert_equal "CENTIMETERS", R.model_length_units(fake_model)
    assert_nil R.model_length_units(Object.new)
  end

  # A builtin adopted by writing only _x_formula (the classic value slot)
  # surfaces as a real attribute before the engine writes an x cache.
  def test_meta_only_attr_detected
    inst = { "_x_formula" => "50" }
    ps = R.build(DEF_DICT, inst, kind: :component)
    x = ps["x"]
    refute_nil x
    assert_equal "50", x.formula
    # builtin unit defaults kick in when no _x_units/_x_formulaunits exist
    assert_equal "INCHES", x.formulaunits
    assert_equal "DEFAULT", x.units
  end

  # _inst__<attr>_<meta> clusters on the instance dict mark an attr too.
  def test_nested_meta_only_attr_detected
    inst = { "_inst__y_formula" => "10" }
    ps = R.build(DEF_DICT, inst, kind: :component)
    refute_nil ps["y"]
    assert_equal "10", ps["y"].formula
  end

  # System keys ending in a meta-field name (_lengthunits -> "length")
  # must not be mistaken for attribute clusters; engine status keys
  # (_error/_display/_nominal) never mark an attr by themselves.
  def test_meta_only_system_keys_ignored
    dict = { "_lengthunits" => "INCHES", "_hasbehaviors" => 1.0,
             "_ghost_error" => "boom", "_ghost_nominal" => 5.0 }
    ps = R.build(nil, dict, kind: :group)
    assert_nil ps["length"]
    assert_nil ps["ghost"]
  end

  def test_options_stray_ampersands
    p = DC::Param.new("s", options: "&2-slojno=2&3-slojno=3&")
    assert_equal [{ "label" => "2-slojno", "value" => "2" },
                  { "label" => "3-slojno", "value" => "3" }],
                 p.parsed_options
  end
end
