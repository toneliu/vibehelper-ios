#if canImport(ActivityKit)
import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct VibeIslandAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public var status: String
    public var title: String
    public var body: String
    public var petType: String
    public var showActions: Bool
    public var frame: Int
    public var animStart: Date

    public init(
      status: String,
      title: String,
      body: String,
      petType: String,
      showActions: Bool,
      frame: Int,
      animStart: Date = Date()
    ) {
      self.status = status
      self.title = title
      self.body = body
      self.petType = petType
      self.showActions = showActions
      self.frame = frame
      self.animStart = animStart
    }
  }

  public init() {}
}
#endif
