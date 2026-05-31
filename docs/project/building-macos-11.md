## 在 macOS 11 上构建 Bun

这份说明记录了一条在 **macOS 11.7.x（Intel/x64）** 上从源码构建 Bun 的本地排障路径。它的范围刻意比较窄：主要反映这次排查过程中在当前仓库里观察到的问题、做过的改动和得到的结论，而不是对 Bun 在所有 macOS 11 环境下的官方支持情况做统一说明。

## 环境信息

- 主机系统：macOS `11.7.11`
- 架构：`x86_64`
- 仓库：`oven-sh/bun` `bun-v1.1.20`
- Bun 主体构建使用的编译器：MacPorts LLVM 16
  - `CC=/opt/local/bin/clang-mp-16`
  - `CXX=/opt/local/bin/clang++-mp-16`
- ICU 通过 MacPorts 安装
  - 头文件：`/opt/local/include`
  - 库文件：`/opt/local/lib`

## 为什么 macOS 11 在这里比较棘手

这个环境里有三个问题会互相叠加：

1. Bun 默认的 macOS 源码构建路径，预期的是比当前主机更高一些的 Apple SDK / 运行时组合。
2. 预编译的 WebKit 制品和本机安装的 ICU，未必是按同一套 ICU ABI 构建出来的。
3. 如果 `WebKitBuild` 目录里残留了旧的缓存，本地重编 WebKit 时可能会悄悄使用一套和 Bun 主工程不同的编译器。

实际排障时，这意味着一次构建可能会因为多层原因同时失败；修掉上一层之后，下一层问题才会暴露出来。

## 观察到的失败现象

### 1. Release 构建选错了编译器

最开始的 release 构建失败，是因为 CMake 选中了 `/usr/bin/clang++` 的 AppleClang，而不是 LLVM 16。最早暴露出来的是 C++20 concepts 相关错误，比如 `std::same_as`、`std::invocable` 不存在。

**这个环境里的处理方式**

```bash
export CC=/opt/local/bin/clang-mp-16
export CXX=/opt/local/bin/clang++-mp-16
```

切换编译器之后，要删除对应的构建目录，避免 CMake 继续复用旧缓存里的编译器选择。

### 2. 在 macOS 上使用预编译 WebKit 时缺少 ICU 头文件

换成正确编译器之后，macOS 11 上的构建接着失败在 ICU 头文件缺失，例如 `unicode/uidna.h`。

为了让 Bun 能从 MacPorts 或 Homebrew 找到 ICU，本地在 `CMakeLists.txt` 里做了修改，让 Apple 平台构建能够识别：

- `ICU_INCLUDE_DIR`
- `ICU_LIBRARY_DIR`

这些值既可以来自环境变量，也可以从 `/opt/local`、Homebrew `icu4c` 等常见安装路径中自动发现。

### 3. `/opt/local/include` 引起的 include 路径污染

早期有一次尝试是直接导出比较宽泛的编译参数：

- `CPPFLAGS=-I/opt/local/include`
- `CFLAGS=-I/opt/local/include`
- `CXXFLAGS=-I/opt/local/include`
- `LDFLAGS=-L/opt/local/lib`

这样虽然短时间内解决了 ICU 头文件找不到的问题，但同时引入了新问题：MacPorts 的 OpenSSL 头文件被排到了 Bun 自带的 BoringSSL 头文件之前，最终出现宏重定义、类型冲突，以及 OpenSSL 废弃 API 警告被当成错误处理的情况。

**这里得到的结论是：** 不要全局把 `/opt/local/include` 强塞到最前面。只传 ICU 相关路径即可。

### 4. Bun 用了 MacPorts ICU 头文件，但仍然链接 `icucore`

在 include 顺序问题减轻之后，`bun setup` 可以走到 `bun-debug` 的最终链接阶段，但又因为 ICU 符号未定义而失败，例如带版本号的 `_uidna_nameToASCII_78`、`_u_hasBinaryProperty_78`。

这说明当时 Bun 在编译阶段已经使用了自定义 ICU 头文件，但链接阶段仍然走的是 Apple 的 `icucore`。

为了解决这一点，本地又修改了 `CMakeLists.txt`，让它在 macOS 下如果设置了 `ICU_LIBRARY_DIR`，就改为链接：

- `icui18n`
- `icuuc`
- `icudata`

而不是始终使用 `icucore`。

### 5. 预编译 WebKit 与本地 ICU 不匹配

当 Bun 的链接步骤切换到 MacPorts ICU 库之后，失败点再次后移。此时 `bun-debug` 仍然无法链接，但未定义符号的来源已经变成了：

- `bun-webkit/lib/libJavaScriptCore.a`
- `bun-webkit/lib/libWTF.a`

