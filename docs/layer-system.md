# Layer 体系与 DrawDeviceD3D 合成

> 两部分合一：**KAG3 图层体系**（脚本层类继承、Z 序、表裏双页、世界层）与
> **DrawDeviceD3D 实现**（D3D 模式的 primary 划分、每帧合成顺序、FrontBuff 语义、
> 注册机制、验证与遗留）。渲染后端接口见 `rendering.md`。

---

## 1. 结论（TL;DR）

1. **Layer 树是唯一合成顺序来源**：合成顺序 = `Children` 数组的深度优先遍历
   （先父后子、子按数组序），从底到顶逐层 Blt 进 DrawBuffer。任何"Z 序"最终都
   体现在 Children 顺序里。
2. **absolute 只是重排 Children 的工具**：设了 absolute 的层被移动到
   "第一个 `AbsoluteOrderIndex >= v` 的层之前"；未设的层其
   `AbsoluteOrderIndex` 初始化为当时的树序。
3. **非 D3D 主窗口只有一个 LayerManager**（primary = `_primaryLayer`），
   sysbase / fore.base / back.base / uibase / 消息层全在同一棵树里。
4. **D3D 模式 `sysbase = null`**，而 BaseLayer/SystemBaseLayer 构造固定
   `Layer(win, win.sysbase)` → fore.base / back.base / uibase **各自成为独立
   primary（独立 LayerManager）**，这是 `drawDevice.primaryLayers` 有多个
   manager 的根源。独立 primary 的 DrawBuffer 初始为不透明黑 `0xFF000000`，
   合成前必须清成全透明（§6.4）。
5. **表裏是双缓冲页面**：fore.base / back.base 两个固定 Layer；非 D3D 时裏隐藏，
   转场完成**只交换脚本变量引用**（Layer 对象不变）。
6. **世界层 Z 序**由 absolute 决定：立绘/base ≈ 0..N → 消息框 1000000 →
   msgwin 1000001+ → uibase frontIndex 5000000。

---

## 2. 类继承体系

```
原生 tTJSNI_Layer（tjsNativeLayer.*）
├── KAGLayer            KAGLayer.tjs        — index 属性 → absolute
│   ├── AnimKAGLayer    AnimationLayer.tjs  — move/zoom/fade
│   │   ├── MessageLayer MessageLayer.tjs   — 消息框（表/裏各一套）
│   │   │     └ faceLayer / nameLayer / lineLayer / subLayers[]
│   │   ├── ButtonLayer / DialogLayer / CheckBoxLayer / EditLayer / SliderLayer
│   │   └── ClickGlyphLayer
│   ├── AffineLayer     AffineLayer.tjs
│   │   └── EnvGraphicLayer（非 D3D 世界层，+ EnvGraphicBase 多继承）
│   └── AnimationLayer / MapSelectLayer / MessageLineLayer ...
├── SystemBaseLayer     BaseLayer.tjs       — 系统基座（D3D: drawPlane=Both）
│   └── BaseLayer       BaseLayer.tjs       — fore.base / back.base
└── HistoryLayer        HistoryLayer.tjs    — 履历（挂 uibase）

原生 D3DLayer（插件，Layer 树之外）
└── D3DAffineLayer（D3D.tjs）               — GPU 直通层（absolute→frontIndex）
    └── D3DEnvGraphicLayer（+ EnvGraphicBase）— D3D 世界层
原生 D3DImage / D3DPicture / D3DRefImage / D3DEmotePlayer
```

- `EnvGraphicLayer` = `AffineLayer + EnvGraphicBase`：有 Layer 部分（挂
  fore.base/back.base 下），EnvGraphicBase 提供 zpos/order/absoluteBase/camera。
- `D3DEnvGraphicLayer` = `D3DAffineLayer + EnvGraphicBase`：**没有 Layer 部分**，
  纯 GPU 直通层，Z 由 `frontIndex` 表达。

---

