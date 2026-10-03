import { abilityConnectionManager } from '@kit.DistributedServiceKit';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';
import { ObsController, ObsAppState } from '../model/ObsModel';

const TAG = 'DirectorLink';
const SERVICE_NAME = 'obs-director';

/** Typed reply payload — ArkTS forbids untyped object literals. All fields
 * optional so one class covers every command result; JSON.stringify skips
 * undefined members so the wire format stays minimal. */
class DirectorReply {
  ok: boolean = true;
  action?: string;
  scene?: string;
  recording?: boolean;
  streaming?: boolean;
  scenes?: string[];
  selectedScene?: string;
  error?: string;
}

/** Parsed command frame from the phone console. */
class DirectorCommand {
  action: string = '';
  index: number = -1;
}

/**
 * DirectorLink — W3 C4 server side: the MatePad Edge running OBS becomes
 * the *sink* of a cross-device Ability connection, and a phone running any
 * client (our future director UI, or even this same app) is the *source*.
 * Text is the only payload three-party apps may send over this channel —
 * which is all a director console needs: small JSON commands
 *   { "action": "switchScene", "index": 1 }
 *   { "action": "toggleRecording" }
 *   { "action": "toggleStreaming" }
 *   { "action": "status" }
 * and status JSON flowing back.
 *
 * Flow per the official guide (abilityconnectmanager-guidelines): the
 * source device's connect() raises this app's UIAbility through
 * onCollaborate; we rebuild the session from the wantParam echo (PeerInfo
 * and ConnectOptions are handed back to us), register
 * 'receiveMessage'/'connect'/'disconnect', and acceptConnect with the
 * collabToken. Long-running-task caveat from the docs: backgrounded or
 * locked-screen apps lose the collaboration after 5 s unless a continuous
 * task is held — streaming already holds audioRecording, so the console
 * stays alive exactly while it matters.
 *
 * Single-device reality: the phone client cannot be exercised without a
 * second device on the same account; the sink is a pure state machine and
 * compiles clean here.
 */
export class DirectorLink {
  private static sessionId: number = -1;

  /** Entry from EntryAbility.onCollaborate (source side connect()). */
  static onCollaborate(wantParam: Record<string, Object>, context: common.UIAbilityContext): void {
    const collabParam = wantParam['ohos.extra.param.key.supportCollaborateIndex'] as Record<string, Object>;
    if (collabParam === undefined || collabParam === null) {
      Logger.warn(`${TAG}: no collaborate index in wantParam, ignoring`);
      return;
    }
    const peerInfo = collabParam['PeerInfo'] as abilityConnectionManager.PeerInfo;
    const options = collabParam['ConnectOption'] as abilityConnectionManager.ConnectOptions;
    if (peerInfo === undefined || options === undefined) {
      Logger.warn(`${TAG}: wantParam lacks PeerInfo/ConnectOption`);
      return;
    }
    DirectorLink.teardown('re-collaborate');

    let sessionId = -1;
    try {
      sessionId = abilityConnectionManager.createAbilityConnectionSession(SERVICE_NAME, context, peerInfo, options);
    } catch (err) {
      Logger.error(`${TAG}: createSession failed`, Logger.asError(err as Object));
      return;
    }
    if (sessionId === -1) {
      Logger.warn(`${TAG}: createSession returned -1`);
      return;
    }
    DirectorLink.sessionId = sessionId;
    DirectorLink.registerEvents(sessionId);

    const collabToken = collabParam['ohos.dms.collabToken'] as string;
    abilityConnectionManager.acceptConnect(sessionId, collabToken).then(() => {
      Logger.info(`${TAG}: accepted connect (sessionId=${sessionId})`);
      DirectorLink.pushStatus(sessionId);
    }).catch((err: Object) => {
      Logger.error(`${TAG}: acceptConnect failed`, Logger.asError(err));
      DirectorLink.teardown('accept failed');
    });
  }

