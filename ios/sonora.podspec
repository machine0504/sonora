Pod::Spec.new do |s|
  s.name             = 'sonora'
  s.version          = '0.0.1'
  s.summary          = 'Low-latency native voice recorder plugin for Flutter.'
  s.description      = <<-DESC
Low-latency voice recorder (AVAudioRecorder) with realtime amplitude stream. iOS implementation.
                       DESC
  s.homepage         = 'https://github.com/machine0504/sonora'
  s.license          = { :type => 'MIT' }
  s.author           = { 'machine0504' => 'machine0504@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.swift_version    = '5.0'
  s.dependency 'Flutter'
  # CallKit 用于识别系统 / VoIP 通话，通话中禁止开录。
  s.frameworks       = 'AVFoundation', 'CallKit'
  s.platform         = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
