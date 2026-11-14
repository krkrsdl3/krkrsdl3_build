# krkrsdl3 渲染后端抽象层（iTVPRenderBackend）

> 面向贡献者：本文是渲染后端抽象层的唯一说明——接口语义、上传/提交契约、
> 三个后端（OpenGL / 软件 / Vulkan）的实现要点、性能模型，以及后续演进方向。
> 渲染体系的数据流与分层见 `docs/rendering-system.md`；
> DrawDeviceD3D 的合成逻辑见 `docs/drawdevice-d3d.md`。

---

## 1. 定位与设计目标

### 1.1 分层职责

引擎的图层合成内核（`RenderManager`）**始终是软件渲染**：文字、PS 混合、
模糊、gamma、转场等只有 CPU 实现，图层树在 CPU 上合成出一张 DrawBuffer。
抽象层只负责把这张 CPU 结果与少量 GPU 直通内容（D3D 层、emote 网格）
合成上屏。整体分三层：

| 层 | 内容 | 主要使用者 |
|---|---|---|
| 窗口合成 | 交换链/窗口表面 + 统一 letterbox | `TVPRenderOnce`（合成器） |
| 2D 网格 | 离屏目标 + 贴图 + 蒙版/混合 + `DrawMesh` | emoteplayer 等插件 |
| Layer 合成 | 矩形合成，混合公式对齐软件 `RenderManager` | DrawDeviceD3D |

### 1.2 后端分工

- **OpenGL/OpenGL ES**：旧硬件兜底。立即模式、`glTexSubImage2D` 上传、
  FBO 离屏目标，行为与历史实现一致，不引入额外同步。
- **Vulkan**：面向新硬件。显式内存/提交模型，CPU 不在热路径等待 GPU，
  命令与上传在帧内攒批。
- **软件后端**：无 GPU / 回退路径，CPU 光栅化 + SDL 纹理。

### 1.3 抽象原则

1. 除入口（`environ/*`）与 `core/render` 外，业务代码不允许出现后端分支。
2. 贴图/目标句柄是不透明 `void*`，由后端分配与释放。
3. **抽象层只承诺语义，不暴露同步方式**：同一份调用序列在 GL 与 VK 下
   结果一致，同步由后端内部消化（详见 §3）。
4. 坐标、字节序、行序统一（见 §7），三后端回读结果同构。

---

## 2. 接口（合并设计）

接口声明在 `cpp/core/render/TVPCompositor.h`。一个类同时承担窗口合成、
2D 网格、Layer 合成三个角色，避免插件与上层依赖多个渲染器实例。

```cpp
class iTVPRenderBackend {
    GetName() / IsHardware() / FetchInfo()

    // ---- 窗口合成（由 TVPRenderOnce 调度）----
    BeginFrame(w, h) / EndFrame()                  // 取交换链 → 绘制 → 提交/呈现
    CreateWindowTexture / UpdateWindowTexture / DestroyWindowTexture
    DrawWindowTexture(handle, x, y, w, h)          // 像素坐标，letterbox 已算好

    // ---- 2D 网格 ----
    CreateTarget / DestroyTarget / SetTarget / ClearTarget
    LockTarget / UnlockTarget
    GetTargetTexture(target)                       // 目标作为采样源
    UpdateTargetTexture(target, pixels, w, h, pitch)
    CreateTexture / UpdateTexture / DestroyTexture / LockTexture

    // ---- 网格与 Layer 绘制 ----
    SetMask(target)
    SetBlendMode(mode, uniformColor)               // 0/1/3/4/6/21（emote 约定）
    DrawMesh(verts, nVerts, idx, nIdx, tex, opacity, colorModulation)
    LayerSetBlend(method, opacity, uniformColor)   // 软件 RenderManager 语义
    LayerDrawRect(tex, x, y, w, h, u0, v0, u1, v1)
};
```

### 2.1 两套混合语义

- `SetBlendMode + DrawMesh`：emoteplayer 约定（0 普通 / 1,4 乘色 / 3 加色 /
  21 纯色替换 / 6 跳过）。
