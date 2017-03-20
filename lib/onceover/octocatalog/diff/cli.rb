class Onceover
  class CLI
    class Run
      class Diff
        def self.command
          @cmd ||= Cri::Command.define do
            name 'diff'
            usage 'diff'
            summary "Diff two versions of the controlrepo's compiled catalogs"
            description <<-DESCRIPTION
This uses octocatalog-diff to run diffs on all things in the test matrix
instead of actually testing them. Requires two branches, tags or
revisions to compare between.
            DESCRIPTION

            option :f,  :from, 'branch to compare from', argument: :required
            option :t,  :to,   'branch to compare to', argument: :required

            run do |opts, args, cmd|
              require 'facter'
              require 'colored'

              #TODO: Allow for custom arguments
              repo        = Onceover::Controlrepo.new(opts)
              test_config = Onceover::TestConfig.new(repo.onceover_yaml, opts)
              num_threads = (Facter.value('processors')['count'] / 2)
              tests = test_config.run_filters(Onceover::Test.deduplicate(test_config.spec_tests))

              @queue = tests.inject(Queue.new, :push)
              @results = []

              @threads = Array.new(num_threads) do
                Thread.new do
                  r10k_cache_dir = Dir.mktmpdir('r10k_cache')
                  r10k_config = {
                    'cachedir' => r10k_cache_dir,
                  }
                  logger.debug "Creating r10k cache for thread at #{r10k_cache_dir}"
                  File.write("#{r10k_cache_dir}/r10k.yaml",r10k_config.to_yaml)

                  until @queue.empty?
                    test = @queue.shift

                    logger.info "Preparing environment for #{test.classes[0].name} on #{test.nodes[0].name}"
                    logger.debug "Creating temp directory"
                    tempdir = Dir.mktmpdir(test.to_s)
                    logger.debug "Temp directory created at #{tempdir}"

                    logger.debug "Copying controlrepo to #{tempdir}"
                    FileUtils.copy_entry(repo.root,tempdir)

                    # Copy all of the factsets over in reverse order so that
                    # local ones override vendored ones
                    logger.debug "Deploying vendored factsets"
                    written = []
                    repo.facts_files.each do |file|
                      FileUtils.cp(file,"#{tempdir}/spec/factsets/") unless written.any? do |name|
                        name.eql? File.basename(file)
                      end
                      written << File.basename(file)
                    end

                    if File.directory?("#{r10k_cache_dir}/modules")
                      logger.debug "Copying modules from thread cache to #{tempdir}"
                      FileUtils.copy_entry("#{r10k_cache_dir}/modules","#{tempdir}/modules")
                    end

                    logger.info "Deploying Puppetfile for #{test.classes[0].name} on #{test.nodes[0].name}"
                    r10k_cmd = "r10k puppetfile install --verbose --color --puppetfile #{repo.puppetfile} --config #{r10k_cache_dir}/r10k.yaml"
                    Open3.popen3(r10k_cmd, :chdir => tempdir) do |stdin, stdout, stderr, wait_thr|
                      exit_status = wait_thr.value
                      if exit_status.exitstatus != 0
                        STDOUT.puts stdout.read
                        STDERR.puts stderr.read
                        abort "R10k encountered an error, see the logs for details"
                      end
                    end

                    # TODO: Improve the way this works so that it doesn't blat site.pp
                    logger.debug "Creating before script that overwrites site.pp"
                    class_name = test.classes[0].name
                    template_dir = File.expand_path('../../../../templates',File.dirname(__FILE__))
                    template = File.read(File.expand_path("./change_manifest.rb.erb",template_dir))
                    File.write("#{tempdir}/bootstrap_script.rb",ERB.new(template, nil, '-').result(binding))
                    FileUtils.chmod("u=rwx","#{tempdir}/bootstrap_script.rb")

                    logger.debug "Getting Puppet binary"
                    binary = `which puppet`.chomp

                    logger.debug "Running Octocatalog diff"
                    logger.info "Compiling catalogs for #{test.classes[0].name} on #{test.nodes[0].name}"

                    command_prefix = ENV['BUNDLE_GEMFILE'] ? 'bundle exec ' : ''

                    command_args = [
                      '--fact-file',
                      "#{tempdir}/spec/factsets/#{test.nodes[0].name}.json",
                      '--from',
                      opts[:from],
                      '--to',
                      opts[:to],
                      '--basedir',
                      tempdir,
                      '--puppet-binary',
                      binary,
                      '--bootstrap-script',
                      "'#{tempdir}/bootstrap_script.rb'",
                      '--hiera-config',
                      repo.hiera_config_file,
                      '--pass-env-vars',
                      ENV.keys.keep_if {|k| k =~ /^RUBY|^BUNDLE/ }.join(',')
                    ]

                    cmd = "#{command_prefix}octocatalog-diff #{command_args.join(' ')}"
                    logger.debug "Running: #{cmd}"
                    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
                      exit_status = wait_thr.value
                      @results << {
                        stdout: stdout.read,
                        stderr: stderr.read,
                        exit_status: exit_status.exitstatus,
                        test: test
                      }
                    end
                    logger.info "Storing results for #{test.classes[0].name} on #{test.nodes[0].name}"

                    logger.debug "Backing up modules to thread cache #{tempdir}"
                    FileUtils.mv("#{tempdir}/modules","#{r10k_cache_dir}/modules",:force => true)

                    logger.debug "Removing temporary build cache"
                    FileUtils.rm_r(tempdir)
                  end

                  FileUtils.rm_r(r10k_cache_dir)
                end
              end

              @threads.each(&:join)
              @results.each do |result|
                puts "#{"Test:".bold} #{result[:test].classes[0].name} on #{result[:test].nodes[0].name}"
                puts "#{"Exit:".bold} #{result[:exit_status]}"
                puts "#{"Status:".bold} #{"changes".yellow}" if result[:exit_status] == 2
                puts "#{"Status:".bold} #{"no differences".green}" if result[:exit_status] == 0
                puts "#{"Status:".bold} #{"failed".red}" if result[:exit_status] == 1
                puts "#{"Results:".bold}\n#{result[:stdout]}\n" if result[:exit_status] == 2
                puts "#{"Errors:".bold}\n#{result[:stderr]}\n" if result[:exit_status] == 1
                puts ""
              end
            end
          end
        end
      end
    end
  end
end

# Register itself
Onceover::CLI::Run.command.add_command(Onceover::CLI::Run::Diff.command)
