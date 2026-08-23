# krkrsdl3 渲染体系全景解读

> 本文档是对 krkrsdl3 整个渲染体系的完整解读，覆盖从 TJS2 脚本 API 到最终上屏的
> 全部层次：脚本对象（Layer/Bitmap）→ 图层/位图 → 软件合成内核（RenderManager）→
> 图层管理器/绘制设备 → 窗口贴图合成（Compositor）→ 渲染后端（GL/SW/Vulkan）→
> 帧循环。
>
> 后端抽象层的接口设计说明另见 `docs/rendering-architecture.md`；emoteplayer 插件
> 如何使用后端抽象见 `docs/emoteplayer-analysis.md`。本文侧重
> "数据流 + 分层职责 + 关键类关系"，三者互补。

---

## 1. 总体架构

渲染体系按数据流向分为 **5 层**：

```
┌─────────────────────────────────────────────────────────────────────┐
│ ① 脚本层（TJS2）        cpp/core/script/                             │
│    Layer / Bitmap / Window 脚本对象（tTJSNI_*）                      │
│    ↓ 调用绘制 API（Blt / StretchBlt / AffineBlt / Text ...）          │
├─────────────────────────────────────────────────────────────────────┤
│ ② 图层 / 位图层          cpp/core/render/ (LayerBitmap.*)            │
│    tTVPBaseTexture / tTVPBaseBitmap / tTVPBitmap                     │
│    ↓ 经 iTVPRenderManager 的 RenderMethod 操作贴图                    │
├─────────────────────────────────────────────────────────────────────┤
│ ③ 软件合成内核           cpp/core/render/RenderManager.*             │
│    iTVPRenderManager / tTVPSoftwareRenderManager                     │
│    iTVPTexture2D（软件贴图）+ RenderMethod 注册表（gl/tvpgl.cpp）      │
│    ↓ 合成到 DrawBuffer（tTVPDestTexture）                             │
├─────────────────────────────────────────────────────────────────────┤
│ ④ 图层管理器 / 绘制设备   cpp/core/render/ (LayerManager.*           │
│    DrawDevice.* LayerTreeOwner.* MainWindowLayer.cpp)                │
│    tTVPLayerManager → tTVPBasicDrawDevice → iWindowLayer             │
│    ↓ 上传窗口贴图（TVPUpdateTexture）                                 │
├─────────────────────────────────────────────────────────────────────┤
│ ⑤ 窗口贴图合成 + 后端    cpp/core/render/TVPCompositor.cpp           │
│    cpp/core/render/backend/*（GL/SW/Vulkan）                         │
│    TVPRenderOnce → iTVPRenderBackend（GL/SW/Vulkan）                  │
│    ↓                                                               │
│    屏幕                                                             │
└─────────────────────────────────────────────────────────────────────┘
```

**核心设计取向**（RenderManager.h 文件头注释）：

> 由于 GPU 兼容软渲染，但软渲染不兼容 GPU，所以对于内核我们按照 krkr2/krkrz 原版思路，
> **保持完全软渲染**；GPU 加速则放入插件中，使用特殊的 Layer 和 DrawDevice 来实现。

即：引擎的图层合成内核永远是软件渲染（`tTVPSoftwareRenderManager`），
`-render` 参数只改变"上屏后端"（第 ⑤ 层）。这是理解整个体系的关键。

> **为什么内核不 GPU 化（CPU↔GPU 带宽）**：`iTVPRenderManager` 的接口契约是
> CPU 位图操作（`GetScanLineForWrite`/`GetPoint`/`GetTextureData`...）。若改为 GPU
> 实现，每个 `OperateRect` 都要把目标纹理 GPU→CPU 回读或 CPU→GPU 上传
> （一次全屏往返 = w·h·4 字节 PCIe 传输），一帧几十上百次 blit 就形成
> **CPU→GPU→CPU→GPU→CPU 的反复横跳**；而大量图形处理（FreeType 文字、PS 混合、
> 模糊、gamma、色彩映射、转场）根本没有 GPU 等价实现，一旦纹理在 GPU 侧，
> 这些操作会强制整帧回读。因此正确做法是 **Layer 分批在 CPU 上精细合成后，
> 每帧只做一次 CPU→GPU 上传**（CPU→CPU→CPU→CPU→GPU，见
> `docs/drawdevice-d3d.md` §4.3）——DrawDeviceD3D 正是这条路径。

