import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VibeIslandWidgetBundle: WidgetBundle {
  var body: some Widget {
    VibeIslandLiveActivity()
  }
}

struct VibeIslandLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: VibeIslandAttributes.self) { context in
      HStack(spacing: 12) {
        AnimatedPixelPetView(
          petType: context.state.petType,
          status: context.state.status,
          frame: context.state.frame,
          animStart: context.state.animStart,
          size: 34
        )

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Circle()
              .fill(statusColor(context.state.status))
              .frame(width: 7, height: 7)
            Text(statusTitle(context.state.status))
              .font(.caption.bold())
              .foregroundColor(.white)
            Spacer()
            Text(context.state.title)
              .font(.caption2)
              .foregroundColor(.white.opacity(0.68))
              .lineLimit(1)
          }
          Text(context.state.body.isEmpty ? "VibeHelper 实时同步中" : context.state.body)
            .font(.caption)
            .foregroundColor(.white.opacity(0.9))
            .lineLimit(2)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .activityBackgroundTint(Color(red: 0.051, green: 0.067, blue: 0.094))
      .activitySystemActionForegroundColor(Color.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            AnimatedPixelPetView(
              petType: context.state.petType,
              status: context.state.status,
              frame: context.state.frame,
              animStart: context.state.animStart,
              size: 26
            )
            Text(statusTitle(context.state.status))
              .font(.caption.bold())
              .foregroundColor(statusColor(context.state.status))
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          HStack(spacing: 4) {
            if context.state.status == "working" {
              Text(context.state.animStart, style: .timer)
                .font(.caption2.monospacedDigit())
                .foregroundColor(statusColor(context.state.status))
                .lineLimit(1)
            }
            Text(context.state.title)
              .font(.caption2.weight(.semibold))
              .foregroundColor(.white.opacity(0.75))
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(context.state.body.isEmpty ? "VibeHelper 正在监听 Agent 状态" : context.state.body)
              .font(.caption)
              .foregroundColor(.white.opacity(0.92))
              .lineLimit(2)
            HStack {
              Text(context.state.showActions ? "点击进入 VibeHelper 允许 / 拒绝" : "点击回到对话")
                .font(.caption2)
                .foregroundColor(statusColor(context.state.status).opacity(0.95))
              Spacer()
            }
          }
          .padding(.top, 2)
        }
      } compactLeading: {
        AnimatedPixelPetView(
          petType: context.state.petType,
          status: context.state.status,
          frame: context.state.frame,
          animStart: context.state.animStart,
          size: 20
        )
      } compactTrailing: {
        HStack(spacing: 4) {
          Circle()
            .fill(statusColor(context.state.status))
            .frame(width: 6, height: 6)
          Text(shortLabel(context.state.status))
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .lineLimit(1)
        }
      } minimal: {
        AnimatedPixelPetView(
          petType: context.state.petType,
          status: context.state.status,
          frame: context.state.frame,
          animStart: context.state.animStart,
          size: 18
        )
      }
      .keylineTint(statusColor(context.state.status))
    }
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "waiting_approval":
      return Color(red: 0.961, green: 0.620, blue: 0.043)
    case "question":
      return Color(red: 0.545, green: 0.361, blue: 0.965)
    case "working":
      return Color(red: 0.220, green: 0.741, blue: 0.973)
    case "disconnected":
      return Color(red: 0.937, green: 0.267, blue: 0.267)
    default:
      return Color(red: 0.204, green: 0.827, blue: 0.600)
    }
  }

  private func statusTitle(_ status: String) -> String {
    switch status {
    case "waiting_approval":
      return "等待授权"
    case "question":
      return "Agent 提问"
    case "working":
      return "思考执行中"
    case "disconnected":
      return "连接断开"
    default:
      return "Agent 就绪"
    }
  }

  private func shortLabel(_ status: String) -> String {
    switch status {
    case "waiting_approval":
      return "待授权"
    case "question":
      return "提问"
    case "working":
      return "执行中"
    case "disconnected":
      return "断连"
    default:
      return "就绪"
    }
  }
}

/// Native background-animated 12x12 pixel pet powered by custom pixel TTF fonts
/// driven by SpringBoard's `Text(timerInterval:)` clock (1fps animation even when app is suspended).
struct AnimatedPixelPetView: View {
  let petType: String
  let status: String
  let frame: Int
  let animStart: Date
  let size: CGFloat

