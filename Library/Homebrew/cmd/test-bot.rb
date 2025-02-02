# Comprehensively test a formula or pull request.
#
# Usage: brew test-bot [options...] <pull-request|formula>
#
# Options:
# --keep-logs:    Write and keep log files under ./brewbot/
# --cleanup:      Clean the Homebrew directory. Very dangerous. Use with care.
# --clean-cache:  Remove all cached downloads. Use with care.
# --skip-setup:   Don't check the local system is setup correctly.
# --junit:        Generate a JUnit XML test results file.
# --email:        Generate an email subject file.
# --no-bottle:    Run brew install without --build-bottle
# --HEAD:         Run brew install with --HEAD
# --local:        Ask Homebrew to write verbose logs under ./logs/ and set HOME to ./home/
# --tap=<tap>:    Use the git repository of the given tap
# --dry-run:      Just print commands, don't run them.
# --fail-fast:    Immediately exit on a failing step.
#
# --ci-master:         Shortcut for Homebrew master branch CI options.
# --ci-pr:             Shortcut for Homebrew pull request CI options.
# --ci-testing:        Shortcut for Homebrew testing CI options.
# --ci-upload:         Homebrew CI bottle upload.

require 'formula'
require 'utils'
require 'date'
require 'rexml/document'
require 'rexml/xmldecl'
require 'rexml/cdata'
require 'cmd/tap'

