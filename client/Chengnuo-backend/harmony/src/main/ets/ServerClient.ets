import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BackendConfig } from './BackendConfig';

/** 一次服务器转发的结果（对齐 Node 版 clientRouter.submitToServer 的返回） */
export class SubmitResult {
  readonly ok: boolean;
  readonly status: number;
  readonly body: Object | null;
  readonly error: string | null;

  constructor(ok: boolean, status: number, body: Object | null, error: string | null) {
    this.ok = ok;
    this.status = status;
    this.body = body;
    this.error = error;
  }
}

/** 服务器转发客户端：只发 serviceId + payload + 登录 token，服务器同步应答（不需反向回连） */
export class ServerClient {
  static async submitToServer(serviceId: number, token: string | null,
    payload: Record<string, Object>): Promise<SubmitResult> {
    const url: string = `${BackendConfig.getServerBase()}/api/route/task`;
    const body: Record<string, Object> = { 'serviceId': serviceId, 'payload': payload };
    if (token !== null && token.trim().length > 0) {
      // 登录凭据：服务器据此反解调用者身份（注册/登录/退出/注销无需携带）
      body['token'] = token.trim();
    }
    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json' } as Record<string, string>,
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 60000
      });
      const status: number = response.responseCode;
      const text: string = typeof response.result === 'string' ? response.result as string : `${response.result}`;
      let parsed: Object | null = null;
      try {
        parsed = JSON.parse(text);
      } catch (e) {
        const raw: Record<string, Object> = { 'raw': text };
        parsed = raw;
      }
      return new SubmitResult(status >= 200 && status < 300, status, parsed, null);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      return new SubmitResult(false, 0, null, err.message);
    } finally {
      httpRequest.destroy();
    }
  }
}
