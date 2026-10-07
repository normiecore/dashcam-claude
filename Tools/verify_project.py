#!/usr/bin/env python3
"""Static repository checks; a Mac/Xcode compile remains mandatory."""
import hashlib
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
errors = []


def parse_openstep(source):
    """Parse the OpenStep plist subset written by generate_xcodeproj.py.

    Assignments must end with a semicolon, including the last entry in a dict.
    Whitespace and C-style comments are ignored. Quoted and bare scalars are kept
    as strings because PBX IDs, booleans, and build setting values are strings.
    """
    tokens = []
    index = 0
    while index < len(source):
        char = source[index]
        if char.isspace():
            index += 1
        elif source.startswith('//', index):
            end = source.find('\n', index + 2)
            index = len(source) if end < 0 else end + 1
        elif source.startswith('/*', index):
            end = source.find('*/', index + 2)
            if end < 0:
                raise ValueError('unterminated comment')
            index = end + 2
        elif char in '{}()=;,':
            tokens.append(char)
            index += 1
        elif char == '"':
            start = index
            index += 1
            value = ''
            while index < len(source) and source[index] != '"':
                if source[index] == '\\':
                    index += 1
                    if index >= len(source):
                        raise ValueError('unterminated quoted scalar')
                value += source[index]
                index += 1
            if index >= len(source):
                raise ValueError('unterminated quoted scalar')
            tokens.append(value)
            index += 1
        else:
            start = index
            while index < len(source) and not source[index].isspace() and source[index] not in '{}()=;,"':
                if source.startswith('//', index) or source.startswith('/*', index):
                    break
                index += 1
            if index == start:
                raise ValueError(f'invalid character at offset {index}')
            tokens.append(source[start:index])

    cursor = 0
    def consume(expected=None):
        nonlocal cursor
        if cursor >= len(tokens):
            raise ValueError(f'unexpected end, expected {expected or "value"}')
        token = tokens[cursor]
        if expected is not None and token != expected:
            raise ValueError(f'expected {expected!r} at token {cursor}, got {token!r}')
        cursor += 1
        return token

    def value():
        if cursor >= len(tokens):
            raise ValueError('expected value')
        if tokens[cursor] == '{':
            consume('{')
            result = {}
            while cursor < len(tokens) and tokens[cursor] != '}':
                key = consume()
                if key in ('{', '}', '(', ')', '=', ';', ','):
                    raise ValueError(f'expected dictionary key, got {key!r}')
                consume('=')
                if key in result:
                    raise ValueError(f'duplicate dictionary key {key}')
                result[key] = value()
                consume(';')
            consume('}')
            return result
        if tokens[cursor] == '(':
            consume('(')
            result = []
            while cursor < len(tokens) and tokens[cursor] != ')':
                result.append(value())
                if cursor < len(tokens) and tokens[cursor] == ',':
                    consume(',')
                elif cursor < len(tokens) and tokens[cursor] != ')':
                    raise ValueError('expected array comma or closing parenthesis')
            consume(')')
            return result
        scalar = consume()
        if scalar in ('{', '}', '(', ')', '=', ';', ','):
            raise ValueError(f'expected scalar, got {scalar!r}')
        return scalar

    parsed = value()
    if cursor != len(tokens):
        raise ValueError('trailing tokens after root dictionary')
    if not isinstance(parsed, dict):
        raise ValueError('root is not a dictionary')
    return parsed

def check(condition, message):
    if not condition:
        errors.append(message)

pbx = (root / 'Dashcam.xcodeproj/project.pbxproj').read_text()
try:
    graph = parse_openstep(pbx)
except ValueError as exc:
    print(f'ERROR: invalid PBX project grammar: {exc}', file=sys.stderr)
    sys.exit(1)
objects = graph.get('objects', {})
script = (root / 'Tools/generate_xcodeproj.py').read_text()
scheme = ET.parse(root / 'Dashcam.xcodeproj/xcshareddata/xcschemes/Dashcam.xcscheme')
info = plistlib.loads((root / 'App/Info.plist').read_bytes())
privacy = plistlib.loads((root / 'App/PrivacyInfo.xcprivacy').read_bytes())

def oid(name):
    return hashlib.sha1(('Dashcam V0.1/' + name).encode()).hexdigest().upper()[:24]

