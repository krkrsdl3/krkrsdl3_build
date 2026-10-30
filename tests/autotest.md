# 离屏自动化测试宿主（autotest）

给「不开窗口、不出声，按帧推进，随时截图，能点能打字，还能跑脚本」这套验证流程用的宿主模式。
自研取向：**无常驻服务、无网络**，一次跑一趟旅程，产物落成 PNG + 文本报告，
要改判据就改脚本再跑一遍。

- 引擎侧：`cpp/environ/PlatformAutoTest.h` + `cpp/environ/sdl3/sdl3_autotest.cpp`（SDL3 主循环与送显钩子）
- 脚本侧：`cpp/plugins/autotest.cpp`（ncbind 模块 `autotest.dll`，暴露全局 `AutoTest`）
- 启动器与示例旅程：`tests/run.py`、`tests/harness_boot.tjs`、`tests/harness_click.tjs`（本文档同目录）

---

## 0. 编译开关

整块能力由根 `CMakeLists.txt` 的 `option(ENABLE_AUTOTEST ... ON)` 控制，可以整块摘掉：

```
cmake -D ENABLE_AUTOTEST=OFF out/windows && cmake --build out/windows --config Release   # 发布构建：摘掉测试宿主
cmake -D ENABLE_AUTOTEST=ON  out/windows && cmake --build out/windows --config Release   # 日常/测试构建（默认）
```

（宏是全局 `add_definitions`，所以来回切换会触发整棵工程重新编译；源文件数 304 ↔ 302。）

关闭时的效果：
- `sdl3_autotest.cpp`、`plugins/autotest.cpp` 不进源文件列表（`cmake/cmake_environ.txt`、
  `cmake/cmake_plugins.txt`），`autotest.dll` 模块不注册，`AutoTest` 全局不存在；
- 宏 `_KRKRSDL3_AUTOTEST` 不定义，`PlatformAutoTest.h` 里的声明换成同名 `inline` 空实现，
  所以 `sdl3_app.cpp` / `TVPWindow.cpp` 的调用点不需要各自的 `#ifdef`，编译期就被折成常量
  （`nm` 查产物里 `TVPAutoTest*` 符号数量为 0，实测已验证）；
- `-offscreen` / `-silent` / `-frames` / `-dump` / `-at_harness` 变成无人读取的普通命令行项，
  游戏照原样启动。

---

## 1. 命令行开关

| 开关 | 作用 |
|---|---|
| `-offscreen` | 窗口带 `SDL_WINDOW_HIDDEN` 创建且始终不显示；同时**不**隐藏控制台，stdout 可以继续收日志 |
| `-silent` | 在 `SDL_Init` 前把 `SDL_AUDIO_DRIVER` 设成 `dummy`：音频链路照常走，声音不落地 |
| `-frames=N` | 呈现满 N 帧就收尾退出（脚本卡住时的硬上限） |
| `-dump=PATH` | 退出前把最后一帧写成图片（扩展名 `png` / `bmp`） |
| `-at_harness=PATH` | 游戏**正常启动之后**再执行这个本地 TJS 脚本，由它接管后续流程 |

既有的 `-render=software` / `-window=WxH` / `-vsync=0` / `-stretch=1` 都照常可用；
离屏跑建议 `-render=software -vsync=0`（最快最稳，且三种后端都能截图，各后端回读方式见 §5）。

完全无显示环境再加 `SDL_VIDEODRIVER=dummy`（`run.py --dummy`），已实测截图照样有效。

不带任何上述开关时，主循环与送显路径各自只剩一个恒假的 `TVPAutoTestActive()` 分支，
除此之外没有任何残留（`autotest.dll` 也不加载）；想连这个分支都不要，按 §0 用 `ENABLE_AUTOTEST=OFF` 重新配置——
`TVPAutoTestActive()` 在关闭的构建里是 `inline` 常量 false，整个块编译期就折没了。

## 2. AutoTest 脚本 API

宿主脚本第一行先 `Plugins.link("autotest.dll");`，之后全局 `AutoTest` 可用。
坐标一律是**窗口像素坐标**（和真实鼠标事件同一解释路径，letterbox 偏移与缩放由引擎换算）。

| 调用 | 含义 |
|---|---|
| `AutoTest.capture(path)` | 预约抓取 → 跑一帧 → 写成 png/bmp。刚注入的输入会算进这一帧 |
| `AutoTest.pump(n)` | 立即跑 n 个完整帧，返回实际跑过的帧数 |
| `AutoTest.frame()` | 已呈现帧数 |
| `AutoTest.checksum()` / `brightness()` | 最近一次 capture 那帧的 RGB 指纹（16 位十六进制）与平均亮度 0-255 |
| `AutoTest.size()` / `title()` / `offscreen()` | 窗口尺寸串、窗口标题、是否离屏 |
| `AutoTest.click(x, y)` / `rightClick` / `doubleClick` | 移动 + 按下 + 空跑两帧 + 松开，节奏与真人点击一致 |
| `AutoTest.moveTo(x, y)` / `mouseDown` / `mouseUp` / `wheel(x, y, dx, dy)` | 拆开用的原子输入 |
| `AutoTest.tapKey(name, hold)` / `keyDown(name)` / `keyUp(name)` | 按键，`name` 用 SDL 扫描码名（`RETURN` `ESCAPE` `SPACE` `LEFT` `A` `F1` …） |
| `AutoTest.type(text)` | 文本输入（走引擎的 IME 提交路径，可输中文） |
| `AutoTest.log(n)` | 引擎日志最后 n 行 |
| `AutoTest.write(path, text)` | 把文本写进本地文件（自己的报告/断言结果） |
| `AutoTest.lastError()` | 最近一次注入/导出的失败原因 |
| `AutoTest.quit()` | 结束进程 |

