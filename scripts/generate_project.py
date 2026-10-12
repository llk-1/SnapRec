#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from the repository's Swift files."""
from pathlib import Path
import hashlib

ROOT = Path(__file__).resolve().parent.parent
objects = []

def ident(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def q(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

def obj(key, body):
    uid = ident(key)
    objects.append(f'\t\t{uid} = {{ {body} }};')
    return uid

def array(values):
    return '(' + ', '.join(values) + (',' if values else '') + ')'

sources = sorted(ROOT.glob('SnapRec/**/*.swift'))
tests = sorted(ROOT.glob('SnapRecTests/*.swift'))
source_refs, source_builds, test_refs, test_builds = [], [], [], []
for files, refs, builds in [(sources, source_refs, source_builds), (tests, test_refs, test_builds)]:
    for file in files:
        path = str(file.relative_to(ROOT))
        ref = obj('ref:' + path, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = "<group>";')
        refs.append(ref)
        builds.append(obj('build:' + path, f'isa = PBXBuildFile; fileRef = {ref};'))

app_product = obj('app-product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = SnapRec.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = SnapRecTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
resources = []
resource_refs = []
assets = ROOT / 'SnapRec/Resources/Assets.xcassets'
if assets.exists():
    ref = obj('assets-ref', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = SnapRec/Resources/Assets.xcassets; sourceTree = "<group>";')
    resource_refs.append(ref)
    resources.append(obj('assets-build', f'isa = PBXBuildFile; fileRef = {ref};'))
for name, filetype in [('Info.plist', 'text.plist.xml'), ('SnapRec.entitlements', 'text.plist.entitlements')]:
    resource_refs.append(obj('resource:' + name, f'isa = PBXFileReference; lastKnownFileType = {filetype}; path = {q("SnapRec/Resources/" + name)}; sourceTree = "<group>";'))
readme = obj('readme', 'isa = PBXFileReference; lastKnownFileType = net.daringfireball.markdown; path = README.md; sourceTree = "<group>";')
source_group = obj('source-group', f'isa = PBXGroup; name = SnapRec; children = {array(source_refs + resource_refs)}; sourceTree = "<group>";')
test_group = obj('test-group', f'isa = PBXGroup; name = SnapRecTests; children = {array(test_refs)}; sourceTree = "<group>";')
products_group = obj('products-group', f'isa = PBXGroup; name = Products; children = {array([app_product, test_product])}; sourceTree = "<group>";')
main_group = obj('main-group', f'isa = PBXGroup; children = {array([source_group, test_group, readme, products_group])}; sourceTree = "<group>";')
app_sources = obj('app-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(source_builds)}; runOnlyForDeploymentPostprocessing = 0;')
test_sources = obj('test-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(test_builds)}; runOnlyForDeploymentPostprocessing = 0;')
app_resources = obj('app-resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resources)}; runOnlyForDeploymentPostprocessing = 0;')
app_frameworks = obj('app-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
test_frameworks = obj('test-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')

def config_list(key, base):
    configurations = []
    for name in ['Debug', 'Release']:
        settings = dict(base)
        settings['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if name == 'Debug' else '-O'
        settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if name == 'Debug' else 'dwarf-with-dsym'
        if name == 'Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)'
        body = ' '.join(f'{k} = {q(v)};' for k, v in sorted(settings.items()))
        configurations.append(obj(key + '-' + name, f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ {body} }};'))
    return obj(key + '-list', f'isa = XCConfigurationList; buildConfigurations = {array(configurations)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

project_configs = config_list('project-config', {
    'SDKROOT': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '15.0', 'SWIFT_VERSION': '6.0',
    'SWIFT_STRICT_CONCURRENCY': 'complete', 'CLANG_ENABLE_MODULES': 'YES',
    'ARCHS': '$(ARCHS_STANDARD)', 'ONLY_ACTIVE_ARCH': 'YES',
    'ENABLE_TESTABILITY': 'YES', 'CODE_SIGN_STYLE': 'Automatic', 'CODE_SIGN_IDENTITY': '-',
})
app_settings = {
    'PRODUCT_NAME': 'SnapRec', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.snaprec.SnapRec',
    'INFOPLIST_FILE': 'SnapRec/Resources/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO',
    'CODE_SIGN_ENTITLEMENTS': 'SnapRec/Resources/SnapRec.entitlements',
    'ENABLE_HARDENED_RUNTIME': 'YES', 'ENABLE_APP_SANDBOX': 'NO',
    'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks',
}
if assets.exists(): app_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
app_configs = config_list('app-config', app_settings)
test_configs = config_list('test-config', {
    'PRODUCT_NAME': 'SnapRecTests', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.snaprec.SnapRecTests',
    'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/SnapRec.app/Contents/MacOS/SnapRec',
    'BUNDLE_LOADER': '$(TEST_HOST)', 'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks',
})
app_target = obj('app-target', f'isa = PBXNativeTarget; name = SnapRec; productName = SnapRec; productType = "com.apple.product-type.application"; productReference = {app_product}; buildConfigurationList = {app_configs}; buildPhases = {array([app_sources, app_frameworks, app_resources])}; buildRules = (); dependencies = ();')
proxy = obj('app-proxy', f'isa = PBXContainerItemProxy; containerPortal = {ident("project")}; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = SnapRec;')
dependency = obj('app-dependency', f'isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy};')
test_target = obj('test-target', f'isa = PBXNativeTarget; name = SnapRecTests; productName = SnapRecTests; productType = "com.apple.product-type.bundle.unit-test"; productReference = {test_product}; buildConfigurationList = {test_configs}; buildPhases = {array([test_sources, test_frameworks])}; buildRules = (); dependencies = {array([dependency])};')
project = obj('project', f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {app_target} = {{ CreatedOnToolsVersion = 16.0; }}; {test_target} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {app_target}; }}; }}; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = {array([app_target, test_target])};')
directory = ROOT / 'SnapRec.xcodeproj'
directory.mkdir(exist_ok=True)
(directory / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + '\n\t};\n\trootObject = ' + project + ';\n}\n')
scheme_dir = directory / 'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
def reference(uid, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:SnapRec.xcodeproj"/>'
app_ref = reference(app_target, 'SnapRec', 'SnapRec.app')
test_ref = reference(test_target, 'SnapRecTests', 'SnapRecTests.xctest')
(scheme_dir / 'SnapRec.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO">
  <MacroExpansion>{app_ref}</MacroExpansion>
  <EnvironmentVariables>
   <EnvironmentVariable key="SNAPREC_LIVE_CAPTURE_TESTS" value="$(SNAPREC_LIVE_CAPTURE_TESTS)" isEnabled="YES"/>
   <EnvironmentVariable key="SNAPREC_LIVE_OUTPUT_DIR" value="$(SRCROOT)/build/LiveCaptures" isEnabled="YES"/>
  </EnvironmentVariables>
  <Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables>
 </TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
workspace = directory / 'project.xcworkspace'
workspace.mkdir(exist_ok=True)
(workspace / 'contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0"><FileRef location="self:"/></Workspace>\n')
print(f'Generated {directory.name}: {len(sources)} app sources, {len(tests)} test sources')