---

## 2. 脚本层（面向 TJS2）

### 2.1 脚本对象（`cpp/core/script/`）

| 类 | 文件 | 说明 |
|---|---|---|
| `tTJSNI_BaseLayer` | `tjsNativeLayer.h/cpp` | Layer 脚本对象的原生实例：图层树节点 + 绘制能力 |
| `tTJSNI_Layer` | 同上 | 具体图层（继承 BaseLayer） |
| `tTJSNI_Bitmap` | `tjsNativeBitmap.h/cpp` | Bitmap 脚本对象：持有 `tTVPBaseBitmap*` |
| `tTJSNI_Window` | `tjsNativeWindow.*` | Window 脚本对象 |
| `tTJSNI_BitmapLayerTreeOwner` | `tjsNativeBitmapLayerTreeOwner.h` | 位图式 LayerTreeOwner（`tTVPLayerTreeOwner` 子类） |

脚本对象是 **tjs2 脚本与 C++ 渲染内核的桥**：脚本操作 `Layer` / `Bitmap` 属性与方法，
最终都落到 `iTVPBaseBitmap` 的绘制 API 上。

### 2.2 Layer 树结构（`tTJSNI_BaseLayer`）

- 树管理：`Parent` / `Children`（`tObjectList`），`Join` / `Part` / `AddChild` / `SeverChild`。
- Z 序：`OrderIndex`（父内序号）、`OverallOrderIndex`（全局序号，惰性重建）、
  `AbsoluteOrderIndex`（绝对 Z 模式）。
- 可见性：`Visible` + `Opacity`（`IsSeen = Visible && Opacity != 0`）。
- 类型：`Type`（用户设置）与 `DisplayType`（实际），`ltEffect`/`ltFilter` 时两者不同；
  `UpdateDrawFace()` 由类型推导 `DrawFace`（dfOpaque/dfAlpha/dfAddAlpha/...）。
- 区域：`Rect`（图层矩形）、`ExposedRegion`（不被子层遮挡的暴露区）、
  `OverlappedRegion`（被子层遮挡区）——`CreateExposedRegion()` 生成，
  用于**只重绘暴露部分**的更新优化。
- 缓存：`CacheBitmap` + `CacheRecalcRegion`（图层缓存位图与待重建区域）；
  `Complete()` 把子树合成进缓存，减少重复合成。
- 命中测试：`htMask` / `htProvince`（按掩码或省图判定点击归属）。

### 2.3 图层类型与混合方法

- 图层类型 `tTVPLayerType`（`drawable.h`）：`ltOpaque`(=ltCoverRect)、`ltAlpha`(=ltTransparent)、
  `ltAdditive`、`ltSubtractive`、`ltMultiplicative`、`ltEffect`、`ltFilter`、
  `ltDodge`…`ltExclusion` 共 29 种，含 Photoshop 风格混合（`ltPs*`）。
- 位图混合方法 `tTVPBBBltMethod`（`LayerBitmap.h`）：`bmCopy`、`bmAlpha`、`bmAdd`、`bmSub`、
  `bmMul`、`bmDodge`、`bmScreen`、`bmAddAlpha` 系列以及 `bmPs*` 系列共 34 种。
- 拉伸类型 `tTVPBBStretchType`：`stNearest`…`stBlackmanSinc` 20 种 +
  Fast 变体 + `stRefNoClip` 标志。

### 2.4 更新区域（`tTVPComplexRect`，`ComplexRect.h`）

- `tTVPRect`：简单矩形（left/top/right/bottom，兼容 x1y1x2y2 命名）。
- `tTVPComplexRect`：矩形集合（内部以区间列表表示），支持 Or/And/Sub 等运算与迭代器。
- 图层只把**变化区域**记入更新区，合成时按"暴露区 ∩ 更新区"逐条重绘——
  这是 krkrz 经典的矩形合并优化（`TVP_UPDATE_UNITE_LIMIT` 等合并阈值）。

