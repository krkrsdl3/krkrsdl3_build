# krkrsdl3 渲染体系

> 从 TJS2 脚本 API 到最终上屏的完整说明：分层与数据流、软件合成内核、
> 渲染后端抽象层（GL / 软件 / Vulkan）、上传与提交契约、回读约束、性能与扩展点。
>
> 相关文档：Layer 体系与 D3D 合成见 `layer-system.md`；emoteplayer 见
> `emoteplayer-analysis.md`；窗口与输入见 `window-system.md`。

---

## 1. 分层与数据流

```
① 脚本层（TJS2）        cpp/core/script/
   Layer / Bitmap / Window 脚本对象（tTJSNI_*）
   ↓ Blt / StretchBlt / AffineBlt / DrawText ...
② 图层 / 位图层         cpp/core/render/LayerBitmap.*
   tTVPBaseTexture / tTVPBaseBitmap / tTVPBitmap
   ↓ iTVPRenderManager 的 RenderMethod
③ 软件合成内核          cpp/core/render/RenderManager.*
   tTVPSoftwareRenderManager → 合成到 DrawBuffer（tTVPDestTexture）
   ↓
④ 图层管理器 / 绘制设备  LayerManager.* / DrawDevice.* / TVPWindow.*
   UpdateToDrawDevice → Show → Window::PresentTexture（统一呈现入口）
   ↓
⑤ 窗口贴图合成 + 后端    TVPCompositor.* + backend/*
   TVPRenderOnce → iTVPRenderBackend（GL / SW / Vulkan）→ 屏幕
```

**核心取向**：引擎的图层合成内核**永远是软件渲染**，`-render` 只改变第 ⑤ 层的
上屏后端（`RenderManager.h` 文件头注释）。原因：`iTVPRenderManager` 的接口契约
本质是 CPU 位图操作（`GetScanLineForWrite`/`GetPoint`/`GetTextureData`），GPU 化
会让每次 `OperateRect` 都整幅回读或上传，形成 CPU→GPU→CPU 的反复横跳；且文字、
PS 混合、模糊、gamma、转场等只有 CPU 实现。正确做法是**图层在 CPU 上精细合成，
每帧只做一次整幅上传**（带宽论证见 `layer-system.md` §7）。

---

## 2. 图层与位图 API（`LayerBitmap.*`）

```
tTVPBitmap                 原始 DIB（Bits / Pitch / Palette）
  └ tTVPNativeBaseBitmap   持有 iTVPTexture2D + 字体/文本 + GetTextureForRender
      └ iTVPBaseBitmap     绘制 API：Fill/CopyRect/Blt/StretchBlt/AffineBlt/模糊/伽马…
          ├ tTVPBaseBitmap     province image（软件管理器）
          └ tTVPBaseTexture    常规图层（当前管理器）
              └ tTVPDestTexture  LayerManager 的合成目标（HoldAlpha 控制）
```

- **写时独立**：`GetTextureForRender(isBlendTarget, rc)` — 需要混合目标或整图操作
  时 `Independ()` 复制像素，只读整图渲染时 `IndependNoCopy()` 零拷贝引用。
  这是"Bitmap 赋值给多个 Layer"与"各自独立绘制"之间的平衡点。
- **绘制全部落到 RenderMethod**：`Blt` → `GetRenderMethod(opa,hda,method)` +
  `OperateRect`（opa==255 && bmCopy && !hda 退化为 `CopyRect`）；`StretchBlt`
  走 `ResizeRGBA` 预缩放；`AffineBlt` 走 `OperateTriangles`（多线程分块）；
  文本走 FreeType 光栅化 + `InternalBlendText`。
- **更新区**：`tTVPComplexRect`（区间列表）只记录变化区域，合成时按
  "暴露区 ∩ 更新区"逐条重绘（经典矩形合并优化）。

---

## 3. 软件合成内核（`RenderManager.*`）

