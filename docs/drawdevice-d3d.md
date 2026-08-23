# DrawDeviceD3D 实现报告：脚本层运行逻辑与引擎实现

> 范围：`cpp/plugins/DrawDeviceD3D/` 的全部逻辑、三后端（sw/gl/vk）支持、
> KAG 脚本层调用链分析、类注册机制、验证结果与遗留问题。

---

## 1. 背景：RenderManager.h 注释中的"特殊 Layer/DrawDevice"

Kirikiri 传统上所有图层合成都在 CPU 侧（软件位图 Blt）。D3D 模式引入了一套
"特殊 Layer/DrawDevice"：`DrawDeviceD3D` 作为窗口的 draw device，接管每帧合成，
普通 `Layer` 通过附加属性（`drawPlane`/`frontIndex`/`backIndex`）参与 D3D 合成排序，
`D3DLayer` 则是独立于 `Layer` 树之外的 GPU 直通绘制层。

本实现的最终架构：**Layer 树保持完全软渲染**（与渲染基准同路径，正确性天然
一致），`DrawDeviceD3D` 把当前 LayerManager 的软件 DrawBuffer **清为全透明后
按图层 alpha 重绘**、每帧一次上传到 GPU（`LBM_ALPHA`），与独立 D3D 层
（GPU 直通）合成到离屏目标后上屏；软件/GL/Vulkan 三个后端都可用（软件后端
作为保底回退）。带宽与兼容性论证见 4.3，DrawBuffer 透明化（FrontBuff 语义）
见 2.5。

---

## 2. 脚本层运行逻辑（KAG 系统脚本）

KAG 系统脚本随引擎分发（UTF-16，参考用；游戏归档通常自带一份同名脚本覆盖，
实际运行时以游戏归档内的版本为准）。D3D 相关的调用链如下。

### 2.1 启动与类加载

```
startup.tjs
  └─ Scripts.execStorage("system/Initialize.tjs")   // KAG 初始化
       └─ ... 加载 D3D.tjs / d3d.tjs（游戏或系统归档）
            ├─ Plugins.link("drawdeviceD3D.dll")    // 触发 ncb 类注册
            ├─ class D3DRefImage extends D3DImage   // 脚本子类（依赖原生类）
            └─ class D3DAffineLayer extends D3DLayer
                 ├─ 构造：super.D3DLayer(d3dDevice)  // 原生类构造，参数=设备对象
                 └─ onUpdate() 中 setMatrix(16 参数) // 仿射矩阵下沉
```

### 2.2 Window 侧的 D3D 标志（脚本属性，非引擎属性）

KAG 在 Window 类上扩展：

```tjs
property isD3D { getter() { return (drawDevice instanceof "DrawDeviceD3D"); }};
```

即：`win.drawDevice = dd` 之后 `win.isD3D` 自动为真。
**前提：`DrawDeviceD3D` 必须注册为 TJS 类**（`instanceof` 依赖类对象存在）。

### 2.3 普通 Layer 参与 D3D 合成（BaseLayer.tjs 模式）

```tjs
class SystemBaseLayer extends Layer {
  function SystemBaseLayer(win) {
    ...
    if (window.isD3D) {
      this.drawPlane = D3DLayer.DrawPlaneBoth;              // Layer 附加属性
      this.frontIndex = this.backIndex =
          indexBase + window.drawDevice.primaryLayers.count - 1;  // 层序
      type = ltAlpha;
    } else { type = ltOpaque; }
  }
}
```

- `drawPlane`/`frontIndex`/`backIndex` 由 `NCB_ATTACH_CLASS_WITH_HOOK(LayerD3DAttach, Layer)`
  挂在普通 Layer 上（getter/setter + 懒创建 native instance）。
- `primaryLayers.count`：DrawDeviceD3D 的 `primaryLayers` 属性（数组）。
- `indexBase = 5000000`：D3D 层序从 500 万起，`capture(layer, index)` 的索引约定。

### 2.4 每帧驱动（Window → DrawDevice）

