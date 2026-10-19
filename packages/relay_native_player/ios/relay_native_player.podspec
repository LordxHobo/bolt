Pod::Spec.new do |s|
  s.name             = 'relay_native_player'
  s.version          = '0.0.1'
  s.summary          = "Relay's iPhone live player with picture-in-picture."
  s.homepage         = 'https://github.com/LordxHobo/relay'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Relay' => 'relay@localhost' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