```cpp
class iTVPTexture2D        // 贴图（软件实现 = 内存位图）
{ Width/Height/GetFormat/GetScanLineForRead|Write/GetPixelData/GetPitch
  Update(...)/GetPoint/SetPoint/IsStatic/IsOpaque/GetTextureData/AddRef/Release }

class iTVPRenderManager    // 渲染管理器
{ CreateTexture2D(×4 重载) / GetRenderMethod / CompileRenderMethod
  OperateRect / OperateTriangles / OperatePerspective
  BeginStencil / EndStencil / SetRenderTarget / IsSoftware / GetName }
```

- **注册表**：`TVPRegisterRenderManager(name, factory)`；默认
  `TVPGetRenderManager()` 取 `"software"`（当前唯一实现，惰性创建）。
  `TVPGetSoftwareRenderManager()` 是 province image 专用的独立单例。
- **软件贴图**：`_static`（引用外部指针，零拷贝）、`_compress`（TLG 延迟解压，
  3 帧未用自动释放）、常规（引用 `tTVPBitmap` 或自持缓冲）。
- **RenderMethod 注册表**（`gl/tvpgl.cpp`、`blend_function.cpp` 等）：填充 /
  复制 / Alpha 混合（`_d` 保持目标 alpha、`_a` 附加 alpha）/ 带色图 / PS 混合 /
  特效（灰度、模糊、gamma）/ 转场（`ConstAlphaBlend_SD`、`UnivTransBlend`）。
  `GetRenderMethod(opa, hda, method)` 查 `tRenderMethodCache`。
- **三种运算路径**：`OperateRect`（裁剪 + 源区映射 + 逐行混合）、
  `OperateTriangles`（矩形退化 → OperateRect；平行四边形 → `InternalAffineBlt`
  多线程；一般四边形 → 网格插值）、`OperatePerspective`（透视变换到临时纹理）。

---

## 4. 图层管理器与统一呈现入口

```
iTVPLayerTreeOwner        窗口侧：持有 LayerManager 列表、光标/IME/输入分发
   ▲
tTVPLayerManager          图层树：Primary/焦点/模态/捕获、UpdateRegion、
   ▲                      DrawBuffer（tTVPDestTexture）→ UpdateToDrawDevice
tTVPBasicDrawDevice       AddLayerManager / Update / Show
   ▲
tTVPDrawable              GetDrawTargetBitmap / DrawCompleted
```

一帧合成（软件路径）：

```
tTVPBasicDrawDevice::Update
  └ Manager->UpdateToDrawDevice()
      └ tTJSNI_BaseLayer::CompleteForWindow(drawable)
          ├ StartBitmapCompletion
          ├ InternalComplete2(UpdateRegion, drawable)   // 唯一完成路径（无 GPU 分支）
          │    ├ QueryUpdateExcludeRect()               // 不透明遮挡裁剪
          │    ├ 按条带拆分（TVPGraphicSplitOperationType）
          │    └ Draw(drawable, r) → 子层 Complete → DrawCompleted
          └ EndBitmapCompletion
```

**呈现只有一条路径**：

```
DrawDevice::Show → DrawBuffer(iTVPTexture2D)
   ├ GPU 驻留：GetTextureHandle() 直传
   └ 软渲染：LockCPURead → scratch 贴图
        ↓
   TVPWindow::PresentTexture(texture, w, h)
      ├ GPU 后端：sprite 纹理别名（borrowedTexture，零拷贝，sprite 不负责销毁）
      └ SW 后端：LockTexture → TVPUpdateTexture 上传窗口贴图
```

---

## 5. 渲染后端抽象层（`iTVPRenderBackend`）

### 5.1 接口

一个后端实例、一套绘制 API：没有"2D 网格渲染器"和"Layer 合成器"两个角色，
只有两个同级原语 `DrawMesh`（任意几何）和 `DrawRect`（轴对齐矩形），共用一次
`SetBlend` 状态。

