# emoteplayer 插件解读

> 面向贡献者：本文解读 `cpp/plugins/emoteplayer/`（约 7400 行）的架构与渲染方式——
> 资源解析、动画状态机、网格计算、与引擎渲染抽象的边界。改这个插件前先读本文。

---

## 1. 定位

emoteplayer 是一个 **Live2D 式（EMOTE/PSB 格式）动画播放器插件**：
资源解析 + 动画状态机 + 自绘渲染全部在插件内部实现，输出端把最终像素写入
KAG Layer 的主图像缓冲，由引擎的合成器继续处理。

- 文件结构：
  - `emotefile.{h,cpp}`：PSB 资源解析（压缩/加密/调色板/对象树/图标位图）
  - `emoterunner.{h,cpp}`：动画状态机（progress 构建渲染引用树）+ 网格计算 + 绘制入口
  - `emoteplayerclass.{h,cpp}`：TJS 脚本接口（EmotePlayer / SeparateLayerAdaptor）
  - `emoteplayer.cpp`：ncbind 插件注册

## 2. 动画数据流（两阶段模型）

```
脚本调用 progress(mstime) ──► 推进 clockPassed，构建/更新"渲染引用树"（ref 树）
脚本调用 draw(layer)      ──► 用 ref 树绘制一帧 → 回读到 CPU → 写入 Layer → Update()
```

- **ref 树（progress 阶段，每帧重建）**：
  - `emotemotionref::progress` 按 priority 重建 `_nodeCache`，递归展开子 motion；
  - `emotenoderef::progress` 线性扫 frameList 定位当前/下一帧，线性插值所有属性
    （坐标/角度/缩放/透明度/混色），按 `inheritMask` 组合变换链；
  - 图标节点在 CPU 上求值双三次 Bezier 面并细分网格（默认 8×8=81 顶点/128 三角形，
    `_meshVertices` 布局即 `{x,y,u,v}`，与后端的 DrawMesh 顶点格式一致）。
- **绘制（draw 阶段）**：把 ref 树展平后按 `getCurrentRenderZ` painter 排序，
  逐节点绘制。

## 3. 渲染方式（与引擎渲染抽象的边界）

插件**不区分渲染后端**，只面向 `iTVPRenderBackend` 的 2D 网格接口
（经 `TVPGetRenderBackend()` 获得当前后端）：

- **目标**：每个播放器持有主目标 + 蒙版目标（`CreateTarget`，GL 后端=FBO、
  软渲染=CPU 缓冲、Vulkan=离屏图像），尺寸随 Layer 变化重建（`ResetDrawArea` /
  `checkDrawArea`）。
- **蒙版**：`hasStencil` 节点先把蒙版层画进蒙版目标，再 `SetMask` 过滤主体
  （alpha>=128 有效），与后端的蒙版语义一致。
- **混合**：`SetBlendMode(bm)`（0 普通 / 1,4 乘色 / 3 加色 / 21 纯色替换 / 6 跳过），
  网格顶点直接传递 `_meshVertices`。
- **回读输出**：`LockTarget` 取 CPU 像素（GL 经 glReadPixels、软渲染零拷贝、
  Vulkan 经 staging）→ memcpy 进 `ths->GetMainImagePixelBufferForWrite()` → `Update()`，
  让引擎把这一层合成进最终画面。
- **纹理**：图标位图统一 RGBA 字节序，经后端的 `CreateTexture/UpdateTexture` 上传
  （GL 生成 mipmap、软渲染/Vulkan 为 CPU/GPU 缓冲），句柄存于 `emoteicon::selftexture`。

> 与引擎其他部分的分工：插件不触碰 DrawDevice / RenderManager / TVPCompositor，
> 唯一输出口是"改 Layer 主图像缓冲 + Update()"。

## 4. 工程遗留与注意点（贡献须知）

以下是现状中需要留意的地方，改动前先理解它们：

- **ref 树每帧全量重建**（`_nodeCache` clear+重建、子 motion 每帧 new/delete、
  字符串键反复 istringstream 解析）——主线程 CPU 热点。
- **字符串键带尾随 '\0'**：`parseString` 会把 '\0' 并入 std::string，
  大量代码依赖这个约定（如 label 拼接后补 '\0' 再查表），**不要顺手"清理"**，
  会破坏查找逻辑。
- **蒙版为"不考虑复合蒙版"的实现**：`stencilCompositeMaskLayerList` 只取首个
  有效蒙版层。
- **软渲染路径（SW 后端）是保底实现**：行为与 GPU 后端一致（含 bm 混合公式、
  蒙版 alpha>=128 判定），改动 GPU 语义时必须同步软渲染实现，反之亦然。
- **`isSelfClear`**：true=draw 自主清屏；false=依赖脚本调用 `clear()` 清屏
  （多次 draw 叠加）。`ClearTarget(isSelfClear)` 语义由后端解释。
- **图标数据双份**：`emoteicon::data`（CPU 像素，解析产物）与后端纹理并存，
  GL 模式纹理含 mipmap。

## 5. 常见修改点

| 想改什么 | 改哪里 |
|---|---|
| 动画插值/参数化/时间轴 | `emoterunner.cpp` 的 progress 系列 |
| 网格细分密度/贝塞尔求值 | `buildSubdivMesh` / `evaluateSurfaceChain`（emoterunner.cpp） |
| 混合/蒙版语义 | 后端 `SetBlendMode` / `SetMask`（core/render/backend/）与插件 draw 调用处 |
| 输出方式（去回读直通 GPU） | `EmotePlayer::draw`（emoteplayerclass.cpp），需后端支持"目标直接作纹理" |
| 图标格式/解码 | `emotefile.cpp` 的 readIconTobuffer / ensureLoad |
