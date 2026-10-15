#!/usr/bin/env python3
"""Build an isolated recovery-menu fixture and run Apple's macOS UI automation."""
import argparse
import hashlib
import json
import os
import signal
import time
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

def qualification_exit(build_exit, summary, expected_count):
    if build_exit:
        return build_exit
    counts = [summary.get(key) for key in ['totalTestCount', 'passedTests', 'skippedTests', 'failedTests', 'expectedFailures']]
    if any(type(value) is not int or value < 0 for value in counts):
        return 2
    total, passed, skipped, failed, expected = counts
    if expected_count < 1 or total != expected_count or passed + skipped != total or failed or expected or summary.get('result') != 'Passed':
        return 2
    return 77 if skipped else 0


def stop_owned_ui_processes(binaries):
    expected = {str(Path(binary).resolve()) for binary in binaries}
    for requested_signal in [signal.SIGTERM, signal.SIGKILL]:
        listing = subprocess.run(['/bin/ps', '-axo', 'pid=,comm=', '-ww'], capture_output=True, text=True, check=True)
        owned = []
        for line in listing.stdout.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[1].startswith('/') and str(Path(fields[1]).resolve()) in expected:
                owned.append(int(fields[0]))
        for pid in owned:
            try:
                os.kill(pid, requested_signal)
            except ProcessLookupError:
                pass
        if owned and requested_signal == signal.SIGTERM:
            time.sleep(0.1)


