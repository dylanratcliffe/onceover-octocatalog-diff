require "onceover/octocatalog/diff/version"
require "onceover/octocatalog/diff/cli"

class Onceover
  module Octocatalog
    module Diff
      def self.create_facts_yaml(repo,output_location)
        require 'json'

        repo.facts_files.each do |facts_file|
          facts = JSON.load(File.read(facts_file))
          File.open("#{output_location}/#{File.basename(facts_file,'.*')}.yaml", 'w') {|f| f.write facts.to_yaml }
        end
      end
    end
  end
end