### 2.5 转场（`TransIntf.h/cpp`、`transhandler.h`）

- `iTVPTransHandlerProvider`：转场处理器提供者（CrossFade 等，可注册多个）。
- `tTVPSimpleOptionProvider` / `tTVPSimpleImageProvider`：把脚本对象包装成
  选项/图像提供者。
- 转场合成通过 `TVPGetRenderManager()->GetRenderMethod("UnivTransBlend"...)` +
  `OperateRect` 完成（见 TransIntf.cpp）。

---

## 3. 图层 / 位图层（`cpp/core/render/LayerBitmap.h/.cpp`）

### 3.1 类继承关系

```
tTVPBitmap                      原始 DIB 位图（Bits / BitmapInfo / Pitch / Palette）
   │
tTVPNativeBaseBitmap            位图基类：持有 iTVPTexture2D* Bitmap
   │                              + 字体/文本（SetFont/DrawText/DrawGlyph/GetTextWidth...）
   │                              + GetTextureForRender（写时独立）
   │
iTVPBaseBitmap                  绘制 API：Fill / CopyRect / Blt / StretchBlt /
   │                              AffineBlt / DoBoxBlur / 伽马 / 翻转 / 灰度 ...
   ├── tTVPBaseBitmap            province image 用（软件 RenderManager）
   └── tTVPBaseTexture           常规图层用（当前 RenderManager）
         └── tTVPDestTexture     LayerManager 的合成目标（HoldAlpha 控制）
```

### 3.2 关键机制：写时独立（Copy-on-Write）

`tTVPNativeBaseBitmap::GetTextureForRender(isBlendTarget, rc)`：

- 需要混合目标或整图操作 → `Independ()`（复制像素，脱离共享）。
- 整图只读渲染 → `IndependNoCopy()`（零拷贝引用）。
- 部分区域操作 → `Independ()`。

这是"图层间共享图像数据"（Bitmap 赋值给多个 Layer）与"各自独立绘制"之间的平衡点。

### 3.3 绘制 API 的落点

所有绘制最终都转成 **RenderMethod + OperateXxx** 调用，例如：

- `Blt`：`mgr->GetRenderMethod(opa, hda, method)` → `OperateRect(...)`
  （opa==255 && bmCopy && !hda 时退化为 `CopyRect`）。
- `StretchBlt`：设置 `StretchType` 参数 → `OperateRect`（内部 `TVPImageUtils::ResizeRGBA`）。
- `AffineBlt`：`OperateTriangles`（仿射变换，可多线程分块）。
- 文本：FreeType 光栅化 → `InternalBlendText` 逐字混合进位图。

---

## 4. 软件合成内核（`cpp/core/render/RenderManager.h/.cpp`）

这是 **Layer/Bitmap 的运算核心**，用户特别要求解读的部分。

### 4.1 两个接口

```cpp
class iTVPTexture2D          // 贴图抽象（软件实现为内存位图）
{
    Width / Height / GetInternalWidth / SetSize
    GetFormat()              // Gray/RGB/RGBA/Compressed
    GetScanLineForRead(l) / GetScanLineForWrite(l) / GetPixelData / GetPitch
    Update(pixel, format, pitch, rc)   // 局部更新
    GetPoint(x,y) / SetPoint(x,y,clr)
    IsStatic() / IsOpaque() / GetTextureData(picData, pic_pitch)
    RefCount / AddRef / Release         // 引用计数，延迟回收（_toDeleteTextures）
};

class iTVPRenderManager      // 渲染管理器抽象
{
    CreateTexture2D(...)  ×4 重载：像素/位图/流/已有贴图拷贝
    GetRenderMethod(name) / CompileRenderMethod(glsl, nTex, flags)
      / GetOrCompileRenderMethod
    OperateRect(method, tar, reftar, rctar, textures)          // dst ← tex1..texN
    OperateTriangles(method, nTri, tar, reftar, rcclip, pttar, textures)
    OperatePerspective(method, nQuads, tar, reftar, rcclip, pttar, textures)
    BeginStencil / EndStencil / SetRenderTarget               // 预留 GPU 接口
    IsSoftware() / GetName() / GetRenderStat
};
```

