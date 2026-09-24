require_relative 'ruby/lib/click_man/version'

Gem::Specification.new do |spec|
  spec.name = 'clickman'
  spec.version = ClickMan::VERSION
  spec.authors = ['LockVoid Labs']
  spec.summary = 'Product analytics for Rails at the price of a small database.'
  spec.description = 'A Rails engine that stores product events column-wise in your own database, ' \
                     'reports actives, retention and funnels, and forwards events to other tools; ' \
                     'with a Rust ingest server and Swift, Kotlin and Rust clients.'
  spec.homepage = 'https://github.com/lockvoid/clickman'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.3'

  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir[
      'ruby/{app,bin,config,lib}/**/*',
      'crates/*/{Cargo.toml,src/**/*,include/**/*}',
      'Cargo.toml',
      'Cargo.lock',
      'sql/**/*',
      'fixtures/*.json',
      'docs/*.md',
      'LICENSE',
      'README.md'
    ].select { File.file?(it) }
  end
  spec.bindir = 'ruby/bin'
  spec.executables = ['clickman-ingest']
  spec.require_paths = ['ruby/lib']

  spec.add_dependency 'activejob', '>= 8.0'
  spec.add_dependency 'activerecord', '>= 8.0'
  spec.add_dependency 'msgpack', '>= 1.7'
  spec.add_dependency 'railties', '>= 8.0'
  spec.add_dependency 'zeitwerk', '>= 2.6'
  spec.add_dependency 'zstd-ruby', '>= 1.5'
end
