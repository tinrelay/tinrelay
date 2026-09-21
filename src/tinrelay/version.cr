module Tinrelay
  VERSION                   = "0.3.0"
  PROTOCOL                  = 1
  HAIL_LIFETIME_SECONDS     = 60 * 60
  FALLBACK_LIFETIME_SECONDS = 96 * 60 * 60
  BUILD_LABEL               = {{ env("TINRELAY_BUILD_LABEL") || "development" }}
end