- `LayerSetBlend + LayerDrawRect`：软件 `RenderManager`（`gl/tvpgl.cpp` 的
  bm* 方法）语义，含 `>>8` 截断、`LBM_MUL_HDA`、`LBM_COPYMASK` 等，
  三后端允许 ±1 舍入误差。
- 两套语义不可混用；坐标与 UV 约定见 §7。

### 2.2 窗口贴图与离屏目标

- GPU 后端下窗口贴图与一般贴图是同一套纹理实现
  （`CreateWindowTexture == CreateTexture`）。
- 窗口呈现采用"目标纹理别名"：GPU 路径下 `TVPWindow::PresentTexture`
  直接把合成目标的目标纹理交给窗口 sprite（`borrowedTexture`，零拷贝），
  `TVPRenderOnce` 再用 `DrawWindowTexture` 画到交换链；
  软件路径则回读目标后上传窗口贴图。
- 句柄生命周期：借用的纹理不由 sprite 销毁；后端切换/目标销毁前必须
  先 `ReleaseBorrowedTexture()`（见 `docs/gpu-readback-design.md`）。

---

## 3. 上传与提交契约（核心）

### 3.1 契约

1. `UpdateTexture/UpdateWindowTexture/UpdateTargetTexture` 是
   "CPU 像素 → 后端存储"的**入队**操作。调用返回后数据对本帧后续绘制可见，
   但**不保证 GPU 已执行完**。
2. 绘制与上传按调用顺序形成依赖；同一逻辑帧内的上传/绘制可以由后端
   合并成一次或多次提交。
3. 稳态帧内 CPU 不应等待 GPU。只有显式回读（`LockTarget/LockTexture`）
   允许阻塞。

GL 的 `glTexSubImage2D` 天然满足 1-3；Vulkan 需要后端自己维护暂存、
提交边界与依赖，不能把"同步"推给调用方。

### 3.2 两个后端的落地方式

| 环节 | OpenGL（旧硬件） | Vulkan（新硬件） |
|---|---|---|
| 上传 | `glTexSubImage2D` 立即入驱动队列 | 主机可见图像写入 + 提交边界内的 GPU 拷贝（目标态：设备本地 optimal 图 + 暂存环） |
| 采样图 | 驱动内部 tiling | 线性图直接采样（现状）/ `TILING_OPTIMAL`（目标态） |
| 同步 | 驱动保证 | 同提交写后读 → 提交；跨提交 → 队列顺序 / 二值信号量 |
| 回读 | `glReadPixels` | staging + fence，显式且低频 |

### 3.3 Vulkan 后端当前实现

`cpp/core/render/backend/VulkanRenderBackend.cpp` 的热路径已去掉逐 pass 同步：

1. **不做"每个新 pass 提交并等待"**。只有要采样"本 command buffer 内刚写过"
   的目标图像时才 `FlushMeshCommands()`（RADV 会忽略 GENERAL→GENERAL 的
   同提交 image barrier，跨提交边界才可靠）。为做到这一点，
   `writtenImages_` 记录当前命令缓冲写过的目标，`sampledImages_` 记录
   采样源，`presentedImages_` 记录上一帧上屏的贴图。
2. **同一目标的连续绘制保持同一个 render pass**：`SetTarget` 遇到相同目标
   且无待处理清屏请求时不 `EndPass`，避免每个图层一次 pass 切换。
   `ClearTarget(true)` 会结束当前 pass，让下一次绘制以 CLEAR 变体重开。
3. **帧末不阻塞 CPU**：`EndFrame` 用 `FlushMeshCommands(false, meshDone_)`
   只提交不等待，窗口帧提交通过二值信号量 `meshDone_` 依赖 mesh 提交；
   mesh 命令缓冲的复用推迟到下一次录制前的 `WaitMeshIdle()`。
