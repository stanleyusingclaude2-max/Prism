#!/usr/bin/env python3
"""Validate project references, bundled resources, metadata and upload JavaScript.

This is a static/resource check. It does not replace xcodebuild or device tests.
Optional tools: openstep-parser (Python), node, ffprobe.
"""

from __future__ import annotations

from collections import Counter
from html.parser import HTMLParser
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, "/tmp/playit-validation-python")
try:
    from openstep_parser import OpenStepDecoder
except ImportError:
    sys.exit("Install the project parser: python3 -m pip install openstep-parser")


def require(condition: bool, message: str):
    if not condition:
        raise ValueError(message)


def nonempty(path: Path):
    require(path.is_file() and path.stat().st_size > 0, f"Missing/empty file: {path}")


def bundled_file_lookup(bundled: set[Path]) -> dict[str, list[Path]]:
    """Resolve resource-copy destinations, including preserved folder references."""
    result: dict[str, list[Path]] = {}
    for resource in bundled:
        if resource.is_dir() and resource.suffix != ".xcassets":
            for path in resource.rglob("*"):
                if path.is_file():
                    name = resource.name + "/" + path.relative_to(resource).as_posix()
                    result.setdefault(name, []).append(path)
        elif resource.is_file():
            result.setdefault(resource.name, []).append(resource)
    return result


def validate_fonts(info: dict, bundled: set[Path]) -> tuple[int, int]:
    registrations = info.get("UIAppFonts", [])
    require(isinstance(registrations, list) and bool(registrations), "UIAppFonts must register the app's bundled typefaces")
    require(len(registrations) == len(set(registrations)), "UIAppFonts contains duplicate registrations")
    lookup = bundled_file_lookup(bundled)
    font_paths: list[Path] = []
    for name in registrations:
        require(isinstance(name, str) and bool(name), "UIAppFonts contains an invalid filename")
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and ".." not in relative.parts and "\\" not in name, f"Unsafe UIAppFonts resource path: {name}")
        matches = lookup.get(name, [])
        require(len(matches) == 1, f"UIAppFonts resource is missing or ambiguous in the app's Resources build phase: {name}")
        path = matches[0]
        nonempty(path)
        require(path.suffix.lower() == ".otf", f"Expected the supplied OpenType D-DIN resource: {name}")
        with path.open("rb") as file:
            require(file.read(4) == b"OTTO", f"Invalid OpenType/CFF file signature: {path}")
        font_paths.append(path)

    license_matches = lookup.get("D-DIN-OFL.txt", [])
    require(len(license_matches) == 1, "The D-DIN license must be copied into the app bundle")
    nonempty(license_matches[0])
    license_text = license_matches[0].read_text()
    require("SIL OPEN FONT LICENSE Version 1.1" in license_text and "Datto" in license_text and "D-DIN" in license_text, "The bundled D-DIN license is incomplete or belongs to a different font")

    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        print("FontTools is unavailable: font bundle paths, file signatures and license checked; PostScript/glyph inspection skipped.")
        return len(font_paths), 0

    postscript_names: set[str] = set()
    for path in font_paths:
        with TTFont(path) as font:
            names = {record.toUnicode() for record in font["name"].names if record.nameID == 6}
            require(len(names) == 1, f"Expected one unambiguous PostScript font name: {path}")
            postscript_names.update(names)
            cmap = font.getBestCmap() or {}
            missing = [chr(code) for code in range(0x20, 0x7F) if cmap.get(code) in {None, ".notdef"}]
            require(not missing, f"The supplied font lacks printable ASCII glyphs: {path}: {missing}")
            embedded_license = "\n".join(record.toUnicode() for record in font["name"].names if record.nameID in {13, 14})
            require("SIL Open Font License" in embedded_license and "1.1" in embedded_license, f"The font's embedded license does not match OFL 1.1: {path}")
    require(postscript_names == {"D-DIN", "D-DIN-Bold"}, f"Unexpected font faces in actual OpenType binaries: {postscript_names}")
    typography = (ROOT / "Playit/Design/AppTypography.swift").read_text()
    referenced_faces = set(re.findall(r'\b(?:regularName|boldName)\s*=\s*"([^"\\]+)"', typography))
    require(referenced_faces == postscript_names, f"App typography refers to faces not registered by the actual font files: {referenced_faces - postscript_names}")
    return len(font_paths), len(postscript_names)