```cpp
BeginFrame / EndFrame
CreateWindowTexture / UpdateWindowTexture / DestroyWindowTexture / DrawWindowTexture
CreateTarget / DestroyTarget / SetTarget / ClearTarget / LockTarget / UnlockTarget
GetTargetTexture / UpdateTargetTexture
CreateTexture / UpdateTexture / UploadTextureRect / DestroyTexture / LockTexture
SetMask / SetBlend / DrawMesh / DrawRect / DrawQuads
```

- `UploadTextureRect(tex,x,y,w,h,pixels,pitch)`：现代上传契约，默认实现回退整幅
  `UpdateTexture`；VK 覆盖为"暂存环入队"，GL 覆盖为带偏移的 `glTexSubImage2D`。
- `DrawQuads(tex, verts, n, idx, nIdx)`：同 texture/当前混合状态下的一批四边形。
  默认实现逐 quad 回退 `DrawMesh`；**opacity/染色取自 `SetBlend` 记录的当前状态**
  （接口本身不带这两个参数），三个后端共用基类的 `blendOpacity_/blendModulation_`。

### 5.2 一套枚举、两套混合语义

`SetBlend(mode, opacity, uniformColor, colorModulation)`，按数值区间分流，公式不混用：

| 区间 | 枚举 | 语义来源 | 配套原语 |
|---|---|---|---|
| < 0x100 | `BM_NORMAL=0` / `BM_MULTIPLY=1` / `BM_ADD=3` / `BM_SKIP=6` / `BM_SOLID=21` | emoteplayer | `DrawMesh` |
| ≥ 0x100 | `BM_COPY..BM_COPYMASK`（0x100~0x10A） | 软件 RenderManager 的 bm*（`>>8` 截断） | `DrawRect` |

后者由 `IsRMBlend(mode)` 判定，含 `BM_ALPHA`（src-over 全通道）、`BM_CONSTALPHA`、
`BM_ADD_RM` / `BM_SUB` / `BM_MUL_RM` / `BM_MUL_HDA`、`BM_FILL`、`BM_COPYCOLOR` /
`BM_COPYOPAQUE` / `BM_COPYMASK`。三后端与软件合成逐像素一致（允许 ±1 舍入，
`BM_COPY` 精确直写）。

### 5.3 上传与提交契约

1. `UpdateTexture` / `UpdateWindowTexture` / `UpdateTargetTexture` /
   `UploadTextureRect` 都是"入队"：返回后数据对本帧后续绘制可见，**不保证
   GPU 已执行完**，调用方可立即复用 pixels 缓冲。
2. 上传与绘制按调用顺序形成依赖；同一逻辑帧内可合并成一次或多次提交。
3. 稳态帧内 CPU 不等待 GPU；只有显式回读（`LockTarget`/`LockTexture`）允许阻塞。

### 5.4 三个后端

| 后端 | 文件 | 上传 | 目标 | 特点 |
|---|---|---|---|---|
| OpenGL/GLES | `backend/GLRenderBackend.*` | `glTexSubImage2D`（立即入驱动队列） | FBO + 颜色纹理 | 立即模式，行为与历史实现一致 |
| 软件 | `backend/SWRenderBackend.*` | 直接写 CPU 缓冲 | CPU 位图 | SDL_Texture 经平台钩子上屏 |
| Vulkan | `backend/VulkanRenderBackend.*` | 暂存环 + `vkCmdCopyBufferToImage`，帧末一次提交 | 离屏图像（GENERAL 布局） | 显式内存/同步，CPU 不阻塞 |

Vulkan 要点：

- **按需提交**：只有要采样"本 command buffer 内刚写过"的目标图像时才
  `FlushMeshCommands()`（同提交的 GENERAL→GENERAL barrier 在 RADV 上不可靠）；
  同一目标的连续绘制保持同一个 render pass。
- **帧末不等待**：`EndFrame` 只提交，窗口帧用二值信号量依赖 mesh 提交；
  命令缓冲复用推迟到下一次录制前的 `WaitMeshIdle()`。
