{% if flag?(:win32) %}
  require "./private_storage/windows"
{% elsif flag?(:darwin) || flag?(:linux) %}
  require "./private_storage/posix"
{% else %}
  {% raise "TinRelay does not support this platform" %}
{% end %}