def validate_accent(objects: dict, color_names: set[str]) -> str:
    theme = (ROOT / "Playit/Design/Theme.swift").read_text()
    match = re.search(r'\bstatic\s+let\s+accent\s*=\s*Color\(\s*"([^"\\]+)"\s*\)', theme)
    require(bool(match), "Theme.accent must directly resolve its named asset instead of inheriting an environment tint")
    asset_name = match.group(1)
    require(asset_name == "AccentColor" and asset_name in color_names, "Theme.accent does not resolve the app's AccentColor asset")
    app_targets = [item for item in objects.values() if item["isa"] == "PBXNativeTarget" and item.get("productType") == "com.apple.product-type.application"]
    require(len(app_targets) == 1, "Expected one app target for accent validation")
    configurations = objects[app_targets[0]["buildConfigurationList"]]["buildConfigurations"]
    for configuration_id in configurations:
        configuration = objects[configuration_id]
        setting = configuration["buildSettings"].get("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME")
        require(setting == asset_name, f"{configuration['name']} global accent does not match Theme.accent: {setting}")
    return asset_name


def validate_app_icon(objects: dict, bundled: set[Path], asset_dir: Path) -> str:
    """Check the icon's real PNG metadata, manifest and Xcode target selection."""
    iconset = asset_dir / "AppIcon.appiconset"
    manifest_path = iconset / "Contents.json"
    nonempty(manifest_path)
    manifest = json.loads(manifest_path.read_text())
    defaults = [entry for entry in manifest.get("images", [])
                if entry.get("idiom") == "universal" and entry.get("platform") == "ios"
                and entry.get("size") == "1024x1024" and not entry.get("appearances")]
    require(len(defaults) == 1, "AppIcon must have one default universal iOS 1024×1024 slot")
    filename = defaults[0].get("filename", "")
    require(bool(filename) and PurePosixPath(filename).name == filename, "AppIcon has an invalid image filename")
    icon_path = iconset / filename
    nonempty(icon_path)
    require(asset_dir.resolve() in bundled, "AppIcon's asset catalog is absent from the Resources build phase")

    with icon_path.open("rb") as file:
        header = file.read(33)
    require(len(header) == 33 and header[:8] == b"\x89PNG\r\n\x1a\n" and header[12:16] == b"IHDR", "AppIcon is not a PNG with an IHDR header")
    width, height, depth, color_type = struct.unpack(">IIBB", header[16:26])
    require((width, height) == (1024, 1024), f"AppIcon dimensions must be 1024×1024, got {width}×{height}")
    require(depth == 8 and color_type == 2, "AppIcon must use 8-bit RGB without an alpha channel")
    try:
        from PIL import Image
    except ImportError:
        print("AppIcon header passed; install Pillow to additionally verify PNG integrity/transparency metadata.")
    else:
        with Image.open(icon_path) as icon:
            require(icon.format == "PNG" and icon.mode == "RGB" and "transparency" not in icon.info,
                    "AppIcon must be an opaque RGB PNG without transparency metadata")
            icon.verify()

    app_targets = [item for item in objects.values() if item["isa"] == "PBXNativeTarget" and item.get("productType") == "com.apple.product-type.application"]
    require(len(app_targets) == 1, "Expected one app target for AppIcon validation")
    for config_id in objects[app_targets[0]["buildConfigurationList"]]["buildConfigurations"]:
        configuration = objects[config_id]
        require(configuration["buildSettings"].get("ASSETCATALOG_COMPILER_APPICON_NAME") == "AppIcon",
                f"{configuration['name']} is not configured to use AppIcon")

    vector_path = ROOT / "Design/AppIcon-B.svg"
    nonempty(vector_path)
    vector = ET.parse(vector_path).getroot()
    require(vector.tag.endswith("svg") and [float(value) for value in vector.attrib.get("viewBox", "").split()] == [0, 0, 1024, 1024],
            "The selected B vector source must retain its complete 1024px square")
    require(not (ROOT / "Design/AppIcon-C.svg").exists(), "Remove the retired C icon source so only the shipped icon has a vector source")
    return f"{width}×{height}, RGB without alpha, universal iOS slot and App Debug/Release settings matched"


