#!/usr/bin/env python3
"""Generates PufferParty.xcodeproj from the files on disk.

Run from the repository root after adding or removing source files:

    python3 scripts/generate_xcodeproj.py

(Alternatively `xcodegen` with project.yml produces an equivalent project.)
"""
import hashlib
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "PufferParty"
TESTS = "PufferPartyTests"
BUNDLE_ID = "io.krillion.pufferparty"
DEPLOYMENT = "17.0"


def uid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


def q(value):
    """Quote a pbxproj string when needed."""
    safe = all(c.isalnum() or c in "._/$" for c in value) and value != ""
    if safe and not value.startswith("$("):
        return value
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def collect(folder):
    out = []
    base = os.path.join(ROOT, folder)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if not d.endswith(".xcassets"))
        rel = os.path.relpath(dirpath, ROOT)
        for d in os.listdir(dirpath):
            if d.endswith(".xcassets"):
                out.append(os.path.join(rel, d))
        for f in sorted(filenames):
            if f.startswith("."):
                continue
            out.append(os.path.join(rel, f))
    return sorted(set(out))


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".xcassets": "folder.assetcatalog",
    ".ttf": "file",
    ".txt": "text",
    ".plist": "text.plist.xml",
    ".entitlements": "text.plist.entitlements",
}


def file_type(path):
    return FILE_TYPES.get(os.path.splitext(path)[1], "file")


