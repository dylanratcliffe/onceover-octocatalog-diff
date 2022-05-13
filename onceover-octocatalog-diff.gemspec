# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'onceover/octocatalog/diff/version'

Gem::Specification.new do |spec|
  spec.name          = "onceover-octocatalog-diff"
  spec.version       = Onceover::Octocatalog::Diff::VERSION
  spec.authors       = ["Dylan Ratcliffe"]
  spec.email         = ["dylan.ratcliffe@puppet.com"]

  spec.summary       = "Adds octocatalog-diff functionality to onceover"
  spec.description   = "Allows Onceover users to use their existing factsets to check what affect given changes will have on a role's compiled catalog"
  spec.homepage      = "https://github.com/dylanratcliffe/onceover-octocatalog-diff"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", ">= 2.2.10"
  spec.add_development_dependency "rake", ">= 12.3.3"
  spec.add_runtime_dependency 'octocatalog-diff', '~> 2.1'
  spec.add_runtime_dependency 'onceover', '>= 3.20.0'
end
