# krkrsdl3 窗口系统架构

> 面向贡献者：本文解读窗口系统的分层职责、事件流、生命周期与统一呈现入口。
> 窗口系统在重构后收敛为三层：脚本绑定（`tjsNativeWindow.*`）→ 引擎核心
> （`TVPWindow.*`）→ 窗口管理（`WindowManager.*`）。

---

## 1. 分层职责

```
TJS 脚本对象 (Window)
   │
   ▼
tTJSNI_Window        cpp/core/script/tjsNativeWindow.*   （script 侧）
   │  持有 TVPWindow*，只做最小的脚本绑定与转发；
   │  维护脚本侧附属对象（ObjectVector、VideoOverlay 列表）
   ▼
TVPWindow            cpp/core/main/TVPWindow.*           （引擎侧核心）
   │  唯一窗口实现类（具体类，无抽象基类）：
   │  sprite/paint box、draw device、iTVPLayerTreeOwner、
   │  关闭/模态状态机、IME、鼠标键模拟、速度追踪、
   │  On* 输入事件入口（引擎处理 + 触发 TJS 事件）
   ▲
   │ 投递 tTVPOn*InputEvent（引擎事件队列）
   │
WindowManager        cpp/core/main/WindowManager.*       （窗口管理）
      窗口列表（含主窗口/激活窗口）、scancode 状态、
      SDL 平台事件分发（krkrsdl3::KRKR_Trig_*）
```

**原则**：非 script 部分（TVPWindow / WindowManager / DrawDevice / TVPCompositor
等）不得 include script 侧的 `tjsNative*` 头文件；script 侧可依赖引擎侧。
引擎侧仅允许对 `tTJSNI_BaseLayer` / `tTJSNI_BaseVideoOverlay` 做前向声明。

## 2. 事件流

```
SDL 事件 → environ/*_app.cpp
  └─ krkrsdl3::KRKR_Trig_MouseDown/MouseUp/MouseMove/MouseScroll/KeyDown/KeyUp/TextInput
       └─ WindowManager：坐标换算（sprite offset/scale）、scancode 状态维护
            └─ TVPPostInputEvent(tTVPOn*InputEvent(TVPWindow*, ...))   // 引擎事件队列
                 └─ Deliver() → TVPWindow::On*（引擎侧：DrawDevice 转发 + 触发 TJS 事件）
                      ├─ DrawDevice->OnClick/OnMouseDown/...（图层命中/回调）
                      └─ TVPPostEvent(Owner, "onClick", ...)           // TJS 事件
                           └─ tjsNativeWindow.cpp 的 TVP_ACTION_INVOKE 成员（脚本可覆写）
```

- 输入事件类（`tTVPOn*InputEvent`）与窗口枚举定义在 `TVPWindow.h`（引擎侧）。
- 鼠标滚轮（`KRKR_Trig_MouseScroll`）不排队，直接调用 `TVPWindow::OnMouseWheel`。
- `TVPGetKeyMouseAsyncState` / `TVPGetJoyPadAsyncState`：scancode 状态由
  WindowManager 维护。

## 3. 生命周期

| 阶段 | 行为 |
|---|---|
| 构造 | `tTJSNI_Window::Construct` → `new TVPWindow`（构造时自动注册到 WindowManager、创建 sprite）→ 设置 Owner → 创建默认 PassThrough draw device |
| 使用 | TJS 属性/方法经绑定转发到 TVPWindow |
| 关闭（脚本 close） | `TVPWindow::Close` → `OnCloseQuery`（发 `onCloseQuery` TJS 事件）→ `OnCloseQueryCalled`（主窗口：Invalidate 脚本对象 → 绑定 Invalidate → 删除窗口；非主窗口：隐藏） |
| 关闭（程序） | `OnClose`：先 `NotifyWindowClose()`（标记已脱离）→ Invalidate 脚本对象 → 自删 |
| 对象失效 | `tTJSNI_Window::Invalidate` → 取消事件/窗口更新 → 断开 VideoOverlay → 失效 ObjectVector → 释放 draw device → 删除 TVPWindow（若未自删） |
| 终止 | `TVPClearAllWindows()` 兜底清空列表 |

- 借用纹理的解除：DrawDevice 析构时调 `TVPWindow::ReleaseBorrowedTexture()`；
  TVPWindow 析构时 `DrawDevice->SetWindowInterface(nullptr)` 作为安全网。

## 4. 窗口列表（WindowManager）

- `TVPWindowVector`（创建序）+ `TVPMainWindow`（首个创建）+ `CurrentWindowLayer`（激活窗口）。
- 注册/注销：`TVPRegisterWindowToList` / `TVPUnregisterWindowToList`（TVPWindow
  构造/析构自动调用）。
- 激活语义：`SetVisible(true)` → `BringToFront()`（旧激活窗口右移一屏并
  `OnReleaseCapture`）；隐藏/销毁激活窗口时从后向前选择下一个可见窗口。
- `TVPIsFirstWindow`：首窗口负责平台窗口尺寸（`TVPSetWindowSize`）与全屏
  （`TVPSetWindowFullscreen`）的联动。

## 5. 统一呈现入口

TVPWindow 只提供一个呈现入口（见 `docs/gpu-readback-design.md` §2.2 A1）：

```
TVPWindow::PresentTexture(void* texture, tjs_int w, tjs_int h)
  ├─ GPU 后端：sprite 纹理别名（borrowedTexture，零拷贝）
  └─ 软件后端：LockTexture 零拷贝读取 → TVPUpdateTexture 上传窗口贴图
                （尺寸不一致时 SetSize 同步 paint box/sprite/首窗口平台尺寸）
```

各 DrawDevice 自行把呈现源转化为 compositor 贴图：

| DrawDevice | 转化 |
|---|---|
| `tTVPBasicDrawDevice::Show` | DrawBuffer（iTVPTexture2D）→ `LockCPURead` → scratch 一般贴图 → `PresentTexture`；GPU 驻留纹理（GPU RenderManager 注入）带 `GetTextureHandle()` 时直传 |
| `DrawDeviceD3D::PresentToWindow` | GPU 后端直传 `GetTargetTexture(CompositeTarget)`（零拷贝）；SW 后端经 `PresentScratchTexture` 中转 |

借用语义：`TVPSprite::borrowedTexture` 标记借用的纹理句柄，`TVPDestroyTexture`
不销毁借用句柄；`ReleaseBorrowedTexture()` 解除借用。

## 6. 文件清单

| 文件 | 职责 |
|---|---|
| `cpp/core/script/tjsNativeWindow.h/.cpp` | tTJSNI_Window（薄绑定）+ tTJSNC_Window（TJS 类注册，事件成员声明） |
| `cpp/core/main/TVPWindow.h/.cpp` | TVPWindow 引擎核心 + 输入事件类 + 窗口枚举 |
| `cpp/core/main/WindowManager.h/.cpp` | 窗口列表 + scancode 状态 + KRKR_Trig_* 事件分发 |
| `cpp/core/render/transhandler.h` | 转场 handler 接口（未变） |

> 历史说明：旧架构为 `WindowIntf.*`（tTJSNI_BaseWindow/tTJSNI_Window）+
> `MainWindowLayer.*`（TVPWindowLayer，iWindowLayer 实现）+ 抽象接口
> `iTVPWindow`/`iWindowLayer` 的多层链条；重构后合并为上述三层。