### 4.2 注册表与单例

- `TVPRegisterRenderManager(name, factory)` + `REGISTER_RENDERMANAGER` 宏：
  各实现静态注册；`tTVPSoftwareRenderManager` 注册名为 `"software"`。
- `TVPGetRenderManager()`：默认取 `"software"`（当前唯一实现），惰性创建 + `Initialize()`。
- `TVPGetSoftwareRenderManager()`：独立单例（province image 专用，与主管理器分开）。
- `TVPIsSoftwareRenderManager()`：当前渲染管理器是否为软件实现
  （脚本层已无 GPU 合成路径，此函数主要用于诊断/扩展）。

### 4.3 软件贴图实现（`RenderManager.cpp`）

| 类 | 说明 |
|---|---|
| `tTVPSoftwareTexture2D_static` | 直接引用外部像素指针（零拷贝），`IsStatic()==true` |
| `tTVPSoftwareTexture2D_compress` | 压缩格式（TLG 等）：**延迟解压**，`GetPixelData()` 才解压；3 帧未用自动释放（`tTVPContinuousEventCallbackIntf`） |
| `tTVPSoftwareTexture2D` | 常规贴图：`tTVPBitmap` 引用（AddRef）或自持像素缓冲 |

### 4.4 RenderMethod 注册表（软件混合函数库）

`tTVPSoftwareRenderManager::Initialize()` 注册了几十种方法
（`Register_1/2/3/4`，实现位于 `gl/tvpgl.cpp`、`gl/blend_function.cpp`、
`gl/blend_functor_c.h`、`gl/blend_variation.h`），按功能分组：

- **填充**：`FillARGB`、`FillColor`、`FillMask`、`RemoveConstOpacity`
- **复制**：`Copy`、`CopyColor`、`CopyMask`、`CopyOpaqueImage`
- **Alpha 混合**：`ConstAlphaBlend`（+ `_d` 保持目标 alpha、`_a` 附加 alpha 变体）、
  `ConstColorAlphaBlend` 系列
- **带色图**：`ApplyColorMap`（+ `_d`/`_a` 变体）、`RemoveOpacity`
- **PS 混合**：`PsNormal`…`PsExclusion`（每组 4 个变体：保持 alpha/附加 alpha 组合）
- **特效**：`DoGrayScale`、`DoBoxBlur`/`DoBoxBlurAlpha`、`AdjustGamma`（+`_a`）、
  `AlphaToAdditiveAlpha`、`AdditiveAlphaToAlpha`
- **转场**：`ConstAlphaBlend_SD(_d/_a)`、`UnivTransBlend(_d/_a)`

每种方法对应 `blend_functor_c.h` 中的模板化像素函数；`GetRenderMethod(opa, hda, method)`
按不透明度/是否保持目标 alpha/混合方法查表（`tRenderMethodCache`）。

### 4.5 三种运算路径

- `OperateRect`：普通矩形混合。先做目标裁剪 + 源区线性映射，
  不等尺寸时经 `TVPImageUtils::ResizeRGBA` 预缩放，再调
  `tTVPRenderMethod_Software::DoRender` 逐行执行混合函数。
- `OperateTriangles`：仿射/三角变形。
  - 矩形→矩形退化路径直接走 `OperateRect`；
  - 平行四边形容器走 `InternalAffineBlt`（**多线程分块**，`TVPExecThreadTask`）；
  - 一般情况按四边形网格插值。
- `OperatePerspective`：透视变换（`TVPImageUtils::GetPerspectiveTransform` +
  `WarpPerspectiveRGBA`），先渲染到临时纹理再 `DoRender` 到目标。

---

## 5. 图层管理器 / 绘制设备（`LayerManager.*`、`DrawDevice.*`、`LayerTreeOwner.*`）

### 5.1 三个角色