缺失的是未带版本号的 ICU 符号，例如 `udat_open`、`ucal_open`、`uidna_openUTS46` 等大量入口。

这说明 Bun 自己一侧的 ICU 链接已经更接近一致了，但当前链接进来的 **预编译 WebKit** 并不是针对本机这套 ICU 环境构建的。

## 排障过程中做过的本地代码和脚本改动

### `CMakeLists.txt`

本地调试过程中在这里做过的改动包括：

- 从环境变量或常见 MacPorts / Homebrew 路径中探测 ICU 头文件
- 从环境变量或 ICU 前缀目录中推导 ICU 库路径
- 延后注入 ICU include 目录，避免 `/opt/local/include` 抢在 Bun 自带 BoringSSL 之前
- 在 macOS 下如果设置了 `ICU_LIBRARY_DIR`，则链接 `icui18n`、`icuuc`、`icudata`

这些改动能让 Bun 识别并使用非系统 ICU，但**并不能**让预编译 WebKit 自动和这套 ICU 兼容。

### `run.sh`

本地辅助脚本最后被收敛成只导出 ICU 相关环境变量：

```bash
export CC=/opt/local/bin/clang-mp-16
export CXX=/opt/local/bin/clang++-mp-16
export ICU_INCLUDE_DIR=/opt/local/include
export ICU_LIBRARY_DIR=/opt/local/lib
```

之前那些指向 `/opt/local/include` 和 `/opt/local/lib` 的宽泛 `CPPFLAGS`、`CFLAGS`、`CXXFLAGS`、`LDFLAGS` 都被有意移除了。

### `src/bun.js/bindings/workaround-missing-symbols.cpp`

本地还做过一个实验性改动：给 ICU 78 加了一个 Apple 平台专用的 `ubrk_clone` 兼容 shim。它是调试过程中的一次尝试，但单独靠这个改动，并不能解决预编译 WebKit 和本地 ICU 不匹配的问题。

## 做过的尝试

### 尝试一：继续使用预编译 WebKit，同时接入自定义 ICU

结果：

- 解决了 ICU 头文件缺失问题
- 让 Bun 自身的一部分 ICU 链接问题向前推进了
- 但最终仍然在链接阶段失败，因为预编译 `JavaScriptCore` 和本地 ICU 不一致

### 尝试二：全局启用 MacPorts include 路径

结果：

- 短时间内解决了 ICU 头文件缺失
- 破坏了 BoringSSL / OpenSSL 头文件选择顺序
- 不是一个可持续的长期方案

### 尝试三：重编本地 WebKit

结果：

- 如果预编译 WebKit 无法和当前 ICU 环境共存，这个方向本身是对的
- 早期确实出现过 `WebKitBuild/Debug` 残留旧缓存、实际命令落到 Homebrew LLVM 的情况
- 但在清空 `WebKitBuild/Debug`、显式传入 `CC` / `CXX`、并重新生成 `compile_commands.json` 之后，**这个问题已经被纠正**

最新一次重新配置后，`compile_commands.json` 中已经可以看到 `LLIntOffsetsExtractor.cpp` 等目标改为使用：

```text
/opt/local/bin/clang++-mp-16
```

也就是说，**“WebKit 实际仍在使用 Homebrew LLVM 22” 这条判断已经过期**。当前更准确的状态是：

- 编译器污染已经清掉，Bun 主工程和本地 WebKit 的实际编译器已经统一到 MacPorts LLVM 16
- 但 WebKit 的二次重配过程中，`Source/cmake/WebKitCommon.cmake` 会打印 `No CMAKE_BUILD_TYPE value specified, defaulting to Release.`
- 因此即使构建目录名叫 `WebKitBuild/Debug`，缓存里的 `CMAKE_BUILD_TYPE` 仍可能被写成 `Release`

这意味着当前卡点已经从“编译器选错了”前移为“配置链在二次重配时丢失了 `Debug` 构建类型”。此前看到的源码级报错，例如：

- `Dispatcher::template inherits(from)`
- `.template taggedPtr()`

现在更应该优先放在 **Debug / Release 配置不一致** 的上下文里继续排查，而不是先假设仍然是 Homebrew LLVM 造成的。

继续往下排查后，这一层问题也已经被处理：

- `build_webkit.sh` 里的关键 CMake 参数改成了显式类型的 `-D...:TYPE=...`
- 重新配置后，`WebKitBuild/Debug` 不再在二次重配时悄悄退回 `Release`
- 配置输出能够稳定显示 `The CMake build type is: Debug`

接下来的真实阻塞点不再是 `BuildType`，而是 **WebKit 在 Cocoa 路径下默认按 Apple ICU 语义编译**。

具体表现为：虽然 `find_package(ICU)` 已经能找到 MacPorts 的 ICU 78.3，但 WebKit 代码里仍然有两层 Apple 假设：