```
窗口事件循环（SDL_AppIterate）
  ├─ tTJSNI_BaseWindow::UpdateContent()
  │    ├─ DrawDevice->Update()          // iTVPDrawDevice::Update → RenderFrame()
  │    └─ (非 VSync) DrawDevice->Show() // → PresentToWindow()
  └─ TVPRenderOnce()
       ├─ Backend->BeginFrame(w, h)
       ├─ DrawWindowTexture(spr->texture, ...)   // spr->texture = composite 包装
       └─ Backend->EndFrame()
```

脚本侧还有显式 `dd.update(diffTime)`（转场推进 + RenderFrame + PresentToWindow）。

### 2.5 D3D 模式的 LayerManager 划分与 RenderFrame 合成顺序

**D3D 模式下每个"基座层"都是独立 primary（独立 LayerManager）**：`sysbase=null`
（MainWindow 1767），而 SystemBaseLayer/BaseLayer 构造固定 `Layer(win, win.sysbase)`
（BaseLayer.tjs 12 行）→ `Layer(win, null)` 创建新 primary。运行时实证（诊断日志，
见 5.2）注册顺序固定为：

```
mgr[0] = プライマリレイヤ（_primaryLayer，drawPlane=0/frontIndex=0）
mgr[1] = 表-背景（fore.base，drawPlane=Front）
mgr[2] = 裏-背景（back.base，drawPlane=Back）
mgr[3] = uibase（SystemBaseLayer，drawPlane=Both/frontIndex=5000000）
```

脚本 `setPrimaryFocus(layer)`（MainWindow 623）把 layer 的根（primary）与
`drawDevice.primaryLayers` 比对并设置 `layerManagerIndex`：平时指向 fore.base
（1564/2038/5719），**打开对话框/菜单时指向 uibase**（openDialog → currentDialog
setter 1263 → dialog.parent=uibase），转场完成回 fore.base。**合成只取
`layerManagerIndex` 对应的那一个 manager**。

RenderFrame 合成顺序（非 D3D 树序的等价复现）：

```
SetTarget(CompositeTarget) + ClearTarget(true)
  → Back 平面 D3D 世界层（仅转场期间参与；backLayers 按 frontIndex 排序）
  → Front/Both 平面 D3D 世界层（frontLayers，frontIndex≈0..N）
  → ComposeLayerManager(layerManagerIndex)   ← 消息/UI 树，透明区露出世界层
  → D3DEmotePlayer（GPU 直通动画，最上层）
  → 转场交叉淡化（PrevCompositeTarget * (1-p) + composite * p）
```

世界层（D3DEnvGraphicLayer，树外 GPU 层）画在 DrawBuffer **之下**，对应非 D3D
的层序（世界层 absolute≈0..N < 消息框 1000000 < uibase 5000000）。

**ComposeLayerManager（FrontBuff 语义）**——这是本实现的关键正确性点：

```
lm->SetHoldAlpha(false)                 // ltAlpha 图层 bmAlpha → bmAlphaOnAlpha
                                        //（src-over 写入目标 alpha）
buf->Fill(全屏, 0x00000000)             // 清底：空区域不带不透明黑
mgr->RequestInvalidation(全屏)          // 强制整树重绘（否则旧帧残留重叠）
mgr->UpdateToDrawDevice()               // CPU 侧软渲染合成（与基准同路径）
GetTextureData → UpdateTexture          // 每帧 1 次 CPU→GPU 上传
DrawQuadTo(..., LBM_ALPHA)              // 透明区露出下层世界层
```

- **根因回顾（"uibase 黑白表面"）**：`tTVPLayerManager::GetOrCreateDrawBuffer` 把
  DrawBuffer 初始填为**不透明黑 0xFF000000**，且只重绘失效区域、从不清理。
  独立 primary 的 DrawBuffer 在空区域（uibase 的透明区域）就是 0xFF000000；
  整幅 `LBM_COPY` 上传 → 不透明黑盖住下层 → 黑白表面 + 旧帧内容残留重叠。
- `SetHoldAlpha(false)` 必须与清底配合：`ltAlpha` 图层在 hda=true 时走 `bmAlpha`
  （目标 alpha 恒 255 的不透明叠加），清底无效；hda=false 走 `bmAlphaOnAlpha`
  （src-over，alpha 写入目标）。
