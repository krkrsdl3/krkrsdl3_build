# KAG3 Layer 体系研究报告（KAG 系统脚本 + tjsNativeLayer 引擎实现）

> 范围：KAG3 系统脚本（引擎分发的 system/main 脚本集）与引擎
> `tjsNativeLayer.*` / `LayerManager.*` / `DrawDevice.*`。目标：梳理全部 Layer 的
> 父子关系与 Z 顺序机制，D3D / 非 D3D 两种模式的类对应，为 DrawDeviceD3D 的
> 合成设计提供事实依据。

---

## 1. 总体结论（TL;DR）

1. **Layer 树 = 唯一合成顺序来源**：引擎的合成顺序 = `Children` 数组的深度优先
   遍历（`tTJSNI_BaseLayer::Draw` 递归，先父后子、子按数组序），即"从底到顶"
   逐层 Blt 进 DrawBuffer。**任何"Z 序"最终都体现在 Children 数组顺序里**。
2. **absolute 机制只是"重排 Children 的工具"**：层设 `absolute` → 父层进入
   `AbsoluteOrderMode` → 该层被移动到 Children 中按 `AbsoluteOrderIndex` 升序的
   位置（`ChildChangeAbsoluteOrder`）。未设 absolute 的子层其 `AbsoluteOrderIndex`
   初始化为树序。
3. **KAG 主窗口（非 D3D）只有一个 LayerManager**（primary = `_primaryLayer`），
   sysbase / fore.base / back.base / uibase / 消息层全挂在同一棵树里。
4. **D3D 模式下 `sysbase = null`**，而 BaseLayer/SystemBaseLayer 构造固定
   `Layer(win, win.sysbase)` → **fore.base、back.base、uibase 各自成为独立
   primary（独立 LayerManager）**——这是 D3D 模式 `drawDevice.primaryLayers`
   出现多个 manager 的根源（已运行时确认，见 §10）。每个独立 primary 的
   DrawBuffer 初始为不透明黑 0xFF000000，D3D 合成必须"清为全透明后按 alpha
   重绘"（见 §9 与 docs/drawdevice-d3d.md §2.5）。
5. **表裏（fore/back）是"双缓冲页面"**：fore.base/back.base 是两个固定 Layer
   对象；表显示、裏隐藏（非 D3D 由 `initBaseVisible` 控制）；转场 = 表以裏为源
   过渡，完成后**脚本变量 fore↔back 引用互换** + `initBaseVisible()`。
6. **世界层（立绘/背景/消息窗）Z 序**由 absolute 值决定：
   `character/base≈0..N` → `消息框=1000000` → `msgwin=1000001+`（envinit.tjs）。

---

## 2. Layer 类继承体系（脚本层 → 原生 Layer）

```
原生 tTJSNI_Layer（引擎 tjsNativeLayer.*）
├── KAGLayer            KAGLayer.tjs       — KAG 层基类（index 属性→absolute）
│   ├── AnimKAGLayer    AnimationLayer.tjs — 动画支持（move/zoom/fade）
│   │   ├── MessageLayer MessageLayer.tjs  — 消息框（表/裏各一套）
│   │   │     ├── faceLayer（FaceLayer，表情）
│   │   │     ├── nameLayer（NameLayer，名字）
│   │   │     ├── lineLayer（MessageLineLayer，文字行）
│   │   │     └── subLayers[]（LinkButton 等）
│   │   ├── ButtonLayer / DialogLayer / CheckBoxLayer / EditLayer / SliderLayer
│   │   └── ClickGlyphLayer（行/页等待记号，挂 BaseLayer 下）
│   ├── AffineLayer      AffineLayer.tjs  — 仿射变换层
│   │   └── EnvGraphicLayer（非 D3D 世界层，+EnvGraphicBase 多继承）
│   ├── AnimationLayer / MapSelectLayer ...
│   └── MessageLineLayer
├── SystemBaseLayer      BaseLayer.tjs    — 系统基座（D3D: drawPlane=Both）
│   └── BaseLayer        BaseLayer.tjs    — fore.base / back.base
├── HistoryLayer         HistoryLayer.tjs — 履历（挂 uibase 下）
└── （引擎原生 Layer）

原生 D3DLayer（插件 DrawDeviceD3D）—— Layer 树之外
└── D3DAffineLayer（脚本 D3D.tjs）        — 仿射 GPU 层（absolute→frontIndex）
    └── D3DEnvGraphicLayer（+EnvGraphicBase）— D3D 世界层

原生 D3DImage / D3DPicture / D3DRefImage / D3DEmotePlayer（D3D.tjs 包装）
```