  private static registerEvents(sessionId: number): void {
    abilityConnectionManager.on('connect', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
      Logger.info(`${TAG}: session connected (${info.sessionId})`);
    });
    abilityConnectionManager.on('disconnect', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
      Logger.info(`${TAG}: session disconnected (${info.sessionId})`);
    });
    abilityConnectionManager.on('receiveMessage', sessionId, (info: abilityConnectionManager.EventCallbackInfo) => {
      const msg = DirectorLink.messageOf(info);
      if (msg !== '') {
        DirectorLink.handleCommand(msg, sessionId);
      }
    });
  }

  /** EventCallbackInfo carries the text payload on `message`; the declared
   * interface is broad, so read through a Record view. */
  private static messageOf(info: abilityConnectionManager.EventCallbackInfo): string {
    const bag = info as Object as Record<string, Object>;
    const raw = bag['message'];
    return typeof raw === 'string' ? raw : '';
  }

  /** Command grammar (JSON text; three-party channels are text-only). */
  private static handleCommand(json: string, sessionId: number): void {
    Logger.info(`${TAG}: command ${json}`);
    let cmd: DirectorCommand;
    try {
      cmd = JSON.parse(json) as DirectorCommand;
    } catch (err) {
      DirectorLink.replyOk(sessionId, undefined, 'not-json');
      return;
    }
    if (typeof cmd.action !== 'string' || cmd.action === '') {
      DirectorLink.replyOk(sessionId, undefined, 'missing action');
      return;
    }
    const model = ObsAppState.getInstance();
    switch (cmd.action) {
      case 'switchScene': {
        const scenes = model.scenes;
        if (cmd.index >= 0 && cmd.index < scenes.length) {
          ObsController.selectScene(scenes[cmd.index].id);
          const reply = new DirectorReply();
          reply.ok = true;
          reply.action = cmd.action;
          reply.scene = scenes[cmd.index].name;
          DirectorLink.send(sessionId, reply);
        } else {
          DirectorLink.replyOk(sessionId, cmd.action, 'index out of range');
        }
        break;
      }
      case 'toggleRecording':
        ObsController.toggleRecording();
        DirectorLink.replyState(sessionId, cmd.action);
        break;
      case 'toggleStreaming':
        ObsController.toggleStreaming();
        DirectorLink.replyState(sessionId, cmd.action);
        break;
      case 'status':
        DirectorLink.pushStatus(sessionId);
        break;
      default:
        DirectorLink.replyOk(sessionId, cmd.action, 'unknown action');
    }
  }

  private static replyOk(sessionId: number, action: string | undefined, error: string): void {
    const reply = new DirectorReply();
    reply.ok = false;
    reply.action = action;
    reply.error = error;
    DirectorLink.send(sessionId, reply);
  }

  private static replyState(sessionId: number, action: string): void {
    const model = ObsAppState.getInstance();
    const reply = new DirectorReply();
    reply.ok = true;
    reply.action = action;
    reply.recording = model.stats.recording;
    reply.streaming = model.stats.streaming;
    DirectorLink.send(sessionId, reply);
  }

  private static pushStatus(sessionId: number): void {
    const model = ObsAppState.getInstance();
    const reply = new DirectorReply();
    reply.ok = true;
    reply.action = 'status';
    reply.recording = model.stats.recording;
    reply.streaming = model.stats.streaming;
    reply.selectedScene = model.selectedSceneId;
    reply.scenes = model.scenes.map((s) => s.name);
    DirectorLink.send(sessionId, reply);
  }

  private static send(sessionId: number, reply: DirectorReply): void {
    abilityConnectionManager.sendMessage(sessionId, JSON.stringify(reply)).catch((err: Object) => {
      Logger.warn(`${TAG}: reply failed: ${Logger.asError(err).message}`);
    });
  }

  /** Called from EntryAbility.onDestroy / when the collaboration is over. */
  static teardown(reason: string): void {
    if (DirectorLink.sessionId !== -1) {
      Logger.info(`${TAG}: teardown (${reason}) sessionId=${DirectorLink.sessionId}`);
      try {
        abilityConnectionManager.destroyAbilityConnectionSession(DirectorLink.sessionId);
      } catch (err) {
        Logger.warn(`${TAG}: destroy failed: ${Logger.asError(err as Object).message}`);
      }
      DirectorLink.sessionId = -1;
    }
  }
}
