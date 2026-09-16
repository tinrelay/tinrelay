{% if flag?(:win32) %}
  require "./child_lifetime/windows"
{% elsif flag?(:darwin) || flag?(:linux) %}
  require "./child_lifetime/posix"
{% else %}
  {% raise "TinRelay does not support this platform" %}
{% end %}
