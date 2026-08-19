# 介绍

krkrsdl3的构建系统仓库，目前支持windows/linux/android/WebAssembly/HarmonyOS系统。

# 目录结构说明

```
📁android/    # 安卓工程文件夹
📁ohos/       # 鸿蒙工程文件夹
📁emscripten/ # wasm依赖外壳
📁cmake/        # cmake编译示例
├── 📄 cmake_console.txt # tjs2编译脚本
├── 📄 cmake_main.txt    # 全量编译脚本
📁cpp/        # 主要代码文件夹
📁Res/   # 程序资源文件
📁script # 各平台的程序构建脚本
📁vcpkg/ # 自定义vcpkg依赖
📄.clang-format # 格式化代码风格定义文件
📄CMakeLists.txt/CMakePresets.json # CMake配置文件
📄vcpkg.json/vcpkg-configuration.json # vcpkg配置文件
```

# 外部环境依赖

- cmake/ninja:跨平台构建工具
- vcpkg:包管理工具
- LLVM-MinGW/Visual Studio 2022:windows构建工具链
- Android SDK/Android NDK:安卓构建工具链
- Emscripten SDK:WebAssembly构建工具链
- DevEco Studio:鸿蒙开发工具

# 补充说明

系统越复杂问题就越难以排除，所以非必要时请保持当前的构建系统