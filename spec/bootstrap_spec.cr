require "./spec_helper"

private def write_site_config(path : String, name : String, base_url : String,
                              wordmark : String, art_manifest_path : String? = nil) : Nil
  File.write(
    path,
    {
      site: {
        site_name:         name,
        base_url:          base_url,
        wordmark:          wordmark,
        art_manifest_path: art_manifest_path,
      },
    }.to_json
  )
end

private def social_preview(body : String) : Tuple(String, String)
  head = body.split("</head>", 2).first
  title = head.match(
    /<meta property="og:title" content="([^"]+)">/
  ).not_nil![1]
  description = head.match(
    /<meta property="og:description" content="([^"]+)">/
  ).not_nil![1]
  {title, description}
end

private def assert_site_identity(origin : String, name : String, base_url : String,
                                 wordmark : String, stylesheet : String? = nil) : Nil
  response = HTTP::Client.get(origin)
  response.body.should contain("<title>#{name} - #{name}</title>")
  response.body.should contain(%(href="#{base_url}/"))
  response.body.should contain(%(href="#{base_url}/index.md"))
  response.body.should contain("<span>#{wordmark}</span>")
  response.body.should contain(%(href="#{stylesheet}")) if stylesheet
  response.headers["Link"].should contain("<#{base_url}/index.md>")

  coordinate = "steward@harbor"
  home_preview = social_preview(response.body)
  line_preview = social_preview(HTTP::Client.get("#{origin}/line").body)
  directed_preview = social_preview(HTTP::Client.get("#{origin}/steward%40harbor").body)
  home_preview[0].should eq(name)
  home_preview[1].should contain(name)
  home_preview[1].should contain("ship-to-ship radio")
  line_preview.each do |value|
    value.should contain(name)
    value.should contain("radio")
    value.should_not contain(coordinate)
  end
  directed_preview.each do |value|
    value.should contain(name)
    value.should contain("line")
    value.should contain(coordinate)
  end

  llms = HTTP::Client.get("#{origin}/llms.txt")
  llms.body.should contain("#{base_url}/line/index.md")
  HTTP::Client.get("#{origin}/sitemap.xml").body.should contain(
    "<loc>#{base_url}/line</loc>"
  )
end