```
iTVPLayerTreeOwner           窗口侧：持有 LayerManager 列表
   ▲                           StartBitmapCompletion / NotifyBitmapCompleted /
   │                           EndBitmapCompletion / 光标 / IME / 输入事件分发
tTVPLayerManager             图层树管理器：Primary、焦点、模态、捕获、
   ▲                           UpdateRegion、DrawBuffer（tTVPDestTexture）
   │                           UpdateToDrawDevice → Primary->CompleteForWindow
tTVPBasicDrawDevice          绘制设备：AddLayerManager / Update / Show
   ▲                           Show() 取 DrawBuffer 上传窗口
tTVPDrawable                 合成目标抽象：GetDrawTargetBitmap / DrawCompleted
```

### 5.2 `tTVPLayerManager` 职责

- **图层树**：`AttachPrimary` / `DetachPrimary`、`GetAllNodes`（全局 Z 序）、
  `SetFocusTo` / 焦点遍历 / 模态层栈 / 鼠标捕获 / 触摸捕获。
- **输入分发**：`NotifyClick/MouseDown/KeyDown/Touch*` 系列 → `Primary*` 系列
  沿图层树分发（命中测试 + 事件冒泡）。
- **更新区**：`AddUpdateRegion` / `UpdateRegion`（`tTVPComplexRect`）；
  `UpdateToDrawDevice()` → `Primary->CompleteForWindow(this)`。
- **合成缓冲**：`GetDrawTargetBitmap` / `DrawCompleted` 把各图层 Blt 进
  `DrawBuffer`（`tTVPDestTexture`，`HoldAlpha` 控制是否保持目标 alpha）。

### 5.3 一帧合成流程（软件路径）

```
tTVPBasicDrawDevice::Update
  └─ Manager->UpdateToDrawDevice()
       └─ tTJSNI_BaseLayer::CompleteForWindow(drawable)
            ├─ Manager->GetLayerTreeOwner()->StartBitmapCompletion(Manager)
            ├─ InternalComplete2(UpdateRegion, drawable)     // 软件路径
            │    ├─ QueryUpdateExcludeRect()                 // 查找不透明遮挡
            │    ├─ 按条带拆分（TVPGraphicSplitOperationType）
            │    └─ Draw(drawable, r, ...)                   // 递归绘制子树
            │         └─ 各子层 Complete → GetDrawTargetBitmap → DrawCompleted
            └─ EndBitmapCompletion(Manager)
```

- `InternalComplete2`：唯一完成路径（早期曾存在 `InternalComplete2_GPU`/`Draw_GPU`
  GPU 分支，因带宽与兼容性问题已移除——Layer 树恒为软渲染，见 §1 注解）。
- `Complete(rect)`：图层缓存（CacheBitmap）重建，`CacheRecalcRegion` 为空时直接复用缓存。

### 5.4 绘制设备上屏

```
tTVPBasicDrawDevice::Show()
  └─ Manager->GetDrawBuffer() → buf->GetTexture()
       └─ form->UpdateDrawBuffer(tex)     // form = iWindowLayer（MainWindowLayer.cpp）
            └─ TVPUpdateTexture(pSprite, ...)   // 上传窗口贴图
```

---

## 6. 窗口贴图合成与渲染后端（第 ⑤ 层）

### 6.1 TVPSprite 与合成器（`TVPCompositor.cpp`）

- `TVPSprite`（`PlatformView.h`）：窗口贴图描述——
  `texture`（后端不透明句柄）/ `type`（0 窗口 / 1 modal / 2 overlay）/
  `xPos,yPos,scale,width,height,isVisible`。
- `TVPCompositor` 是纯调度器：
  - `TVPJoinTexture` / `TVPDepartTexture`：维护参与合成的 sprite 列表。
  - `TVPRenderOnce(winW, winH)`：`BeginFrame` → 绘制 currentSprite 与 overlay
    （统一 `TVPCalcLetterbox` 等比缩放居中）→ `EndFrame`。
  - `TVPCreateTexture` / `TVPUpdateTexture` / `TVPDestroyTexture`：
    窗口贴图生命周期管理（转发给后端）。

