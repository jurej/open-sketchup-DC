module OpenSketchupDC
  module OpenDC
    PLUGIN_ID = "OpenSketchupDC_OpenDC".freeze
    PLUGIN_NAME = "Open DC".freeze
    VERSION = "0.1.0".freeze

    # Trimble Dynamic Components dictionary (the "classic" format).
    DC_DICT = "dynamic_attributes".freeze
    # Our own engine's dictionary.
    OS_DC_DICT = "open_dc".freeze

    ENGINE_CLASSIC = "classic".freeze
    ENGINE_OS = "osdc".freeze

    # Meta fields stored as _<attr>_<field> in both dictionary formats.
    META_FIELDS = %w[
      label formula formulaunits access options units formlabel
      nominal error display
    ].freeze

    # Keys that are entity-level metadata, not user attributes.
    SYSTEM_KEYS = %w[
      _name _formatversion _hasbehaviors _has_movetool_behaviors
      _has_interact_behaviors _lengthunits _lastmodified _scaletool
      _engine _legacy_dc
    ].freeze

    # Access levels for user-visible params (same semantics as classic DC).
    ACCESS_NONE    = "NONE".freeze
    ACCESS_VIEW    = "VIEW".freeze
    ACCESS_TEXTBOX = "TEXTBOX".freeze
    ACCESS_LIST    = "LIST".freeze
    ACCESS_LEVELS  = [ACCESS_NONE, ACCESS_VIEW, ACCESS_TEXTBOX, ACCESS_LIST].freeze

    # Attributes that drive the applier (position / rotation / size / state).
    APPLIED_ATTRS = %w[
      x y z rotx roty rotz lenx leny lenz hidden material copies
    ].freeze
  end
end
