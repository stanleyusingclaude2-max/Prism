#!/usr/bin/env python3
"""Generate the deterministic, traditional-group Prism Xcode project.

Run this again after adding Swift files or resources. No XcodeGen dependency is
required. The generator does not modify application sources or user settings.
"""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Prism.xcodeproj"
MPV_URL = "https://github.com/mpvkit/MPVKit.git"
MPV_REVISION = "98c3453e252922e3136422da3fbb2e341ed9edc8"


@dataclass(frozen=True)
class Ref:
    value: str


objects: dict[str, dict] = {}
labels: dict[str, str] = {}


def identifier(kind: str, key: str) -> str:
    return hashlib.sha1(f"playit:{kind}:{key}".encode()).hexdigest()[:24].upper()


def add(kind: str, key: str, **properties) -> Ref:
    uid = identifier(kind, key)
    if uid in objects:
        raise ValueError(f"Duplicate object identity: {kind}/{key}")
    objects[uid] = {"isa": kind, **properties}
    labels[uid] = key
    return Ref(uid)


def serialize(value, indent: int = 0) -> str:
    tabs = "\t" * indent
    if isinstance(value, Ref):
        return value.value
    if isinstance(value, dict):
        contents = "\n".join(
            f"{tabs}\t{key} = {serialize(item, indent + 1)};"
            for key, item in value.items()
        )
        return "{\n" + contents + "\n" + tabs + "}"
    if isinstance(value, (tuple, list)):
        if not value:
            return "()"
        contents = "\n".join(f"{tabs}\t{serialize(item, indent + 1)}," for item in value)
        return "(\n" + contents + "\n" + tabs + ")"
    if isinstance(value, bool):
        return "YES" if value else "NO"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def references(value):
    if isinstance(value, Ref):
        yield value.value
    elif isinstance(value, dict):
        for item in value.values():
            yield from references(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from references(item)


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".xcprivacy": "text.xml",
    ".xcassets": "folder.assetcatalog",
    ".html": "text.html",
    ".js": "sourcecode.javascript",
    ".css": "text.css",
    ".json": "text.json",
    ".svg": "image.svg",
    ".png": "image.png",
    ".jpg": "image.jpeg",
    ".jpeg": "image.jpeg",
    ".heic": "image.heic",
    ".gif": "image.gif",
    ".mp4": "video.mp4",
    ".mov": "video.quicktime",
    ".m4v": "video.mp4",
    ".mkv": "file",
    ".avi": "video.avi",
    ".srt": "text",
    ".vtt": "text",
    ".txt": "text",
    ".ttf": "file",
    ".otf": "file",
}
RESOURCE_SUFFIXES = set(FILE_TYPES) - {".swift", ".plist", ".xcassets"}


def build_entry(reference: Ref, key: str) -> Ref:
    return add("PBXBuildFile", key, fileRef=reference)


def source_tree(relative: str, source_entries: list[Ref], resource_entries: list[Ref]) -> Ref:
    directory = ROOT / relative
    entries = []
    children = sorted(directory.iterdir(), key=lambda p: (not p.is_dir(), p.name.casefold())) if directory.exists() else []
    for child in children:
        if child.name.startswith(".") or child.name in {"__pycache__", "DerivedData", "build"}:
            continue
        rel = child.relative_to(ROOT).as_posix()
        # Folder references preserve fixture subdirectories in the app bundle.
        if child.is_dir() and child.name == "Fixtures":
            reference = add("PBXFileReference", rel, lastKnownFileType="folder", path=child.name, sourceTree="<group>")
            entries.append(reference)
            resource_entries.append(build_entry(reference, rel + " in Resources"))
        elif child.is_dir() and child.suffix == ".xcassets":
            reference = add("PBXFileReference", rel, lastKnownFileType="folder.assetcatalog", path=child.name, sourceTree="<group>")
            entries.append(reference)
            resource_entries.append(build_entry(reference, rel + " in Resources"))
        elif child.is_dir():
            entries.append(source_tree(rel, source_entries, resource_entries))
        elif child.suffix.lower() in FILE_TYPES:
            reference = add("PBXFileReference", rel, lastKnownFileType=FILE_TYPES[child.suffix.lower()], path=child.name, sourceTree="<group>")
            entries.append(reference)
            if child.suffix == ".swift":
                source_entries.append(build_entry(reference, rel + " in Sources"))
            elif child.suffix.lower() in RESOURCE_SUFFIXES:
                resource_entries.append(build_entry(reference, rel + " in Resources"))
    # Keep Info.plist visible even when its author has not written it yet.
    if relative == "Playit/Resources" and not (directory / "Info.plist").exists():
        entries.append(add("PBXFileReference", relative + "/Info.plist", lastKnownFileType="text.plist.xml", path="Info.plist", sourceTree="<group>"))
    return add("PBXGroup", relative, children=entries, path=Path(relative).name, sourceTree="<group>")