- **上传自适应**：UMA（集显）走 LINEAR 直写映射内存；独显走 device-local
  OPTIMAL + host-visible 暂存环（双区交替，帧内零栅栏等待）。
- **顶点偏移只能作用一次**：索引里加了 `vBase` 就不能再给
  `vkCmdBindVertexBuffers` 传偏移，否则本帧第 2 次及之后的绘制会读到别的
  quad 的顶点（表现为图层放大/串位）。
- 其它易错点：NDC Y 向下（窗口 shader 内翻转，离屏网格不翻转）；窗口四边形
  必须 `vkCmdDrawIndexed(6)`；命令缓冲复用前确认上次提交完成；无深度附件。

### 5.5 全局约定

1. **坐标**：窗口合成用像素坐标 + 统一 letterbox（调度器算，后端不重复）；
   网格绘制用 NDC（GL 语义）；Layer 合成用目标像素坐标，内容顶（t=0）→ NDC −1。
2. **字节序**：所有贴图 RGBA 8bit、自上而下行序。
3. **句柄**：不透明 `void*`，由后端分配与释放；销毁必须回到同一后端实例。
4. **回读**：`LockTarget` 返回的指针在 `UnlockTarget` 前有效（GL/VK 为回读
   缓冲，SW 为内部缓冲）。

---

## 6. 帧循环（`environ/sdl3/sdl3_app.cpp`）

```
SDL_AppIterate
  ├ Application->Run()          // TJS 事件循环、定时器、图层更新
  │    └ 各层绘制 → 软件合成 → DrawBuffer → Show → Window::PresentTexture
  └ TVPRenderOnce(RW, RH)       // 合成器：清屏 → 画 currentSprite/overlay → 呈现
       ├ backend->BeginFrame()
       ├ backend->DrawWindowTexture(...)  × currentSprite + overlay（letterbox）
       └ backend->EndFrame()              // SwapBuffers / vkQueuePresent
```

注意 ⑤ 与 ⑥ 是两件事：先把软件合成的最终帧像素变成窗口贴图，再由后端呈现。
`-render` 只替换后者。入口 `sdl3_entry.cpp` 是薄壳；后端初始化失败自动回退软渲染；
退出时 `TVPShutdownRenderBackend()` 必须先于 GL 上下文销毁。

---

## 7. 回读与纹理驻留

回读是合法但必须显式：设计目标是**合成链路零隐式回读**，单帧内同一纹理至多
一次回读 + 一次上传。

| 场景 | 接口 | 说明 |
|---|---|---|
| 截屏 / 存档缩略图 | 整帧 `LockTarget(CompositeTarget)` | 取最终合成目标，不要逐图层回读 |
| 图片导出 / `saveToFile` | `LockTexture` / `GetTextureData` | 回读一次后可复用缓存 |
| 像素脚本 API（`getPixel`/`pointInImage`/`getScanLine`） | `LockTexture`（带缓存） | 语义不变，多次读取共享一次回读 |
| 视频叠加层 / AlphaMovie / 解码 | 现有 `GetScanLine*` | 解码语义本就在 CPU 侧 |
| 调试分析 | `LockTexture` | 标注即可 |

判定标准：用户显式触发、低频、语义上必须拿 CPU 像素 → 允许；每帧/指针事件/
合成管线内部自动发生的 → 视为隐式回读，禁止。

---

## 8. 性能与验证

一帧成本：TJS 事件 + 图层树软合成（CPU）→ DrawBuffer → **每帧一次整幅上传**
→ D3D 层/emote 的 GPU 绘制 + UI 层合成 → 窗口 pass → Present。软件合成是主要
开销，与后端选择无关。