- `Platform.h` 在 `PLATFORM(COCOA)` 下默认定义 `U_DISABLE_RENAMING=1`
- `Source/cmake/OptionsJSCOnly.cmake` 也会在 Apple/JSCOnly 路径下注入 `-DU_DISABLE_RENAMING=1`

这会导致源码按 **未重命名 ICU 符号** 编译，而链接阶段却已经切到 MacPorts ICU，最终在 `bin/jsc` 链接时出现大量未定义符号。

为了解决这一点，本地又做了两类配套改动：

- `build_webkit.sh` 显式传入 `-DUSE_APPLE_ICU=OFF`、`-DBUN_EXTERNAL_ICU=ON`，并把 ICU 头文件、库目录以及 `icui18n` / `icuuc` / `icudata` 的路径都指向 `/opt/local`
- WebKit 源码侧让 `BUN_EXTERNAL_ICU` 成为一个显式开关：启用后，不再强制定义 `U_DISABLE_RENAMING=1`

完成这些改动之后，本地 WebKit 的 `jsc` 已经成功编成，且确认链接到 MacPorts ICU，而不是 `libicucore.tbd`。

最终验证方式包括：

- `log_webkit_rebuild` 末尾为 `[2465/2465] Linking CXX executable bin/jsc`
- 产物存在：`src/bun.js/WebKit/WebKitBuild/Debug/bin/jsc`
- `otool -L` 显示：

```text
/opt/local/lib/libicudata.78.dylib
/opt/local/lib/libicui18n.78.dylib
/opt/local/lib/libicuuc.78.dylib
```

到这里可以认为：**本地 WebKit + MacPorts ICU 这条链路已经打通**。

## 当前判断

针对这个 macOS 11 环境，目前比较现实的是两条路线。

### 路线 A：继续使用预编译 WebKit

如果目标是尽量少偏离 Bun 默认的构建方式，优先考虑这条路线。

- 尽量不要启用自定义 ICU 链接覆盖
- 不要全局注入 `/opt/local/include`
- 尽量维持 Bun 默认的 macOS 链接路径
- 同时要接受 macOS 11 仍可能受 SDK 与 `icucore` 版本问题限制

这条路线最简单，但对较老的 macOS 主机来说也最不灵活。

### 路线 B：本地重编 WebKit，并保证整条链路一致

如果 Bun 必须在 macOS 11 上链接非系统 ICU，更适合走这条路线。

要求包括：

- Bun 和 WebKit 使用同一套编译器
- 重新配置前删除缓存的 `WebKitBuild/Debug` 或 `WebKitBuild/Release`
- 在真正开始编译前，先检查生成后的 `compile_commands.json`
- 让 `WEBKIT_DIR` 明确指向本地构建出来的 WebKit 输出目录

这次排查里，本地辅助脚本已经收敛为 `build_webkit.sh`，它会：

- 清空旧的 `WebKitBuild/Debug`
- 显式导出 `CC=/opt/local/bin/clang-mp-16` 和 `CXX=/opt/local/bin/clang++-mp-16`
- 清理一批可能把 Homebrew 工具链重新带回来的环境变量
- 显式关闭 `USE_APPLE_ICU`，并把 ICU 发现路径固定到 `/opt/local`
- 显式启用 `BUN_EXTERNAL_ICU`，让 WebKit 不再沿用 Apple ICU 的 `U_DISABLE_RENAMING=1` 语义
- 支持通过 `CONFIGURE_ONLY=1` 只做配置、不立刻进入完整编译

示例流程：

```bash
cd /Users/tq02ksu/workspace/oven-sh/bun

CONFIGURE_ONLY=1 ./build_webkit.sh

grep 'CMAKE_BUILD_TYPE:' src/bun.js/WebKit/WebKitBuild/Debug/CMakeCache.txt
grep '/opt/local/bin/clang++-mp-16' src/bun.js/WebKit/WebKitBuild/Debug/compile_commands.json | head

./build_webkit.sh

cmake -B build -DWEBKIT_DIR="$PWD/src/bun.js/WebKit/WebKitBuild/Debug"
ninja -C build
```

如果本地重新编了 WebKit，在继续排查源码级 WebKit 错误之前，先确认两件事：

- `compile_commands.json` 里的实际命令已经统一到 `/opt/local/bin/clang++-mp-16`
- `CMakeCache.txt` 里的 `CMAKE_BUILD_TYPE` 没有在二次重配后被悄悄改回 `Release`

如果本地 `jsc` 已经编成，还应再确认一件事：

- `otool -L src/bun.js/WebKit/WebKitBuild/Debug/bin/jsc` 指向的是 `/opt/local/lib/libicudata*.dylib`、`libicui18n*.dylib`、`libicuuc*.dylib`，而不是 `libicucore.tbd`