def main() -> int:
    project_dir = ROOT / "Prism.xcodeproj"
    require(not (ROOT / "Playit.xcodeproj").exists(), "Remove the obsolete Playit.xcodeproj before delivering the Prism project")
    project = OpenStepDecoder.ParseFromString((project_dir / "project.pbxproj").read_text())
    objects = project["objects"]
    root = objects[project["rootObject"]]
    ref_keys = {"buildConfigurationList", "mainGroup", "productRefGroup", "productReference", "fileRef", "productRef", "target", "targetProxy", "containerPortal", "package", "remoteGlobalIDString", "TestTargetID"}
    list_ref_keys = {"children", "files", "buildConfigurations", "buildPhases", "dependencies", "packageProductDependencies", "packageReferences", "targets"}

    def inspect_refs(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ref_keys:
                    require(item in objects, f"Dangling project reference {key}: {item}")
                elif key in list_ref_keys:
                    for ref in item:
                        require(ref in objects, f"Dangling project array reference {key}: {ref}")
                else:
                    inspect_refs(item)
        elif isinstance(value, list):
            for item in value:
                inspect_refs(item)

    inspect_refs(objects)
    targets = {objects[uid]["name"]: objects[uid] for uid in root["targets"]}
    require(set(targets) == {"Prism", "PrismUITests"}, "The project must expose Prism and PrismUITests targets")
    target_versions = set()
    for name, bundle_id in (("Prism", "com.playit.app"), ("PrismUITests", "com.playit.app.uitests")):
        target = targets[name]
        product = objects[target["productReference"]]
        suffix = ".app" if name == "Prism" else ".xctest"
        require(target["productName"] == name and product["path"] == name + suffix, f"Incorrect renamed product: {name}")
        for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            settings = objects[config_id]["buildSettings"]
            require(settings.get("PRODUCT_NAME") in {name, "$(TARGET_NAME)"}, f"Unexpected product/executable name: {name}")
            require(settings.get("PRODUCT_BUNDLE_IDENTIFIER") == bundle_id, f"Bundle ID must preserve overwrite-install compatibility: {name}")
            if name == "PrismUITests":
                require(settings.get("TEST_TARGET_NAME") == "Prism", "UI tests must launch the renamed Prism app")
            target_versions.add((settings.get("MARKETING_VERSION"), settings.get("CURRENT_PROJECT_VERSION")))
    require(len(target_versions) == 1 and all(next(iter(target_versions))), "App and UI-test versions must match in every configuration")
    expected_products = {"PlayitCore", "PlayitTransferCore", "MPVKit"}
    dependencies = [objects[uid] for uid in targets["Prism"].get("packageProductDependencies", [])]
    require({obj.get("productName") for obj in dependencies} == expected_products,
            "App must link both local products and MPVKit")
    for dependency in dependencies:
        package_ref = objects[dependency["package"]]
        require(dependency["package"] in root["packageReferences"], "Product package is not registered by the project")
        product = dependency["productName"]
        if product == "MPVKit":
            require(package_ref["isa"] == "XCRemoteSwiftPackageReference" and package_ref["repositoryURL"] == "https://github.com/mpvkit/MPVKit.git", "MPVKit source URL is invalid")
            continue
        require(package_ref["isa"] == "XCLocalSwiftPackageReference", f"{product} must remain a local package")
        package_path = (ROOT / package_ref["relativePath"]).resolve()
        require(package_path.is_relative_to(ROOT.resolve()), "Local package escapes the source directory")
        manifest_path = package_path / "Package.swift"
        nonempty(manifest_path)
        require(re.search(r'\.library\(\s*name:\s*"' + re.escape(product) + r'"', manifest_path.read_text()) is not None,
                f"Local manifest does not export {product}")
        require(any((package_path / "Sources" / product).glob("*.swift")), f"{product} source files are missing")
    paths: dict[str, Path] = {}

    def walk_group(uid: str, parent: Path):
        item = objects[uid]
        if item.get("sourceTree") == "BUILT_PRODUCTS_DIR":
            return
        base = parent / item.get("path", "")
        if item["isa"] == "PBXGroup":
            for child in item.get("children", []):
                walk_group(child, base)
        elif item["isa"] == "PBXFileReference":
            require(base.exists(), f"Project points at missing file/directory: {base}")
            paths[uid] = base.resolve()

    walk_group(root["mainGroup"], ROOT)
    bundled: set[Path] = set()
    app_sources: set[Path] = set()
    for item in objects.values():
        if item["isa"] in {"PBXResourcesBuildPhase", "PBXSourcesBuildPhase"}:
            for uid in item.get("files", []):
                file_ref = objects[uid].get("fileRef")
                if file_ref:
                    path = paths[file_ref]
                    (bundled if item["isa"] == "PBXResourcesBuildPhase" else app_sources).add(path)
    expected_sources = {path.resolve() for directory in ("Playit", "PlayitUITests") for path in (ROOT / directory).rglob("*.swift")}
    require(app_sources == expected_sources, "Swift source membership is stale; run scripts/generate-project.py")
    for filename in ("Assets.xcassets", "PrivacyInfo.xcprivacy", "Fixtures", "MPVKit-LICENSE.txt"):
        require((ROOT / "Playit/Resources" / filename).resolve() in bundled, f"Resource is not in the build phase: {filename}")

    plists = []
    for path in list(ROOT.rglob("*.plist")) + list(ROOT.rglob("*.xcprivacy")):
        if ".build" in path.parts:
            continue
        with path.open("rb") as file:
            data = plistlib.load(file)
        require(isinstance(data, dict), f"Expected plist dictionary: {path}")
        plists.append(path)
    info = plistlib.loads((ROOT / "Playit/Resources/Info.plist").read_bytes())
    require(info.get("UIFileSharingEnabled") and info.get("LSSupportsOpeningDocumentsInPlace"), "USB/File app sharing must remain enabled")
    require(bool(info.get("NSLocalNetworkUsageDescription")), "Local-network permission purpose is missing")
    require({"UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"} <= set(info["UISupportedInterfaceOrientations"]), "Phone orientation declaration is incomplete")
    privacy = plistlib.loads((ROOT / "Playit/Resources/PrivacyInfo.xcprivacy").read_bytes())
    require(privacy.get("NSPrivacyTracking") is False, "Unexpected privacy tracking declaration")
    for entry in privacy.get("NSPrivacyAccessedAPITypes", []):
        require(bool(entry.get("NSPrivacyAccessedAPIType")) and bool(entry.get("NSPrivacyAccessedAPITypeReasons")), "Incomplete required-reason API declaration")

    asset_dir = ROOT / "Playit/Resources/Assets.xcassets"
    image_names = {path.stem for path in asset_dir.glob("*.imageset")}
    color_names = {path.stem for path in asset_dir.glob("*.colorset")}
    json_count = 0
    for path in ROOT.rglob("*.json"):
        if ".build" in path.parts:
            continue
        data = json.loads(path.read_text())
        json_count += 1
        if path.name == "Contents.json":
            require(isinstance(data.get("info"), dict), f"Missing asset info: {path}")
            for image in data.get("images", []):
                if image.get("filename"):
                    nonempty(path.parent / image["filename"])
            for color in data.get("colors", []):
                components = color.get("color", {}).get("components", {})
                require(bool(components), f"Missing asset color components: {path}")
                for value in components.values():
                    require(0 <= float(value) <= 1, f"Invalid normalized color value: {path}")
    svg_count = 0
    for path in asset_dir.rglob("*.svg"):
        nonempty(path)
        svg = ET.parse(path).getroot()
        require(svg.tag.endswith("svg"), f"Unexpected SVG root: {path}")
        for dimension in ("width", "height"):
            require(bool(re.match(r"^[1-9]\d*(?:\.\d+)?(?:px)?$", svg.attrib.get(dimension, ""))), f"Missing positive SVG {dimension}: {path}")
        require(bool(svg.attrib.get("viewBox")) and len(svg) > 0, f"Empty SVG content/viewBox: {path}")
        svg_count += 1

    source_text = "\n".join(path.read_text() for path in (ROOT / "Playit").rglob("*.swift"))
    used_icons = set(re.findall(r'"(Icon[A-Za-z0-9_]+)"', source_text))
    used_colors = set(re.findall(r'Color\("([^"\\]+)"\)', source_text))
    used_colors |= set(re.findall(r'UIColor\(named:\s*"([^"\\]+)"\)', source_text))
    require(not (used_icons - image_names), f"Unresolved icon assets: {used_icons - image_names}")
    require(not (used_colors - color_names), f"Unresolved color assets: {used_colors - color_names}")
    static_images = set(re.findall(r'Image\("([^"\\]+)"\)', source_text))
    require(not (static_images - image_names), f"Unresolved static Image calls: {static_images - image_names}")
    registered_fonts, inspected_faces = validate_fonts(info, bundled)
    accent_asset = validate_accent(objects, color_names)
    app_icon_status = validate_app_icon(objects, bundled, asset_dir)

    sample_code = (ROOT / "Playit/App/PlayitApp.swift").read_text().split("enum SampleMedia", 1)[1]
    samples = re.findall(r'\("([^"\\]+)",\s*"([^"\\]+)"\)', sample_code)
    fixture_dir = ROOT / "Playit/Resources/Fixtures"
    require(len(samples) >= 4, "Expected playable sample files for UI tests")
    for stem, extension in samples:
        nonempty(fixture_dir / (stem + "." + extension))
    fixture_results = []
    if shutil.which("ffprobe"):
        fixture_metadata: dict[str, dict] = {}
        for stem, extension in samples:
            path = fixture_dir / (stem + "." + extension)
            result = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_streams", "-of", "json", str(path)], capture_output=True, text=True, check=True)
            data = json.loads(result.stdout)
            require(bool(data.get("streams")), f"Undecodable media fixture: {path}")
            fixture_results.append((path.name, len(data["streams"])))
            fixture_metadata[path.name] = data
        result = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=best_effort_timestamp_time", "-of", "json", str(fixture_dir / "sample-variable.mkv")], capture_output=True, text=True, check=True)
        times = [float(frame["best_effort_timestamp_time"]) for frame in json.loads(result.stdout)["frames"]]
        require(len({round(b - a, 3) for a, b in zip(times, times[1:])}) > 1, "The VFR fixture has constant frame durations")
        portrait = next(stream for stream in fixture_metadata["sample-portrait.mov"]["streams"] if stream["codec_type"] == "video")
        require(portrait["height"] > portrait["width"], "The portrait fixture must contain a genuinely portrait video stream")
        rotated = next(stream for stream in fixture_metadata["sample-rotated.mov"]["streams"] if stream["codec_type"] == "video")
        rotations = [side_data["rotation"] for side_data in rotated.get("side_data_list", []) if "rotation" in side_data]
        require(bool(rotations) and float(rotations[0]) % 360 in {90, 270}, "The rotated fixture must carry an actual quarter-turn display matrix")
        require(rotated["width"] > rotated["height"], "The rotated portrait fixture must retain landscape encoded dimensions")

    scheme = ET.parse(project_dir / "xcshareddata/xcschemes/Prism.xcscheme").getroot()
    for buildable in scheme.iter("BuildableReference"):
        require(buildable.attrib["BlueprintIdentifier"] in objects, "Shared scheme references a missing target")
        target = objects[buildable.attrib["BlueprintIdentifier"]]
        require(target["isa"] == "PBXNativeTarget" and target["name"] in targets, "Shared scheme must reference a Prism native target")
        require(buildable.attrib["BlueprintName"] == target["name"] and buildable.attrib["BuildableName"] == objects[target["productReference"]]["path"], "Shared scheme product names are stale")
        require(buildable.attrib["ReferencedContainer"] == "container:Prism.xcodeproj", "Shared scheme still references the old project")
    ET.parse(project_dir / "project.xcworkspace/contents.xcworkspacedata")
    pins = json.loads((project_dir / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
    require(pins["pins"][0]["state"]["revision"] == "98c3453e252922e3136422da3fbb2e341ed9edc8", "MPVKit revision pin changed unexpectedly")

    upload_source = (ROOT / "Playit/Transfer/UploadPage.swift").read_text()
    match = re.search(r'html\s*=\s*#"""(.*?)"""#', upload_source, re.S)
    require(bool(match), "Upload HTML string was not found")
    web_fonts = set(re.findall(r'url\("fonts/([^"/]+\.otf)"\)', match.group(1)))
    require(web_fonts == set(info["UIAppFonts"]), "Browser font URLs do not match the registered local font resources")

    class PageParser(HTMLParser):
        def __init__(self):
            super().__init__()
            self.script_open = False
            self.scripts: list[str] = []
            self.ids: list[str] = []

        def handle_starttag(self, tag, attrs):
            attributes = dict(attrs)
            if attributes.get("id"):
                self.ids.append(attributes["id"])
            if tag == "script":
                self.script_open = True

        def handle_endtag(self, tag):
            if tag == "script":
                self.script_open = False

        def handle_data(self, data):
            if self.script_open:
                self.scripts.append(data)

    page = PageParser()
    page.feed(match.group(1))
    require(not [key for key, count in Counter(page.ids).items() if count > 1], "Upload HTML has duplicate element IDs")
    require({"drop", "choose", "picker", "queue", "capacity"} <= set(page.ids), "Upload HTML is missing required controls")
    require(bool(page.scripts), "Upload HTML has no JavaScript")
    if shutil.which("node"):
        with tempfile.TemporaryDirectory(prefix="playit-js-") as directory:
            script = Path(directory) / "upload.js"
            script.write_text("\n".join(page.scripts))
            subprocess.run(["node", "--check", str(script)], check=True)
    shell_count = 0
    for path in (ROOT / "scripts").glob("*.sh"):
        subprocess.run(["bash", "-n", str(path)], check=True)
        shell_count += 1

    print(f"Project: {len(objects)} valid PBX objects, {len(paths)} existing file/folder references, {len(expected_sources)} Swift target memberships, {len(bundled)} bundled resource entries.")
    print(f"Metadata/assets: {len(plists)} plists/privacy manifests, {json_count} JSON files, {svg_count} nonempty SVGs; {len(used_icons)} icon and {len(used_colors)} named color references resolved.")
    print(f"Typography/accent: {registered_fonts} registered OpenType bundle resources, {inspected_faces} PostScript/ASCII/OFL inspections; Theme and build configurations resolve {accent_asset}.")
    print(f"AppIcon: {app_icon_status}.")
    print(f"Fixtures: {len(samples)} bundle lookups resolved; ffprobe checked {len(fixture_results)} files including variable frame durations, portrait dimensions and a rotated display matrix.")
    print(f"Upload JavaScript parsed; {shell_count} shell scripts parsed. Shared scheme and pinned MPVKit dependency checked.")
    print("No iOS SDK compilation, simulator execution or device performance claim is made by these checks.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
