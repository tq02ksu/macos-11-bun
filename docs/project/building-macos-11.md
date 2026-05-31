## 在 macOS 11 上构建 Bun

这份说明面向 **macOS 11.7.x（Intel/x64）** 的本地构建场景，目标是把已经验证过的路径整理成一份可操作的向导，而不是完整覆盖所有 macOS 环境。

## 环境信息

- 主机系统：macOS `11.7.11`
- 架构：`x86_64`
- 仓库基线：`bun v1.1.20`
- 已验证编译器：MacPorts LLVM 16
- 已验证 ICU 安装位置：`/opt/local`

## 存在的问题

- 默认构建流程可能选到 `/usr/bin/clang++`，而不是预期的 LLVM 16。
- 预编译 WebKit 在 macOS 11 上可能找不到或无法兼容本机安装的 ICU。
- 全局注入 `/opt/local/include` 容易污染头文件顺序，进而影响 BoringSSL。
- Bun 可能在编译期使用了外部 ICU 头文件，但链接阶段仍落回 `icucore`。
- WebKit 的二次重配可能把 `Debug` 悄悄回退成 `Release`。
- Cocoa 路径下的 WebKit 默认倾向于按 Apple ICU 语义编译，和外部 ICU 可能不一致。

## 构建路线

这套环境里，答案已经明确：**必须让 Bun 链接非系统 ICU**。

原因是当前官方预编译产物默认链接系统 ICU，但在 macOS 11 这套环境里，系统 ICU 与当前需要的 WebKit / ICU 组合并不兼容。

因此这份向导只保留一条已验证路径：**本地重编 WebKit，并让 Bun 与 WebKit 使用同一套外部 ICU**。

这条路线是当前已验证成功的路径。为了减少手工操作，**建议保留并使用仓库根目录的 `build_webkit.sh`**。它值得保留，因为它能明显简化这几件事：

- 自动定位可用的 ICU 前缀
- 自动定位 `clang`、`clang++`、`llvm-ar`、`ninja`
- 统一导出 `CC` / `CXX` / `AR` / ICU 相关环境变量
- 清掉容易把旧工具链带回来的环境变量
- 强制使用显式类型的 CMake 参数，避免 `Debug` 回退成 `Release`

相比之下，之前的 `run.sh` 只是在执行几条很短的 release 命令，**没有显著降低步骤复杂度**，因此不再保留。

### 第 1 步：编 WebKit 之前先清空旧缓存

`build_webkit.sh` 已经会自动删除目标 `WebKitBuild/<BuildType>` 目录，所以这里不需要手工再删一次。

### 第 2 步：先只做 configure

```bash
cd /path/to/bun
CONFIGURE_ONLY=1 ./build_webkit.sh
```

如果你不是用 MacPorts LLVM 16，或者 ICU 不在 `/opt/local`，可以先用环境变量覆盖：

```bash
CC=/path/to/clang
CXX=/path/to/clang++
AR=/path/to/llvm-ar
ICU_PREFIX=/path/to/icu
CONFIGURE_ONLY=1 ./build_webkit.sh
```

### 第 3 步：确认 configure 结果正确

```bash
grep 'CMAKE_BUILD_TYPE:' src/bun.js/WebKit/WebKitBuild/Debug/CMakeCache.txt
grep '/clang++' src/bun.js/WebKit/WebKitBuild/Debug/compile_commands.json | head
```

你要重点确认三件事：

- `CMAKE_BUILD_TYPE` 还是 `Debug`
- `compile_commands.json` 里的编译器已经统一到你想要的那套工具链
- ICU 路径来自同一套安装

### 第 4 步：正式编译本地 WebKit

```bash
./build_webkit.sh
```

### 第 5 步：确认 `jsc` 产物真的正确

```bash
test -f src/bun.js/WebKit/WebKitBuild/Debug/bin/jsc
otool -L src/bun.js/WebKit/WebKitBuild/Debug/bin/jsc | grep icu
```

你希望看到的是：

- `jsc` 已生成
- 链接到 `/opt/local/lib/libicudata*.dylib`
- 链接到 `/opt/local/lib/libicui18n*.dylib`
- 链接到 `/opt/local/lib/libicuuc*.dylib`
- 而不是 `libicucore.tbd`