### 路线 B 的后续结果：Bun 主工程也已经接上本地 WebKit 并编成

在本地 `WebKitBuild/Debug/bin/jsc` 验证通过之后，下一步又让 Bun 主工程显式指向：

- `WEBKIT_DIR=/Users/tq02ksu/workspace/oven-sh/bun/src/bun.js/WebKit/WebKitBuild/Debug`

并在单独的构建目录里重新配置：

- `build-local-webkit-debug`

为了让这条链路真正跑通，本地又补了几类适配：

1. 顶层 `CMakeLists.txt` 在 **使用本地 WebKit** 的分支下，也要像预编译 WebKit 分支一样识别：

- `ICU_INCLUDE_DIR`
- `ICU_LIBRARY_DIR`

2. 这些 ICU 路径既要支持从环境变量读取，也要支持从显式 `-DICU_INCLUDE_DIR=...` / `-DICU_LIBRARY_DIR=...` 的 CMake cache 参数读取。
3. Bun 自身有少量源码调用点需要跟随这次本地 WebKit 的 JavaScriptCore 头文件 API 一起调整，例如：

- `ZigGlobalObject.cpp` 中 `JSMap::clear(...)` 的参数从 `JSGlobalObject*` 改成 `VM&`
- `ZigGlobalObject.cpp` 需要显式包含 `JavaScriptCore/JSMapInlines.h`，否则会触发 `HashMapImpl::clear` 的 `undefined-inline`
- `SerializedScriptValue.cpp` 中 `JSMapIterator::create(...)` / `JSSetIterator::create(...)` 的首参，也需要从 `JSGlobalObject*` 改为 `VM&`

这些修正完成之后，`build-local-webkit-debug` 里的 Bun 主工程已经成功编成。

最终验证结果包括：

- `build-local-webkit-debug/bun-debug` 已生成
- 日志末尾出现：`[135/136] Linking CXX executable bun-debug`
- `otool -L build-local-webkit-debug/bun-debug | grep icu` 显示：

```text
/opt/local/lib/libicui18n.78.dylib
/opt/local/lib/libicuuc.78.dylib
/opt/local/lib/libicudata.78.dylib
```

这说明当前这条链路已经不只是“本地 WebKit 能编成”，而是：

- **本地 WebKit + MacPorts ICU 78** 已经能被 Bun 主工程实际消费
- **`bun-debug` 已经在 macOS 11 上成功编成，并链接到 MacPorts ICU 78**

## 只编 release 的情况

`bun setup` 会固定先构建 `./build/bun-debug`。如果当前目标只是先验证 release 构建，可以跳过 `bun setup`，直接编 release。

```bash
export CC=/opt/local/bin/clang-mp-16
export CXX=/opt/local/bin/clang++-mp-16
export ICU_INCLUDE_DIR=/opt/local/include
export ICU_LIBRARY_DIR=/opt/local/lib

rm -rf build-release
bun run build:release
```

这样可以绕开 debug 构建本身，但**并不能保证** release 链接一定成功；如果 release 仍然混用了预编译 WebKit 和不兼容的本地 ICU，问题还是会出现。

## 总结

这次 macOS 11 排障过程中比较明确的几点是：

- Bun 和 WebKit 必须使用同一编译器家族，并且都要基于干净的 CMake 缓存重新配置。
- 仅仅看 `CMakeCache.txt` 还不够，最好同时检查 `compile_commands.json`，确认“实际生成的命令”确实使用了目标编译器。
- ICU 头文件和 ICU 库必须来自同一套安装。
- 全局导出 `/opt/local/include` 过于粗暴，容易把 BoringSSL 构建带偏。
- 把 Bun 自身切到自定义 ICU 库之后，Bun 这一侧可以更一致，但预编译 WebKit 仍可能保持不一致。
- 对本地 WebKit 来说，`CMAKE_BUILD_TYPE` 回退和 Apple ICU 假设这两层问题都已经被处理。
- 当前最新已确认结果是：`WebKitBuild/Debug/bin/jsc` 可以在 macOS 11 上成功编成，并链接到 MacPorts ICU 78。
- 当前最新已确认结果还包括：`build-local-webkit-debug/bun-debug` 也已经成功编成，并链接到 `/opt/local/lib/libicui18n.78.dylib`、`libicuuc.78.dylib`、`libicudata.78.dylib`。
- 对 macOS 11 这类较老环境来说，如果必须使用非系统 ICU，本地重编 WebKit 是更有希望走通的路径。

在当前这套环境里，`Debug` 路线已经完成验证；如果还要继续推进，下一步更自然的是基于同样的方法再验证 `Release` 构建。

如果未来这条流程要沉淀成上游支持的正式方案，建议在底层的 macOS 11 / ICU / WebKit 路径稳定之后，再把这份说明重新整理和简化。