def main():
    app_files = collect(APP)
    test_files = collect(TESTS)
    objects = []

    def obj(oid, body):
        objects.append((oid, body))

    # File references and groups
    groups = {}  # path -> list of child ids

    def ensure_group(path):
        if path in groups:
            return
        groups[path] = []
        parent = os.path.dirname(path)
        if parent:
            ensure_group(parent)
            groups[parent].append(("group", path))

    file_ids = {}
    for path in app_files + test_files:
        parent = os.path.dirname(path)
        ensure_group(parent)
        fid = uid("file", path)
        file_ids[path] = fid
        groups[parent].append(("file", path))
        name = os.path.basename(path)
        obj(fid, "{isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = \"<group>\"; }"
            % (file_type(path), q(name)))

    app_product = uid("product", APP)
    test_product = uid("product", TESTS)
    obj(app_product, "{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; "
                     "path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; }" % APP)
    obj(test_product, "{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; "
                      "path = %s.xctest; sourceTree = BUILT_PRODUCTS_DIR; }" % TESTS)

    products_group = uid("group", "Products")
    obj(products_group, "{isa = PBXGroup; children = (%s, %s, ); name = Products; sourceTree = \"<group>\"; }"
        % (app_product, test_product))

    for path, children in groups.items():
        child_ids = []
        for kind, child in sorted(children, key=lambda c: (c[0] != "group", c[1].lower())):
            child_ids.append(uid("group", child) if kind == "group" else file_ids[child])
        obj(uid("group", path), "{isa = PBXGroup; children = (%s); path = %s; sourceTree = \"<group>\"; }"
            % ("".join(c + ", " for c in child_ids), q(os.path.basename(path))))

    main_group = uid("group", "<main>")
    top = [uid("group", APP), uid("group", TESTS), products_group]
    obj(main_group, "{isa = PBXGroup; children = (%s); sourceTree = \"<group>\"; }" % "".join(t + ", " for t in top))

    # Build files
    def build_files(paths, phase):
        ids = []
        for path in paths:
            bid = uid("build", phase, path)
            obj(bid, "{isa = PBXBuildFile; fileRef = %s; }" % file_ids[path])
            ids.append(bid)
        return ids

    app_sources = [p for p in app_files if p.endswith(".swift")]
    app_resources = [p for p in app_files if p.endswith((".xcassets", ".ttf", ".txt"))]
    test_sources = [p for p in test_files if p.endswith(".swift")]

    def phase(isa, name, ids):
        pid = uid("phase", name)
        obj(pid, "{isa = %s; buildActionMask = 2147483647; files = (%s); runOnlyForDeploymentPostprocessing = 0; }"
            % (isa, "".join(i + ", " for i in ids)))
        return pid

    app_src_phase = phase("PBXSourcesBuildPhase", "app-sources", build_files(app_sources, "app-src"))
    app_res_phase = phase("PBXResourcesBuildPhase", "app-resources", build_files(app_resources, "app-res"))
    app_fw_phase = phase("PBXFrameworksBuildPhase", "app-frameworks", [])
    test_src_phase = phase("PBXSourcesBuildPhase", "test-sources", build_files(test_sources, "test-src"))
    test_res_phase = phase("PBXResourcesBuildPhase", "test-resources", [])
    test_fw_phase = phase("PBXFrameworksBuildPhase", "test-frameworks", [])

    # Build configurations
    def settings_block(settings):
        return "".join("\t\t\t\t%s = %s;\n" % (k, q(v) if isinstance(v, str) else v) for k, v in sorted(settings.items()))

    def config(name, owner, settings):
        cid = uid("config", owner, name)
        obj(cid, "{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n%s\t\t\t};\n\t\t\tname = %s;\n\t\t}"
            % (settings_block(settings), name))
        return cid

    def config_list(owner, debug, release):
        lid = uid("configlist", owner)
        obj(lid, "{isa = XCConfigurationList; buildConfigurations = (%s, %s, ); defaultConfigurationIsVisible = 0; "
                 "defaultConfigurationName = Release; }" % (debug, release))
        return lid

    project_common = {
        "ALWAYS_SEARCH_USER_PATHS": "NO",
        "CLANG_ENABLE_MODULES": "YES",
        "CLANG_ENABLE_OBJC_ARC": "YES",
        "COPY_PHASE_STRIP": "NO",
        "ENABLE_STRICT_OBJC_MSGSEND": "YES",
        "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "GCC_NO_COMMON_BLOCKS": "YES",
        "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT,
        "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0",
    }
    project_debug = dict(project_common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf",
        "ENABLE_TESTABILITY": "YES",
        "GCC_OPTIMIZATION_LEVEL": "0",
        "ONLY_ACTIVE_ARCH": "YES",
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
        "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    })
    project_release = dict(project_common, **{
        "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
        "SWIFT_COMPILATION_MODE": "wholemodule",
        "SWIFT_OPTIMIZATION_LEVEL": "-O",
        "VALIDATE_PRODUCT": "YES",
    })
    project_list = config_list("project", config("Debug", "project", project_debug),
                               config("Release", "project", project_release))

    app_settings = {
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "CODE_SIGN_ENTITLEMENTS": "%s/%s.entitlements" % (APP, APP),
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "DEVELOPMENT_TEAM": "",
        "ENABLE_PREVIEWS": "YES",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "%s/Info.plist" % APP,
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_EMIT_LOC_STRINGS": "NO",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "TARGETED_DEVICE_FAMILY": "1,2",
    }
    app_list = config_list("app", config("Debug", "app", app_settings), config("Release", "app", app_settings))

    test_settings = {
        "BUNDLE_LOADER": "$(TEST_HOST)",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": "1",
        "GENERATE_INFOPLIST_FILE": "YES",
        "MARKETING_VERSION": "1.0",
        "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + ".tests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SWIFT_STRICT_CONCURRENCY": "minimal",
        "TARGETED_DEVICE_FAMILY": "1,2",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/%s.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/%s" % (APP, APP),
    }
    test_list = config_list("tests", config("Debug", "tests", test_settings), config("Release", "tests", test_settings))

    # Targets
    app_target = uid("target", APP)
    test_target = uid("target", TESTS)
    project_id = uid("project")
    proxy = uid("proxy", TESTS)
    dependency = uid("dependency", TESTS)

    obj(app_target, "{isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = (%s, %s, %s, ); "
                    "buildRules = ( ); dependencies = ( ); name = %s; productName = %s; productReference = %s; "
                    "productType = \"com.apple.product-type.application\"; }"
        % (app_list, app_src_phase, app_fw_phase, app_res_phase, APP, APP, app_product))
    obj(proxy, "{isa = PBXContainerItemProxy; containerPortal = %s; proxyType = 1; remoteGlobalIDString = %s; "
               "remoteInfo = %s; }" % (project_id, app_target, APP))
    obj(dependency, "{isa = PBXTargetDependency; target = %s; targetProxy = %s; }" % (app_target, proxy))
    obj(test_target, "{isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = (%s, %s, %s, ); "
                     "buildRules = ( ); dependencies = (%s, ); name = %s; productName = %s; productReference = %s; "
                     "productType = \"com.apple.product-type.bundle.unit-test\"; }"
        % (test_list, test_src_phase, test_fw_phase, test_res_phase, dependency, TESTS, TESTS, test_product))

    obj(project_id, "{isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; "
                    "LastSwiftUpdateCheck = 1600; LastUpgradeCheck = 1600; TargetAttributes = {%s = {CreatedOnToolsVersion = 16.0; }; "
                    "%s = {CreatedOnToolsVersion = 16.0; TestTargetID = %s; }; }; }; "
                    "buildConfigurationList = %s; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; "
                    "hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = %s; productRefGroup = %s; "
                    "projectDirPath = \"\"; projectRoot = \"\"; targets = (%s, %s, ); }"
        % (app_target, test_target, app_target, project_list, main_group, products_group, app_target, test_target))

    lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 60;",
             "\tobjects = {"]
    for oid, body in sorted(objects):
        lines.append("\t\t%s = %s;" % (oid, body))
    lines += ["\t};", "\trootObject = %s;" % project_id, "}", ""]

    proj_dir = os.path.join(ROOT, APP + ".xcodeproj")
    os.makedirs(os.path.join(proj_dir, "xcshareddata", "xcschemes"), exist_ok=True)
    with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
        f.write("\n".join(lines))
    with open(os.path.join(proj_dir, "xcshareddata", "xcschemes", APP + ".xcscheme"), "w") as f:
        f.write(SCHEME.format(app=APP, tests=TESTS, app_id=app_target, test_id=test_target))
    print("wrote", proj_dir, "with", len(app_sources), "app sources,", len(test_sources), "test sources")


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_id}" BuildableName = "{app}.app" BlueprintName = "{app}" ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{test_id}" BuildableName = "{tests}.xctest" BlueprintName = "{tests}" ReferencedContainer = "container:{app}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_id}" BuildableName = "{app}.app" BlueprintName = "{app}" ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_id}" BuildableName = "{app}.app" BlueprintName = "{app}" ReferencedContainer = "container:{app}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

if __name__ == "__main__":
    main()