def configurations(label: str, settings: dict, release_extra: dict | None = None) -> Ref:
    items = []
    for name in ("Debug", "Release"):
        values = {**settings}
        if label == "Project":
            values.update(
                {"DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "GCC_OPTIMIZATION_LEVEL": "0", "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "SWIFT_OPTIMIZATION_LEVEL": "-Onone"}
                if name == "Debug" else
                {"DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O", "VALIDATE_PRODUCT": "YES"}
            )
        if name == "Release" and release_extra:
            values.update(release_extra)
        items.append(add("XCBuildConfiguration", label + "/" + name, buildSettings=values, name=name))
    return add("XCConfigurationList", label, buildConfigurations=items, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def write_xml(path: Path, root: ET.Element) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(path, encoding="UTF-8", xml_declaration=True)


def main() -> int:
    app_sources: list[Ref] = []
    app_resources: list[Ref] = []
    test_sources: list[Ref] = []
    test_resources: list[Ref] = []
    app_group = source_tree("Playit", app_sources, app_resources)
    test_group = source_tree("PlayitUITests", test_sources, test_resources)
    package_group = add("PBXGroup", "Packages", children=[
        add("PBXFileReference", "Packages/PlayitCore", lastKnownFileType="folder", path="PlayitCore", sourceTree="<group>"),
        add("PBXFileReference", "Packages/PlayitTransferCore", lastKnownFileType="folder", path="PlayitTransferCore", sourceTree="<group>"),
    ], path="Packages", sourceTree="<group>")
    app_product = add("PBXFileReference", "Prism.app", explicitFileType="wrapper.application", includeInIndex=0, path="Prism.app", sourceTree="BUILT_PRODUCTS_DIR")
    test_product = add("PBXFileReference", "PrismUITests.xctest", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="PrismUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
    products = add("PBXGroup", "Products", children=[app_product, test_product], name="Products", sourceTree="<group>")
    main_group = add("PBXGroup", "Main", children=[app_group, test_group, package_group, products], sourceTree="<group>")
    package_refs = [
        add("XCLocalSwiftPackageReference", "PlayitCore", relativePath="Packages/PlayitCore"),
        add("XCLocalSwiftPackageReference", "PlayitTransferCore", relativePath="Packages/PlayitTransferCore"),
        add("XCRemoteSwiftPackageReference", "MPVKit", repositoryURL=MPV_URL, requirement={"kind": "revision", "revision": MPV_REVISION}),
    ]
    package_products = [add("XCSwiftPackageProductDependency", name, package=ref, productName=name) for ref, name in zip(package_refs, ["PlayitCore", "PlayitTransferCore", "MPVKit"])]
    framework_entries = [add("PBXBuildFile", name + " in Frameworks", productRef=ref) for name, ref in zip(["PlayitCore", "PlayitTransferCore", "MPVKit"], package_products)]
    app_source_phase = add("PBXSourcesBuildPhase", "Prism Sources", buildActionMask=2147483647, files=app_sources, runOnlyForDeploymentPostprocessing=0)
    app_resource_phase = add("PBXResourcesBuildPhase", "Prism Resources", buildActionMask=2147483647, files=app_resources, runOnlyForDeploymentPostprocessing=0)
    app_framework_phase = add("PBXFrameworksBuildPhase", "Prism Frameworks", buildActionMask=2147483647, files=framework_entries, runOnlyForDeploymentPostprocessing=0)
    test_source_phase = add("PBXSourcesBuildPhase", "PrismUITests Sources", buildActionMask=2147483647, files=test_sources, runOnlyForDeploymentPostprocessing=0)
    test_resource_phase = add("PBXResourcesBuildPhase", "PrismUITests Resources", buildActionMask=2147483647, files=test_resources, runOnlyForDeploymentPostprocessing=0)
    test_framework_phase = add("PBXFrameworksBuildPhase", "PrismUITests Frameworks", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
    project_settings = {
        "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
        "CLANG_WARN_BOOL_CONVERSION": "YES", "CLANG_WARN_CONSTANT_CONVERSION": "YES", "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
        "CLANG_WARN_EMPTY_BODY": "YES", "CLANG_WARN_ENUM_CONVERSION": "YES", "CLANG_WARN_INFINITE_RECURSION": "YES",
        "CLANG_WARN_INT_CONVERSION": "YES", "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES", "CLANG_WARN_UNREACHABLE_CODE": "YES",
        "COPY_PHASE_STRIP": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "GCC_C_LANGUAGE_STANDARD": "gnu17",
        "GCC_NO_COMMON_BLOCKS": "YES", "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES", "GCC_WARN_ABOUT_RETURN_TYPE": "YES_ERROR",
        "GCC_WARN_UNDECLARED_SELECTOR": "YES", "GCC_WARN_UNINITIALIZED_AUTOS": "YES_AGGRESSIVE", "GCC_WARN_UNUSED_FUNCTION": "YES",
        "GCC_WARN_UNUSED_VARIABLE": "YES", "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0",
    }
    app_settings = {
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor", "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "16",
        "DEVELOPMENT_TEAM": "", "ENABLE_PREVIEWS": "YES", "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "Playit/Resources/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
        "MARKETING_VERSION": "0.3.2", "PRODUCT_BUNDLE_IDENTIFIER": "com.playit.app", "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SWIFT_EMIT_LOC_STRINGS": "YES", "SWIFT_STRICT_CONCURRENCY": "targeted", "SWIFT_VERSION": "5.0", "TARGETED_DEVICE_FAMILY": "1,2",
    }
    if (ROOT / "Playit/Resources/Assets.xcassets/AppIcon.appiconset").is_dir():
        app_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
    test_settings = {
        "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "16", "DEVELOPMENT_TEAM": "", "GENERATE_INFOPLIST_FILE": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": "17.0", "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@loader_path/Frameworks"],
        "MARKETING_VERSION": "0.3.2", "PRODUCT_BUNDLE_IDENTIFIER": "com.playit.app.uitests", "PRODUCT_NAME": "$(TARGET_NAME)",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SWIFT_VERSION": "5.0", "TARGETED_DEVICE_FAMILY": "1,2", "TEST_TARGET_NAME": "Prism",
    }
    project_config = configurations("Project", project_settings)
    # The short test clips are only for UI tests and demos (-prism-sample-media
    # in Debug runs); App Store builds leave them out.
    app_config = configurations("Prism", app_settings, {"EXCLUDED_SOURCE_FILE_NAMES": "Fixtures"})
    test_config = configurations("PrismUITests", test_settings)
    app_target = add("PBXNativeTarget", "Prism", buildConfigurationList=app_config, buildPhases=[app_source_phase, app_framework_phase, app_resource_phase], buildRules=[], dependencies=[], name="Prism", packageProductDependencies=package_products, productName="Prism", productReference=app_product, productType="com.apple.product-type.application")
    # The proxy's project reference is filled after the project object is created.
    project_id = identifier("PBXProject", "Prism")
    proxy = add("PBXContainerItemProxy", "UI tests app proxy", containerPortal=Ref(project_id), proxyType=1, remoteGlobalIDString=app_target, remoteInfo="Prism")
    dependency = add("PBXTargetDependency", "UI tests app dependency", target=app_target, targetProxy=proxy)
    test_target = add("PBXNativeTarget", "PrismUITests", buildConfigurationList=test_config, buildPhases=[test_source_phase, test_framework_phase, test_resource_phase], buildRules=[], dependencies=[dependency], name="PrismUITests", packageProductDependencies=[], productName="PrismUITests", productReference=test_product, productType="com.apple.product-type.bundle.ui-testing")
    project_ref = add("PBXProject", "Prism", attributes={"BuildIndependentTargetsInParallel": "YES", "LastSwiftUpdateCheck": "1600", "LastUpgradeCheck": "1600", "TargetAttributes": {app_target.value: {"CreatedOnToolsVersion": "16.0"}, test_target.value: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_target}}}, buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0", developmentRegion="zh-Hans", hasScannedForEncodings=0, knownRegions=["zh-Hans", "en", "Base"], mainGroup=main_group, packageReferences=package_refs, productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_target, test_target])
    for uid, item in objects.items():
        for target in references(item):
            if target not in objects:
                raise ValueError(f"Dangling PBX reference in {uid}: {target}")
    data = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_ref}
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(data) + "\n")

    workspace = ET.Element("Workspace", version="1.0")
    ET.SubElement(workspace, "FileRef", location="self:")
    write_xml(PROJECT / "project.xcworkspace/contents.xcworkspacedata", workspace)
    pins = {"pins": [{"identity": "mpvkit", "kind": "remoteSourceControl", "location": MPV_URL, "state": {"revision": MPV_REVISION}}], "version": 2}
    pin_path = PROJECT / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    pin_path.parent.mkdir(parents=True, exist_ok=True)
    pin_path.write_text(json.dumps(pins, indent=2) + "\n")

    scheme = ET.Element("Scheme", LastUpgradeVersion="1600", version="1.3")

    def buildable(parent, ref: Ref, name: str, product_name: str):
        return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=ref.value, BuildableName=product_name, BlueprintName=name, ReferencedContainer="container:Prism.xcodeproj")

    build = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
    build_entries = ET.SubElement(build, "BuildActionEntries")
    app_entry = ET.SubElement(build_entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES")
    buildable(app_entry, app_target, "Prism", "Prism.app")
    test_entry = ET.SubElement(build_entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="NO", buildForProfiling="NO", buildForArchiving="NO", buildForAnalyzing="NO")
    buildable(test_entry, test_target, "PrismUITests", "PrismUITests.xctest")
    test_action = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", shouldUseLaunchSchemeArgsEnv="YES")
    testables = ET.SubElement(test_action, "Testables")
    testable = ET.SubElement(testables, "TestableReference", skipped="NO")
    buildable(testable, test_target, "PrismUITests", "PrismUITests.xctest")
    macro = ET.SubElement(test_action, "MacroExpansion")
    buildable(macro, app_target, "Prism", "Prism.app")
    launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
    runnable = ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0")
    buildable(runnable, app_target, "Prism", "Prism.app")
    profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
    buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"), app_target, "Prism", "Prism.app")
    ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
    ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
    write_xml(PROJECT / "xcshareddata/xcschemes/Prism.xcscheme", scheme)

    try:
        from openstep_parser import OpenStepDecoder
    except ImportError:
        sys.path.insert(0, "/tmp/playit-validation-python")
        try:
            from openstep_parser import OpenStepDecoder
        except ImportError:
            OpenStepDecoder = None
    if OpenStepDecoder:
        parsed = OpenStepDecoder.ParseFromString((PROJECT / "project.pbxproj").read_text())
        if parsed["rootObject"] != project_ref.value or len(parsed["objects"]) != len(objects):
            raise ValueError("OpenStep parser round-trip mismatch")
        parse_status = "OpenStep parser passed"
    else:
        parse_status = "Reference graph passed; optional OpenStep parser unavailable"
    print(f"Generated {PROJECT}: {len(app_sources)} app Swift files, {len(app_resources)} app resource entries, {len(test_sources)} UI-test Swift files, {len(objects)} PBX objects.")
    print(parse_status + "; shared Prism scheme and MPVKit revision pin written.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