### 第 6 步：让 Bun 主工程接入本地 WebKit

```bash
cmake -B build-local-webkit-debug -DWEBKIT_DIR="$PWD/src/bun.js/WebKit/WebKitBuild/Debug"
ninja -C build-local-webkit-debug
```

### 第 7 步：确认 Bun 主工程也吃到了同一套 ICU

```bash
test -f build-local-webkit-debug/bun-debug
otool -L build-local-webkit-debug/bun-debug | grep icu
```

你希望看到的是：

- `build-local-webkit-debug/bun-debug` 已生成
- `bun-debug` 链接到 `/opt/local/lib/libicui18n.78.dylib`
- `bun-debug` 链接到 `/opt/local/lib/libicuuc.78.dylib`
- `bun-debug` 链接到 `/opt/local/lib/libicudata.78.dylib`

## Release 编译方式

如果 `Debug` 路线已经打通，`Release` 可以沿用同一套方法，只是把构建目录和 `BUILD_TYPE` 切到 `Release`。

### 第 1 步：先只做 Release configure

```bash
cd /path/to/bun
BUILD_TYPE=Release CONFIGURE_ONLY=1 ./build_webkit.sh
```

### 第 2 步：确认 Release configure 结果正确

```bash
grep 'CMAKE_BUILD_TYPE:' src/bun.js/WebKit/WebKitBuild/Release/CMakeCache.txt
grep '/clang++' src/bun.js/WebKit/WebKitBuild/Release/compile_commands.json | head
```

这里仍然要确认三件事：

- `CMAKE_BUILD_TYPE` 是 `Release`
- `compile_commands.json` 里的编译器仍然是你预期的那套工具链
- ICU 路径仍然来自同一套安装

### 第 3 步：正式编译 Release WebKit

```bash
BUILD_TYPE=Release ./build_webkit.sh
```

### 第 4 步：确认 Release `jsc` 产物

```bash
test -f src/bun.js/WebKit/WebKitBuild/Release/bin/jsc
otool -L src/bun.js/WebKit/WebKitBuild/Release/bin/jsc | grep icu
```

### 第 5 步：让 Bun 主工程接入 Release WebKit

```bash
cmake -B build-local-webkit-release \
	-DCMAKE_BUILD_TYPE=Release \
	-DWEBKIT_DIR="$PWD/src/bun.js/WebKit/WebKitBuild/Release"

ninja -C build-local-webkit-release
```

### 第 6 步：确认 Release Bun 产物

```bash
test -f build-local-webkit-release/bun
otool -L build-local-webkit-release/bun | grep icu
```

如果需要额外确认 release 相关产物，也可以检查：

```bash
ls -l build-local-webkit-release/bun build-local-webkit-release/bun-profile
```

## 这条路径依赖了哪些代码改动

为了让路线 B 跑通，当前仓库里已经验证过以下几类修正：

- `CMakeLists.txt` 能识别并使用外部 ICU 的 include 与 library 路径
- `ZigGlobalObject.cpp` 中 `JSMap::clear(...)` 的调用已跟随本地 WebKit API 调整为传 `VM&`
- `ZigGlobalObject.cpp` 已补充 `JavaScriptCore/JSMapInlines.h`
- `SerializedScriptValue.cpp` 中 `JSMapIterator::create(...)` / `JSSetIterator::create(...)` 的首参已改为 `VM&`
- `workaround-missing-symbols.cpp` 里有针对当前 ICU 版本的兼容处理

## 结果判断

如果你已经完成以下两件事，就可以认为这条路径已经打通：

- `src/bun.js/WebKit/WebKitBuild/Debug/bin/jsc` 成功编成，并链接到外部 ICU
- `build-local-webkit-debug/bun-debug` 成功编成，并链接到同一套外部 ICU
- `src/bun.js/WebKit/WebKitBuild/Release/bin/jsc` 如需 release，也能成功编成并链接到同一套外部 ICU
- `build-local-webkit-release/bun` 如需 release，也能成功编成并链接到同一套外部 ICU

## 当前建议

- 当前环境直接走这条已验证路径，少绕弯路。
- `build_webkit.sh` 建议保留，因为它明显减少了出错步骤。
- `run.sh` 不再保留，因为它没有比直接执行命令更简单。
