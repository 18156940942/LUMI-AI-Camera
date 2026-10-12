#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
LUMI AI Camera —— Xcode 工程文件生成器
=====================================

为什么不手动维护 project.pbxproj？
--------------------------------
pbxproj 是 Xcode 的私有格式，里面每一条记录都要靠 24 位十六进制 UUID 互相引用。
手写 / 手改的典型后果是：新增一个 .swift 文件忘了登记 → 编译报「找不到类型」，
而且报错信息完全指不到真正的病根。用生成器产出，可以保证：

  1. 磁盘上每一个 .swift 都在 Sources 构建阶段里（不会漏）；
  2. 资源文件都在 Resources 构建阶段里（不会漏 pose_library.json）；
  3. UUID 由「类型前缀 + 相对路径」的 MD5 前 24 位推出 —— 确定性、可复现、
     同一路径永远得到同一 UUID，因此重复运行不会产生 diff，也不会撞号。

用法：
    python3 scripts/generate_xcodeproj.py

生成物：
    LUMI.xcodeproj/project.pbxproj
    LUMI.xcodeproj/project.xcworkspace/contents.xcworkspacedata
    LUMI.xcodeproj/xcshareddata/xcschemes/LUMI.xcscheme
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

# ----------------------------------------------------------------------------
# 基本常量
# ----------------------------------------------------------------------------

PROJECT_NAME = "LUMI"
APP_TARGET = "LUMI"
TEST_TARGET = "LUMITests"

BUNDLE_ID = "com.lumi.aicamera"
TEST_BUNDLE_ID = "com.lumi.aicamera.tests"

DEPLOYMENT_TARGET = "17.0"   # iOS 17 起才有 AVCaptureDevice.DeviceType.external / 旋转协调器
SWIFT_VERSION = "5.0"
MARKETING_VERSION = "1.0.0"
CURRENT_PROJECT_VERSION = "1"

APP_GROUP_DIR = "LUMI"
TEST_GROUP_DIR = "LUMITests"

# 资源：相对仓库根
ASSETS_REL = "LUMI/Resources/Assets.xcassets"
POSE_LIBRARY_REL = "LUMI/Resources/pose_library.json"
INFO_PLIST_REL = "LUMI/Resources/Info.plist"

# 这两个目录不进 Xcode 工程（文档 / 外部工具脚本），避免污染 Build Phases
PRUNED_DIRS = {"docs", "scripts", "tools", ".github", ".git", ".workbuddy"}


# ----------------------------------------------------------------------------
# UUID 生成
# ----------------------------------------------------------------------------

def uid(*parts: str) -> str:
    """由若干字符串推出一个确定性的 24 位十六进制 UUID。

    加入类型前缀（parts[0]）是为了让「同一个路径」在充当不同角色时
    （例如既是 PBXFileReference 又是 PBXBuildFile）拿到不同 UUID。
    """
    key = "\x1f".join(parts)
    return hashlib.md5(key.encode("utf-8")).hexdigest()[:24].upper()


# 固定对象的 UUID
ROOT_OBJECT = uid("PBXProject", PROJECT_NAME)
MAIN_GROUP = uid("PBXGroup", "<main>")
PRODUCTS_GROUP = uid("PBXGroup", "Products")
APP_PRODUCT_REF = uid("PBXFileReference", "LUMI.app")
TEST_PRODUCT_REF = uid("PBXFileReference", "LUMITests.xctest")

APP_TARGET_ID = uid("PBXNativeTarget", APP_TARGET)
TEST_TARGET_ID = uid("PBXNativeTarget", TEST_TARGET)

APP_SOURCES_PHASE = uid("PBXSourcesBuildPhase", APP_TARGET)
APP_RESOURCES_PHASE = uid("PBXResourcesBuildPhase", APP_TARGET)
APP_FRAMEWORKS_PHASE = uid("PBXFrameworksBuildPhase", APP_TARGET)