关键点：
- **EnvGraphicLayer（非 D3D 世界层）是多继承** `AffineLayer + EnvGraphicBase`：
  它有 Layer 部分（挂 fore.base/back.base 下），另有 EnvGraphicBase 提供
  zpos/order/absoluteBase/camera 等世界逻辑。
- **D3DEnvGraphicLayer** 继承 `D3DAffineLayer + EnvGraphicBase`：**没有 Layer
  部分**，是纯 GPU 直通层（在 Layer 树外），Z 由 `frontIndex` 表达
  （`D3DAffineLayer.absolute` 属性映射到 frontIndex/backIndex）。

---

## 3. KAG 主窗口 Layer 树（非 D3D，KAGWindow 构造 MainWindow.tjs 1733-1810）

```
_primaryLayer  (new Layer(this, null))      ← primary（唯一 LayerManager）
 │  全屏黑底 fillRect(0xff000000)，ltOpaque
 ├─ sysbase     (new Layer(this, _primaryLayer))  非 D3D 才有
 │    全屏透明，ltOpaque，hasImage=false（"トップレイヤ"）
 │    ├─ fore.base  (BaseLayer)     表背景：背景图/立绘/世界层挂载点
 │    │    ├─ fore.messages[i] (MessageLayer)  表消息框
 │    │    │    ├─ faceLayer / nameLayer / lineLayer(MessageLineLayer) / subLayers
 │    │    └─ 世界层（EnvGraphicLayer，运行时创建挂载）
 │    ├─ back.base  (BaseLayer)     裏背景（initBaseVisible 置 visible=false）
 │    │    └─ back.messages[i] (MessageLayer)  裏消息框
 │    └─ uibase     (SystemBaseLayer)  系统 UI 基座（ltBinder，透明）
 │         ├─ historyLayer (HistoryLayer)
 │         ├─ _debugwin / skipNoDispWin（调试/跳过窗口）
 │         └─ 系统菜单/对话框等（DialogLayer 族，运行时创建）
 └─ [TransLayer（懒创建，包装 SystemBaseLayer，画面切换用）]
```

- 创建顺序（= add 顺序 = 树序从底到顶）：主层 → sysbase → fore.base → back.base
  → uibase → historyLayer → 消息层（allocateMessageLayers）。
- **`window.add(layer)` 只是把对象加入窗口 ObjectVector（生命周期管理），
  不改变 parent**；树的父子关系由 `Layer(win, parent)` 构造决定。
- 非 D3D：**只有一个 primary**（_primaryLayer），其余层全部挂在树下。

---

## 4. Z 顺序机制（三层体系）

### 4.1 树序（OrderIndex / Children 顺序）
- `OrderIndex`：层在**父的 Children 数组**中的序号（`RecreateOrderIndex`）。
- 引擎合成按 Children 顺序 DFS（§1），所以**树序 = 绘制顺序**。

### 4.2 absolute（绝对 Z）模式
- 层 `SetAbsoluteOrderIndex(v)` → 父层 `SetAbsoluteOrderMode(true)` →
  `ChildChangeAbsoluteOrder`：把该层移到 Children 中"第一个
  `AbsoluteOrderIndex >= v` 的层之前"。
- 进入 absolute 模式时，**所有子层 AbsoluteOrderIndex 初始化为当时的树序**；
  之后设过 absolute 的层按新值重排，未设的保持树序值。
