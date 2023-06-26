# frozen_string_literal: true

class Onceover
  class CLI
    class Run
      class Diff
        def self.command
          @cmd ||= Cri::Command.define do
            name 'diff'
            usage 'diff -f <branch> -t <branch>'
            summary "Diff two versions of the controlrepo's compiled catalogs"
            description <<~DESCRIPTION
              This uses octocatalog-diff to run diffs on all tests in the test_matrix defined in onceover.yaml.
              Requires two branches, tags or revisions to compare between.

              The `from` branch represents the current desired state. The `to` branch contains the updated desired state to be compared.

              #{'Examples:'.bold}

              1. Compare catalog between `main` and `feature_xyz`:

              #{'onceover diff -f main -t feature_xyz'.bold}

              2. Compare catalog between `development` and `main`:

              #{'onceover diff -f development -t main'.bold}
            DESCRIPTION

            flag nil, :display_source, 'Display the source class filename and line number for diffs'
            option :f,  :from, 'Branch to compare from', argument: :required
            option :t,  :to,   'Branch to compare to', argument: :required

            run do |opts, args, cmd|
              require 'facter'
              require 'colored2'

              # TODO: Allow for custom arguments
              repo        = Onceover::Controlrepo.new(opts)
              test_config = Onceover::TestConfig.new(repo.onceover_yaml, opts)
              logger.info("Compare catalogs between #{opts[:from].red} and #{opts[:to].green}")
              logger.info("Repo Path #{repo.root}")
              num_threads = (Facter.value('processors')['count'] / 2)
              logger.debug("Available thread count: #{num_threads}")
              tests = test_config.run_filters(Onceover::Test.deduplicate(test_config.spec_tests))

              @queue = tests.inject(Queue.new, :push)
              @results = []


              logger.info('Provision common temp environment')
              # Create control repo to and from
              environment_dir = Dir.mktmpdir('octo_diff_temp')
              logger.debug "Temp directory created at #{environment_dir}"
              r10k_cache_dir = Dir.mktmpdir('r10k_cache_temp')
              logger.debug "Temp directory created at #{r10k_cache_dir}"

              # From dir no longer needed
              #logger.info("Provision temp environment: #{opts[:from]}")
              # Create control repo to and from
              fromdir = "#{environment_dir}/#{opts[:from]}"
              #logger.debug "Temp directory created at #{fromdir}"

              # To dir no longer needed
              # logger.info("Provision temp environment: #{opts[:to]}")
              todir = "#{environment_dir}/#{opts[:to]}"
              # todir = Dir.mktmpdir('control_repo')
              # logger.debug "Temp directory created at #{todir}"

              # Copy no longer needed
              # logger.debug "Copying controlrepo to #{fromdir}"
              # FileUtils.copy_entry(repo.root, fromdir)
              # logger.debug "Copying controlrepo to #{todir}"
              # FileUtils.copy_entry(repo.root, todir)

              # Create r10k_cache_dir
              logger.debug 'Creating a common r10k cache'
              # Cache dir no longer needed
              r10k_config = {
                # 'cachedir' => r10k_cache_dir,
                'cachedir' => environment_dir,
                'sources' => {
                  'default' => {
                    'remote' => repo.root,
                    'basedir' => environment_dir,
                    'invalid_branches' => 'correct_and_warn'
                  },
                }
              }
              File.write("#{r10k_cache_dir}/r10k.yaml", r10k_config.to_yaml)

              # # Copy all of the factsets over in reverse order so that
              # # local ones override vendored ones
              # logger.debug 'Deploying vendored factsets'
              # deduped_factsets = repo.facts_files.reverse.inject({}) do |hash, file|
              #   hash[File.basename(file)] = file
              #   hash
              # end
              # logger.info('Copy vendored factsets to control-repos')
              # deduped_factsets.each do |basename, path|
              #   facts = JSON.load(File.read(path))
              #   # Factsets are only read from todir, see command_args (--fact-file)
              #   # File.open("#{fromdir}/spec/factsets/#{File.basename(path,'.*')}.yaml", 'w') { |f| f.write facts.to_yaml }
              #   File.open("#{todir}/spec/factsets/#{File.basename(path, '.*')}.yaml", 'w') { |f| f.write facts.to_yaml }
              # end

              # Set correct branch in bootstrap dirs
              # Not needed, pulled during r10k deploy
              # logger.debug "Check out #{opts[:from]} branch"
              # git_from = "git checkout #{opts[:from]}"
              # Open3.popen3(git_from, :chdir => fromdir) do |stdin, stdout, stderr, wait_thr|
              #   exit_status = wait_thr.value
              #   if exit_status.exitstatus != 0
              #     STDOUT.puts stdout.read
              #     STDERR.puts stderr.read
              #     abort "Git checkout branch #{opts[:from]} failed. Please verify this is a valid control-repo branch"
              #   end
              # end
              # logger.debug "Check out #{opts[:to]} branch"
              # git_to = "git checkout #{opts[:to]}"
              # Open3.popen3(git_to, :chdir => todir) do |stdin, stdout, stderr, wait_thr|
              #   exit_status = wait_thr.value
              #   if exit_status.exitstatus != 0
              #     STDOUT.puts stdout.read
              #     STDERR.puts stderr.read
              #     abort "Git checkout branch #{opts[:to]} failed. Please verify this is a valid control-repo branch"
              #   end
              # end

              # Update Puppetfile for control-branch
              # r10k seems to have issues resolving the :control_branch reference in Puppetfile.
              # Setting control_branch to actual branch as workaround.
              #frompuppetfile = "#{fromdir}/Puppetfile"
              #from_content = File.read(frompuppetfile)
              #new_content = from_content.gsub(/:control_branch/, "'#{opts[:from]}'")
              #File.open(frompuppetfile, 'w') { |file| file.puts new_content }

              #topuppetfile = "#{todir}/Puppetfile"
              #to_content = File.read(topuppetfile)
              #new_content = to_content.gsub(/:control_branch/, "'#{opts[:to]}'")
              #File.open(topuppetfile, 'w') { |file| file.puts new_content }

              # Deploy Puppetfile in from
              logger.info "Deploying Puppetfile for #{opts[:from]} branch"
              r10k_cmd = "r10k deploy environment #{opts[:from]} --modules -v debug --config #{r10k_cache_dir}/r10k.yaml"
              Open3.popen3(r10k_cmd) do |stdin, stdout, stderr, wait_thr|
              # Open3.popen3(r10k_cmd, :chdir => fromdir) do |stdin, stdout, stderr, wait_thr|
                exit_status = wait_thr.value
                if exit_status.exitstatus != 0
                  STDOUT.puts stdout.read
                  STDERR.puts stderr.read
                  abort 'R10k encountered an error, see the logs for details'
                end
              end

              # Deploy Puppetfile in to
              logger.info "Deploying Puppetfile for #{opts[:to]} branch"
              r10k_cmd = "r10k deploy environment #{opts[:to]} --modules -v debug --config #{r10k_cache_dir}/r10k.yaml"
              Open3.popen3(r10k_cmd) do |stdin, stdout, stderr, wait_thr|
              # Open3.popen3(r10k_cmd, :chdir => todir) do |stdin, stdout, stderr, wait_thr|
                exit_status = wait_thr.value
                if exit_status.exitstatus != 0
                  STDOUT.puts stdout.read
                  STDERR.puts stderr.read
                  abort 'R10k encountered an error, see the logs for details'
                end
              end

              # Move beneath deploy of environments
              # Copy all of the factsets over in reverse order so that
              # local ones override vendored ones
              logger.debug 'Deploying vendored factsets'
              deduped_factsets = repo.facts_files.reverse.inject({}) do |hash, file|
                hash[File.basename(file)] = file
                hash
              end
              logger.info('Copy vendored factsets to control-repos')
              deduped_factsets.each do |basename, path|
                facts = JSON.load(File.read(path))
                # Factsets are only read from todir, see command_args (--fact-file)
                # File.open("#{fromdir}/spec/factsets/#{File.basename(path,'.*')}.yaml", 'w') { |f| f.write facts.to_yaml }
                File.open("#{todir}/spec/factsets/#{File.basename(path, '.*')}.yaml", 'w') { |f| f.write facts.to_yaml }
              end


              @threads = Array.new(num_threads) do
                Thread.new do
                  until @queue.empty?
                    test = @queue.shift

                    logger.debug "Preparing environment for #{test.classes[0].name} on #{test.nodes[0].name}"

                    # To enable parrallel testing, each role / node pair is allocated a thread.
                    # To support multiple threads compiling catalogs using the same `to` and `from` environments
                    # we must adopt node classification strategy that will not leak between threads. Site.pp is
                    # common amongst each thread, using an `include <role_class>` declaration would leak into other
                    # threads resulting nodes applying resources from other role classes.
                    #
                    # A dedicated ENC script per role/node pair ensures classification freshness without complex logic.
                    # - ENC script: <node_name>-<role_class_name>.sh (e.g. CentOS-8.3.2011-64-role_base.sh)
                    # - The ENC script will only classify a node with a single role_class
                    # - The ENC scripts are generated automatically by the thread.
                    logger.debug "Create ENC script for #{test.classes[0].name} on #{test.nodes[0].name}"
                    class_name = test.classes[0].name
                    control_repos = [fromdir, todir]
                    safe_class = class_name.gsub(/::/, '_')

                    # Create an ENC script for the current thread's target node and role class
                    # This ensures this thread will only apply this role class.
                    control_repos.each do |file_name|
                      tempfile = File.open("#{file_name}/scripts/#{test.nodes[0].name}-#{safe_class}.sh", 'w')
                      tempfile.puts "echo '---\nclasses:\n  #{class_name}:'"
                      tempfile.close
                      File.chmod(0744, "#{file_name}/scripts/#{test.nodes[0].name}-#{safe_class}.sh")
                    end

                    logger.debug 'Getting Puppet binary'
                    binary = `which puppet`.chomp

                    logger.debug 'Running Octocatalog diff'
                    logger.info "Compiling catalogs for #{test.classes[0].name} on #{test.nodes[0].name}"

                    command_prefix = ENV['BUNDLE_GEMFILE'] ? 'bundle exec ' : ''
                    bootstrap_env = "--bootstrap-environment GEM_HOME=#{ENV['GEM_HOME']}" if ENV['GEM_HOME']
                    # Whether the output should show the source file and fileline of the update.
                    display_source = opts[:display_source] ? '--display-source' : '--no-display-source'

                    command_args = [
                      '--fact-file',
                      "#{todir}/spec/factsets/#{test.nodes[0].name}.yaml",
                      '--bootstrapped-from-dir',
                      fromdir,
                      '--bootstrapped-to-dir',
                      todir,
                      '--puppet-binary',
                      binary,
                      '--hiera-config',
                      repo.hiera_config_file,
                      '--pass-env-vars',
                      ENV.keys.keep_if { |k| k =~ /^RUBY|^BUNDLE|^PUPPET/ }.join(','),
                      bootstrap_env,
                      display_source,
                      '--enc',
                      "#{todir}/scripts/#{test.nodes[0].name}-#{safe_class}.sh",
                      '-n',
                      test.nodes[0].name
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
                    logger.debug "Storing results for #{test.classes[0].name} on #{test.nodes[0].name}"
                  end
                end
              end

              @threads.each(&:join)
              logger.info("#{'Test Results:'.bold} #{"#{opts[:from]} (-)".red} vs #{"#{opts[:to]} (+)".green}")
              logger.debug("Results Explained:")
              logger.debug("#{'(+)'.green} resource added or modified in `to`")
              logger.debug("#{'(-)'.red} resource removed or previous content in `from`")
              @results.each do |result|
                puts "#{'Test:'.bold} #{result[:test].classes[0].name} on #{result[:test].nodes[0].name}"
                puts "#{'Exit:'.bold} #{result[:exit_status]}"
                puts "#{'Status:'.bold} #{'changes'.yellow}" if result[:exit_status] == 2
                puts "#{'Status:'.bold} #{'no differences'.green}" if result[:exit_status] == 0
                puts "#{'Status:'.bold} #{'failed'.red}" if result[:exit_status] == 1
                puts "#{'Results:'.bold}\n#{result[:stdout]}\n" if result[:exit_status] == 2
                puts "#{'Errors:'.bold}\n#{result[:stderr]}\n" if result[:exit_status] == 1
                puts ''
              end

              logger.info 'Cleanup temp environment directories'
              logger.debug "Processing removal: #{fromdir}"
              FileUtils.rm_r(fromdir)
              logger.debug "Processing removal: #{todir}"
              FileUtils.rm_r(todir)

              logger.info 'Removing temporary build cache'
              logger.debug "Processing removal: #{r10k_cache_dir}"
              FileUtils.rm_r(r10k_cache_dir)
              logger.debug "Processing removal: #{environment_dir}"
              FileUtils.rm_r(environment_dir)
            end
          end
        end
      end
    end
  end
end

# Register itself
Onceover::CLI::Run.command.add_command(Onceover::CLI::Run::Diff.command)
