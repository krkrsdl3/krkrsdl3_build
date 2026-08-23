# krkrsdl3 渲染后端抽象层（iTVPRenderBackend）

> 面向贡献者：本文解读 `cpp/core/render/` 中的渲染后端抽象层——接口约定、三个后端
> （OpenGL / 软渲染 / Vulkan）的实现要点、平台集成方式，以及新增后端的步骤与注意点。
> 渲染体系的整体数据流与分层见 `docs/rendering-system.md`；emoteplayer 插件如何
> 使用本抽象层见 `docs/emoteplayer-analysis.md`。

---

## 1. 设计目标与约定

### 1.1 为什么需要抽象层

引擎的图层合成内核（`RenderManager` 等）**保持完全软渲染**（krkr2/krkrz 原版思路），
脚本渲染的最终结果是一张 CPU 位图。这张位图需要以不同方式上屏（GL / SDL 软渲染 /
Vulkan / 未来的 Metal），同时动画插件（emoteplayer）有"离屏网格绘制 + CPU 回读"
或"GPU 直通绘制"（DrawDeviceD3D 的 emote 路径）的需求。`iTVPRenderBackend` 把
这些需求统一成一个接口，约定：

1. **除 entry（平台入口）与 render（core/render）外，代码中不允许出现渲染后端区分**
   （如 `if (renderer == "opengl")`）。插件与上层只面向接口编程。
2. 贴图句柄一律为**不透明 `void*`**，由后端分配/释放；上层不解释句柄内容。
3. 坐标与字节序约定统一（见 §5），各后端行为一致。

### 1.2 接口位置

- 接口 `iTVPRenderBackend`、注册表（`TVPRegisterRenderBackend` /
  `TVPListRenderBackends` / `TVPRenderBackendAvailable`）、全局后端
  （`TVPSetRenderBackend` / `TVPGetRenderBackend` / `TVPShutdownRenderBackend`）
  全部声明在 **`cpp/core/render/TVPCompositor.h`**（无独立 RenderBackend.h）。
- `TVPSprite`（窗口贴图描述，含 `void* texture` 句柄）在 `cpp/environ/PlatformView.h`。

## 2. 接口（合并设计）

一个接口同时承担两个角色：

```cpp
class iTVPRenderBackend {
    GetName() / IsHardware()
    // ---- 帧控制（窗口合成，由 TVPRenderOnce 调度）----
    BeginFrame(w, h) / EndFrame()            // 清屏/取交换链 → 提交并呈现
    // ---- 窗口贴图（上屏合成用）----
    CreateWindowTexture / UpdateWindowTexture / DestroyWindowTexture
    DrawWindowTexture(handle, x, y, w, h)    // 像素坐标（letterbox 已由调度器算好）
    // ---- 2D 网格渲染（供插件：离屏目标 + 一般贴图 + 蒙版/混合 + 网格绘制）----
    CreateTarget / DestroyTarget             // 离屏目标：GL=FBO，SW=CPU 缓冲，VK=离屏图像
    SetTarget / ClearTarget                  // ClearTarget(false)=仅清深度（SW 无深度→不清）
    LockTarget(handle, pitch) / UnlockTarget // 回读 CPU 像素（GL: glReadPixels；SW: 零拷贝）
    CreateTexture / UpdateTexture / DestroyTexture  // 一般贴图
    SetMask(maskTarget)                      // 蒙版=同尺寸目标，alpha>=128 有效；nullptr 关闭
    SetBlendMode(mode, uniformColor)         // 0/1/3/4/21；6=跳过；21 需 uniformColor(RGBA 0..1)
    DrawMesh(verts, nVerts, idx, nIdx, texture, opacity)
    // ---- Layer 合成（供 DrawDeviceD3D：软件 RenderManager 混合语义的矩形合成）----
    LayerSetBlend(method, opacity, uniformColor)  // LBM_COPY/ALPHA/CONSTALPHA/ADD/SUB/MUL/
                                                  // MUL_HDA/FILL/COPYCOLOR/COPYOPAQUE/COPYMASK
    LayerDrawRect(texture, x, y, w, h, u0,v0,u1,v1) // 目标像素坐标 + 归一化源矩形
    FetchInfo()                              // 后端信息日志（GL 厂商/版本/扩展等）
};
```

- **窗口贴图与一般贴图在接口上显式区分**：GPU 后端两者是同一实现
  （`CreateWindowTexture == CreateTexture`）；软件后端窗口贴图是 SDL_Texture
  （经平台钩子），一般贴图是 CPU 缓冲。
- **插件即用户**：emoteplayer 等插件经 `TVPGetRenderBackend()` 直接获得当前后端
  （兼作 2D 渲染器），没有独立的 2D 渲染器注册表。