TEST_SOURCES_PHASE = uid("PBXSourcesBuildPhase", TEST_TARGET)
TEST_RESOURCES_PHASE = uid("PBXResourcesBuildPhase", TEST_TARGET)
TEST_FRAMEWORKS_PHASE = uid("PBXFrameworksBuildPhase", TEST_TARGET)

APP_PRODUCT_DEP = uid("PBXTargetDependency", TEST_TARGET)
APP_PRODUCT_DEP_PROXY = uid("PBXContainerItemProxy", TEST_TARGET)

PROJ_CONFIG_LIST = uid("XCConfigurationList", "project")
APP_CONFIG_LIST = uid("XCConfigurationList", APP_TARGET)
TEST_CONFIG_LIST = uid("XCConfigurationList", TEST_TARGET)

PROJ_DEBUG = uid("XCBuildConfiguration", "project.Debug")
PROJ_RELEASE = uid("XCBuildConfiguration", "project.Release")
APP_DEBUG = uid("XCBuildConfiguration", f"{APP_TARGET}.Debug")
APP_RELEASE = uid("XCBuildConfiguration", f"{APP_TARGET}.Release")
TEST_DEBUG = uid("XCBuildConfiguration", f"{TEST_TARGET}.Debug")
TEST_RELEASE = uid("XCBuildConfiguration", f"{TEST_TARGET}.Release")


# ----------------------------------------------------------------------------
# 收集源文件
# ----------------------------------------------------------------------------

def collect_swift_files(root: Path, subdir: str) -> list[str]:
    """收集某一目录下所有 .swift，返回相对仓库根的 posix 路径，按路径排序。"""
    base = root / subdir
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(base):
        # 跳过被裁剪目录与隐藏目录
        dirnames[:] = sorted(d for d in dirnames if d not in PRUNED_DIRS and not d.startswith("."))
        for name in sorted(filenames):
            if name.endswith(".swift"):
                full = Path(dirpath) / name
                found.append(full.relative_to(root).as_posix())
    return sorted(found)


# ----------------------------------------------------------------------------
# pbxproj 文本构建
# ----------------------------------------------------------------------------