### 6.2 渲染后端接口（`core/render/TVPCompositor.h`，单一合并接口）

```cpp
class iTVPRenderBackend {          // 一个接口同时承担两个角色
    GetName() / IsHardware()
    // ---- 帧控制（窗口合成）----
    BeginFrame(w,h) / EndFrame()
    // ---- 窗口贴图（上屏合成）----
    CreateWindowTexture / UpdateWindowTexture / DestroyWindowTexture
    DrawWindowTexture(handle, x, y, w, h)      // 像素坐标，含 letterbox
    // ---- 2D 网格渲染（离屏目标 + 一般贴图 + 蒙版/混合 + DrawMesh）----
    CreateTarget / SetTarget / ClearTarget / LockTarget / UnlockTarget
    CreateTexture / UpdateTexture / DestroyTexture      // 一般贴图
    SetMask / SetBlendMode(0/1/3/4/6/21) / DrawMesh      // 蒙版 + 混合 + 网格
    // ---- Layer 合成（DrawDeviceD3D 用；软件 RenderManager 混合语义）----
    LayerSetBlend(method, opacity, uniformColor) / LayerDrawRect(texture, x, y, w, h, uv0..1)
    FetchInfo()
};
```

**合并设计**：每个后端只有一个类、一个抽象接口；窗口贴图与一般贴图在接口上
显式区分（`*WindowTexture` vs `*Texture`）——GPU 后端两者是同一实现
（`CreateWindowTexture == CreateTexture`）；软件后端区分
窗口贴图（SDL_Texture，经平台钩子）与一般贴图（CPU buffer）。
插件（emoteplayer）经 `TVPGetRenderBackend()` 直接获得当前后端即 2D 渲染器，
无独立的 2D 渲染器注册表。

**Layer 合成（第三个角色）**：`LayerSetBlend/LayerDrawRect` 供 DrawDeviceD3D 合成
用，混合公式遵循软件 RenderManager（tvpgl 的 bm* 方法，含 `>>8` 截断语义），
与 2D 网格（emoteplayer 约定）明确区分；三后端实现与软件合成逐像素一致
（允许 ±1 舍入，`LBM_COPY` 精确直写）。详见 `docs/rendering-architecture.md` §2、
`docs/drawdevice-d3d.md` §4.2。

### 6.3 三个后端实现

| 后端 | 文件 | 窗口合成 | 2D 网格 | Layer 合成 |
|---|---|---|---|---|
| OpenGL/GLES | `backend/GLRenderBackend.{h,cpp}` | 窗口 shader（330 core / 300 es）+ 四边形 | 网格 shader（330 core / 100 es）+ FBO 目标/蒙版/混合 | layer shader + 固定函数混合状态（软件 bm* 语义） |
| 软渲染 | `backend/SWRenderBackend.{h,cpp}` | SDL_Texture 经 `PlatformView.h` 平台钩子 | CPU 光栅化（edge function + 仿射纹理步进 + blendPixels） | 矩形光栅化 + tvpgl 整数公式（位级一致） |
| Vulkan | `backend/VulkanRenderBackend.{h,cpp}` | 交换链 + 四边形管线 | 3 个混合管线变体 + 离屏目标 + staging 回读 | `vk2d_layer.frag` + 9 条混合管线变体 |

选择逻辑：`-render` 参数（auto → opengl → vulkan → software），
`TVPGetRenderBackend()` 返回当前合成后端（兼作 2D 渲染器）。

### 6.4 平台钩子（`cpp/environ/PlatformView.h`）

- 软渲染：`TVPCreateTextureBackend` / `TVPUpdateTextureBackend` /
  `TVPDestroyTextureBackend` / `TVPRenderTextureBackend` /
  `TVPRenderClearBackend` / `TVPRenderPresentBackend`
  （各平台入口实现 SDL Renderer 细节；OHOS 无软渲染返回 false）。
- GL：`TVPSwapBuffersBackend`（SDL_GL_SwapWindow / eglSwapBuffers）。

---

