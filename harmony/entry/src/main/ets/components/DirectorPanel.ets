import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { DirectorRemote, DirectorStatus } from '../common/DirectorRemote';
import { MobileTheme as MT } from '../common/MobileTheme';
import { Logger } from '../common/Logger';

/**
 * DirectorPanel — W3 C4 phone-side director console. Lists trusted
 * same-account devices, connects the ability-collaboration session to the
 * one running OBS (the producer), then renders live state: scene buttons
 * (tap = cut), record/stream toggles fed back by the producer's status
 * JSON. Mounted under the camera role page so the phone is "camera OR
 * remote" from one screen.
 *
 * Contrast rework 10-17: colours from MobileTheme — the old muted fills
 * (#2f6f3e/#8a3434/#345a8a) read as "disabled" on a phone and the unlabelled
 * default text vanished on dark surfaces. Scene buttons are now real T-bars
 * (tall, bold, selected = green), transport buttons are saturated fills.
 */
@ComponentV2
export struct DirectorPanel {
  @Local peers: DirectorPeerEntry[] = [];
  @Local connected: boolean = false;
  @Local connecting: boolean = false;
  @Local statusText: string = '未发现已配对的设备';
  @Local scenes: string[] = [];
  @Local selectedScene: string = '';
  @Local recording: boolean = false;
  @Local streaming: boolean = false;
  private pollTimerId: number = -1;

  aboutToAppear(): void {
    DirectorRemote.onStatus = (st: DirectorStatus | undefined, connected: boolean) => {
      this.connected = connected;
      this.connecting = false;
      if (st === undefined) {
        this.statusText = connected ? '已连接' : '未连接（制作端断开）';
        return;
      }
      if (st.scenes !== undefined) {
        this.scenes = st.scenes;
      }
      if (st.selectedScene !== undefined) {
        this.selectedScene = st.selectedScene;
      }
      if (st.recording !== undefined) {
        this.recording = st.recording;
      }
      if (st.streaming !== undefined) {
        this.streaming = st.streaming;
      }
      if (st.action === 'switchScene' && st.scene !== undefined) {
        this.selectedScene = st.scene;
      }
      this.statusText = '已连接制作端';
    };
    this.refreshPeers();
    // Status heartbeat: pull producer state once a second while connected —
    // the console must reflect a REC started on the producer itself too.
    this.pollTimerId = setInterval(() => {
      if (DirectorRemote.connected) {
        DirectorRemote.requestStatus();
      }
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.pollTimerId >= 0) {
      clearInterval(this.pollTimerId);
      this.pollTimerId = -1;
    }
    DirectorRemote.onStatus = null;
    DirectorRemote.teardown('panel hide');
  }

  private refreshPeers(): void {
    this.peers = DirectorRemote.listPeers().map((p) => {
      const e = new DirectorPeerEntry();
      e.deviceId = p.deviceId;
      e.deviceName = p.deviceName;
      return e;
    });
    if (this.peers.length === 0 && !this.connected) {
      this.statusText = '未发现已配对的设备（先在超级终端配对同账号设备）';
    } else if (!this.connected) {
      this.statusText = `发现 ${this.peers.length} 台设备，点连接`;
    }
  }

  private connectTo(peer: DirectorPeerEntry): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.connecting = true;
      this.statusText = `正在连接 ${peer.deviceName}…`;
      const ok = DirectorRemote.connectTo(peer.deviceId, ctx);
      if (!ok) {
        this.connecting = false;
        this.statusText = '会话创建失败（检查 DISTRIBUTED_DATASYNC 授权）';
      }
    } catch (err) {
      this.connecting = false;
      this.statusText = `连接异常：${Logger.asError(err as Object).message}`;
    }
  }

  private statusColor(): string {
    if (this.connected) {
      return MT.ok;
    }
    return this.statusText.indexOf('失败') >= 0 || this.statusText.indexOf('异常') >= 0 ? MT.live : MT.textDim;
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Circle({ width: 9, height: 9 }).fill(this.connected ? MT.ok : MT.textDim)
        Text('导播台')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(MT.textStrong)
        Blank()
        Button(this.connected ? '断开' : '刷新设备')
          .type(ButtonType.Normal)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(MT.text)
          .height(32)
          .padding({ left: 14, right: 14, top: 0, bottom: 0 })
          .backgroundColor(MT.inset)
          .borderRadius(6)
          .border({ width: 1, color: MT.cardBorder })
          .onClick(() => {
            if (this.connected) {
              DirectorRemote.teardown('user');
              this.connected = false;
              this.scenes = [];
              this.refreshPeers();
            } else {
              this.refreshPeers();
            }
          })
      }
      .width('100%')

      if (!this.connected) {
        ForEach(this.peers, (peer: DirectorPeerEntry) => {
          Row({ space: 10 }) {
            Text(peer.deviceName)
              .fontSize(15)
              .fontColor(MT.text)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Button(this.connecting ? '连接中…' : '连接')
              .type(ButtonType.Normal)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .height(36)
              .width(88)
              .borderRadius(6)
              .enabled(!this.connecting)
              .backgroundColor(MT.blue)
              .onClick(() => {
                this.connectTo(peer);
              })
          }
          .width('100%')
        }, (peer: DirectorPeerEntry) => peer.deviceId)
      } else {
        // Scene strip: tap a scene = cut on the producer. Selected scene
        // carries the green T-bar look of the desktop program channel.
        Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
          ForEach(this.scenes, (name: string, idx: number) => {
            Button(name)
              .type(ButtonType.Normal)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .height(40)
              .padding({ left: 16, right: 16, top: 0, bottom: 0 })
              .borderRadius(6)
              .backgroundColor(name === this.selectedScene ? MT.green : MT.inset)
              .border({ width: 1, color: name === this.selectedScene ? MT.green : MT.cardBorder })
              .onClick(() => {
                DirectorRemote.switchScene(idx);
              })
          }, (name: string) => name)
        }
        .width('100%')

        Row({ space: 10 }) {
          Button(this.recording ? '● 停止录制' : '● 开始录制')
            .type(ButtonType.Normal)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .height(44)
            .layoutWeight(1)
            .borderRadius(8)
            .backgroundColor(this.recording ? MT.red : MT.green)
            .onClick(() => {
              DirectorRemote.toggleRecording();
            })
          Button(this.streaming ? '■ 停止直播' : '▶ 开始直播')
            .type(ButtonType.Normal)
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .height(44)
            .layoutWeight(1)
            .borderRadius(8)
            .backgroundColor(this.streaming ? MT.red : MT.blue)
            .onClick(() => {
              DirectorRemote.toggleStreaming();
            })
        }
        .width('100%')
      }

      Text(this.statusText)
        .fontSize(13)
        .fontColor(this.statusColor())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(MT.card)
    .borderRadius(10)
    .border({ width: 1, color: MT.cardBorder })
  }
}

/** Typed ForEach item (ArkTS forbids anonymous object literals in state). */
export class DirectorPeerEntry {
  deviceId: string = '';
  deviceName: string = '';
}