4. **上传按需等待**：只有被上传的贴图可能仍被未完成的 GPU 读取
   （`sampledImages_` / `presentedImages_`）时才同步。D3D 合成路径下
   ScratchTexture 只被"上传之后的"绘制采样，稳态下零等待。
5. **显存类型打分**：`FindHostVisibleMemory` 在满足 host-visible 的类型中
   优先 device-local、再 host-cached、最后 host-coherent。集显上
   `DEVICE_LOCAL|HOST_VISIBLE|HOST_CACHED` 比默认的第一个 host-visible
   （通常是无缓存的写合并内存）快得多。
6. **混合/布局**：所有离屏目标与线性贴图使用 GENERAL 布局，绘制、采样、
   回读都免布局转换；贴图行距用 `vkGetImageSubresourceLayout` 查询。
7. **回读**：`LockTarget` 录制 barrier + `vkCmdCopyImageToBuffer` →
   submit → fence wait（仅测试/插件回读使用）。

---

## 4. 三个后端的实现要点

| 后端 | 窗口合成 | 2D 网格 | Layer 合成 |
|---|---|---|---|
| OpenGL/GLES | 全屏四边形 + 单贴图 shader（330 core / 300 es），uniform 缓存、惰性 VAO/VBO/EBO | 网格 shader（330 core / 100 es）+ FBO 目标 + 蒙版 discard + bm 混合映射 | layer shader + 固定混合状态（COPY/ALPHA/ADD/SUB/MUL…），shader 内 ×255/256 模拟 `>>8` |
| 软件 | SDL_Texture，经 `PlatformView.h` 平台钩子 | CPU 光栅化（edge function + 仿射步进 + `blendPixels`） | 矩形光栅化 + `LayerBlendPixel`（tvpgl 整数公式直译，位级一致） |
| Vulkan | 交换链 + 四边形管线（push constant 传像素坐标） | 3 条混合管线 + 离屏目标 + staging 回读 | `vk2d_layer.frag` + 9 条混合管线（含 REVERSE_SUBTRACT / DST_COLOR） |

### 4.1 Vulkan 易错点清单

- **初始化顺序**：Instance → Surface → Device → Swapchain → RenderPass →
  Framebuffers → Pipeline。帧缓冲必须在其依赖的 render pass 与交换链
  图像视图之后创建；交换链重建时一并重建。
- **NDC Y 轴**：Vulkan NDC Y 向下（-1 顶部），窗口 shader 内翻转；
  离屏 2D 网格**不翻转**——GL 回读行序翻转与 VK NDC 方向恰好抵消。
- **索引绘制**：窗口四边形必须 `vkCmdDrawIndexed(6)`（`0,1,2 / 2,3,0`），
  `vkCmdDraw(4)` 在 TRIANGLE_LIST 下只覆盖一半屏幕。
- **混合**：alpha 通道 `GL_MAX` 对应 `VK_BLEND_OP_MAX`；无深度附件
  （z=0 顶点在 GL 的 GEQUAL 测试下恒通过，等价省略）。
- **命令缓冲复用**：提交后重新 `vkResetCommandBuffer` 前必须确认上一次
  提交已完成（`WaitMeshIdle`），否则会写正在执行的命令缓冲。
- **跨提交依赖**：不等待栅栏时用信号量连接 mesh 提交与窗口帧提交；
  只靠队列顺序不足以保证执行依赖。

---

## 5. 平台钩子

`cpp/environ/PlatformView.h`，由各入口实现：

- 软渲染：`TVPCreateTextureBackend` / `TVPUpdateTextureBackend` /
  `TVPDestroyTextureBackend` / `TVPRenderTextureBackend` /
  `TVPRenderClearBackend` / `TVPRenderPresentBackend` /
  `TVPSoftwareRenderBackendAvailable`（OHOS 无软渲染）。
- GL：`TVPSwapBuffersBackend`（`SDL_GL_SwapWindow` / `eglSwapBuffers`）。
- 窗口尺寸：`TVPGetWindowSize`（逻辑）/ `TVPGetWindowSizeInPixels`（像素，
  Vulkan 交换链使用）。

