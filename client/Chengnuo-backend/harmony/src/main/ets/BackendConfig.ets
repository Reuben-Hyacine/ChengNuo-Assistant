import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/**
 * 库配置：数据目录（filesDir/backend-data）+ 服务器地址。
 * 数据全部落在 App 沙箱内，仅 App 自身可读。
 */
export class BackendConfig {
  private static dataDir: string = '';
  private static bootAtMs: number = 0;
  private static initialized: boolean = false;
  /** 进程内 Ability 上下文（rawfile 资源读取用，init 时记录） */
  private static appContext: common.Context | null = null;
  /** server 基地址，形如 http://10.0.2.2:3000 */
  private static serverBase: string = 'http://10.0.2.2:3000';

  static init(context: common.Context): void {
    if (BackendConfig.initialized) {
      return;
    }
    BackendConfig.appContext = context;
    try {
      const baseDir: string = context.filesDir;
      const dir: string = `${baseDir}/backend-data`;
      // fs.accessSync 对不存在的路径会抛 13900002（而非返回 false），
      // 不能用「!accessSync(dir) 才 mkdir」判断；直接 mkdir（已存在时抛错忽略）后按存在性收尾
      try {
        fileIo.mkdirSync(dir, true);
      } catch (e) {
        // 目录已存在或暂时创建失败：以下面的存在性检查为准
      }
      let usable: boolean = false;
      try {
        usable = fileIo.accessSync(dir);
      } catch (e) {
        usable = false;
      }
      if (usable) {
        BackendConfig.dataDir = dir;
      }
      BackendConfig.bootAtMs = BackendConfig.loadBootAt();
      BackendConfig.initialized = true;
    } catch (e) {
      BackendConfig.bootAtMs = Date.now();
    }
  }

  private static bootAtFilePath(): string {
    return `${BackendConfig.dataDir}/boot-at.txt`;
  }

  private static loadBootAt(): number {
    try {
      const filePath: string = BackendConfig.bootAtFilePath();
      if (fileIo.accessSync(filePath)) {
        const text: string = fileIo.readTextSync(filePath);
        const value: number = Number(text.trim());
        if (Number.isFinite(value) && value > 0) {
          return value;
        }
      }
      const now: number = Date.now();
      const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, `${now}`);
      fileIo.closeSync(file);
      return now;
    } catch (e) {
      return Date.now();
    }
  }

  /** 本次安装周期内的首启时刻（毫秒），与 ServerGateway 的 bootId 语义一致 */
  static bootId(): number {
    return BackendConfig.bootAtMs;
  }

  /** 取 init 时记录的进程上下文（未 init 返回 null，调用方自行兜底） */
  static context(): common.Context | null {
    return BackendConfig.appContext;
  }

  static dataFilePath(name: string): string {
    return `${BackendConfig.dataDir}/${name}`;
  }

  static getServerBase(): string {
    return BackendConfig.serverBase;
  }

  static setServerBase(base: string): void {
    const trimmed: string = base.trim();
    if (trimmed.length > 0) {
      BackendConfig.serverBase = trimmed;
    }
  }
}
