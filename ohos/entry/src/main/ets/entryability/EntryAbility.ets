import { UIAbility, Want, AbilityConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
    onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
        hilog.info(0x3200, 'krkrsdl3', 'Ability onCreate');
    }

    onDestroy(): void {
        hilog.info(0x3200, 'krkrsdl3', 'Ability onDestroy');
    }

    onWindowStageCreate(windowStage: window.WindowStage): void {
        hilog.info(0x3200, 'krkrsdl3', 'WindowStage onCreate');

        windowStage.loadContent('pages/Index', (err: BusinessError): void => {
            if (err.code) {
                hilog.error(0x3200, 'krkrsdl3', 'Failed to load content: %{public}d', err.code);
                return;
            }
            hilog.info(0x3200, 'krkrsdl3', 'Content loaded successfully');
        });
    }

    onWindowStageDestroy(): void {
        hilog.info(0x3200, 'krkrsdl3', 'WindowStage onDestroy');
    }
}