- **每帧上传次数 = 1**（只有被合成 manager 的 DrawBuffer），全部 CPU→GPU，无 GPU→CPU。

> 历史说明：早期"Z 段分段合成"（SetSegmentFilter/D3DSegmentFilter、
> GetDirectChildCount/GetDirectChild、段A/段B 两次上传）因遮挡关系问题被整体
> 回退，tjsNativeLayer 中的相关接口已删除；本文 2.5 描述的是当前实现。

### 2.6 D3DLayer 系脚本用法要点

- `new D3DLayer(d3dDevice)`；`drawPlane = DrawPlaneBoth/Front/Back`；
  `frontIndex`/`backIndex` 排序；`setMatrix(16 参数)`。
- `D3DPicture`：`assignImageRange(image, u0,v0,u1,v1)`、`setCoord(x,y)`、
  `blendMode`、`opacity`。
- `D3DImage.load(layer)`：把 Layer 位图导入 GPU 纹理；`D3DRefImage` 引用计数封装。
- `D3DEmotePlayer`：PSB emote 动画 GPU 直通（内部 emoteplayer::EmotePlayer::drawToTarget，
  绘制窗口/原点按图层矩阵折算，见 4.4）。
- `capture(layer, index)`：把 Layer 内容捕获到设备纹理（index 0 = primary，
  ≥5000000 = D3D 层序）。

---

## 3. 类注册机制（ncbind）与踩坑

### 3.1 注册宏的区别（重要！）

| 宏 | 生成内容 | 注册对象 |
|---|---|---|
| `NCB_REGISTER_CLASS(cls)` | `static ncbNativeClassAutoRegister<cls> ...;`（静态对象） | ✅ 进 `_top` 链 |
| `NCB_REGISTER_SUBCLASS(cls)` | 仅 `template<> void ncbRegistClass<ncbRegistSubClass<cls>>::Regist()`（函数特化） | ❌ **无静态对象** |

`NCB_REGISTER_SUBCLASS` 是"TJS 继承注册"（注册为某个已注册类的子类），
依赖父类注册链；**对独立类（D3DLayer/D3DImage/D3DPicture/D3DEmotePlayer）必须用
`NCB_REGISTER_CLASS`**，否则类对象不进 `_top` 链，`LoadModule` 收集不到 → 脚本里
`D3DLayer.DrawPlaneBoth` 直接 undefined（本实现踩过此坑：原 `NCB_REGISTER_SUBCLASS`
导致只注册了 2 个类，游戏脚本 BaseLayer.tjs 访问 `D3DLayer.DrawPlaneBoth` 异常）。

### 3.2 注册触发链

```
脚本 Plugins.link("xxx.dll")
  → TVPLoadPlugin → TVPLoadInternalPlugin
  → ncbAutoRegister::LoadModule(TVPExtractStorageName(name))
  → 按 NCB_MODULE_NAME（小写）查 _internal_plugins → 注册该模块所有类
```

- `NCB_MODULE_NAME` 在 reg 文件顶部定义（如 `"drawdeviceD3D.dll"`），大小写不敏感。
- 普通 C++ 类（非 tTJSNI 派生）经 `ncbInstanceAdaptor<T>::GetNativeInstance` 绑定。

### 3.3 Layer 附加属性

`NCB_ATTACH_CLASS_WITH_HOOK(LayerD3DAttach, Layer)` + `NCB_GET_INSTANCE_HOOK`
（懒创建附加实例）→ 普通 Layer 获得 drawPlane/frontIndex/backIndex。
脚本只赋值不读值，getter/setter 各写各的（引擎侧不做额外动作，纯排序元数据）。

---

## 4. 引擎实现架构（cpp/plugins/DrawDeviceD3D/ + core/render/）

### 4.1 文件清单

