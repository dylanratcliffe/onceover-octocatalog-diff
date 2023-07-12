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

            flag nil, :display_detail_add, 'Display the detailed attributes for added resources'
            flag nil, :display_source, 'Display the source class filename and line number for diffs'
            flag nil, :no_color, 'Disable color for octocatalog-diff output'
            option :f,  :from, 'Branch to compare from', argument: :required
            option :t,  :to,   'Branch to compare to', argument: :required

            run do |opts, args, cmd|
              require 'facter'
              require 'colored2'

              # TODO: Allow for custom arguments
              repo        = Onceover::Controlrepo.new(opts)
              test_config = Onceover::TestConfig.new(repo.onceover_yaml, opts)
              logger.info("Compare catalogs between #{opts[:from]} and #{opts[:to]}")
              logger.info("Repo Path #{repo.root}")
              num_threads = (Facter.value('processors')['count'] / 2)
              logger.debug("Available thread count: #{num_threads}")
              tests = test_config.run_filters(Onceover::Test.deduplicate(test_config.spec_tests))

              @queue = tests.inject(Queue.new, :push)
              @results = []    # collect octocatalog-diff output from each thread
              @git_remote = [] # collect git checkout output

              logger.info('Provision temp working directories')
              environment_dir = Dir.mktmpdir('octo_diff_temp')
              logger.debug "Temp environment directory created at #{environment_dir}"
              r10k_cache_dir = Dir.mktmpdir('r10k_cache_temp')
              logger.debug "Temp r10k cache directory created at #{r10k_cache_dir}"

              # Create control repo to and from
              logger.debug("Provision temp environment: #{opts[:from]}")
              fromdir = "#{environment_dir}/#{opts[:from]}"
              logger.debug "Temp #{opts[:from]} directory created at #{fromdir}"

              logger.debug("Provision temp environment: #{opts[:to]}")
              todir = "#{environment_dir}/#{opts[:to]}"
              logger.debug "Temp #{opts[:to]} directory created at #{todir}"

              # TODO: Confirm if there is a better way to update git /ref/heads for repo.root to discover commit for `to` and `from`
              # If either the `to` or `from` reference hasn't been checked out locally, r10k will fail to discover/deploy it.
              # A simple git checkout for the `to` and `from` branch ensures the local repo is aware of /ref/heads and r10k can use them successfully.  
               remote_cmd = "git checkout #{opts[:from]}; git checkout #{opts[:to]}" # checkout the `from` branch to ensure local repo has a reference for r10k
               Open3.popen3(remote_cmd) do |stdin, stdout, stderr, wait_thr|
                 exit_status = wait_thr.value
                 @git_remote << {
                   stdout: stdout.read,
                   stderr: stderr.read,
                   exit_status: exit_status.exitstatus,
                 }
               end

              # Create r10k_cache_dir
              logger.debug 'Creating a common r10k cache'
              r10k_config = {
                'cachedir' => r10k_cache_dir,
                'sources' => {
                  'default' => {
                    'remote' => repo.root,
                    'basedir' => environment_dir,
                    'invalid_branches' => 'correct_and_warn'
                  },
                }
              }
              File.write("#{r10k_cache_dir}/r10k.yaml", r10k_config.to_yaml)

              # Deploy environment in `from` temp environment
              logger.info "Deploying Puppetfile for #{opts[:from]} branch"
              r10k_cmd = "r10k deploy environment #{opts[:from]} --color --trace --modules --config #{r10k_cache_dir}/r10k.yaml"
              Open3.popen3(r10k_cmd) do |stdin, stdout, stderr, wait_thr|
              # Open3.popen3(r10k_cmd, :chdir => fromdir) do |stdin, stdout, stderr, wait_thr|
                exit_status = wait_thr.value
                if exit_status.exitstatus != 0
                  STDOUT.puts stdout.read
                  STDERR.puts stderr.read
                  abort 'R10k encountered an error, see the logs for details'
                end
              end

              # Deploy environment in `to` temp environment
              logger.info "Deploying Puppetfile for #{opts[:to]} branch"
              r10k_cmd = "r10k deploy environment #{opts[:to]} --color --trace --modules --config #{r10k_cache_dir}/r10k.yaml"
              Open3.popen3(r10k_cmd) do |stdin, stdout, stderr, wait_thr|
              # Open3.popen3(r10k_cmd, :chdir => todir) do |stdin, stdout, stderr, wait_thr|
                exit_status = wait_thr.value
                if exit_status.exitstatus != 0
                  STDOUT.puts stdout.read
                  STDERR.puts stderr.read
                  abort 'R10k encountered an error, see the logs for details'
                end
              end

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
                    
                    # flag: Whether the output should show the source file and fileline of the resource update.
                    display_detail_add = opts[:display_detail_add] ? '--display-detail-add' : '--no-display-detail-add'
                    display_source = opts[:display_source] ? '--display-source' : '--no-display-source'
                    color = opts[:no_color] ? '--no-color' : '--color'
                    command_args = [
                      '--fact-file',
                      "#{todir}/spec/factsets/#{test.nodes[0].name}.yaml",
                      '--bootstrapped-from-dir',
                      fromdir,
                      '--bootstrapped-to-dir',
                      todir,
                      '--puppet-binary',
                      binary,
                      color,
                      '--hiera-config',
                      repo.hiera_config_file,
                      '--pass-env-vars',
                      ENV.keys.keep_if { |k| k =~ /^RUBY|^BUNDLE|^PUPPET/ }.join(','),
                      bootstrap_env,
                      display_detail_add,
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
                        test: {class: test.classes[0].name, node: test.nodes[0].name}
                      }
                    end
                    logger.debug "Storing results for #{test.classes[0].name} on #{test.nodes[0].name}"
                  end
                end
              end

              @threads.each(&:join)
              logger.info("Test Results: #{opts[:from]} (-) vs #{opts[:to]} (+)")
              logger.debug("Results Explained:")
              logger.debug("#{'(+)'.green} resource added or modified in `to`")
              logger.debug("#{'(-)'.red} resource removed or previous content in `from`")
              # TODO: Determine method of different output formatters table, pretty
              
              @results.each do |result|
                if opts[:no_color]
                  puts "#{'Test:'} #{result[:test][:class]} on #{result[:test][:node]}"
                  puts "#{'Exit:'} #{result[:exit_status]}"
                  puts "#{'Status:'} #{'changes'}" if result[:exit_status] == 2
                  puts "#{'Status:'} #{'no differences'}" if result[:exit_status] == 0
                  puts "#{'Status:'} #{'failed'}" if result[:exit_status] == 1
                  puts "#{'Results:'}\n#{result[:stdout]}\n" if result[:exit_status] == 2
                  puts "#{'Errors:'}\n#{result[:stderr]}\n" if result[:exit_status] == 1
                  puts ''
                else
                  puts "#{'Test:'.bold} #{result[:test][:class]} on #{result[:test][:node]}"
                  puts "#{'Exit:'.bold} #{result[:exit_status]}"
                  puts "#{'Status:'.bold} #{'changes'.yellow}" if result[:exit_status] == 2
                  puts "#{'Status:'.bold} #{'no differences'.green}" if result[:exit_status] == 0
                  puts "#{'Status:'.bold} #{'failed'.red}" if result[:exit_status] == 1
                  puts "#{'Results:'.bold}\n#{result[:stdout]}\n" if result[:exit_status] == 2
                  puts "#{'Errors:'.bold}\n#{result[:stderr]}\n" if result[:exit_status] == 1
                  puts ''
                end
              end

              def print_summary_table
                # Sort does nothing presently. 
                # @results.sort_by { |result| [result[:exit_status]] }
                require 'table_print'
                states = { 0 => 'no differences', 1 => 'failed', 2 => 'changes' }

                tp.set :max_width, 200
                tp @results, 
                { node: lambda { |result| result[:test][:node]} }, 
                { class: lambda { |result| result[:test][:class]} }, 
                { status: lambda { |result| states[result[:exit_status]]} }, 
                { add: lambda { |result| result[:stdout].scan(/\+ /).length} }, 
                { remove: lambda { |result| result[:stdout].scan(/- /).length} } 
                puts ''
              end
             
              print_summary_table
              
              logger.info 'Cleanup temp environment directories'
              logger.debug "Processing removal: #{fromdir}"
              #FileUtils.rm_r(fromdir)
              logger.debug "Processing removal: #{todir}"
              #FileUtils.rm_r(todir)

              logger.info 'Removing temporary build cache'
              logger.debug "Processing removal: #{r10k_cache_dir}"
              #FileUtils.rm_r(r10k_cache_dir)
              logger.debug "Processing removal: #{environment_dir}"
              #FileUtils.rm_r(environment_dir)
            end
          end
        end
      end
    end
  end
end

# Register itself
Onceover::CLI::Run.command.add_command(Onceover::CLI::Run::Diff.command)
