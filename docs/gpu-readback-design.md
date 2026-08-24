# 防 GPU→CPU 回读设计（纹理驻留与显式同步）

> 面向贡献者：本文调查"注入 GPU RenderManager（`TVPSetRenderManager`）后，
> 哪些代码路径会强制 GPU→CPU 像素回读"，并给出防回读的接口设计与改造清单。
> 背景：渲染内核默认完全软渲染（`docs/rendering-system.md` §1）；`TVPSetRenderManager`
> 已预留插件注入 GPU 渲染管理器的机制（`RenderManager.cpp:4973`），`TVPTrans`
> 已完成按当前渲染管理器分派（见 `TVPTrans.h` 文件头）。

---

## 1. 现状调查

### 1.1 纹理驻留的既有事实

| 事实 | 位置 |
|---|---|
| `tTVPBaseTexture::GetRenderManager()` 返回 **当前可切换的** `TVPGetRenderManager()`，图层/位图/临时缓冲的纹理都由"当前管理器"创建 | `LayerBitmap.cpp:1670/1680` |
| `tTVPBaseBitmap`（ProvinceImage）固定使用软件管理器 | `LayerBitmap.cpp:1649` |
| 唯一 `iTVPTexture2D` 实现是软件纹理 `tTVPSoftwareTexture2D`；GPU 管理器需自带纹理实现 | `RenderManager.cpp:849` |
| 上屏 sprite 是后端窗口贴图（不透明 `void*` 句柄）；`TVPUpdateTexture` 走 **CPU 缓冲** 上传 | `TVPCompositor.cpp:168` |
| 图层绘制（Blt/StretchBlt/AffineBlt/Fill/文本）已全部是 "渲染方法 + `OperateRect/Triangles`" 形态 | `LayerBitmap.cpp` 全篇 |
| DrawDeviceD3D 已有 GPU 合成目标**零拷贝上屏**模式（`spr->texture = GetTargetTexture(...)`） | `DrawDeviceD3D.cpp:634-655` |
| 文本渲染：FreeType 字形在 CPU 暂存 → `CreateTexture2D/Update` 上传 → 渲染方法混合（GPU 安全） | `LayerBitmap.cpp:2505+` |

结论：**绘制路径已经"管理器无关"，注入 GPU 管理器后合成自动走 GPU；真正的风险集中在 CPU 像素访问（回读）调用点。**

### 1.2 回读点清单（按风险分类）

#### A. 显式脚本读 —— 保留语义，但必须"显式化 + 缓存"

| # | 调用点 | 位置 |
|---|---|---|
| A1 | Bitmap 像素 API：`getPixel/setPixel/getAlpha/setMask/scanline` | `core/script/tjsNativeBitmap.cpp:70-234` |
| A2 | Layer 像素 API：`pointInImage`、`getScanLineForWrite` 等 | `core/script/tjsNativeLayer.cpp:2886-3000` |
| A3 | 保存/导出、视频叠加层、AlphaMovie、wave buffer、LoadBMP 8bpp 转换 | 各媒体/插件路径 |

#### B. 直接 CPU 写操作 —— GPU 驻留时不可用，需 GPU 实现或显式驻留切换

| # | 操作 | 位置 |
|---|---|---|
| B1 | `Copy9Patch`（memcpy 直写） | `LayerBitmap.cpp:778` |
| B2 | `UDFlip` / `LRFlip` | `LayerBitmap.cpp:1467/1523` |
| B3 | `InternalDoBoxBlur` | `LayerBitmap.cpp:1387` |

（`DoGrayScale` / `AdjustGamma` / `ConvertAddAlphaToAlpha` 已是渲染方法，安全。）

#### C. 已 GPU 安全 —— 无需改动

- 全部 Blt/StretchBlt/AffineBlt/Fill/CopyRect/文本（渲染方法）
- TVPTrans 混合（已按 `TVPGetRenderManager()` 分派）
- LayerManager 合成管线（Complete/DrawCompleted/UpdateToDrawDevice，纯渲染方法）
- ProvinceImage（固定软件）

---

## 2. 设计：纹理驻留模型与显式同步

### 2.1 `iTVPTexture2D` 接口扩展（`core/render/RenderManager.h`）