  private var layerSpecs: [(String, Color)] {
    switch petType {
    case "cat":
      return [
        ("VibePetCatBody", Color(red: 0.231, green: 0.259, blue: 0.329)),
        ("VibePetCatEyes", Color(red: 0.980, green: 0.800, blue: 0.082)),
        ("VibePetCatDetail", Color(red: 0.957, green: 0.447, blue: 0.714)),
      ]
    case "bot":
      let glow: Color = {
        switch status {
        case "waiting_approval", "question":
          return Color(red: 0.961, green: 0.620, blue: 0.043)
        case "working":
          return Color(red: 0.133, green: 0.827, blue: 0.933)
        default:
          return Color(red: 0.220, green: 0.741, blue: 0.973)
        }
      }()
      return [
        ("VibePetBotBody", Color(red: 0.796, green: 0.835, blue: 0.882)),
        ("VibePetBotScreen", Color(red: 0.118, green: 0.161, blue: 0.231)),
        ("VibePetBotGlow", glow),
      ]
    default:
      return [
        ("VibePetShibaBody", Color(red: 0.961, green: 0.620, blue: 0.043)),
        ("VibePetShibaDark", Color(red: 0.471, green: 0.208, blue: 0.059)),
        ("VibePetShibaLight", Color(red: 0.996, green: 0.953, blue: 0.780)),
      ]
    }
  }

  // Font+timer rendering was invisible inside the Live Activity process on
  // sideloaded builds, so always draw the reliable Canvas sprite instead.
  var body: some View {
    PixelPetCanvas(petType: petType, status: status, frame: frame)
      .frame(width: size, height: size)
  }
}

/// 12x12 pixel-art pet renderer matching Android `IslandPetView.kt`.
struct PixelPetCanvas: View {
  let petType: String
  let status: String
  let frame: Int

  var body: some View {
    Canvas { context, size in
      let petSize = min(size.width, size.height)
      guard petSize > 0 else { return }
      let cell = petSize / 12.0
      let left = (size.width - petSize) / 2.0
      let top = (size.height - petSize) / 2.0
      let sprite = spriteRows()
      let yShift: CGFloat = {
        switch status {
        case "working":
          return (frame % 2 == 1) ? -0.45 * cell : 0
        case "waiting_approval", "question":
          return (frame % 4 == 1) ? -0.6 * cell : 0
        default:
          return 0
        }
      }()
      let dim = status == "disconnected"
      let flip = (frame % 16) >= 8

      for r in 0..<min(12, sprite.count) {
        let chars = Array(sprite[r])
        for c in 0..<min(12, chars.count) {
          let ch = chars[c]
          if ch == "." { continue }
          guard let color = pixelColor(ch, dim: dim) else { continue }
          let col = flip ? (11 - c) : c
          let x0 = left + CGFloat(col) * cell
          let y0 = max(0, min(size.height, top + CGFloat(r) * cell + yShift))
          let rect = CGRect(x: x0, y: y0, width: cell + 0.35, height: cell + 0.35)
          context.fill(Path(rect), with: .color(color))
        }
      }

      drawBadge(context: &context, left: left, top: top, cell: cell)
    }
  }

  private func drawBadge(context: inout GraphicsContext, left: CGFloat, top: CGFloat, cell: CGFloat) {
    switch status {
    case "working":
      let c = (frame % 2 == 0)
        ? Color(red: 0.220, green: 0.741, blue: 0.973)
        : Color(red: 0.376, green: 0.647, blue: 0.980)
      let sx: CGFloat = (frame % 2 == 0) ? 10 : 9
      let sy: CGFloat = (frame % 4 < 2) ? 1 : 2
      context.fill(
        Path(CGRect(x: left + sx * cell, y: top + sy * cell, width: 1.5 * cell, height: 1.5 * cell)),
        with: .color(c)
      )
    case "waiting_approval":
      if frame % 2 == 0 {
        let c = Color(red: 0.961, green: 0.620, blue: 0.043)
        context.fill(
          Path(CGRect(x: left + 10 * cell, y: top + 0.5 * cell, width: 1.4 * cell, height: 2.7 * cell)),
          with: .color(c)
        )
        context.fill(
          Path(CGRect(x: left + 10 * cell, y: top + 4 * cell, width: 1.4 * cell, height: 1.2 * cell)),
          with: .color(c)
        )
      }
    case "question":
      let dy: CGFloat = (frame % 2 == 0) ? 0 : -0.4 * cell
      let c = Color(red: 0.984, green: 0.749, blue: 0.141)
      context.fill(
        Path(CGRect(x: left + 9.5 * cell, y: max(0, top + 0.5 * cell + dy), width: 2.0 * cell, height: 1.7 * cell)),
        with: .color(c)
      )
      context.fill(
        Path(CGRect(x: left + 10 * cell, y: top + 3 * cell + dy, width: 1.2 * cell, height: 1.2 * cell)),
        with: .color(c)
      )
    case "idle", "done":
      if frame % 4 < 3 {
        let c = Color(red: 0.204, green: 0.827, blue: 0.600)
        let rise = CGFloat(frame % 3) * 0.4 * cell
        context.fill(
          Path(CGRect(x: left + 9.8 * cell, y: max(0, top + 2.0 * cell - rise), width: 1.6 * cell, height: 1.2 * cell)),
          with: .color(c)
        )
      }
    default:
      break
    }
  }

