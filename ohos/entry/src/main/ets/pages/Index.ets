import { hilog } from '@kit.PerformanceAnalysisKit';
import krkr from 'libkrkrsdl3.so';
import { common } from '@kit.AbilityKit';
import { DownloadDirManager } from '../utils/DownloadDirManager';
import window from '@ohos.window';
import inputMethod from '@ohos.inputMethod';
import display from '@ohos.display';

const TAG = 'krkrsdl3';
const DOMAIN = 0x3200;

enum TouchState { IDLE, SINGLE, MULTI }

interface FingerInfo {
    startX: number;
    startY: number;
    moved: boolean;
}

@Entry
@Component
struct Index {
    private xComponentId: string = 'xcomponent_krkrsdl3';
    private xComponentController: XComponentController = new XComponentController();
    private engineInited: boolean = false;
    private gamePath: string = '';
    private density: number = 1;

    private touchState: TouchState = TouchState.IDLE;
    private activeFingers: Map<number, FingerInfo> = new Map();

    async aboutToAppear(): Promise<void> {
        hilog.info(DOMAIN, TAG, 'aboutToAppear');
        let ctx = getContext(this) as common.UIAbilityContext;
        this.density = display.getDefaultDisplaySync().densityPixels;

        try {
            krkr.registerCallbacks(
                 (title: string): void => {
                    window.getLastWindow(ctx).then((win: window.Window): void => {
                        try { win.setWindowTitle(title); } catch (e) {}
                    });
                },
                (full: boolean): void => {
                    window.getLastWindow(ctx).then((win: window.Window): void => {
                        try {
                            win.setWindowLayoutFullScreen(full);
                            win.setWindowSystemBarEnable([]);
                        } catch (e) {}
                    });
                },
                (show: boolean, _x: number, _y: number, _w: number, _h: number): void => {
                    let ctrl = inputMethod.getController();
                    try { if (show) ctrl.showTextInput(); else ctrl.hideTextInput(); } catch (e) {}
                }
            );
        } catch (e) { hilog.error(DOMAIN, TAG, 'registerCallbacks: %{public}s', String(e)); }

        try { krkr.setResourceManager(ctx.resourceManager); } catch (e) {}

        await DownloadDirManager.getInstance().init(ctx);
        await DownloadDirManager.getInstance().initDownloadDirectory();
        this.gamePath = DownloadDirManager.getInstance().getDownloadDirPath() + '/data.xp3';
        this.launchGame();
    }

    private launchGame(): void {
        if (this.engineInited || this.gamePath.length === 0) return;
        try { this.engineInited = krkr.initEngine(this.gamePath); } catch (e) {
            hilog.error(DOMAIN, TAG, 'initEngine: %{public}s', String(e));
        }
    }

    private sendTouch(type: number, xVP: number, yVP: number, button: number): void {
        if (!this.engineInited) return;
        let x = Math.round(xVP * this.density);
        let y = Math.round(yVP * this.density);
        try { krkr.sendMouseEvent(type, x, y, button); } catch (e) {}
    }

    aboutToDisappear(): void {
        try { krkr.shutdown(); } catch (e) {}
    }

    build() {
        Column() {
            XComponent({
                id: this.xComponentId,
                type: XComponentType.SURFACE,
                libraryname: 'krkrsdl3',
                controller: this.xComponentController
            })
            .onLoad((): void => {
                let sid = this.xComponentController.getXComponentSurfaceId();
                try { krkr.setSurface(sid); } catch (e) {
                    hilog.error(DOMAIN, TAG, 'setSurface: %{public}s', String(e));
                }
            })
            .onAreaChange((oldArea: Area, newArea: Area) => {
                const widthVP = newArea.width as number;
                const heightVP = newArea.height as number;
                let widthPx = Math.round(widthVP * this.density);
                let heightPx = Math.round(heightVP * this.density);
                if (widthPx > 0 && heightPx > 0) {
                    try {
                        if (typeof krkr.updateWindowSize === 'function') {
                            krkr.updateWindowSize(widthPx, heightPx);
                        }
                    } catch (e) {
                        hilog.error(DOMAIN, TAG, 'updateWindowSize error: %{public}s', String(e));
                    }
                }
            })
            .width('100%')
            .height('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')
        .onTouch((event: TouchEvent): void => {
            if (event.type === TouchType.Down) {
                for (let ct of event.changedTouches) {
                    this.activeFingers.set(ct.id, { startX: ct.x, startY: ct.y, moved: false });
                }
                let cnt = this.activeFingers.size;
                if (cnt === 1) this.touchState = TouchState.SINGLE;
                else if (cnt >= 2) this.touchState = TouchState.MULTI;
                if (cnt >= 3) {
                    this.activeFingers.clear();
                    this.touchState = TouchState.IDLE;
                }
            } else if (event.type === TouchType.Up) {
                let savedState = this.touchState;
                let lastFinger: FingerInfo | undefined;
                let lastX = 0, lastY = 0;
                for (let ct of event.changedTouches) {
                    if (this.activeFingers.size === 1) {
                        lastFinger = this.activeFingers.get(ct.id);
                        lastX = ct.x;
                        lastY = ct.y;
                    }
                    this.activeFingers.delete(ct.id);
                }
                if (lastFinger) {
                    let btn = (savedState === TouchState.MULTI) ? 2 : 1;
                    if (!lastFinger.moved)
                        this.sendTouch(0, lastX, lastY, btn);
                    this.sendTouch(1, lastX, lastY, btn);
                    this.touchState = TouchState.IDLE;
                }
            } else if (event.type === TouchType.Move) {
                if (this.touchState === TouchState.SINGLE && this.activeFingers.size === 1) {
                    let t = event.touches[0];
                    let f = this.activeFingers.get(t.id);
                    if (f) {
                        let dx = t.x - f.startX;
                        let dy = t.y - f.startY;
                        if (dx * dx + dy * dy > 64)
                            f.moved = true;
                        this.sendTouch(2, t.x, t.y, 0);
                    }
                }
            }
        })
        .onMouse((event: MouseEvent): void => {
            if (event.action === MouseAction.Press) {
                let btn = event.button === MouseButton.Right ? 2 : event.button === MouseButton.Middle ? 3 : 1;
                this.sendTouch(0, event.x, event.y, btn);
            } else if (event.action === MouseAction.Release) {
                let btn = event.button === MouseButton.Right ? 2 : event.button === MouseButton.Middle ? 3 : 1;
                this.sendTouch(1, event.x, event.y, btn);
            } else if (event.action === MouseAction.Move) {
                this.sendTouch(2, event.x, event.y, 0);
            }
        })
    }
}