describe "the canonical bootstrap representations" do
  it "uses defaults when optional runtime site configuration is absent" do
    TinrelaySpec.with_server do |_root, origin, _api|
      response = HTTP::Client.get(origin)
      response.body.should contain("<title>TinRelay - TinRelay</title>")
      response.body.should contain(%(href="https://tinrelay.space/"))
    end
  end

  it "loads and atomically reloads complete runtime site identity" do
    root = TinrelaySpec.temporary_root
    config_path = File.join(root, "tinrelayd.json")
    template = File.expand_path("../templates/common-bootstrap.md", __DIR__)
    first_art = File.join(root, "first-art.json")
    second_art = File.join(root, "second-art.json")
    File.write(first_art, {"home" => "/art/harbor.css"}.to_json)
    File.write(second_art, {"home" => "/art/signal.css"}.to_json)
    write_site_config(
      config_path, "Harbor & Signal", "https://radio.example/", "Harbor Signal",
      first_art
    )
    config = Tinrelay::ServerConfig.new(
      "127.0.0.1", 0, File.join(root, "service.db"), template,
      "https://example.test/tinrelay.git", System.cpu_count,
      TinrelaySpec::DEFAULT_METADATA_LIMIT
    )
    begin
      Dir.cd(root) do
        api = Tinrelay::API.new(config)
        server = HTTP::Server.new(api.handler)
        address = server.bind_tcp("127.0.0.1", 0)
        spawn { server.listen }
        Fiber.yield
        origin = "http://127.0.0.1:#{address.port}"
        begin
          assert_site_identity(
            origin, "Harbor &amp; Signal", "https://radio.example", "Harbor Signal",
            "/art/harbor.css"
          )

          write_site_config(
            config_path, "Signal House", "https://signal.example", "Signal  House",
            second_art
          )
          api.reload_configuration
          assert_site_identity(
            origin, "Signal House", "https://signal.example", "Signal  House",
            "/art/signal.css"
          )

          write_site_config(
            config_path, "Broken", "https://broken.example", " Broken", second_art
          )
          expect_raises(Tinrelay::Invalid) { api.reload_configuration }
          assert_site_identity(
            origin, "Signal House", "https://signal.example", "Signal  House",
            "/art/signal.css"
          )

          write_site_config(
            config_path, "Broken", "https://broken.example", "Broken Mark",
            File.join(root, "missing-art.json")
          )
          expect_raises(Tinrelay::Invalid) { api.reload_configuration }
          assert_site_identity(
            origin, "Signal House", "https://signal.example", "Signal  House",
            "/art/signal.css"
          )

          File.delete(config_path)
          expect_raises(Tinrelay::Invalid) { api.reload_configuration }
          assert_site_identity(
            origin, "Signal House", "https://signal.example", "Signal  House",
            "/art/signal.css"
          )
        ensure
          server.close
          api.close
        end
      end

      expect_raises(Tinrelay::Invalid) do
        Tinrelay::TinrelaydConfig.load(File.join(root, "missing.json"))
      end

      unknown_top = File.join(root, "unknown-top.json")
      File.write(unknown_top, {
        site: {
          site_name: "TinRelay", base_url: "https://tinrelay.space",
          wordmark: "Tin Relay", art_manifest_path: nil,
        },
        typo: true,
      }.to_json)
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::TinrelaydConfig.load(unknown_top)
      end

      unknown_site = File.join(root, "unknown-site.json")
      File.write(unknown_site, {
        site: {
          site_name: "TinRelay", base_url: "https://tinrelay.space",
          wordmark: "Tin Relay", art_manifest_path: nil,
          art_manfiest_path: nil,
        },
      }.to_json)
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::TinrelaydConfig.load(unknown_site)
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "serves one canonical public homepage as Markdown and HTML" do
    TinrelaySpec.with_server do |_root, origin, api|
      expected = api.bootstrap_page.homepage
      markdown = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      markdown.status_code.should eq(200)
      markdown.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      markdown.headers["Vary"].should eq("Accept")
      markdown.body.should eq(expected)
      markdown.body.should contain(
        "[![A TinRelay exchange between Tamsin aboard northbound and Sabine aboard quiet-signal.]"
      )

      explicit = HTTP::Client.get("#{origin}/index.md")
      explicit.status_code.should eq(200)
      explicit.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      explicit.body.should eq(expected)

      browser = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      browser.body.should eq(
        api.bootstrap_page.html(expected, false, "/index.md", "home")
      )
      browser.body.should contain(%(data-page="home"))
      browser.body.should contain(
        %(<img src="/tinrelay-art/home/assets/) +
        %(northbound-quiet-signal-conversation.1d58d472e312.webp" ) +
        %(alt="A TinRelay exchange between Tamsin aboard northbound ) +
        %(and Sabine aboard quiet-signal." />)
      )
      browser.body.should contain(
        %(<a href="/tinrelay-art/home/assets/) +
        %(northbound-quiet-signal-conversation-full.611f397815e0.png">)
      )
      browser.body.should contain(%(<link rel="canonical" href="https://tinrelay.space/">))
      browser.body.should contain(
        %(<link rel="alternate" type="text/markdown" ) +
        %(href="https://tinrelay.space/index.md">)
      )
      browser.body.should contain(
        %(<link rel="icon" href="/tinrelay-art/identity/favicon.cf4c5f39348a.ico" ) +
        %(sizes="16x16 32x32 48x48">)
      )
      browser.body.should contain(
        %(<link rel="icon" type="image/svg+xml" ) +
        %(href="/tinrelay-art/identity/favicon.50beb0bc304b.svg" sizes="any">)
      )
      browser.body.should contain(
        %(<link rel="apple-touch-icon" ) +
        %(href="/tinrelay-art/identity/apple-touch-icon.87a03ed48d86.png">)
      )
      browser.body.should contain(
        %(<link rel="mask-icon" ) +
        %(href="/tinrelay-art/identity/mask-icon.a17f08eea9a2.svg" color="#080b14">)
      )
      browser.body.should contain(%(<meta name="theme-color" content="#080b14">))
      browser.body.should contain(
        %(<link rel="stylesheet" ) +
        %(href="/tinrelay-art/identity/wordmark.07d6c616afc0.css">)
      )
      script_path = browser.body.match(
        %r{<script defer src="(/assets/tinrelay/home-copy\.[0-9a-f]{64}\.js)"></script>}
      ).not_nil![1]
      script = HTTP::Client.get("#{origin}#{script_path}")
      script.status_code.should eq(200)
      script.headers["Content-Type"].should eq("text/javascript; charset=utf-8")
      script.headers["X-Content-Type-Options"].should eq("nosniff")
      script.body.should eq(File.read(
        File.join(File.dirname(api.bootstrap_page.common_path),
          "assets", "tinrelay", "home-copy.js")
      ))
      browser.headers["Content-Security-Policy"].should contain("script-src 'self'")
      browser.headers["Link"].should contain("/index.md")
      browser.headers["X-Robots-Tag"]?.should be_nil

      head = HTTP::Client.head(
        origin, headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      head.status_code.should eq(200)
      head.body.should be_empty
      head.headers["Content-Length"].to_i.should eq(expected.bytesize)

      browser_head = HTTP::Client.head(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      browser_head.status_code.should eq(200)
      browser_head.body.should be_empty
      browser_head.headers["Content-Type"].should eq("text/html; charset=utf-8")
      browser_head.headers["Content-Length"].to_i.should eq(browser.body.bytesize)
    end
  end

  it "keeps public HTML stable while live radio status is dormant" do
    TinrelaySpec.with_server do |_root, origin, api|
      response = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      response.body.should_not contain("Line quiet")
      response.body.should_not contain("radio listening")
      stable_body = response.body

      finished = Channel(Nil).new(2)
      spawn do
        waiter = api.handoffs.park("alpha", 1)
        api.handoffs.wait(waiter, 1.second)
        api.handoffs.release("alpha", waiter)
        finished.send(nil)
      end
      TinrelaySpec.eventually { api.handoffs.waiting_count == 1 }
      response = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      response.body.should eq(stable_body)

      spawn do
        waiter = api.handoffs.park("beta", 1)
        api.handoffs.wait(waiter, 1.second)
        api.handoffs.release("beta", waiter)
        finished.send(nil)
      end
      TinrelaySpec.eventually { api.handoffs.waiting_count == 2 }
      response = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      response.body.should eq(stable_body)

      2.times { TinrelaySpec.receive(finished) }
    end
  end

  it "serves exact canonical Markdown and renders only those bytes for browsers" do
    TinrelaySpec.with_server do |_root, origin, api|
      expected = api.bootstrap_page.markdown
      markdown = HTTP::Client.get(
        "#{origin}/line", headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      markdown.status_code.should eq(200)
      markdown.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      markdown.headers["Vary"].should eq("Accept")
      markdown.headers["Referrer-Policy"].should eq("no-referrer")
      markdown.body.should eq(expected)

      explicit = HTTP::Client.get("#{origin}/line/index.md")
      explicit.body.should eq(expected)
      explicit.headers["Content-Type"].should eq("text/markdown; charset=utf-8")

      browser = HTTP::Client.get(
        "#{origin}/line", headers: HTTP::Headers{"Accept" => "text/html"}
      )
      browser.body.should eq(
        api.bootstrap_page.html(expected, false, "/line/index.md", "meet")
      )
      browser.headers["Content-Security-Policy"].should contain("default-src 'none'")
      browser.headers["Content-Security-Policy"].should contain("style-src 'self'")
      browser.headers["Content-Security-Policy"].should_not contain("'unsafe-inline'")
      browser.headers["Content-Security-Policy"].should contain("img-src 'self'")
      browser.headers["Content-Security-Policy"].should contain("font-src 'self'")
      browser.headers["Content-Security-Policy"].should_not contain("script-src")
      browser.body.should_not match(%r{/assets/tinrelay/home-copy\.[0-9a-f]{64}\.js})
      browser.headers["Link"].should contain("/line/index.md")

      refused_markdown = HTTP::Client.get(
        "#{origin}/line",
        headers: HTTP::Headers{"Accept" => "text/markdown;q=0.0, text/html;q=1"}
      )
      refused_markdown.headers["Content-Type"].should eq("text/html; charset=utf-8")
      refused_markdown.body.should eq(browser.body)

      head = HTTP::Client.head(
        "#{origin}/line", headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      head.status_code.should eq(200)
      head.body.should be_empty
      head.headers["Content-Length"].to_i.should eq(expected.bytesize)
    end
  end

  it "serves the plain built-in presentation without external art" do
    TinrelaySpec.with_server do |_root, origin, api|
      browser = HTTP::Client.get(
        origin, headers: HTTP::Headers{"Accept" => "text/html"}
      )
      stylesheet_path = browser.body
        .scan(%r{href="(/assets/tinrelay/plain\.[0-9a-f]{64}\.css)"})
        .first[1]
      stylesheet = HTTP::Client.get("#{origin}#{stylesheet_path}")
      stylesheet.status_code.should eq(200)
      stylesheet.headers["Content-Type"].should eq("text/css; charset=utf-8")
      stylesheet.headers["X-Content-Type-Options"].should eq("nosniff")
      stylesheet.headers["Cache-Control"].should eq(
        "public, max-age=31536000, immutable"
      )
      stylesheet.body.should eq(
        File.read(File.join(File.dirname(api.bootstrap_page.common_path),
          "assets", "tinrelay", "plain.css"))
      )

      HTTP::Client.get(
        "#{origin}/assets/tinrelay/not-allowlisted.css"
      ).status_code.should eq(404)
      HTTP::Client.get(
        "#{origin}/assets/tinrelay/../common-bootstrap.md"
      ).status_code.should eq(404)
    end
  end

  it "changes the plain stylesheet URL when its exact bytes change" do
    root = TinrelaySpec.temporary_root
    begin
      assets = File.join(root, "assets", "tinrelay")
      Dir.mkdir_p(assets)
      File.write(File.join(root, "common-bootstrap.md"), "# Placeholder\n")
      File.write(
        File.join(root, "meet-shell.html"),
        %(<html><head>{{PLAIN_STYLESHEET}}</head><body>{{BODY}}</body></html>\n)
      )
      css_path = File.join(assets, "plain.css")
      File.write(css_path, "body { color: white; }\n")
      first = Tinrelay::BootstrapPage.new(
        File.join(root, "common-bootstrap.md"), "https://example.test/tinrelay.git"
      ).html("# One\n", false, "/index.md", "meet")

      File.write(css_path, "body { color: amber; }\n")
      second = Tinrelay::BootstrapPage.new(
        File.join(root, "common-bootstrap.md"), "https://example.test/tinrelay.git"
      ).html("# One\n", false, "/index.md", "meet")

      first_path = first.match(%r{/assets/tinrelay/plain\.[0-9a-f]{64}\.css}).not_nil![0]
      second_path = second.match(%r{/assets/tinrelay/plain\.[0-9a-f]{64}\.css}).not_nil![0]
      first_path.should_not eq(second_path)
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "serves a plain directed journey from one public coordinate" do
    TinrelaySpec.with_server do |_root, origin, api|
      coordinate = "steward@harbor"
      expected = api.bootstrap_page.markdown(coordinate)
      response = HTTP::Client.get(
        "#{origin}/steward%40harbor",
        headers: HTTP::Headers{"Accept" => "text/html"}
      )
      response.status_code.should eq(200)
      response.headers["Cache-Control"].should eq("no-store")
      response.headers["X-Robots-Tag"].should contain("noindex")
      response.body.should eq(
        api.bootstrap_page.html(
          expected, true, "/steward%40harbor/index.md", "meet", coordinate: coordinate
        )
      )
      response.body.should contain(coordinate)
      response.body.split("</head>", 2).first.should contain(coordinate)
      response.body.should contain(%(href="#{api.bootstrap_page.source_repository}">Source</a>))
      response.body.should_not contain("{{SOURCE_REPOSITORY}}")

      markdown = HTTP::Client.get("#{origin}/steward%40harbor/index.md")
      markdown.body.should eq(expected)
      markdown.headers["X-Robots-Tag"].should contain("noindex")

      ship_general = HTTP::Client.get("#{origin}/%40harbor")
      ship_general.status_code.should eq(200)
      ship_general.body.should contain("<code>@harbor</code>")
    end
  end

  it "publishes distinct social previews for home and line routes" do
    TinrelaySpec.with_server do |_root, origin, _api|
      headers = HTTP::Headers{"Accept" => "text/html"}
      home = HTTP::Client.get(origin, headers: headers).body
      line = HTTP::Client.get("#{origin}/line", headers: headers).body
      coordinate = "steward@harbor"
      directed = HTTP::Client.get("#{origin}/steward%40harbor", headers: headers).body

      previews = [social_preview(home), social_preview(line), social_preview(directed)]
      previews.uniq.size.should eq(3)
      image_alt = home.match(/<img [^>]*alt="([^"]+)"/).not_nil![1]
      previews[0][1].should_not eq(image_alt)
      previews[2].each(&.should contain(coordinate))
    end
  end

  it "serves the JS-less mentorless and directed meet adventure from canonical Markdown" do
    TinrelaySpec.with_server do |_root, origin, api|
      journeys = {
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

      mentorless_entry = HTTP::Client.get(
        "#{origin}/line", headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      mentorless_entry.body.should contain("/line/already-aboard")
      mentorless_entry.body.should contain("/line/first-light")
      mentorless_entry.headers["Set-Cookie"]?.should be_nil

      journeys.each do |journey, actions|
        actions.each_with_index do |action, index|
          suffix = action == journey ? journey : "#{journey}/#{action}"
          markdown = HTTP::Client.get(
            "#{origin}/line/#{suffix}",
            headers: HTTP::Headers{"Accept" => "text/markdown"}
          )
          markdown.status_code.should eq(200)
          markdown.body.should_not match(/\{\{[A-Z_]+\}\}/)
          markdown.headers["X-Robots-Tag"].should contain("noindex")
          markdown.body.should contain("step #{index + 1} of #{actions.size}")
          markdown.body.should contain("[this page](/line/#{suffix})")
          markdown.body.should contain("[full flight plan](/line/flight-plan)")
        end
      end

      [nil, "steward@harbor"].each do |coordinate|
        base = coordinate ? "/steward%40harbor" : "/line"
        journeys.each_key do |journey|
          [{"hear-the-ping", "open-the-channel"}].each do |action, next_action|
            rendered = api.bootstrap_page.markdown(
              coordinate, action, journey, repeater_origin: origin
            )
            rendered.should contain("](#{base}/#{journey}/#{next_action})")
          end
        end
      end

      coordinate = "steward@harbor"
      encoded = "steward%40harbor"
      directed_entry = HTTP::Client.get(
        "#{origin}/#{encoded}",
        headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      coordinate_at = directed_entry.body.index("`#{coordinate}`").not_nil!
      action_at = directed_entry.body.index("/#{encoded}/already-aboard").not_nil!
      coordinate_at.should be < action_at
      directed_entry.headers["Set-Cookie"]?.should be_nil
      directed_entry.body.scan(/\]\(([^)]+)\)/).each do |match|
        target = match[1]
        target.should_not contain('?')
      end

      journeys.each do |journey, actions|
        actions.each do |action|
          suffix = action == journey ? journey : "#{journey}/#{action}"
          path = "/#{encoded}/#{suffix}"
          markdown = HTTP::Client.get(
            "#{origin}#{path}",
            headers: HTTP::Headers{"Accept" => "text/markdown"}
          )
          markdown.status_code.should eq(200)
          markdown.body.should_not match(/\{\{[A-Z_]+\}\}/)
          markdown.headers["X-Robots-Tag"].should contain("noindex")
        end
      end

      {
        "already-aboard" => "open-the-schematics",
        "first-light"    => "open-the-channel",
      }.each do |journey, action|
        suffix = "#{journey}/#{action}"
        path = "/#{encoded}/#{suffix}"
        markdown = HTTP::Client.get(
          "#{origin}#{path}",
          headers: HTTP::Headers{"Accept" => "text/markdown"}
        )
        expected = api.bootstrap_page.markdown(
          coordinate, action, journey, repeater_origin: origin
        )
        markdown.body.should eq(expected)
        explicit_path = "#{path}/index.md"
        HTTP::Client.get("#{origin}#{explicit_path}").body.should eq(expected)
        browser = HTTP::Client.get(
          "#{origin}#{path}", headers: HTTP::Headers{"Accept" => "text/html"}
        )
        browser.body.should eq(
          api.bootstrap_page.html(expected, true, explicit_path, action, coordinate: coordinate)
        )
      end

      head = HTTP::Client.head("#{origin}/#{encoded}/first-light/open-the-schematics")
      head.status_code.should eq(200)
      head.body.should be_empty
      HTTP::Client.get("#{origin}/#{encoded}/first-light/unknown").status_code.should eq(404)
      HTTP::Client.get("#{origin}/line/open-the-schematics").status_code.should eq(404)

      Tinrelay::BootstrapPage::OPTIONAL_ACTIONS.each do |action|
        journeys.each_key do |journey|
          response = HTTP::Client.get(
            "#{origin}/line/#{journey}/#{action}",
            headers: HTTP::Headers{"Accept" => "text/markdown"}
          )
          response.status_code.should eq(200)
          response.body.should_not match(/\{\{[A-Z_]+\}\}/)
          response.body.should_not contain("full flight plan")
        end
      end
    end
  end

  it "renders the claim command for the public origin that served the journey" do
    TinrelaySpec.with_server do |_root, origin, _api|
      direct = HTTP::Client.get(
        "#{origin}/line/already-aboard/name-the-ship",
        headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      direct.status_code.should eq(200)
      direct.body.should contain(
        %(tinrelay --ship "$SHIP" join --server #{origin})
      )

      proxied = HTTP::Client.get(
        "#{origin}/line/already-aboard/name-the-ship",
        headers: HTTP::Headers{
          "Accept"            => "text/markdown",
          "Host"              => "tinrelay.space",
          "X-Forwarded-Proto" => "https",
        }
      )
      proxied.status_code.should eq(200)
      proxied.body.should contain(
        %(tinrelay --ship "$SHIP" join --server https://tinrelay.space)
      )
      proxied.body.should_not contain("{{REPEATER_ORIGIN}}")

      unsafe = HTTP::Client.get(
        "#{origin}/line/already-aboard/name-the-ship",
        headers: HTTP::Headers{
          "Accept" => "text/markdown",
          "Host"   => "tinrelay.space$(false)",
        }
      )
      unsafe.status_code.should eq(400)
      unsafe.body.should_not contain("$(false)")
    end
  end

  it "serves an unadvertised plain flight plan for either meet context" do
    TinrelaySpec.with_server do |_root, origin, api|
      route_entries = ->(base : String, coordinate : String?) do
        markdown = api.bootstrap_page.markdown(coordinate)
        title = markdown.lines.find(&.starts_with?("# ")).not_nil![2..].strip
        [{
          title: title,
          path:  base,
        }] + Tinrelay::BootstrapPage::JOURNEY_ACTIONS.flat_map do |journey, actions|
          actions.map do |action|
            suffix = action == journey ? journey : "#{journey}/#{action}"
            markdown = api.bootstrap_page.markdown(
              coordinate, action, journey, repeater_origin: origin
            )
            {
              title: markdown.lines.find(&.starts_with?("# ")).not_nil![2..].strip,
              path:  "#{base}/#{suffix}",
            }
          end
        end
      end
      links = ->(markdown : String) do
        markdown.scan(/\[([^\]]+)\]\(([^)]+)\)/).map do |match|
          {title: match[1], path: match[2]}
        end
      end

      mentorless = HTTP::Client.get(
        "#{origin}/line/flight-plan",
        headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      mentorless.status_code.should eq(200)
      mentorless.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      mentorless.headers["X-Robots-Tag"].should eq("noindex, nofollow, noarchive")
      links.call(mentorless.body).should eq(route_entries.call("/line", nil))
      HTTP::Client.get("#{origin}/line/flight-plan/index.md").body.should eq(mentorless.body)

      coordinate = "steward@harbor"
      directed_base = "/steward%40harbor"
      directed = HTTP::Client.get(
        "#{origin}#{directed_base}/flight-plan",
        headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      directed.status_code.should eq(200)
      links.call(directed.body).should eq(route_entries.call(directed_base, coordinate))
      explicit_path = "/steward%40harbor/flight-plan/index.md"
      HTTP::Client.get("#{origin}#{explicit_path}").body.should eq(directed.body)

      browser = HTTP::Client.get(
        "#{origin}#{directed_base}/flight-plan",
        headers: HTTP::Headers{"Accept" => "text/html"}
      )
      browser.body.should eq(
        api.bootstrap_page.html(
          directed.body, true, explicit_path, "flight-plan", coordinate: coordinate
        )
      )
      browser.body.should contain(%(data-page="flight-plan"))
      plain_stylesheet = browser.body.match(
        %r{href="(/assets/tinrelay/plain\.[0-9a-f]{64}\.css)"}
      ).not_nil![1]
      browser.body.scan(/<link rel="stylesheet" href="([^"]+)">/).map(&.[1]).should eq([
        plain_stylesheet,
        "/tinrelay-art/identity/wordmark.07d6c616afc0.css",
      ])
      browser.body.split("</head>", 2).first.should contain(coordinate)

      llms = HTTP::Client.get("#{origin}/llms.txt").body
      homepage = HTTP::Client.get(origin).body
      line = HTTP::Client.get("#{origin}/line").body
      robots = HTTP::Client.get("#{origin}/robots.txt").body
      sitemap = HTTP::Client.get("#{origin}/sitemap.xml").body
      [homepage, line, llms, robots, sitemap].each do |advertised_surface|
        advertised_surface.should_not contain("/line/flight-plan")
      end
    end
  end

  it "keeps raw template HTML inert" do
    root = TinrelaySpec.temporary_root
    begin
      File.write(
        File.join(root, "common-bootstrap.md"),
        <<-MARKDOWN
          # Safe

          {{COORDINATE_BLOCK}}
          <script>window.bad = true</script>

          [Continue]({{MEET_ROOT}})
          MARKDOWN
      )
      File.write(File.join(root, "meet-shell.html"), "<html><body>{{BODY}}</body></html>\n")
      page = Tinrelay::BootstrapPage.new(
        File.join(root, "common-bootstrap.md"),
        "https://example.test/tinrelay.git"
      )
      rendered = page.html(page.markdown, false, "/line/index.md", "meet")
      rendered.should_not contain("<script>")
      rendered.should contain("<!-- raw HTML omitted -->")
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "uses the first Markdown title in the HTML document title" do
    root = TinrelaySpec.temporary_root
    begin
      File.write(File.join(root, "common-bootstrap.md"), "# Placeholder\n")
      File.write(
        File.join(root, "meet-shell.html"),
        "<html><head><title>{{TITLE}}</title></head><body>{{BODY}}</body></html>\n"
      )
      page = Tinrelay::BootstrapPage.new(
        File.join(root, "common-bootstrap.md"),
        "https://example.test/tinrelay.git"
      )

      rendered = page.html(
        "# A *small* &amp; safe title\n\nBody.\n",
        false,
        "/line/index.md",
        "meet"
      )
      rendered.should contain("<title>A small &amp; safe title - TinRelay</title>")
      rendered.should contain("<h1>A <em>small</em> &amp; safe title</h1>")

      untitled = page.html("Body only.\n", false, "/line/index.md", "meet")
      untitled.should contain("<title>TinRelay</title>")
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "selects optional runtime art by stable page key without changing Markdown" do
    root = TinrelaySpec.temporary_root
    begin
      manifest = File.join(root, "art.json")
      File.write(
        manifest,
        {
          "home"             => "/tinrelay-art/home.71ae.css",
          "meet"             => "/tinrelay-art/meet.a81c.css",
          "open-the-channel" => "/tinrelay-art/open-the-channel.918e.css",
        }.to_json
      )
      TinrelaySpec.with_server(manifest) do |_server_root, origin, api|
        home = HTTP::Client.get(
          origin, headers: HTTP::Headers{"Accept" => "text/html"}
        )
        home.body.should contain(%(data-page="home"))
        home.body.should contain(%(href="/tinrelay-art/home.71ae.css"))

        entry = HTTP::Client.get(
          "#{origin}/line", headers: HTTP::Headers{"Accept" => "text/html"}
        )
        entry.body.should match(
          %r{href="/assets/tinrelay/plain\.[0-9a-f]{64}\.css"}
        )
        entry.body.should contain(%(href="/tinrelay-art/meet.a81c.css"))
        route_art_index = entry.body.index("/tinrelay-art/meet.a81c.css").not_nil!
        wordmark_index = entry.body.index(
          "/tinrelay-art/identity/wordmark.07d6c616afc0.css"
        ).not_nil!
        route_art_index.should be < wordmark_index

        action = HTTP::Client.get(
          "#{origin}/steward%40harbor/first-light/open-the-channel",
          headers: HTTP::Headers{"Accept" => "text/html"}
        )
        action.body.should contain(%(href="/tinrelay-art/open-the-channel.918e.css"))
        action.body.should_not contain("steward@harbor.css")

        unstyled = HTTP::Client.get(
          "#{origin}/line/first-light",
          headers: HTTP::Headers{"Accept" => "text/html"}
        )
        unstyled.body.should match(
          %r{href="/assets/tinrelay/plain\.[0-9a-f]{64}\.css"}
        )
        unstyled.body.should_not contain(%(href="/tinrelay-art/meet.a81c.css"))
        unstyled.body.should_not contain(%(href="/tinrelay-art/open-the-channel.918e.css"))

        flight_plan = HTTP::Client.get(
          "#{origin}/line/flight-plan",
          headers: HTTP::Headers{"Accept" => "text/html"}
        )
        flight_plan.body.should contain(%(data-page="flight-plan"))
        flight_plan.body.should match(
          %r{href="/assets/tinrelay/plain\.[0-9a-f]{64}\.css"}
        )
        flight_plan.body.should_not contain(%(href="/tinrelay-art/meet.a81c.css"))
        flight_plan.body.should_not contain(%(href="/tinrelay-art/open-the-channel.918e.css"))

        markdown = HTTP::Client.get(
          "#{origin}/line",
          headers: HTTP::Headers{"Accept" => "text/markdown"}
        )
        markdown.body.should eq(api.bootstrap_page.markdown)
        markdown.body.should_not contain("/tinrelay-art/")
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "rejects malformed runtime art configuration before serving" do
    root = TinrelaySpec.temporary_root
    begin
      oversized_path = File.join(root, "oversized.json")
      File.write(oversized_path, Bytes.new(Tinrelay::ArtManifest::MAX_BYTES + 1))
      oversized = expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(
          oversized_path, Tinrelay::BootstrapPage::PAGE_KEYS
        )
      end
      oversized.message.should eq(
        "art manifest exceeds #{Tinrelay::ArtManifest::MAX_BYTES} bytes"
      )

      invalid_json = File.join(root, "invalid.json")
      File.write(invalid_json, "[]")
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(invalid_json, Tinrelay::BootstrapPage::PAGE_KEYS)
      end

      unknown_page = File.join(root, "unknown-page.json")
      File.write(unknown_page, {"future-page" => "/art/future.css"}.to_json)
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(unknown_page, Tinrelay::BootstrapPage::PAGE_KEYS)
      end

      unsafe_url = File.join(root, "unsafe-url.json")
      File.write(unsafe_url, {"meet" => "https://outside.example/meet.css"}.to_json)
      expect_raises(Tinrelay::Invalid) do
        Tinrelay::ArtManifest.load(unsafe_url, Tinrelay::BootstrapPage::PAGE_KEYS)
      end
    ensure
      FileUtils.rm_r(root) if Dir.exists?(root)
    end
  end

  it "keeps public discovery bounded and negotiates unknown routes" do
    TinrelaySpec.with_server do |_root, origin, _api|
      HTTP::Client.get("#{origin}/line").status_code.should eq(200)
      HTTP::Client.get("#{origin}/line/").status_code.should eq(404)
      HTTP::Client.get("#{origin}/join").status_code.should eq(404)
      HTTP::Client.get(origin).status_code.should eq(200)

      llms = HTTP::Client.get("#{origin}/llms.txt")
      llms.status_code.should eq(200)
      llms.body.should contain("/index.md")
      llms.body.should contain("/line/index.md")
      robots = HTTP::Client.get("#{origin}/robots.txt")
      robots.body.should contain("Allow: /$")
      robots.body.should contain("Allow: /line$")
      robots.body.should contain("Disallow: /*@*")
      robots.body.should contain("Disallow: /*%40*")
      robots.body.should contain("Disallow: /v1/")
      sitemap = HTTP::Client.get("#{origin}/sitemap.xml")
      sitemap.body.should contain("<loc>https://tinrelay.space/</loc>")
      sitemap.body.should contain("https://tinrelay.space/line")
      sitemap.body.should_not contain("steward@harbor")

      public_missing = HTTP::Client.get(
        "#{origin}/missing",
        headers: HTTP::Headers{"Accept" => "text/markdown"}
      )
      public_missing.status_code.should eq(404)
      public_missing.headers["Content-Type"].should eq("text/markdown; charset=utf-8")
      api_missing = HTTP::Client.get(
        "#{origin}/v1/missing",
        headers: HTTP::Headers{"X-Tinrelay-Protocol" => Tinrelay::PROTOCOL.to_s}
      )
      api_missing.status_code.should eq(404)
      api_missing.headers["Content-Type"].should start_with("application/json")
    end
  end
end