  private func spriteRows() -> [String] {
    let f = frame % 8
    switch petType {
    case "cat":
      let blink = (status == "idle" || status == "done") && f == 7
      let tailUp = f % 2 == 0
      let eye = blink ? "K" : "E"
      let tailA = tailUp ? "KKKKKKKKKK.K" : "KKKKKKKKKK.."
      let tailB = tailUp ? ".KDDDDDDK.K." : ".KDDDDDDKKK."
      let paw = (status == "working" && f % 2 == 1) ? "..W.KKKK.W.." : "..KK....WW.."
      return [
        "............",
        "..KP....PK..",
        "..KKKKKKKK..",
        ".KKKKKKKKKK.",
        ".KK\(eye)KKKK\(eye)KK.",
        ".KKKKPPKKKK.",
        tailA,
        tailB,
        "..KKKKKKKK..",
        "..KKKKKKKK..",
        paw,
        "............",
      ]
    case "bot":
      let blink = f == 5 && status != "working"
      let visor = blink ? "S" : "C"
      let ant = (f % 2 == 0) ? ".....AA....." : ".....MM....."
      let foot = (status == "working" && f % 2 == 1) ? "..M......M.." : "...MM..MM..."
      return [
        ant,
        ".....MM.....",
        "..LLLLLLLL..",
        ".LMMMMMMMMM.",
        ".LMSSSSSSSM.",
        ".LMS\(visor)SSS\(visor)SM.",
        ".LMSSSSSSSM.",
        "..LLLLLLLL..",
        "..MMMMMMMM..",
        "..MMCCCCMM..",
        foot,
        "............",
      ]
    default:
      let blink = (status == "idle" || status == "done") && f == 7
      let wag = f < 4
      let eye = blink ? "B" : "E"
      let tail6 = wag ? "..BBBBBBBB.." : "...BBBBBBBO."
      let tail7 = wag ? ".BOOOOOOOB.." : "..OOOOOOOOB."
      let paw = (status == "working" && f % 2 == 1) ? "..C.CCCC.C.." : "..CC....CC.."
      return [
        "............",
        "..BB....BB..",
        "..BOOOOOOB..",
        ".BOOOOOOOOB.",
        ".BOO\(eye)OO\(eye)OOB.",
        ".BOCECCCOOB.",
        tail6,
        tail7,
        "..OOCCCCOO..",
        "..OOOOOOOO..",
        paw,
        "............",
      ]
    }
  }

  private func pixelColor(_ ch: Character, dim: Bool) -> Color? {
    var rgb: (Double, Double, Double)?
    switch petType {
    case "cat":
      switch ch {
      case "K": rgb = (0.231, 0.259, 0.329)
      case "D": rgb = (0.137, 0.157, 0.212)
      case "E": rgb = (0.980, 0.800, 0.082)
      case "P": rgb = (0.957, 0.447, 0.714)
      case "W": rgb = (0.886, 0.910, 0.941)
      default: return nil
      }
    case "bot":
      switch ch {
      case "M": rgb = (0.580, 0.639, 0.722)
      case "L": rgb = (0.796, 0.835, 0.882)
      case "S": rgb = (0.118, 0.161, 0.231)
      case "C":
        if status == "waiting_approval" || status == "question" {
          rgb = (0.961, 0.620, 0.043)
        } else if status == "disconnected" {
          rgb = (0.392, 0.455, 0.545)
        } else {
          rgb = (0.220, 0.741, 0.973)
        }
      case "A":
        rgb = (status == "working" && frame % 2 == 0)
          ? (0.133, 0.827, 0.933)
          : (0.961, 0.620, 0.043)
      default: return nil
      }
    default:
      switch ch {
      case "O": rgb = (0.898, 0.604, 0.235)
      case "B": rgb = (0.541, 0.294, 0.094)
      case "C": rgb = (1.000, 0.953, 0.839)
      case "E": rgb = (0.118, 0.106, 0.094)
      case "P": rgb = (0.957, 0.447, 0.714)
      default: return nil
      }
    }
    guard let c = rgb else { return nil }
    let mult = dim ? 0.45 : 1.0
    return Color(red: c.0 * mult, green: c.1 * mult, blue: c.2 * mult)
  }
}