- **`GetAbsoluteOrderIndex()` 语义陷阱**：父层非 absolute 模式时返回**树序**
  （`GetOrderIndex()`），只有父层为 absolute 模式才返回 AbsoluteOrderIndex。

### 4.3 OverallOrderIndex（全局 DFS 序）
- `Manager->RecreateOverallOrderIndex()`：从 primary 出发 DFS 编号，
  **无排序**，就是树序的线性化；供转场/捕获等按全局顺序处理。

### 4.4 KAG 实际使用的 Z 值（absolute 体系）
| 对象 | absolute / zorder | 来源 |
|---|---|---|
| 主层 _primaryLayer | （树序最底） | MainWindow 1733 |
| 背景 base/bg（stage 类） | zorder 30 | envinit objectList |
| 角色立绘 ch*（character/clayer） | zorder 100，absoluteBase≈0 | envinit |
| 事件层 ev* | zorder 250-256 | envinit |
| 消息框 fore.messages | **absolute = 1000000 + i*1000** | MainWindow reorderLayers |
| 消息窗 face（msgwin 类） | absoluteBase = **1000001** | envinit 2141 |
| SystemBaseLayer（uibase，D3D） | frontIndex = 5000000（indexBase） | BaseLayer.tjs |

**世界层的 absolute = absoluteBase + 排序索引**（world.onUpdateAbsolute 按
isUnder/orderzpos 排序后分配 `v.absolute = v.absoluteBase + i`）。

---

## 5. 表裏（fore/back）双页切换体系

### 5.1 结构
- `fore` / `back` 是 KAGWindow 的两个**脚本对象**，各自持 `base`（BaseLayer）、
  `messages[]`（MessageLayer）。fore.base/back.base 是两个**固定 Layer 对象**。

### 5.2 显隐（非 D3D，MainWindow `initBaseVisible` 1554-1569）
```tjs
uibase.visible = true;
if (isD3D) {
    fore.base.drawPlane = DrawPlaneFront;
    back.base.drawPlane = DrawPlaneBack;
    fore.base.visible = true;            // 不隐藏 back.base（D3D 分支）
} else {
    fore.base.visible = true;
    back.base.visible = false;           // 裏隐藏——同一时刻只显示表
}
```
- 非 D3D：**back.base 平时隐藏**（visible=false），只在转场中作为转场源参与。

### 5.3 内容加载（backlay / forelay / page）
- `*tag|backlay` → 内容/层操作目标 = **裏**（`getLayerPageFromElm(elm, backlay)`
  选 `back`/`fore`；`backupLayer` 用 `assignComp()` 表裏间复制）。
- `*tag|page=back` → 目标层 = back 侧（`getLayerFromElm`）。

### 5.4 转场（MainWindow 6954-7002）
```tjs
if (isD3D) {
    drawDevice.startTransition(e);       // D3D：设备级 crossfade（composite 快照）
} else {
    back.base.stopTransition();
    fore.base.beginTransition(method, true, back.base, elm); // 表以裏为源
}
```
- 非 D3D：**表（旧画面）以裏（新画面）为源**做 Layer 转场（crossfade 等）。
- D3D：设备把当前 composite 快照到 PrevCompositeTarget，逐帧
  `prev*(1-p) + current*p`。

### 5.5 转场完成（`onTransitionEnd` 6995-7019）
```tjs
fore.messages[i].assignTransSrc();      // 状态复制
var tmp = fore; fore = back; back = tmp; // 引用互换（Layer 对象不变！）
current = (currentPage?back:fore).messages[currentNum];
forEachEventHook('onExchangeForeBack');  // → world.basePlane = 0（世界层回表）
initBaseVisible();                       // 新表显示、新裏隐藏
```
- **fore/back 只是脚本变量互换**，树结构不变；"新表"= 原 back.base 对象
  （已预载新画面），"新裏"= 原 fore.base 对象（旧画面，隐藏待复用）。