- **`DrawMesh` 顶点格式**：交错 `(x, y, u, v)` 每顶点 4 个 float；
  `x/y` 为 NDC `[-1,1]`（GL 语义，Y 向上），`u/v` 为纹理坐标。
  CPU 侧网格计算（如 emoteplayer 的 `MeshVertex {x,y,u,v}`）与此布局天然一致，
  可直接传递。
- **Layer 合成与 2D 网格是两套混合语义**：`DrawMesh` 的 `SetBlendMode` 遵循
  emoteplayer 的混合约定（0 普通 / 1,4 乘色 / 3 加色 / 21 纯色 / 6 跳过）；
  `LayerSetBlend/LayerDrawRect` 遵循软件 RenderManager（`gl/tvpgl.cpp` 的
  bm* 方法，含 `_o` 变体的 `>>8` 截断语义）——两者不可混用。三后端 Layer 合成
  与软件合成逐像素一致（允许 ±1 舍入；`LBM_COPY` 为精确直写）。

## 3. 三个后端实现（`cpp/core/render/backend/`）

| 后端 | 文件 | 窗口合成 | 2D 网格 | Layer 合成 |
|---|---|---|---|---|
| OpenGL/GLES | `GLRenderBackend.{h,cpp}` | 全屏四边形 + 单贴图 shader（330 core / 300 es），uniform 缓存、惰性创建 VAO/VBO/EBO | 网格 shader（330 core / 100 es）+ FBO 目标 + 蒙版采样 discard + bm 混合映射 | layer shader + 固定函数混合状态（COPY 直写 / ALPHA 全通道 SRC_ALPHA / ADD ONE+ONE / SUB 反向减 / MUL DST_COLOR…），shader 内 ×255/256 模拟软件 >>8 |
| 软渲染 | `SWRenderBackend.{h,cpp}` | SDL_Texture 经 `PlatformView.h` 平台钩子 | CPU 光栅化（edge function + 仿射纹理步进 + blendPixels 混合公式），不依赖图形 API，为默认兜底 | 矩形光栅化 + `LayerBlendPixel`（tvpgl 整数公式直接翻译，位级一致） |
| Vulkan | `VulkanRenderBackend.{h,cpp}` | 交换链 + 四边形管线（push constant 传像素坐标） | 3 个混合管线变体 + 离屏目标 + staging 回读 | `vk2d_layer.frag`（glslc 预编译嵌入）+ 9 条混合管线变体（含 REVERSE_SUBTRACT / DST_COLOR 因子组合） |

- 后端经 `TVPRegisterRenderBackend` 静态注册（含平台探测 `probe`）；
  `-render` 参数与 `TVPSettings.renderer` 决定选择（`auto` → opengl → vulkan → software）。
- 入口初始化失败时自动回退软渲染（重建窗口 + 软渲染后端），不直接退出。
- **Layer 合成与 2D 网格共享目标/贴图/命令缓冲设施**，仅混合状态与绘制入口不同；
  DrawDeviceD3D（见 `docs/drawdevice-d3d.md`）是 Layer 合成路径的主要使用者。

### 3.1 Vulkan 后端要点（最容易踩坑的部分）

- **初始化严格顺序**（参考 out/Vulkan-SDL3 实例）：
  `Instance → Surface → Device → Swapchain → RenderPass → Framebuffers → Pipeline`。
  帧缓冲必须在其依赖的 render pass 与交换链图像视图**之后**创建；
  交换链重建（窗口 resize / OUT_OF_DATE）时同样要重建帧缓冲。
- **NDC Y 轴方向**：Vulkan NDC Y 向下（-1 顶部、+1 底部），与 OpenGL 相反。
  窗口合成 shader（`shader/vk_quad.vert`）内做 `ndcPos.y = -ndcPos.y` 翻转；
  离屏 2D 网格路径**不需要**翻转——GL 的 `glReadPixels` 行序翻转与 Vulkan 的
  NDC 方向恰好抵消，回读结果一致（改前请先与 GL/SW 对比验证）。
- **索引绘制**：窗口四边形必须用索引（两个三角形 `0,1,2 / 2,3,0`，与 GL 的 EBO
  一致）；直接 `vkCmdDraw(4)` 在 TRIANGLE_LIST 下只会覆盖一半屏幕。
- 离屏目标/纹理使用 **GENERAL 布局**（绘制/采样/回读免布局转换）；
  线性贴图行距经 `vkGetImageSubresourceLayout` 查询，不能假设 `width*4`。
- 混合的 alpha 通道 `GL_MAX` 对应 `VK_BLEND_OP_MAX`；无深度附件
  （GL 路径的 GL_GEQUAL 深度测试对 z=0 顶点恒通过，等价省略）。
