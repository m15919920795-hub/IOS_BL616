#!/usr/bin/env python3
"""Deterministically generate the native Objective-C app and hosted XCTest project."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OBJECTS = {}


class Ref(str):
    pass


def ident(name):
    return Ref(hashlib.sha1(name.encode()).hexdigest()[:24].upper())


def add(object_key, isa, **fields):
    key = ident(object_key)
    OBJECTS[key] = dict(isa=isa, **fields)
    return key


def quote(value):
    if isinstance(value, Ref):
        return value
    if isinstance(value, dict):
        return "{\n" + "\n".join(f"{quote(k)} = {quote(v)};" for k, v in value.items()) + "\n}"
    if isinstance(value, list):
        return "(" + ", ".join(quote(v) for v in value) + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def config_list(name, common, target):
    refs = []
    for mode in ("Debug", "Release"):
        settings = dict(common)
        settings.update(target)
        if name == "project":
            settings.update(GCC_OPTIMIZATION_LEVEL="0" if mode == "Debug" else "s",
                            DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym",
                            ENABLE_TESTABILITY="YES" if mode == "Debug" else "NO")
        refs.append(add(name + mode, "XCBuildConfiguration", buildSettings=settings, name=mode))
    return add(name + "configs", "XCConfigurationList", buildConfigurations=refs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def build():
    OBJECTS.clear()
    app_sources, test_sources = [], []
    kinds = {".m": "sourcecode.c.objc", ".c": "sourcecode.c.c", ".h": "sourcecode.c.h", ".plist": "text.plist.xml"}

    def group(directory):
        children = []
        for path in sorted((ROOT / directory).iterdir()):
            relative = path.relative_to(ROOT)
            if path.is_dir():
                children.append(group(relative))
            else:
                ref = add(str(relative), "PBXFileReference", lastKnownFileType=kinds[path.suffix],
                          path=path.name, sourceTree="<group>")
                children.append(ref)
                if path.suffix in (".m", ".c"):
                    build_ref = add(str(relative) + "build", "PBXBuildFile", fileRef=ref)
                    (test_sources if directory.parts[0] == "BL616CameraTests" else app_sources).append(build_ref)
        return add(str(directory) + "group", "PBXGroup", children=children, path=directory.name, sourceTree="<group>")

    app_group = group(Path("BL616Camera"))
    test_group = group(Path("BL616CameraTests"))
    app_product = add("app_product", "PBXFileReference", explicitFileType="wrapper.application",
                      includeInIndex=0, path="BL616Camera.app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = add("test_product", "PBXFileReference", explicitFileType="wrapper.cfbundle",
                       includeInIndex=0, path="BL616CameraTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("products", "PBXGroup", children=[app_product, test_product], name="Products", sourceTree="<group>")
    main_group = add("main_group", "PBXGroup", children=[app_group, test_group, products], sourceTree="<group>")
    package = add("cocoa_package", "XCRemoteSwiftPackageReference",
                  repositoryURL="https://github.com/robbiehanson/CocoaAsyncSocket.git",
                  requirement=dict(kind="exactVersion", version="7.6.5"))
    cocoa_product = add("cocoa_product", "XCSwiftPackageProductDependency", package=package, productName="CocoaAsyncSocket")
    app_frameworks = []
    for name in ("UIKit", "ImageIO"):
        ref = add(name, "PBXFileReference", lastKnownFileType="wrapper.framework",
                  path=f"System/Library/Frameworks/{name}.framework", sourceTree="SDKROOT")
        app_frameworks.append(add(name + "build", "PBXBuildFile", fileRef=ref))
    app_frameworks.append(add("app_cocoa", "PBXBuildFile", productRef=cocoa_product))
    test_frameworks = [add("test_cocoa", "PBXBuildFile", productRef=cocoa_product)]
    phases = {}
    for target, sources, frameworks in (("app", app_sources, app_frameworks), ("test", test_sources, test_frameworks)):
        phases[target] = [add(target + "sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
                             files=sources, runOnlyForDeploymentPostprocessing=0),
                          add(target + "frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                             files=frameworks, runOnlyForDeploymentPostprocessing=0),
                          add(target + "resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                             files=[], runOnlyForDeploymentPostprocessing=0)]
    project_configs = config_list("project", dict(
        CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES", GCC_C_LANGUAGE_STANDARD="c11",
        IPHONEOS_DEPLOYMENT_TARGET="15.0", SDKROOT="iphoneos", GCC_WARN_INHIBIT_ALL_WARNINGS="NO",
        CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF="YES", GCC_WARN_UNUSED_VARIABLE="YES"), {})
    common = dict(CODE_SIGN_STYLE="Automatic", TARGETED_DEVICE_FAMILY="1,2",
                  HEADER_SEARCH_PATHS=["$(inherited)", "$(SRCROOT)/BL616Camera/App", "$(SRCROOT)/BL616Camera/Core",
                                       "$(SRCROOT)/BL616Camera/Network", "$(SRCROOT)/BL616Camera/UI", "$(SRCROOT)/BL616Camera/Video"])
    app_configs = config_list("app", common, dict(
        INFOPLIST_FILE="BL616Camera/Resources/Info.plist", GENERATE_INFOPLIST_FILE="NO",
        PRODUCT_BUNDLE_IDENTIFIER="com.guanxukeji.BL616Camera", PRODUCT_NAME="$(TARGET_NAME)",
        CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="0.1.0"))
    test_configs = config_list("test", common, dict(
        GENERATE_INFOPLIST_FILE="YES", PRODUCT_BUNDLE_IDENTIFIER="com.guanxukeji.BL616CameraTests",
        PRODUCT_NAME="$(TARGET_NAME)", TEST_HOST="$(BUILT_PRODUCTS_DIR)/BL616Camera.app/BL616Camera",
        BUNDLE_LOADER="$(TEST_HOST)", FRAMEWORK_SEARCH_PATHS=["$(inherited)", "$(PLATFORM_DIR)/Developer/Library/Frameworks"]))
    proxy = add("test_proxy", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType=1,
                remoteGlobalIDString=ident("app"), remoteInfo="BL616Camera")
    dependency = add("test_dependency", "PBXTargetDependency", target=ident("app"), targetProxy=proxy)
    app = add("app", "PBXNativeTarget", buildConfigurationList=app_configs, buildPhases=phases["app"],
              buildRules=[], dependencies=[], name="BL616Camera", packageProductDependencies=[cocoa_product],
              productName="BL616Camera", productReference=app_product, productType="com.apple.product-type.application")
    tests = add("test", "PBXNativeTarget", buildConfigurationList=test_configs, buildPhases=phases["test"],
                buildRules=[], dependencies=[dependency], name="BL616CameraTests", packageProductDependencies=[cocoa_product],
                productName="BL616CameraTests", productReference=test_product, productType="com.apple.product-type.bundle.unit-test")
    project = add("project", "PBXProject", attributes=dict(LastUpgradeCheck="1500",
        TargetAttributes={app: dict(CreatedOnToolsVersion="15.0"), tests: dict(CreatedOnToolsVersion="15.0", TestTargetID=app)}),
        buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="zh_CN",
        hasScannedForEncodings=0, knownRegions=["zh_CN", "en", "Base"], mainGroup=main_group,
        productRefGroup=products, projectDirPath="", projectRoot="", packageReferences=[package], targets=[app, tests])
    document = dict(archiveVersion=1, classes={}, objectVersion=56, objects=OBJECTS, rootObject=project)
    text = "// !$*UTF8*$!\n" + quote(document) + "\n"
    buildable = lambda target, name, ext: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:BL616Camera.xcodeproj"/>'
    app_xml, test_xml = buildable(app,"BL616Camera","app"), buildable(tests,"BL616CameraTests","xctest")
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_xml}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <MacroExpansion>{app_xml}</MacroExpansion><Testables><TestableReference skipped="NO">{test_xml}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">{app_xml}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_xml}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    return {"BL616Camera.xcodeproj/project.pbxproj": text,
            "BL616Camera.xcodeproj/xcshareddata/xcschemes/BL616Camera.xcscheme": scheme}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    for name, content in build().items():
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"Regenerate project: python3 tools/generate_project.py ({name})")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    print("Xcode project is up to date")