```cpp
class iTVPTexture2D {
    // ---- 驻留查询 ----
    virtual bool IsCPUResident() const { return true; }   // 软件纹理 = true；GPU 纹理 = false
    bool IsGPUResident() const { return !IsCPUResident(); }
    virtual void* GetTextureHandle() { return nullptr; }  // GPU 驻留时的后端句柄（sprite 别名用）

    // ---- 显式同步（带缓存，防乒乓）----
    // 返回 CPU 像素（软件实现零拷贝返回真实缓冲；GPU 实现做一次回读并缓存）
    virtual void* LockCPURead();
    virtual void UnlockCPU();
    // CPU 数据已修改，下次 GPU 使用前需上传
    virtual void MarkCPUModified();
    // 纹理已驻留到 GPU，CPU 缓存失效
    virtual void InvalidateCPUCache();
};
```

原则（写进接口注释）：
1. **读不切换驻留**——CPU 访问只从缓存读，绝不隐式回读后丢弃缓存；
2. **写才标记脏**——`MarkCPUModified` 后，下次 GPU 侧使用前由 GPU 实现上传；
3. **一帧内同一纹理最多一次回读 + 一次上传**（脏位保证）；
4. 现有 `GetScanLineForRead/Write`、`GetPoint/SetPoint`、`GetTextureData`、`GetPixelData` **语义不变**，GPU 实现统一基于 `LockCPURead` 缓存实现，使调用方无感知但代价显式化；
5. **显式回读允许，隐式回读禁止**——本设计的目的是消灭"每帧/高频路径里无感知的回读"，而不是禁止回读本身（见 §2.6）。

软件实现：全部零拷贝（`LockCPURead` 直接返回内存）；行为与现状逐像素一致。

### 2.2 热路径改造 —— 已实现 ✅

#### A1：统一呈现入口 `TVPWindow::PresentTexture`（唯一呈现路径）

TVPWindow 只提供一个呈现入口 `PresentTexture(void* texture, w, h)`（compositor 体系
可采样贴图），源 → 贴图的转化由各 DrawDevice 自己完成：
- **软渲染设备**（`tTVPBasicDrawDevice::Show`）：`iTVPTexture2D`（软渲染 DrawBuffer）→
  `LockCPURead` → 上传到自有 scratch 一般贴图 → `PresentTexture`；
  GPU 驻留纹理（GPU RenderManager 注入）自带 `GetTextureHandle()` 时直传，**零回读**；
- **GPU 设备**（`DrawDeviceD3D::PresentToWindow`）：GPU 后端直传
  `GetTargetTexture(CompositeTarget)`（sprite 别名，零拷贝）；软件后端目标（CPU 缓冲）
  → `PresentScratchTexture` 中转 → `PresentTexture`（SW 保底路径）。
- `PresentTexture` 内部：GPU 后端 sprite 纹理别名（`borrowedTexture` 标记，§2.3）；
  软件后端 `LockTexture` 零拷贝读取 → `TVPUpdateTexture` 上传窗口贴图；尺寸不一致时
  `SetSize` 同步 paint box / sprite / 首窗口平台尺寸（防止呈现数据超出窗口被裁剪）。
- 借用解除：`TVPWindow::ReleaseBorrowedTexture()`（DrawDevice 析构时调用；
  Window 析构经 `SetWindowInterface(nullptr)` 解除设备引用）。
- 转化辅助：后端接口新增 `LockTexture`（SW=CPU 缓冲零拷贝读取；GPU 返回 nullptr 走别名）。

#### A2：`htMask` 命中测试

`tjsNativeLayer.cpp` `_HitTestNoVisibleCheck` 的 htMask 分支改经
`MainImage->GetTexture()->LockCPURead()` 读像素（同一指针事件内多次命中共享一次回读；
软件路径零拷贝，行为不变）。`htProvince` 走固定软件位图，不动。

### 2.3 sprite 所有权（`environ/PlatformView.h`）

`TVPSprite` 增加 `bool borrowedTexture = false;`：
- `TVPDestroyTexture`：`borrowedTexture` 时不销毁句柄，只置空；
- 别名路径设置 `borrowedTexture = true`；`TVPCreateTexture` 创建的归 sprite 所有。
- 这同时修掉 DrawDeviceD3D 现有别名路径的潜在双重销毁（`spr->texture = GetTargetTexture(...)` 后由 sprite 析构销毁目标纹理）。

### 2.4 C 类直接 CPU 写操作策略（P1）