- 回读：`LockTarget` 录制 barrier + `vkCmdCopyImageToBuffer` → submit → fence wait。

### 3.2 平台钩子（`cpp/environ/PlatformView.h`，各入口实现）

- 软渲染：`TVPCreateTextureBackend` / `TVPUpdateTextureBackend` /
  `TVPDestroyTextureBackend` / `TVPRenderTextureBackend` /
  `TVPRenderClearBackend` / `TVPRenderPresentBackend` / `TVPSoftwareRenderBackendAvailable`
  （OHOS 无软渲染，返回 false）。
- GL 呈现：`TVPSwapBuffersBackend`（SDL_GL_SwapWindow / eglSwapBuffers）。
- 窗口尺寸：`TVPGetWindowSize`（逻辑）/ `TVPGetWindowSizeInPixels`（像素，Vulkan 用）。

## 4. 可配置性

命令行参数（`TVPParseArguments`，所有平台生效）：

| 参数 | 取值 | 说明 |
|---|---|---|
| `-render` | `auto`(默认) / `opengl` / `gl` / `gpu` / `vulkan` / `vk` / `software` / `sw` | 后端选择 |
| `-window` | `WxH` | 初始窗口尺寸（默认 1280x720） |
| `-vsync` | `0` / `1` | 垂直同步（默认 1；GL: SwapInterval，SW: RenderVSync，VK: FIFO/Mailbox） |

编译开关（CMake）：`USE_RENDER_GL` / `USE_RENDER_VK` → 宏
`_KRKRSDL3_USE_OPENGL` / `_KRKRSDL3_USE_VULKAN`；`_KRKRSDL3_GL`（桌面 GL）/
`_KRKRSDL3_GLES`（移动/Web/OHOS）区分 shader 与加载器。
Linux 链接**系统 Vulkan loader**（vcpkg 的 vulkan-loader 枚举实例扩展时会丢失
wayland/xcb/xlib surface 扩展，导致 SDL_Vulkan_LoadLibrary 失败）。

## 5. 全局约定（贡献前必读）

1. **坐标**：窗口合成用"像素坐标 + 统一 letterbox"（调度器 `TVPCalcLetterbox` 计算，
   后端不重复实现）；网格绘制用 NDC（GL 语义，Y 向上）。
2. **字节序**：贴图统一 RGBA 8bit（icon 等解析时做 R/B 交换归一，不再按后端区分）。
3. **句柄生命周期**：贴图/目标句柄由后端分配；销毁必须回到同一后端实例
   （后端切换后旧句柄无效——`TVPGetRenderBackend` 变化时上层应重建资源）。
4. **上下文归属**：GL 后端要求调用时 GL 上下文当前有效；Vulkan 后端与合成器共享
   实例/设备/队列，各自独立命令缓冲。
5. **回读语义**：`LockTarget` 返回的指针在 `UnlockTarget` 前有效（GL/VK 为回读缓冲，
   SW 为内部缓冲），调用方应在此期间拷贝完成。

## 6. 新增后端（以 Metal 为例）的步骤

1. 新建 `MetalRenderBackend.{h,mm}`，实现 `iTVPRenderBackend` 全部方法：
   - 纹理/目标 = 持有 `id<MTLTexture>` 的包装对象（CFBridgingRetain/Release）；
   - 上传 = `replaceRegion:`（或 staging buffer + blit）；
   - 帧控制 = CAMetalLayer `nextDrawable` + `[commandBuffer presentDrawable:]`；
   - NDC Y 方向与 Vulkan 相同，在顶点 shader 内处理。
2. 静态注册：`TVPRegisterRenderBackend`，`probe` 检查 `MTLCreateSystemDefaultDevice()`。
3. 入口（sdl3_app.cpp）：`-render=metal` 分支，窗口标志 `SDL_WINDOW_METAL`，
   创建后 `TVPSetRenderBackend`。
4. CMake：Apple 分支 `find_library(Metal/QuartzCore)`，`.mm` 需 `enable_language(OBJCXX)`，
   定义 `_KRKRSDL3_USE_METAL`。
5. `TVPSettings` 默认选择顺序中加入 `metal`（macOS 上 `auto` 优先 metal）。
6. 实现 `LayerSetBlend` / `LayerDrawRect`（Layer 合成角色）：
   - 混合状态按 `LayerBlendMethod` 映射到后端能力（直写 / SRC_ALPHA 对 /
     ONE+ONE 加减 / DST_COLOR 乘 / 通道选择因子组合）；
   - 坐标：目标像素坐标 → NDC（内容顶=NDC −1），UV 归一化源矩形；
   - 需要与软件 RenderManager（`gl/tvpgl.cpp` 的 bm* 方法）逐像素一致
     （允许 ±1 舍入）。
