import Foundation
import os

public enum XPCConfiguration {
  /// Bundle identifier of a XPC service.
  case serviceName(String)
  /// Mach service name advertised via launchd.plist.
  case machServiceName(String, options: NSXPCConnection.Options)
}

/// Live connection to the given XPC service.
final public class XPC<P> {

  public let configuration: XPCConfiguration
  
  /// Callback for unexpected XPC errors.
  public let errorHandler: (_ error: Error) -> Void

  /// Current XPC state.
  @Atomic
  private var cachedState: (connection: NSXPCConnection, proxy: P)? {
    willSet {
      cachedState?.connection.invalidate()
    }
  }

  /// Creates a live XPC connection.
  /// - Parameter configuration: Configuration for XPC service.
  /// - Parameter errorHandler: Callback for unexpected XPC errors.
  /// - Parameter error: XPC error.
  public init(configuration: XPCConfiguration, errorHandler: @escaping (_ error: Error) -> Void) {
    self.configuration = configuration
    self.errorHandler = errorHandler
  }

  /// Cleanup XPC connection.
  deinit {
    self.cachedState = nil
  }
}

// MARK: - Internal API

public extension XPC {

  /// Performs a XPC operation.
  /// - Parameter handler: Callback with a proxy object.
  /// - Parameter proxy: Remote object interface.
  func callProxy(_ handler: (_ proxy: P) -> Void) {
    do {
      handler(try proxy())
    } catch {
      cachedState = nil
      errorHandler(error)
    }
  }
}

// MARK: - Private API

private extension XPC {

  /// Used to create a XPC if needed and returns a proxy or an error.
  func proxy() throws -> P {
    if let state = cachedState {
      return state.proxy
    }

    // Service protocol cannot be created from `String(describing: P.self)` so we use a method `dump` and strip special characters
    var dumpOutput = ""
    _ = dump(P.self, to: &dumpOutput)
    let components = dumpOutput.components(separatedBy: " ")
    guard let protocolName = components.first(where: { $0.contains(".") }), let serviceProtocol = NSProtocolFromString(protocolName) else {
      os_log(.error, log: events, "Invalid Proxy Type")
      throw CocoaError(.xpcConnectionInvalid)
    }

    let connection = NSXPCConnection(configuration: configuration)
    connection.remoteObjectInterface = .init(with: serviceProtocol)
    connection.resume()
    connection.interruptionHandler = { [weak self] in
      os_log(.error, log: events, "Exit or Crash")
      self?.errorHandler(CocoaError(.xpcConnectionInterrupted))
    }
    let anyProxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
      os_log(.error, log: events, "No Reply: %{public}s", String(describing: error))
      self?.errorHandler(error)
    }
    guard let proxy = anyProxy as? P else {
      os_log(.error, log: events, "Invalid Proxy Type")
      throw CocoaError(.xpcConnectionInvalid)
    }
    cachedState = (connection, proxy)
    return proxy
  }
}

/// Local handle for logging events.
private let events: OSLog = .init(subsystem: "com.apple.feedback.SharedKit.Events", category: "XPC")

extension NSXPCConnection {
  convenience init(configuration: XPCConfiguration) {
    switch configuration {
    case let .serviceName(serviceName):
      self.init(serviceName: serviceName)
    case let .machServiceName(machServiceName, options: options):
      self.init(machServiceName: machServiceName, options: options)
    }
  }
}