## 7. 帧循环（`cpp/environ/sdl3/sdl3_app.cpp`）

```
SDL_AppIterate
  ├─ Application->Run()                 // TJS 事件循环：脚本执行、定时器、图层更新
  │     └─ 图层绘制 → 软件合成 → DrawBuffer
  │     └─ DrawDevice::Show → UpdateDrawBuffer → TVPUpdateTexture（上传窗口贴图）
  └─ TVPRenderOnce(RW, RH)              // 合成器：清屏 → 画 currentSprite/overlay → 呈现
        ├─ backend->BeginFrame()
        ├─ backend->DrawWindowTexture(...)   × currentSprite + overlay
        └─ backend->EndFrame()               // SwapBuffers / Present
```

入口拆分：`sdl3_entry.cpp`（/ `sdl2_entry.cpp`）为薄壳，主逻辑在
`sdl3_app.cpp`（/ `sdl2_app.cpp`）：参数解析 → 按 `-render` 创建后端
（失败自动回退软渲染）→ 启动引擎 → `SDL_AppIterate` 帧循环。
退出时 `TVPShutdownRenderBackend()` 先于 GL 上下文销毁（GL 后端析构需要上下文仍有效）。

---

## 8. 一帧完整数据流（端到端示例）

以"脚本修改一个 Layer 的图片并让其显示"为例：

```
① TJS2:  Layer.image = ...  /  Layer.update()
        ↓
② tTJSNI_BaseLayer 属性设置 → 标记视觉状态变化（VisualStateChanged）
        ↓
③ 引擎层更新（TVPSystem/TVPTimer 驱动）
        ↓
④ tTVPBasicDrawDevice::Update()
        └─ tTVPLayerManager::UpdateToDrawDevice()
             └─ CompleteForWindow → InternalComplete2（按 UpdateRegion 分条带）
                  └─ Draw() 递归 → 各子层 Blt/StretchBlt/AffineBlt
                       └─ iTVPBaseBitmap::Blt → RenderManager::OperateRect
                            └─ tTVPSoftwareRenderManager 执行混合函数（gl/tvpgl.cpp）
                       └─ DrawCompleted → 合成进 tTVPDestTexture (DrawBuffer)
        ↓
⑤ tTVPBasicDrawDevice::Show()
        └─ form->UpdateDrawBuffer(DrawBuffer->GetTexture())
             └─ TVPUpdateTexture(pSprite, ...) → backend->UpdateWindowTexture()
        ↓
⑥ SDL_AppIterate → TVPRenderOnce(RW, RH)
        ├─ backend->BeginFrame(RW, RH)          // 清屏/取交换链图像
        ├─ backend->DrawWindowTexture(currentSprite, letterbox 后坐标)
        ├─ backend->DrawWindowTexture(overlay...)
        └─ backend->EndFrame()                  // SwapBuffers / vkQueuePresent
        ↓
   屏幕
```

> 注意：⑤ 与 ⑥ 是两个独立阶段——⑤ 把"软件合成好的最终帧像素"上传为窗口贴图，
> ⑥ 把窗口贴图交给当前后端呈现。`-render` 只替换 ⑥ 的实现。

---

## 9. 关键文件清单

### 脚本层（面向 TJS2）
| 文件 | 内容 |
|---|---|
| `cpp/core/script/tjsNativeLayer.h/.cpp` | Layer 脚本对象（约 1.1 万行：树/绘制/输入/缓存/转场） |
| `cpp/core/script/tjsNativeBitmap.h/.cpp` | Bitmap 脚本对象 |
| `cpp/core/script/tjsNativeBitmapLayerTreeOwner.h` | 位图式 LayerTreeOwner |
| `cpp/core/script/tjsNativeLayer.cpp` | `CompleteForWindow`、`InternalComplete2`、`Draw`（无 GPU 路径，Layer 树恒为软渲染） |