class PbxProjBuilder:
    def __init__(self, app_sources: list[str], test_sources: list[str]) -> None:
        self.app_sources = app_sources
        self.test_sources = test_sources
        # 目录树：group 路径 -> {children}
        self.groups: dict[str, dict] = {}

    # -- 目录树 --------------------------------------------------------------

    def _ensure_group_node(self, group_path: str) -> dict:
        if group_path not in self.groups:
            self.groups[group_path] = {"files": [], "subgroups": []}
        return self.groups[group_path]

    def build_group_tree(self) -> None:
        """为 app 与 test 源码按磁盘目录结构建出 group 树。"""
        for rel in self.app_sources + self.test_sources:
            parts = rel.split("/")
            filename = parts[-1]
            dirs = parts[:-1]
            # 逐级登记 group
            for depth in range(1, len(dirs) + 1):
                parent = "/".join(dirs[: depth - 1])
                child = "/".join(dirs[:depth])
                node = self._ensure_group_node(child)
                if parent != child:
                    pg = self._ensure_group_node(parent)
                    if child not in pg["subgroups"]:
                        pg["subgroups"].append(child)
            owner = "/".join(dirs)
            self._ensure_group_node(owner)["files"].append(rel)

        # 资源文件挂到 LUMI/Resources
        res_dir = f"{APP_GROUP_DIR}/Resources"
        self._ensure_group_node(res_dir)
        for rel in (ASSETS_REL, POSE_LIBRARY_REL):
            self._ensure_group_node(res_dir)["files"].append(rel)
        # 资源目录需要挂在 LUMI 下
        if res_dir not in self._ensure_group_node(APP_GROUP_DIR)["subgroups"]:
            self._ensure_group_node(APP_GROUP_DIR)["subgroups"].append(res_dir)

    # -- 各 section ----------------------------------------------------------

    def section_file_references(self) -> str:
        lines: list[str] = []
        # 产物
        lines.append(
            f"\t\t{APP_PRODUCT_REF} /* {APP_TARGET}.app */ = "
            f"{{isa = PBXFileReference; explicitFileType = wrapper.application; "
            f"includeInIndex = 0; path = {APP_TARGET}.app; sourceTree = BUILT_PRODUCTS_DIR; }};"
        )
        lines.append(
            f"\t\t{TEST_PRODUCT_REF} /* {TEST_TARGET}.xctest */ = "
            f"{{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; "
            f"includeInIndex = 0; path = {TEST_TARGET}.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};"
        )
        # Swift 源码
        for rel in self.app_sources + self.test_sources:
            fref = uid("PBXFileReference", rel)
            lines.append(
                f"\t\t{fref} /* {Path(rel).name} */ = {{isa = PBXFileReference; "
                f"lastKnownFileType = sourcecode.swift; path = {Path(rel).name}; "
                f"sourceTree = \"<group>\"; }};"
            )
        # 资源
        lines.append(
            f"\t\t{uid('PBXFileReference', ASSETS_REL)} /* Assets.xcassets */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; "
            f"path = Assets.xcassets; sourceTree = \"<group>\"; }};"
        )
        lines.append(
            f"\t\t{uid('PBXFileReference', POSE_LIBRARY_REL)} /* pose_library.json */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = text.json; "
            f"path = pose_library.json; sourceTree = \"<group>\"; }};"
        )
        # Info.plist —— 只是给 Xcode 侧栏能点开看，不进任何 Build Phase
        lines.append(
            f"\t\t{uid('PBXFileReference', INFO_PLIST_REL)} /* Info.plist */ = "
            f"{{isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
            f"path = Info.plist; sourceTree = \"<group>\"; }};"
        )
        return "\n".join(lines)

    def section_build_files(self) -> str:
        lines: list[str] = []
        for rel in self.app_sources:
            lines.append(
                f"\t\t{uid('PBXBuildFile', rel)} /* {Path(rel).name} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {uid('PBXFileReference', rel)} "
                f"/* {Path(rel).name} */; }};"
            )
        for rel in self.test_sources:
            lines.append(
                f"\t\t{uid('PBXBuildFile', rel)} /* {Path(rel).name} in Sources */ = "
                f"{{isa = PBXBuildFile; fileRef = {uid('PBXFileReference', rel)} "
                f"/* {Path(rel).name} */; }};"
            )
        for rel in (ASSETS_REL, POSE_LIBRARY_REL):
            name = Path(rel).name
            lines.append(
                f"\t\t{uid('PBXBuildFile', rel)} /* {name} in Resources */ = "
                f"{{isa = PBXBuildFile; fileRef = {uid('PBXFileReference', rel)} "
                f"/* {name} */; }};"
            )
        return "\n".join(lines)

    def section_groups(self) -> str:
        lines: list[str] = []

        # Products
        lines.append(
            f"\t\t{PRODUCTS_GROUP} /* Products */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"\t\t\t\t{APP_PRODUCT_REF} /* {APP_TARGET}.app */,\n"
            f"\t\t\t\t{TEST_PRODUCT_REF} /* {TEST_TARGET}.xctest */,\n"
            f"\t\t\t);\n"
            f"\t\t\tname = Products;\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )

        # mainGroup
        top_level = [APP_GROUP_DIR, TEST_GROUP_DIR]
        lines.append(
            f"\t\t{MAIN_GROUP} /* Main Group */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            + "".join(f"\t\t\t\t{uid('PBXGroup', g)} /* {g} */,\n" for g in top_level)
            + f"\t\t\t\t{PRODUCTS_GROUP} /* Products */,\n"
            f"\t\t\t);\n"
            f"\t\t\tsourceTree = \"<group>\";\n"
            f"\t\t}};"
        )

        # 每个目录一个 group
        for group_path in sorted(self.groups):
            node = self.groups[group_path]
            gid = uid("PBXGroup", group_path)
            name = group_path.split("/")[-1]
            children: list[str] = []
            for sub in sorted(node["subgroups"]):
                children.append(f"\t\t\t\t{uid('PBXGroup', sub)} /* {sub.split('/')[-1]} */,\n")
            for rel in sorted(node["files"]):
                children.append(
                    f"\t\t\t\t{uid('PBXFileReference', rel)} /* {Path(rel).name} */,\n"
                )
            lines.append(
                f"\t\t{gid} /* {name} */ = {{\n"
                f"\t\t\tisa = PBXGroup;\n"
                f"\t\t\tchildren = (\n"
                + "".join(children)
                + f"\t\t\t);\n"
                f"\t\t\tpath = {name};\n"
                f"\t\t\tsourceTree = \"<group>\";\n"
                f"\t\t}};"
            )
        return "\n".join(lines)

    def section_native_targets(self) -> str:
        app_src = "".join(
            f"\t\t\t\t{uid('PBXBuildFile', r)} /* {Path(r).name} in Sources */,\n"
            for r in self.app_sources
        )
        app_res = "".join(
            f"\t\t\t\t{uid('PBXBuildFile', r)} /* {Path(r).name} in Resources */,\n"
            for r in (ASSETS_REL, POSE_LIBRARY_REL)
        )
        test_src = "".join(
            f"\t\t\t\t{uid('PBXBuildFile', r)} /* {Path(r).name} in Sources */,\n"
            for r in self.test_sources
        )
        return (
            f"\t\t{APP_TARGET_ID} /* {APP_TARGET} */ = {{\n"
            f"\t\t\tisa = PBXNativeTarget;\n"
            f"\t\t\tbuildConfigurationList = {APP_CONFIG_LIST} "
            f"/* Build configuration list for PBXNativeTarget \"{APP_TARGET}\" */;\n"
            f"\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{APP_SOURCES_PHASE} /* Sources */,\n"
            f"\t\t\t\t{APP_FRAMEWORKS_PHASE} /* Frameworks */,\n"
            f"\t\t\t\t{APP_RESOURCES_PHASE} /* Resources */,\n"
            f"\t\t\t);\n"
            f"\t\t\tbuildRules = (\n\t\t\t);\n"
            f"\t\t\tdependencies = (\n\t\t\t);\n"
            f"\t\t\tname = {APP_TARGET};\n"
            f"\t\t\tproductName = {APP_TARGET};\n"
            f"\t\t\tproductReference = {APP_PRODUCT_REF} /* {APP_TARGET}.app */;\n"
            f"\t\t\tproductType = \"com.apple.product-type.application\";\n"
            f"\t\t}};\n"
            f"\t\t{TEST_TARGET_ID} /* {TEST_TARGET} */ = {{\n"
            f"\t\t\tisa = PBXNativeTarget;\n"
            f"\t\t\tbuildConfigurationList = {TEST_CONFIG_LIST} "
            f"/* Build configuration list for PBXNativeTarget \"{TEST_TARGET}\" */;\n"
            f"\t\t\tbuildPhases = (\n"
            f"\t\t\t\t{TEST_SOURCES_PHASE} /* Sources */,\n"
            f"\t\t\t\t{TEST_FRAMEWORKS_PHASE} /* Frameworks */,\n"
            f"\t\t\t\t{TEST_RESOURCES_PHASE} /* Resources */,\n"
            f"\t\t\t);\n"
            f"\t\t\tbuildRules = (\n\t\t\t);\n"
            f"\t\t\tdependencies = (\n"
            f"\t\t\t\t{APP_PRODUCT_DEP} /* PBXTargetDependency */,\n"
            f"\t\t\t);\n"
            f"\t\t\tname = {TEST_TARGET};\n"
            f"\t\t\tproductName = {TEST_TARGET};\n"
            f"\t\t\tproductReference = {TEST_PRODUCT_REF} /* {TEST_TARGET}.xctest */;\n"
            f"\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";\n"
            f"\t\t}};"
        )

    def build_phase_blocks(self) -> dict[str, str]:
        """返回 {'Sources': text, 'Frameworks': text, 'Resources': text}。

        每个 block 内部已经自带正确的两/三级缩进，调用方按 section 顺序拼接即可，
        不做任何字符串切分，从根上避免缩进错位。
        """

        def phase(pid: str, label: str, isa: str, files: list[tuple[str, str]]) -> str:
            body = "".join(f"\t\t\t\t{bid} /* {name} */,\n" for bid, name in files)
            return (
                f"\t\t{pid} /* {label} */ = {{\n"
                f"\t\t\tisa = {isa};\n"
                f"\t\t\tbuildActionMask = 2147483647;\n"
                f"\t\t\tfiles = (\n"
                f"{body}"
                f"\t\t\t);\n"
                f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
                f"\t\t}};"
            )

        app_src_files = [
            (uid("PBXBuildFile", r), f"{Path(r).name} in Sources") for r in self.app_sources
        ]
        app_res_files = [
            (uid("PBXBuildFile", r), f"{Path(r).name} in Resources")
            for r in (ASSETS_REL, POSE_LIBRARY_REL)
        ]
        test_src_files = [
            (uid("PBXBuildFile", r), f"{Path(r).name} in Sources") for r in self.test_sources
        ]

        return {
            "Sources": "\n".join([
                phase(APP_SOURCES_PHASE, "Sources", "PBXSourcesBuildPhase", app_src_files),
                phase(TEST_SOURCES_PHASE, "Sources", "PBXSourcesBuildPhase", test_src_files),
            ]),
            # Frameworks 留空数组：Swift 会自动链接用到的系统框架
            # （AVFoundation / Vision / PhotosUI / CoreImage），不需要显式 SDK 引用，
            # 显式加反而容易在换 Xcode 版本时失效。
            "Frameworks": "\n".join([
                phase(APP_FRAMEWORKS_PHASE, "Frameworks", "PBXFrameworksBuildPhase", []),
                phase(TEST_FRAMEWORKS_PHASE, "Frameworks", "PBXFrameworksBuildPhase", []),
            ]),
            "Resources": "\n".join([
                phase(APP_RESOURCES_PHASE, "Resources", "PBXResourcesBuildPhase", app_res_files),
                phase(TEST_RESOURCES_PHASE, "Resources", "PBXResourcesBuildPhase", []),
            ]),
        }

    def section_project(self) -> str:
        return (
            f"\t\t{ROOT_OBJECT} /* Project object */ = {{\n"
            f"\t\t\tisa = PBXProject;\n"
            f"\t\t\tattributes = {{\n"
            f"\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
            f"\t\t\t\tLastSwiftUpdateCheck = 1500;\n"
            f"\t\t\t\tLastUpgradeCheck = 1500;\n"
            f"\t\t\t\tTargetAttributes = {{\n"
            f"\t\t\t\t\t{APP_TARGET_ID} = {{\n"
            f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
            f"\t\t\t\t\t}};\n"
            f"\t\t\t\t\t{TEST_TARGET_ID} = {{\n"
            f"\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
            f"\t\t\t\t\t\tTestTargetID = {APP_TARGET_ID};\n"
            f"\t\t\t\t\t}};\n"
            f"\t\t\t\t}};\n"
            f"\t\t\t}};\n"
            f"\t\t\tbuildConfigurationList = {PROJ_CONFIG_LIST} "
            f"/* Build configuration list for PBXProject \"{PROJECT_NAME}\" */;\n"
            f"\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
            f"\t\t\tdevelopmentRegion = zh_CN;\n"
            f"\t\t\thasScannedForEncodings = 0;\n"
            f"\t\t\tknownRegions = (\n\t\t\t\tzh_CN,\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n"
            f"\t\t\tmainGroup = {MAIN_GROUP};\n"
            f"\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;\n"
            f"\t\t\tprojectDirPath = \"\";\n"
            f"\t\t\tprojectRoot = \"\";\n"
            f"\t\t\ttargets = (\n"
            f"\t\t\t\t{APP_TARGET_ID} /* {APP_TARGET} */,\n"
            f"\t\t\t\t{TEST_TARGET_ID} /* {TEST_TARGET} */,\n"
            f"\t\t\t);\n"
            f"\t\t}};"
        )

    def section_dependencies(self) -> str:
        return (
            f"\t\t{APP_PRODUCT_DEP} /* PBXTargetDependency */ = {{\n"
            f"\t\t\tisa = PBXTargetDependency;\n"
            f"\t\t\ttarget = {APP_TARGET_ID} /* {APP_TARGET} */;\n"
            f"\t\t\ttargetProxy = {APP_PRODUCT_DEP_PROXY} /* PBXContainerItemProxy */;\n"
            f"\t\t}};\n"
            f"\t\t{APP_PRODUCT_DEP_PROXY} /* PBXContainerItemProxy */ = {{\n"
            f"\t\t\tisa = PBXContainerItemProxy;\n"
            f"\t\t\tcontainerPortal = {ROOT_OBJECT} /* Project object */;\n"
            f"\t\t\tproxyType = 1;\n"
            f"\t\t\tremoteGlobalIDString = {APP_TARGET_ID};\n"
            f"\t\t\tremoteInfo = {APP_TARGET};\n"
            f"\t\t}};"
        )

    def section_build_configurations(self) -> str:
        common_project = {
            "ALWAYS_SEARCH_USER_PATHS": "NO",
            "CLANG_ANALYZER_NONNULL": "YES",
            "CLANG_ENABLE_MODULES": "YES",
            "CLANG_ENABLE_OBJC_ARC": "YES",
            "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING": "YES",
            "CLANG_WARN_BOOL_CONVERSION": "YES",
            "CLANG_WARN_COMMA": "YES",
            "CLANG_WARN_CONSTANT_CONVERSION": "YES",
            "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
            "CLANG_WARN_DIRECT_OBJC_ISA_USAGE": "YES",
            "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
            "CLANG_WARN_EMPTY_BODY": "YES",
            "CLANG_WARN_ENUM_CONVERSION": "YES",
            "CLANG_WARN_INFINITE_RECURSION": "YES",
            "CLANG_WARN_INT_CONVERSION": "YES",
            "CLANG_WARN_NON_LITERAL_NULL_CONVERSION": "YES",
            "CLANG_WARN_OBJC_LITERAL_CONVERSION": "YES",
            "CLANG_WARN_OBJC_ROOT_CLASS": "YES",
            "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "YES",
            "CLANG_WARN_RANGE_LOOP_ANALYSIS": "YES",
            "CLANG_WARN_STRICT_PROTOTYPES": "YES",
            "CLANG_WARN_SUSPICIOUS_MOVE": "YES",
            "CLANG_WARN_UNGUARDED_AVAILABILITY": "YES_AGGRESSIVE",
            "CLANG_WARN_UNREACHABLE_CODE": "YES",
            "CLANG_WARN__DUPLICATE_METHOD_MATCH": "YES",
            "COPY_PHASE_STRIP": "NO",
            "ENABLE_STRICT_OBJC_MSGSEND": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "GCC_C_LANGUAGE_STANDARD": "gnu17",
            "GCC_NO_COMMON_BLOCKS": "YES",
            "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES",
            "GCC_WARN_ABOUT_RETURN_TYPE": "YES",
            "GCC_WARN_UNDECLARED_SELECTOR": "YES",
            "GCC_WARN_UNINITIALIZED_AUTOS": "YES",
            "GCC_WARN_UNUSED_FUNCTION": "YES",
            "GCC_WARN_UNUSED_VARIABLE": "YES",
            "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
            "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
            "MTL_FAST_MATH": "YES",
            "SDKROOT": "iphoneos",
            "SWIFT_VERSION": SWIFT_VERSION,
            "TARGETED_DEVICE_FAMILY": '"1,2"',
        }
        debug_only = {
            "DEBUG_INFORMATION_FORMAT": "dwarf",
            "ENABLE_TESTABILITY": "YES",
            "GCC_DYNAMIC_NO_PIC": "NO",
            "GCC_OPTIMIZATION_LEVEL": "0",
            "GCC_PREPROCESSOR_DEFINITIONS": '(\n\t\t\t\t\t"DEBUG=1",\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t)',
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE",
            "ONLY_ACTIVE_ARCH": "YES",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
            "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"',
        }
        release_only = {
            "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
            "ENABLE_NS_ASSERTIONS": "NO",
            "MTL_ENABLE_DEBUG_INFO": "NO",
            "SWIFT_COMPILATION_MODE": "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": '"-O"',
            "VALIDATE_PRODUCT": "YES",
        }

        def render(entries: dict[str, str], indent: str = "\t\t\t") -> str:
            return "".join(f"{indent}{k} = {v};\n" for k, v in entries.items())

        app_target_common = {
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": CURRENT_PROJECT_VERSION,
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": INFO_PLIST_REL,
            "LD_RUNPATH_SEARCH_PATHS": '(\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"@executable_path/Frameworks",\n\t\t\t\t)',
            "MARKETING_VERSION": MARKETING_VERSION,
            "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID,
            "PRODUCT_NAME": '"$(TARGET_NAME)"',
            "SWIFT_EMIT_LOC_STRINGS": "YES",
            "TARGETED_DEVICE_FAMILY": '"1,2"',
        }
        test_target_common = {
            "ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES": "YES",
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": CURRENT_PROJECT_VERSION,
            "GENERATE_INFOPLIST_FILE": "YES",
            "MARKETING_VERSION": MARKETING_VERSION,
            "PRODUCT_BUNDLE_IDENTIFIER": TEST_BUNDLE_ID,
            "PRODUCT_NAME": '"$(TARGET_NAME)"',
            "SWIFT_EMIT_LOC_STRINGS": "NO",
            "TARGETED_DEVICE_FAMILY": '"1,2"',
            "TEST_HOST": f'"$(BUILT_PRODUCTS_DIR)/{APP_TARGET}.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/{APP_TARGET}"',
            "BUNDLE_LOADER": '"$(TEST_HOST)"',
        }

        blocks: list[str] = []

        def config(cid: str, name: str, entries: dict[str, str]) -> str:
            return (
                f"\t\t{cid} /* {name} */ = {{\n"
                f"\t\t\tisa = XCBuildConfiguration;\n"
                f"\t\t\tbuildSettings = {{\n"
                + render(entries)
                + f"\t\t\t}};\n"
                f"\t\t\tname = {name};\n"
                f"\t\t}};"
            )

        blocks.append(config(PROJ_DEBUG, "Debug", {**common_project, **debug_only}))
        blocks.append(config(PROJ_RELEASE, "Release", {**common_project, **release_only}))
        blocks.append(config(APP_DEBUG, "Debug", dict(app_target_common)))
        blocks.append(config(APP_RELEASE, "Release", dict(app_target_common)))
        blocks.append(config(TEST_DEBUG, "Debug", dict(test_target_common)))
        blocks.append(config(TEST_RELEASE, "Release", dict(test_target_common)))
        return "\n".join(blocks)

    def section_config_lists(self) -> str:
        def lst(cid: str, label: str, debug: str, release: str, default: str) -> str:
            return (
                f"\t\t{cid} /* Build configuration list for {label} */ = {{\n"
                f"\t\t\tisa = XCConfigurationList;\n"
                f"\t\t\tbuildConfigurations = (\n"
                f"\t\t\t\t{debug} /* Debug */,\n"
                f"\t\t\t\t{release} /* Release */,\n"
                f"\t\t\t);\n"
                f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
                f"\t\t\tdefaultConfigurationName = {default};\n"
                f"\t\t}};"
            )

        return "\n".join([
            lst(PROJ_CONFIG_LIST, f'PBXProject "{PROJECT_NAME}"', PROJ_DEBUG, PROJ_RELEASE, "Release"),
            lst(APP_CONFIG_LIST, f'PBXNativeTarget "{APP_TARGET}"', APP_DEBUG, APP_RELEASE, "Release"),
            lst(TEST_CONFIG_LIST, f'PBXNativeTarget "{TEST_TARGET}"', TEST_DEBUG, TEST_RELEASE, "Release"),
        ])

    # -- 组装 ----------------------------------------------------------------

    def render(self) -> str:
        phases = self.build_phase_blocks()
        deps_full = self.section_dependencies()
        dep_block, proxy_block = deps_full.split("\n", 1)

        sections: list[tuple[str, str]] = [
            ("PBXBuildFile", self.section_build_files()),
            ("PBXContainerItemProxy", proxy_block),
            ("PBXFileReference", self.section_file_references()),
            ("PBXFrameworksBuildPhase", phases["Frameworks"]),
            ("PBXGroup", self.section_groups()),
            ("PBXNativeTarget", self.section_native_targets()),
            ("PBXProject", self.section_project()),
            ("PBXResourcesBuildPhase", phases["Resources"]),
            ("PBXSourcesBuildPhase", phases["Sources"]),
            ("PBXTargetDependency", dep_block),
            ("XCBuildConfiguration", self.section_build_configurations()),
            ("XCConfigurationList", self.section_config_lists()),
        ]

        out: list[str] = []
        out.append("// !$*UTF8*$!")
        out.append("{")
        out.append("\tarchiveVersion = 1;")
        out.append("\tclasses = {\n\t};")
        out.append("\tobjectVersion = 56;")
        out.append("\tobjects = {\n")
        for name, body in sections:
            out.append(f"/* Begin {name} section */")
            out.append(body)
            out.append(f"/* End {name} section */\n")
        out.append("\t};")
        out.append(f"\trootObject = {ROOT_OBJECT} /* Project object */;")
        out.append("}")
        return "\n".join(out) + "\n"


# ----------------------------------------------------------------------------
# 附加文件
# ----------------------------------------------------------------------------

WORKSPACE_DATA = """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""


def scheme_xml(app_target: str, test_target: str, project_name: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{APP_TARGET_ID}"
               BuildableName = "{app_target}.app"
               BlueprintName = "{app_target}"
               ReferencedContainer = "container:{project_name}.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{TEST_TARGET_ID}"
               BuildableName = "{test_target}.xctest"
               BlueprintName = "{test_target}"
               ReferencedContainer = "container:{project_name}.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
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
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET_ID}"
            BuildableName = "{app_target}.app"
            BlueprintName = "{app_target}"
            ReferencedContainer = "container:{project_name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{APP_TARGET_ID}"
            BuildableName = "{app_target}.app"
            BlueprintName = "{app_target}"
            ReferencedContainer = "container:{project_name}.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

def main() -> int:
    root = Path(__file__).resolve().parent.parent
    print(f"[LUMI] 项目根目录: {root}")

    app_sources = collect_swift_files(root, APP_GROUP_DIR)
    test_sources = collect_swift_files(root, TEST_GROUP_DIR)

    if not app_sources:
        print("!! 没找到任何 App 源码，检查工作目录", file=sys.stderr)
        return 1
    if not test_sources:
        print("!! 没找到任何测试源码（LUMITests/*.swift），继续生成但测试目标会是空的", file=sys.stderr)

    print(f"[LUMI] App 源文件 {len(app_sources)} 个")
    for rel in app_sources:
        print(f"        · {rel}")
    print(f"[LUMI] 测试文件 {len(test_sources)} 个")
    for rel in test_sources:
        print(f"        · {rel}")

    builder = PbxProjBuilder(app_sources, test_sources)
    builder.build_group_tree()
    content = builder.render()

    proj_dir = root / f"{PROJECT_NAME}.xcodeproj"
    (proj_dir / "project.xcworkspace").mkdir(parents=True, exist_ok=True)
    (proj_dir / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)

    (proj_dir / "project.pbxproj").write_text(content, encoding="utf-8")
    (proj_dir / "project.xcworkspace" / "contents.xcworkspacedata").write_text(
        WORKSPACE_DATA, encoding="utf-8"
    )
    (proj_dir / "xcshareddata" / "xcschemes" / f"{APP_TARGET}.xcscheme").write_text(
        scheme_xml(APP_TARGET, TEST_TARGET, PROJECT_NAME), encoding="utf-8"
    )

    print(f"[LUMI] 已写出 {proj_dir}/project.pbxproj "
          f"({len(content)} 字节, {content.count(chr(10))} 行)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
