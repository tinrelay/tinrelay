{% if flag?(:win32) %}
  require "./outgoing_observer_transport/windows"
{% elsif flag?(:darwin) || flag?(:linux) %}
  require "./outgoing_observer_transport/posix"
{% else %}
  {% raise "TinRelay does not support this platform" %}
{% end %}