优先：为 `Copy9Patch` / `UDFlip` / `LRFlip` / `InternalDoBoxBlur` 提供渲染方法（GL/VK 可表达）；
未实现前：在这些操作入口对 GPU 驻留纹理做显式切换：

```cpp
void* pixels = tex->LockCPURead();      // 一次性回读（带缓存）
... 直接 CPU 写 ...
tex->MarkCPUModified();                 // 下次 GPU 使用前自动上传
```

保证同一纹理单帧至多一次回读+一次上传，且写路径显式可见。

### 2.5 B 类显式读（P2）

- 脚本像素 API 语义保留；GPU 实现经 `LockCPURead` 缓存自动获得"多次读取共享一次回读"；
- 各媒体/导出路径在代码注释中标注"显式回读，允许"；
- `docs/rendering-architecture.md` 补充"GPU 管理器注入契约"一节（纹理驻留语义 + 必须提供的渲染方法集，含 TVPTrans 方法集）。

### 2.6 允许的显式回读（白名单）

回读是合法操作，以下场景**允许并且应当**使用显式回读接口；设计只保证它们不混入隐式热路径：

| 场景 | 推荐接口 | 说明 |
|---|---|---|
| 截屏 / 游戏存档缩略图 | 整帧：`iTVPRenderBackend::LockTarget(CompositeTarget)` 一次回读（DrawDeviceD3D 软件保底路径同款）；局部：`tex->LockCPURead()` | 低频、用户触发；整帧回读应取**最终合成目标**而非逐图层回读 |
| 图片导出 / 保存（`saveToFile` 等） | `tex->LockCPURead()` / `GetTextureData` | 显式导出，回读一次后可复用缓存 |
| 像素脚本 API（`getPixel`/`pointInImage`/`getScanLine` 等） | `LockCPURead()`（GPU 实现自动缓存） | 语义不变，多次读取共享一次回读 |
| 视频叠加层 / AlphaMovie / wave buffer / 解码回读 | 现有 `GetScanLine*` 等 | 解码器语义本身在 CPU 侧，允许 |
| 调试 / 分析工具 | `LockCPURead()` | 允许，标注即可 |

白名单的判定标准：**用户显式触发、低频、语义上需要 CPU 像素**。凡是每帧/指针事件/合成管线内部自动发生的回读，一律视为隐式回读，禁止（A 类已完成）。

---

## 3. 改动文件清单（含优先级）

| 优先级 | 文件 | 改动 |
|---|---|---|
| ✅ 已完成 | `core/render/RenderManager.h` | `iTVPTexture2D` 驻留/同步接口（软件实现零拷贝默认实现） |
| ✅ 已完成 | `core/main/TVPWindow.cpp` | 统一呈现入口 `PresentTexture`（A1）+ 尺寸同步 |
| ✅ 已完成 | `environ/PlatformView.h` / `core/render/TVPCompositor.cpp` | `TVPSprite::borrowedTexture` + `TVPDestroyTexture` 所有权 |
| ✅ 已完成 | `core/script/tjsNativeLayer.cpp` | `htMask` 走 `LockCPURead` 缓存（A2） |
| P1 | `core/render/LayerBitmap.cpp` | C 类操作：渲染方法化或显式驻留切换 |
| P2 | `core/script/tjsNativeBitmap.cpp`、`core/script/tjsNativeLayer.cpp` | 像素脚本 API 注释/语义化（GPU 实现自动缓存） |
| P2 | 媒体/插件路径 | 标注显式回读 |
| P3 | `docs/` | GPU RenderManager 注入契约文档 |
| ✅ 已完成 | `plugins/DrawDeviceD3D` | 呈现统一走 `Window::PresentTexture`（GPU 直传 / SW 中转） |

## 4. 验收标准

1. 注入 GPU RenderManager 后，单帧合成链路（LayerManager → DrawBuffer → Show → sprite → TVPRenderOnce）**零隐式回读**（A1/A2 已实现）；
2. 软件路径行为逐像素不变（默认渲染管理器下所有新增接口零拷贝）；
3. 显式脚本读（B 类）语义不变，且多次读取共享一次回读；
4. 同一纹理在一帧内最多一次回读 + 一次上传（脏位保证）；
5. 白名单场景（截屏/存档/导出/像素 API，§2.6）全部走显式接口，功能不受影响且回读次数可预期（整帧截屏 = 每帧合成目标一次回读）。