## 3. 树结构与 Z 序

### 3.1 非 D3D 的树（KAGWindow 构造，MainWindow.tjs）

```
_primaryLayer (new Layer(this, null))        ← 唯一 primary（全屏黑底）
 ├ sysbase (Layer, 全屏透明)
 │   ├ fore.base (BaseLayer)   表背景：背景图/立绘/世界层挂载点
 │   │    ├ fore.messages[i] (MessageLayer) → face/name/line/subLayers
 │   │    └ 世界层（EnvGraphicLayer 运行时挂载）
 │   ├ back.base (BaseLayer)   裏背景（initBaseVisible 置 visible=false）
 │   │    └ back.messages[i]
 │   └ uibase (SystemBaseLayer) 系统 UI 基座
 │        ├ historyLayer / _debugwin / skipNoDispWin
 │        └ 系统菜单、对话框（DialogLayer 族）
 └ [TransLayer（懒创建）]
```

创建顺序 = 树序（从底到顶）。`window.add(layer)` 只做生命周期管理，**不改变
parent**；父子关系由 `Layer(win, parent)` 决定。

### 3.2 三套 Z 序

| 机制 | 含义 | 用途 |
|---|---|---|
| `OrderIndex` | 在父 Children 数组中的序号 | **= 绘制顺序** |
| `AbsoluteOrderIndex` | 绝对 Z，父层进入 AbsoluteOrderMode 后重排 | KAG 的 `index`/`zorder` |
| `OverallOrderIndex` | 从 primary 出发 DFS 线性化编号 | 转场、捕获等全局遍历 |

⚠ 语义陷阱：`GetAbsoluteOrderIndex()` 在父层非 absolute 模式下返回的是**树序**。

### 3.3 KAG 实际使用的 Z 值

| 对象 | 值 | 来源 |
|---|---|---|
| 主层 `_primaryLayer` | 树序最底 | MainWindow |
| 背景 base/bg（stage） | zorder 30 | envinit objectList |
| 角色立绘 ch*（character） | zorder 100，absoluteBase≈0 | envinit |
| 事件层 ev* | zorder 250–256 | envinit |
| 消息框 fore.messages | absolute = 1000000 + i*1000 | MainWindow reorderLayers |
| 消息窗 face（msgwin） | absoluteBase = 1000001 | envinit |
| uibase（D3D） | frontIndex = 5000000（indexBase） | BaseLayer.tjs |

世界层的 `absolute = absoluteBase + 排序索引`（`world.onUpdateAbsolute` 按
isUnder/orderzpos 排序后分配）。

---

## 4. 表裏（fore/back）双页

- `fore` / `back` 是两个脚本对象，各持 `base`（BaseLayer）与 `messages[]`。
- **显隐**（`initBaseVisible`）：非 D3D 里 `back.base.visible = false`（同一时刻
  只显示表）；D3D 分支反过来——`fore.base.drawPlane=Front`、
  `back.base.drawPlane=Back`，两边都不隐藏（各自是独立 manager）。
- **写内容**：`|backlay` 把目标切到裏，`|page=back` 指定 back 侧层。
- **转场**：非 D3D 走 `fore.base.beginTransition(method, true, back.base, elm)`
  （表以裏为源）；D3D 走 `drawDevice.startTransition(e)`（composite 快照逐帧
  `prev*(1-p) + current*p`）。
- **完成**（`onTransitionEnd`）：`assignTransSrc()` 复制状态 →
  **fore/back 引用互换** → `initBaseVisible()` → `onExchangeForeBack` 让世界层
  回到表面。世界层用 `setPlane(plane)` 切换 parent（`getBaseLayer`），切换时
  保存并恢复 `absolute` 以保持 Z。

---

## 5. 世界层

- `EnvObjectWorld`：管理 `envlayerList`、`basePlane`（当前创建目标）、
  `getD3DDevice()`。