| 文件 | 职责 |
|---|---|
| `DrawDeviceD3D.h/.cpp` | 设备类：RenderFrame/PresentToWindow/composite/D3DLayers/转场/捕获 |
| `DrawDeviceD3D_reg.cpp` | ncb 注册（DrawDeviceD3D/D3DLayer/D3DImage/D3DPicture/D3DEmotePlayer + LayerD3DAttach） |
| `D3DEmotePlayer.h/.cpp` | emote 动画 GPU 直通（包装 emoteplayer::EmotePlayer） |
| `core/render/TVPCompositor.h/.cpp` | `iTVPRenderBackend` 抽象（窗口合成 + 2D 网格 + Layer 合成）与后端注册 |
| `core/render/backend/{SW,GL,Vulkan}RenderBackend.*` | 三后端实现 |
| `core/render/RenderManager.h/.cpp` | 软件渲染管理器（Layer 树合成内核，恒为软渲染） |

> 历史说明：早期版本存在 `GPURenderManager.cpp`（iTVPRenderManager 的 GPU 实现，
> 经 `TVPSetRenderManager` 挂载、`tjsNativeLayer::IsGPU` 切换 Layer 树合成路径），
> 因带宽与兼容性问题被**整体移除**（见 4.3），不再有"GPU RenderManager"这一层。

### 4.2 渲染后端抽象的第三个角色：Layer 合成

`iTVPRenderBackend` 现在承担三个角色（对应接口三段）：

| 角色 | 接口 | 使用者 |
|---|---|---|
| 窗口合成 | `BeginFrame/EndFrame` + `*WindowTexture` | `TVPRenderOnce`（上屏） |
| 2D 网格 | `CreateTarget/DrawMesh/SetMask/SetBlendMode` | emoteplayer 插件（动画网格 + 蒙版） |
| **Layer 合成** | `LayerSetBlend/LayerDrawRect` | DrawDeviceD3D（D3DLayer 图片、DrawBuffer 上屏、转场、D3DEmotePlayer 混入） |

Layer 合成与 2D 网格的区别：**混合公式遵循软件 RenderManager（gl/tvpgl.cpp 的
bm* 方法语义），而非 emoteplayer 的混合约定**。三后端实现与软件合成逐像素一致
（允许 ±1 舍入误差）：

| LBM 方法 | 语义（软件方法） | GL/VK 实现 |
|---|---|---|
| `LBM_COPY` | dest = src（直写） | 不混合 |
| `LBM_ALPHA` | dest += (src-dest)·(src.a·opa8>>8)>>8 | SRC_ALPHA/ONE_MINUS_SRC_ALPHA（全通道）；shader 以 ×255/256 模拟 >>8 |
| `LBM_CONSTALPHA` | dest += (src-dest)·opa8>>8（源视为不透明） | 同上，alpha 通道=opa |
| `LBM_ADD` | dest = sat(dest + src·opa8>>8)，alpha 不变 | ONE/ONE 加；shader RGB 缩放、alpha 置 0 |
| `LBM_SUB` | dest = sat(dest − s)，s=255−(255−src)·opa8>>8 | ONE/ONE 反向减 |
| `LBM_MUL` | dest.rgb = dest.rgb·s.rgb>>8，dest.a=0 | DST_COLOR/ZERO，alpha ZERO/ZERO |
| `LBM_MUL_HDA` | 同上，dest.a 保留 | DST_COLOR/ZERO，alpha ONE/ZERO |
| `LBM_FILL` | dest = uniformColor | 不混合，shader 输出颜色 |
| `LBM_COPYCOLOR/COPYOPAQUE/COPYMASK` | 保留目标 alpha / alpha 置 255 / 复制 alpha | 混合因子组合 |

坐标约定：目标像素坐标，内容 y 向下，内容顶（t=0）→ NDC −1；GL 的 FBO 行序、
VK 的 NDC 方向与 SW 的回读行序恰好一致（三后端 `LockTarget` 结果同构）。

### 4.3 为什么 Layer 树保持软渲染（CPU↔GPU 带宽与兼容性）

**核心结论：`iTVPRenderManager` 的接口契约本质是 CPU 位图操作（
`GetScanLineForWrite`/`GetPoint`/`GetTextureData`...），把它 GPU 化在带宽与
兼容性上都不划算，所以 Layer 树永远走软件 RenderManager；GPU 只承接
"整帧合成上屏"与"独立 D3D 层"。**

