import { abilityConnectionManager } from '@kit.DistributedServiceKit';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'DirectorRemote';
const SERVICE_NAME = 'obs-director';

/** One entry of the producer-side status reply (mirrors DirectorLink.ets). */
export class DirectorStatus {
  ok: boolean = true;
  action?: string;
  scene?: string;
  selectedScene?: string;
  recording?: boolean;
  streaming?: boolean;
  scenes?: string[];
  error?: string;
}

/** Typed peer descriptor (ArkTS forbids untyped object literals). */
class RemotePeer {
  deviceId: string = '';
  deviceName: string = '';
}

/**
 * DirectorRemote — W3 C4 client side: the phone becomes the *source* of a
 * cross-device Ability connection and the producer (MatePad Edge running
 * OBS) is the sink (DirectorLink.ets). Text JSON commands flow one way
 * (switchScene / toggleRecording / toggleStreaming / status), status JSON
 * flows back and drives this UI.
 *
 * Peer discovery uses distributedDeviceManager.getAvailableDeviceListSync():
 * trusted same-account devices on the LAN. The deviceId it returns is the
 * networkId abilityConnectionManager expects. DISTRIBUTED_DATASYNC (granted
 * at launch) gates both APIs; without a trusted pair the list is empty and
 * the UI says so instead of pretending.
 */
export class DirectorRemote {
  private static sessionId: number = -1;
  static onStatus: ((status: DirectorStatus | undefined, connected: boolean) => void) | null = null;
  static connected: boolean = false;

  /** Trusted same-account producer candidates (all devices; the caller
   * filters by what actually runs OBS — we just list names). */
  static listPeers(): RemotePeer[] {
    const out: RemotePeer[] = [];
    try {
      const dm = distributedDeviceManager.createDeviceManager(
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).name);
      for (const d of dm.getAvailableDeviceListSync()) {
        const p = new RemotePeer();
        p.deviceId = d.networkId ?? '';
        p.deviceName = d.deviceName ?? 'unknown';
        if (p.deviceId.length > 0) {
          out.push(p);
        }
      }
    } catch (err) {
      Logger.error(`${TAG}: listPeers failed`, Logger.asError(err as Object));
    }
    return out;
  }

  static connectTo(peerDeviceId: string, context: common.UIAbilityContext): boolean {
    DirectorRemote.teardown('re-connect');
    try {
      const peerInfo: abilityConnectionManager.PeerInfo = {
        deviceId: peerDeviceId,
        bundleName: 'com.qingkouwei.qinglu',
        moduleName: 'entry',
        abilityName: 'EntryAbility',
        serviceName: SERVICE_NAME,
      };
      const options: abilityConnectionManager.ConnectOptions = {
        needSendData: true,
      };
      const sessionId = abilityConnectionManager.createAbilityConnectionSession(
        SERVICE_NAME, context, peerInfo, options);
      if (sessionId === -1) {
        Logger.warn(`${TAG}: createSession returned -1`);
        return false;
      }
      DirectorRemote.sessionId = sessionId;
      abilityConnectionManager.on('receiveMessage', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
        DirectorRemote.handleReply(info);
      });
      abilityConnectionManager.on('disconnect', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
        Logger.info(`${TAG}: producer disconnected (${info.sessionId})`);
        DirectorRemote.connected = false;
        DirectorRemote.emit(undefined);
      });
      abilityConnectionManager.connect(sessionId).then((result: abilityConnectionManager.ConnectResult) => {
        DirectorRemote.connected = result.isConnected;
        Logger.info(`${TAG}: connect result isConnected=${result.isConnected} err=${result.errorCode ?? 0}`);
        DirectorRemote.emit(undefined);
        if (result.isConnected) {
          DirectorRemote.requestStatus();
        }
      }).catch((err: Object) => {
        Logger.error(`${TAG}: connect rejected`, Logger.asError(err));
        DirectorRemote.connected = false;
        DirectorRemote.emit(undefined);
      });
      return true;
    } catch (err) {
      Logger.error(`${TAG}: connectTo failed`, Logger.asError(err as Object));
      return false;
    }
  }

  /** Command frame (subset of fields per action). */
  private static send(cmd: DirectorCommand): void {
    Logger.info(`${TAG}: send action=${cmd.action} session=${DirectorRemote.sessionId} connected=${DirectorRemote.connected}`);
    if (DirectorRemote.sessionId === -1 || !DirectorRemote.connected) return;
    abilityConnectionManager.sendMessage(DirectorRemote.sessionId, JSON.stringify(cmd)).catch((err: Object) => {
      Logger.warn(`${TAG}: send failed: ${Logger.asError(err).message}`);
    });
  }

  static switchScene(index: number): void {
    const cmd = new DirectorCommand();
    cmd.action = 'switchScene';
    cmd.index = index;
    DirectorRemote.send(cmd);
  }

  static toggleRecording(): void {
    const cmd = new DirectorCommand();
    cmd.action = 'toggleRecording';
    DirectorRemote.send(cmd);
  }

  static toggleStreaming(): void {
    const cmd = new DirectorCommand();
    cmd.action = 'toggleStreaming';
    DirectorRemote.send(cmd);
  }

  static requestStatus(): void {
    const cmd = new DirectorCommand();
    cmd.action = 'status';
    DirectorRemote.send(cmd);
  }

  private static handleReply(info: abilityConnectionManager.EventCallbackInfo): void {
    // EventCallbackInfo text field is `msg` (not `message`) — see DirectorLink.
    const bag = info as Object as Record<string, Object>;
    const raw = bag['msg'];
    if (typeof raw !== 'string' || raw.length === 0) return;
    try {
      const st = JSON.parse(raw) as DirectorStatus;
      DirectorRemote.emit(st);
    } catch (err) {
      Logger.warn(`${TAG}: bad reply ${raw}`);
    }
  }

  private static emit(st: DirectorStatus | undefined): void {
    if (DirectorRemote.onStatus !== null) {
      DirectorRemote.onStatus(st, DirectorRemote.connected);
    }
  }

  static teardown(reason: string): void {
    if (DirectorRemote.sessionId !== -1) {
      Logger.info(`${TAG}: teardown (${reason})`);
      try {
        abilityConnectionManager.off('receiveMessage', DirectorRemote.sessionId);
        abilityConnectionManager.destroyAbilityConnectionSession(DirectorRemote.sessionId);
      } catch (err) {
        Logger.warn(`${TAG}: destroy failed: ${Logger.asError(err as Object).message}`);
      }
      DirectorRemote.sessionId = -1;
      DirectorRemote.connected = false;
    }
  }
}

/** Parsed command frame sent to the producer (mirrors DirectorLink). */
class DirectorCommand {
  action: string = '';
  index: number = -1;
}