TJS2 字面量提醒：数组是 `[a, b]`（`.add()` / `.length`），字典是 `%[k: v]`——`%[...]` 不是数组。

## 3. run.py 启动器

```
python tests/run.py --game out/testgame/data.xp3 \
    --harness tests/harness_boot.tjs --frames 2400 --every 400
python tests/run.py --harness tests/harness_click.tjs \
    --click 90,310 --key ESCAPE --arg at_settle=90 --dummy
```

常用项：`--game`（默认 `out/testgame/data.xp3`）、`--harness`、`--out`（默认 `out/autotest/<时间戳>`）、
`--frames`、`--every`、`--click X,Y`（可重复）、`--key NAME`（可重复）、`--type 文本`、
`--arg K=V`（任意自定义旋钮，转成 `-K=V`）、`--window WxH`、`--renderer`、`--visible`、`--dummy`、
`--dump-last`、`--dry-run`。

跑完打印 `exit=`、产物 PNG 列表、`state.txt` 内容和 console.log 末尾。

## 4. 示例旅程

- `tests/harness_boot.tjs`：按 `-at_frames` 推进，每 `-at_every` 帧存一张 `boot_<帧号>.png`，
  再把帧号 / 标题 / 指纹 / 亮度逐帧记进 `state.txt`。用来看启动过程在哪一帧变成什么。
- `tests/harness_click.tjs`：稳定 `-at_frames` 帧后，依次注入 `-at_clicks` / `-at_keys` /
  `-at_type`，每步前后各截一图，`state.txt` 里给出 `changed=0/1` 与前后指纹——这一步到底有没有生效。

迭代方式：先跑 boot 找到目标画面 → 看图定坐标 → 用 click 旅程带坐标重跑 → 看 `changed` 与前后两图。

## 5. 已知边界

1. **三种后端都能截屏，只有一条取帧通路**：预约后在 `TVPWindow::PresentTexture` 里经渲染后端的
   `LockTexture` 拿像素（接口约定 RGBA、自上而下行序）。软渲染是 CPU 缓冲零拷贝；OpenGL 复用
   `LockTarget` 的目标回读（一般贴图则挂临时 FBO 读）；Vulkan 复用 image→staging 拷贝
   （一般贴图本身就是 host-visible 线性图像，直接给指针）。截图语义是**首窗口送显的合成内容帧**，
   不含 letterbox 黑边与次级窗口；窗口实际尺寸看 `AutoTest.size()`。
2. 抓帧是**按需**的：只有预约（`capture()`）后的那次送显才取像素；主循环与 `TVPWindow::PresentTexture`
   各自只留一个 `TVPAutoTestActive()` 分支，普通进游戏恒假、OFF 构建整块折掉。
   软渲染拿到的是合成缓冲的零拷贝指针，实测 1280x720 约 40 fps（早期"每帧回读渲染目标"的写法只有 15-18 fps）。
   `-dump` 例外：它要的就是最后一帧，所以持续保留最新送显帧。
   `checksum()` / `brightness()` 描述的是最近一次抓到的帧，不是"当前"帧。
3. `pump()` 从脚本里嵌套驱动主循环（与模态窗口 `TVPDrawSceneOnce` 同一条路径），
   所以脚本可以同步地"等 N 帧"；引擎计时器仍按墙钟推进，长旅程建议直接多跑帧而不是 sleep。
4. 要更快迭代可以 `--window 640x360`（注意点击坐标随之减半）。
5. `AutoTest.write` 走引擎文本流，落盘是 UTF-16LE（`run.py` 已按 BOM 自动识别）。
6. 测试宿主只在 SDL3、非 OHOS 且 `ENABLE_AUTOTEST=ON` 的构建里编译（§0；
   `cmake/cmake_environ.txt`、`cmake/cmake_plugins.txt`、`_KRKRSDL3_USE_SDL3` / `_KRKRSDL3_AUTOTEST` 宏）。
   其它平台与 SDL2 构建里，核心侧的调用点由头文件的 `inline` 空实现接住，不需要额外条件编译。
7. `-render=vulkan` 下**进程退出时会崩**（0xC0000374，与测试宿主无关：不带任何测试开关、可见窗口跑满
   `-frames` 也一样）。产物在崩溃前已经落盘，所以离屏旅程仍可用，但 `run.py` 的 `exit=` 不是 0。
