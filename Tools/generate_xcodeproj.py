#!/usr/bin/env python3
"""Regenerate the checked-in traditional Xcode project with stable object IDs.

This script uses only Python's standard library. Edit SOURCE_FILES when adding a target source.
"""
from hashlib import sha1
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_FILES = [
    'App/DashcamApp.swift', 'App/ContentView.swift', 'App/ClipExportService.swift',
    'App/DeveloperSimulation.swift', 'App/CameraCaptureService.swift',
    'App/SegmentWriter.swift', 'Core/RecordingStore.swift', 'Core/RetentionPolicy.c',
]
TEST_FILES = ['Tests/RecordingStoreTests.swift', 'Tests/SegmentWriterTests.swift']
RESOURCES = ['App/PrivacyInfo.xcprivacy', 'App/Assets.xcassets']
EXTRA = ['App/Info.plist', 'App/Dashcam-Bridging-Header.h', 'Core/RetentionPolicy.h']

def oid(name):
    return sha1(('Dashcam V0.1/' + name).encode()).hexdigest().upper()[:24]

def ref(name, comment=None):
    return f'{oid(name)} /* {comment or name.split("/")[-1]} */'

def block(name, kind, body):
    return f'\t\t{ref(name)} = {{isa = {kind}; {body}; }};\n'

def array(xs):
    return '( ' + ', '.join(xs) + ', )' if xs else '( )'

files = SOURCE_FILES + TEST_FILES + RESOURCES + EXTRA
objects = ''
for path in files:
    ext = Path(path).suffix
    filetype = {'.swift': 'sourcecode.swift', '.c': 'sourcecode.c.c', '.h': 'sourcecode.c.h',
                '.plist': 'text.plist.xml', '.xcprivacy': 'text.xml',
                '.xcassets': 'folder.assetcatalog' }[ext]
    objects += block('file/' + path, 'PBXFileReference',
                     f'lastKnownFileType = {filetype}; path = {Path(path).name}; sourceTree = "<group>"')
for path in SOURCE_FILES + TEST_FILES + RESOURCES:
    objects += block('build/' + path, 'PBXBuildFile', f'fileRef = {ref("file/" + path)}')
for group in ('App', 'Core', 'Tests'):
    entries = [ref('file/' + p) for p in files if p.startswith(group + '/')]
    objects += block('group/' + group, 'PBXGroup',
                     f'children = {array(entries)}; path = {group}; sourceTree = "<group>"')
objects += block('group/main', 'PBXGroup',
                 f'children = {array([ref("group/" + p) for p in ("App", "Core", "Tests")] + [ref("product/app"), ref("product/tests")])}; sourceTree = "<group>"')
for name, kind, path in [('app', 'wrapper.application', 'Dashcam.app'),
                         ('tests', 'wrapper.cfbundle', 'DashcamTests.xctest')]:
    objects += block('product/' + name, 'PBXFileReference',
                     f'explicitFileType = {kind}; includeInIndex = 0; path = {path}; sourceTree = BUILT_PRODUCTS_DIR')
for phase, paths in [('app-sources', SOURCE_FILES), ('test-sources', TEST_FILES)]:
    objects += block('phase/' + phase, 'PBXSourcesBuildPhase',
                     f'buildActionMask = 2147483647; files = {array([ref("build/" + p) for p in paths])}; runOnlyForDeploymentPostprocessing = 0')
objects += block('phase/app-resources', 'PBXResourcesBuildPhase',
                 f'buildActionMask = 2147483647; files = {array([ref("build/" + p) for p in RESOURCES])}; runOnlyForDeploymentPostprocessing = 0')
objects += block('dependency/tests-app', 'PBXTargetDependency',
                 f'target = {ref("target/app")}; targetProxy = {ref("proxy/tests-app")}')
objects += block('proxy/tests-app', 'PBXContainerItemProxy',
                 f'containerPortal = {ref("project")}; proxyType = 1; remoteGlobalIDString = {oid("target/app")}; remoteInfo = Dashcam')
objects += block('target/app', 'PBXNativeTarget',
                 f'buildConfigurationList = {ref("configlist/app")}; buildPhases = {array([ref("phase/app-sources"), ref("phase/app-resources")])}; '
                 f'buildRules = ( ); dependencies = ( ); name = Dashcam; productName = Dashcam; productReference = {ref("product/app")}; productType = "com.apple.product-type.application"')