- `EnvLayerObject`：持 `targetLayer` / `hideLayer`；`createLayer()` 按模式创建
  `D3DEnvGraphicLayer` 或 `EnvGraphicLayer`。
- `onUpdateAbsolute()`：按 `isUnder`（orderzpos/order/link）排序后分配
  `absolute = absoluteBase + i`——非 D3D 直接设 Layer absolute（树内重排），
  D3D 设 `frontIndex`（`D3DAffineLayer.absolute` setter）。
- envinit 类配置：`character`(100)、`stage`/`base`(30)、`event`(250+)、
  `msgwin`(4000 / absoluteBase 1000001)、`emotion`(parent=character, order 3)。

---

## 6. D3D 模式

### 6.1 与非 D3D 的差异

| 角色 | 非 D3D | D3D |
|---|---|---|
| 绘制设备 | BasicDrawDevice（单 manager） | DrawDeviceD3D（Managers 数组） |
| 系统基座 | sysbase（挂主层下） | **sysbase = null** |
| 表/裏背景 | 挂 sysbase 下 | **parent=null → 独立 primary** |
| 系统 UI 基座 | uibase（挂 sysbase 下） | uibase（独立 primary） |
| 世界层 | EnvGraphicLayer（树内，absolute） | D3DEnvGraphicLayer（**树外**，frontIndex） |
| 转场 | Layer 转场 | 设备级 composite crossfade |
| 裏显隐 | 隐藏 | 不隐藏（平时不进合成，见 6.3） |
| 世界层平面 | parent 切换 | drawPlane 切换（Front↔Back） |

**普通 Layer 的 D3D 附加属性**（`LayerD3DAttach`：drawPlane/frontIndex/backIndex，
脚本只写不读，纯排序元数据）：主层 `0/0`、fore.base `Front`、back.base `Back`、
uibase `Both / 5000000`。

### 6.2 每帧驱动

```
TVPWindow::UpdateContent()
  ├ DrawDevice->Update()            → RenderFrame()
  └ (非 VSync) DrawDevice->Show()   → PresentToWindow() → Window::PresentTexture
TVPRenderOnce()                     → BeginFrame → DrawWindowTexture(别名) → EndFrame
```

脚本侧另有显式 `dd.update(diffTime)`（转场推进 + RenderFrame + Present）。

### 6.3 RenderFrame 合成顺序

```
SetTarget(CompositeTarget) + ClearTarget(true)
  → Back 平面世界层（仅转场期间；backLayers 按 frontIndex 排序）
  → Front/Both 平面世界层（frontLayers，frontIndex≈0..N）
  → ComposeLayerManager(layerManagerIndex)    ← 消息/UI 树，透明区露出世界层
  → D3DEmotePlayer（GPU 直通动画，最上层）
  → 转场交叉淡化（PrevCompositeTarget * (1-p) + composite * p）
```

`layerManagerIndex` 由脚本 `setPrimaryFocus(layer)` 驱动：平时指 fore.base，
打开对话框/菜单时指 uibase，转场完成回 fore.base。**合成只取这一个 manager**
（消息框与背景同处 fore.base 树，被当作一个整体处理）。back.base 平时不被合成。

### 6.4 ComposeLayerManager（FrontBuff 语义，正确性关键）

```
lm->SetHoldAlpha(false)            // ltAlpha 走 bmAlphaOnAlpha（src-over，写 alpha）
buf->Fill(全屏, 0x00000000)        // 清底：空区域不带不透明黑
mgr->RequestInvalidation(全屏)      // 强制整树重绘，否则旧帧残留重叠
mgr->UpdateToDrawDevice()          // CPU 软合成（与基准同路径）
GetTextureData → UpdateTexture     // 每帧 1 次 CPU→GPU 上传
DrawQuadTo(..., BM_ALPHA)          // 透明区露出下层世界层
```

