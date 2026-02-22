Pod::Spec.new do |s|
  s.name             = 'dart_monty_desktop'
  s.version          = '0.1.0'
  s.summary          = 'macOS native library for dart_monty.'
  s.homepage         = 'https://github.com/runyaga/dart-monty'
  s.license          = { :type => 'MIT' }
  s.author           = { 'runyaga' => 'runyaga@users.noreply.github.com' }
  s.source           = { :path => '.' }

  s.platform         = :osx, '10.14'
  s.osx.deployment_target = '10.14'

  s.source_files     = 'Classes/**/*'
  s.vendored_libraries = 'libdart_monty_native.dylib'

  s.dependency 'FlutterMacOS'
end