---

## 6. 可配置性

命令行参数（`TVPParseArguments`，各平台生效）：

| 参数 | 取值 | 说明 |
|---|---|---|
| `-render` | `auto`(默认) / `opengl` / `gl` / `gpu` / `vulkan` / `vk` / `software` / `sw` | 后端选择；auto 顺序为 metal → d3d* → opengl → vulkan → software |
| `-window` | `WxH` | 初始窗口尺寸（默认 1280x720） |
| `-vsync` | `0` / `1` | 垂直同步（默认 1；GL: SwapInterval，SW: RenderVSync，VK: FIFO/Mailbox） |
| `-stretch` | `0` / `1` | 0=等比 letterbox（默认），1=拉伸铺满 |

编译开关（CMake）：`USE_RENDER_GL` / `USE_RENDER_VK`；宏
`_KRKRSDL3_GL`（桌面 GL）/ `_KRKRSDL3_GLES`（移动/Web/OHOS）。
Linux 链接系统 Vulkan loader（vcpkg 的 loader 会丢失 wayland/xcb surface 扩展）。

后端初始化失败时入口自动回退软渲染（重建窗口 + 软后端）。

---

## 7. 全局约定

1. **坐标**：窗口合成用像素坐标 + 统一 letterbox（调度器计算，后端不重复
   实现）；网格绘制用 NDC（GL 语义，Y 向上）；Layer 合成用目标像素坐标，
   内容顶（t=0）对应 NDC -1，三后端回读一致。
2. **字节序**：所有贴图 RGBA 8bit，自上而下行序。
3. **句柄生命周期**：贴图/目标由后端分配；销毁必须回到同一后端实例；
   后端切换后旧句柄无效。
4. **上下文归属**：GL 要求调用时上下文有效；VK 后端与合成器共享实例/设备/
   队列，各自独立命令缓冲。
5. **回读语义**：`LockTarget` 返回的指针在 `UnlockTarget` 前有效
   （GL/VK 为回读缓冲，SW 为内部缓冲），调用方应在此期间完成拷贝。

---

## 8. 性能模型与实测

一帧的主要成本（按当前架构，GPU 与软件后端同路径的部分）：

```
TJS 事件 + 图层树软合成（CPU）→ DrawBuffer（CPU）
  → 每帧一次整幅上传（w·h·4，CPU→GPU）
  → D3D 层/emote 的 GPU 绘制 + UI 层合成
  → 窗口 pass（letterbox 缩放）→ Present
```

- 软件合成是主要开销，GL 与 VK 共享，不随后端变化。
- Vulkan 的历史问题是**每帧 4~5 次 submit + fence 等待**（逐 pass 提交），
  在 DrawDeviceD3D 场景实测约 **3.0~3.5 ms/帧**，是"Vulkan 很卡"的主因。
  改为按需提交 + 帧末只提交不等待 + 同目标 pass 连续录制后，同步开销降到
  **约 0.05 ms/帧**；同一 D3D 场景从约 130~235 fps 提升到约 240~300 fps
  （OpenGL 同场景约 350~450 fps，软件约 140 fps）。
- 剩下的差距主要来自架构固有成本：全帧 CPU→GPU 上传、线性贴图采样、
  以及每次 upload/draw 的显式 API 调用。要再提升需要改数据流（§9），
  而不是继续在同步上做文章。

性能验证方式（离屏、不干扰桌面）：

```
python tests/run.py --game out/testgame/data.xp3 --renderer vulkan \
    --harness tests/harness_boot.tjs --frames 600
```

`out/testgame` 是 DrawDeviceD3D 场景（真正走后端 Layer 合成）；
其它测试游戏大多只走软件 RenderManager + 窗口上传，观察不到后端差异。

---

## 9. 演进方向（GL/VK 双快）

现状的接口是"GL 形状"的：`UpdateTexture` 隐含同步、整帧上传、
窗口贴图与离屏目标共用句柄、呈现靠贴图别名。这些语义在 GL 上天然成立，
在 Vulkan 上只能靠提交/等待兜底。目标语义（两个后端都成立）：