source_files = re.findall(r"'((?:App|Core|Tests)/[^']+\.(?:swift|c))'", script)
# The list also appears in test/constants sections; discard duplicates.
source_files = list(dict.fromkeys(source_files))
for name in source_files:
    check((root / name).is_file(), f'Missing target source: {name}')
    file_ref = objects.get(oid('file/' + name), {})
    build_ref = objects.get(oid('build/' + name), {})
    check(file_ref.get('isa') == 'PBXFileReference' and file_ref.get('path') == Path(name).name,
          f'Missing project file reference: {name}')
    check(build_ref.get('isa') == 'PBXBuildFile' and build_ref.get('fileRef') == oid('file/' + name),
          f'Missing build phase entry: {name}')
    phase = 'test-sources' if name.startswith('Tests/') else 'app-sources'
    check(oid('build/' + name) in objects.get(oid('phase/' + phase), {}).get('files', []),
          f'Source absent from {phase}: {name}')
    group = name.split('/')[0]
    check(oid('file/' + name) in objects.get(oid('group/' + group), {}).get('children', []),
          f'Source absent from {group} group: {name}')
for name in ('App/PrivacyInfo.xcprivacy',):
    check(oid('build/' + name) in objects.get(oid('phase/app-resources'), {}).get('files', []),
          f'Resource absent from app target: {name}')
check(graph.get('rootObject') == oid('project'), 'Invalid root object')
project = objects.get(oid('project'), {})
check(project.get('isa') == 'PBXProject', 'Root is not a PBXProject')
check(project.get('targets') == [oid('target/app'), oid('target/tests')], 'Project target references incorrect')
check(project.get('mainGroup') == oid('group/main'), 'Main group reference incorrect')
check(objects.get(oid('target/app'), {}).get('buildPhases') ==
      [oid('phase/app-sources'), oid('phase/app-resources')], 'App build phases incorrect')
check(objects.get(oid('target/tests'), {}).get('buildPhases') ==
      [oid('phase/test-sources')], 'Tests build phase incorrect')
check(objects.get(oid('target/tests'), {}).get('dependencies') ==
      [oid('dependency/tests-app')], 'App-hosted test target dependency missing')
check(objects.get(oid('dependency/tests-app'), {}).get('target') == oid('target/app'),
      'Test dependency points to wrong app')
for object_id, object_body in objects.items():
    if object_body.get('isa') == 'PBXBuildFile':
        check(object_body.get('fileRef') in objects, f'Unresolved fileRef in {object_id}')
    if object_body.get('isa') == 'PBXGroup':
        check(all(item in objects for item in object_body.get('children', [])),
              f'Unresolved group child in {object_id}')
    if object_body.get('isa') in ('PBXSourcesBuildPhase', 'PBXResourcesBuildPhase'):
        check(all(item in objects for item in object_body.get('files', [])),
              f'Unresolved build file in {object_id}')
    if object_body.get('isa') in ('PBXNativeTarget', 'PBXProject'):
        check(object_body.get('buildConfigurationList') in objects,
              f'Unresolved configuration list in {object_id}')
    if object_body.get('isa') == 'XCConfigurationList':
        check(all(item in objects for item in object_body.get('buildConfigurations', [])),
              f'Unresolved build configuration in {object_id}')
check('DEVELOPMENT_TEAM =' not in pbx, 'Project must not fix an Apple development team')
check('com.normiecore.dashcam.dev' in pbx, 'Expected development bundle identifier')
check('IPHONEOS_DEPLOYMENT_TARGET = 17.0' in pbx, 'Deployment target must be iOS 17')
check('SWIFT_VERSION = 5.0' in pbx, 'Swift language mode must be 5')
check('CODE_SIGN_ENTITLEMENTS' not in pbx, 'Unexpected entitlements in project')
check('UIBackgroundModes' not in info, 'Foreground-only app must not declare background mode')
check(info.get('UISupportedInterfaceOrientations') == ['UIInterfaceOrientationLandscapeRight'],
      'App must use fixed landscape-right orientation')
for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription'):
    check(bool(info.get(key)), f'Missing {key}')
check(info.get('CFBundleShortVersionString') == '$(MARKETING_VERSION)', 'Version must derive from build settings')
reason = {item['NSPrivacyAccessedAPIType']: item['NSPrivacyAccessedAPITypeReasons']
          for item in privacy.get('NSPrivacyAccessedAPITypes', [])}
check(reason.get('NSPrivacyAccessedAPICategoryDiskSpace') == ['E174.1'], 'Disk space reason missing')
check(reason.get('NSPrivacyAccessedAPICategoryFileTimestamp') == ['C617.1'], 'Container file metadata reason missing')
check(not privacy.get('NSPrivacyTracking'), 'Unexpected tracking declaration')
check(oid('target/app') in ET.tostring(scheme.getroot(), encoding='unicode'), 'Scheme lacks app target')
check(oid('target/tests') in ET.tostring(scheme.getroot(), encoding='unicode'), 'Scheme lacks tests target')
if errors:
    print('\n'.join('ERROR: ' + item for item in errors), file=sys.stderr)
    sys.exit(1)
print(f'Project grammar and graph OK: {len(source_files)} source/test files; plist and scheme checks passed.')
print('Swift compilation still requires Xcode. Run Tools/verify-mac.sh on a Mac.')