def run_ui_tests(command, log, owned_binaries, timeout=240):
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    log.write(f'UI_AUTOMATION_PID={process.pid}\n')
    log.flush()
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124
    finally:
        # XCTest launches its runner and fixture through system services, outside xcodebuild's process group.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        stop_owned_ui_processes(owned_binaries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--candidate-source', type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--only-testing', help='One XCTest method for focused diagnosis')
    mode.add_argument('--check-pending-retry', choices=['changed', 'unchanged'], help='Public in-process AX tracking check; no global input or XCTest')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    products = args.derived_data.resolve() / 'Build/Products/Debug'
    run_id = hashlib.sha256(str(out).encode()).hexdigest()[:12]
    app = out / 'RecoveryMenuInteraction.app'
    contents = app / 'Contents'
    (contents / 'MacOS').mkdir(parents=True, exist_ok=True)
    shutil.copytree(products / 'Bopify.app/Contents/Resources', contents / 'Resources', dirs_exist_ok=True)
    binary = contents / 'MacOS/RecoveryMenuInteraction'
    (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': binary.name,
        'CFBundleIdentifier': 'com.leesiongchan.bopify.recovery-menu-interaction.r' + run_id, 'CFBundleName': 'RecoveryMenuInteraction',
        'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '26.0'}))
    source = args.candidate_source.resolve() if args.candidate_source else root / 'Bopify/Bopify/Views/PlaybackConnectionStatusView.swift'
    fixture = root / 'docs/superpowers/verification/RecoveryMenuInteractionApp.swift'
    tests = root / 'docs/superpowers/verification/RecoveryMenuUITests.swift'
    snapshots = {}
    for path in [source, fixture, tests, root / 'Bopify/Bopify/MenuBar/StatusPanel.swift']:
        destination = out / ('Compiled' + path.name)
        shutil.copy2(path, destination)
        snapshots[path.name] = destination
    expected_count = 1 if args.only_testing else len(re.findall(r'    func test\w+\(', snapshots[tests.name].read_text()))
    command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-default-isolation', 'MainActor',
        '-warnings-as-errors', '-target', 'arm64-apple-macosx26.0', '-module-cache-path', str(out / 'module-cache'),
        '-I', str(products), '-I', str(root / 'Packages/BopifyCore/Sources/CBopifyCore/include'),
        '-L', str(products), '-lbopify_core', '-liconv', '-lobjc']
    for framework in ['AudioToolbox', 'CoreAudio', 'IOKit', 'CoreFoundation', 'Foundation', 'SystemConfiguration', 'Security']:
        command += ['-framework', framework]
    command += [str(snapshots[source.name]), str(snapshots['StatusPanel.swift']), str(snapshots[fixture.name])]
    command += [str(products / (name + '.o')) for name in ['BopifyDomain', 'BopifyPlayback', 'CBopifyCore']]
    command += ['-o', str(binary)]
    with (out / 'fixture-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)

    if args.check_pending_retry:
        with (out / 'tracking.log').open('w') as log:
            code = run_ui_tests([str(binary), '--output', str(out), '--check-pending-retry', args.check_pending_retry], log, [binary], timeout=10)
        metadata = {'exit_code': code, 'coverage': 'local-menu-tracking-and-public-AX-selection',
            'compiled_sources': {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in snapshots.items()},
            'minimum_target': '26.0', 'global_input': False}
        (out / 'run-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
        print(f'Pending retry check exit={code}; evidence: {out}', flush=True)
        raise SystemExit(code)

    project = out / 'RecoveryMenuTests.xcodeproj'
    project.mkdir(exist_ok=True)
    # The automation target stays outside the shipping Xcode project and launches only the fake app above.
    objects = {}
    def add(key, isa, **values):
        objects[key] = dict(isa=isa, **values)
        return key
    project_id, group, products_id, target, file_id, product_id, build, sources, frameworks = [f'{n:024X}' for n in range(1, 10)]
    project_config, target_config, project_debug, target_debug = [f'{n:024X}' for n in range(10, 14)]
    add(file_id, 'PBXFileReference', lastKnownFileType='sourcecode.swift', path=str(snapshots[tests.name]), sourceTree='<absolute>')
    add(product_id, 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='RecoveryMenuTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
    add(build, 'PBXBuildFile', fileRef=file_id)
    add(sources, 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=[build], runOnlyForDeploymentPostprocessing=0)
    add(frameworks, 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    add(products_id, 'PBXGroup', children=[product_id], name='Products', sourceTree='<group>')
    add(group, 'PBXGroup', children=[file_id, products_id], sourceTree='<group>')
    add(project_debug, 'XCBuildConfiguration', name='Debug', buildSettings={'SDKROOT': 'macosx', 'MACOSX_DEPLOYMENT_TARGET': '26.0', 'SWIFT_VERSION': '6.0', 'ALWAYS_SEARCH_USER_PATHS': 'NO', 'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES', 'CODE_SIGN_IDENTITY': '-', 'CODE_SIGN_STYLE': 'Manual'})
    add(target_debug, 'XCBuildConfiguration', name='Debug', buildSettings={'PRODUCT_NAME': 'RecoveryMenuTests', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.leesiongchan.bopify.recovery-menu-tests.r' + run_id, 'GENERATE_INFOPLIST_FILE': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'complete', 'SWIFT_VERSION': '6.0', 'ENABLE_APP_SANDBOX': 'NO'})
    add(project_config, 'XCConfigurationList', buildConfigurations=[project_debug], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
    add(target_config, 'XCConfigurationList', buildConfigurations=[target_debug], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
    add(target, 'PBXNativeTarget', name='RecoveryMenuTests', productName='RecoveryMenuTests', productType='com.apple.product-type.bundle.ui-testing', productReference=product_id, buildConfigurationList=target_config, buildPhases=[sources, frameworks], buildRules=[], dependencies=[])
    add(project_id, 'PBXProject', attributes={'LastUpgradeCheck': '2700'}, buildConfigurationList=project_config, compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en'], mainGroup=group, productRefGroup=products_id, projectDirPath='', projectRoot='', targets=[target])
    (project / 'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion': '1', 'classes': {}, 'objectVersion': '56', 'objects': objects, 'rootObject': project_id}))
    scheme_dir = project / 'xcshareddata/xcschemes'
    scheme_dir.mkdir(parents=True, exist_ok=True)
    scheme = ET.Element('Scheme', LastUpgradeVersion='2700', version='1.3')
    build_action = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='NO', buildImplicitDependencies='YES')
    entry = ET.SubElement(ET.SubElement(build_action, 'BuildActionEntries'), 'BuildActionEntry', buildForTesting='YES', buildForRunning='NO', buildForProfiling='NO', buildForArchiving='NO', buildForAnalyzing='YES')
    reference = dict(BuildableIdentifier='primary', BlueprintIdentifier=target, BuildableName='RecoveryMenuTests.xctest', BlueprintName='RecoveryMenuTests', ReferencedContainer='container:RecoveryMenuTests.xcodeproj')
    ET.SubElement(entry, 'BuildableReference', **reference)
    test_action = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.PosixSpawn', shouldUseLaunchSchemeArgsEnv='NO')
    testable = ET.SubElement(ET.SubElement(test_action, 'Testables'), 'TestableReference', skipped='NO')
    ET.SubElement(testable, 'BuildableReference', **reference)
    env = ET.SubElement(test_action, 'EnvironmentVariables')
    for key, value in {'MENU_APP': str(app), 'MENU_EVIDENCE': str(out / 'cases')}.items():
        ET.SubElement(env, 'EnvironmentVariable', key=key, value=value, isEnabled='YES')
    ET.ElementTree(scheme).write(scheme_dir / 'RecoveryMenuTests.xcscheme', encoding='utf-8', xml_declaration=True)
    result_bundle = out / 'UIResults.xcresult'
    command = ['xcodebuild', 'test', '-project', str(project), '-scheme', 'RecoveryMenuTests',
        '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(out / 'DerivedData'),
        '-resultBundlePath', str(result_bundle), '-parallel-testing-enabled', 'NO']
    if args.only_testing:
        command += ['-only-testing:RecoveryMenuTests/RecoveryMenuUITests/' + args.only_testing]
    with (out / 'ui-tests.log').open('w') as log:
        code = run_ui_tests(command, log, [binary, out / 'DerivedData/Build/Products/Debug/RecoveryMenuTests-Runner.app/Contents/MacOS/RecoveryMenuTests-Runner'])
    result = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(result_bundle)], capture_output=True, text=True)
    try:
        summary = json.loads(result.stdout) if result.returncode == 0 else {}
    except json.JSONDecodeError:
        summary = {}
    (out / 'test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    qualification = qualification_exit(code, summary, expected_count)
    metadata = {'xcodebuild_exit': code, 'qualification_exit': qualification, 'expected_tests': expected_count,
        'compiled_sources': {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in snapshots.items()}, 'os': subprocess.check_output(['sw_vers'], text=True),
        'result_bundle': str(result_bundle), 'minimum_target': '26.0'}
    (out / 'run-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'UI automation exit={code}, qualification={qualification}; evidence: {out}', flush=True)
    raise SystemExit(qualification)


if __name__ == "__main__":
    main()