1. **资源三分**：`Texture`（采样）/ `RenderTarget`（颜色附件）/
   `WindowSurface`（呈现）。句柄生命周期显式，取消目标纹理的 sprite 别名。
2. **子矩形上传**：`Upload(texture, rect, pixels, pitch)`。
   GL 直接 `glTexSubImage2D`；VK 写暂存环并在帧命令缓冲里
   `vkCmdCopyBufferToImage`。软件合成只上传脏矩形（非 D3D 路径收益最大）。
3. **帧内攒批**：`BeginFrame` 之后的所有 upload/draw 属于同一逻辑帧，
   `EndFrame` 统一提交一次 mesh + 一次 present（现状已是 1~2 次提交）。
4. **呈现独立**：`Present(surface, target, dstRect)`；VK 与帧绘制同队列提交
   （或 `vkCmdBlitImage` 1:1 直拷），GL 走 FBO blit/全屏四边形。
5. **显式异步回读**：`RequestReadback/WaitReadback`；`LockTarget` 仅保留兼容，
   测试/插件回读不再阻塞正常帧。
6. **批绘制**：`DrawQuads(texture, blend, verts[], count)`，emote 等插件按
   纹理/混合状态合批，减少每 sprite 一次绑定与 Vulkan 命令。

建议顺序：先做 1+2+3（Vulkan 侧 optimal 采样图 + 暂存环 + 子矩形上传），
再收敛窗口呈现（4），最后按需做 5/6。GL 后端保持立即模式，
上述语义 1:1 映射到原有调用，旧硬件行为不变。

---

## 10. 新增后端（以 Metal 为例）

1. 新建 `MetalRenderBackend.{h,mm}`，实现 `iTVPRenderBackend` 全部方法：
   - 纹理/目标 = 持有 `id<MTLTexture>` 的包装对象；
   - 上传 = `replaceRegion:`（或 blit + staging）；
   - 帧控制 = `nextDrawable` + `presentDrawable:`；
   - NDC Y 方向与 Vulkan 相同，在顶点 shader 内处理。
2. 静态注册 `TVPRegisterRenderBackend`，`probe` 检查设备可用性。
3. 入口（`sdl3_app.cpp`）加 `-render` 分支与窗口标志，创建后
   `TVPSetRenderBackend`。
4. CMake 加 Metal/QuartzCore 与 `_KRKRSDL3_USE_METAL`，默认选择顺序插入
   （macOS 上 auto 优先 metal）。
5. 实现上传/提交语义：CPU 不等待 GPU；Layer 合成与软件 bm* 语义逐像素
   一致（允许 ±1 舍入）。

---

## 11. 关键文件

| 文件 | 内容 |
|---|---|
| `cpp/core/render/TVPCompositor.h/.cpp` | 接口、后端注册表、`TVPRenderOnce`、窗口贴图调度 |
| `cpp/core/render/backend/GLRenderBackend.{h,cpp}` | GL/GLES 合并后端 |
| `cpp/core/render/backend/VulkanRenderBackend.{h,cpp}` | Vulkan 合并后端 |
| `cpp/core/render/backend/SWRenderBackend.{h,cpp}` | 软件合并后端 |
| `cpp/core/render/backend/shader/*` | GLSL 与预编译 SPIR-V |
| `cpp/environ/PlatformView.h` | 软渲染/GL 平台钩子 |
| `cpp/environ/sdl3/sdl3_app.cpp` | SDL3 入口、后端创建与帧循环 |
| `cpp/core/main/TVPWindow.cpp` | 窗口呈现（`PresentTexture`/借用纹理） |
| `cpp/plugins/DrawDeviceD3D/*` | Layer 合成路径的主要使用者 |
| `docs/rendering-system.md` | 整体数据流与分层 |
| `docs/drawdevice-d3d.md` | D3D 合成实现与验证 |