module Homebrew
  EMAIL_SUBJECT_FILE = "brew-test-bot.#{MacOS.cat}.email.txt"
  BYTES_IN_1_MEGABYTE = 1024*1024

  def homebrew_git_repo tap=nil
    if tap
      user, repo = tap.split "/"
      HOMEBREW_LIBRARY/"Taps/#{user}/homebrew-#{repo}"
    else
      HOMEBREW_REPOSITORY
    end
  end

  class Step
    attr_reader :command, :name, :status, :output, :time

    def initialize test, command, options={}
      @test = test
      @category = test.category
      @command = command
      @puts_output_on_success = options[:puts_output_on_success]
      @name = command[1].delete("-")
      @status = :running
      @repository = options[:repository] || HOMEBREW_REPOSITORY
      @time = 0
    end

    def log_file_path
      file = "#{@category}.#{@name}.txt"
      root = @test.log_root
      root ? root + file : file
    end

    def status_colour
      case @status
      when :passed  then "green"
      when :running then "orange"
      when :failed  then "red"
      end
    end

    def status_upcase
      @status.to_s.upcase
    end

    def command_short
      (@command - %w[brew --force --retry --verbose --build-bottle --rb]).join(" ")
    end

    def passed?
      @status == :passed
    end

    def failed?
      @status == :failed
    end

    def puts_command
      cmd = @command.join(" ")
      print "#{Tty.blue}==>#{Tty.white} #{cmd}#{Tty.reset}"
      tabs = (80 - "PASSED".length + 1 - cmd.length) / 8
      tabs.times{ print "\t" }
      $stdout.flush
    end

    def puts_result
      puts " #{Tty.send status_colour}#{status_upcase}#{Tty.reset}"
    end

    def has_output?
      @output && !@output.empty?
    end

    def run
      puts_command
      if ARGV.include? "--dry-run"
        puts
        @status = :passed
        return
      end

      start_time = Time.now

      log = log_file_path

      pid = fork do
        File.open(log, "wb") do |f|
          STDOUT.reopen(f)
          STDERR.reopen(f)
        end
        Dir.chdir(@repository) if @command.first == "git"
        exec(*@command)
      end
      Process.wait(pid)

      @time = Time.now - start_time

      @status = $?.success? ? :passed : :failed
      puts_result

      if File.exist?(log)
        @output = fix_encoding File.read(log)
        if has_output? and (failed? or @puts_output_on_success)
          puts @output
        end
        FileUtils.rm(log) unless ARGV.include? "--keep-logs"
      end

      exit 1 if ARGV.include?("--fail-fast") && @status == :failed
    end

    private

    if String.method_defined?(:force_encoding)
      def fix_encoding(str)
        return str if str.valid_encoding?
        # Assume we are starting from a "mostly" UTF-8 string
        str.force_encoding(Encoding::UTF_8)
        str.encode!(Encoding::UTF_16, :invalid => :replace)
        str.encode!(Encoding::UTF_8)
      end
    elsif require "iconv"
      def fix_encoding(str)
        Iconv.conv("UTF-8//IGNORE", "UTF-8", str)
      end
    else
      def fix_encoding(str)
        str
      end
    end
  end

  class Test
    attr_reader :log_root, :category, :name, :steps

    def initialize argument, tap=nil
      @hash = nil
      @url = nil
      @formulae = []
      @added_formulae = []
      @modified_formula = []
      @steps = []
      @tap = tap
      @repository = Homebrew.homebrew_git_repo @tap

      url_match = argument.match HOMEBREW_PULL_OR_COMMIT_URL_REGEX

      begin
        formula = Formulary.factory(argument)
      rescue FormulaUnavailableError
      end

      git "rev-parse", "--verify", "-q", argument
      if $?.success?
        @hash = argument
      elsif url_match
        @url = url_match[0]
      elsif formula
        @formulae = [argument]
      else
        raise ArgumentError.new("#{argument} is not a pull request URL, commit URL or formula name.")
      end

      @category = __method__
      @brewbot_root = Pathname.pwd + "brewbot"
      FileUtils.mkdir_p @brewbot_root
    end

    def no_args?
      @hash == 'HEAD'
    end

    def git(*args)
      rd, wr = IO.pipe

      pid = fork do
        rd.close
        STDERR.reopen("/dev/null")
        STDOUT.reopen(wr)
        wr.close
        Dir.chdir @repository
        exec("git", *args)
      end
      wr.close
      Process.wait(pid)

      rd.read
    ensure
      rd.close
    end

    def download
      def shorten_revision revision
        git("rev-parse", "--short", revision).strip
      end

      def current_sha1
        shorten_revision 'HEAD'
      end

      def current_branch
        git("symbolic-ref", "HEAD").gsub("refs/heads/", "").strip
      end

      def single_commit? start_revision, end_revision
        git("rev-list", "--count", "#{start_revision}..#{end_revision}").to_i == 1
      end

      def diff_formulae start_revision, end_revision, path, filter
        git(
          "diff-tree", "-r", "--name-only", "--diff-filter=#{filter}",
          start_revision, end_revision, "--", path
        ).lines.map do |line|
          File.basename(line.chomp, ".rb")
        end
      end

      @category = __method__
      @start_branch = current_branch

      # Use Jenkins environment variables if present.
      if no_args? and ENV['GIT_PREVIOUS_COMMIT'] and ENV['GIT_COMMIT'] \
         and not ENV['ghprbPullLink']
        diff_start_sha1 = shorten_revision ENV['GIT_PREVIOUS_COMMIT']
        diff_end_sha1 = shorten_revision ENV['GIT_COMMIT']
        test "brew", "update" if current_branch == "master"
      elsif @hash
        diff_start_sha1 = current_sha1
        test "brew", "update" if current_branch == "master"
        diff_end_sha1 = current_sha1
      elsif @url
        test "brew", "update" if current_branch == "master"
      end

      # Handle Jenkins pull request builder plugin.
      if ENV['ghprbPullLink']
        @url = ENV['ghprbPullLink']
        @hash = nil
      end

      if no_args?
        if diff_start_sha1 == diff_end_sha1 or \
          single_commit?(diff_start_sha1, diff_end_sha1)
          @name = diff_end_sha1
        else
          @name = "#{diff_start_sha1}-#{diff_end_sha1}"
        end
      elsif @hash
        test "git", "checkout", @hash
        diff_start_sha1 = "#{@hash}^"
        diff_end_sha1 = @hash
        @name = @hash
      elsif @url
        diff_start_sha1 = current_sha1
        test "git", "checkout", diff_start_sha1
        test "brew", "pull", "--clean", @url
        diff_end_sha1 = current_sha1
        @short_url = @url.gsub('https://github.com/', '')
        if @short_url.include? '/commit/'
          # 7 characters should be enough for a commit (not 40).
          @short_url.gsub!(/(commit\/\w{7}).*/, '\1')
          @name = @short_url
        else
          @name = "#{@short_url}-#{diff_end_sha1}"
        end
      else
        diff_start_sha1 = diff_end_sha1 = current_sha1
        @name = "#{@formulae.first}-#{diff_end_sha1}"
      end

      @log_root = @brewbot_root + @name
      FileUtils.mkdir_p @log_root

      return unless diff_start_sha1 != diff_end_sha1
      return if @url and not steps.last.passed?

      if @tap
        formula_path = %w[Formula HomebrewFormula].find { |dir| (@repository/dir).directory? } || ""
      else
        formula_path = "Library/Formula"
      end

      @added_formulae += diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "A")
      @modified_formula += diff_formulae(diff_start_sha1, diff_end_sha1, formula_path, "M")
      @formulae += @added_formulae + @modified_formula
    end

    def skip formula_name
      puts "#{Tty.blue}==>#{Tty.white} SKIPPING: #{formula_name}#{Tty.reset}"
    end

    def satisfied_requirements? formula, spec, dependency=nil
      requirements = formula.send(spec).requirements

      unsatisfied_requirements = requirements.reject do |requirement|
        satisfied = false
        satisfied ||= requirement.satisfied?
        satisfied ||= requirement.optional?
        if !satisfied && requirement.default_formula?
          default = Formula[requirement.class.default_formula]
          satisfied = satisfied_requirements?(default, :stable, formula.name)
        end
        satisfied
      end

      if unsatisfied_requirements.empty?
        true
      else
        name = formula.name
        name += " (#{spec})" unless spec == :stable
        name += " (#{dependency} dependency)" if dependency
        skip name
        puts unsatisfied_requirements.map(&:message)
        false
      end
    end

    def setup
      @category = __method__
      return if ARGV.include? "--skip-setup"
      test "brew", "doctor"
      test "brew", "--env"
      test "brew", "config"
    end

    def formula formula_name
      @category = "#{__method__}.#{formula_name}"

      test "brew", "uses", formula_name
      dependencies = `brew deps #{formula_name}`.split("\n")
      dependencies -= `brew list`.split("\n")
      unchanged_dependencies = dependencies - @formulae
      changed_dependences = dependencies - unchanged_dependencies

      dependents = `brew uses --skip-build --skip-optional #{formula_name}`.split("\n")
      dependents -= @formulae
      dependents = dependents.map {|d| Formulary.factory(d)}

      testable_dependents = dependents.select { |d| d.test_defined? && d.bottled? }

      formula = Formulary.factory(formula_name)
      installed_gcc = false

      deps = []
      reqs = []

      if formula.stable
        return unless satisfied_requirements?(formula, :stable)

        deps |= formula.stable.deps.to_a
        reqs |= formula.stable.requirements.to_a
      elsif formula.devel
        return unless satisfied_requirements?(formula, :devel)
      end

      if formula.devel && !ARGV.include?('--HEAD')
        deps |= formula.devel.deps.to_a
        reqs |= formula.devel.requirements.to_a
      end

      begin
        deps.each do |dep|
          if dep.is_a?(TapDependency) && dep.tap
            tap_dir = Homebrew.homebrew_git_repo dep.tap
            test "brew", "tap", dep.tap unless tap_dir.directory?
          end
          CompilerSelector.select_for(dep.to_formula)
        end
        CompilerSelector.select_for(formula)
      rescue CompilerSelectionError => e
        unless installed_gcc
          test "brew", "install", "gcc"
          installed_gcc = true
          OS::Mac.clear_version_cache
          retry
        end
        skip formula_name
        puts e.message
        return
      end

      if (deps | reqs).any? { |d| d.name == "mercurial" && d.build? }
        test "brew", "install", "mercurial"
      end

      test "brew", "fetch", "--retry", *unchanged_dependencies unless unchanged_dependencies.empty?
      test "brew", "fetch", "--retry", "--build-bottle", *changed_dependences unless changed_dependences.empty?
      # Install changed dependencies as new bottles so we don't have checksum problems.
      test "brew", "install", "--build-bottle", *changed_dependences unless changed_dependences.empty?
      formula_fetch_options = []
      formula_fetch_options << "--build-bottle" unless ARGV.include? "--no-bottle"
      formula_fetch_options << "--force" if ARGV.include? "--cleanup"
      formula_fetch_options << formula_name
      test "brew", "fetch", "--retry", *formula_fetch_options
      test "brew", "uninstall", "--force", formula_name if formula.installed?
      install_args = %w[--verbose]
      install_args << "--build-bottle" unless ARGV.include? "--no-bottle"
      install_args << "--HEAD" if ARGV.include? "--HEAD"

      # Pass --devel or --HEAD to install in the event formulae lack stable. Supports devel-only/head-only.
      # head-only should not have devel, but devel-only can have head. Stable can have all three.
      if devel_only_tap? formula
        install_args << "--devel"
      elsif head_only_tap? formula
        install_args << "--HEAD"
      end

      install_args << formula_name
      # Don't care about e.g. bottle failures for dependencies.
      ENV["HOMEBREW_DEVELOPER"] = nil
      test "brew", "install", "--only-dependencies", *install_args unless dependencies.empty?
      ENV["HOMEBREW_DEVELOPER"] = "1"
      test "brew", "install", *install_args
      install_passed = steps.last.passed?
      audit_args = [formula_name]
      audit_args << "--strict" if @added_formulae.include? formula_name
      test "brew", "audit", *audit_args
      if install_passed
        if formula.stable? && !ARGV.include?('--no-bottle')
          bottle_args = ["--rb", formula_name]
          if @tap
            tap_user, tap_repo = @tap.split "/"
            bottle_args << "--root-url=#{BottleSpecification::DEFAULT_ROOT_URL}/#{tap_repo}"
          end
          bottle_args << { :puts_output_on_success => true }
          test "brew", "bottle", *bottle_args
          bottle_step = steps.last
          if bottle_step.passed? and bottle_step.has_output?
            bottle_filename =
              bottle_step.output.gsub(/.*(\.\/\S+#{bottle_native_regex}).*/m, '\1')
            test "brew", "uninstall", "--force", formula_name
            test "brew", "install", bottle_filename
          end
        end
        test "brew", "test", "--verbose", formula_name if formula.test_defined?
        testable_dependents.each do |dependent|
          unless dependent.installed?
            test "brew", "fetch", "--retry", dependent.name
            next if steps.last.failed?
            conflicts = dependent.conflicts.map { |c| Formulary.factory(c.name) }.select { |f| f.installed? }
            conflicts.each do |conflict|
              test "brew", "unlink", conflict.name
            end
            test "brew", "install", dependent.name
            next if steps.last.failed?
          end
          if dependent.installed?
            test "brew", "test", "--verbose", dependent.name
          end
        end
        test "brew", "uninstall", "--force", formula_name
      end

      if formula.devel && formula.stable? && !ARGV.include?('--HEAD') \
         && satisfied_requirements?(formula, :devel)
        test "brew", "fetch", "--retry", "--devel", *formula_fetch_options
        test "brew", "install", "--devel", "--verbose", formula_name
        devel_install_passed = steps.last.passed?
        test "brew", "audit", "--devel", *audit_args
        if devel_install_passed
          test "brew", "test", "--devel", "--verbose", formula_name if formula.test_defined?
          test "brew", "uninstall", "--devel", "--force", formula_name
        end
      end
      test "brew", "uninstall", "--force", *unchanged_dependencies unless unchanged_dependencies.empty?
    end

    def homebrew
      @category = __method__
      test "brew", "tests"
      test "brew", "readall"
    end

    def cleanup_before
      @category = __method__
      return unless ARGV.include? '--cleanup'
      git "stash"
      git "am", "--abort"
      git "rebase", "--abort"
      git "reset", "--hard"
      git "checkout", "-f", "master"
      git "clean", "-fdx"
      git "clean", "-ffdx" unless $?.success?
    end

    def cleanup_after
      @category = __method__

      checkout_args = []
      if ARGV.include? '--cleanup'
        test "git", "clean", "-fdx"
        test "git", "clean", "-ffdx" if steps.last.failed?
        checkout_args << "-f"
      end

      checkout_args << @start_branch

      if ARGV.include? '--cleanup' or @url or @hash
        test "git", "checkout", *checkout_args
      end

      if ARGV.include? '--cleanup'
        test "git", "reset", "--hard"
        git "stash", "pop"
        test "brew", "cleanup"
      end

      FileUtils.rm_rf @brewbot_root unless ARGV.include? "--keep-logs"
    end

    def test(*args)
      options = Hash === args.last ? args.pop : {}
      options[:repository] = @repository
      step = Step.new self, args, options
      step.run
      steps << step
      step
    end

    def check_results
      steps.all? do |step|
        case step.status
        when :passed  then true
        when :running then raise
        when :failed  then false
        end
      end
    end

    def formulae
      changed_formulae_dependents = {}
      dependencies = []
      non_dependencies = []

      @formulae.each do |formula|
        formula_dependencies = `brew deps #{formula}`.split("\n")
        unchanged_dependencies = formula_dependencies - @formulae
        changed_dependences = formula_dependencies - unchanged_dependencies
        changed_dependences.each do |changed_formula|
          changed_formulae_dependents[changed_formula] ||= 0
          changed_formulae_dependents[changed_formula] += 1
        end
      end

      changed_formulae = changed_formulae_dependents.sort do |a1,a2|
        a2[1].to_i <=> a1[1].to_i
      end
      changed_formulae.map!(&:first)
      unchanged_formulae = @formulae - changed_formulae
      changed_formulae + unchanged_formulae
    end

    def head_only_tap? formula
      formula.head && formula.devel.nil? && formula.stable.nil? && formula.tap == "homebrew/homebrew-head-only"
    end

    def devel_only_tap? formula
      formula.devel && formula.stable.nil? && formula.tap == "homebrew/homebrew-devel-only"
    end

    def run
      cleanup_before
      download
      setup
      homebrew
      formulae.each do |f|
        formula(f)
      end
      cleanup_after
      check_results
    end
  end

  def test_bot
    tap = ARGV.value('tap')

    if !tap && ENV['UPSTREAM_BOT_PARAMS']
      bot_argv = ENV['UPSTREAM_BOT_PARAMS'].split " "
      bot_argv.extend HomebrewArgvExtension
      tap ||= bot_argv.value('tap')
    end

    git_url = ENV['UPSTREAM_GIT_URL'] || ENV['GIT_URL']
    if !tap && git_url
      # Also can get tap from Jenkins GIT_URL.
      url_path = git_url.gsub(%r{^https?://github\.com/}, "").gsub(%r{/$}, "")
      HOMEBREW_TAP_ARGS_REGEX =~ url_path
      tap = "#{$1}/#{$3}" if $1 && $3
    end

    if Pathname.pwd == HOMEBREW_PREFIX and ARGV.include? "--cleanup"
      odie 'cannot use --cleanup from HOMEBREW_PREFIX as it will delete all output.'
    end

    if ARGV.include? "--email"
      File.open EMAIL_SUBJECT_FILE, 'w' do |file|
        # The file should be written at the end but in case we don't get to that
        # point ensure that we have something valid.
        file.write "#{MacOS.version}: internal error."
      end
    end

    ENV['HOMEBREW_DEVELOPER'] = '1'
    ENV['HOMEBREW_NO_EMOJI'] = '1'
    if ARGV.include? '--ci-master' or ARGV.include? '--ci-pr' \
       or ARGV.include? '--ci-testing'
      ARGV << "--cleanup" if ENV["JENKINS_HOME"] || ENV["TRAVIS_COMMIT"]
      ARGV << "--junit" << "--local"
    end
    if ARGV.include? '--ci-master'
      ARGV << '--no-bottle' << '--email'
    end

    if ARGV.include? '--local'
      ENV['HOME'] = "#{Dir.pwd}/home"
      mkdir_p ENV['HOME']
      ENV['HOMEBREW_LOGS'] = "#{Dir.pwd}/logs"
    end

    repository = Homebrew.homebrew_git_repo tap

    # Tap repository if required, this is done before everything else
    # because Formula parsing and/or git commit hash lookup depends on it.
    if tap
      if !repository.directory?
        safe_system "brew", "tap", tap
      else
        safe_system "brew", "tap", "--repair"
      end
    end

    if ARGV.include? '--ci-upload'
      jenkins = ENV['JENKINS_HOME']
      job = ENV['UPSTREAM_JOB_NAME']
      id = ENV['UPSTREAM_BUILD_ID']
      raise "Missing Jenkins variables!" unless jenkins and job and id

      user = ENV["BINTRAY_USER"]
      key = ENV["BINTRAY_KEY"]
      raise "Missing Bintray variables!" unless user && key

      ARGV << '--verbose'

      bottles = Dir["#{jenkins}/jobs/#{job}/configurations/axis-version/*/builds/#{id}/archive/*.bottle*.*"]
      return if bottles.empty?
      FileUtils.cp bottles, Dir.pwd, :verbose => true

      ENV["GIT_COMMITTER_NAME"] = "BrewTestBot"
      ENV["GIT_COMMITTER_EMAIL"] = "brew-test-bot@googlegroups.com"
      ENV["GIT_WORK_TREE"] = repository
      ENV["GIT_DIR"] = "#{ENV["GIT_WORK_TREE"]}/.git"

      pr = ENV['UPSTREAM_PULL_REQUEST']
      number = ENV['UPSTREAM_BUILD_NUMBER']

      system "git am --abort 2>/dev/null"
      system "git rebase --abort 2>/dev/null"
      safe_system "git", "checkout", "-f", "master"
      safe_system "git", "reset", "--hard", "origin/master"
      safe_system "brew", "update"

      if pr
        pull_pr = if tap
          user, repo = tap.split "/"
          "https://github.com/#{user}/homebrew-#{repo}/pull/#{pr}"
        else
          pr
        end
        safe_system "brew", "pull", "--clean", pull_pr
      end

      ENV["GIT_AUTHOR_NAME"] = ENV["GIT_COMMITTER_NAME"]
      ENV["GIT_AUTHOR_EMAIL"] = ENV["GIT_COMMITTER_EMAIL"]
      safe_system "brew", "bottle", "--merge", "--write", *Dir["*.bottle.rb"]

      remote_repo = tap ? tap.gsub("/", "-") : "homebrew"

      remote = "git@github.com:BrewTestBot/#{remote_repo}.git"
      tag = pr ? "pr-#{pr}" : "testing-#{number}"
      safe_system "git", "push", "--force", remote, "master:master", ":refs/tags/#{tag}"

      # SourceForge upload (will be removed soon)
      path = "/home/frs/project/m/ma/machomebrew/Bottles/"
      if tap
        tap_user, tap_repo = tap.split "/"
        path += "#{tap_repo}/"
      end
      url = "BrewTestBot,machomebrew@frs.sourceforge.net:#{path}"

      rsync_args = %w[--partial --progress --human-readable --compress]
      rsync_args += Dir["*.bottle*.tar.gz"] + [url]

      safe_system "rsync", *rsync_args

      # Bintray upload (will take over soon)
      repo = if tap
        tap.sub("/", "-") + "-bottles"
      else
        "bottles"
      end

      Dir.glob("*.bottle*.tar.gz") do |filename|
        # Skip taps for now until we're using Bintray for Homebrew/homebrew
        next if tap
        version = BottleVersion.parse(filename).to_s
        formula = bottle_filename_formula_name filename

        package_url = "https://api.bintray.com/packages/homebrew/#{repo}/#{formula}"
        unless system "curl", "--silent", "--fail", "--output", "/dev/null", package_url
          safe_system "curl", "-H", "Content-Type: application/json",
            "-d", "{'name':'#{formula}','licenses':['MIT']}", package_url
        end

        safe_system "curl", "-u#{user}:#{key}", "-T", filename,
          "#{package_url}/#{version}/#{filename}"
      end

      safe_system "git", "tag", "--force", tag
      safe_system "git", "push", "--force", remote, "refs/tags/#{tag}"
      return
    end

    tests = []
    any_errors = false
    if ARGV.named.empty?
      # With no arguments just build the most recent commit.
      test = Test.new('HEAD', tap)
      any_errors = !test.run
      tests << test
    else
      ARGV.named.each do |argument|
        test_error = false
        begin
          test = Test.new(argument, tap)
        rescue ArgumentError => e
          test_error = true
          ofail e.message
        else
          test_error = !test.run
          tests << test
        end
        any_errors ||= test_error
      end
    end

    if ARGV.include? "--junit"
      xml_document = REXML::Document.new
      xml_document << REXML::XMLDecl.new
      testsuites = xml_document.add_element "testsuites"

      tests.each do |test|
        testsuite = testsuites.add_element "testsuite"
        testsuite.add_attribute "name", "brew-test-bot.#{MacOS.cat}"
        testsuite.add_attribute "tests", test.steps.count

        test.steps.each do |step|
          testcase = testsuite.add_element "testcase"
          testcase.add_attribute "name", step.command_short
          testcase.add_attribute "status", step.status
          testcase.add_attribute "time", step.time

          if step.has_output?
            # Remove invalid XML CData characters from step output.
            output = step.output.delete("\000\a\b\e\f")

            if output.bytesize > BYTES_IN_1_MEGABYTE
              output = "truncated output to 1MB:\n" \
                + output.slice(-BYTES_IN_1_MEGABYTE, BYTES_IN_1_MEGABYTE)
            end

            cdata = REXML::CData.new output

            if step.passed?
              elem = testcase.add_element "system-out"
            else
              elem = testcase.add_element "failure"
              elem.add_attribute "message", "#{step.status}: #{step.command.join(" ")}"
            end

            elem << cdata
          end
        end
      end

      open("brew-test-bot.xml", "w") do |xml_file|
        pretty_print_indent = 2
        xml_document.write(xml_file, pretty_print_indent)
      end
    end

    if ARGV.include? "--email"
      failed_steps = []
      tests.each do |test|
        test.steps.each do |step|
          next if step.passed?
          failed_steps << step.command_short
        end
      end

      if failed_steps.empty?
        email_subject = ''
      else
        email_subject = "#{MacOS.version}: #{failed_steps.join ', '}."
      end

      File.open EMAIL_SUBJECT_FILE, 'w' do |file|
        file.write email_subject
      end
    end

    safe_system "rm -rf #{HOMEBREW_CACHE}/*" if ARGV.include? "--clean-cache"

    Homebrew.failed = any_errors
  end
end