1. **带宽**：GPU 化 RenderManager 后，每个 `OperateRect` 都要求目标纹理
   GPU→CPU 回读（`LockTarget`）或 CPU→GPU 上传（`UpdateTargetTexture`）。
   一次全屏回读/上传就是 w·h·4 字节的 PCIe 传输；一帧几十上百次 blit
   会形成 **CPU→GPU→CPU→GPU→CPU 的反复横跳**，带宽开销远超 GPU 混合省下的
   计算量。
2. **GetScanLineForWrite 是硬伤**：大量图形处理（FreeType 文字逐字混合、
   PS 系列混合、模糊、gamma、色彩映射、转场、省图/蒙版等）只有 CPU 实现。
   一旦纹理在 GPU 侧，这些操作必须先回读、CPU 处理、再整幅上传——
   即使某个场景 90% 的操作可以 GPU 化，剩下的 10% 也会强制整帧往返。
3. **正确做法（本实现的路径）**：**Layer 分批在 CPU 上做精细处理**（文字、
   特效、逐层混合全部走软件 RenderManager，与渲染基准完全同路径），
   一帧的 CPU 结果集中为一张 DrawBuffer，**每帧只做一次 CPU→GPU 上传**，
   之后的所有合成（D3D 层、emote、转场、上屏）都在 GPU 侧完成：

   ```
   CPU ──CPU──▶ CPU ──CPU──▶ CPU ──CPU──▶ CPU ──GPU──▶ GPU
   图层1     图层2      图层N    DrawBuffer   合成目标    屏幕
   （逐层精细合成，零 GPU 往返）      │
                                    └─ 每帧一次整幅上传（w·h·4 字节）
   ```

   该方案带宽最小（每帧固定一次上传），且**与渲染基准（非 D3D 模式）逐像素
   同路径**——Layer 树的合成代码与非 D3D 模式完全相同，正确性天然一致。

### 4.4 DrawDeviceD3D 关键路径

- 构造：只保存后端引用，**不切换全局渲染管理器**（Layer 树恒为软渲染；
  `tjsNativeLayer` 的 IsGPU/GPU 合成路径已全部删除）。
- `RenderFrame`：见 2.5（清屏 → Back/Front 世界层 → 当前 manager DrawBuffer →
  emote → 转场）；`NotifyLayerImageChange → Window->RequestUpdate()`。
- `ComposeLayerManager(index)`：`dynamic_cast<tTVPLayerManager*>` →
  `SetHoldAlpha(false)` → `GetOrCreateDrawBuffer()` → `Fill(全屏, 0x00000000)` →
  `RequestInvalidation(全屏)` → `UpdateToDrawDevice()`（CPU 软合成）→
  `GetTextureData` 读像素 → `UpdateTexture` 上传（CPU→GPU，每帧 1 次）→
  `DrawQuadTo(..., LBM_ALPHA)` 混入 composite。
- `PresentToWindow`：GPU 后端 `spr->texture = GetTargetTexture(CompositeTarget)`
  （零拷贝上屏）；SW 后端 `LockTarget → UpdateWindowTexture` 回读上传。
- `DrawD3DLayerPictures`（D3DLayer 的 GPU 直通）：按 frontIndex 排序后逐层
  `SetTarget + LayerSetBlend(LBM) + DrawMesh`（4 角经仿射矩阵 → NDC；目前非仿射
  也走 DrawMesh 近似混合，可优化为 `LayerDrawRect` 精确 Layer 合成路径）；
  `blendMode`（Layer.type 常量）经 `MapLayerTypeToBlendMode` 映射到 LBM。
- `D3DEmotePlayer::Draw`（emote 世界坐标语义）：
  - 每个 D3DEmotePlayer 持独立 `emoteplayer::EmotePlayer`（共享 ResourceManager，
    资源缓存 + 解密种子类静态共享）；
  - `load()` 的 motionKey 必须用 `TVPGetPlacedPath`（与 ResourceManager 缓存键一致），
    否则查不到缓存 → play() 兜底分支会取缓存里第一个匹配文件 → 多角色加载同一模型；
  - `clone()` 完整复制（同一 motionKey + 进度/速度/变换/变量，经 ncb
    `CreateAdaptor` 包装成脚本对象）；
  - **绘制窗口**：dx_ 模型为 2x 高分辨率版，图层矩阵 (a,d,tx,ty) 是"图层空间 →
    世界（原点=屏幕中心）"的映射，故
    `limit = (W/|a|, H/|d|)`，`origin = ((W/2+tx)/a, (H/2+ty)/d)`，
    目标像素 = a·p + (tx,ty) + (W/2,H/2)；
  - 合成：整幅目标经 `LayerSetBlend(LBM_ALPHA) + LayerDrawRect` 混入 composite。