- **"uibase 黑白表面"根因**：`GetOrCreateDrawBuffer` 把 DrawBuffer 初始填成
  不透明黑 `0xFF000000`，且只重绘失效区域；空区域整幅上传后盖住下层。
- `SetHoldAlpha(false)` 必须与清底配合：hda=true 时 ltAlpha 走 `bmAlpha`
  （目标 alpha 恒 255），清底无效。
- 每帧上传次数 = 1，全部 CPU→GPU，无 GPU→CPU。

### 6.5 D3DLayer 系脚本要点

`new D3DLayer(dd)` + `drawPlane` / `frontIndex` / `backIndex` / `setMatrix(16)`；
`D3DPicture`（`assignImageRange` / `setCoord` / `blendMode` / `opacity`）；
`D3DImage.load(layer)`（Layer 位图 → GPU 贴图）；`capture(layer, index)`
（index 0 = primary，≥5000000 = D3D 层序）；`D3DEmotePlayer`（PSB 动画 GPU 直通）。

**D3DEmotePlayer 绘制**：`DrawToTarget` 把**完整的图层仿射矩阵**（`Layer->Matrix`
再平移到屏幕中心 `(W/2, H/2)`）作为 `glm::mat4` 传给
`EmotePlayer::drawToTarget`，插件内部按 `projection * _targetTrans * _affineTrans`
变换顶点后直接绘入给定目标——不再做缩放提取/取整/逆矩阵那套窗口折算。
整幅目标尺寸 = 设备尺寸，画完经 `SetBlend(BM_ALPHA) + DrawRect` 混入 composite。
`load()` 的 motionKey 必须用 `TVPGetPlacedPath`（与 ResourceManager 缓存键一致），
否则多角色会共用同一模型。

---

## 7. 为什么 Layer 树保持软渲染

`iTVPRenderManager` 的契约本质是 CPU 位图操作，GPU 化在带宽与兼容性上都不划算：

1. **带宽**：每个 `OperateRect` 都要整幅回读或上传（w·h·4 字节 PCIe），一帧
   几十上百次 blit 就是 CPU→GPU→CPU 的反复横跳，远超 GPU 混合省下的计算量。
2. **`GetScanLineForWrite` 是硬伤**：文字、PS 混合、模糊、gamma、色彩映射、
   转场、省图/蒙版只有 CPU 实现；即使 90% 操作能 GPU 化，剩下 10% 也会强制整帧往返。
3. **实际路径**：图层在 CPU 上逐层精细合成（与基准同路径，正确性天然一致），
   每帧只做一次整幅上传，之后所有合成（D3D 层、emote、转场、上屏）都在 GPU 侧：

```
CPU → 图层1 → 图层2 → … → 图层N → DrawBuffer ──(每帧一次 w·h·4)──▶ GPU 合成 → 屏幕
```

早期 `tTVPRenderManager_GPU`（"d3d"）与 `tjsNativeLayer` 的 IsGPU/GPU 合成分支
已整体移除。

---

## 8. 注册机制与脚本 API 对照

**注册宏**：`NCB_REGISTER_CLASS`（生成静态注册对象，独立类必须用这个） vs
`NCB_REGISTER_SUBCLASS`（只做 TJS 继承注册，无静态对象）。踩过的坑：独立类用
`NCB_REGISTER_SUBCLASS` 会导致类对象进不了 `_top` 链，`D3DLayer.DrawPlaneBoth`
在脚本里 undefined。

触发链：`Plugins.link("xxx.dll")` → `TVPLoadPlugin` → `ncbAutoRegister::LoadModule`
→ 按 `NCB_MODULE_NAME`（小写）注册该模块所有类。