### 图层 / 位图 / 合成内核
| 文件 | 内容 |
|---|---|
| `cpp/core/render/LayerBitmap.h/.cpp` | tTVPBitmap / tTVPNativeBaseBitmap / iTVPBaseBitmap / tTVPBaseTexture，全部绘制 API |
| `cpp/core/render/RenderManager.h/.cpp` | iTVPTexture2D / iTVPRenderManager / tTVPSoftwareRenderManager / RenderMethod 注册表 |
| `cpp/core/render/gl/tvpgl.cpp` | 软件混合/缩放函数库（59 万字节） |
| `cpp/core/render/gl/blend_function.cpp` 等 | 混合函数模板 |
| `cpp/core/render/ComplexRect.h/.cpp` | tTVPRect / tTVPComplexRect 更新区 |
| `cpp/core/render/drawable.h` | tTVPLayerType / tTVPDrawable |

### 图层管理 / 绘制设备
| 文件 | 内容 |
|---|---|
| `cpp/core/render/LayerManager.h/.cpp` | tTVPLayerManager / tTVPDestTexture |
| `cpp/core/render/DrawDevice.h/.cpp` | iTVPDrawDevice / tTVPBasicDrawDevice |
| `cpp/core/render/LayerTreeOwner.h/.cpp` | iTVPLayerTreeOwner / tTVPLayerTreeOwner |
| `cpp/core/render/TransIntf.h/.cpp`、`transhandler.h` | 转场 |
| `cpp/core/render/MainWindowLayer.cpp` | TVPWindowLayer（iWindowLayer 实现，持有 TVPSprite） |
| `cpp/core/render/TVPCompositor.h/.cpp` | TVPRenderOnce / 窗口贴图调度 |

### 渲染后端
| 文件 | 内容 |
|---|---|
| `cpp/core/render/TVPCompositor.h` | 单一合并接口 iTVPRenderBackend + 注册表 + 全局后端 |
| `cpp/core/render/backend/GLRenderBackend.{h,cpp}` | GL 合并后端（窗口合成 + 2D 网格 + Layer 合成） |
| `cpp/core/render/backend/SWRenderBackend.{h,cpp}` | 软件合并后端（SDL_Texture + CPU 光栅化） |
| `cpp/core/render/backend/VulkanRenderBackend.{h,cpp}` | Vulkan 合并后端 |
| `cpp/core/render/backend/shader/*` | GLSL/SPIR-V 源码与生成头 |
| `cpp/environ/PlatformView.h` | 平台钩子（软渲染/GL 呈现） |

### 入口 / 循环
| 文件 | 内容 |
|---|---|
| `cpp/environ/sdl3/sdl3_app.cpp`（+ `sdl3_entry.cpp` 薄壳） | SDL3 入口：初始化、SDL_AppIterate 帧循环、后端选择 |
| `cpp/environ/sdl2/sdl2_app.cpp`（+ `sdl2_entry.cpp` 薄壳）、`cpp/environ/ohos/ohos_entry.cpp` | SDL2 / OHOS 入口（同一套后端接口） |

---

## 10. 扩展点速查

- **换 RenderManager**（GPU 化内核）：实现 `iTVPRenderManager` +
  `REGISTER_RENDERMANAGER`。⚠ 注意：脚本层已**移除** `IsGPU`/`InternalComplete2_GPU`
  路径（`tjsNativeLayer`），Layer 树恒走软件合成——GPU 化内核需自行承担
  `GetScanLineForWrite` 等 CPU 操作的回读/上传往返（带宽见 §1 注解），
  DrawDeviceD3D 曾实现过 `tTVPRenderManager_GPU`（"d3d"），因带宽与兼容性
  问题已整体移除，GPU 加速改由后端 Layer 合成路径承担。
- **换上屏后端**：实现 `iTVPRenderBackend`（窗口合成 + 2D 网格 + Layer 合成，见 6.2）+
  `TVPRegisterRenderBackend`；`-render` 选择，初始化失败自动回退软渲染。
- **插件直接渲染**（emoteplayer）：经 `TVPGetRenderBackend()` 获得当前后端，
  离屏目标绘制 + LockTarget 回读，插件内零后端区分代码。
- **多线程**：`TVPExecThreadTask`（软件合成分块）、`TVPDrawThreadNum` 可调。