本机（Intel Core 5 220H / Intel Graphics 集显 / UMA）实测：D3D 负载场景下
**Vulkan ≈ OpenGL ≈ 500 fps 量级（VK/GL ≈ 1.0）**。历史上 VK 慢的主因是
"每个新 pass 都提交并等待"（4~5 次 GPU 同步/帧，早期实测约 3ms/帧）；改为
按需提交 + 帧末只提交不等待 + 同目标连续录制后，同步已不再是帧时间的主要项。

复跑（离屏、不干扰桌面）：

```bash
TESTGAME=/path/to/testgame                          # 换成你的测试游戏目录
python tests/bench.py --rounds 4 --frames 600       # 三后端交错跑分，取中位
python tests/run.py --game "$TESTGAME/data.xp3" --renderer vulkan \
    --harness tests/harness_boot.tjs --frames 600   # 单次跑，看画面与日志
```

必须用真正绑定 DrawDeviceD3D 的测试场景（`$TESTGAME/data.xp3`），
否则只走软件 RenderManager + 窗口上传，看不出后端差异。

---

## 9. 扩展点

- **新增上屏后端**（以 Metal 为例）：实现 `iTVPRenderBackend` 全部方法
  （纹理/目标包装、`replaceRegion:` 上传、`nextDrawable` 呈现、NDC Y 与 VK 同向），
  `TVPRegisterRenderBackend` 静态注册，入口加 `-render` 分支，CMake 加平台框架。
  要求：CPU 不等待 GPU；Layer 合成与软件 bm* 语义逐像素一致。
- **换 RenderManager**：实现 `iTVPRenderManager` + `REGISTER_RENDERMANAGER`。
  ⚠ 脚本层已移除 `IsGPU`/GPU 合成路径，Layer 树恒走软件合成；GPU 化内核需自行
  承担 `GetScanLineForWrite` 等 CPU 操作的回读/上传往返。
- **插件直接渲染**（emoteplayer）：`TVPGetRenderBackend()` 拿到当前后端，
  离屏目标绘制 + `LockTarget` 回读，插件内无后端分支。
- **多线程**：`TVPExecThreadTask`（软件合成分块）、`TVPDrawThreadNum` 可调。
- **命令行**：`-render` 取值 `opengl|gl|gpu` / `vulkan|vk` / `metal|mtl` /
  `d3d11|d3d` / `d3d12` / `d3d9` / `software|sw`；**不给时默认 software**，
  指定的后端起不来（或未编译进来）时记录日志并回退软件后端。
  `-window WxH`（默认 1280x720）、`-vsync 0|1`（默认 1）、
  `-stretch 0|1`（默认 0，等比 letterbox）。编译开关 `USE_RENDER_GL` / `USE_RENDER_VK`，
  宏 `_KRKRSDL3_GL` / `_KRKRSDL3_GLES`。

---

## 10. 关键文件

| 文件 | 内容 |
|---|---|
| `core/script/tjsNativeLayer.*` `tjsNativeBitmap.*` `tjsNativeWindow.*` | 脚本对象绑定 |
| `core/render/LayerBitmap.*` | 位图/图层绘制 API |
| `core/render/RenderManager.*` + `gl/tvpgl.cpp` 等 | 软件合成内核与混合函数库 |
| `core/render/LayerManager.*` `DrawDevice.*` `LayerTreeOwner.*` | 图层树、绘制设备、宿主 |
| `core/render/ComplexRect.h/.cpp` `drawable.h` | 更新区、图层类型 |
| `core/render/TVPCompositor.*` | `iTVPRenderBackend` 接口、后端注册表、`TVPRenderOnce` |
| `core/render/backend/*`（GL/SW/Vulkan） | 三个后端实现 |
| `core/render/backend/shader/*` | GLSL 与预编译 SPIR-V（`regenerate.sh` 重新生成） |
| `environ/PlatformView.h` | 平台钩子（软渲染 / GL 呈现） |
| `environ/sdl3/sdl3_app.cpp` | SDL3 入口、后端选择、帧循环 |
| `core/main/TVPWindow.cpp` | 窗口呈现（`PresentTexture` / 借用纹理） |