objects += block('target/tests', 'PBXNativeTarget',
                 f'buildConfigurationList = {ref("configlist/tests")}; buildPhases = {array([ref("phase/test-sources")])}; '
                 f'buildRules = ( ); dependencies = {array([ref("dependency/tests-app")])}; name = DashcamTests; productName = DashcamTests; '
                 f'productReference = {ref("product/tests")}; productType = "com.apple.product-type.bundle.unit-test"')
objects += block('project', 'PBXProject',
                 f'attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ '
                 f'{oid("target/app")} = {{ CreatedOnToolsVersion = 16.0; }}; '
                 f'{oid("target/tests")} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {oid("target/app")}; }}; }}; }}; '
                 f'buildConfigurationList = {ref("configlist/project")}; compatibilityVersion = "Xcode 14.0"; '
                 f'developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); '
                 f'mainGroup = {ref("group/main")}; productRefGroup = {ref("group/main")}; '
                 f'projectDirPath = ""; projectRoot = ""; targets = {array([ref("target/app"), ref("target/tests")])}')

project_common = {
    'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CLANG_ENABLE_MODULES': 'YES',
    'CLANG_ENABLE_OBJC_ARC': 'YES', 'CLANG_WARN_DOCUMENTATION_COMMENTS': 'YES',
    'GCC_C_LANGUAGE_STANDARD': 'gnu11', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0',
    'SDKROOT': 'iphoneos', 'SWIFT_VERSION': '5.0',
    'TARGETED_DEVICE_FAMILY': '1',
}
app_common = {
    'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon',
    'CLANG_ENABLE_MODULES': 'YES', 'CODE_SIGN_STYLE': 'Automatic',
    'CURRENT_PROJECT_VERSION': '1', 'GENERATE_INFOPLIST_FILE': 'NO',
    'INFOPLIST_FILE': 'App/Info.plist',
    'MARKETING_VERSION': '0.1.0', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.normiecore.dashcam.dev',
    'PRODUCT_NAME': '"$(TARGET_NAME)"',
    'SWIFT_OBJC_BRIDGING_HEADER': 'App/Dashcam-Bridging-Header.h',
    'HEADER_SEARCH_PATHS': '( "$(PROJECT_DIR)/Core", )',
    'SWIFT_EMIT_LOC_STRINGS': 'YES',
    'SUPPORTED_PLATFORMS': '"iphoneos iphonesimulator"',
}
test_common = {
    'BUNDLE_LOADER': '"$(TEST_HOST)"', 'CODE_SIGN_STYLE': 'Automatic',
    'GENERATE_INFOPLIST_FILE': 'YES', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.normiecore.dashcam.dev.tests',
    'PRODUCT_NAME': '"$(TARGET_NAME)"', 'SWIFT_VERSION': '5.0',
    'TEST_HOST': '"$(BUILT_PRODUCTS_DIR)/Dashcam.app/Dashcam"',
    'TEST_TARGET_NAME': 'Dashcam',
}
def settings(d):
    return ' '.join(f'{k} = {v};' for k, v in sorted(d.items()))
for target, common in [('project', project_common), ('app', app_common), ('tests', test_common)]:
    for mode in ('Debug', 'Release'):
        conf = dict(common)
        if target == 'project':
            conf.update({'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym' if mode == 'Release' else 'dwarf',
                         'GCC_OPTIMIZATION_LEVEL': '0' if mode == 'Debug' else 's',
                         'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG' if mode == 'Debug' else '""',
                         'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if mode == 'Debug' else '-O',
                         'ENABLE_TESTABILITY': 'YES' if mode == 'Debug' else 'NO'})
        objects += block(f'config/{target}/{mode}', 'XCBuildConfiguration',
                         f'buildSettings = {{ {settings(conf)} }}; name = {mode}')
    objects += block('configlist/' + target, 'XCConfigurationList',
                     f'buildConfigurations = {array([ref(f"config/{target}/{mode}") for mode in ("Debug", "Release")])}; '
                     'defaultConfigurationIsVisible = 0; defaultConfigurationName = Release')
output = '// !$*UTF8*$!\n{\n archiveVersion = 1; classes = { }; objectVersion = 56;\n objects = {\n' + objects + '\t};\n' + f' rootObject = {ref("project")};\n' + '}\n'
(ROOT / 'Dashcam.xcodeproj/project.pbxproj').write_text(output)
