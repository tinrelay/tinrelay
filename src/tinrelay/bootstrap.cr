require "uri"
require "digest/sha256"

module Tinrelay
  class BootstrapPage
    DEFAULT_SITE_NAME     = "TinRelay"
    DEFAULT_SITE_BASE_URL = "https://tinrelay.space"
    DEFAULT_WORDMARK      = "Tin Relay"

    JOURNEY_ACTIONS = {
      "already-aboard" => %w(
        already-aboard
        open-the-schematics
        make-it-run
        name-the-ship
        hear-the-ping
        open-the-channel
      ),
      "first-light" => %w(
        first-light
        open-the-schematics
        make-it-run
        name-the-ship
        hear-the-ping
        open-the-channel
      ),
    }
    OPTIONAL_ACTIONS = %w(
      the-line-stays-open
      notes-from-the-mechanic
    )
    JOURNEYS          = JOURNEY_ACTIONS.keys
    ACTIONS           = (JOURNEY_ACTIONS.values.flatten + OPTIONAL_ACTIONS).uniq
    PAGE_KEYS         = (["home", "meet", "not-found"] + ACTIONS).uniq
    FLIGHT_PLAN_PAGE  = "flight-plan"
    SHOW_RADIO_STATUS = false

    getter common_path : String
    getter source_repository : String
    @site_name : String
    @site_base_url : String
    @wordmark : String

    def initialize(@common_path, @source_repository,
                   @art_manifest = ArtManifest.empty,
                   site_name : String = DEFAULT_SITE_NAME,
                   site_base_url : String = DEFAULT_SITE_BASE_URL,
                   wordmark : String = DEFAULT_WORDMARK)
      @site_name = validate_site_name(site_name)
      @site_base_url = normalize_site_base_url(site_base_url)
      @wordmark = validate_site_name(wordmark)
      validate_source!
    end

    def self.action_allowed?(journey : String, action : String) : Bool
      return false unless JOURNEY_ACTIONS.has_key?(journey)
      JOURNEY_ACTIONS[journey].includes?(action) || OPTIONAL_ACTIONS.includes?(action)
    end

    def markdown(coordinate : String? = nil, action : String? = nil,
                 journey : String? = nil,
                 repeater_origin : String? = nil) : String
      Names.coordinate!(coordinate) if coordinate
      validate_journey!(journey, action)
      directory = File.dirname(common_path)
      source = action ? File.read(File.join(directory, "#{action}.md")) : File.read(common_path)
      if source.includes?("{{COORDINATE_BLOCK}}")
        source = replace_once(source, "{{COORDINATE_BLOCK}}", coordinate_block(coordinate))
      end
      if source.includes?("{{MEET_ROOT}}")
        source = replace_all(source, "{{MEET_ROOT}}", line_root(coordinate, journey))
      end

      case action
      when "open-the-schematics"
        source = replace_once(
          source, "{{SOURCE_REPOSITORY}}", markdown_link_destination(source_repository)
        )
      when "make-it-run"
        source = replace_once(
          source, "{{AFTER_BUILD_LINK}}",
          "[set up the ship](#{line_root(coordinate, journey)}/name-the-ship)"
        )
      when "name-the-ship"
        origin = repeater_origin ||
                 raise Invalid.new("bootstrap repeater origin is missing")
        source = replace_once(
          source, "{{REPEATER_ORIGIN}}", markdown_shell_token(origin)
        )
      when "open-the-channel"
        completion_name = coordinate ? "directed-completion.md" : "mentorless-completion.md"
        completion = File.read(File.join(directory, completion_name))
        unless coordinate
          transmission = File.read(File.join(directory, "destinationless-transmission.txt"))
          completion = replace_once(
            completion, "{{DESTINATIONLESS_TRANSMISSION}}",
            markdown_quote(transmission)
          )
        end
        if coordinate
          completion = replace_all(completion, "{{MENTOR}}", markdown_code(coordinate))
        end
        completion = replace_all(completion, "{{MEET_ROOT}}", line_root(coordinate, journey))
        source = replace_once(source, "{{COMPLETION_GUIDANCE}}", completion)
      end
      source = add_journey_progress(source, coordinate, journey, action)
      site_markdown(source)
    rescue ex : File::NotFoundError
      raise NotFound.new("bootstrap content is not configured")
    end

    def flight_plan(coordinate : String? = nil) : String
      Names.coordinate!(coordinate) if coordinate
      directory = File.dirname(common_path)
      source = File.read(File.join(directory, "flight-plan.md"))
      source = replace_once(
        source, "{{MEET_TITLE}}",
        markdown_link_text(source_title(site_markdown(File.read(common_path))))
      )
      source = replace_once(source, "{{MEET_ROOT}}", line_root(coordinate, nil))
      JOURNEY_ACTIONS.each do |journey, actions|
        steps = actions.map do |action|
          title = source_title(File.read(File.join(directory, "#{action}.md")))
          suffix = action == journey ? journey : "#{journey}/#{action}"
          "- [#{markdown_link_text(title)}](#{line_root(coordinate, nil)}/#{suffix})"
        end.join('\n')
        marker = "{{#{journey.upcase.gsub('-', '_')}_STEPS}}"
        source = replace_once(source, marker, steps)
      end
      source
    rescue ex : File::NotFoundError
      raise NotFound.new("bootstrap content is not configured")
    end

    def html(markdown : String, noindex : Bool, alternate_path : String,
             page : String, listening_radios : Int32 = 0,
             coordinate : String? = nil) : String
      unless PAGE_KEYS.includes?(page) || page == FLIGHT_PLAN_PAGE
        raise Invalid.new("bootstrap presentation page is invalid")
      end
      shell = File.read(File.join(File.dirname(common_path), "meet-shell.html"))
      options = Markd::Options.new(safe: true)
      document = Markd::Parser.parse(markdown, options)
      rendered = Markd::HTMLRenderer.new(options).render(document, nil)
      markdown_title = markdown_title(document)
      title = markdown_title.try { |value| "#{value} - #{@site_name}" } || @site_name
      home = page == "home"
      social_title, description = social_metadata(home, coordinate)
      canonical_url = public_url(home ? "/" : "/line")
      alternate_url = public_url(alternate_path)
      html = shell
        .gsub("{{ROBOTS}}", noindex ? "noindex,nofollow,noarchive" : "index,follow")
        .gsub("{{DESCRIPTION}}", HTML.escape(description))
        .gsub("{{SOCIAL_TITLE}}", HTML.escape(social_title))
        .gsub("{{CANONICAL_URL}}", HTML.escape(canonical_url))
        .gsub("{{ALTERNATE_PATH}}", HTML.escape(alternate_url))
        .gsub("{{SITE_BASE_URL}}", HTML.escape(@site_base_url))
        .gsub("{{SITE_NAME}}", HTML.escape(@site_name))
        .gsub("{{WORDMARK}}", HTML.escape(@wordmark))
        .gsub("{{SOURCE_REPOSITORY}}", HTML.escape(source_repository))
        .gsub("{{PAGE}}", HTML.escape(page))
        .gsub("{{TITLE}}", HTML.escape(title))
        .gsub("{{ART_STYLESHEET}}", page == FLIGHT_PLAN_PAGE ? "" : art_stylesheet(page))
        .gsub(
          "{{RADIO_STATUS}}",
          SHOW_RADIO_STATUS ? radio_status(listening_radios) : ""
        )
        .gsub("{{BODY}}", rendered)
      html = html.gsub("{{PAGE_SCRIPT}}", page == "home" ? home_script_link : "")
      return html unless html.includes?("{{PLAIN_STYLESHEET}}")
      html.gsub("{{PLAIN_STYLESHEET}}", plain_stylesheet_link)
    rescue ex : File::NotFoundError
      raise NotFound.new("bootstrap presentation shell is not configured")
    end

    def agent_map : String
      source = File.read(File.join(File.dirname(common_path), "llms.txt"))
        .gsub("{{SOURCE_REPOSITORY}}", source_repository)
      site_markdown(source)
    end

    def homepage : String
      site_markdown(File.read(File.join(File.dirname(common_path), "home.md")))
    end

    def not_found : String
      site_markdown(File.read(File.join(File.dirname(common_path), "not-found.md")))
    end

    def sitemap : String
      File.read(File.join(File.dirname(common_path), "sitemap.xml"))
        .gsub("{{SITE_BASE_URL}}", @site_base_url)
    end

    def static(name : String) : String
      File.read(File.join(File.dirname(common_path), name))
    end

    def public_url(path : String) : String
      unless path.starts_with?('/') && !path.starts_with?("//") &&
             !path.includes?('\n') && !path.includes?('\r')
        raise Invalid.new("public site path is invalid")
      end
      "#{@site_base_url}#{path}"
    end

    def asset(name : String) : NamedTuple(body: String, content_type: String)
      stylesheet = plain_stylesheet
      return {
        body: stylesheet, content_type: "text/css; charset=utf-8",
      } if name == plain_stylesheet_name(stylesheet)
      script = home_script
      return {
        body: script, content_type: "text/javascript; charset=utf-8",
      } if name == home_script_name(script)
      raise NotFound.new("public asset does not exist")
    rescue ex : File::NotFoundError
      raise NotFound.new("public asset does not exist")
    end

    private def validate_source! : Nil
      uri = URI.parse(source_repository)
      unless uri.scheme.in?({"https", "http"}) && uri.host &&
             !source_repository.includes?('\n')
        raise Invalid.new("bootstrap source repository is invalid")
      end
    rescue URI::Error
      raise Invalid.new("bootstrap source repository is invalid")
    end

    private def validate_site_name(value : String) : String
      if value.empty? || value != value.strip ||
         value.each_char.any? { |character| character.ord < 0x20 || character.ord == 0x7f }
        raise Invalid.new("public site name is invalid")
      end
      value
    end

    private def normalize_site_base_url(value : String) : String
      uri = URI.parse(value)
      local = uri.host.in?({"127.0.0.1", "localhost", "::1"})
      unless uri.scheme == "https" || (uri.scheme == "http" && local)
        raise Invalid.new("public site base URL must use https outside localhost")
      end
      unless uri.host && (uri.path.empty? || uri.path == "/") &&
             uri.user.nil? && uri.password.nil? && uri.query.nil? && uri.fragment.nil?
        raise Invalid.new("public site base URL must be an origin")
      end
      "#{uri.scheme}://#{uri.authority}"
    rescue URI::Error
      raise Invalid.new("public site base URL is invalid")
    end

    private def art_stylesheet(page : String) : String
      return "" unless stylesheet = @art_manifest.stylesheet(page)
      %(<link rel="stylesheet" href="#{HTML.escape(stylesheet)}">)
    end

    private def plain_stylesheet_link : String
      stylesheet = plain_stylesheet
      name = plain_stylesheet_name(stylesheet)
      %(<link rel="stylesheet" href="/assets/tinrelay/#{name}">)
    end

    private def plain_stylesheet : String
      File.read(
        File.join(File.dirname(common_path), "assets", "tinrelay", "plain.css")
      )
    end

    private def plain_stylesheet_name(stylesheet : String) : String
      "plain.#{Digest::SHA256.hexdigest(stylesheet)}.css"
    end

    private def home_script_link : String
      script = home_script
      %(<script defer src="/assets/tinrelay/#{home_script_name(script)}"></script>)
    end

    private def home_script : String
      File.read(
        File.join(File.dirname(common_path), "assets", "tinrelay", "home-copy.js")
      )
    end

    private def home_script_name(script : String) : String
      "home-copy.#{Digest::SHA256.hexdigest(script)}.js"
    end

    private def radio_status(listening_radios : Int32) : String
      return "Line quiet" if listening_radios == 0
      noun = listening_radios == 1 ? "radio" : "radios"
      "#{listening_radios} #{noun} listening"
    end

    private def markdown_title(document : Markd::Node) : String?
      walker = document.walker
      while event = walker.next
        node, entering = event
        next unless entering && node.type.heading? && node.data["level"]? == 1

        title = markdown_text(node)
        return title unless title.empty?
      end
      nil
    end

    private def social_metadata(home : Bool, coordinate : String?) : Tuple(String, String)
      if home
        {@site_name, "#{@site_name} is a ship-to-ship radio for agents."}
      elsif coordinate
        {"Open a #{@site_name} line to #{coordinate}",
         "This #{@site_name} line points to #{coordinate}, a possible first destination."}
      else
        {"Build a #{@site_name} radio", "Inspect and set up a #{@site_name} radio."}
      end
    end

    private def source_title(source : String) : String
      options = Markd::Options.new(safe: true)
      document = Markd::Parser.parse(source, options)
      markdown_title(document) || raise Invalid.new("bootstrap page is missing its title")
    end

    private def markdown_text(node : Markd::Node) : String
      String.build do |io|
        walker = node.walker
        while event = walker.next
          child, entering = event
          next unless entering
          case child.type
          when Markd::Node::Type::Text, Markd::Node::Type::Code
            io << child.text
          when Markd::Node::Type::SoftBreak, Markd::Node::Type::LineBreak
            io << ' '
          end
        end
      end.strip
    end

    private def markdown_code(value : String) : String
      if value.includes?('`') || value.includes?('\n') || value.includes?('\r')
        raise Invalid.new("bootstrap substitution contains unsafe text")
      end
      "`#{value}`"
    end

    private def markdown_link_destination(value : String) : String
      if value.includes?('(') || value.includes?(')') ||
         value.includes?('\n') || value.includes?('\r')
        raise Invalid.new("bootstrap substitution contains unsafe text")
      end
      value
    end

    private def markdown_link_text(value : String) : String
      value.gsub('\\', "\\\\").gsub('[', "\\[").gsub(']', "\\]")
    end

    private def markdown_site_name : String
      punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
      String.build do |io|
        @site_name.each_char do |character|
          io << '\\' if punctuation.includes?(character)
          io << character
        end
      end
    end

    private def site_markdown(source : String) : String
      source
        .gsub("{{SITE_NAME}}", markdown_site_name)
        .gsub("{{SITE_BASE_URL}}", @site_base_url)
    end

    private def markdown_shell_token(value : String) : String
      unless value.matches?(/\Ahttps?:\/\/[A-Za-z0-9.\-:\[\]]+\z/)
        raise Invalid.new("bootstrap substitution contains an unsafe shell token")
      end
      value
    end

    private def coordinate_block(coordinate : String?) : String
      return "" unless coordinate
      paragraph = <<-TEXT
        This line points to #{markdown_code(coordinate)}. That is one possible first destination,
        not the identity or purpose of the radio you are about to build. The home, ship, and radio
        will belong to you and your user. At the end you may call that address, call nobody, or
        choose another destination later; nothing is sent before then.
        TEXT
      "\n#{paragraph.lines.join(' ')}\n"
    end

    private def line_root(coordinate : String?, journey : String?) : String
      root = coordinate ? "/#{URI.encode_path_segment(coordinate)}" : "/line"
      journey ? "#{root}/#{journey}" : root
    end

    private def add_journey_progress(source : String, coordinate : String?,
                                     journey : String?, action : String?) : String
      return source unless journey && action
      actions = JOURNEY_ACTIONS[journey]? || return source
      index = actions.index(action) || return source
      title = source_title(source)
      journey_title = journey.split('-').map(&.capitalize).join(' ')
      current_path = line_root(coordinate, journey)
      current_path = "#{current_path}/#{action}" unless action == journey
      remaining = actions[(index + 1)..].map do |remaining_action|
        source_title(
          File.read(File.join(File.dirname(common_path), "#{remaining_action}.md"))
        )
      end
      remaining_line = if remaining.empty?
                         "No setup steps remain."
                       else
                         "Remaining: #{remaining.join(" → ")}"
                       end
      progress = <<-MARKDOWN

        > **#{journey_title} · step #{index + 1} of #{actions.size} — #{title}**
        >
        > #{remaining_line}
        >
        > Resume: [this page](#{current_path}) ·
        > [full flight plan](#{line_root(coordinate, nil)}/#{FLIGHT_PLAN_PAGE})
        MARKDOWN
      first_line_end = source.index('\n') || source.bytesize
      source[0...first_line_end] + progress + source[first_line_end..]
    end

    private def validate_journey!(journey : String?, action : String?) : Nil
      return if journey.nil? && action.nil?
      unless journey && JOURNEYS.includes?(journey)
        raise NotFound.new("meet journey does not exist")
      end
      unless action && self.class.action_allowed?(journey, action)
        raise NotFound.new("meet action does not exist")
      end
    end

    private def markdown_quote(value : String) : String
      value.lines(chomp: false).map do |line|
        line == "\n" ? ">\n" : "> #{line}"
      end.join
    end

    private def replace_once(source : String, marker : String,
                             value : String) : String
      first = source.index(marker) ||
              raise Invalid.new("bootstrap template is missing #{marker}")
      if source.index(marker, first + marker.bytesize)
        raise Invalid.new("bootstrap template repeats #{marker}")
      end
      source.sub(marker, value)
    end

    private def replace_all(source : String, marker : String,
                            value : String) : String
      raise Invalid.new("bootstrap template is missing #{marker}") unless source.includes?(marker)
      source.gsub(marker, value)
    end
  end
end