- **世界层联动**（world.tjs）：
  - `prepareTransition()`（4462）：`basePlane = 1`，世界层 `setPlane(1)` 移入裏
    （back.base 下/Back 平面）；旧层转 trans 层（addTransLayer）。
  - `onExchangeForeBack()`（4478）：`basePlane = 0`，世界层 `setPlane(0)` 回表。

### 5.6 世界层 setPlane（world.tjs EnvGraphicLayer）
```tjs
function setPlane(plane) {
    var absolute = this.absolute;
    parent = owner.world.getBaseLayer(plane);   // plane=0→fore.base，1→back.base
    this.absolute = absolute;                   // 保持 Z
}
```
- `getBaseLayer(plane)`：`plane ? kag.back.base : kag.fore.base`。
- `getPlane(target)`：`target.parent == kag.fore.base ? 0 : 1`。

---

## 6. 世界层体系（EnvObjectWorld / EnvLayerObject）

- `EnvObjectWorld`（world.tjs 3096+）：KAG 的"环境/世界"宿主，管理
  `envlayerList`（EnvLayerObject 列表）、`basePlane`（当前创建目标）、
  `getD3DDevice()`（返回 `kag.drawDevice`）。
- `EnvLayerObject`：每个世界对象持 `targetLayer`（当前显示层）+ `hideLayer`
  （转场消去层）；`createLayer(src)` 按模式创建：
  ```tjs
  if (kag.isD3D && d3d) layer = new D3DEnvGraphicLayer(this, world.basePlane, name);
  else                 layer = new EnvGraphicLayer(this, world.basePlane, name);
  ```
- `world.onUpdateAbsolute()`（3215）：对所有世界层按 `isUnder`（orderzpos/order/
  link 比较）排序，分配 `absolute = absoluteBase + i`——**非 D3D 直接设 Layer
  absolute（树内重排）；D3D 设 frontIndex（D3DAffineLayer.absolute 属性）**。
- envinit.tjs 类配置：`character`（zorder 100）、`stage`/`base`（zorder 30）、
  `event`（zorder 250+）、`msgwin`（zorder 4000，absoluteBase=1000001）、
  `emotion`（parent=character，order 3）等。

---

## 7. D3D 模式的差异与类对应

| 角色 | 非 D3D | D3D |
|---|---|---|
| 窗口绘制设备 | BasicDrawDevice（单 manager） | DrawDeviceD3D（Managers 数组） |
| 系统基座 | sysbase（Layer，挂主层下） | **sysbase = null** |
| 表/裏背景 | fore.base / back.base（挂 sysbase 下） | fore.base / back.base（**parent=null → 独立 primary**，见 §10） |
| 系统 UI 基座 | uibase（挂 sysbase 下） | uibase（独立 primary） |
| 消息框 | MessageLayer（挂 fore.base/back.base） | 同左（挂 fore.base/back.base） |
| 世界层 | EnvGraphicLayer（Layer 树内，absolute 排序） | **D3DEnvGraphicLayer（树外，frontIndex 排序）** |
| 转场 | fore.base.beginTransition（Layer 转场） | drawDevice.startTransition（composite crossfade） |
| 裏的显隐 | back.base.visible=false（initBaseVisible） | **back.base 不隐藏**（D3D 分支）——裏内容平时也进 DrawBuffer |
| 世界层平面 | parent 切换（fore.base↔back.base） | drawPlane 切换（Front↔Back） |

- **普通 Layer 的 D3D 附加属性**（LayerD3DAttach，drawPlane/frontIndex/backIndex）：
  `_primaryLayer.drawPlane=0(frontIndex=0)`；`fore.base.drawPlane=Front`；
  `back.base.drawPlane=Back`；`uibase.drawPlane=Both(frontIndex=5000000)`
  （MainWindow 1737-1743 / initBaseVisible / SystemBaseLayer）。
- **D3D 世界层 frontIndex = absoluteBase + i**（D3DAffineLayer.absolute 属性
  setter → frontIndex=backIndex=v）——实测游戏中 ≈0..N（小值），
  uibase=5000000，主层=0。

---

## 8. 消息框与 UI 层细节

