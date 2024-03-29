lib = File.expand_path('../lib/', __FILE__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)
require 'gcra/version'

Gem::Specification.new do |spec|
  spec.name          = 'gcra'
  spec.version       = GCRA::VERSION
  spec.authors       = ['Michael Frister', 'Tobias Schoknecht']
  spec.email         = ['tobias.schoknecht@viafintech.com']
  spec.description   = 'GCRA implementation for rate limiting'
  spec.summary       = 'Ruby implementation of a generic cell rate algorithm (GCRA), ported from ' \
                       'the Go implementation throttled.'
  spec.homepage      = 'https://github.com/viafintech/gcra-ruby'
  spec.license       = 'MIT'

  spec.files         = Dir['lib/**/*.rb']
  spec.test_files    = spec.files.grep(%r{^spec/})
  spec.require_paths = ['lib']

  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'redis', '~> 5.0.5'
end