| 脚本用法 | 引擎实现 |
|---|---|
| `new DrawDeviceD3D(w,h)` | 设备构造（不切换渲染管理器） |
| `win.drawDevice = dd` | `TVPWindow::SetDrawDeviceObject` → UpdateContent 驱动 |
| `dd.update(t)` / `dd.capture(layer,i)` / `dd.startTransition` | 对应方法 |
| `dd.primaryLayers` / `layerManagerIndex` / `transState` … | NCB 属性 |
| `new D3DLayer(dd)` + `drawPlane/frontIndex/setMatrix` | D3DLayer 类 |
| `new D3DPicture(img)` / `new D3DImage(layer)` | D3DPicture / D3DImage 类 |
| `layer.drawPlane = ...` | LayerD3DAttach 附加属性 |
| `new D3DEmotePlayer(...)` | D3DEmotePlayer（2x 世界坐标窗口，alpha 混入合成目标） |

---

## 9. 验证与遗留

**已验证**（三后端 SW/GL/VK）：

- 非 D3D 与 D3D 两种模式下均启动正常、画面一致、无脚本错误、无崩溃；
  D3D 模式 emote 角色位置/尺寸与软件基准一致。
- manager 名录固定为 `{プライマリレイヤ, 表-背景, 裏-背景, uibase}`，注册顺序 =
  add 顺序；`layerManagerIndex` 随 setPrimaryFocus 切换。
- DrawBuffer 清透明后空区域 alpha=0，世界层 + 消息/UI 分层正确，
  "uibase 黑白表面"消失；实测游戏未使用 backlay（back.base 长期为空）。
- Layer 合成混合：SW 为 tvpgl 整数公式直译（位级一致）；GL/VK 用 shader 折算
  （×255/256 模拟 `>>8`），与软件差 ≤1；`BM_COPY` 精确直写。

**遗留**：

1. 完整转场序列（world.basePlane 切换 + backLayers 参与）未逐帧验证。
2. `DrawD3DLayerPictures` 目前所有世界层都走网格路径（近似混合）；非仿射矩形
   可改走 `SetBlend + DrawRect` 的精确 Layer 语义。
3. `SetHoldAlpha(false)` 会改变目标 manager 的合成语义；中途把 drawDevice 切回
   BasicDrawDevice 时窗口合成会带 alpha（游戏通常启动时定模式，不受影响）。
4. `ComposeLayerManager` 每帧整屏 `RequestInvalidation`（全量重绘），静态画面
   本可只重绘失效区，是清底语义的取舍。
5. emoteplayer 部分脚本接口仍是 TODO 桩：`assign` / `setColor` / `pass` / `stop` /
   `skipToSync` / `getVariableFrameList`（只打日志），影响行同步、时间轴混合、
   变量帧查询等特性。（`startWind`、`setTimelineBlendRatio`、`skip` 已实现。）
6. KAG 的 `world.getD3DDevice()` 若目标游戏用到需补齐。

**调试钩子**：`KRKR_DUMP_FRAME=<目录> KRKR_DUMP_INTERVAL=<N>`（默认关闭，零开销）
在 `TVPUpdateTexture` / `PresentToWindow` 各写 `win_/d3d_<帧号>.rgba`
（magic + w/h + RGBA）。

---

## 10. 关键文件

| 文件 | 职责 |
|---|---|
| `plugins/DrawDeviceD3D/DrawDeviceD3D.*` | RenderFrame / PresentToWindow / ComposeLayerManager / 转场 / capture |
| `plugins/DrawDeviceD3D/DrawDeviceD3D_reg.cpp` | ncb 注册（设备 + D3DLayer/D3DImage/D3DPicture/D3DEmotePlayer + LayerD3DAttach） |
| `plugins/DrawDeviceD3D/D3DEmotePlayer.*` | emote 动画 GPU 直通 |
| `core/script/tjsNativeLayer.*` | Layer 脚本对象（树/绘制/输入/缓存/转场） |
| `core/render/LayerManager.*` `DrawDevice.*` `LayerTreeOwner.*` | 图层树与绘制设备 |
| `core/render/RenderManager.*` | 软件合成内核（Layer 树合成） |
| `core/render/TVPCompositor.*` + `backend/*` | 渲染后端抽象与三后端 |