- `allocateMessageLayers`（MainWindow 6330+）：`fore.messages[i] =
  new MessageLayer(this, fore.base, ...)`、`back.messages[i] = new
  MessageLayer(this, back.base, ...)`；`setCompLayer` 表裏配对；
  末尾 `reorderLayers(false, true)` → **消息框 absolute = 1000000 + i*1000**。
- MessageLayer 内部子层：faceLayer（表情）、nameLayer（名字）、
  lineLayer（MessageLineLayer，文字行）、subLayers（Link* 系列）。
- HistoryLayer / _debugwin / skipNoDispWin 挂 **uibase** 下；
  DialogLayer 族（对话框/按钮/选择肢）由系统在 uibase 下动态创建。
- **非 D3D 完整 Z 序（从底到顶）**：
  `主层 → 背景(stage) → 立绘(character) → 事件层(ev) → 消息框(1000000) →
  消息窗(msgwin 1000001+) → uibase(树序最顶) → 系统对话框`。

---

## 9. 对 DrawDeviceD3D 合成的启示

1. **普通 Layer 树合成 = 软渲染 DrawBuffer**（与基准同路径）——引擎合成顺序
   就是树序，无需也不应重排。
2. **当前实现的 Z 方案**（DrawDeviceD3D::RenderFrame）：先画 D3D 世界层
   （frontLayers，frontIndex≈0..N；backLayers 仅转场期间），再在**其上**合成
   `layerManagerIndex` 指向的 manager DrawBuffer（消息/UI）。世界层在消息框
   之下、uibase 之下，与 non-D3D absolute 层序一致。代价：**只有当前 manager
   的 DrawBuffer 被合成**（消息框与背景同处 fore.base 树，被当作一个整体），
   且 DrawBuffer 必须透明化（清 0,0,0,0 + SetHoldAlpha(false) + LBM_ALPHA），
   否则空区域的不透明黑会盖住世界层（"uibase 黑白表面"根因）。
3. **Managers 数组（已实证）**：D3D 模式注册顺序固定为
   {プライマリレイヤ, fore.base, back.base, uibase}（诊断日志），与 add 顺序
   一致；`layerManagerIndex` 由脚本 setPrimaryFocus 驱动：平时 fore.base，
   打开对话框/菜单 → uibase（openDialog 把 dialog.parent 设为 uibase 后
   currentDialog setter 调 setPrimaryFocus）。
4. **D3D 模式裏（back.base）不隐藏**：back.base 是独立 manager，平时不被合成
   （layerManagerIndex 不指向它）；backlay 内容只有转场/切页时才可见。
   实测游戏的 back.base DrawBuffer 长时间全空（黑/透明），未使用 backlay。
5. **backLayers/frontLayers 两组**：世界层按 drawPlane 分成 Front/Both 组与
   Back 组，组内按 frontIndex 排序；Back 组仅转场期间参与合成。

---

## 10. 运行时验证结果（DrawDeviceD3D 诊断日志实证）

1. ✅ **fore.base/back.base/uibase 各自成为独立 LayerManager**：manager 名录
   = {プライマリレイヤ, 表-背景, 裏-背景, uibase(无名)}，共 4 个，注册顺序与
   add 顺序一致；`primaryLayers.count` 参与 uibase frontIndex 计算。
2. ◐ **消息框 absolute（1000000）**：消息层挂在 fore.base 下随 manager 合成，
   reorderLayers 在 D3D 分支同样执行（消息框内容正确出现在 DrawBuffer 中）；
   absolute 具体值未直接打印。
3. ✅ **实测游戏未使用 backlay**：back.base DrawBuffer 长时间全空（修复前为
   全不透明黑，修复后为全透明）。
4. ◐ **D3D 世界层 frontIndex 值域**：世界层按 frontIndex 排序绘制正确（画面
   遮挡关系正确）；具体数值未打印（绝对Base 由游戏设定）。
5. ✅ **TransLayer 未产生额外 manager**：运行全程 n=4 恒定（TransLayer 懒创建
   的 SystemBaseLayer 未注册或未被创建）。
