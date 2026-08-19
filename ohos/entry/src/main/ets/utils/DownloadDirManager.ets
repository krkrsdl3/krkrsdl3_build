/**
 * 下载目录管理器
 * 使用 DOWNLOAD 模式获取 Download/{bundleName}/ 目录的持久化权限
 * 参考 PPSSPP 实现
 */
import { picker } from '@kit.CoreFileKit';
import { fileUri } from '@kit.CoreFileKit';
import { fileShare } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

const TAG = '[DownloadDirManager]';
const PREFERENCES_NAME = 'download_dir_settings';
const KEY_DOWNLOAD_DIR_PATH = 'download_dir_path';
const KEY_DOWNLOAD_DIR_URI = 'download_dir_uri';

export class DownloadDirManager {
  private static instance: DownloadDirManager | null = null;
  private context: common.UIAbilityContext | null = null;
  private dataPreferences: preferences.Preferences | null = null;
  private downloadDirPath: string = '';
  private downloadDirUri: string = '';
  private initialized: boolean = false;

  private constructor() {}

  public static getInstance(): DownloadDirManager {
    if (!DownloadDirManager.instance) {
      DownloadDirManager.instance = new DownloadDirManager();
    }
    return DownloadDirManager.instance;
  }

  /**
   * 初始化管理器
   */
  public async init(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }

    this.context = context;

    try {
      this.dataPreferences = await preferences.getPreferences(context, PREFERENCES_NAME);
      await this.loadDownloadDir();

      if (this.downloadDirPath && this.downloadDirUri) {
        // 激活已持久化的权限
        await this.activateDownloadPermission();
      }

      this.initialized = true;
      console.info(`${TAG} Initialized, downloadDir: ${this.downloadDirPath}`);
    } catch (err) {
      console.error(`${TAG} Init failed: ${(err as Error).message}`);
    }
  }

  /**
   * 加载已保存的下载目录
   */
  private async loadDownloadDir(): Promise<void> {
    if (!this.dataPreferences) return;

    try {
      this.downloadDirPath = await this.dataPreferences.get(KEY_DOWNLOAD_DIR_PATH, '') as string;
      this.downloadDirUri = await this.dataPreferences.get(KEY_DOWNLOAD_DIR_URI, '') as string;
      console.info(`${TAG} Loaded downloadDir: ${this.downloadDirPath}`);
    } catch (err) {
      console.error(`${TAG} Load failed: ${(err as Error).message}`);
    }
  }

  /**
   * 保存下载目录
   */
  private async saveDownloadDir(): Promise<void> {
    if (!this.dataPreferences) return;

    try {
      await this.dataPreferences.put(KEY_DOWNLOAD_DIR_PATH, this.downloadDirPath);
      await this.dataPreferences.put(KEY_DOWNLOAD_DIR_URI, this.downloadDirUri);
      await this.dataPreferences.flush();
      console.info(`${TAG} Saved downloadDir: ${this.downloadDirPath}`);
    } catch (err) {
      console.error(`${TAG} Save failed: ${(err as Error).message}`);
    }
  }

  /**
   * 初始化下载目录（首次使用时调用）
   * 使用 DOWNLOAD 模式获取 Download/{bundleName}/ 目录
   */
  public async initDownloadDirectory(): Promise<string> {
    if (this.downloadDirPath) {
      console.info(`${TAG} Download directory already initialized: ${this.downloadDirPath}`);
      return this.downloadDirPath;
    }

    if (!this.context) {
      console.error(`${TAG} Context not initialized`);
      return '';
    }

    try {
      const documentViewPicker = new picker.DocumentViewPicker(this.context);
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;

      const result = await documentViewPicker.save(documentSaveOptions);

      if (result && result.length > 0) {
        this.downloadDirUri = result[0];
        console.info(`${TAG} Download directory URI: ${this.downloadDirUri}`);

        // 将 URI 转换为路径
        this.downloadDirPath = new fileUri.FileUri(this.downloadDirUri).path;
        console.info(`${TAG} Download directory path: ${this.downloadDirPath}`);

        // 保存到本地存储
        await this.saveDownloadDir();

        console.info(`${TAG} Download directory initialized: ${this.downloadDirPath}`);
        return this.downloadDirPath;
      }
    } catch (err) {
      console.error(`${TAG} Init download directory failed: ${(err as Error).message}`);
    }

    return '';
  }

  /**
   * 激活下载目录的持久化权限
   */
  private async activateDownloadPermission(): Promise<void> {
    if (!this.downloadDirUri) return;

    console.info(`${TAG} Activating download permission for: ${this.downloadDirUri}`);

    try {
      // 检查设备是否支持持久化权限功能
      if (!canIUse('SystemCapability.FileManagement.AppFileService.FolderAuthorization')) {
        console.info(`${TAG} FolderAuthorization not supported, skipping activation`);
        return;
      }

      const policyInfo: fileShare.PolicyInfo = {
        uri: this.downloadDirUri,
        operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE,
      };
      const policies: fileShare.PolicyInfo[] = [policyInfo];

      await fileShare.activatePermission(policies);
      console.info(`${TAG} Download permission activated successfully`);
    } catch (err) {
      const error = err as BusinessError;
      console.error(`${TAG} Failed to activate download permission: ${error.message}, code: ${error.code}`);

      // 如果权限未持久化，尝试持久化
      if (error.code === 13900001) {
        console.info(`${TAG} Permission not persisted, trying to persist...`);
        try {
          const policyInfo: fileShare.PolicyInfo = {
            uri: this.downloadDirUri,
            operationMode: fileShare.OperationMode.READ_MODE | fileShare.OperationMode.WRITE_MODE,
          };
          const policies: fileShare.PolicyInfo[] = [policyInfo];
          await fileShare.persistPermission(policies);
          console.info(`${TAG} Permission persisted, activating again...`);
          await fileShare.activatePermission(policies);
          console.info(`${TAG} Download permission activated after persist`);
        } catch (persistErr) {
          console.error(`${TAG} Failed to persist permission: ${(persistErr as Error).message}`);
        }
      }
    }
  }

  /**
   * 获取下载目录路径
   */
  public getDownloadDirPath(): string {
    return this.downloadDirPath;
  }

  /**
   * 获取下载目录 URI
   */
  public getDownloadDirUri(): string {
    return this.downloadDirUri;
  }

  /**
   * 检查下载目录是否已初始化
   */
  public isInitialized(): boolean {
    return !!this.downloadDirPath;
  }
}
