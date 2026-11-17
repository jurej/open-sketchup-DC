# Open DC - modern Dynamic Components for SketchUp
# Copyright (C) 2026 Jure Judež and contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../plugins/OpenSketchupDC_OpenDC", __dir__)
require "constants"
require "core/params"
require "core/dc_reader"
require "core/sk_props"

# Pure parts of SkProps: dictionary name/key matching, the scalar write
# guard and value coercion. Entity-facing wrappers (dict_sources,
# value_of, write) need the SketchUp API and are covered by manual QA.
class TestSkProps < Minitest::Test
  P = OpenSketchupDC::OpenDC::SkProps

  # Minimal dict stand-in: AttributeDictionary responds to name/keys/[].
  FakeDict = Struct.new(:name, :data) do
    def [](k) = data[k]
    def keys = data.keys
  end

  def test_scalar_guard
    assert P.scalar?("x")
    assert P.scalar?(1.5)
    assert P.scalar?(0)
    assert P.scalar?(true)
    assert P.scalar?(false)
    assert P.scalar?(nil)
    refute P.scalar?([1, 2])
    refute P.scalar?({ "a" => 1 })
    refute P.scalar?(Object.new)
  end

  # Dict keys are mixed-case ("Price", "URL") while formula refs arrive
  # lowercased - lookups must match case-insensitively and still return
  # the stored key's value.
  def test_case_insensitive_key_lookup
    d = FakeDict.new("SU_InstanceSet", { "Price" => 10.0, "URL" => "x" })
    assert_equal "Price", P.key_in(d, "price")
    assert_equal "URL", P.key_in(d, "url")
    assert_nil P.key_in(d, "nope")
    assert P.dict_key?(d, "PRICE")
    refute P.dict_key?(d, "nope")
    assert_equal 10.0, P.dict_get(d, "price")
    assert_nil P.dict_get(d, "missing")
  end

  def test_find_dict_case_insensitive
    d1 = FakeDict.new("SU_InstanceSet", {})
    d2 = FakeDict.new("AppliedSchemaTypes", {})
    pairs = [[Object.new, d1], [Object.new, d2]]
    assert_equal d1, P.find_dict(pairs, "su_instanceset")[1]
    assert_equal d2, P.find_dict(pairs, "appliedschematypes")[1]
    assert_nil P.find_dict(pairs, "missing")
  end

  def test_coerce_dict_value_types
    assert_in_delta 4.5, P.coerce_dict_value(1.0, "4.5")
    assert_equal true, P.coerce_dict_value(false, "true")
    assert_equal true, P.coerce_dict_value(false, "1")
    assert_equal false, P.coerce_dict_value(true, "0")
    assert_equal "abc", P.coerce_dict_value("x", "abc")
    assert_raises(StandardError) { P.coerce_dict_value(1.0, "abc") }
    assert_raises(StandardError) { P.coerce_dict_value(true, "x") }
  end

  # A param name containing "!" is a driver: sketchup!<prop> writes a
  # native property, <dict>!<key> a dictionary value. sketchup! wins over
  # a dictionary literally named "sketchup".
  def test_driver_names
    assert P.driver_name?("sketchup!name")
    assert P.driver_name?("SU_InstanceSet!Price")
    refute P.driver_name?("thickness")
    refute P.driver_name?(nil)

    assert_equal [:sketchup, "name"], P.driver_target("sketchup!name")
    assert_equal [:dict, "su_instanceset", "price"],
                 P.driver_target("su_instanceset!price")
    assert_equal [:dict, "d", "k"], P.driver_target("d!k")
    assert_nil P.driver_target("x")
    assert_nil P.driver_target("d!")
    # model!/scene! are reserved read-only scopes - never writable.
    assert_nil P.driver_target("model!name")
    assert_nil P.driver_target("scene!name")
    assert_nil P.driver_target("MODEL!units")
  end

  # _<name>_formula discovery must round-trip "!" in attr names - a
  # stored _sketchup!name_formula materializes a driver param.
  def test_driver_meta_discovery
    dict = { "_sketchup!name_formula" => "=\"A\"",
             "_su_instanceset!price_formula" => "=x*2" }
    names = OpenSketchupDC::OpenDC::DCReader.attr_names(dict)
    assert_includes names, "sketchup!name"
    assert_includes names, "su_instanceset!price"
  end

  def test_prop_table_shape
    assert_equal %w[name instname description summary itemcode creator layer],
                 P::WRITABLE
    assert P::PROP_NAMES.include?("persistentid")
    assert P::PROP_NAMES.include?("guid")
    refute P::WRITABLE.include?("guid")
    refute P::WRITABLE.include?("persistentid")
  end

  def test_model_scene_prop_tables
    %w[name title filename path description units lat lng northangle
       georeferenced scenecount].each do |n|
      assert P::MODEL_PROP_NAMES.include?(n), "missing model!#{n}"
    end
    %w[name description usetime transitiontime pagetime].each do |n|
      assert P::SCENE_PROP_NAMES.include?(n), "missing scene!#{n}"
    end
    # Behavior builtins gained synthesized rows so they are reachable.
    %w[onclick copies copy scaletool].each do |n|
      assert OpenSketchupDC::OpenDC::DCReader::BUILTIN_UNITS.key?(n),
             "missing builtin #{n}"
    end
  end
end
