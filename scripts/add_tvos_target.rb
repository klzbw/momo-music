#!/usr/bin/env ruby
# 在 Capacitor 生成的 Xcode 工程里，复制 iOS App target 为 tvOS target
# 用法: ruby add_tvos_target.rb <path/to/App.xcodeproj> <target_name> <new_target_name>
require 'xcodeproj'

project_path = ARGV[0]
ios_target_name = ARGV[1] || 'App'
tvos_target_name = ARGV[2] || 'App-tvOS'

project = Xcodeproj::Project.open(project_path)
ios_target = project.targets.find { |t| t.name == ios_target_name }
abort "iOS target '#{ios_target_name}' not found" unless ios_target

# 如果已存在 tvOS target 就跳过
if project.targets.any? { |t| t.name == tvos_target_name }
  puts "tvOS target '#{tvos_target_name}' already exists, skipping"
  exit 0
end

# 复制 target
tvos_target = ios_target.dup
tvos_target.name = tvos_target_name
tvos_target.product_name = tvos_target_name
project.targets << tvos_target

# 修改 build settings
tvos_target.build_configurations.each do |config|
  config.build_settings['SDKROOT'] = 'appletvos'
  config.build_settings['SUPPORTED_PLATFORMS'] = 'appletvos'
  config.build_settings['SUPPORTED_PLATFORMS[arch=*]'] = 'appletvos'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '3'
  config.build_settings['SDK_NAME'] = 'appletvos'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['PRODUCT_NAME'] = tvos_target_name
  # tvOS 不支持的设置
  config.build_settings.delete('ENABLE_BITCODE')
  # 设置基础 SDK 版本
  config.build_settings['TVOS_DEPLOYMENT_TARGET'] = '17.0'
end

# 创建 scheme
scheme_path = project_path.gsub('.xcodeproj', ".xcshareddata/xcschemes/#{tvos_target_name}.xcscheme")
FileUtils.mkdir_p(File.dirname(scheme_path))

scheme_xml = <<~SCHEME
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "NO"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "#{tvos_target.uuid}"
               BuildableName = "#{tvos_target_name}.app"
               BlueprintName = "#{tvos_target_name}"
               ReferencedContainer = "container:#{File.basename(project_path)}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
   </LaunchAction>
</Scheme>
SCHEME

File.write(scheme_path, scheme_xml)
puts "Created scheme: #{scheme_path}"

project.save
puts "Done: added tvOS target '#{tvos_target_name}'"
