#!/usr/bin/env ruby
# 创建一个最小的 tvOS WKWebView 工程，加载本地 web 资源
# 用法: ruby create_tvos_project.rb <project_dir> <web_dist_dir> <product_name>
require 'xcodeproj'
require 'fileutils'

project_dir = ARGV[0]
web_dist = File.expand_path(ARGV[1])
product_name = ARGV[2] || 'momo-music'
bundle_id = 'com.klzbw.momomusic'

FileUtils.mkdir_p(project_dir)
project_path = File.join(project_dir, "#{product_name}.xcodeproj")

project = Xcodeproj::Project.new(project_path)

# 主 group
main_group = project.main_group.new_group(product_name, product_name)

# 创建 target
target = project.new_target(:application, product_name, :tvos, '17.0')
target.product_type = 'com.apple.product-type.application'

# 配置 build settings
target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = bundle_id
  config.build_settings['PRODUCT_NAME'] = product_name
  config.build_settings['SDKROOT'] = 'appletvos'
  config.build_settings['SUPPORTED_PLATFORMS'] = 'appletvos'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '3'
  config.build_settings['TVOS_DEPLOYMENT_TARGET'] = '17.0'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGN_IDENTITY'] = ''
  config.build_settings['INFOPLIST_FILE'] = "#{product_name}/Info.plist"
  config.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @executable_path/Frameworks'
  config.build_settings['DEVELOPMENT_TEAM'] = ''
  config.build_settings['CLANG_ENABLE_MODULES'] = 'YES'
  config.build_settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  config.build_settings['COMBINE_HIDPI_IMAGES'] = 'NO'
end

# App 源码目录
app_dir = File.join(project_dir, product_name)
FileUtils.mkdir_p(app_dir)

# main.m - tvOS Objective-C 入口 + WKWebView（比 Swift 更易解析系统模块）
main_m = <<~OBJC
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaPlaybackRequiresUserAction = NO;
    config.allowsAirPlayForMediaPlayback = YES;

    WKWebView *webView = [[WKWebView alloc] initWithFrame:[[UIScreen mainScreen] bounds] configuration:config];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    webView.backgroundColor = [UIColor blackColor];
    webView.scrollView.bounces = NO;

    NSURL *indexURL = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html"];
    if (indexURL) {
        [webView loadFileURL:indexURL allowingReadAccessToURL:[indexURL URLByDeletingLastPathComponent]];
    }

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view = webView;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
OBJC

File.write(File.join(app_dir, 'main.m'), main_m)

# Info.plist
info_plist = <<~PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>UILaunchStoryboardName</key>
    <string></string>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
    </array>
</dict>
</plist>
PLIST

File.write(File.join(app_dir, 'Info.plist'), info_plist)

# 把 web 资源复制到 app 目录下的 public/
public_dir = File.join(app_dir, 'public')
FileUtils.mkdir_p(public_dir)
FileUtils.cp_r(File.join(web_dist, '.'), public_dir)
puts "Copied web assets: #{Dir.entries(public_dir).inspect}"

# 把源码和资源加进 target
main_file_ref = main_group.new_reference('main.m')
target.add_file_references([main_file_ref])

# 显式 link WebKit / UIKit / Foundation 系统框架
fw_phase = target.frameworks_build_phase
%w[WebKit UIKit Foundation].each do |fw|
  ref = project.frameworks_group.new_reference("#{fw}.framework")
  ref.name = fw
  ref.source_tree = 'SDKROOT'
  ref.path = "System/Library/Frameworks/#{fw}.framework"
  fw_phase.add_file_reference(ref)
end

# public/ 文件夹作为 bundle resource（阶段文件）
public_group = main_group.new_group('public', 'public')
# 把 public 下所有文件作为资源（相对 app_dir 的路径，例如 index.html, assets/xxx.js）
resource_files = Dir.glob(File.join(public_dir, '**', '*')).select { |f| File.file?(f) }
resource_refs = resource_files.map do |f|
  rel = Pathname.new(f).relative_path_from(public_dir).to_s
  public_group.new_reference(rel)
end
target.add_resources(resource_refs)
puts "Added #{resource_refs.size} resource files"

# 保存工程
project.save

# 创建 scheme
scheme_dir = File.join(project_path, 'xcshareddata/xcschemes')
FileUtils.mkdir_p(scheme_dir)
scheme_path = File.join(scheme_dir, "#{product_name}.xcscheme")

scheme_xml = <<~SCHEME
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="#{target.uuid}"
               BuildableName="#{product_name}.app"
               BlueprintName="#{product_name}"
               ReferencedContainer="container:#{File.basename(project_path)}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration="Release"
      selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle="0"
      useCustomWorkingDirectory="NO"
      ignoresPersistentStateOnLaunch="NO"
      debugDocumentVersioning="YES"
      debugServiceExtension="internal"
      allowLocationSimulation="YES">
   </LaunchAction>
</Scheme>
SCHEME

File.write(scheme_path, scheme_xml)
puts "Created tvOS project: #{project_path}"
puts "Scheme: #{product_name}"