- `capture(layer, index)`：DrawBuffer（软件位图，带 alpha）→ 软件 RenderManager
  `CreateTexture2D(w,h,tex)` 拷贝 → `layer->AssignTexture`。

> 兼容性：合成路径只经核心公开接口（iTVPLayerManager/iTVPBaseBitmap/
> iTVPRenderBackend）操作，无 tjsNativeLayer 反向依赖；非 D3D 模式（及
> DrawDeviceD3D 插件未编译时）完全不经过 ComposeLayerManager。

### 4.5 Vulkan 侧的关键技术问题与修复（RADV）

1. **mesh command buffer 从未提交**：GL 是立即模式无此问题；Vulkan 的离屏
   composite 绘制全部录制在 mesh command buffer，纯 GPU 路径没有任何 LockTarget
   调用 → 全黑。**修复：`FlushMeshCommands()` 在 EndFrame 提交（先于窗口帧），
   DestroyTarget/DestroyTextureInternal 前也提交**（录制引用已销毁的
   imageView/描述符集会导致 `VK_ERROR_DEVICE_LOST`，此即早期 device lost 根源）。
2. **同提交内写后读不可见**：RADV 忽略 GENERAL→GENERAL（无 layout 转换）的
   image barrier，同一 command buffer 内"写入 target 后立即采样"结果未定义。
   **修复：每次新 pass（`!passActive_`）前无条件 `FlushMeshCommands()`**
   （提交边界提供完整可见性；每帧绘制次数有限，开销可接受）。
3. **push constant std140 布局**：网格 `{vec2 viewport@0, enableMask@8,
   enableColor@12, opa@16, pad[3]@20-31, vec4 uniformColor@32}` = 48 字节；
   Layer 合成 `{opa@0, method@4, pad@8, vec4 uniformColor@16}` = 32 字节
   （spirv-dis 验证）。
4. **blankMask 描述符**：set1（蒙版）必须按 `maskSetLayout_` 分配；Target 需要
   set0 采样包装（`texture` 字段，注册进 `textures_`）。
5. **frame fence 时序**：acquire 成功后才 reset fence；失败路径用空提交重新置位，
   避免等待悬挂。
6. **EnsureVertexBuffers**：buffer 重建时 mapped 指针必须失效重映射（悬垂修复）。

---

## 5. 验证结果

### 5.1 渲染后端 Layer 合成路径（三后端自洽）

- SW：`LayerBlendPixel` 为 tvpgl 整数公式的直接翻译（位级一致）。
- GL/VK：混合状态 + shader 折算（×255/256 模拟 >>8），与软件语义
  **逐像素一致（±1 舍入）**；`LBM_COPY` 为精确直写（diff=0）。

### 5.2 真实商业游戏验证

- 非 D3D 模式（游戏 patch 脚本取消注释 `global.DrawDeviceD3D = void;`）：
  GL/VK/SW 启动正常、画面一致、无脚本错误。
- D3D 模式（游戏 patch 脚本注释掉 `global.DrawDeviceD3D = void;`）：
  GL/VK/SW 三后端全部运行正常、无脚本异常、无崩溃；
  emote 角色（D3DEmotePlayer）位置/尺寸与软件基准一致
  （dx_ 模型经 2x 世界坐标窗口渲染，见 4.4）。
- **D3D 模式合成正确性（诊断日志实证）**：
  - manager 名录 = {プライマリレイヤ, 表-背景, 裏-背景, uibase}（独立 primary，
    注册顺序固定）；`layerManagerIndex` 随脚本 setPrimaryFocus 在 fore/back/uibase
    间切换（UILoader 加载、对话框等时机）。
  - DrawBuffer 清透明后：空区域像素 alpha=0（诊断 ASCII 图全 `_`），不再有
    不透明黑残留；世界层 + 消息/UI 分层合成画面正确（"uibase 黑白表面"消失，
    透明区露出 D3D 世界层）。
  - 早期版本"右上角 logo 上下颠倒"的差异由 IsGPU/GPU 贴图路径导致，
    移除 IsGPU、Layer 树改回软渲染后消失。
- 帧 dump 调试钩子：`KRKR_DUMP_FRAME=<目录> KRKR_DUMP_INTERVAL=<N>` 环境变量
  启用（默认关闭，零开销），`TVPUpdateTexture`（非 D3D）与
  `PresentToWindow`（D3D）各写 `win_/d3d_<帧号>.rgba`（magic + w/h + RGBA）。

---

## 6. 遗留问题

1. **转场（表裏）与对话框路径**：`transState/startTransition`（composite 快照
   交叉淡化）与对话框打开（layerManagerIndex → uibase manager）已随透明化修复
   顺带修正，但完整转场序列（world.basePlane 切换 + backLayers 参与）尚未逐帧
   验证。
2. **DrawD3DLayerPictures 非仿射走 DrawMesh**：目前所有 D3D 世界层都经 2D 网格
   路径（近似混合）；非仿射矩形可改走 `LayerSetBlend + LayerDrawRect`（Layer
   合成精确语义，与 D3DEmotePlayer 同路径）。
3. **`SetHoldAlpha(false)` 的副作用**：D3D 模式运行期间目标 manager 的
   DrawBuffer 合成语义变为 src-over（写入 alpha）；若中途把 drawDevice 切回
   BasicDrawDevice（非 D3D），窗口合成会以 alpha 语义进行——游戏通常在启动时
   决定模式，不受影响；其余游戏需留意。
4. **每帧全矩形强制合成**：ComposeLayerManager 每帧 RequestInvalidation(全屏)
   使 DrawBuffer 整树重绘（与基准全屏更新同开销）；静态画面本可只重绘失效区，
   但清底语义要求全量重绘，属当前实现的取舍。
5. **emoteplayer 引擎的部分脚本接口为 TODO 桩**：`pass`/`skip`/`stop`/
   `setColor`/`startWind`/`setTimelineBlendRatio`/`assign` 等仅打日志
   （emoteplayerclass.cpp）——影响行同步、时间轴混合等特性，尚未完整实现。
6. **`world.getD3DDevice()`**（KAG 世界对象）：KAG 的 D3D.tjs 使用；
   若目标游戏用到需要补齐（引擎 KAG 层或脚本扩展）。
7. **帧 dump 调试钩子保留**：`KRKR_DUMP_FRAME` 为 env 门控，默认不生效。

---

## 7. 附录：脚本 → 引擎 API 对照

| 脚本用法 | 引擎实现 |
|---|---|
| `new DrawDeviceD3D(w, h)` | `DrawDeviceD3D(tjs_int, tjs_int)`（不切换渲染管理器） |
| `win.drawDevice = dd` | `tTJSNI_BaseWindow::SetDrawDeviceObject` → UpdateContent 驱动 |
| `dd.update(t)` / `dd.capture(layer, i)` / `dd.startTransition` | 对应方法 |
| `dd.primaryLayers.count` / `dd.layerManagerIndex` / `dd.clearColor` / `dd.maskMode` / `dd.stretchType` / `dd.transState` | NCB 属性 |
| `new D3DLayer(dd)` + `drawPlane/frontIndex/backIndex/setMatrix` | D3DLayer 类（GPU 直通，Layer 合成路径） |
| `new D3DPicture(img)` + `assignImageRange/setCoord/blendMode/opacity` | D3DPicture 类 |
| `new D3DImage(l)` + `load/width/height` | D3DImage 类（Layer 位图 → GPU 贴图） |
| `layer.drawPlane = ...` | LayerD3DAttach 附加属性 |
| `new D3DEmotePlayer(...)` | D3DEmotePlayer 类（2x 世界坐标窗口 + Layer 合成 alpha 混入合成目标） |
